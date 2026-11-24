
/* #####################################################################
   QUESTION 8 - Transport Fleet Maintenance
   ##################################################################### */
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path TO q8, public;

-- (a) Tables ------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE NOT NULL
);

-- (b) Function ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END $$;

-- (c) Procedure (does NOT touch the odometer; the trigger does) ----------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE,
                                           p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id; END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (d) Trigger -----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % <= start %', NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
                        NEW.start_odometer, v_current;
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer      -- exactly once per trip
    WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- (a) continued: seed data (trips go through the procedure) --------------
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1001', 10000,  8000),   -- 2,000 km since service
 ('BCD 2002', 25000, 19000),   -- 6,000 km: already due
 ('CDE 3003', 39000, 35000);   -- 4,000 km: becomes exactly 5,000

CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10300);
CALL pr_record_trip(1, CURRENT_DATE - 5, 10300, 10800);
CALL pr_record_trip(2, CURRENT_DATE - 4, 25000, 25400);
CALL pr_record_trip(2, CURRENT_DATE - 3, 25400, 26000);
CALL pr_record_trip(3, CURRENT_DATE - 2, 39000, 39500);
CALL pr_record_trip(3, CURRENT_DATE - 1, 39500, 40000);

SELECT vehicle_id, registration, current_odometer, fn_service_due(vehicle_id) AS due
FROM vehicles ORDER BY vehicle_id;    -- false, true, true (exactly 5,000)
-- Rejected: CALL pr_record_trip(1, CURRENT_DATE, 9999, 10100);  -- start mismatch

-- (e) View --------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) Index -------------------------------------------------------------
-- Equality on vehicle_id then range on trip_on: the B-tree returns one vehicle's
-- trips for a date window as a single ordered slice, with no sort needed.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts() LANGUAGE plpgsql AS $$
BEGIN
    -- remove alerts for vehicles that are no longer due (e.g. after servicing)
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                      WHERE v.vehicle_id = sa.vehicle_id
                        AND v.current_odometer - v.last_service_odometer >= 5000);
    -- insert or update one alert per due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service, flagged_on = EXCLUDED.flagged_on;
END $$;

SELECT cron.schedule('q8_refresh_service_alerts', '0 6 * * 1',     -- Mondays 06:00
       $$CALL q8.pr_refresh_service_alerts()$$);

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2; -- serviced
CALL pr_refresh_service_alerts();                        -- alert for vehicle 2 removed
SELECT * FROM service_alerts;

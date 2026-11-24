# Q8 – Transport Fleet Maintenance (schema `q8`)

**Purpose:** record trips and flag vehicles that have travelled at least 5,000 km since their last service.

## Objects
| Part | Object | What it does |
|---|---|---|
| (a) | `vehicles`, `trips`, `service_alerts` | non-negative odometers, `last_service_odometer <= current_odometer`; 3 vehicles, 6 trips loaded via the procedure |
| (b) | `fn_service_due(id)` | `current − last_service >= 5000`; rejects unknown vehicle |
| (c) | `pr_record_trip(vehicle, date, start, end)` | validates vehicle and `end > start`; inserts the trip **without** touching the odometer |
| (d) | `trg_trips_odometer` | BEFORE INSERT; start must equal current odometer, rejects bad mileage, updates `current_odometer` once |
| (e) | `v_service_due` | registration and km since service for due vehicles |
| (f) | `idx_trips_vehicle_trip_on (vehicle_id, trip_on)` | one vehicle + date range |
| (g) | `pr_refresh_service_alerts()` + job `q8_refresh_service_alerts` | deletes alerts no longer due, upserts alerts for due vehicles; cron `0 6 * * 1` |

## Design note
The trigger owns the odometer update, so the procedure must not update it (otherwise it would be applied twice). Vehicle 3 ends at exactly 5,000 km to test the boundary.

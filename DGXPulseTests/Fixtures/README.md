# Fixtures

Captured from the live DGX Dashboard exposed via NVIDIA Sync on localhost.

| File | Source |
| --- | --- |
| `unauthorized_telemetry.json` | `GET /api/v1/gpu_telemetry/stream` without `Authorization` |
| `unauthorized_updates.json` | `GET /api/v1/updates/available` without `Authorization` |
| `login_failure.json` | `POST /api/login` with invalid credentials |
| `login_success.json` | Shape of `POST /api/login` success (`token` key); value redacted |
| `gpu_telemetry.json` | `gpu_telemetry` SSE `data` payload field names from the live dashboard client (`TelemetryForGPUs`, `percentage_utilization`, `memory_total_in_mb`, `memory_available_in_mb`); values match a live dashboard screenshot |
| `gpu_telemetry_stream.sse` | SSE framing (`event` + `data`) as consumed by the dashboard stream client |

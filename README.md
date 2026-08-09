# DGXPulse

Native macOS menu bar monitor for your [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/). Open it and it just works when NVIDIA Sync (or an SSH tunnel) is exposing the local DGX Dashboard.

## Requirements

- macOS 15.0+
- [NVIDIA Sync](https://docs.nvidia.com/sync/latest/index.html) connected to your Spark (LAN or Tailscale), **or** a manual tunnel to the dashboard
- DGX Dashboard credentials (same as the web UI)

DGXPulse is **not App Sandboxed**. It needs to read NVIDIA Sync’s local device config and run the Sync CLI (`nvsync status`) to learn which localhost port currently maps to the remote dashboard. That is intentional for a local companion utility.

## First run

1. Connect to your Spark in NVIDIA Sync (open DGX Dashboard once if needed).
2. Launch DGXPulse.
3. Sign in once with your dashboard username and password.
4. RAM and GPU appear in the menu bar; open the detail window for gauges and history.

Credentials: password is never stored. The session token is kept in Keychain.

## How DGXPulse finds the dashboard

On the Spark, DGX Dashboard listens on **remote port `11000`**. NVIDIA Sync tunnels that port to your Mac.

Sync prefers local `11000` too, but when that port is taken (common after sleep or relaunch) it binds a **different local port**. The browser URL Sync opens (for example `http://localhost:61704`) is that mapped port.

DGXPulse asks Sync for the mapping via the Sync CLI:

```bash
nvsync status <device-alias>
```

Example response (trimmed):

```json
{
  "status": "RUNNING",
  "ports": {
    "11000": { "local_port": 61704, "status": "OPENED" }
  }
}
```

Discovery order:

1. Base URL override from Preferences (if set)
2. Sync CLI local port for remote `11000`
3. Last working URL (re-verified)
4. Manual tunnel default `http://127.0.0.1:11000`

On Mac wake, stream failure, or stale telemetry, DGXPulse forgets the old URL and resolves again.

Manual tunnel example (no Sync):

```bash
ssh -L 11000:localhost:11000 <user>@<spark-host>
```

## Develop

```bash
make check   # swift-format, SwiftLint, unit tests
open DGXPulse.xcodeproj
```

Features land via pull requests. CI runs format, lint, and tests on every PR.

## Legal

DGXPulse is an independent, unofficial project and is not affiliated with, sponsored by, or endorsed by NVIDIA Corporation. NVIDIA, DGX, DGX Spark, NVIDIA Sync, and DGX Dashboard are trademarks of NVIDIA Corporation or its affiliates.

# DGXPulse

Native macOS menu bar monitor for your [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/). Open it and it just works when NVIDIA Sync (or an SSH tunnel) is exposing the local DGX Dashboard.

## Requirements

- macOS 26.4+
- [NVIDIA Sync](https://docs.nvidia.com/sync/latest/index.html) connected to your Spark (LAN or Tailscale), **or** a manual tunnel to the dashboard
- DGX Dashboard credentials (same as the web UI)

## First run

1. Connect to your Spark in NVIDIA Sync (open DGX Dashboard once if needed).
2. Launch DGXPulse.
3. Sign in once with your dashboard username and password.
4. RAM and GPU appear in the menu bar; open the detail window for gauges and history.

Credentials: password is never stored. The session token is kept in Keychain.

## Ports

Defaults assume dashboard port `11000` (Sync may bind a different local port). DGXPulse discovers the live localhost dashboard and remembers the last working URL. Override in Preferences only if you need to.

Manual tunnel example:

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

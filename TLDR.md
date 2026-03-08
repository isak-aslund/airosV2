# AirOS Containerization — TLDR

## Problem
Full OS rebuild every time any software changes. No way to know versions on a drone.
Manual SSH + git operations to update.

## Solution
Split into Base OS (flash once) + Docker Compose stack (update via web UI or zip).

## Architecture

```
             Docker Compose (on Jetson Orin NX)
  ┌──────────────┬──────────────┬──────────────┐
  │ airos-video  │ airos-flight │ airos-manager│
  │ MediaMTX     │ MAVLink Rtr  │ FastAPI :8080│
  │ AR0234 gst   │ ACC+10 svc   │ Web UI       │
  │ IMX678 gst   │ D-Bus(int.)  │ Updates      │
  │ NVIDIA GPU   │ SPI/UART/GPIO│ Networking   │
  ├──────────────┴──────────────┴──────────────┤
  │     sightec (optional, profile-gated)       │
  ├─────────────────────────────────────────────┤
  │ Base OS: L4T R36.4.0 + kernel + cam drivers│
  │ Docker + NVIDIA CT + NetworkManager + SSH   │
  │ systemd: airos-compose.service (boots stack)│
  │          airos-watchdog.timer (safety net)   │
  │          nvargus-daemon (camera ISP)         │
  └─────────────────────────────────────────────┘
```

## Key Files
- `docker-compose.yml` — defines the 4-service stack
- `versions.env` — all version pins
- `containers/airos-video/Dockerfile` — 2-stage: mediamtx + gstreamer
- `containers/airos-flight/Dockerfile` — 6-stage: mavlink-router + ACC + nmea + logger + sender
- `containers/airos-flight/patches/s6-systemd-shim.py` — adapts ACC systemd calls to s6
- `containers/airos-manager/app/` — FastAPI web UI + update + networking
- `base-os/build-base-os.sh` — builds minimal flash image
- `Makefile` — build-all, create-update, push-all

## How Updates Work
1. `make build-all` builds 3 container images (arm64)
2. `make create-update` packages them into a .zip with manifest.json + checksums
3. Connect to drone at 192.168.144.111:8080
4. Drag-drop the .zip → manager validates, loads images, atomic compose update, health checks
5. If anything fails → automatic rollback to previous version

## Networking
- Declared in `/etc/airos/network.yml`
- Default: 192.168.144.111/24 + 10.223.0.111/16, gateway 192.168.144.78
- Can be updated via web UI or included in update zip
- Applied via nmcli

## What's Done (105 files, all tested)
- All 3 Dockerfiles (video, flight, manager)
- s6-overlay service definitions (15 services total)
- s6-systemd-shim.py (ACC compatibility layer)
- FastAPI manager with update/network/status/logs endpoints
- Web UI (dark theme, auto-refresh, drag-drop upload)
- Base OS build script + systemd units + watchdog
- Makefile + cross-compilation setup
- Docker daemon.json (NVIDIA runtime + log rotation)

## What's Next
1. Cross-compile arm64 images on x86_64 (docker buildx) ← being set up now
2. Test on actual Jetson hardware
3. Build base OS image and flash
4. End-to-end update test via web UI
5. Sightec integration test
6. GitHub Actions CI/CD

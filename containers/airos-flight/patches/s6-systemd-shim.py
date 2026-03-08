"""
s6-overlay shim for ACC's systemd service management.

Drop-in replacement for ACC/dbus/systemd.py that translates systemd
service control calls into s6-svc subprocess calls. Provides the same
async API (start_service, stop_service, restart_service, service_exists)
so ACC code does not need modification.
"""

import asyncio
import os
from utils import ACC_Logger

# Map systemd service names to s6 service directories
_SERVICE_MAP = {
    "airolit_mavlink_router.service": "mavlink-router",
    "airolit_gremsy.service": "gremsy",
    "airolit_nextvision.service": "nextvision",
    "airolit_AR0234.service": "ar0234-stream",
    "airolit_ECON_IMX678.service": "imx678-stream",
    "airolit_FRAMOS_IMX678.service": "imx678-stream",
}

S6_SERVICE_DIR = "/run/service"


def _resolve_service(service_name: str) -> str | None:
    """Resolve a systemd service name to its s6 service directory name."""
    return _SERVICE_MAP.get(service_name)


async def start_service(bus, service_name: str, mode: str = "replace") -> str:
    """Start an s6-managed service (equivalent to systemctl start)."""
    logger = ACC_Logger.get_logger("systemd")
    s6_name = _resolve_service(service_name)
    if s6_name is None:
        logger.error(f"No s6 mapping for systemd service: {service_name}")
        return ""
    svc_dir = f"{S6_SERVICE_DIR}/{s6_name}"
    if not os.path.isdir(svc_dir):
        logger.error(f"s6 service directory does not exist: {svc_dir}")
        return ""
    try:
        proc = await asyncio.create_subprocess_exec("s6-svc", "-u", svc_dir)
        await proc.wait()
        logger.info(f"Started s6 service: {s6_name}")
    except Exception as e:
        logger.warning(f"Failed to start s6 service {s6_name}: {e}")
    return svc_dir


async def restart_service(bus, service_name: str, mode: str = "replace") -> str:
    """Restart an s6-managed service (equivalent to systemctl restart)."""
    logger = ACC_Logger.get_logger("systemd")
    s6_name = _resolve_service(service_name)
    if s6_name is None:
        logger.error(f"No s6 mapping for systemd service: {service_name}")
        return ""
    svc_dir = f"{S6_SERVICE_DIR}/{s6_name}"
    if not os.path.isdir(svc_dir):
        logger.error(f"s6 service directory does not exist: {svc_dir}")
        return ""
    try:
        proc = await asyncio.create_subprocess_exec("s6-svc", "-r", svc_dir)
        await proc.wait()
        logger.info(f"Restarted s6 service: {s6_name}")
    except Exception as e:
        logger.warning(f"Failed to restart s6 service {s6_name}: {e}")
    return svc_dir


async def stop_service(bus, service_name: str, mode: str = "replace") -> str:
    """Stop an s6-managed service (equivalent to systemctl stop)."""
    logger = ACC_Logger.get_logger("systemd")
    s6_name = _resolve_service(service_name)
    if s6_name is None:
        logger.error(f"No s6 mapping for systemd service: {service_name}")
        return ""
    svc_dir = f"{S6_SERVICE_DIR}/{s6_name}"
    if not os.path.isdir(svc_dir):
        logger.error(f"s6 service directory does not exist: {svc_dir}")
        return ""
    try:
        proc = await asyncio.create_subprocess_exec("s6-svc", "-d", svc_dir)
        await proc.wait()
        logger.info(f"Stopped s6 service: {s6_name}")
    except Exception as e:
        logger.warning(f"Failed to stop s6 service {s6_name}: {e}")
    return svc_dir


async def service_exists(bus, service_name: str) -> bool:
    """Check if an s6 service directory exists (equivalent to systemctl list-units)."""
    s6_name = _resolve_service(service_name)
    if s6_name is None:
        return False
    return os.path.isdir(f"{S6_SERVICE_DIR}/{s6_name}")

from __future__ import annotations

import json
import logging
import os
import shutil
import socket
import time
from pathlib import Path

import docker
import yaml
from fastapi import APIRouter, HTTPException

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1", tags=["status"])

MANIFEST_PATH = Path("/etc/airos/manifest.json")
NETWORK_CONFIG_PATH = Path("/etc/airos/network.yml")
COMPOSE_PROJECT_LABEL = "com.docker.compose.project"


def _get_uptime() -> str:
    """Read system uptime from /proc/uptime."""
    try:
        raw = Path("/proc/uptime").read_text()
        seconds = float(raw.split()[0])
        days = int(seconds // 86400)
        hours = int((seconds % 86400) // 3600)
        minutes = int((seconds % 3600) // 60)
        if days > 0:
            return f"{days}d {hours}h {minutes}m"
        if hours > 0:
            return f"{hours}h {minutes}m"
        return f"{minutes}m"
    except (FileNotFoundError, ValueError):
        return "unknown"


def _get_disk_usage() -> dict:
    """Get disk usage for root partition."""
    try:
        usage = shutil.disk_usage("/")
        return {
            "total_gb": round(usage.total / (1024**3), 1),
            "used_gb": round(usage.used / (1024**3), 1),
            "free_gb": round(usage.free / (1024**3), 1),
            "percent": round(usage.used / usage.total * 100, 1),
        }
    except OSError:
        return {"total_gb": 0, "used_gb": 0, "free_gb": 0, "percent": 0}


def _get_memory_usage() -> dict:
    """Parse /proc/meminfo for memory stats."""
    try:
        info: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                key = parts[0].rstrip(":")
                info[key] = int(parts[1])  # in kB

        total = info.get("MemTotal", 0)
        available = info.get("MemAvailable", 0)
        used = total - available

        return {
            "total_mb": round(total / 1024, 0),
            "used_mb": round(used / 1024, 0),
            "available_mb": round(available / 1024, 0),
            "percent": round(used / total * 100, 1) if total > 0 else 0,
        }
    except (FileNotFoundError, ValueError, ZeroDivisionError):
        return {"total_mb": 0, "used_mb": 0, "available_mb": 0, "percent": 0}


def _get_base_version() -> str | None:
    """Read base OS version from manifest."""
    try:
        raw = MANIFEST_PATH.read_text(encoding="utf-8")
        data = json.loads(raw)
        return data.get("version")
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def _get_network_config() -> dict | None:
    """Read network.yml if present."""
    try:
        raw = NETWORK_CONFIG_PATH.read_text(encoding="utf-8")
        return yaml.safe_load(raw)
    except (FileNotFoundError, yaml.YAMLError):
        return None


def _parse_version_from_image(image_tags: list[str]) -> str:
    """Extract version tag from image. Prefers semver-like tags."""
    for tag in image_tags:
        # tag format: registry/name:version or name:version
        if ":" in tag:
            version = tag.rsplit(":", 1)[-1]
            if version != "latest":
                return version
    # Fallback
    if image_tags:
        tag = image_tags[0]
        if ":" in tag:
            return tag.rsplit(":", 1)[-1]
    return "unknown"


def _get_containers() -> list[dict]:
    """List compose-managed containers with details."""
    try:
        client = docker.from_env()
    except docker.errors.DockerException as exc:
        logger.error("Cannot connect to Docker: %s", exc)
        return []

    try:
        containers = client.containers.list(
            all=True,
            filters={"label": COMPOSE_PROJECT_LABEL},
        )

        result: list[dict] = []
        for c in containers:
            state = c.attrs.get("State", {})

            health = "none"
            health_obj = state.get("Health")
            if health_obj:
                health = health_obj.get("Status", "unknown")

            status = state.get("Status", "unknown")
            image_tags = c.image.tags if c.image else []

            result.append({
                "name": c.name,
                "image": image_tags[0] if image_tags else "unknown",
                "status": status,
                "health": health,
                "version": _parse_version_from_image(image_tags),
                "labels": c.labels,
                "created": c.attrs.get("Created", ""),
            })

        return result
    finally:
        client.close()


@router.get("/status")
async def get_status():
    """Full system and container status."""
    return {
        "system": {
            "hostname": socket.gethostname(),
            "uptime": _get_uptime(),
            "disk": _get_disk_usage(),
            "memory": _get_memory_usage(),
            "base_version": _get_base_version(),
        },
        "containers": _get_containers(),
        "network": _get_network_config(),
        "timestamp": time.time(),
    }

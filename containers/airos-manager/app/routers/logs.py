from __future__ import annotations

import logging

import docker
from fastapi import APIRouter, HTTPException, Query

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1", tags=["logs"])


@router.get("/logs/{container_name}")
async def get_container_logs(
    container_name: str,
    lines: int = Query(default=100, ge=1, le=10000),
):
    """Return the last N lines of a container's logs."""
    try:
        client = docker.from_env()
    except docker.errors.DockerException as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Cannot connect to Docker: {exc}",
        ) from exc

    try:
        container = client.containers.get(container_name)
    except docker.errors.NotFound:
        client.close()
        raise HTTPException(
            status_code=404,
            detail=f"Container '{container_name}' not found",
        )
    except docker.errors.APIError as exc:
        client.close()
        raise HTTPException(
            status_code=500,
            detail=f"Docker API error: {exc}",
        ) from exc

    try:
        raw_logs = container.logs(tail=lines, timestamps=True)
        log_text = raw_logs.decode(errors="replace")

        log_lines = []
        for line in log_text.splitlines():
            # Timestamps from docker are ISO format at start of line
            if " " in line:
                ts, msg = line.split(" ", 1)
                log_lines.append({"timestamp": ts, "message": msg})
            else:
                log_lines.append({"timestamp": "", "message": line})

        return {
            "container": container_name,
            "lines": len(log_lines),
            "logs": log_lines,
        }
    except docker.errors.APIError as exc:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get logs: {exc}",
        ) from exc
    finally:
        client.close()

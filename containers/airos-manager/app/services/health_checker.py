from __future__ import annotations

import asyncio
import logging
import time

import docker

logger = logging.getLogger(__name__)

COMPOSE_PROJECT_LABEL = "com.docker.compose.project"


async def wait_for_healthy(
    timeout: int = 120,
    poll_interval: float = 3.0,
) -> tuple[bool, dict[str, str]]:
    """Poll all compose-managed containers until healthy or timeout.

    Returns (all_healthy, container_statuses) where container_statuses maps
    container name to its health state string.
    """
    loop = asyncio.get_running_loop()
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        statuses = await loop.run_in_executor(None, _check_containers)
        if not statuses:
            logger.warning("No compose containers found, retrying...")
            await asyncio.sleep(poll_interval)
            continue

        all_healthy = True
        for name, health in statuses.items():
            if health not in ("healthy", "none"):
                # "none" means no healthcheck defined -- treat as ok
                all_healthy = False
                break

        if all_healthy:
            logger.info("All containers healthy: %s", statuses)
            return True, statuses

        remaining = deadline - time.monotonic()
        logger.info(
            "Waiting for containers (%.0fs remaining): %s",
            remaining,
            statuses,
        )
        await asyncio.sleep(poll_interval)

    # Final check
    statuses = await loop.run_in_executor(None, _check_containers)
    all_healthy = all(
        h in ("healthy", "none") for h in statuses.values()
    )
    return all_healthy, statuses


def _check_containers() -> dict[str, str]:
    """Synchronous helper to inspect container health states."""
    try:
        client = docker.from_env()
    except docker.errors.DockerException:
        logger.error("Cannot connect to Docker daemon")
        return {}

    containers = client.containers.list(
        all=True,
        filters={"label": COMPOSE_PROJECT_LABEL},
    )

    statuses: dict[str, str] = {}
    for c in containers:
        health = "none"
        state = c.attrs.get("State", {})
        health_obj = state.get("Health")
        if health_obj:
            health = health_obj.get("Status", "unknown")

        # If container is not running, mark accordingly
        if state.get("Status") != "running":
            health = "stopped"

        statuses[c.name] = health

    client.close()
    return statuses

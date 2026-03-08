from __future__ import annotations

import asyncio
import logging
from pathlib import Path

import yaml

from models.network import Connection, IPv4Config, NetworkConfig

logger = logging.getLogger(__name__)

NETWORK_CONFIG_PATH = "/etc/airos/network.yml"


async def load_network_config(
    path: str | Path = NETWORK_CONFIG_PATH,
) -> NetworkConfig | None:
    """Parse network.yml and return a NetworkConfig, or None if missing."""
    path = Path(path)
    if not path.exists():
        return None

    loop = asyncio.get_running_loop()
    raw = await loop.run_in_executor(None, path.read_text, "utf-8")
    data = yaml.safe_load(raw)
    if data is None:
        return None
    return NetworkConfig(**data)


def validate_network_config(config: NetworkConfig) -> list[str]:
    """Return a list of validation errors (empty if valid)."""
    errors: list[str] = []
    if not config.connections:
        errors.append("At least one connection is required")

    seen_names: set[str] = set()
    seen_interfaces: set[str] = set()

    for conn in config.connections:
        if conn.name in seen_names:
            errors.append(f"Duplicate connection name: {conn.name}")
        seen_names.add(conn.name)

        if conn.interface in seen_interfaces:
            errors.append(f"Duplicate interface: {conn.interface}")
        seen_interfaces.add(conn.interface)

        if not conn.interface:
            errors.append(f"Connection '{conn.name}' missing interface")

        if conn.ipv4.method == "manual" and not conn.ipv4.addresses:
            errors.append(
                f"Connection '{conn.name}' uses manual method but has no addresses"
            )

        for addr in conn.ipv4.addresses:
            if "/" not in addr:
                errors.append(
                    f"Connection '{conn.name}' address '{addr}' missing CIDR prefix"
                )

    return errors


async def apply_network_config(config: NetworkConfig) -> list[str]:
    """Apply network config via nmcli. Returns list of errors (empty on success)."""
    errors: list[str] = []

    for conn in config.connections:
        try:
            await _apply_connection(conn)
        except Exception as exc:
            msg = f"Failed to apply connection '{conn.name}': {exc}"
            logger.error(msg)
            errors.append(msg)

    return errors


async def _apply_connection(conn: Connection) -> None:
    """Apply a single connection via nmcli."""
    exists = await _connection_exists(conn.name)

    if exists:
        await _modify_connection(conn)
    else:
        await _add_connection(conn)

    await _run_nmcli(["nmcli", "connection", "up", conn.name])


async def _connection_exists(name: str) -> bool:
    """Check if an nmcli connection profile exists."""
    proc = await asyncio.create_subprocess_exec(
        "nmcli", "connection", "show", name,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    await proc.communicate()
    return proc.returncode == 0


async def _modify_connection(conn: Connection) -> None:
    """Modify an existing connection."""
    cmd = ["nmcli", "connection", "modify", conn.name]
    cmd.extend(_ipv4_args(conn.ipv4))
    await _run_nmcli(cmd)


async def _add_connection(conn: Connection) -> None:
    """Add a new connection."""
    cmd = [
        "nmcli", "connection", "add",
        "con-name", conn.name,
        "ifname", conn.interface,
        "type", conn.type,
    ]
    cmd.extend(_ipv4_args(conn.ipv4))
    await _run_nmcli(cmd)


def _ipv4_args(ipv4: IPv4Config) -> list[str]:
    """Build nmcli ipv4.* arguments."""
    args: list[str] = [
        "ipv4.method", ipv4.method,
    ]
    if ipv4.addresses:
        args.extend(["ipv4.addresses", ",".join(ipv4.addresses)])
    if ipv4.gateway:
        args.extend(["ipv4.gateway", ipv4.gateway])
    if ipv4.dns:
        args.extend(["ipv4.dns", ",".join(ipv4.dns)])
    return args


async def _run_nmcli(cmd: list[str]) -> str:
    """Execute an nmcli command and return stdout. Raises on failure."""
    logger.info("Running: %s", " ".join(cmd))
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode != 0:
        err = stderr.decode(errors="replace").strip()
        raise RuntimeError(f"nmcli failed (rc={proc.returncode}): {err}")
    return stdout.decode(errors="replace")


async def get_current_state() -> list[dict]:
    """Get current network connection state from nmcli."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "nmcli", "-t", "-f",
            "NAME,TYPE,DEVICE,STATE,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS",
            "connection", "show", "--active",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode != 0:
            logger.warning(
                "nmcli state query failed: %s",
                stderr.decode(errors="replace"),
            )
            return []

        connections: list[dict] = []
        for line in stdout.decode(errors="replace").strip().splitlines():
            parts = line.split(":")
            if len(parts) >= 4:
                connections.append({
                    "name": parts[0],
                    "type": parts[1],
                    "device": parts[2],
                    "state": parts[3],
                })
        return connections
    except FileNotFoundError:
        logger.warning("nmcli not found")
        return []

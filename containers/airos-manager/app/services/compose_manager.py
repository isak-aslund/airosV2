from __future__ import annotations

import asyncio
import logging
import os
import shutil
from pathlib import Path

logger = logging.getLogger(__name__)

COMPOSE_FILE = "/etc/airos/docker-compose.yml"
ENV_FILE = "/etc/airos/versions.env"


async def atomic_write(path: str | Path, content: str | bytes) -> None:
    """Write content to path atomically via write-to-tmp then rename."""
    path = Path(path)
    tmp_path = path.with_suffix(path.suffix + ".new")

    loop = asyncio.get_running_loop()

    if isinstance(content, str):
        await loop.run_in_executor(None, _write_text, tmp_path, content)
    else:
        await loop.run_in_executor(None, _write_bytes, tmp_path, content)

    await loop.run_in_executor(None, os.rename, str(tmp_path), str(path))
    logger.info("Atomic write completed: %s", path)


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _write_bytes(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


async def backup_file(path: str | Path) -> Path | None:
    """Copy path to path.bak. Returns backup path or None if source missing."""
    path = Path(path)
    if not path.exists():
        return None
    bak = path.with_suffix(path.suffix + ".bak")
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, shutil.copy2, str(path), str(bak))
    logger.info("Backup created: %s -> %s", path, bak)
    return bak


async def restore_backup(path: str | Path) -> bool:
    """Rename path.bak back to path. Returns True on success."""
    path = Path(path)
    bak = path.with_suffix(path.suffix + ".bak")
    if not bak.exists():
        logger.warning("No backup to restore for %s", path)
        return False
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, os.rename, str(bak), str(path))
    logger.info("Restored backup: %s", path)
    return True


async def compose_up(
    compose_file: str = COMPOSE_FILE,
    env_file: str = ENV_FILE,
) -> tuple[int, str, str]:
    """Run docker compose up -d. Returns (returncode, stdout, stderr)."""
    cmd = [
        "docker", "compose",
        "-f", compose_file,
        "--env-file", env_file,
        "up", "-d", "--remove-orphans",
    ]
    logger.info("Running: %s", " ".join(cmd))
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    stdout_str = stdout.decode(errors="replace")
    stderr_str = stderr.decode(errors="replace")
    if proc.returncode != 0:
        logger.error("compose up failed (rc=%d): %s", proc.returncode, stderr_str)
    else:
        logger.info("compose up succeeded")
    return proc.returncode, stdout_str, stderr_str


async def compose_validate(path: str | Path) -> tuple[bool, str]:
    """Validate a docker-compose file. Returns (valid, message)."""
    cmd = ["docker", "compose", "-f", str(path), "config", "--quiet"]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode == 0:
        return True, "Valid"
    return False, stderr.decode(errors="replace").strip()

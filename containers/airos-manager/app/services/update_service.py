from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import docker

from models.manifest import Manifest, ManifestFile
from services import compose_manager
from services.health_checker import wait_for_healthy
from services.network_service import apply_network_config, load_network_config

logger = logging.getLogger(__name__)

AIROS_DIR = Path("/etc/airos")
HISTORY_FILE = Path("/app/data/update_history.json")

# Files that can appear in an update zip and their target paths
MANAGED_FILES = {
    "docker-compose.yml": AIROS_DIR / "docker-compose.yml",
    "versions.env": AIROS_DIR / "versions.env",
    "network.yml": AIROS_DIR / "network.yml",
}


async def validate_zip(zip_path: Path) -> tuple[Manifest | None, Path | None, list[str]]:
    """Extract and validate an update zip.

    Returns (manifest, extract_dir, errors).
    On success errors is empty; on failure manifest/extract_dir may be None.
    """
    errors: list[str] = []

    if not zipfile.is_zipfile(zip_path):
        return None, None, ["Uploaded file is not a valid zip archive"]

    extract_dir = Path(tempfile.mkdtemp(prefix="airos_update_"))

    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, _extract_zip, zip_path, extract_dir)

    manifest_path = extract_dir / "manifest.json"
    if not manifest_path.exists():
        return None, extract_dir, ["manifest.json not found in zip"]

    try:
        raw = manifest_path.read_text(encoding="utf-8")
        manifest = Manifest(**json.loads(raw))
    except Exception as exc:
        return None, extract_dir, [f"Invalid manifest.json: {exc}"]

    # Verify checksums
    for filename, file_meta in manifest.files.items():
        file_path = extract_dir / filename
        if not file_path.exists():
            errors.append(f"File listed in manifest not found: {filename}")
            continue
        actual_hash = await loop.run_in_executor(None, _sha256, file_path)
        if actual_hash != file_meta.sha256:
            errors.append(
                f"Checksum mismatch for {filename}: "
                f"expected {file_meta.sha256}, got {actual_hash}"
            )

    return manifest, extract_dir, errors


def _extract_zip(zip_path: Path, dest: Path) -> None:
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(dest)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


async def load_images(
    extract_dir: Path,
    manifest: Manifest,
) -> tuple[list[str], list[str]]:
    """Docker-load image tarballs. Returns (loaded, errors)."""
    loaded: list[str] = []
    errors: list[str] = []

    loop = asyncio.get_running_loop()

    for filename, file_meta in manifest.files.items():
        if file_meta.type != "image":
            continue

        tar_path = extract_dir / filename
        if not tar_path.exists():
            errors.append(f"Image file missing: {filename}")
            continue

        try:
            result = await loop.run_in_executor(None, _docker_load, tar_path)
            loaded.append(f"{filename}: {result}")
            logger.info("Loaded image: %s -> %s", filename, result)
        except Exception as exc:
            msg = f"Failed to load {filename}: {exc}"
            logger.error(msg)
            errors.append(msg)

    return loaded, errors


def _docker_load(tar_path: Path) -> str:
    """Synchronous docker load."""
    client = docker.from_env()
    try:
        with open(tar_path, "rb") as f:
            result = client.images.load(f)
        tags = []
        for img in result:
            tags.extend(img.tags)
        return ", ".join(tags) if tags else "loaded (untagged)"
    finally:
        client.close()


async def apply_update(
    extract_dir: Path,
    manifest: Manifest,
) -> dict:
    """Orchestrate the full update flow with rollback on failure.

    Returns a result dict with status, details, and any errors.
    """
    result = {
        "status": "success",
        "version": manifest.version,
        "loaded_images": [],
        "applied_configs": [],
        "errors": [],
        "rolled_back": False,
    }

    backed_up: list[str] = []

    try:
        # 1. Load docker images
        loaded, img_errors = await load_images(extract_dir, manifest)
        result["loaded_images"] = loaded
        if img_errors:
            result["errors"].extend(img_errors)
            result["status"] = "failed"
            return result

        # 2. Backup current files before overwriting
        for config_name, target_path in MANAGED_FILES.items():
            src = extract_dir / config_name
            if src.exists() and target_path.exists():
                bak = await compose_manager.backup_file(target_path)
                if bak:
                    backed_up.append(str(target_path))

        # 3. Apply config files
        # docker-compose.yml: validate before applying
        compose_src = extract_dir / "docker-compose.yml"
        if compose_src.exists():
            valid, msg = await compose_manager.compose_validate(compose_src)
            if not valid:
                result["errors"].append(f"Invalid docker-compose.yml: {msg}")
                result["status"] = "failed"
                await _rollback(backed_up)
                result["rolled_back"] = True
                return result

            content = compose_src.read_text(encoding="utf-8")
            await compose_manager.atomic_write(MANAGED_FILES["docker-compose.yml"], content)
            result["applied_configs"].append("docker-compose.yml")

        # versions.env
        env_src = extract_dir / "versions.env"
        if env_src.exists():
            content = env_src.read_text(encoding="utf-8")
            await compose_manager.atomic_write(MANAGED_FILES["versions.env"], content)
            result["applied_configs"].append("versions.env")

        # network.yml
        net_src = extract_dir / "network.yml"
        if net_src.exists():
            content = net_src.read_text(encoding="utf-8")
            await compose_manager.atomic_write(MANAGED_FILES["network.yml"], content)
            result["applied_configs"].append("network.yml")

            # Apply network config
            net_config = await load_network_config(MANAGED_FILES["network.yml"])
            if net_config:
                net_errors = await apply_network_config(net_config)
                if net_errors:
                    logger.warning("Network apply errors: %s", net_errors)
                    result["errors"].extend(net_errors)

        # 4. Docker compose up
        rc, stdout, stderr = await compose_manager.compose_up()
        if rc != 0:
            result["errors"].append(f"docker compose up failed: {stderr}")
            result["status"] = "failed"
            await _rollback(backed_up)
            result["rolled_back"] = True

            # Attempt recovery compose up after rollback
            rc2, _, stderr2 = await compose_manager.compose_up()
            if rc2 != 0:
                result["errors"].append(f"Rollback compose up also failed: {stderr2}")
            return result

        # 5. Wait for health checks
        healthy, statuses = await wait_for_healthy(timeout=120)
        result["container_statuses"] = statuses

        if not healthy:
            result["errors"].append(
                f"Containers not healthy after update: {statuses}"
            )
            result["status"] = "failed"

            logger.warning("Health check failed, rolling back...")
            await _rollback(backed_up)
            result["rolled_back"] = True

            rc2, _, stderr2 = await compose_manager.compose_up()
            if rc2 != 0:
                result["errors"].append(f"Rollback compose up failed: {stderr2}")
            return result

        # 6. Record in history
        await _record_history(result)

        return result

    except Exception as exc:
        logger.exception("Update failed with exception")
        result["status"] = "failed"
        result["errors"].append(str(exc))

        await _rollback(backed_up)
        result["rolled_back"] = True

        try:
            await compose_manager.compose_up()
        except Exception:
            result["errors"].append("Rollback compose up also failed")

        return result


async def _rollback(backed_up_paths: list[str]) -> None:
    """Restore all backed-up files."""
    for path_str in backed_up_paths:
        try:
            await compose_manager.restore_backup(path_str)
        except Exception as exc:
            logger.error("Failed to restore %s: %s", path_str, exc)


async def _record_history(result: dict) -> None:
    """Append update result to history file."""
    HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)

    history: list[dict] = []
    if HISTORY_FILE.exists():
        try:
            raw = HISTORY_FILE.read_text(encoding="utf-8")
            history = json.loads(raw)
        except (json.JSONDecodeError, OSError):
            history = []

    entry = {
        "version": result.get("version", "unknown"),
        "status": result["status"],
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "loaded_images": result.get("loaded_images", []),
        "applied_configs": result.get("applied_configs", []),
        "errors": result.get("errors", []),
    }
    history.append(entry)

    # Keep last 50 entries
    history = history[-50:]

    await compose_manager.atomic_write(HISTORY_FILE, json.dumps(history, indent=2))


async def get_update_history() -> list[dict]:
    """Read update history from disk."""
    if not HISTORY_FILE.exists():
        return []
    try:
        raw = HISTORY_FILE.read_text(encoding="utf-8")
        return json.loads(raw)
    except (json.JSONDecodeError, OSError):
        return []

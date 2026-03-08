from __future__ import annotations

import logging
import shutil
import tempfile
from pathlib import Path

from fastapi import APIRouter, HTTPException, UploadFile

from services.update_service import apply_update, get_update_history, validate_zip

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1", tags=["update"])


@router.post("/update")
async def upload_update(file: UploadFile):
    """Accept a .zip update bundle, validate, and apply it."""
    if not file.filename or not file.filename.endswith(".zip"):
        raise HTTPException(status_code=400, detail="Only .zip files are accepted")

    # Save uploaded file to temp location
    tmp_dir = Path(tempfile.mkdtemp(prefix="airos_upload_"))
    zip_path = tmp_dir / file.filename

    try:
        content = await file.read()
        zip_path.write_bytes(content)

        # Validate
        manifest, extract_dir, errors = await validate_zip(zip_path)
        if errors:
            raise HTTPException(
                status_code=400,
                detail={"message": "Validation failed", "errors": errors},
            )

        if manifest is None or extract_dir is None:
            raise HTTPException(
                status_code=400,
                detail="Failed to parse update package",
            )

        # Apply
        result = await apply_update(extract_dir, manifest)

        if result["status"] != "success":
            raise HTTPException(
                status_code=500,
                detail={
                    "message": "Update failed",
                    "errors": result.get("errors", []),
                    "rolled_back": result.get("rolled_back", False),
                },
            )

        return {
            "status": "success",
            "version": result.get("version"),
            "loaded_images": result.get("loaded_images", []),
            "applied_configs": result.get("applied_configs", []),
            "container_statuses": result.get("container_statuses", {}),
        }

    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("Unexpected error during update")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        # Clean up temp files
        shutil.rmtree(tmp_dir, ignore_errors=True)


@router.get("/update/history")
async def update_history():
    """Return update history."""
    history = await get_update_history()
    return {"history": history}

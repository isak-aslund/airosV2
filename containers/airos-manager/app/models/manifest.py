from __future__ import annotations

from pydantic import BaseModel


class ManifestFile(BaseModel):
    sha256: str
    type: str = "config"  # "config" or "image"


class Manifest(BaseModel):
    version: str
    created: str
    files: dict[str, ManifestFile]

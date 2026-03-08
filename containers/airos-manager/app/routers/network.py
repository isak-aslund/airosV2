from __future__ import annotations

import logging

import yaml
from fastapi import APIRouter, HTTPException

from models.network import NetworkConfig
from services import compose_manager
from services.network_service import (
    NETWORK_CONFIG_PATH,
    apply_network_config,
    get_current_state,
    load_network_config,
    validate_network_config,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1", tags=["network"])


@router.get("/network")
async def get_network():
    """Return current network configuration and live state."""
    config = await load_network_config()
    state = await get_current_state()

    if config is None:
        return {
            "config": None,
            "state": state,
            "message": "No network configuration file found",
        }

    return {
        "config": config.model_dump(),
        "state": state,
    }


@router.post("/network")
async def set_network(config: NetworkConfig):
    """Validate and apply a new network configuration."""
    # Validate
    errors = validate_network_config(config)
    if errors:
        raise HTTPException(
            status_code=400,
            detail={"message": "Invalid network configuration", "errors": errors},
        )

    # Backup current config
    await compose_manager.backup_file(NETWORK_CONFIG_PATH)

    # Write atomically
    content = yaml.dump(
        config.model_dump(),
        default_flow_style=False,
        sort_keys=False,
    )
    await compose_manager.atomic_write(NETWORK_CONFIG_PATH, content)

    # Apply via nmcli
    apply_errors = await apply_network_config(config)

    if apply_errors:
        # Attempt to restore previous config
        restored = await compose_manager.restore_backup(NETWORK_CONFIG_PATH)
        if restored:
            old_config = await load_network_config()
            if old_config:
                await apply_network_config(old_config)

        raise HTTPException(
            status_code=500,
            detail={
                "message": "Failed to apply network configuration",
                "errors": apply_errors,
                "rolled_back": restored,
            },
        )

    return {
        "status": "success",
        "config": config.model_dump(),
    }

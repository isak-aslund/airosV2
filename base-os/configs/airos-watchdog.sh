#!/bin/bash
# AirOS Manager Watchdog
# Ensures the management container stays running

COMPOSE_DIR="/etc/airos"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/versions.env"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "No compose file found at $COMPOSE_FILE"
    exit 1
fi

# Check if manager container is running and healthy
MANAGER_STATUS=$(docker inspect --format='{{.State.Health.Status}}' airos-airos-manager-1 2>/dev/null)

if [ "$MANAGER_STATUS" != "healthy" ]; then
    echo "Manager unhealthy (status: ${MANAGER_STATUS:-not found}), restarting compose stack..."
    cd "$COMPOSE_DIR"
    docker compose --env-file "$ENV_FILE" up -d --remove-orphans
fi

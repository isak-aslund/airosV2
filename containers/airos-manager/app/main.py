from __future__ import annotations

import logging
from contextlib import asynccontextmanager

import docker
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from pathlib import Path

from routers import logs, network, status, update

APP_DIR = Path(__file__).resolve().parent

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

docker_client: docker.DockerClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize Docker client on startup, close on shutdown."""
    global docker_client
    try:
        docker_client = docker.from_env()
        docker_client.ping()
        logger.info("Docker client initialized successfully")
    except docker.errors.DockerException as exc:
        logger.warning("Docker not available at startup: %s", exc)
        docker_client = None

    yield

    if docker_client:
        docker_client.close()
        logger.info("Docker client closed")


app = FastAPI(
    title="AirOS Manager",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS for local network access
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Routers
app.include_router(status.router)
app.include_router(update.router)
app.include_router(network.router)
app.include_router(logs.router)

# Static files
_static_dir = APP_DIR / "static"
if _static_dir.is_dir():
    app.mount("/static", StaticFiles(directory=str(_static_dir)), name="static")


@app.get("/")
async def index():
    """Serve the management UI."""
    return FileResponse(str(APP_DIR / "templates" / "index.html"))


@app.get("/health")
async def health():
    """Health check endpoint. Verifies docker socket is accessible."""
    docker_ok = False
    try:
        client = docker.from_env()
        client.ping()
        docker_ok = True
        client.close()
    except docker.errors.DockerException:
        pass

    if not docker_ok:
        return JSONResponse(
            status_code=503,
            content={"status": "degraded", "docker": False},
        )

    return {"status": "ok", "docker": True}

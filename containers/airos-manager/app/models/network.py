from __future__ import annotations

from pydantic import BaseModel


class IPv4Config(BaseModel):
    method: str = "manual"
    addresses: list[str]
    gateway: str | None = None
    dns: list[str] = []


class Connection(BaseModel):
    name: str
    interface: str
    type: str = "ethernet"
    ipv4: IPv4Config


class NetworkConfig(BaseModel):
    version: int = 1
    connections: list[Connection]

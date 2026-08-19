"""aria2c-manager: background aria2c server + web UI + browser intake."""

from .api import VERSION, create_app
from .config import Config

__all__ = ["VERSION", "create_app", "Config"]

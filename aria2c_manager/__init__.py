"""aria2c-manager: background aria2c server for the browser extension and DMS widget."""

from .api import VERSION, create_app
from .config import Config

__all__ = ["VERSION", "create_app", "Config"]

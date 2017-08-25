from .gil_load import init, test, start, stop, get, preload_path
try:
    from .__version__ import __version__
except ImportError:
    __version__ = None

__all__ = ["init", "test", "start", "stop", "get", "preload_path"]

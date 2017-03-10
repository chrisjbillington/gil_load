from .gil_load import init, get
try:
    from .__version__ import __version__
except ImportError:
    __version__ = None

__all__ = ["init", "get"]

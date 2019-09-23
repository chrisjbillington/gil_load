try:
    from .__version__ import __version__
except ImportError:
    __version__ = None

def _load_preload_lib():
    """profiling won't work if the library isn't preloaded using LD_PRELOAD,
    but we ensure it's loaded anyway so that we can import the cython
    extension and call its functions still - otherwise it won't import since
    it has not been linked to the preload library."""
    import os
    import ctypes
    from distutils.sysconfig import get_config_var
    this_dir = os.path.dirname(os.path.realpath(__file__))
    so_name = os.path.join(this_dir, 'preload')
    ext_suffix = get_config_var('EXT_SUFFIX')
    if ext_suffix is not None:
        so_name += ext_suffix
    else:
        so_name += '.so'
    ctypes.CDLL(so_name, ctypes.RTLD_GLOBAL) 
    return so_name

preload_path = _load_preload_lib()

from .gil_load import init, test, start, stop, get, format


__all__ = ["init", "test", "start", "stop", "get", "preload_path", "format"]

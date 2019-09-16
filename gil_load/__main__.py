import gil_load
import os
import sys

preload_path = gil_load.preload_path

LD_PRELOAD = os.getenv('LD_PRELOAD')
if LD_PRELOAD is not None:
    preload_path += ':' + LD_PRELOAD

os.environ['LD_PRELOAD'] = preload_path

os.execv(sys.executable, [sys.executable] + sys.argv[1:])

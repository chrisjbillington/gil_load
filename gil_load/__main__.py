from __future__ import absolute_import

# A litte module that just prints the preload path to stdout so that it can be preloaded like:
# LD_PRELOAD=$(python -m gil_load) python my_script.py
import gil_load
print(gil_load.preload_path)
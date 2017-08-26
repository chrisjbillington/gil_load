import sys
import os
from setuptools import setup
from setuptools.extension import Extension

from distutils.version import LooseVersion

VERSION = '0.3.5'

# Auto generate a __version__ package for the package to import
with open(os.path.join('gil_load', '__version__.py'), 'w') as f:
    f.write("__version__ = '%s'\n"%VERSION)

# Use cython to cythonize the extensions, but if the .c file is already
# distributed with sdist, use it and don't require users to have cython:
USE_CYTHON = False
if '--use-cython' in sys.argv:
    USE_CYTHON = True
    sys.argv.remove('--use-cython')
if 'sdist' in sys.argv:
    USE_CYTHON = True

if USE_CYTHON:
    import cython
    if LooseVersion(cython.__version__) < LooseVersion('0.22.0'):
        raise ValueError('cython >= 0.22 required')
    ext = '.pyx'
else:
    ext = '.c'

# Required for glibc < 2.17:
extra_link_args = ["-lrt"]

ext_modules = [Extension('gil_load.gil_load',
                         ['gil_load/gil_load' + ext],
                         extra_link_args=extra_link_args,
                         include_dirs=['gil_load']),
               Extension('gil_load.preload',
                         ['gil_load/preload.c'],
                         extra_link_args=['-ldl'])]

if USE_CYTHON:
    from Cython.Build import cythonize
    ext_modules = cythonize(ext_modules)
    
setup(
    name = 'gil_load',
    version=VERSION,
    description='Utility for measuring the fraction of time the GIL is held in a program',
    author='Chris Billington',
    author_email='chrisjbillington@gmail.com',
    url='https://github.com/chrisjbillington/gil_load',
    license="BSD",
    packages=['gil_load'],
    ext_modules = ext_modules
)

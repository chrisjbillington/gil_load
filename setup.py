import os
from setuptools import setup
from setuptools.extension import Extension
from Cython.Build import cythonize

VERSION = '0.4.2'

# Auto generate a __version__ package for the package to import
with open(os.path.join('gil_load', '__version__.py'), 'w') as f:
    f.write("__version__ = '%s'\n"%VERSION)

# Required for glibc < 2.17:
extra_link_args = ["-lrt"]

ext_modules = [
    Extension(
        'gil_load.gil_load',
        ['gil_load/gil_load.pyx'],
        extra_link_args=extra_link_args,
        include_dirs=['gil_load'],
    ),
    Extension('gil_load.preload', ['gil_load/preload.c'], extra_link_args=['-ldl']),
]

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

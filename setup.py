import os
from distutils.core import setup
from distutils.extension import Extension
from Cython.Build import cythonize


VERSION = '0.1.0'

# Auto generate a __version__ package for the package to import
with open(os.path.join('gil_load', '__version__.py'), 'w') as f:
    f.write("__version__ = '%s'\n"%VERSION)

ext_modules = [Extension('gil_load.gil_load', ["gil_load/gil_load.pyx"])]


setup(
    name = 'gil_load',
    version=VERSION,
    description='Utility for measuring the fraction of time the GIL is held in a program',
    author='Chris Billington',
    author_email='chrisjbillington@gmail.com',
    url='https://github.com/chrisjbillington/gil_load',
    license="BSD",
    packages=['gil_load'],
    ext_modules = cythonize(ext_modules)
)

import os
from setuptools import setup
from setuptools.extension import Extension

from distutils.version import LooseVersion

try:
    import cython
except ImportError:
    msg = ('cython required. Cython can be installed with:\n' +
           '   sudo pip install cython\n' +
           'or from your OS\'s package manager')
    raise ImportError(msg)

if LooseVersion(cython.__version__) < LooseVersion('0.22.0'):
    msg = ('cython >= 0.22 required. Cython can be upgraded with:\n' +
           '   sudo pip install --upgrade cython.\n' +
           'On some systems this will not take precendent over a ' +
           'version of cython that was installed from the OS\'s package manager. ' +
           'In these cases you should consider removing the version of cython ' +
           'that was installed by your OS\'s package manager.')
    raise ValueError(msg)

from Cython.Build import cythonize

VERSION = '0.3.1'

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

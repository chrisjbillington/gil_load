# gil_load

`gil_load` is a utility for measuring the fraction of time the CPython GIL
(Global interpreter lock) is held. It is for linux only, and has been tested
on Python 2.7, 3.5 and 3.6

  * [Installation](#installation)
  * [Introduction](#introduction)
  * [Usage](#usage)
  * [Notes](#notes)


## Installation

to install `gil_load`, run:

```
$ sudo pip3 install gil_load
```

or to install from source:

```
$ sudo python3 setup.py install
```

`gil_load` can also be installed with Python 2.

## Introduction

A lot of people complain about the Python GIL, saying that it prevents them
from utilising all cores on their expensive CPUs. In my experience this claim
is more often than not without merit.

## Example usage

```python
import numpy as np
import threading
import gil_load


x = np.random.randn(4096, 4096)
y = np.random.randn(4096, 4096)

def inplace_fft(a):
    a[:] = np.fft.fft2(a).real


gil_load.init()
gil_load.start()

thread1 = threading.Thread(target=inplace_fft, args=(x,))
thread2 = threading.Thread(target=inplace_fft, args=(y,))

thread1.start()
thread2.start()

thread1.join()
thread2.join()

gil_load.stop()

print(gil_load.get(N=4))

```

This prints:

```
(0.0, [0.0, 0.0, 0.0])
```

Which means that the mean fraction of the time the GIL was held, as well as
the 1 minute, 5 minute and 15 minute averages (not really relevant since the
code was running only for a few seconds) was zero to four digits. In fact, the
code that samples whether the GIL is held every 50ms probably never
encountered it being held in this code, because the numpy code was never
holding the GIL, so even though the code takes several seconds to run, the
only opportunity for the GIL to be detected as held is during the thread
starting and stopping.

So if your code looks like this, don't worry about the GIL. It's not your problem.

## Documentation

`test()` :

test that the code can in fact determine whether the GIL is held
for your Python interpreter. Raises `AssertionError` on failure, does nothing
on success.

`init()` :

Find the data structure for the GIL in memory so that we can monitor it later
to see how often it is held. This function must be called before any other
threads are started, and before calling `start()` to start monitoring the GIL.
Note: this function calls `PyEval_InitThreads()`, so if your application was
single-threaded, it will take a slight performance hit from this, as the
Python interpreter is not quite as efficient in multithreaded mode as it is in
single-threaded mode, even if there is only one thread running.

`start(av_sample_interval=0.05, output_interval=5, output=None, reset_counts=False)`:

Start monitoring the GIL. Monitoring works by spawning a thread (running only
C code so as not to require the GIL itself), and checking whether the GIL is
held at random times. The interval between sampling times is exponentially
distributed with mean set by `av_sample_interval`. Over time, statistics are
accumulated for what proportion of the time the GIL was held. Overall load, as
well as 1 minute, 5 minute, and 15 minute exponential moving averages are
computed. If `output` is not None, then it should be an open file or a
filename (if the latter it will be opened in append mode), and the average GIL
demand will be written to this file approximately every `output_interval`
seconds. If `reset_counts` is `True`, then the accumulated statics from
previous calls to `start()` and then `stop()` wil lbe cleared. If you do not
clear the counts, then you can repeatedly sample the GIL usage of just a small
segment of your code by wrapping it with calls to `start()` and `stop()`. Due
to the exponential distribution of sampling intervals, this will accumulate
accurate statistics even if the time the function takes to run is less than
`av_sample_interval`.

`stop()`:

Stop monitoring the GIL. Accumulated statistics can then be accessed with `get()`

`get(N=2)`:

Returns the average GIL load, and the 1m, 5m and 15m exponential averages,
rounded to N digits, either from the currently running GIL monitoring, or from
the previous monitoring if `stop()` has been called.
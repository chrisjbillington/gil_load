# gil_load

`gil_load` is a utility for measuring the fraction of time the CPython GIL (Global
interpreter lock) is held or waited for. It is for linux only, and has been tested on
Python 2.7, 3.5, 3.6 and 3.7.

  * [Installation](#installation)
  * [Introduction](#introduction)
  * [Usage](#usage)
  * [Functions](#functions)


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

A lot of people complain about the Python GIL, saying that it prevents them from
utilising all cores on their expensive CPUs. In my experience this claim is more often
than not without merit. This module was motivated by the desire to demonstrate that
typical parallel code in Python, such as numerical calculations using `numpy`, does not
suffer from high GIL contention and is truly parallel and utilising all cores. However,
in other circumstances where the GIL *is* contested, this module can tell you how
contested it is, which threads are hogging the GIL and which are starved.

## Usage

In your code, call `gil_load.init()` before starting any threads. When you wish to begin
monitoring, call `gil_load.start()`. When you want to stop monitoring, call
`gil_load.stop()`. You can thus monitor a small segment of code, which is useful if your
program is idle most of the time and you only need to profile when something is actually
happening. Multiple calls to `gil_load.start()` and `gil_load.stop()` can accumulate
statistics over time. See the arguments of `gil_load.start()` for more details.

You may either pass arguments to `gil_load.start()` configuring it to output monitoring
results periodically to a file (such as `sys.stdout`), or you may manually collect
statistics by calling `gil_load.get()`.

For example, here is some code that runs four threads doing fast Fourier transforms with
`numpy`:


```python
import numpy as np
import threading
import gil_load

N_THREADS = 4
NPTS = 4096

gil_load.init()

def do_some_work():
    for i in range(2):
        x = np.random.randn(NPTS, NPTS)
        x[:] = np.fft.fft2(x).real

gil_load.start()

threads = []
for i in range(N_THREADS):
    thread = threading.Thread(target=do_some_work, daemon=True)
    threads.append(thread)
    thread.start()


for thread in threads:
    thread.join()

gil_load.stop()

stats = gil_load.get()
print(gil_load.format(stats))

```

To run the script, one must use `gil_load` to launch the script like so:

```
python -m gil_load example.py
```

This runs (on my computer) for about 5 seconds, and prints:

```
held: 0.004 (0.004, 0.004, 0.004)
wait: 0.0 (0.0, 0.0, 0.0)
  <140125322438464>
    held: 0.0 (0.0, 0.0, 0.0)
    wait: 0.0 (0.0, 0.0, 0.0)
  <140124982937344>
    held: 0.0 (0.0, 0.0, 0.0)
    wait: 0.0 (0.0, 0.0, 0.0)
  <140124974544640>
    held: 0.0 (0.0, 0.0, 0.0)
    wait: 0.0 (0.0, 0.0, 0.0)
  <140124966151936>
    held: 0.001 (0.001, 0.001, 0.001)
    wait: 0.0 (0.0, 0.0, 0.0)
  <140124957759232>
    held: 0.003 (0.003, 0.003, 0.003)
    wait: 0.0 (0.0, 0.0, 0.0)
```

This output is the total and per-thread averages for the fraction of the time the GIL
was held, as well as the 1m, 5m and 15m exponential moving averages thereof. This shows
that for this script, the GIL was held 0.4 % of the time, and contested ≈0 % of the
time.

## How it works

In order to minimise the overhead of profiling, `gil_load` is a *sampling profiler*. It
waits for random amounts of time and then samples the situation: which thread is holding
the GIL, if any, and which threads are waiting for the GIL? This builds up statistics
over time, but does mean that answers are only accurate if there have been many samples.
The default mean sampling interval is 5ms, and `gil_load` samples at intervals randomly
drawn from an exponential distribution with this mean in order to avoid systematic
errors that perfectly regular timing might introduce. Thus, one can only trust profiling
results if the duration of profiling is large compared to the mean sample time.

`gil_load` uses `LD_PRELOAD` to override some system calls so that it can detect when a
thread acquires or releases the GIL, this is why the script must be run with `python -m
gil_load my_script.py` so that `gil_load` can set `LD_PRELOAD` before running your
script.

## Command line and function documentation

To run with monitoring enabled, run your script with:

```
python -m gil_load [args] my_script.py
```

Any arguments will be passed to the Python interpreter running your script.


`gil_load.init()` :

Find the data structure for the GIL in memory so that we can monitor it later to see how
often it is held. This function must be called before any other threads are started, and
before calling `gil_load.start()`. Note: this function calls `PyEval_InitThreads()`, so
if your application was single-threaded, it will take a slight performance hit from
this, as the Python interpreter is not quite as efficient in multithreaded mode as it is
in single-threaded mode, even if there is only one thread running.

`gil_load.test()` :

Test that the code can in fact determine whether the GIL is held for your Python
interpreter. Raises `AssertionError` on failure, returns True on success. Must be called
after `gil_load.init()`.


`gil_load.start(av_sample_interval=0.005, output_interval=5, output=None, reset_counts=False)`:

Start monitoring the GIL. Monitoring runs in a separate thread (running only C code so
as not to require the GIL itself), and checking whether the GIL is held at random times.
The interval between sampling times is exponentially distributed with mean set by
`av_sample_interval`. Over time, statistics are accumulated for what proportion of the
time the GIL was held. Overall load, as well as 1 minute, 5 minute, and 15 minute
exponential moving averages are computed. If `output` is not None, then it should be an
open file (e.g sys.stdout), a filename  (which will be opened in append mode), or a file
descriptor. The average GIL load will be written to this file approximately every
`output_interval` seconds. If `reset_counts` is `True`, then the accumulated statics
from previous calls to `start()` and then `stop()` wil lbe cleared. If you do not clear
the counts, then you can repeatedly sample the GIL usage of just a small segment of your
code by wrapping it with calls to `start()` and `stop()`. Due to the exponential
distribution of sampling intervals, this will accumulate accurate statistics even if the
time the function takes to run is less than `av_sample_interval`. However, each call to
start() does involve the starting of a new thread, the overhead of which may make
profiling very short segments of code inaccurate.

`gil_load.stop()`:

Stop monitoring the GIL. Accumulated statistics can then be accessed with
`gil_load.get()`

`gil_load.get()`:

Returns a 2-tuple:
```python
    (total_stats, thread_stats)
```
Where `total_stats` is a dict:
```python
    {
        'held': held,
        'held_1m': held_1m,
        'held_5m': held_5m,
        'held_15m': held_15m,
        'wait': wait,
        'wait_1m': wait_1m,
        'wait_5m': wait_5m,
        'wait_15m': wait_15m,
    }
```
where `held` is the total fraction of the time that the GIL has been held, `wait` is the
total fraction of the time the GIL was being waited on, and the `_1m`, `_5m` and `_15m`
suffixed entries are the 1, 5, and 15 minute exponential moving averages of the held and
wait fractions.

`thread_stats` is a dict of the form:
```python
    {thread_id: thread_stats}
```
where `thread_stats` is a dictionary with the same information as `total_stats`, but
pertaining only to the given thread.

`gil_load.format(stats, N=3)`:

Format statistics as returned by `gil_load.get()` for printing, with all numbers rounded
    to `N` digits. Format is:
```python
    held: <average> (1m, 5m, 15m)
    wait: <average> (1m, 5m, 15m)
      <thread_id>
        held: <average> (1m, 5m, 15m)
        wait: <average> (1m, 5m, 15m)
      ...
```

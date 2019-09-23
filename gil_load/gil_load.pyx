# cython: language_level=3
from __future__ import absolute_import
import sys
import os
import threading
import ctypes
cimport cython
from ctypes import cdll
from cpython.version cimport PY_MAJOR_VERSION
from cpython.pystate cimport PyThreadState_Get, PyThreadState
from libc.errno cimport ETIMEDOUT
from libc.stdlib cimport malloc, free
from libc.stdio cimport printf, fprintf, FILE, fdopen, fclose, fflush
from libc.string cimport memcpy
from libc.math cimport log
from libc.time cimport time, time_t, localtime, strftime, tm
from posix.time cimport timespec, clockid_t, clock_gettime, CLOCK_MONOTONIC
from posix.unistd cimport usleep, useconds_t

cdef extern from "pthread.h" nogil:

    ctypedef long pthread_t

    ctypedef struct pthread_cond_t:
        pass
    ctypedef struct pthread_mutex_t:
        pass
    ctypedef struct pthread_barrier_t:
        pass
    ctypedef struct pthread_condattr_t:
        pass
    ctypedef struct pthread_mutexattr_t:
        pass
    ctypedef struct pthread_barrierattr_t:
        pass

    pthread_t pthread_self()
    int pthread_cond_init(pthread_cond_t *, pthread_condattr_t *)
    int pthread_cond_signal(pthread_cond_t *)
    int pthread_cond_timedwait(pthread_cond_t *, pthread_mutex_t *, timespec *)
    int pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *)

    int pthread_condattr_init(pthread_condattr_t *)
    int pthread_condattr_setclock(pthread_condattr_t *, clockid_t)

    int pthread_mutex_init(pthread_mutex_t *, pthread_mutexattr_t *)
    int pthread_mutex_lock(pthread_mutex_t *)
    int pthread_mutex_unlock(pthread_mutex_t *)

    int pthread_barrier_init(pthread_barrier_t *, pthread_barrierattr_t *, unsigned int count)
    int pthread_barrier_wait(pthread_barrier_t *)


cdef extern from "stdlib.h":
    double drand48() nogil
    int srand48(int) nogil

cdef extern from "preload.h":
    int set_initialised() nogil
    pthread_t * get_threads_arr() nogil
    int * get_threads_waiting_arr() nogil
    int get_most_recently_acquired() nogil
    int begin_sample() nogil
    void end_sample() nogil


DEF MAX_THREADS_TRACKED = 1024

cdef int n_threads_tracked = 0

# The pointer to the GIL. Different variables depending on Python 2 or 3:

# In Python 3 it's a static int called gil_locked in ceval_gil.h that is
# either 1 or 0 depending on whether the GIL is held.
cdef int * gil_locked = NULL

# In Python 2 it's a static PyThreadState pointer called
# _PyThreadState_Current in pystate.c that points to the current ThreadState
# or is NULL depending on whether the GIL is held.
cdef PyThreadState * * _PyThreadState_Current = NULL


# Number of checks of the GIL and number of times it was held:
cdef long check_count = 0
cdef long held_count = 0
cdef long wait_count = 0

# The fraction of the time the GIL has been held:
cdef double gil_held = 0

# 1m, 5m, 15m averages:
cdef double gil_held_1m = 0
cdef double gil_held_5m = 0
cdef double gil_held_15m = 0

# The fraction of the time the GIL was being waited on:
cdef double gil_wait = 0

# 1m, 5m, 15m averages:
cdef double gil_wait_1m = 0
cdef double gil_wait_5m = 0
cdef double gil_wait_15m = 0

# Number of times threads were holding/waiting for the GIL upon being checked:
cdef long thread_held_count[MAX_THREADS_TRACKED] 
cdef long thread_wait_count[MAX_THREADS_TRACKED] 

# The fraction of the time each thread was holding/waiting for the GIL:
cdef double thread_held_frac[MAX_THREADS_TRACKED] 
cdef double thread_wait_frac[MAX_THREADS_TRACKED] 

# 1m, 5m, 15m averages:
cdef double thread_held_frac_1m[MAX_THREADS_TRACKED] 
cdef double thread_held_frac_5m[MAX_THREADS_TRACKED] 
cdef double thread_held_frac_15m[MAX_THREADS_TRACKED] 
cdef double thread_wait_frac_1m[MAX_THREADS_TRACKED] 
cdef double thread_wait_frac_5m[MAX_THREADS_TRACKED] 
cdef double thread_wait_frac_15m[MAX_THREADS_TRACKED] 

cdef int i
for i in range(MAX_THREADS_TRACKED):
    thread_held_count[i] = 0
    thread_held_frac[i] = 0
    thread_held_frac_1m[i] = 0
    thread_held_frac_5m[i] = 0
    thread_held_frac_15m[i] = 0
    thread_wait_count[i] = 0
    thread_wait_frac[i] = 0
    thread_wait_frac_1m[i] = 0
    thread_wait_frac_5m[i] = 0
    thread_wait_frac_15m[i] = 0

# The thread that is monitoring the GIL
monitoring_thread = None

# A lock to make the functions in this module threadsafe
lock = threading.Lock()

cdef int PY2 = PY_MAJOR_VERSION == 2
cdef int PY3 = PY_MAJOR_VERSION == 3
if not (PY2 or PY3):
    raise ImportError("Only compatible with Python 2 or 3")


# Flags to tell the monitoring thread to start or stop, and an associated condition and
# mutex to ensure we can wake it when sleeping and tell it to quit in a race-free way.
cdef int starting = 0
cdef int stopping = 0
cdef pthread_cond_t cond
cdef pthread_mutex_t mutex

# The arrays that store the threads and whether each is waiting for the GIL:
cdef pthread_t * threads = get_threads_arr()
cdef int * threads_waiting = get_threads_waiting_arr()

cdef pthread_t monitoring_thread_ident = -1

cdef int get_gil_held() nogil:
    """Return whether the GIL is held by some thread"""
    if PY3:
        return gil_locked[0]
    else:
        return _PyThreadState_Current[0] != NULL


cdef void mktimestamp(char* s) nogil:
    """String timestamp, for logging"""
    cdef time_t timer
    cdef tm tm_info
    time(&timer);
    tm_info = localtime(&timer)[0]
    strftime(s, 26, "[%Y-%m-%d %H:%M:%S]", &tm_info)


cdef timespec abstimeout(double seconds) nogil:
    """Return the absolute time for a given number of seconds from now, using
    CLOCK MONOTONIC"""
    cdef timespec timeout
    cdef int BILLION = 1000000000

    clock_gettime(CLOCK_MONOTONIC, &timeout)

    timeout.tv_sec += <time_t> seconds
    timeout.tv_nsec += <long> ((seconds % 1) * BILLION)

    if timeout.tv_nsec > BILLION:
        timeout.tv_sec += 1
        timeout.tv_nsec -= BILLION

    return timeout


def _get_data_segments():
    """Get all possible data segments of process memory, in which the variable
    for the GIL might be located"""
    with open('/proc/{}/maps'.format(os.getpid())) as f:
        # Dymanically linked?
        for line in f:
            if line.split()[1] == 'rw-p':
                if 'gil_load' in line or '[heap]' in line or '[stack]' in line:
                    continue
                start, stop = [int(s, 16) for s in line.split()[0].split('-')]
                yield start, stop-start

def _find_gil():
    """diff the data segment of memory against itself with the GIL held vs not
    held to find the data describing whether the GIL is held. This is
    different in Python 2 vs Python 3, so we find a different variable in each
    case, gil_locked for Python 3 and _PyThreadState_Current for Python 2, and
    we set a global variable equal to a pointer to one of those."""
    cdef long start, size
    cdef char *data_segment
    cdef char *data_segment_nogil

    cdef int rc = 0

    ctypes.pythonapi.PyEval_InitThreads()

    cdef PyThreadState * threadstate = PyThreadState_Get()

    cdef int i

    for start, size in _get_data_segments():
        data_segment = <char *> start
        data_segment_nogil = <char *> malloc(size)
        with nogil:
            memcpy(data_segment_nogil, data_segment, size)

        if PY3:
            rc = _find_gil_py3(data_segment, data_segment_nogil, size)
        else:
            rc = _find_gil_py2(data_segment, data_segment_nogil, size)

        free(data_segment_nogil)

        if rc == 0:
            return

    raise RuntimeError("Failed to find pointer to GIL variable")


cdef int _find_gil_py3(char * data_segment, char * data_segment_nogil, long size):
    """Compare data_segment and data_segment_nogil to find the variable
    gil_locked. It will be the memory location that changes from int 1 to int
    0 when the GIL is held vs not held. Set our global variable gil_locked to
    be a pointer to it and return 0, or return -1 if it was not found"""
    global gil_locked

    # Don't read past the end of the memory segment:
    cdef long stop = size - sizeof(int) - 1

    cdef long i
    for i in range(stop):
        if (<int *> &data_segment[i])[0] == 1 and (<int *> &data_segment_nogil[i])[0] == 0:
            gil_locked = <int *> &data_segment[i]
            return 0
    return -1


cdef int _find_gil_py2(char * data_segment, char * data_segment_nogil, long size):
    """Compare data_segment and data_segment_nogil to find the variable
    _PyThreadState_Current. It will be the memory location that changes from a
    pointer to the current ThreadState to a NULL pointer when the GIL is held
    vs not held. Set our global variable _PyThreadState_Current to be a
    pointer to it and return 0, or return -1 if it was not found"""
    global _PyThreadState_Current

    # Don't read past the end of the memory segment:
    cdef long stop = size - sizeof(PyThreadState *) - 1

    cdef PyThreadState * threadstate = PyThreadState_Get()

    cdef long i
    for i in range(stop):
        if ((<PyThreadState * *> &data_segment[i])[0] == threadstate and 
            (<PyThreadState * *> &data_segment_nogil[i])[0] == NULL):
            _PyThreadState_Current = <PyThreadState * *> &data_segment[i]
            return 0
    return -1


cdef void wait_until_start() nogil:
    global starting
    while not starting:
        pthread_cond_wait(&cond, &mutex)
    starting = 0
    pthread_cond_signal(&cond)


# Globals used in _run that can change between subsequent calls to start():
cdef FILE * _f = NULL
cdef double _av_sample_interval
cdef double _output_interval
cdef int _close_file_on_stop

@cython.cdivision(True)
def _run():

    global monitoring_thread_ident
    global n_threads_tracked
    global stopping
    global held_count
    global wait_count
    global check_count
    global gil_held
    global gil_held_1m
    global gil_held_5m
    global gil_held_15m
    global gil_wait
    global gil_wait_1m
    global gil_wait_5m
    global gil_wait_15m

    # These ones can change from one call to start() to the next:
    cdef FILE * f = _f
    cdef double av_sample_interval = _av_sample_interval
    cdef double output_interval = _output_interval

    cdef int i
    cdef int held
    cdef int wait
    cdef int thread_held
    cdef int thread_wait
    cdef int most_recently_acquired
    cdef long output_count_interval = max(<long> (output_interval / av_sample_interval), 1)

    cdef long next_output_count = output_count_interval

    cdef double k_1 = av_sample_interval/60.0
    cdef double k_5 = av_sample_interval/(5*60.0)
    cdef double k_15 = av_sample_interval/(15*60.0)

    cdef char timestamp[26]

    cdef timespec timeout

    monitoring_thread_ident = pthread_self()

    srand48(time(NULL))

    with nogil:
        pthread_mutex_lock(&mutex)
        while True:
            wait_until_start()
            # Update the output file, sample and output intervals which may have been
            # set as globals:
            f = _f
            av_sample_interval = _av_sample_interval
            output_interval = _output_interval
            while not stopping:
                timeout = abstimeout(-av_sample_interval * log(drand48()))
                if pthread_cond_timedwait(&cond, &mutex, &timeout) == ETIMEDOUT:
                    check_count += 1
                    held = get_gil_held()
                    if held:
                        most_recently_acquired = get_most_recently_acquired()
                    else:
                        most_recently_acquired = -1

                    n_threads_tracked = begin_sample()
                    wait = 0
                    for i in range(n_threads_tracked):
                        thread_wait = threads_waiting[i]
                        if thread_wait:
                            wait = 1
                        thread_held = (i == most_recently_acquired)
                        thread_wait_count[i] += thread_wait
                        thread_held_count[i] += thread_held
                        thread_wait_frac[i] = <double> thread_wait_count[i] / <double> check_count
                        thread_held_frac[i] = <double> thread_held_count[i] / <double> check_count
                        if check_count * av_sample_interval > 60:
                            thread_wait_frac_1m[i] = k_1 * thread_wait + (1 - k_1) *  thread_wait_frac_1m[i]
                            thread_held_frac_1m[i] = k_1 * thread_held + (1 - k_1) *  thread_held_frac_1m[i]
                        else:
                             thread_wait_frac_1m[i] =  thread_wait_frac[i]
                             thread_held_frac_1m[i] =  thread_held_frac[i]
                        if check_count * av_sample_interval > 5 * 60:
                            thread_wait_frac_5m[i] = k_5 * thread_wait + (1 - k_5) * thread_wait_frac_5m[i]
                            thread_held_frac_5m[i] = k_5 * thread_held + (1 - k_5) * thread_held_frac_5m[i]
                        else:
                            thread_wait_frac_5m[i] =  thread_wait_frac[i]
                            thread_held_frac_5m[i] =  thread_held_frac[i]
                        if check_count * av_sample_interval > 15 * 60:
                            thread_wait_frac_15m[i] = k_15 * thread_wait + (1 - k_15) * thread_wait_frac_15m[i]
                            thread_held_frac_15m[i] = k_15 * thread_held + (1 - k_15) * thread_held_frac_15m[i]
                        else:
                           thread_wait_frac_15m[i] =  thread_wait_frac[i]
                           thread_held_frac_15m[i] =  thread_held_frac[i]
                    end_sample()

                    wait_count += wait
                    held_count += held

                    gil_wait = <double> wait_count / <double> check_count
                    gil_held = <double> held_count / <double> check_count
                    if check_count * av_sample_interval > 60:
                        gil_wait_1m = k_1 * wait + (1 - k_1) * gil_wait_1m
                        gil_held_1m = k_1 * held + (1 - k_1) * gil_held_1m
                    else:
                        gil_wait_1m = gil_wait
                        gil_held_1m = gil_held
                    if check_count * av_sample_interval > 5 * 60:
                        gil_wait_5m = k_5 * wait + (1 - k_5) * gil_wait_5m
                        gil_held_5m = k_5 * held + (1 - k_5) * gil_held_5m
                    else:
                        gil_wait_5m = gil_wait
                        gil_held_5m = gil_held
                    if check_count * av_sample_interval > 15 * 60:
                        gil_wait_15m = k_15 * wait + (1 - k_15) * gil_wait_15m
                        gil_held_15m = k_15 * held + (1 - k_15) * gil_held_15m
                    else:
                        gil_wait_15m = gil_wait
                        gil_held_15m = gil_held


                    if check_count == next_output_count:
                        next_output_count += output_count_interval
                        if f != NULL:
                            mktimestamp(timestamp)
                            fprintf(f, "%s\n", timestamp)
                            fprintf(
                                f,
                                "  held: %.3f (%.3f, %.3f, %.3f)\n",
                                gil_held,
                                gil_held_1m,
                                gil_held_5m,
                                gil_held_15m,
                            )
                            fprintf(
                                f,
                                "  wait: %.3f (%.3f, %.3f, %.3f)\n",
                                gil_wait,
                                gil_wait_1m,
                                gil_wait_5m,
                                gil_wait_15m,
                            )

                            for i in range(n_threads_tracked):
                                # Per thread stats. Don't include the monitoring
                                # thread itself in stats:
                                if threads[i] != monitoring_thread_ident:
                                    fprintf(f, "    <%ld>\n", threads[i])
                                    fprintf(
                                        f,
                                        "      held: %.3f (%.3f, %.3f, %.3f)\n",
                                        thread_held_frac[i],
                                        thread_held_frac_1m[i],
                                        thread_held_frac_5m[i],
                                        thread_held_frac_15m[i],
                                    )
                                    fprintf(
                                        f,
                                        "      wait: %.3f (%.3f, %.3f, %.3f)\n",
                                        thread_wait_frac[i],
                                        thread_wait_frac_1m[i],
                                        thread_wait_frac_5m[i],
                                        thread_wait_frac_15m[i],
                                    )

                            fprintf(f, "\n")
                            fflush(f)
            stopping = 0
            pthread_cond_signal(&cond)
            # pthread_mutex_unlock(&mutex)


def _checkinit():
    if (PY3 and gil_locked == NULL) or (PY2 and _PyThreadState_Current == NULL):
        raise RuntimeError("Must call gil_load.init() first")


def init():
    """Find the data structure for the GIL in memory so that we can monitor it later to
    see how often it is held. This function must be called before any other threads are
    started, and before calling `gil_load.start()`. Note: this function calls
    `PyEval_InitThreads()`, so if your application was single-threaded, it will take a
    slight performance hit from this, as the Python interpreter is not quite as
    efficient in multithreaded mode as it is in single-threaded mode, even if there is
    only one thread running."""

    if threading.active_count() > 1:
        raise RuntimeError("gil_load.init() must be called prior to other "
                           "threads being started")

    with lock:
        # Get a pointer to the GIL and store it as a global variable:
        _find_gil()

    # Set up condition and mutex for telling the monitoring thread when to stop:
    cdef pthread_condattr_t condattr
    pthread_condattr_init(&condattr)
    pthread_condattr_setclock(&condattr, CLOCK_MONOTONIC)
    pthread_cond_init(&cond, &condattr)
    pthread_mutex_init(&mutex, NULL)

    # printf('gil held\n')
    # with nogil:
    #     printf('gil released\n')
    # printf('gil reacquired\n')

    cdef int rc = set_initialised()
    if rc != 0:
        msg = ("gil_load preload library not loaded prior to starting Python. " + 
              "gil_load requires a library to be preloaded with LD_PRELOAD. " +
              "run your script in the following way to preload the required library:\n\n" +
              "python -m gil_load my_script.py")
        raise RuntimeError(msg)

    # printf('gil held\n')
    # with nogil:
    #     printf('gil released\n')
    # printf('gil reacquired\n')

def start(av_sample_interval=0.005, output_interval=5, output=None, reset_counts=False):
    """Start monitoring the GIL. Monitoring runs in a separate thread (running only C
    code so as not to require the GIL itself), and checking whether the GIL is held at
    random times. The interval between sampling times is exponentially distributed with
    mean set by `av_sample_interval`. Over time, statistics are accumulated for what
    proportion of the time the GIL was held. Overall load, as well as 1 minute, 5
    minute, and 15 minute exponential moving averages are computed. If `output` is not
    None, then it should be an open file (such as sys.stdout) or a filename (if the
    latter it will be opened in append mode), and the average GIL load will be written
    to this file approximately every `output_interval` seconds. If `reset_counts` is
    `True`, then the accumulated statics from previous calls to `start()` and then
    `stop()` wil lbe cleared. If you do not clear the counts, then you can repeatedly
    sample the GIL usage of just a small segment of your code by wrapping it with calls
    to `start()` and `stop()`. Due to the exponential distribution of sampling
    intervals, this will accumulate accurate statistics even if the time the function
    takes to run is less than `av_sample_interval`. However, each call to start() does
    involve the starting of a new thread, the overhead of which may make profiling very
    short segments of code inaccurate."""

    _checkinit()

    global check_count
    global held_count
    global gil_held
    global gil_held_1m
    global gil_held_5m
    global gil_held_15m
    global monitoring_thread
    global starting
    global _f
    global _av_sample_interval
    global _output_interval
    global _close_file_on_stop

    cdef int i
    if reset_counts:
        check_count = 0
        held_count = 0
        gil_held = gil_held_1m = gil_held_5m = gil_held_15m = 0
        for i in range(MAX_THREADS_TRACKED):
            thread_wait_count[i] = 0
            thread_wait_frac[i] = 0
            thread_wait_frac_1m[i] = 0
            thread_wait_frac_5m[i] = 0
            thread_wait_frac_15m[i] = 0

    if isinstance(output, str):
        output = open(output, 'a')
        _close_file_on_stop = 1
    else:
        _close_file_on_stop = 0

    if output is not None:
        _f = fdopen(output.fileno(), 'a')
    else:
        _f = NULL

    _av_sample_interval = av_sample_interval
    _output_interval = output_interval

    with lock:
        if monitoring_thread is None:
            monitoring_thread = threading.Thread(target=_run)
            monitoring_thread.daemon = True
            monitoring_thread.start()

        # Signal to the thread to start monitoring:
        with nogil:
            pthread_mutex_lock(&mutex)
            starting = 1
            pthread_cond_signal(&cond)
            pthread_mutex_unlock(&mutex)



def stop():
    """Stop monitoring the GIL. Accumulated statistics can then be accessed with
    `gil_load.get()`."""
    global monitoring_thread
    global stopping
    with lock:
        # Tell the monitoring thread to stop and then wait for it to confirm:
        pthread_mutex_lock(&mutex)
        stopping = 1
        pthread_cond_signal(&cond)
        while stopping:
            pthread_cond_wait(&cond, &mutex)
        pthread_mutex_unlock(&mutex)

    if _close_file_on_stop:
        fclose(_f)

def get():
    """Returns a 2-tuple:

        (total_stats, thread_stats)

    total_stats is a dict:

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

    where `held` is the total fraction of the time that the GIL has been held, `wait` is
    the total fraction of the time the GIL was being waited on, and the `_1m`, `_5m` and
    `_15m` suffixed entries are the 1, 5, and 15 minute exponential moving averages of
    the held and wait fractions.

    thread_stats is a dict of the form:

        {thread_id: thread_stats}

    where thread_stats is a dictionary with the same information as total_stats, but
    pertaining only to the given thread."""
    _checkinit()
    cdef int i
    thread_stats = {}
    n_threads_tracked = begin_sample()
    for i in range(n_threads_tracked):
        if threads[i] == monitoring_thread_ident:
            # Don't return stats about the monitoring thread since it never holds the
            # GIL
            continue

        thread_stats[threads[i]] = {
            'held': thread_held_frac[i],
            'held_1m': thread_held_frac_1m[i],
            'held_5m': thread_held_frac_5m[i],
            'held_15m': thread_held_frac_15m[i],
            'wait': thread_wait_frac[i],
            'wait_1m': thread_wait_frac_1m[i],
            'wait_5m': thread_wait_frac_5m[i],
            'wait_15m': thread_wait_frac_15m[i],
        }

    end_sample()

    total_stats = {
        'held': gil_held,
        'held_1m': gil_held_1m,
        'held_5m': gil_held_5m,
        'held_15m': gil_held_15m,
        'wait': gil_wait,
        'wait_1m': gil_wait_1m,
        'wait_5m': gil_wait_5m,
        'wait_15m': gil_wait_15m,
    }

    return total_stats, thread_stats


def format(stats, N=3):
    """Format statistics as returned by get() for printing, with all numbers rounded to
    N digits. Format is:

    held: <average> (1m, 5m, 15m)
    wait: <average> (1m, 5m, 15m)
      <thread_id>
        held: <average> (1m, 5m, 15m)
        wait: <average> (1m, 5m, 15m)
      ...
    """
    total_stats, thread_stats = stats
    lines = []
    total_stats = {k: round(v, N) for k, v in total_stats.items()}
    lines.append(
        "held: {held} ({held_1m}, {held_5m}, {held_15m})".format(**total_stats)
    )
    lines.append(
        "wait: {wait} ({wait_1m}, {wait_5m}, {wait_15m})".format(**total_stats)
    )
    for thread_id, stats in thread_stats.items():
        lines.append('  <{}>'.format(thread_id))
        stats = {k: round(v, N) for k, v in stats.items()}
        lines.append(
            "    held: {held} ({held_1m}, {held_5m}, {held_15m})".format(**stats)
        )
        lines.append(
            "    wait: {wait} ({wait_1m}, {wait_5m}, {wait_15m})".format(**stats)
        )
    return '\n'.join(lines)


def gil_usleep(useconds_t us_nogil, useconds_t us_withgil):
    """usleep with the GIL not held, and then held, for testing purposes"""
    with nogil:
        usleep(us_nogil)
    usleep(us_withgil)


def test():
    """Test that the code can in fact determine whether the GIL is held for your Python
    interpreter. Raises `AssertionError` on failure, returns True on success. Must be
    called after `gil_load.init()`.."""

    cdef int result

    _checkinit()

    if threading.active_count() > 1:
        raise RuntimeError("Test only valid if no other threads running")
    
    assert get_gil_held() == 1, "gil_held() returned 0 when we were holding the GIL"

    with nogil:
         result = get_gil_held()
    assert result == 0, "gil_held() returned 1 when we were not holding the GIL"
    
    return True

import sys
import os
import threading
import ctypes
cimport cython
from libc.errno cimport ETIMEDOUT
from libc.stdlib cimport malloc, free
from libc.stdio cimport printf, fprintf, FILE, fdopen, fflush
from libc.string cimport memcpy
from libc.math cimport log
from libc.time cimport time, time_t, localtime, strftime, tm
from posix.time cimport timespec, clockid_t, clock_gettime, CLOCK_MONOTONIC

cdef extern from "pthread.h" nogil:

    ctypedef struct pthread_cond_t:
        pass
    ctypedef struct pthread_mutex_t:
        pass
    ctypedef struct pthread_condattr_t:
        pass
    ctypedef struct pthread_mutexattr_t:
        pass

    int pthread_cond_init(pthread_cond_t *, pthread_condattr_t *)
    int pthread_cond_signal(pthread_cond_t *)
    int pthread_cond_timedwait(pthread_cond_t *, pthread_mutex_t *, timespec *)

    int pthread_condattr_init(pthread_condattr_t *)
    int pthread_condattr_setclock(pthread_condattr_t *, clockid_t)

    int pthread_mutex_init(pthread_mutex_t *, pthread_mutexattr_t *)
    int pthread_mutex_lock(pthread_mutex_t *)
    int pthread_mutex_unlock(pthread_mutex_t *)


cdef extern from "stdlib.h":
    double drand48() nogil
    int srand48(int) nogil


# The pointer to the GIL. It's a static int called gil_locked in
# ceval_gil.h that is either 1 or 0 depending on whether the GIL is held.
cdef int * gil_locked = NULL

# The fraction of the time the GIL has been held:
cdef double gil_load = 0

# 1m, 5m, 15m averages:
cdef double gil_load_1m = 0
cdef double gil_load_5m = 0
cdef double gil_load_15m = 0

# The thread that is monitoring the GIL
monitoring_thread = None

# A lock to make the functions in this module threadsafe
lock = threading.Lock()


cdef int LITTLE_ENDIAN = sys.byteorder == 'little'


# A flag to tell the monitoring thread to stop, and an associated condition
# and mutex to ensure we can wake it when sleeping and tell it to quit in a
# race-free way.
cdef int stopping = 0
cdef pthread_cond_t cond
cdef pthread_mutex_t mutex


cdef int gil_held() nogil:
    """Return whether the GIL is held by some thread"""
    return gil_locked[0]


cdef void mktimestamp(char* s) nogil:
    """String timestamp, for logging"""
    cdef time_t timer
    cdef tm tm_info
    time(&timer);
    tm_info = localtime(&timer)[0]
    strftime(s, 26, "[%Y-%m-%d %H:%M:%S]", &tm_info)


cdef int sleep(double seconds) nogil:
    """Sleep for a time in seconds or return immediately if seconds <= 0.
   Other threads can interrupt the sleep by acquiring the mutex, setting
   stopping = 1 and then calling pthread_cond_signal(cond). The caller of this
   function must have acquired the mutex. Returns 1 if sleep was interrupted,
   and zero otherwise."""
    cdef timespec abstimeout
    cdef int BILLION = 1000000000

    clock_gettime(CLOCK_MONOTONIC, &abstimeout)
    abstimeout.tv_sec += <time_t>seconds
    abstimeout.tv_nsec += <long>((seconds % 1) * BILLION)
    if abstimeout.tv_nsec > BILLION:
        abstimeout.tv_sec += 1
        abstimeout.tv_nsec -= BILLION

    while not stopping:
        if pthread_cond_timedwait(&cond, &mutex, &abstimeout) == ETIMEDOUT:
            return 0
    return 1


def _get_data_segment():
    """Get the data segment of process memory, in which gil_locked is
    located"""
    with open('/proc/{}/maps'.format(os.getpid())) as f:
        # Dymanically linked?
        for line in f:
            if 'libpython' in line and 'rw-p' in line:
                start, stop = [int(s, 16) for s in line.split()[0].split('-')]
                return start, stop-start
        # Statically linked?
        f.seek(0)
        for line in f:
            if sys.executable in line and 'rw-p' in line:
                start, stop = [int(s, 16) for s in line.split()[0].split('-')]
                return start, stop-start
        raise RuntimeError("Can't find data segment")


cdef int * get_gil_pointer() except NULL:
    """diff the data segment of memory against itself with the GIL held vs not
    held. The memory location that changes is the location of the gil_locked
    variable. Return a pointer to it"""
    cdef long start
    cdef long size
    start, size = _get_data_segment()
    cdef char *data_segment = <char *>start
    cdef char *data_segment_nogil = <char *>malloc(size)
    cdef long i

    if threading.active_count() > 1:
        raise RuntimeError("gil_load.init() must be called prior to other "
                           "threads being started")

    ctypes.pythonapi.PyEval_InitThreads()

    with nogil:
        memcpy(data_segment_nogil, data_segment, size)
    for i in range(size):
        if data_segment[i] != data_segment_nogil[i]:
            free(data_segment_nogil)
            # We've found the least significant byte, so whether it is the
            # first byte in the int depends on the system byte order:
            if LITTLE_ENDIAN:
                return <int*> &data_segment[i]
            else:
                return <int*> &data_segment[i + 1 - sizeof(int)]
    else:
        raise RuntimeError("Failed to find gil in memory")
    

@cython.cdivision(True)
def _run(double av_sample_interval, double output_interval, output_file):
    """"""
    global gil_load
    global gil_load_1m
    global gil_load_5m
    global gil_load_15m

    cdef int held
    cdef long held_count = 0
    cdef long check_count = 0
    cdef long output_count_interval = max(<long> (output_interval / av_sample_interval), 1)

    cdef long next_output_count = output_count_interval

    cdef int output = output_file is not None
    cdef FILE * f
    if output:
        f = fdopen(output_file.fileno(), 'a')

    cdef double k_1 = av_sample_interval/60.0
    cdef double k_5 = av_sample_interval/(5*60.0)
    cdef double k_15 = av_sample_interval/(15*60.0)

    cdef char timestamp[26]

    srand48(time(NULL))

    with nogil:
        pthread_mutex_lock(&mutex)
        while not sleep(-av_sample_interval * log(drand48())):
            held = gil_held()
            held_count += held
            check_count += 1
            gil_load = <double>held_count/<double>check_count
            if check_count * av_sample_interval > 60:
                gil_load_1m = k_1 * held + (1 - k_1) * gil_load_1m
            else:
                gil_load_1m = gil_load
            if check_count * av_sample_interval > 5 * 60:
                gil_load_5m = k_5 * held + (1 - k_5) * gil_load_5m
            else:
                gil_load_5m = gil_load
            if check_count * av_sample_interval > 15 * 60:
                gil_load_15m = k_15 * held + (1 - k_15) * gil_load_15m
            else:
                gil_load_15m = gil_load
            if check_count == next_output_count:
                next_output_count += output_count_interval
                if output:
                    mktimestamp(timestamp)
                    fprintf(f, "%s  GIL load: %.2f (%.2f, %.2f, %.2f)\n",
                            timestamp, gil_load,
                            gil_load_1m, gil_load_5m, gil_load_15m)
                    fflush(f)


def _checkinit():
    if gil_locked == NULL:
        raise RuntimeError("Must call gil_load.init() first")

def init():
    """Find the data structure for the GIL in memory so that we can monitor it
    later to see how often it is held. This function must be called before any
    other threads are started, and before calling start() to start monitoring
    the GIL. Note: this function calls PyEval_InitThreads(), so if your
    application was single-threaded, it will take a slight performance hit
    from this, as the Python interpreter is not quite as efficient in
    multithreaded mode as it is in single-threaded mode, even if there is only
    one thread running."""
    # Get a pointer to the GIL and store it as a global variable:
    global gil_locked
    with lock:
        gil_locked = <int *> get_gil_pointer()

    # Set up condition and mutex for telling the monitoring thread when to stop:
    cdef pthread_condattr_t condattr
    pthread_condattr_init(&condattr)
    pthread_condattr_setclock(&condattr, CLOCK_MONOTONIC)
    pthread_cond_init(&cond, &condattr)
    pthread_mutex_init(&mutex, NULL)


def start(av_sample_interval=0.05, output_interval=5, output=None, reset_counts=False):

    """Start monitoring the GIL. Monitoring works by spawning a thread
    (running only C code so as not to require the GIL itself), and checking
    whether the GIL is held at random times. The random interval between times
    is exponentially distributed with mean set by av_sample_interval. Over
    time, statistics are accumulated for what proportion of the time the
    GIL was held. Overall load, as well as 1 minute, 5 minute, and 15 minute
    exponential moving averages are computed."""

    _checkinit()

    global gil_load
    global gil_load_1m
    global gil_load_5m
    global gil_load_15m
    global monitoring_thread

    if reset_counts:
        gil_load = gil_load_1m = gil_load_5m = gil_load_15m = 0

    if isinstance(output, str):
        output = open(output, 'a')

    with lock:
        if monitoring_thread is not None:
            raise RuntimeError("GIL monitoring already started")
        monitoring_thread = threading.Thread(target=_run,
                                             args=(av_sample_interval, output_interval, output),
                                             daemon=True)
        monitoring_thread.start()


def stop():
    """Stop monitoring the GIL. Accumulated statistics will still be available
    with get()"""
    global monitoring_thread
    global stopping
    with lock:
        if monitoring_thread is None:
            raise RuntimeError("GIL monitoring not running")
        # Tell the monitoring thread to stop and then wait for it:
        pthread_mutex_lock(&mutex)
        stopping = 1
        pthread_cond_signal(&cond)
        pthread_mutex_unlock(&mutex)
        monitoring_thread.join()
        stopping = 0
        monitoring_thread = None


def get(N=2):
    """Returns the average GIL load, and the 1m, 5m and 15m averages, rounded to N digits"""
    _checkinit()
    return round(gil_load, N), [round(n, N) for n in (gil_load_1m, gil_load_5m, gil_load_15m)]


def test():
    """Checks whether indeed the gil_held() function returns whether or not
    the GIL is held."""

    cdef int result

    _checkinit()

    if threading.active_count() > 1:
        raise RuntimeError("Test only valid if no other threads running")
    
    assert gil_held() == 1, "gil_held() returned 0 when we were holding the GIL"

    with nogil:
         result = gil_held()
    assert result == 0, "gil_held() returned 1 when we were not holding the GIL"
    
    return True

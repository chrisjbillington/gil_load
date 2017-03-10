import sys
import os
import threading
import ctypes
from libc.stdlib cimport malloc, free
from libc.stdio cimport printf, fprintf, FILE, fdopen, fflush
from libc.string cimport memcpy
from libc.math cimport log
from libc.time cimport time, time_t, localtime, strftime, tm
from posix.time cimport timespec, nanosleep
cdef extern from "stdlib.h":
    double drand48() nogil
    int srand48(int) nogil


# The pointer to the GIL (it's just an  int)
cdef int * gil_ptr = NULL


# The fraction of the time the GIL has been held:
cdef double gil_load = 0


# 1m, 5m, 15m averages:
cdef double gil_load_1m = 0
cdef double gil_load_5m = 0
cdef double gil_load_15m = 0


LITTLE_ENDIAN = sys.byteorder == 'little'


cdef void mktimestamp(char* s) nogil:
    """String timestamp, for logging"""
    cdef time_t timer
    cdef tm tm_info
    time(&timer);
    tm_info = localtime(&timer)[0]
    strftime(s, 26, "[%Y-%m-%d %H:%M:%S]", &tm_info)


cdef void sleep(double seconds) nogil:
    """Sleep for a given time in seconds. Returns immediately if seconds <= 0"""
    if seconds <= 0:
        return
    cdef timespec remaining
    remaining.tv_sec = <time_t>seconds
    remaining.tv_nsec = <long>((seconds % 1) * 1000000000)
    while True:
        if nanosleep(&remaining, &remaining) == 0:
            break
        # otherwise assume EINTR


def _get_data_segment():
    """Get the data segment of process memory, in which the static variable
    gil_locked from ceval_gil.h is located"""
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
        raise RuntimeError("gil_load.start() must be called prior to other "
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
        raise RuntimeError("Failed to find gil_locked variable")
    

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

    # # Test:
    # printf("  gil: %d\n", gil_ptr[0])
    # with nogil:
    #     printf("nogil: %d\n", gil_ptr[0])

    with nogil:
        while True:
            sleep(-av_sample_interval * log(drand48()))
            held = gil_ptr[0] != 0
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
                            timestamp, gil_load, gil_load_1m, gil_load_5m, gil_load_15m)
                    fflush(f)


def init(av_sample_interval=0.05, output_interval=5, output=None):
    if isinstance(output, str):
        output = open(output, 'a')
    global gil_ptr
    gil_ptr = get_gil_pointer()
    thread = threading.Thread(target=_run,
                              args=(av_sample_interval, output_interval, output))
    thread.daemon = True
    thread.start()


def get():
    return gil_load, (gil_load_1m, gil_load_5m, gil_load_15m)

// Compile with:
// gcc -g3 -Wall -fPIC -shared -o override.so override.c -ldl -lpthread
#define _GNU_SOURCE
#include <Python.h>
#include <stdio.h>
#include <dlfcn.h>
#include <pthread.h>
#include <semaphore.h>
#define MAX_THREADS_TRACKED 1024

// static int (*cond_timedwait_internal)(pthread_cond_t *cond, pthread_mutex_t *mutex, const struct timespec *abstime);
static int (*mutex_lock_internal)(pthread_mutex_t *mutex);
static int (*mutex_unlock_internal)(pthread_mutex_t *mutex);
static int (*sem_wait_internal)(sem_t *sem);

// Py2:
static sem_t * GIL_acq_sem = NULL;
// Py3:
static pthread_mutex_t * GIL_acq_mutex = NULL;

// Whether we know which mutex or semaphore is being used to acquire the GIL:
static int initialised = 0;

// Arrays in which we store pointers to pthreads and mark which ones are
// blocking waiting for the GIL.
static int threads_waiting[MAX_THREADS_TRACKED];
static pthread_t threads[MAX_THREADS_TRACKED];
// how many threads are being tracked:
static int threads_tracked;

// A mutex for non-atomic operations on the above:
static pthread_mutex_t threads_tracked_mutex;

// Thread local for each thread to remember its index in the 'threads_waiting'
// and 'threads' arrays:
static __thread int thread_number = -1;


void __attribute__ ((constructor)) init(void);
void init(void){
    sem_wait_internal = dlsym(RTLD_NEXT, "sem_wait");
    mutex_lock_internal = dlsym(RTLD_NEXT, "pthread_mutex_lock");
    mutex_unlock_internal = dlsym(RTLD_NEXT, "pthread_mutex_unlock");
    pthread_mutex_init(&threads_tracked_mutex, NULL);
}

void register_new_thread(pthread_t thread){
    mutex_lock_internal(&threads_tracked_mutex);
    thread_number = threads_tracked;
    threads_tracked++;
    if(thread_number < MAX_THREADS_TRACKED){
        threads[thread_number] = thread;
        threads_waiting[thread_number] = 0;
    }
    else{
        fprintf(stderr, "gil_load warning: too many threads, not all will be tracked\n");
    }
    pthread_mutex_unlock(&threads_tracked_mutex);
}

void mark_thread_waiting_for_gil(pthread_t thread){
    if(thread_number == -1){
        // We have not seen this thread before.
        register_new_thread(thread);
    }
    if(thread_number < MAX_THREADS_TRACKED){
        printf("%ld waiting for GIL\n", thread);
        threads_waiting[thread_number] = 1;
    }
}

void mark_thread_done_waiting_for_gil(pthread_t thread){
    if(thread_number < MAX_THREADS_TRACKED){
        printf("%ld got GIL\n", thread);
        threads_waiting[thread_number] = 0;
    }
}

int sem_wait(sem_t *sem){
    if (PY_MAJOR_VERSION == 2 && initialised == 0){
        GIL_acq_sem = sem;
    }
    if (PY_MAJOR_VERSION == 2 && initialised == 1 && GIL_acq_sem == sem){
        mark_thread_waiting_for_gil(pthread_self());
    }
    int ret = sem_wait_internal(sem);
    if (PY_MAJOR_VERSION == 2 && initialised == 1 && GIL_acq_sem == sem){
        mark_thread_done_waiting_for_gil(pthread_self());
    }
    return ret;
}

int pthread_mutex_lock(pthread_mutex_t *mutex){
    if (PY_MAJOR_VERSION == 3 && initialised == 1 && GIL_acq_mutex == mutex){
        mark_thread_waiting_for_gil(pthread_self());
    }
    int ret = mutex_lock_internal(mutex);
    return ret;
}

int pthread_mutex_unlock(pthread_mutex_t *mutex){
    if (PY_MAJOR_VERSION == 3 && initialised == 0){
        GIL_acq_mutex = mutex;
    }
    if (PY_MAJOR_VERSION == 3 && initialised == 1 && GIL_acq_mutex == mutex){
        mark_thread_done_waiting_for_gil(pthread_self());
    }
    int ret = mutex_unlock_internal(mutex);
    return ret;
}

int set_initialised(void){
    initialised = 1;
    if (PY_MAJOR_VERSION == 3 && GIL_acq_mutex == NULL){
        return 1;
    }
    if (PY_MAJOR_VERSION == 2 && GIL_acq_sem == NULL){
        return 1;
    }
    return 0;
}
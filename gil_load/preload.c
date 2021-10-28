// Compile with:
// gcc -g3 -Wall -fPIC -shared -o override.so override.c -ldl -lpthread
#define _GNU_SOURCE 1
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
static void (*exit_internal)(void *retval);
static int (*create_internal)(pthread_t *restrict thread,
                                      const pthread_attr_t *restrict attr,
                                      void *(*start_routine)(void *),
                                      void *restrict arg);

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

// Thread number reallocation table, as a circular buffer
static int tnum_reallocation_table[MAX_THREADS_TRACKED];
static size_t tnum_lpop_idx = 0;
static size_t tnum_rpush_idx = 0;

// how many threads we have seen. Possible larger than the number we are
// tracking if it exceeds MAX_THREADS_TRACKED::
static int n_threads_seen = 0;
static int n_threads_tracked = 0;

// A mutex for non-atomic operations on the above:
static pthread_mutex_t threads_tracked_mutex;

// Thread local for each thread to remember its index in the 'threads_waiting'
// and 'threads' arrays:
static __thread int thread_number = -1;

// The thread that most recently acquired the GIL:
static int most_recently_acquired = -1;

// Add a thread number (index in the threads/threads_waiting array) to the
// reallocation table.
static void mark_reallocatable_thread_num(int tnum){
    if (tnum >= MAX_THREADS_TRACKED){
        // Untracked thread
        return;
    }
    if (tnum_rpush_idx - tnum_lpop_idx >= MAX_THREADS_TRACKED){
        // reallocation table is full
        return;
    }
    tnum_reallocation_table[tnum_rpush_idx % MAX_THREADS_TRACKED] = tnum;
    tnum_rpush_idx++;
}

// True if there is at least one thread number in the reallocation table
static inline int has_reallocatable_thread_num(){
    return tnum_lpop_idx < tnum_rpush_idx;
}

// Get the next thread number from the reallocation table
static inline int get_reallocatable_thread_num(){
    int res = tnum_reallocation_table[tnum_lpop_idx % MAX_THREADS_TRACKED];
    tnum_lpop_idx++;
    return res;
}

// Allocate a thread number
static int allocate_thread_number(){
    int res;
    if (has_reallocatable_thread_num()) {
        res = get_reallocatable_thread_num();
        // printf("Reusing thread #%d\n", res);
    } else if (n_threads_tracked < MAX_THREADS_TRACKED){
        res = n_threads_tracked;
        n_threads_tracked++;
        // printf("Tracking new thread #%d\n", res);
    } else {
        res = n_threads_seen;
    }
    n_threads_seen++;
    return res;
}

void __attribute__ ((constructor)) init_gil_load(void);
void init_gil_load(void){
    sem_wait_internal = dlsym(RTLD_NEXT, "sem_wait");
    mutex_lock_internal = dlsym(RTLD_NEXT, "pthread_mutex_lock");
    mutex_unlock_internal = dlsym(RTLD_NEXT, "pthread_mutex_unlock");
    exit_internal = dlsym(RTLD_NEXT, "pthread_exit");
    create_internal = dlsym(RTLD_NEXT, "pthread_create");
    pthread_mutex_init(&threads_tracked_mutex, NULL);
}

void register_new_thread(pthread_t thread){
    mutex_lock_internal(&threads_tracked_mutex);
    thread_number = allocate_thread_number();
    if(thread_number < MAX_THREADS_TRACKED){
        threads[thread_number] = thread;
        threads_waiting[thread_number] = 0;
    }
    else{
        fprintf(stderr, "gil_load warning: too many active threads, not all will be tracked\n");
    }
    pthread_mutex_unlock(&threads_tracked_mutex);
}

void unregister_thread(){
    mutex_lock_internal(&threads_tracked_mutex);
    mark_reallocatable_thread_num(thread_number);
    mutex_unlock_internal(&threads_tracked_mutex);
}

void mark_thread_waiting_for_gil(pthread_t thread){
    if(thread_number == -1){
        // We have not seen this thread before.
        register_new_thread(thread);
    }
    if(thread_number < MAX_THREADS_TRACKED){
        // printf("%ld waiting for GIL\n", thread);
        threads_waiting[thread_number] = 1;
    }
}

void mark_thread_done_waiting_for_gil(pthread_t thread){
    if(thread_number < MAX_THREADS_TRACKED){
        // printf("%ld got GIL\n", thread);
        threads_waiting[thread_number] = 0;
    }
    most_recently_acquired = thread_number;
}

int sem_wait(sem_t *sem){
    if (PY_MAJOR_VERSION == 2 && initialised == 0){
        // gil_load.pyx will call set_initialised(), which sets initialised =
        // 1, and it will do so immediately after a GIL acquisition. At that
        // point the semaphore last stored here will be the one used when
        // waiting for the GIL. So we just store every semaphore we see until
        // we are told (via initialised = 1) that we've found the right one.
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
        // gil_load.pyx will call set_initialised(), which sets initialised =
        // 1, and it will do so immediately after a GIL acquisition. At that
        // point the mutex last stored here will be the one used when waiting
        // for the GIL. So we just store every mutex we see until we are told
        // (via initialised = 1) that we've found the right one.
        GIL_acq_mutex = mutex;
    }
    if (PY_MAJOR_VERSION == 3 && initialised == 1 && GIL_acq_mutex == mutex){
        mark_thread_done_waiting_for_gil(pthread_self());
    }
    int ret = mutex_unlock_internal(mutex);
    return ret;
}

void __attribute__((noreturn)) pthread_exit(void *retval);
void pthread_exit(void *retval){
    unregister_thread();
    exit_internal(retval);
    while (1);  // noreturn
}

struct thread_routine {
    void *(*func)(void *arg);
    void *arg;
};

void *thread_routine_wrapper(void *entrypoint)
{
    struct thread_routine *routine = (struct thread_routine *) entrypoint;
    void *(*start_routine)(void *) = routine->func;
    void *arg = routine->arg;
    free(routine);

    void *retval = start_routine(arg);
    unregister_thread();
    return retval;
}

int pthread_create(pthread_t *restrict thread,
                   const pthread_attr_t *restrict attr,
                   void *(*start_routine)(void *),
                   void *restrict arg){
    struct thread_routine *routine = calloc(1, sizeof(struct thread_routine));
    if (! routine){
        return -EAGAIN;
    }

    routine->func = start_routine;
    routine->arg = arg;

    return create_internal(thread, attr, thread_routine_wrapper, routine);
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


pthread_t * get_threads_arr(void){
    return threads;
}

int * get_threads_waiting_arr(void){
    return threads_waiting;
}

int get_most_recently_acquired(void){
    return most_recently_acquired;
}

int begin_sample(void){
    // Called when calling code wants to analyse the 'threads' and
    // 'threads_waiting' arrays. We acquire the mutex so that the number of
    // elements in the array is guaranteed to be correct and doesn't change
    // while this is occurring. The caller must call end_sample() to release
    // the mutex when it is done. We return the number of elements it is safe
    // to read from the array.
    mutex_lock_internal(&threads_tracked_mutex);
    return n_threads_tracked;
}

void end_sample(void){
    pthread_mutex_unlock(&threads_tracked_mutex);
}
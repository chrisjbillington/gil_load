// Compile with:
// gcc -g3 -Wall -fPIC -shared -o override.so override.c -ldl -lpthread
#define _GNU_SOURCE
#include <Python.h>
#include <stdio.h>
#include <dlfcn.h>
#include <pthread.h>
#include <semaphore.h>

// #include <time.h>

// static int (*cond_timedwait_internal)(pthread_cond_t *cond, pthread_mutex_t *mutex, const struct timespec *abstime);
static int (*mutex_lock_internal)(pthread_mutex_t *mutex);
static int (*mutex_unlock_internal)(pthread_mutex_t *mutex);
static int (*sem_wait_internal)(sem_t *sem);

// Py2:
static sem_t * GIL_acq_sem;
// Py3:
static pthread_mutex_t * GIL_acq_mutex;

// Whether we know which mutex or semaphore is being used to acquire the GIL:
static int initialised = 0;


void __attribute__ ((constructor)) init(void);
void init(void){
    // cond_timedwait_internal = dlvsym(RTLD_NEXT, "pthread_cond_wait", "GLIBC_2.3.2");
    sem_wait_internal = dlsym(RTLD_NEXT, "sem_wait");
    mutex_lock_internal = dlsym(RTLD_NEXT, "pthread_mutex_lock");
    mutex_unlock_internal = dlsym(RTLD_NEXT, "pthread_mutex_unlock");
}

// int pthread_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex, const struct timespec *abstime){
//     printf("%ld -> cond_timedwait: %p\n", pthread_self(), cond);
//     int ret = cond_timedwait_internal(cond, mutex, abstime);
//     printf("  %ld <- cond_timedwait: %p\n", pthread_self(), cond);
//     return ret;
// }

int sem_wait(sem_t *sem){
    if (PY_MAJOR_VERSION == 2 && initialised == 0){
        GIL_acq_sem = sem;
    }
    if (PY_MAJOR_VERSION == 2 && initialised == 1 && GIL_acq_sem == sem){
        printf("%ld -> sem_wait: %p\n", pthread_self(), sem);
    }
    int ret = sem_wait_internal(sem);
    if (PY_MAJOR_VERSION == 2 && initialised == 1 && GIL_acq_sem == sem){
        printf("  %ld <- sem_wait: %p\n", pthread_self(), sem);
    }
    return ret;
}

int pthread_mutex_lock(pthread_mutex_t *mutex){
    if (PY_MAJOR_VERSION == 3 && initialised == 1 && GIL_acq_mutex == mutex){
        printf("%ld -> mutex_lock: %p\n", pthread_self(), mutex);
    }
    int ret = mutex_lock_internal(mutex);
    if (PY_MAJOR_VERSION == 3 && initialised == 1 && GIL_acq_mutex == mutex){
        printf("  %ld <- mutex_lock: %p\n", pthread_self(), mutex);
    }
    return ret;
}

int pthread_mutex_unlock(pthread_mutex_t *mutex){
    if (PY_MAJOR_VERSION == 3 && initialised == 0){
        GIL_acq_mutex = mutex;
    }
    if (PY_MAJOR_VERSION == 3 && initialised == 1 && GIL_acq_mutex == mutex){
        printf("%ld -> mutex_unlock: %p\n", pthread_self(), mutex);
    }
    int ret = mutex_unlock_internal(mutex);
    if (PY_MAJOR_VERSION == 3 && initialised == 1 && GIL_acq_mutex == mutex){
        printf("  %ld <- mutex_unlock: %p\n", pthread_self(), mutex);
    }
    return ret;
}

void set_initialised(void){
    printf("setting initialised\n");
    initialised = 1;
}
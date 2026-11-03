// iPhoneOS POSIX compatibility shim for the Node 26 runtime.
//
// iOS userland does not implement unnamed POSIX semaphores (sem_init returns
// ENOSYS) and the kernel sandbox terminates processes that call System V shared
// memory (shmget traps with SIGSYS). This dylib is loaded into the Node process
// via DYLD_INSERT_LIBRARIES by the node26 launcher and:
//
//   * interposes sem_init/sem_wait/sem_trywait/sem_post/sem_getvalue/sem_destroy
//     with process-local implementations backed by a mutex + condition variable;
//     calls for named semaphores (sem_open) fall through to libSystem.
//   * interposes shmget/shmat/shmdt/shmctl with an emulation backed by POSIX
//     shared memory (shm_open + mmap MAP_SHARED), which is implemented on iOS.
//     Segments created with IPC_PRIVATE get a deterministic name derived from
//     their id so another process that receives the id can attach as well.
//
// Scope/limits: unnamed semaphores are process-local (pshared=0/1 accepted but
// not shared across processes); System V segments are emulated, not kernel
// objects (no SELinux-style permissions, no System V semaphores/msg queues).
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// Opaque ABI types: callers pass a pointer to their own sem_t storage; the
// shim only uses the pointer as a key and never dereferences it.
typedef struct ios_posix_sem { long opaque[8]; } ios_posix_sem_t;

// libSystem exposes these names but iOS rejects sem_init and SIGSYS-traps shmget.
// Declare them locally so this shim can interpose the symbols without including
// the SDK headers that mark them unavailable.
extern int sem_init(ios_posix_sem_t *sem, int pshared, unsigned int value);
extern int sem_destroy(ios_posix_sem_t *sem);
extern int sem_wait(ios_posix_sem_t *sem);
extern int sem_trywait(ios_posix_sem_t *sem);
extern int sem_post(ios_posix_sem_t *sem);
extern int sem_getvalue(ios_posix_sem_t *sem, int *value);
extern int shmget(int key, unsigned long size, int shmflg);
extern void *shmat(int shmid, const void *shmaddr, int shmflg);
extern int shmdt(const void *shmaddr);
extern int shmctl(int shmid, int cmd, void *buf);

#define IOS_SEM_MAX 256
#define IOS_SHM_MAX 128
#define IOS_SHM_NAME_MAX 64

typedef struct {
  int used;
  const ios_posix_sem_t *key;
  unsigned value;  // current count
} ios_sem_entry;

static ios_sem_entry ios_sems[IOS_SEM_MAX];
static pthread_mutex_t ios_sem_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ios_sem_cond = PTHREAD_COND_INITIALIZER;

static ios_sem_entry *ios_sem_find_locked(const ios_posix_sem_t *key) {
  for (int i = 0; i < IOS_SEM_MAX; i++) {
    if (ios_sems[i].used && ios_sems[i].key == key) return &ios_sems[i];
  }
  return NULL;
}

static int ios_sem_init(ios_posix_sem_t *sem, int pshared, unsigned value) {
  if (sem == NULL) { errno = EINVAL; return -1; }
  if (pshared != 0 && pshared != 1) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&ios_sem_lock);
  ios_sem_entry *existing = ios_sem_find_locked(sem);
  if (existing != NULL) {
    pthread_mutex_unlock(&ios_sem_lock);
    errno = EBUSY;
    return -1;
  }
  for (int i = 0; i < IOS_SEM_MAX; i++) {
    if (!ios_sems[i].used) {
      ios_sems[i].used = 1;
      ios_sems[i].key = sem;
      ios_sems[i].value = value;
      pthread_mutex_unlock(&ios_sem_lock);
      return 0;
    }
  }
  pthread_mutex_unlock(&ios_sem_lock);
  errno = ENOSPC;
  return -1;
}

static int ios_sem_destroy(ios_posix_sem_t *sem) {
  if (sem == NULL) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&ios_sem_lock);
  ios_sem_entry *entry = ios_sem_find_locked(sem);
  if (entry == NULL) {
    pthread_mutex_unlock(&ios_sem_lock);
    // Possibly a named semaphore; forward to libSystem if it implements it.
    int (*real)(ios_posix_sem_t *) = (int (*)(ios_posix_sem_t *))dlsym(RTLD_NEXT, "sem_destroy");
    if (real == NULL) { errno = EINVAL; return -1; }
    return real(sem);
  }
  entry->used = 0;
  pthread_cond_broadcast(&ios_sem_cond);
  pthread_mutex_unlock(&ios_sem_lock);
  return 0;
}

static int ios_sem_wait(ios_posix_sem_t *sem) {
  if (sem == NULL) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&ios_sem_lock);
  ios_sem_entry *entry = ios_sem_find_locked(sem);
  if (entry == NULL) {
    pthread_mutex_unlock(&ios_sem_lock);
    int (*real)(ios_posix_sem_t *) = (int (*)(ios_posix_sem_t *))dlsym(RTLD_NEXT, "sem_wait");
    if (real == NULL) { errno = EINVAL; return -1; }
    return real(sem);
  }
  while (entry->value == 0) pthread_cond_wait(&ios_sem_cond, &ios_sem_lock);
  entry->value -= 1;
  pthread_mutex_unlock(&ios_sem_lock);
  return 0;
}

static int ios_sem_trywait(ios_posix_sem_t *sem) {
  if (sem == NULL) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&ios_sem_lock);
  ios_sem_entry *entry = ios_sem_find_locked(sem);
  if (entry == NULL) {
    pthread_mutex_unlock(&ios_sem_lock);
    int (*real)(ios_posix_sem_t *) = (int (*)(ios_posix_sem_t *))dlsym(RTLD_NEXT, "sem_trywait");
    if (real == NULL) { errno = EINVAL; return -1; }
    return real(sem);
  }
  if (entry->value == 0) {
    pthread_mutex_unlock(&ios_sem_lock);
    errno = EAGAIN;
    return -1;
  }
  entry->value -= 1;
  pthread_mutex_unlock(&ios_sem_lock);
  return 0;
}

static int ios_sem_post(ios_posix_sem_t *sem) {
  if (sem == NULL) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&ios_sem_lock);
  ios_sem_entry *entry = ios_sem_find_locked(sem);
  if (entry == NULL) {
    pthread_mutex_unlock(&ios_sem_lock);
    int (*real)(ios_posix_sem_t *) = (int (*)(ios_posix_sem_t *))dlsym(RTLD_NEXT, "sem_post");
    if (real == NULL) { errno = EINVAL; return -1; }
    return real(sem);
  }
  entry->value += 1;
  pthread_cond_signal(&ios_sem_cond);
  pthread_mutex_unlock(&ios_sem_lock);
  return 0;
}

static int ios_sem_getvalue(ios_posix_sem_t *sem, int *value) {
  if (sem == NULL || value == NULL) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&ios_sem_lock);
  ios_sem_entry *entry = ios_sem_find_locked(sem);
  if (entry == NULL) {
    pthread_mutex_unlock(&ios_sem_lock);
    int (*real)(ios_posix_sem_t *, int *) = (int (*)(ios_posix_sem_t *, int *))dlsym(RTLD_NEXT, "sem_getvalue");
    if (real == NULL) { errno = EINVAL; return -1; }
    return real(sem, value);
  }
  *value = (int)entry->value;
  pthread_mutex_unlock(&ios_sem_lock);
  return 0;
}

// ---- System V shared memory emulation -------------------------------------

#define IOS_IPC_PRIVATE 0
#define IOS_IPC_CREAT 01000
#define IOS_IPC_RMID 0
#define IOS_SHM_PRIVATE_FLAG 0x40000000
#define IOS_SHM_ANON_MAX (128 * 1024 * 1024)
#define IOS_SHM_ANON_MAP ((void *)-1)

typedef struct {
  int used;
  int created;
  int id;
  size_t size;
  void *mapping;
} ios_shm_segment;

static ios_shm_segment ios_shms[IOS_SHM_MAX];
static pthread_mutex_t ios_shm_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned int ios_shm_counter = 0;

static void ios_shm_name_for_id(int id, char out[IOS_SHM_NAME_MAX]) {
  if ((id & IOS_SHM_PRIVATE_FLAG) != 0) {
    snprintf(out, IOS_SHM_NAME_MAX, "/n26sv-%d", id & ~IOS_SHM_PRIVATE_FLAG);
  } else {
    snprintf(out, IOS_SHM_NAME_MAX, "/n26svk-%d", id);
  }
}

static int ios_shm_create(const char *name, size_t size) {
  int fd = shm_open(name, O_CREAT | O_RDWR | O_EXCL, 0600);
  if (fd < 0) return -1;
  if (ftruncate(fd, (off_t)size) != 0) {
    int saved = errno;
    close(fd);
    shm_unlink(name);
    errno = saved;
    return -1;
  }
  close(fd);
  return 0;
}

static int ios_shmget(int key, size_t size, int shmflg) {
  (void)shmflg;
  if (size == 0 || size > IOS_SHM_ANON_MAX) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&ios_shm_lock);
  char name[IOS_SHM_NAME_MAX];
  int id;
  if (key == IOS_IPC_PRIVATE) {
    id = (int)(((unsigned)getpid() << 16) ^ (ios_shm_counter++ & 0xffffu)) | IOS_SHM_PRIVATE_FLAG;
    ios_shm_name_for_id(id, name);
    if (ios_shm_create(name, size) != 0) {
      pthread_mutex_unlock(&ios_shm_lock);
      return -1;
    }
  } else {
    // Keyed segments: reuse an existing segment when present, otherwise create
    // it only when IPC_CREAT was requested.
    id = key & ~IOS_SHM_PRIVATE_FLAG;
    ios_shm_name_for_id(id, name);
    int fd = shm_open(name, O_RDWR, 0);
    if (fd >= 0) {
      close(fd);
      pthread_mutex_unlock(&ios_shm_lock);
      return id;
    }
    if ((shmflg & IOS_IPC_CREAT) == 0) {
      pthread_mutex_unlock(&ios_shm_lock);
      errno = ENOENT;
      return -1;
    }
    if (ios_shm_create(name, size) != 0) {
      pthread_mutex_unlock(&ios_shm_lock);
      return -1;
    }
  }
  for (int i = 0; i < IOS_SHM_MAX; i++) {
    if (!ios_shms[i].used) {
      ios_shms[i].used = 1;
      ios_shms[i].created = 1;
      ios_shms[i].id = id;
      ios_shms[i].size = size;
      ios_shms[i].mapping = IOS_SHM_ANON_MAP;
      pthread_mutex_unlock(&ios_shm_lock);
      return id;
    }
  }
  pthread_mutex_unlock(&ios_shm_lock);
  shm_unlink(name);
  errno = ENOSPC;
  return -1;
}

static void *ios_shmat(int id, const void *addr, int shmflg) {
  (void)addr;
  (void)shmflg;
  char name[IOS_SHM_NAME_MAX];
  ios_shm_name_for_id(id, name);
  pthread_mutex_lock(&ios_shm_lock);
  for (int i = 0; i < IOS_SHM_MAX; i++) {
    if (ios_shms[i].used && ios_shms[i].id == id && ios_shms[i].mapping != IOS_SHM_ANON_MAP) {
      void *mapping = ios_shms[i].mapping;
      pthread_mutex_unlock(&ios_shm_lock);
      return mapping;
    }
  }
  pthread_mutex_unlock(&ios_shm_lock);
  int fd = shm_open(name, O_RDWR, 0);
  if (fd < 0) return IOS_SHM_ANON_MAP;
  struct stat status;
  if (fstat(fd, &status) != 0 || status.st_size <= 0) {
    int saved = errno ? errno : EINVAL;
    close(fd);
    errno = saved;
    return IOS_SHM_ANON_MAP;
  }
  size_t length = (size_t)status.st_size;
  void *mapping = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (mapping == MAP_FAILED) return IOS_SHM_ANON_MAP;
  pthread_mutex_lock(&ios_shm_lock);
  int stored = 0;
  for (int i = 0; i < IOS_SHM_MAX; i++) {
    if (!ios_shms[i].used) {
      ios_shms[i].used = 1;
      ios_shms[i].created = 0;
      ios_shms[i].id = id;
      ios_shms[i].size = length;
      ios_shms[i].mapping = mapping;
      stored = 1;
      break;
    }
  }
  pthread_mutex_unlock(&ios_shm_lock);
  if (!stored) {
    munmap(mapping, length);
    errno = ENOSPC;
    return IOS_SHM_ANON_MAP;
  }
  return mapping;
}

static int ios_shmdt(const void *addr) {
  if (addr == NULL || addr == MAP_FAILED) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&ios_shm_lock);
  for (int i = 0; i < IOS_SHM_MAX; i++) {
    if (ios_shms[i].used && ios_shms[i].mapping == addr) {
      void *mapping = ios_shms[i].mapping;
      size_t size = ios_shms[i].size;
      ios_shms[i].used = 0;
      ios_shms[i].created = 0;
      ios_shms[i].mapping = IOS_SHM_ANON_MAP;
      pthread_mutex_unlock(&ios_shm_lock);
      if (munmap(mapping, size) != 0) return -1;
      return 0;
    }
  }
  pthread_mutex_unlock(&ios_shm_lock);
  errno = EINVAL;
  return -1;
}

static int ios_shmctl(int id, int cmd, void *buf) {
  (void)buf;
  if (cmd != IOS_IPC_RMID) { errno = EINVAL; return -1; }
  char name[IOS_SHM_NAME_MAX];
  ios_shm_name_for_id(id, name);
  if (shm_unlink(name) != 0) {
    if (errno == ENOENT) { errno = EINVAL; }
    return -1;
  }
  pthread_mutex_lock(&ios_shm_lock);
  for (int i = 0; i < IOS_SHM_MAX; i++) {
    if (ios_shms[i].used && ios_shms[i].id == id && ios_shms[i].mapping == IOS_SHM_ANON_MAP) {
      ios_shms[i].used = 0;
      break;
    }
  }
  pthread_mutex_unlock(&ios_shm_lock);
  return 0;
}

// ---- dyld interposing -----------------------------------------------------

#define DYLD_INTERPOSE(_replacement, _replacee)                                                 \
  __attribute__((used)) static struct {                                                         \
    const void *replacement;                                                                    \
    const void *replacee;                                                                       \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {                   \
      (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

DYLD_INTERPOSE(ios_sem_init, sem_init)
DYLD_INTERPOSE(ios_sem_destroy, sem_destroy)
DYLD_INTERPOSE(ios_sem_wait, sem_wait)
DYLD_INTERPOSE(ios_sem_trywait, sem_trywait)
DYLD_INTERPOSE(ios_sem_post, sem_post)
DYLD_INTERPOSE(ios_sem_getvalue, sem_getvalue)
DYLD_INTERPOSE(ios_shmget, shmget)
DYLD_INTERPOSE(ios_shmat, shmat)
DYLD_INTERPOSE(ios_shmdt, shmdt)
DYLD_INTERPOSE(ios_shmctl, shmctl)

static void ios_posix_compat_cleanup(void) {
  // Best-effort cleanup of POSIX shm names created for System V emulation.
  for (int i = 0; i < IOS_SHM_MAX; i++) {
    if (ios_shms[i].used && ios_shms[i].created) {
      char name[IOS_SHM_NAME_MAX];
      ios_shm_name_for_id(ios_shms[i].id, name);
      shm_unlink(name);
    }
  }
}

__attribute__((constructor)) static void ios_posix_compat_init(void) {
  atexit(ios_posix_compat_cleanup);
}

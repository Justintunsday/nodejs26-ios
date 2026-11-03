// Tiny probe: can a DYLD_INSERT_LIBRARIES dylib both (a) be loaded, (b) export
// replacement functions, and (c) interpose libSystem's sem_init/shmget so that
// node:ffi / dlsym(RTLD_DEFAULT) users see the interposed symbols?
//
// The standard names are declared without <semaphore.h>/<sys/shm.h> on purpose:
// iOS marks the real POSIX/SysV symbols unavailable, and this diagnostic only
// needs SysV-compatible prototypes (key_t=int, size_t=unsigned long on arm64).
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <dlfcn.h>

typedef struct ios_probe_sem { void *opaque[8]; } ios_probe_sem_t;

extern int sem_init(ios_probe_sem_t *sem, int pshared, unsigned int value);
extern int shmget(int key, unsigned long size, int shmflg);

static int probe_sem_init(ios_probe_sem_t *sem, int pshared, unsigned int value) {
  (void)sem; (void)pshared; (void)value;
  errno = 990;
  return -1;
}

static int probe_shmget(int key, unsigned long size, int shmflg) {
  (void)key; (void)size; (void)shmflg;
  errno = 991;
  return -1;
}

#define DYLD_INTERPOSE(_replacement, _replacee)                                                   \
  __attribute__((used)) static struct {                                                           \
    const void *replacement;                                                                      \
    const void *replacee;                                                                         \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {                     \
      (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

DYLD_INTERPOSE(probe_sem_init, sem_init)
DYLD_INTERPOSE(probe_shmget, shmget)

// Direct-call probes: these use the image's ordinary external relocations, so they
// report whether dyld interposing actually replaced libSystem bindings (as opposed
// to only dlsym(RTLD_DEFAULT) lookups).
int probe_direct_sem_init(void) {
  ios_probe_sem_t sem;
  errno = 0;
  int result = sem_init(&sem, 0, 0);
  int saved = errno;
  errno = saved;
  return result;
}

int probe_direct_shmget(void) {
  errno = 0;
  int result = shmget(0, 4096, 0600);
  int saved = errno;
  errno = saved;
  return result;
}

int probe_direct_errno(void) { return errno; }

__attribute__((constructor)) static void ios_posix_interpose_probe_init(void) {
  void *via_dlsym = dlsym(RTLD_DEFAULT, "sem_init");
  void *via_next = dlsym(RTLD_NEXT, "sem_init");
  void *handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_NOLOAD);
  void *via_handle = handle ? dlsym(handle, "sem_init") : NULL;
  fprintf(stderr,
          "IOS_POSIX_INTERPOSE_PROBE loaded dlsym_default=%p dlsym_next=%p dlsym_handle=%p replacement_pointer=%p\n",
          via_dlsym, via_next, via_handle, (void *)&probe_sem_init);
}

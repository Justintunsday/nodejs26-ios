// Fixed-signature bridge for arm64 Darwin tests driven by node:ffi.
// Keep variadic libc calls in C so Apple's arm64 varargs ABI is respected.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <semaphore.h>
#include <spawn.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <crt_externs.h>

static _Thread_local int saved_errno;
static void start(void) { errno = 0; saved_errno = 0; }
static int done(int result) { saved_errno = errno; return result; }
static void *symbol(const char *name) {
  void *result = dlsym(RTLD_DEFAULT, name);
  if (!result) saved_errno = ENOSYS;
  return result;
}
int probe_errno(void) { return saved_errno; }
const char *probe_strerror(int value) { return strerror(value); }
int probe_constant(const char *name) {
  if (!strcmp(name,"O_RDWR")) return O_RDWR;
  if (!strcmp(name,"O_CREAT")) return O_CREAT;
  if (!strcmp(name,"O_EXCL")) return O_EXCL;
  if (!strcmp(name,"O_TRUNC")) return O_TRUNC;
  if (!strcmp(name,"PROT_READ")) return PROT_READ;
  if (!strcmp(name,"PROT_WRITE")) return PROT_WRITE;
  if (!strcmp(name,"MAP_SHARED")) return MAP_SHARED;
  if (!strcmp(name,"MAP_PRIVATE")) return MAP_PRIVATE;
  if (!strcmp(name,"MAP_ANON")) return MAP_ANON;
  if (!strcmp(name,"CTL_KERN")) return CTL_KERN;
  if (!strcmp(name,"KERN_OSRELEASE")) return KERN_OSRELEASE;
  if (!strcmp(name,"ENOENT")) return ENOENT;
  if (!strcmp(name,"EEXIST")) return EEXIST;
  if (!strcmp(name,"EAGAIN")) return EAGAIN;
  if (!strcmp(name,"ENOSYS")) return ENOSYS;
  if (!strcmp(name,"EACCES")) return EACCES;
  if (!strcmp(name,"EPERM")) return EPERM;
  return -1;
}
int probe_open(const char *path, int flags, uint32_t mode) {
  start(); return done(open(path, flags, (mode_t)mode));
}
int probe_close(int fd) { start(); return done(close(fd)); }
int64_t probe_write(int fd, const void *buffer, uint64_t length) {
  start(); int64_t result = write(fd, buffer, (size_t)length); saved_errno = errno; return result;
}
int64_t probe_read(int fd, void *buffer, uint64_t length) {
  start(); int64_t result = read(fd, buffer, (size_t)length); saved_errno = errno; return result;
}
int probe_fsync(int fd) { start(); return done(fsync(fd)); }
int probe_ftruncate(int fd, int64_t size) { start(); return done(ftruncate(fd, (off_t)size)); }
int probe_unlink(const char *path) { start(); return done(unlink(path)); }
int probe_pipe(int *fds) { start(); return done(pipe(fds)); }
int probe_sysctlbyname(const char *name, void *out, uint64_t *length) {
  start(); return done(sysctlbyname(name, out, (size_t *)length, NULL, 0));
}
int probe_sysctl(const int *mib, uint32_t count, void *out, uint64_t *length) {
  start(); return done(sysctl((int *)mib, count, out, (size_t *)length, NULL, 0));
}
void *probe_mmap(int fd, uint64_t size, int protection, int flags) {
  start(); void *result = mmap(NULL, (size_t)size, protection, flags, fd, 0); saved_errno = errno; return result;
}
int probe_pointer_failed(void *pointer) { return pointer == MAP_FAILED; }
int probe_mprotect(void *pointer, uint64_t size, int protection) {
  start(); return done(mprotect(pointer, (size_t)size, protection));
}
int probe_munmap(void *pointer, uint64_t size) { start(); return done(munmap(pointer, (size_t)size)); }
void probe_store(void *pointer, uint32_t value) { *(volatile uint32_t *)pointer = value; }
uint32_t probe_load(void *pointer) { return *(volatile uint32_t *)pointer; }
int probe_shm_open(const char *name, int flags, uint32_t mode) {
  start(); return done(shm_open(name, flags, (mode_t)mode));
}
int probe_shm_unlink(const char *name) { start(); return done(shm_unlink(name)); }
void *probe_sem_open(const char *name, int flags, uint32_t mode, uint32_t value) {
  start(); sem_t *result = sem_open(name, flags, (mode_t)mode, value); saved_errno = errno; return result;
}
int probe_sem_failed(void *pointer) { return pointer == SEM_FAILED; }
int probe_sem_close(void *pointer) { start(); return done(sem_close(pointer)); }
int probe_sem_unlink(const char *name) { start(); return done(sem_unlink(name)); }
int probe_sem_post(void *pointer) { start(); return done(sem_post(pointer)); }
int probe_sem_trywait(void *pointer) { start(); return done(sem_trywait(pointer)); }
int probe_sem_init(void *pointer, uint32_t value) {
  typedef int (*function)(sem_t *, int, unsigned int);
  start(); function call = (function)symbol("sem_init");
  if (!call) return -1;
  return done(call(pointer, 0, value));
}
int probe_sem_destroy(void *pointer) {
  typedef int (*function)(sem_t *);
  start(); function call = (function)symbol("sem_destroy");
  if (!call) return -1;
  return done(call(pointer));
}
int probe_sem_size(void) { return (int)sizeof(sem_t); }
int probe_shmget(uint64_t size) {
  typedef int (*function)(int, size_t, int);
  start(); function call = (function)symbol("shmget");
  if (!call) return -1;
  // Darwin IPC_PRIVATE=0; no IPC_CREAT is needed for an IPC_PRIVATE key.
  return done(call(0, (size_t)size, 0600));
}
void *probe_shmat(int identifier) {
  typedef void *(*function)(int, const void *, int);
  start(); function call = (function)symbol("shmat");
  if (!call) return MAP_FAILED;
  void *result = call(identifier, NULL, 0); saved_errno = errno; return result;
}
int probe_shmdt(void *pointer) {
  typedef int (*function)(const void *);
  start(); function call = (function)symbol("shmdt");
  if (!call) return -1;
  return done(call(pointer));
}
int probe_shm_rmid(int identifier) {
  typedef int (*function)(int, int, void *);
  start(); function call = (function)symbol("shmctl");
  if (!call) return -1;
  // IPC_RMID=0 in Darwin's sys/ipc.h.
  return done(call(identifier, 0, NULL));
}
int probe_posix_spawn(const char *node, const char *script, const char *mode, const char *directory, int *pid) {
  char *const argv[] = {(char *)node,"--single-threaded","--allow-natives-syntax",(char *)script,(char *)mode,(char *)directory,NULL};
  start(); int result = posix_spawn(pid, node, NULL, NULL, argv, *_NSGetEnviron());
  saved_errno = result; return result; // posix_spawn returns an error number directly.
}
int probe_waitpid(int pid, int *status) { start(); return done(waitpid(pid, status, 0)); }
int probe_execve(const char *node, const char *script, const char *mode, const char *directory) {
  char *const argv[] = {(char *)node,"--single-threaded","--allow-natives-syntax",(char *)script,(char *)mode,(char *)directory,NULL};
  start(); return done(execve(node, argv, *_NSGetEnviron()));
}

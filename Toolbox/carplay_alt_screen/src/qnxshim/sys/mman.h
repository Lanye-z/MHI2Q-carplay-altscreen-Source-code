#ifndef QSHIM_SYS_MMAN_H
#define QSHIM_SYS_MMAN_H

#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2

#define MAP_SHARED 0x0001
#define MAP_FAILED ((void *)-1)

extern int shm_open(const char *name, int oflag, unsigned int mode);
extern int shm_unlink(const char *name);
extern int ftruncate(int fd, off_t length);
extern void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
extern int munmap(void *addr, size_t len);

#endif

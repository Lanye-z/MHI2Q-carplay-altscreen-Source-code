#ifndef QSHIM_FCNTL_H
#define QSHIM_FCNTL_H
#define O_RDONLY 0
extern int open(const char *path, int oflag, ...);
#endif

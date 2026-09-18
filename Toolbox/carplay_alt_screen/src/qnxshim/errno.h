/* Exact errno access used by the freestanding ARM/QNX build.
 * Captured P1404 libc.so.3 exports __get_errno_ptr; QNX keeps the standard
 * ENOENT/ENOTDIR numeric values used to distinguish proven absence from an
 * indeterminate filesystem inspection failure. */
#ifndef QSHIM_ERRNO_H
#define QSHIM_ERRNO_H
extern int *__get_errno_ptr(void);
#define errno   (*__get_errno_ptr())
#define ENOENT  2
#define EACCES  13
#define ENOTDIR 20
#define EIO     5
#endif

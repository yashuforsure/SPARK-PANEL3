#ifndef hook_h
#define hook_h


#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Enforced function names
bool Zexis(void *address[], void *function[], int count);
bool ZexisUnhook(void *address);

#ifdef __cplusplus
}
#endif

#endif /* hook_h */

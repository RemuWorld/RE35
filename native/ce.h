#ifndef COMMAND_ENVIRONMENT_C_H
#define COMMAND_ENVIRONMENT_C_H
#include <stddef.h>
#include <stdint.h>
#ifdef _WIN32
# ifdef CE_BUILD
#  define CE_API __declspec(dllexport)
# else
#  define CE_API __declspec(dllimport)
# endif
#else
# define CE_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ce_handle ce_handle;
enum { CE_OK=0, CE_ARGUMENT=1, CE_RUNTIME=2, CE_SCRIPT=3, CE_MEMORY=4, CE_THREAD=5, CE_BUSY=6 };
/* ABI v1. Paths are UTF-8, NUL terminated. JSON buffers use explicit byte lengths.
 * Every non-NULL returned buffer belongs to the caller; release with ce_free.
 * Calls run on the create thread. Destroy may run on another thread only when
 * idle (SafeHandle finalization); it returns CE_BUSY rather than racing a call.
 * After successful destroy the handle must never be used again. */
CE_API uint32_t ce_abi_version(void);
CE_API int ce_create(const char *lua51_library, const char *lua_root, ce_handle **handle, char **error, size_t *error_size);
CE_API int ce_call(ce_handle *handle, const char *operation, const char *json, size_t json_size,
                   char **output, size_t *output_size, char **error, size_t *error_size);
CE_API int ce_destroy(ce_handle *handle);
CE_API void ce_free(void *buffer);
#ifdef __cplusplus
}
#endif
#endif

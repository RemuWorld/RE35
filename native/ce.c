#define CE_BUILD
#include "ce.h"
#include "lua51_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <pthread.h>
#include <unistd.h>
#endif
#define CE_LIMIT (1024u * 1024u)
#define CE_VM_LIMIT (32u * CE_LIMIT)
typedef struct { char *source; size_t size; const char *name; } ce_module;
typedef struct { const char *name, *path; } ce_source;
static const ce_source core_sources[] = {
#define CE_CORE_MODULE(name, path) { name, path },
#include "core_modules.def"
#undef CE_CORE_MODULE
};
enum { CE_CORE_COUNT = sizeof(core_sources) / sizeof(core_sources[0]) };
struct ce_handle {
  ce_library library; ce_lua51 api; lua_State *state; size_t memory;
  ce_module modules[CE_CORE_COUNT]; char scope[96];
  const char *operation, *input; size_t input_size;
  volatile long busy;
#ifdef _WIN32
  DWORD owner;
#else
  pthread_t owner;
#endif
};
#ifdef _WIN32
static DWORD ce_thread_key = TLS_OUT_OF_INDEXES;
BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
  (void)instance; (void)reserved;
  if (reason == DLL_PROCESS_ATTACH) { ce_thread_key = TlsAlloc(); return ce_thread_key != TLS_OUT_OF_INDEXES; }
  if (reason == DLL_PROCESS_DETACH && ce_thread_key != TLS_OUT_OF_INDEXES) TlsFree(ce_thread_key);
  return TRUE;
}
static ce_handle *active_get(void) { return TlsGetValue(ce_thread_key); }
static void active_set(ce_handle *h) { TlsSetValue(ce_thread_key, h); }
#else
static _Thread_local ce_handle *ce_active;
static ce_handle *active_get(void) { return ce_active; }
static void active_set(ce_handle *h) { ce_active = h; }
#endif
static volatile long ce_serial;
static int acquire(volatile long *value) {
#ifdef _WIN32
  return InterlockedCompareExchange(value, 1, 0) == 0;
#else
  return __sync_bool_compare_and_swap(value, 0, 1);
#endif
}
static void release(volatile long *value) {
#ifdef _WIN32
  InterlockedExchange(value, 0);
#else
  __sync_lock_release(value);
#endif
}
static long next_serial(void) {
#ifdef _WIN32
  return InterlockedIncrement(&ce_serial);
#else
  return __sync_add_and_fetch(&ce_serial, 1);
#endif
}
static int owned(ce_handle *h) {
#ifdef _WIN32
  return h->owner == GetCurrentThreadId();
#else
  return pthread_equal(h->owner, pthread_self());
#endif
}
static int output_copy(const char *source, size_t size, char **output, size_t *length) {
  if (size > CE_LIMIT) return CE_ARGUMENT;
  char *buffer = malloc(size + 1); if (!buffer) return CE_MEMORY;
  if (size) memcpy(buffer, source, size);
  buffer[size] = 0; *output = buffer; *length = size; return CE_OK;
}
static int failed(int code, const char *message, char **error, size_t *size) {
  int result = output_copy(message, strlen(message), error, size); return result == CE_OK ? code : result;
}
static void *allocate(void *userdata, void *pointer, size_t old_size, size_t size) {
  ce_handle *h = userdata; if (!pointer) old_size = 0;
  if (size == 0) { free(pointer); h->memory -= old_size; return NULL; }
  if (old_size > h->memory || size > CE_VM_LIMIT || h->memory - old_size > CE_VM_LIMIT - size) return NULL;
  void *new_pointer = realloc(pointer, size);
  if (new_pointer) h->memory = h->memory - old_size + size;
  return new_pointer;
}
static FILE *open_source(const char *path) {
#ifdef _WIN32
  wchar_t wide[32768]; if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, 32768)) return NULL;
  return _wfopen(wide, L"rb");
#else
  return fopen(path, "rb");
#endif
}
static int load_sources(ce_handle *h, const char *root) {
  if (strlen(root) > 8192) return 0;
  for (int i = 0; i < CE_CORE_COUNT; ++i) {
    char path[8300];
    int length = snprintf(path, sizeof(path), "%s/%s", root, core_sources[i].path);
    if (length < 0 || (size_t)length >= sizeof(path)) return 0;
    FILE *file = open_source(path); if (!file) return 0;
    if (fseek(file, 0, SEEK_END)) { fclose(file); return 0; }
    long size = ftell(file); if (size < 0 || (unsigned long)size > CE_LIMIT || fseek(file, 0, SEEK_SET)) { fclose(file); return 0; }
    h->modules[i].source = malloc((size_t)size + 1); h->modules[i].size = (size_t)size; h->modules[i].name = core_sources[i].name;
    if (!h->modules[i].source) { fclose(file); return 0; }
    size_t read = fread(h->modules[i].source, 1, (size_t)size, file); int error = ferror(file); fclose(file);
    if (read != (size_t)size || error) return 0;
    h->modules[i].source[size] = 0;
  }
  return 1;
}
static void sources_free(ce_handle *h) { for (int i = 0; i < CE_CORE_COUNT; ++i) { free(h->modules[i].source); h->modules[i].source = NULL; } }
static int invoke(lua_State *state);
static int bootstrap(lua_State *state) {
  ce_handle *h = active_get(); ce_lua51 *a = &h->api;
  a->openlibs(state); a->getfield(state, CE_LUA_GLOBALS, "_VERSION");
  const char *version = a->tolstring(state, -1, NULL);
  if (!version || strcmp(version, "Lua 5.1")) { a->pushlstring(state, "Expected Lua 5.1 runtime", 24); return a->error(state); }
  a->settop(state, 0); a->getfield(state, CE_LUA_GLOBALS, "package"); a->getfield(state, -1, "preload");
  for (int i = 0; i < CE_CORE_COUNT; ++i) {
    const char *name = h->modules[i].name;
    if (a->loadbuffer(state, h->modules[i].source, h->modules[i].size, name)) return a->error(state);
    a->setfield(state, -2, name);
  }
  a->settop(state, 0); a->getfield(state, CE_LUA_GLOBALS, "require");
  a->pushlstring(state, "command_environment.core.bridge", 31);
  if (a->pcall(state, 1, 1, 0)) return a->error(state);
  a->settop(state, 0); a->getfield(state, CE_LUA_GLOBALS, "ce_bridge_init"); a->pushlstring(state, h->scope, strlen(h->scope));
  if (a->pcall(state, 1, 0, 0)) return a->error(state);
  // Allocate the dispatch closure while protected and retain it. Later calls
  // reuse it instead of allocating a C closure outside pcall at the VM limit.
  a->pushcclosure(state, invoke, 0); a->setfield(state, -10000, "ce_native_invoke");
  return 0;
}
static int invoke(lua_State *state) {
  ce_handle *h = active_get(); ce_lua51 *a = &h->api;
  a->getfield(state, CE_LUA_GLOBALS, "ce_bridge");
  a->pushlstring(state, h->operation, strlen(h->operation)); a->pushlstring(state, h->input, h->input_size);
  if (a->pcall(state, 2, 1, 0)) return a->error(state);
  return 1;
}
CE_API uint32_t ce_abi_version(void) { return 1; }
CE_API void ce_free(void *buffer) { free(buffer); }
CE_API int ce_create(const char *library, const char *root, ce_handle **output, char **error, size_t *error_size) {
  if (!output || !error || !error_size) return CE_ARGUMENT;
  *output = NULL; *error = NULL; *error_size = 0;
  if (!library || !*library || !root || !*root) return failed(CE_ARGUMENT, "Runtime and Lua root must be explicit UTF-8 paths", error, error_size);
  ce_handle *h = calloc(1, sizeof(*h)); if (!h) return CE_MEMORY;
#ifdef _WIN32
  h->owner = GetCurrentThreadId(); unsigned long process = GetCurrentProcessId();
#else
  h->owner = pthread_self(); unsigned long process = (unsigned long)getpid();
#endif
  snprintf(h->scope, sizeof(h->scope), "ce:%lu:%ld", process, next_serial());
  h->library = ce_library_open(library);
  if (!h->library || !ce_lua51_load(h->library, &h->api)) {
    if (h->library) ce_library_close(h->library);
    free(h);
    return failed(CE_RUNTIME, "Specified library does not provide the required Lua 5.1 C API", error, error_size);
  }
  if (!load_sources(h, root)) { sources_free(h); ce_library_close(h->library); free(h); return failed(CE_SCRIPT, "Could not read bounded core sources from the Lua root", error, error_size); }
  h->state = h->api.allocstate(allocate, h);
  if (!h->state) { sources_free(h); ce_library_close(h->library); free(h); return failed(CE_MEMORY, "Could not create bounded Lua state", error, error_size); }
  ce_handle *previous = active_get(); active_set(h);
  h->api.pushcclosure(h->state, bootstrap, 0); int status = h->api.pcall(h->state, 0, 0, 0); active_set(previous);
  if (status) {
    size_t size = 0; const char *message = h->api.tolstring(h->state, -1, &size);
    int copied = output_copy(message ? message : "Core initialization failed", message ? size : 26, error, error_size);
    h->api.close(h->state); sources_free(h); ce_library_close(h->library); free(h); return copied == CE_OK ? CE_SCRIPT : copied;
  }
  sources_free(h); *output = h; return CE_OK;
}
CE_API int ce_call(ce_handle *h, const char *operation, const char *json, size_t size, char **output, size_t *output_size, char **error, size_t *error_size) {
  if (!output || !output_size || !error || !error_size) return CE_ARGUMENT;
  *output = NULL; *output_size = 0; *error = NULL; *error_size = 0;
  if (!h || !operation || !*operation || strlen(operation) > 64 || !json || size > CE_LIMIT) return failed(CE_ARGUMENT, "Invalid handle, operation or bounded JSON input", error, error_size);
  if (!owned(h)) return failed(CE_THREAD, "Use the engine's owner thread", error, error_size);
  if (!acquire(&h->busy)) return failed(CE_BUSY, "Engine is busy", error, error_size);
  ce_handle *previous = active_get(); active_set(h);
  h->operation = operation; h->input = json; h->input_size = size;
  h->api.settop(h->state, 0); h->api.getfield(h->state, -10000, "ce_native_invoke");
  int status = h->api.pcall(h->state, 0, 1, 0); active_set(previous);
  size_t result_size = 0; const char *result = h->api.tolstring(h->state, -1, &result_size);
  int code;
  if (status || !result) code = failed(CE_SCRIPT, result ? result : "Core did not return a JSON result", error, error_size);
  else code = output_copy(result, result_size, output, output_size);
  h->api.settop(h->state, 0); h->operation = h->input = NULL; release(&h->busy); return code;
}
CE_API int ce_destroy(ce_handle *h) {
  if (!h) return CE_OK;
  if (!acquire(&h->busy)) return CE_BUSY;
  h->api.close(h->state); ce_library_close(h->library); free(h); return CE_OK;
}

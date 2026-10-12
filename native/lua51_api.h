#ifndef CE_LUA51_API_H
#define CE_LUA51_API_H
#include <stddef.h>
/* The documented Lua 5.1 ABI, loaded from a caller-specified existing runtime.
 * No Lua structure layout, interpreter source or Neovim API is required. */
typedef struct lua_State lua_State;
typedef void *(*ce_lua_alloc)(void *, void *, size_t, size_t);
typedef int (*ce_lua_function)(lua_State *);
typedef struct {
  lua_State *(*newstate)(void);
  lua_State *(*allocstate)(ce_lua_alloc, void *);
  void (*openlibs)(lua_State *);
  void (*close)(lua_State *);
  int (*loadfile)(lua_State *, const char *);
  int (*loadbuffer)(lua_State *, const char *, size_t, const char *);
  int (*pcall)(lua_State *, int, int, int);
  const char *(*tolstring)(lua_State *, int, size_t *);
  void (*settop)(lua_State *, int);
  void (*getfield)(lua_State *, int, const char *);
  void (*setfield)(lua_State *, int, const char *);
  void (*pushlstring)(lua_State *, const char *, size_t);
  void (*createtable)(lua_State *, int, int);
  void (*rawseti)(lua_State *, int, int);
  int (*type)(lua_State *, int);
  void (*pushcclosure)(lua_State *, ce_lua_function, int);
  int (*error)(lua_State *);
} ce_lua51;
#define CE_LUA_GLOBALS (-10002)
#ifdef _WIN32
#include <windows.h>
typedef HMODULE ce_library;
static ce_library ce_library_open(const char *path) {
  wchar_t wide[32768];
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, 32768)) return NULL;
  return LoadLibraryExW(wide, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
}
#define ce_symbol GetProcAddress
#define ce_library_close FreeLibrary
#else
#include <dlfcn.h>
typedef void *ce_library;
#define ce_library_open(p) dlopen((p), RTLD_NOW | RTLD_LOCAL)
#define ce_symbol dlsym
#define ce_library_close dlclose
#endif
static int ce_lua51_load(ce_library lib, ce_lua51 *api) {
#define CE_LOAD(member, symbol) do { *(void **)(&api->member) = (void *)ce_symbol(lib, symbol); if (!api->member) return 0; } while (0)
  CE_LOAD(newstate, "luaL_newstate"); CE_LOAD(openlibs, "luaL_openlibs");
  CE_LOAD(allocstate, "lua_newstate");
  CE_LOAD(close, "lua_close"); CE_LOAD(loadfile, "luaL_loadfile");
  CE_LOAD(loadbuffer, "luaL_loadbuffer"); CE_LOAD(pcall, "lua_pcall");
  CE_LOAD(tolstring, "lua_tolstring"); CE_LOAD(settop, "lua_settop");
  CE_LOAD(getfield, "lua_getfield"); CE_LOAD(setfield, "lua_setfield");
  CE_LOAD(pushlstring, "lua_pushlstring"); CE_LOAD(createtable, "lua_createtable");
  CE_LOAD(rawseti, "lua_rawseti"); CE_LOAD(type, "lua_type");
  CE_LOAD(pushcclosure, "lua_pushcclosure"); CE_LOAD(error, "lua_error");
#undef CE_LOAD
  return 1;
}
#endif

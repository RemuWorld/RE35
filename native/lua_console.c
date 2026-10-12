#include "lua51_api.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: lua-console <Lua 5.1 runtime library> <script> [args]\n"); return 2; }
  ce_library lib = ce_library_open(argv[1]); ce_lua51 api;
  if (!lib || !ce_lua51_load(lib, &api)) { fprintf(stderr, "Could not load the Lua 5.1 C API from the specified runtime\n"); if (lib) ce_library_close(lib); return 2; }
  lua_State *state = api.newstate();
  if (!state) { ce_library_close(lib); return 2; }
  api.openlibs(state);
  api.getfield(state, CE_LUA_GLOBALS, "_VERSION");
  const char *version = api.tolstring(state, -1, NULL);
  if (!version || strcmp(version, "Lua 5.1")) { fprintf(stderr, "Runtime must implement Lua 5.1\n"); api.close(state); ce_library_close(lib); return 2; }
  api.settop(state, 0);
  api.createtable(state, argc - 3, 0);
  for (int i = 2; i < argc; ++i) { api.pushlstring(state, argv[i], strlen(argv[i])); api.rawseti(state, -2, i - 2); }
  api.setfield(state, CE_LUA_GLOBALS, "arg");
  int status = api.loadfile(state, argv[2]);
  if (!status) status = api.pcall(state, 0, 0, 0);
  if (status) { const char *error = api.tolstring(state, -1, NULL); fprintf(stderr, "%s\n", error ? error : "Lua execution failed"); }
  api.close(state); ce_library_close(lib); return status ? 1 : 0;
}

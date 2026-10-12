/* Bounded FIFO transport for desktop hosts without a native FFI dependency.
 * One request is operation<TAB>JSON<LF>; one response is JSON<LF>.
 * Paths and the runtime are supplied by the host, never discovered/downloaded.
 */
#include "ce.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
static char *utf8_argument(const wchar_t *value) {
  int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, NULL, 0, NULL, NULL);
  if (length <= 0 || length > 262144) return NULL;
  char *result = (char *)malloc((size_t)length);
  if (result && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result, length, NULL, NULL)) {
    free(result); return NULL;
  }
  return result;
}
#endif
#define CE_FRAME_MAX (1048576u + 65u)
#ifdef _WIN32
int wmain(int argc, wchar_t **argv) {
#else
int main(int argc, char **argv) {
#endif
  ce_handle *handle = NULL;
  char *error = NULL;
  size_t error_size = 0;
  if (argc != 3) {
    fprintf(stderr, "usage: ce_stdio <Lua 5.1 runtime library> <absolute Lua directory>\n");
    return 2;
  }
#ifdef _WIN32
  if (_setmode(_fileno(stdin), _O_BINARY) == -1 || _setmode(_fileno(stdout), _O_BINARY) == -1) return 2;
#endif
#ifdef _WIN32
  char *utf8_runtime = utf8_argument(argv[1]);
  char *utf8_core = utf8_argument(argv[2]);
  if (!utf8_runtime || !utf8_core) { free(utf8_runtime); free(utf8_core); return 2; }
  const char *runtime = utf8_runtime, *core = utf8_core;
#else
  const char *runtime = argv[1], *core = argv[2];
#endif
  int status = ce_create(runtime, core, &handle, &error, &error_size);
#ifdef _WIN32
  free(utf8_runtime); free(utf8_core);
#endif
  if (status != CE_OK) {
    fprintf(stderr, "Could not initialize the configured core runtime (%d)\n", status);
    ce_free(error);
    return 2;
  }
  ce_free(error);
  char *frame = (char *)malloc(CE_FRAME_MAX + 1u);
  if (!frame) { ce_destroy(handle); return 2; }
  int exit_code = 0;
  for (;;) {
    size_t length = 0;
    int character;
    while ((character = fgetc(stdin)) != EOF && character != '\n') {
      if (character == 0 || length >= CE_FRAME_MAX) { exit_code = 2; goto finish; }
      frame[length++] = (char)character;
    }
    if (character == EOF) {
      if (length || ferror(stdin)) exit_code = 2;
      break;
    }
    if (length && frame[length - 1] == '\r') --length;
    frame[length] = '\0';
    char *separator = (char *)memchr(frame, '\t', length);
    if (!separator || separator == frame || (size_t)(separator - frame) > 64u) { exit_code = 2; break; }
    for (char *cursor = frame; cursor < separator; ++cursor) {
      if (!((*cursor >= 'a' && *cursor <= 'z') || *cursor == '_')) { exit_code = 2; goto finish; }
    }
    *separator = '\0';
    char *output = NULL;
    size_t output_size = 0;
    error = NULL; error_size = 0;
    status = ce_call(handle, frame, separator + 1, length - (size_t)(separator + 1 - frame),
      &output, &output_size, &error, &error_size);
    if (status != CE_OK) {
      /* An allocation/transport failure may invalidate the VM. Stop rather
       * than attach a later response to the wrong host request. */
      ce_free(output); ce_free(error); exit_code = 2; break;
    }
    int written = output && output_size <= 1048576u
      && fwrite(output, 1, output_size, stdout) == output_size && fputc('\n', stdout) != EOF && fflush(stdout) == 0;
    ce_free(output); ce_free(error);
    if (!written) { exit_code = 2; break; }
  }
finish:
  free(frame);
  ce_destroy(handle);
  if (exit_code) fprintf(stderr, "Core transport closed after an invalid or failed frame\n");
  return exit_code;
}

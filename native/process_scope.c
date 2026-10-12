/* Optional host process owner. No Lua/core dependency, shell, or installer.
 * A child never runs before it belongs to the owned Job/session group. */
#ifndef _WIN32
#define _GNU_SOURCE
#elif !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0A00
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <io.h>
#include <fcntl.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <dirent.h>
#include <mntent.h>
#endif

typedef struct {
  int code, signal, cancelled, forced, confirmed, detached;
  const char *scope, *error;
} Report;
#ifdef _WIN32
static wchar_t *wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
  wchar_t *w = n ? calloc((size_t)n, sizeof(*w)) : NULL;
  if (w && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n)) { free(w); return NULL; }
  return w;
}
static uint64_t millis(void) { return GetTickCount64(); }
#else
static uint64_t millis(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}
#endif
static int report(const char *path, const Report *r) {
  FILE *f;
#ifdef _WIN32
  wchar_t *w = wide(path);
  if (!w) return 0;
  f = _wfopen(w, L"wb"); free(w);
#else
  f = fopen(path, "wb");
#endif
  if (!f) return 0;
  fprintf(f, "{\"version\":1,\"scope\":\"%s\",\"exit_code\":%d,\"signal\":%d,"
    "\"cancelled\":%s,\"forced\":%s,\"termination_confirmed\":%s,"
    "\"detached_observed\":%d,\"error\":\"%s\"}\n", r->scope, r->code, r->signal,
    r->cancelled ? "true" : "false", r->forced ? "true" : "false", r->confirmed ? "true" : "false",
    r->detached, r->error);
  return fclose(f) == 0;
}

#ifdef _WIN32
#ifdef CE_PROCESS_TEST_LAUNCH_PAUSE
static const char *launch_probe_path;
static void launch_pause(DWORD child_pid) {
  wchar_t *w = wide(launch_probe_path);
  FILE *f = w ? _wfopen(w, L"wb") : NULL;
  free(w);
  if (f) { fprintf(f, "{\"phase\":\"created_suspended_in_job\",\"pid\":%lu}\n", (unsigned long)child_pid); fclose(f); }
  Sleep(5000); /* Explicit compile-time fault probe only, absent from CMake. */
}
#endif
/* Quote for the Windows C argv convention, preserving empty args and slashes.
 * Executable name is also quoted; this is never evaluated by cmd/PowerShell. */
static wchar_t *commandline(char **args) {
  size_t size = 1, at = 0;
  for (int i = 0; args[i]; ++i) size += strlen(args[i]) * 2 + 4;
  wchar_t *out = calloc(size, sizeof(*out));
  if (!out) return NULL;
  for (int i = 0; args[i]; ++i) {
    wchar_t *w = wide(args[i]);
    if (!w) { free(out); return NULL; }
    if (i) out[at++] = L' ';
    out[at++] = L'"';
    size_t slashes = 0;
    for (size_t j = 0;; ++j) {
      wchar_t c = w[j];
      if (c == L'\\') { ++slashes; continue; }
      size_t count = (c == L'"' || c == 0) ? slashes * 2 : slashes;
      while (count--) out[at++] = L'\\';
      slashes = 0;
      if (!c) break;
      if (c == L'"') out[at++] = L'\\';
      out[at++] = c;
    }
    out[at++] = L'"'; free(w);
  }
  out[at] = 0;
  return out;
}
static void drain(HANDLE input, FILE *output) {
  DWORD available, count;
  char buf[8192];
  /* Limit each pass so a noisy child cannot starve cancellation control. */
  for (int i = 0; i < 16 && PeekNamedPipe(input, NULL, 0, NULL, &available, NULL) && available; ++i) {
    if (!ReadFile(input, buf, available < sizeof(buf) ? available : sizeof(buf), &count, NULL) || !count) break;
    fwrite(buf, 1, count, output); fflush(output);
  }
}
static Report run(char **args, unsigned grace) {
  (void)grace; /* Windows advertises atomic Job stop, not POSIX signals. */
  Report r = {125, 0, 0, 0, 0, -1, "windows_job", "Job setup failed before tool start"};
  HANDLE job = NULL, out_read = NULL, out_write = NULL, err_read = NULL, err_write = NULL, nul = NULL;
  PROCESS_INFORMATION pi = {0}; STARTUPINFOEXW si = {0};
  wchar_t *cmd = commandline(args); SIZE_T bytes = 0; int attributes_ready = 0;
  SECURITY_ATTRIBUTES inherit = {sizeof(inherit), NULL, TRUE};
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  HANDLE inherited[3];
  job = CreateJobObjectW(NULL, NULL);
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!job || !cmd || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))
      || !CreatePipe(&out_read, &out_write, &inherit, 0) || !CreatePipe(&err_read, &err_write, &inherit, 0)) goto cleanup;
  if (!SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0) || !SetHandleInformation(err_read, HANDLE_FLAG_INHERIT, 0)) goto cleanup;
  nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, NULL);
  if (nul == INVALID_HANDLE_VALUE) { nul = NULL; goto cleanup; }
  inherited[0] = nul; inherited[1] = out_write; inherited[2] = err_write;
  InitializeProcThreadAttributeList(NULL, 2, 0, &bytes);
  si.lpAttributeList = malloc(bytes);
  if (!si.lpAttributeList || !InitializeProcThreadAttributeList(si.lpAttributeList, 2, 0, &bytes)) goto cleanup;
  attributes_ready = 1;
  if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      inherited, sizeof(inherited), NULL, NULL)) goto cleanup;
  /* Windows 10+/Server 2016+: assign at creation, including the suspended
   * interval. Helper death can never leave a created child outside the Job. */
  if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
      &job, sizeof(job), NULL, NULL)) { r.error = "Atomic Job creation is unsupported"; goto cleanup; }
  si.StartupInfo.cb = sizeof(si); si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  si.StartupInfo.hStdInput = nul; si.StartupInfo.hStdOutput = out_write; si.StartupInfo.hStdError = err_write;
  if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
      NULL, NULL, &si.StartupInfo, &pi)) { r.error = "Executable could not be created"; goto cleanup; }
  BOOL attached = FALSE;
  if (!IsProcessInJob(pi.hProcess, job, &attached) || !attached) {
    r.error = "Created tool is not in its owned Job";
    TerminateProcess(pi.hProcess, 125); WaitForSingleObject(pi.hProcess, 2000); goto cleanup;
  }
#ifdef CE_PROCESS_TEST_LAUNCH_PAUSE
  launch_pause(pi.dwProcessId);
#endif
  if (ResumeThread(pi.hThread) == (DWORD)-1) {
    TerminateProcess(pi.hProcess, 125); WaitForSingleObject(pi.hProcess, 2000); goto cleanup;
  }
  CloseHandle(out_write); out_write = NULL; CloseHandle(err_write); err_write = NULL;
  r.error = "";
  int root_exited = 0, stopping = 0, failed = 0;
  uint64_t deadline = 0;
  HANDLE control = GetStdHandle(STD_INPUT_HANDLE);
  for (;;) {
    drain(out_read, stdout); drain(err_read, stderr);
    DWORD available = 0, count = 0; char input[64];
    BOOL control_ok = PeekNamedPipe(control, NULL, 0, NULL, &available, NULL);
    if (control_ok && available && ReadFile(control, input, available < sizeof(input) ? available : sizeof(input), &count, NULL)) {
      for (DWORD i = 0; i < count; ++i) if (input[i] == 'c' || input[i] == 'f') {
        r.cancelled = 1; if (input[i] == 'f') r.forced = 1;
        if (!stopping) {
          if (!TerminateJobObject(job, 130)) failed = 1;
          stopping = 1; deadline = millis() + 2000;
        }
      }
    } else if (!control_ok && !stopping && GetLastError() == ERROR_BROKEN_PIPE) {
      r.cancelled = 1; if (!TerminateJobObject(job, 130)) failed = 1;
      stopping = 1; deadline = millis() + 2000;
    }
    if (!root_exited && WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) {
      DWORD code = 125; GetExitCodeProcess(pi.hProcess, &code); r.code = (int)code; root_exited = 1;
      /* A successful parent must not leave build children behind. */
      if (!stopping) {
        if (!TerminateJobObject(job, 130)) failed = 1;
        stopping = 1; deadline = millis() + 2000;
      }
    }
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
    if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &accounting, sizeof(accounting), NULL)) {
      failed = 1; r.error = "Job termination query failed"; break;
    }
    if (stopping && root_exited && accounting.ActiveProcesses == 0) { r.confirmed = !failed; break; }
    if (stopping && millis() >= deadline) { r.error = "Job termination not confirmed before deadline"; break; }
    Sleep(10);
  }
  drain(out_read, stdout); drain(err_read, stderr);
cleanup:
  if (job) CloseHandle(job); /* KILL_ON_JOB_CLOSE also protects helper crashes. */
  if (pi.hThread) CloseHandle(pi.hThread);
  if (pi.hProcess) CloseHandle(pi.hProcess);
  if (attributes_ready) DeleteProcThreadAttributeList(si.lpAttributeList);
  free(si.lpAttributeList);
  if (out_read) CloseHandle(out_read);
  if (out_write) CloseHandle(out_write);
  if (err_read) CloseHandle(err_read);
  if (err_write) CloseHandle(err_write);
  if (nul) CloseHandle(nul);
  free(cmd);
  return r;
}
#else
typedef struct { int code, signal; } Exit;
static void owner_lost(int sig) {
  (void)sig;
  /* This handler runs in the still-owned session anchor. kill(0) cannot target
   * a reused numeric PID and includes the anchor itself in the final stop. */
  kill(0, SIGKILL);
  _exit(125);
}
/* Each private blocking pipe carries one record no larger than PIPE_BUF.
 * Such writes are atomic; a short record is a failure, never a partial success.
 * Bound interruptions so a damaged handoff cannot keep the group owner alive. */
static int write_record(int output, const void *value, size_t size) {
  if (!size || size > PIPE_BUF) return 0;
  for (int attempt = 0; attempt < 16; ++attempt) {
    ssize_t count = write(output, value, size);
    if (count == (ssize_t)size) return 1;
    if (count < 0 && errno == EINTR) continue;
    return 0;
  }
  return 0;
}
#if defined(CE_PROCESS_TEST_READY_WRITE_FAIL) || defined(CE_PROCESS_TEST_RESULT_WRITE_FAIL)
/* Explicit test builds only: an actual closed-reader pipe produces EPIPE and
 * SIGPIPE. Keep the real handoff writer open until owner_lost stops the group. */
static int broken_record_pipe(void) {
  int fd[2];
  if (pipe(fd)) owner_lost(SIGUSR1);
  close(fd[0]);
  return fd[1];
}
#endif
#if defined(CE_PROCESS_TEST_READY_WRITE_FAIL) || defined(CE_PROCESS_TEST_NONBLOCK_FAIL)
static void await_test_parent(char **args) {
  /* The owned process_tree fixture passes its output directory as argv[3].
   * Wait for its existing marker, never delay a production handoff. */
  char path[4096];
  if (!args[0] || !args[1] || !args[2] || !args[3]) owner_lost(SIGUSR1);
  int length = snprintf(path, sizeof(path), "%s/parent-ready", args[3]);
  if (length < 0 || (size_t)length >= sizeof(path)) owner_lost(SIGUSR1);
  uint64_t deadline = millis() + 5000;
  while (access(path, F_OK)) {
    if (errno != ENOENT || millis() >= deadline) owner_lost(SIGUSR1);
    usleep(10000);
  }
}
#endif
static void drain(int input, int output) {
  char buf[8192]; ssize_t n;
  for (int i = 0; i < 16 && (n = read(input, buf, sizeof(buf))) > 0; ++i) {
    ssize_t at = 0;
    while (at < n) { ssize_t written = write(output, buf + at, (size_t)(n - at)); if (written <= 0) return; at += written; }
  }
}
/* /proc lets us distinguish live group members from zombies and observe
 * deliberately detached children adopted by the Linux subreaper. */
static int visible_proc(uint64_t deadline);
static int members(pid_t group, pid_t owner, int *detached) {
  unsigned seen = 0; uint64_t deadline = millis() + 250;
  if (!visible_proc(deadline)) return -1;
  DIR *dir = opendir("/proc"); struct dirent *entry; int live = 0;
  *detached = 0;
  if (!dir) return -1;
  for (;;) {
    errno = 0;
    entry = readdir(dir);
    if (!entry) { int failure = errno; closedir(dir); return failure ? -1 : live; }
    if (++seen > 65536 || millis() >= deadline) { closedir(dir); return -1; }
    char *end; long id = strtol(entry->d_name, &end, 10);
    if (!id || *end) continue;
    char path[96], buf[4096], state; long parent, pgid;
    snprintf(path, sizeof(path), "/proc/%ld/stat", id);
    FILE *f = fopen(path, "r");
    if (!f) {
      if (errno == ENOENT || errno == ESRCH) continue;
      closedir(dir); return -1;
    }
    errno = 0;
    char *got = fgets(buf, sizeof(buf), f); int failure = errno; fclose(f);
    if (!got) {
      if (failure == ENOENT || failure == ESRCH) continue;
      closedir(dir); return -1;
    }
    char *last = strrchr(buf, ')');
    if (!last || sscanf(last + 1, " %c %ld %ld", &state, &parent, &pgid) != 3) { closedir(dir); return -1; }
    if (pgid == group && state != 'Z' && state != 'X') ++live;
    if (parent == owner && pgid != group && state != 'Z' && state != 'X') ++*detached;
  }
}
static int visible_proc(uint64_t deadline) {
  char self_buf[4096], state; long parent, group;
  FILE *self = fopen("/proc/self/stat", "r");
  if (!self) return 0;
  char *got = fgets(self_buf, sizeof(self_buf), self); fclose(self);
  char *last = got ? strrchr(self_buf, ')') : NULL;
  if (!last || strtol(self_buf, NULL, 10) != (long)getpid()
      || sscanf(last + 1, " %c %ld %ld", &state, &parent, &group) != 3 || group != (long)getpgrp()) return 0;
  FILE *mounts = setmntent("/proc/self/mounts", "r"); struct mntent *mount;
  int visible = 0; unsigned seen = 0;
  if (!mounts) return 0;
  while ((mount = getmntent(mounts))) {
    if (++seen > 65536 || millis() >= deadline) { visible = 0; break; }
    if (!strcmp(mount->mnt_dir, "/proc")) {
      char *hidden = hasmntopt(mount, "hidepid");
      if (strcmp(mount->mnt_type, "proc") || (hidden &&
          (strncmp(hidden, "hidepid=0", 9) || (hidden[9] != ',' && hidden[9] != '\0')))) { visible = 0; break; }
      visible = 1; /* Every matching stacked mount must be unrestricted. */
    }
  }
  if (ferror(mounts)) visible = 0;
  endmntent(mounts); return visible;
}
static int nonblocking(int fd) {
#ifdef CE_PROCESS_TEST_NONBLOCK_FAIL
  if (fd == STDIN_FILENO) { errno = EBADF; return 0; }
#endif
  int flags = fcntl(fd, F_GETFL); return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}
static Report run(char **args, unsigned grace) {
  Report r = {125, 0, 0, 0, 0, 0, "linux_group", "Session setup failed before tool start"};
  int result[2], ready[2], out[2], err[2]; pid_t anchor, owner = getpid();
  if (!visible_proc(millis() + 250)) { r.error = "Unrestricted proc visibility is required for owned scope evidence"; return r; }
  if (prctl(PR_SET_CHILD_SUBREAPER, 1) || pipe(result) || pipe(ready) || pipe(out) || pipe(err)) return r;
  anchor = fork();
  if (anchor < 0) return r;
  if (anchor == 0) {
    close(result[0]); close(ready[0]); close(out[0]); close(err[0]);
    if (setsid() < 0) _exit(125);
    struct sigaction lost;
    memset(&lost, 0, sizeof(lost)); lost.sa_handler = owner_lost; sigemptyset(&lost.sa_mask);
    if (sigaction(SIGUSR1, &lost, NULL) || prctl(PR_SET_PDEATHSIG, SIGUSR1)) _exit(125);
    if (getppid() != owner) owner_lost(SIGUSR1);
    /* A broken handoff must reach checked cleanup rather than terminate only
     * the anchor. The actual tool restores SIGPIPE to its default below. */
    lost.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &lost, NULL)) _exit(125);
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN);
    pid_t root = fork();
    if (root < 0) _exit(125);
    if (root == 0) {
      close(result[1]); close(ready[1]);
      signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_DFL); signal(SIGUSR1, SIG_DFL);
      int nul = open("/dev/null", O_RDONLY);
      if (nul < 0 || dup2(nul, STDIN_FILENO) < 0 || dup2(out[1], STDOUT_FILENO) < 0 || dup2(err[1], STDERR_FILENO) < 0) _exit(125);
      if (nul > 2) close(nul);
      close(out[1]); close(err[1]);
      execvp(args[0], args); perror("RE35 executable could not be created"); _exit(127);
    }
    close(out[1]); close(err[1]); close(STDIN_FILENO);
    char mark = 'r';
    int ready_output = ready[1];
#if defined(CE_PROCESS_TEST_READY_WRITE_FAIL) || defined(CE_PROCESS_TEST_NONBLOCK_FAIL)
    await_test_parent(args);
#endif
#ifdef CE_PROCESS_TEST_READY_WRITE_FAIL
    ready_output = broken_record_pipe();
#endif
    if (!write_record(ready_output, &mark, sizeof(mark))) owner_lost(SIGUSR1);
    close(ready[1]);
    int status = 0;
    while (waitpid(root, &status, 0) < 0) if (errno != EINTR) owner_lost(SIGUSR1);
    Exit value = {WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status), WIFSIGNALED(status) ? WTERMSIG(status) : 0};
    int result_output = result[1];
#ifdef CE_PROCESS_TEST_RESULT_WRITE_FAIL
    result_output = broken_record_pipe();
#endif
    if (!write_record(result_output, &value, sizeof(value))) owner_lost(SIGUSR1);
    close(result[1]);
    for (;;) pause(); /* Pins the group ID, including after the tool parent exits. */
  }
  close(result[1]); close(ready[1]); close(out[1]); close(err[1]);
  char mark = 0; ssize_t count;
  do { count = read(ready[0], &mark, 1); } while (count < 0 && errno == EINTR);
  close(ready[0]);
  if (count != 1 || mark != 'r') {
    r.error = "Session readiness handoff failed";
    /* The child PID remains unreaped while signalling, so it cannot be reused. */
    kill(anchor, SIGKILL); waitpid(anchor, NULL, 0);
    close(result[0]); close(out[0]); close(err[0]); return r;
  }
  if (!nonblocking(STDIN_FILENO) || !nonblocking(result[0]) || !nonblocking(out[0]) || !nonblocking(err[0])) {
    r.error = "Nonblocking owner control setup failed";
    int signal_ok = kill(-anchor, SIGKILL) == 0 || errno == ESRCH;
    uint64_t stop_deadline = millis() + 2000;
    while (millis() < stop_deadline) {
      int live = members(anchor, getpid(), &r.detached);
      if (live == 0) { r.confirmed = signal_ok; break; }
      if (live < 0) break;
      usleep(10000);
    }
    /* Cleanup signal occurred while the anchor PID was still pinned. */
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    close(result[0]); close(out[0]); close(err[0]); return r;
  }
  r.error = "";
  int stopped = 0, killed = 0, root_exited = 0, signal_failed = 0, cancelled_anchor_exit = 0;
  uint64_t deadline = 0, finish_deadline = 0;
  for (;;) {
    struct pollfd fds[4] = {{STDIN_FILENO, POLLIN | POLLHUP, 0}, {result[0], POLLIN | POLLHUP, 0},
      {out[0], POLLIN, 0}, {err[0], POLLIN, 0}};
    poll(fds, 4, 10); drain(out[0], STDOUT_FILENO); drain(err[0], STDERR_FILENO);
    char input[64]; ssize_t n = read(STDIN_FILENO, input, sizeof(input));
    int request = n == 0 ? 1 : 0, force = 0;
    for (ssize_t i = 0; i < n; ++i) { if (input[i] == 'c' || input[i] == 'f') request = 1; if (input[i] == 'f') force = 1; }
    if (request) r.cancelled = 1;
    if (force) { r.forced = 1; deadline = millis(); }
    Exit value;
    if (!root_exited && read(result[0], &value, sizeof(value)) == (ssize_t)sizeof(value)) {
      r.code = value.code; r.signal = value.signal; root_exited = 1;
    }
    siginfo_t anchor_status;
    memset(&anchor_status, 0, sizeof(anchor_status));
    if (!root_exited && waitid(P_PID, (id_t)anchor, &anchor_status, WEXITED | WNOHANG | WNOWAIT) == 0 && anchor_status.si_pid) {
      r.error = "Session anchor exited before command result"; root_exited = 1; r.code = 125;
      /* Force kills the pinned anchor as well as the tool. Its result pipe can
       * lose that race; this is expected only for our requested forced stop.
       * Keep exit_code=125/signal=0 as unavailable-root evidence and clear the
       * transport error only after every owned group member is proved gone. */
      cancelled_anchor_exit = killed && r.cancelled && r.forced;
    }
    if ((request || root_exited) && !stopped) {
      /* The unreaped anchor pins this PID/PGID even if externally killed.
       * Never reap it before the final signal; never signal again afterward. */
      if (kill(-anchor, SIGTERM) && errno != ESRCH) signal_failed = 1;
      stopped = 1; deadline = millis() + grace;
    }
    if (stopped && !killed) {
      int detached = 0, live = members(anchor, getpid(), &detached);
      /* A normal command with no descendants need not wait the whole grace. */
      if (live == 1 && root_exited) deadline = millis();
      if (millis() >= deadline) {
        if (live > 1) r.forced = 1;
        if (kill(-anchor, SIGKILL) && errno != ESRCH) signal_failed = 1;
        killed = 1; finish_deadline = millis() + 2000;
      }
    }
    if (killed) {
      int live = members(anchor, getpid(), &r.detached);
      if (live == 0) {
        r.confirmed = !signal_failed;
        if (signal_failed) r.error = "Owned group signalling failed";
        else if (cancelled_anchor_exit) r.error = "";
        break;
      }
      if (live < 0 || millis() >= finish_deadline) { r.error = "Group termination not confirmed before deadline"; break; }
    }
  }
  drain(out[0], STDOUT_FILENO); drain(err[0], STDERR_FILENO);
  /* All signalling is finished before any child (especially anchor) is reaped. */
  while (waitpid(-1, NULL, WNOHANG) > 0) {}
  close(result[0]); close(out[0]); close(err[0]);
  return r;
}
#endif

int main(int argc, char **argv) {
#ifdef _WIN32
  /* Child pipes carry bytes. CRT text mode would turn every LF into CRLF,
   * changing both original output and the host's shared byte budget. */
  if (_setmode(_fileno(stdout), _O_BINARY) == -1 || _setmode(_fileno(stderr), _O_BINARY) == -1) return 125;
  int wide_count; wchar_t **wide_args = CommandLineToArgvW(GetCommandLineW(), &wide_count);
  if (!wide_args) return 125;
  argv = calloc((size_t)wide_count + 1, sizeof(*argv));
  if (!argv) { LocalFree(wide_args); return 125; }
  argc = wide_count;
  for (int i = 0; i < argc; ++i) {
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide_args[i], -1, NULL, 0, NULL, NULL);
    argv[i] = n ? malloc((size_t)n) : NULL;
    if (!argv[i] || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide_args[i], -1, argv[i], n, NULL, NULL)) return 125;
  }
  LocalFree(wide_args);
#endif
  if (argc < 7 || strcmp(argv[1], "--status") || strcmp(argv[3], "--grace-ms") || strcmp(argv[5], "--")) return 125;
  char *end; unsigned long grace = strtoul(argv[4], &end, 10);
  if (*end || grace < 1 || grace > 2147483647UL) return 125;
#if defined(_WIN32) && defined(CE_PROCESS_TEST_LAUNCH_PAUSE)
  launch_probe_path = argv[2];
#endif
  Report r = run(&argv[6], (unsigned)grace);
  return report(argv[2], &r) ? 0 : 125;
}

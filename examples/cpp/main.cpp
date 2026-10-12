#include "../../native/ce.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>
static int checks = 0;
static void check(bool value, const char *message) { if (!value) throw std::runtime_error(message); ++checks; }
class Host {
  ce_handle *handle = nullptr;
public:
  Host(const char *runtime, const char *root) {
    char *error = nullptr; size_t size = 0;
    int result = ce_create(runtime, root, &handle, &error, &size);
    std::string message = error ? std::string(error, size) : "Could not create engine"; ce_free(error);
    if (result != CE_OK) throw std::runtime_error(message);
  }
  ~Host() { if (handle) ce_destroy(handle); }
  Host(const Host &) = delete;
  Host &operator=(const Host &) = delete;
  std::string raw(const std::string &op, const std::string &input = "{}") {
    char *out = nullptr, *error = nullptr; size_t size = 0, error_size = 0;
    int result = ce_call(handle, op.c_str(), input.data(), input.size(), &out, &size, &error, &error_size);
    std::string value = result == CE_OK ? std::string(out, size) : error ? std::string(error, error_size) : "Native call failed";
    ce_free(out); ce_free(error); if (result != CE_OK) throw std::runtime_error(value); return value;
  }
  std::string call(const std::string &op, const std::string &input = "{}") {
    std::string reply = raw(op, input);
    if (reply.rfind("{\"ok\":true", 0) != 0) throw std::runtime_error(reply);
    return reply;
  }
};
// These helpers read the documented, canonical bridge envelope. Applications
// may use their existing JSON parser instead; no parser is imposed by the C ABI.
static std::string value_json(const std::string &reply) {
  size_t start = reply.find("\"value\":"); if (start == std::string::npos) throw std::runtime_error("Missing envelope value");
  return reply.substr(start + 8, reply.size() - start - 9);
}
static std::string request_id(const std::string &reply) {
  const std::string key = "\"request_id\":\""; size_t start = reply.find(key);
  if (start == std::string::npos) throw std::runtime_error("Missing request ID");
  start += key.size(); size_t end = reply.find('"', start);
  if (end == std::string::npos) throw std::runtime_error("Invalid request ID");
  return reply.substr(start, end - start);
}
static long amount(const std::string &request) {
  size_t start = request.find("\"amount\":"); if (start == std::string::npos) throw std::runtime_error("Missing amount");
  return std::stol(request.substr(start + 9));
}
static std::string target(long revision) { return "{\"token\":\"counter:1\",\"revision\":\"" + std::to_string(revision) + "\"}"; }
static std::string choose(Host &host, long revision) { return value_json(host.call("select", "{\"id\":\"inc\",\"target\":" + target(revision) + ",\"capabilities\":{\"counter\":true}}")); }
static std::string invoke(Host &host, const std::string &ticket, long n, long revision) {
  return host.raw("invoke", "{\"selection\":" + ticket + ",\"args\":{\"amount\":" + std::to_string(n) + "},\"target\":" + target(revision) + ",\"capabilities\":{\"counter\":true}}");
}
int main(int argc, char **argv) {
  try {
    if (argc != 4) throw std::runtime_error("usage: ce-cpp <Lua 5.1 runtime> <Lua root> <command fixture>");
    check(ce_abi_version() == 1, "C ABI version");
    std::ifstream file(std::filesystem::u8path(argv[3]), std::ios::binary);
    if (!file) throw std::runtime_error("Could not read command fixture");
    std::string fixture((std::istreambuf_iterator<char>(file)), {});
    Host host(argv[1], argv[2]); host.call("register", fixture);
    check(value_json(host.call("resolve", "{\"query\":\"inc\"}")) == "\"demo.increment\"", "Resolve alias");
    check(value_json(host.call("resolve", "{\"path\":[\"d\",\"i\"]}")) == "\"demo.increment\"", "Resolve tree");
    check(host.call("search", "{\"query\":\"증가\"}").find("demo.increment") != std::string::npos, "UTF-8 search");
    check(host.raw("register", fixture).find("\"ok\":false") != std::string::npos, "Reject duplicate registration");
    long counter = 0, revision = 1, executions = 0;
    std::string ticket = choose(host, revision);
    check(invoke(host, ticket, 0, revision).find("\"ok\":false") != std::string::npos, "Reject invalid amount");
    std::string effect = invoke(host, ticket, 3, revision), id = request_id(effect);
    std::string claimed = host.call("claim", "{\"request_id\":\"" + id + "\",\"target\":" + target(revision) + ",\"capabilities\":{\"counter\":true}}");
    counter += amount(claimed); ++revision; ++executions; // Actual C++ application action.
    check(counter == 3 && executions == 1, "Actual C++ handler");
    check(host.raw("claim", "{\"request_id\":\"" + id + "\",\"target\":" + target(revision) + "}").find("\"ok\":false") != std::string::npos, "Claim once");
    host.call("close_ui"); host.call("open_ui");
    std::string completion = "{\"request_id\":\"" + id + "\",\"completion\":{\"status\":\"succeeded\",\"result\":{\"counter\":3}}}";
    host.call("complete", completion);
    check(host.raw("complete", completion).find("\"ok\":false") != std::string::npos, "Complete once");
    check(host.call("snapshot").find("\"counter\":3") != std::string::npos, "Keep result after UI replacement");
    ticket = choose(host, revision);
    host.call("configure", "{\"aliases\":{\"plus\":\"demo.increment\"}}");
    check(invoke(host, ticket, 1, revision).find("\"ok\":false") != std::string::npos, "Reject stale selection");
    ticket = choose(host, revision); ++revision;
    check(invoke(host, ticket, 1, revision).find("\"ok\":false") != std::string::npos && executions == 1, "Reject stale target without side effects");
    ticket = choose(host, revision); id = request_id(invoke(host, ticket, 9, revision));
    claimed = host.call("claim", "{\"request_id\":\"" + id + "\",\"target\":" + target(revision) + ",\"capabilities\":{\"counter\":true}}");
    try { if (amount(claimed) == 9) throw std::runtime_error("Application action failed"); }
    catch (const std::exception &) { host.call("complete", "{\"request_id\":\"" + id + "\",\"completion\":{\"status\":\"failed\",\"result\":{\"message\":\"C++ exception\"}}}"); }
    check(host.call("snapshot").find("C++ exception") != std::string::npos && counter == 3, "Contain C++ exception");
    id = request_id(invoke(host, choose(host, revision), 1, revision));
    host.call("claim", "{\"request_id\":\"" + id + "\",\"target\":" + target(revision) + ",\"capabilities\":{\"counter\":true}}");
    host.call("cancel", "{\"request_id\":\"" + id + "\"}");
    check(host.call("snapshot").find("\"status\":\"pending\"") != std::string::npos, "Cancellation request remains pending");
    host.call("complete", "{\"request_id\":\"" + id + "\",\"completion\":{\"status\":\"cancelled\",\"result\":{\"partial\":\"stdout\"}}}");
    check(host.call("snapshot").find("\"partial\":\"stdout\"") != std::string::npos, "Keep partial cancellation result");
    bool wrong_thread = false;
    std::thread other([&]() { try { host.call("snapshot"); } catch (const std::exception &e) { wrong_thread = std::string(e.what()).find("owner thread") != std::string::npos; } }); other.join();
    check(wrong_thread, "Reject foreign thread"); host.call("snapshot");
    check(host.raw("snapshot", "{\"x\":[]}").find("\"ok\":true") != std::string::npos, "Transport empty array");
    check(host.raw("snapshot", "{bad json}").find("\"ok\":false") != std::string::npos, "Reject malformed JSON");
    id = request_id(invoke(host, choose(host, revision), 1, revision));
    host.call("claim", "{\"request_id\":\"" + id + "\",\"target\":" + target(revision) + ",\"capabilities\":{\"counter\":true}}");
    check(host.call("dispose").find(id) != std::string::npos, "Explicit resource detach on disposal");
    check(host.raw("complete", "{\"request_id\":\"" + id + "\",\"completion\":{\"status\":\"succeeded\"}}").find("\"ok\":false") != std::string::npos, "Reject late result after engine disposal");
    check(counter == 3 && executions == 1, "No hidden host execution");
    std::cout << "C++ host: " << checks << " checks PASS; actual counter=" << counter << "\n"; return 0;
  } catch (const std::exception &e) { std::cerr << e.what() << "\n"; return 1; }
}

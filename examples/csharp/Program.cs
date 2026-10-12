using System;
using System.IO;
using System.Text;
using System.Threading;
class Program
{
    private static int checks;
    static void Check(bool value, string message) { if (!value) throw new Exception(message); checks++; }
    // Canonical transport envelope helpers; consumers can choose their JSON library.
    static string Value(string reply) { int start = reply.IndexOf("\"value\":", StringComparison.Ordinal); if (start < 0) throw new Exception("Missing value"); return reply.Substring(start + 8, reply.Length - start - 9); }
    static string Request(string reply) { string key = "\"request_id\":\""; int start = reply.IndexOf(key, StringComparison.Ordinal) + key.Length; if (start < key.Length) throw new Exception("Missing request"); return reply.Substring(start, reply.IndexOf('"', start) - start); }
    static int Amount(string reply) { int start = reply.IndexOf("\"amount\":", StringComparison.Ordinal) + 9; if (start < 9) throw new Exception("Missing amount"); int end = start; while (end < reply.Length && char.IsDigit(reply[end])) end++; return int.Parse(reply.Substring(start, end - start)); }
    static string Target(int revision) { return "{\"token\":\"counter:1\",\"revision\":\"" + revision + "\"}"; }
    static string Select(CommandEnvironment host, int revision) { return Value(host.Call("select", "{\"id\":\"inc\",\"target\":" + Target(revision) + ",\"capabilities\":{\"counter\":true}}")); }
    static string Invoke(CommandEnvironment host, string ticket, int amount, int revision) { return host.Raw("invoke", "{\"selection\":" + ticket + ",\"args\":{\"amount\":" + amount + "},\"target\":" + Target(revision) + ",\"capabilities\":{\"counter\":true}}"); }
    static int Main(string[] args)
    {
        try
        {
            if (args.Length != 3) throw new Exception("usage: ce-csharp <Lua 5.1 library> <Lua root> <command fixture>");
            using (CommandEnvironment host = new CommandEnvironment(args[0], args[1]))
            {
                host.Call("register", File.ReadAllText(args[2], new UTF8Encoding(false, true)));
                Check(Value(host.Call("resolve", "{\"query\":\"inc\"}")) == "\"demo.increment\"", "Alias");
                Check(Value(host.Call("resolve", "{\"path\":[\"d\",\"i\"]}")) == "\"demo.increment\"", "Tree");
                Check(host.Call("search", "{\"query\":\"증가\"}").Contains("demo.increment"), "UTF-8 search");
                int counter = 0, revision = 1, executions = 0;
                string ticket = Select(host, revision);
                Check(Invoke(host, ticket, 0, revision).Contains("\"ok\":false"), "Invalid argument");
                string id = Request(Invoke(host, ticket, 3, revision));
                string claimed = host.Call("claim", "{\"request_id\":\"" + id + "\",\"target\":" + Target(revision) + ",\"capabilities\":{\"counter\":true}}");
                counter += Amount(claimed); revision++; executions++; // Actual managed application action.
                Check(counter == 3 && executions == 1, "Actual C# handler");
                Check(host.Raw("claim", "{\"request_id\":\"" + id + "\",\"target\":" + Target(revision) + "}").Contains("\"ok\":false"), "Claim once");
                host.Call("close_ui"); host.Call("open_ui");
                string complete = "{\"request_id\":\"" + id + "\",\"completion\":{\"status\":\"succeeded\",\"result\":{\"counter\":3}}}";
                host.Call("complete", complete);
                Check(host.Raw("complete", complete).Contains("\"ok\":false"), "Complete once");
                Check(host.Call("snapshot").Contains("\"counter\":3"), "Result survives UI replacement");
                ticket = Select(host, revision); host.Call("configure", "{\"aliases\":{\"plus\":\"demo.increment\"}}");
                Check(Invoke(host, ticket, 1, revision).Contains("\"ok\":false"), "Stale registry");
                ticket = Select(host, revision); revision++;
                Check(Invoke(host, ticket, 1, revision).Contains("\"ok\":false") && executions == 1, "Stale target executes zero times");
                id = Request(Invoke(host, Select(host, revision), 9, revision));
                claimed = host.Call("claim", "{\"request_id\":\"" + id + "\",\"target\":" + Target(revision) + ",\"capabilities\":{\"counter\":true}}");
                try { if (Amount(claimed) == 9) throw new InvalidOperationException("Managed application action failed"); }
                catch (InvalidOperationException) { host.Call("complete", "{\"request_id\":\"" + id + "\",\"completion\":{\"status\":\"failed\",\"result\":{\"message\":\"C# exception\"}}}"); }
                Check(host.Call("snapshot").Contains("C# exception") && counter == 3, "Contain managed exception");
                id = Request(Invoke(host, Select(host, revision), 1, revision));
                host.Call("claim", "{\"request_id\":\"" + id + "\",\"target\":" + Target(revision) + ",\"capabilities\":{\"counter\":true}}");
                host.Call("cancel", "{\"request_id\":\"" + id + "\"}");
                Check(host.Call("snapshot").Contains("\"status\":\"pending\""), "Cancel remains pending");
                host.Call("complete", "{\"request_id\":\"" + id + "\",\"completion\":{\"status\":\"cancelled\",\"result\":{\"partial\":\"stdout\"}}}");
                Check(host.Call("snapshot").Contains("\"partial\":\"stdout\""), "Partial result retained");
                bool wrongThread = false;
                Thread thread = new Thread(delegate() { try { host.Call("snapshot"); } catch (InvalidOperationException e) { wrongThread = e.Message.Contains("owner thread"); } });
                thread.Start(); thread.Join(); Check(wrongThread, "Owner thread"); host.Call("snapshot");
                Check(host.Raw("snapshot", "{bad json}").Contains("\"ok\":false"), "Malformed input");
                id = Request(Invoke(host, Select(host, revision), 1, revision));
                host.Call("claim", "{\"request_id\":\"" + id + "\",\"target\":" + Target(revision) + ",\"capabilities\":{\"counter\":true}}");
                Check(host.Call("dispose").Contains(id), "Explicit resource handoff");
                Check(host.Raw("complete", "{\"request_id\":\"" + id + "\",\"completion\":{\"status\":\"succeeded\"}}").Contains("\"ok\":false"), "Late result refused");
                Check(counter == 3 && executions == 1, "No implicit host execution");
                host.Dispose();
                bool disposed = false; try { host.Call("snapshot"); } catch (ObjectDisposedException) { disposed = true; }
                Check(disposed, "SafeHandle prevents use after free");
            }
            Console.WriteLine("C# host: " + checks + " checks PASS; .NET " + Environment.Version); return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
}

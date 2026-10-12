using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public sealed class CommandEnvironment : IDisposable
{
    private const string Library = "command_environment";
    private readonly EngineHandle handle;
    private static readonly Encoding Utf8 = new UTF8Encoding(false, true);
    private sealed class EngineHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public EngineHandle(IntPtr pointer) : base(true) { SetHandle(pointer); }
        protected override bool ReleaseHandle() { return ce_destroy(handle) == 0; }
    }
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern uint ce_abi_version();
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern int ce_create(byte[] runtime, byte[] root, out IntPtr handle, out IntPtr error, out UIntPtr errorSize);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern int ce_call(EngineHandle handle, byte[] operation, byte[] json, UIntPtr jsonSize, out IntPtr output, out UIntPtr outputSize, out IntPtr error, out UIntPtr errorSize);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern int ce_destroy(IntPtr handle);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern void ce_free(IntPtr pointer);
    private static byte[] Terminated(string value)
    {
        if (value == null || value.IndexOf('\0') >= 0) throw new ArgumentException("Expected text without NUL");
        byte[] bytes = Utf8.GetBytes(value); Array.Resize(ref bytes, bytes.Length + 1); return bytes;
    }
    private static string Read(IntPtr pointer, UIntPtr size)
    {
        ulong length = size.ToUInt64();
        if (length > 1048576) throw new InvalidOperationException("Native output exceeds byte limit");
        if (pointer == IntPtr.Zero) return "";
        byte[] bytes = new byte[(int)length]; Marshal.Copy(pointer, bytes, 0, bytes.Length); return Utf8.GetString(bytes);
    }
    public CommandEnvironment(string runtime, string luaRoot)
    {
        if (ce_abi_version() != 1) throw new InvalidOperationException("Unsupported native ABI");
        IntPtr pointer, error; UIntPtr length;
        int status = ce_create(Terminated(runtime), Terminated(luaRoot), out pointer, out error, out length);
        try { if (status != 0) throw new InvalidOperationException(Read(error, length)); }
        finally { ce_free(error); }
        handle = new EngineHandle(pointer);
    }
    public string Raw(string operation, string json)
    {
        if (handle.IsClosed || handle.IsInvalid) throw new ObjectDisposedException("CommandEnvironment");
        byte[] input = Utf8.GetBytes(json);
        IntPtr output, error; UIntPtr outputSize, errorSize;
        int status = ce_call(handle, Terminated(operation), input, new UIntPtr((uint)input.Length), out output, out outputSize, out error, out errorSize);
        try { if (status != 0) throw new InvalidOperationException(Read(error, errorSize)); return Read(output, outputSize); }
        finally { ce_free(output); ce_free(error); }
    }
    public string Call(string operation, string json)
    {
        string reply = Raw(operation, json);
        if (!reply.StartsWith("{\"ok\":true", StringComparison.Ordinal)) throw new InvalidOperationException(reply);
        return reply;
    }
    public string Call(string operation) { return Call(operation, "{}"); }
    public void Dispose() { handle.Dispose(); }
}

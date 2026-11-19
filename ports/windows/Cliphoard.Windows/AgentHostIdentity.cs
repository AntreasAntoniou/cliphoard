using System.Runtime.InteropServices;
using System.Security.Principal;
namespace Cliphoard.Windows;
internal static class AgentHostIdentity
{
    internal static AgentHost Current() => Capture(Environment.ProcessId);
    internal static bool IsAlive(AgentHost host)
    {
        try { return Capture(host.ProcessId) == host; }
        catch { return false; }
    }
    private static AgentHost Capture(int pid)
    {
        if (pid <= 0) throw new IOException("Agent host is unavailable.");
        using var process = Native.OpenProcess(0x1000, false, (uint)pid);
        if (process.IsInvalid || !Native.GetExitCodeProcess(process, out uint exit) || exit != 259 || !Native.ProcessIdToSessionId((uint)pid, out uint session)
            || !Native.ProcessIdToSessionId((uint)Environment.ProcessId, out uint ownSession) || session != ownSession || !Native.OpenProcessToken(process, 8, out var token)) throw new IOException("Agent host is unavailable.");
        using (token)
        using (var identity = new WindowsIdentity(token.DangerousGetHandle()))
        using (var current = WindowsIdentity.GetCurrent())
            if (identity.User is null || current.User is null || !identity.User.Equals(current.User)) throw new IOException("Agent host belongs to another account.");
        if (!GetProcessTimes(process, out ulong created, out _, out _, out _) || created < 116444736000000000UL) throw new IOException("Agent host time is unavailable.");
        ulong microseconds = (created - 116444736000000000UL) / 10;
        byte[] environment = new byte[32];
        if (NtQuerySystemInformation(90, environment, (uint)environment.Length, out uint returned) < 0 || returned < 16 || returned > environment.Length) throw new IOException("Agent boot identity is unavailable.");
        Guid boot = new(environment.AsSpan(0, 16));
        if (boot == Guid.Empty || !Native.GetExitCodeProcess(process, out exit) || exit != 259) throw new IOException("Agent host has exited.");
        return new(pid, microseconds / 1000000, microseconds % 1000000, boot.ToString("D"));
    }
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetProcessTimes(Microsoft.Win32.SafeHandles.SafeProcessHandle process, out ulong creation, out ulong exit, out ulong kernel, out ulong user);
    [DllImport("ntdll.dll")] private static extern int NtQuerySystemInformation(uint informationClass, [Out] byte[] information, uint length, out uint returned);
}

using System.Runtime.InteropServices;
namespace Cliphoard.Windows;

internal static class FocusProtection
{
    // Read-only ABI from Microsoft's Windows metadata projection.
    // https://github.com/microsoft/windows-rs/blob/master/crates/libs/windows/src/Windows/UI/Shell/mod.rs
    internal static bool? Read()
    {
        nint name = 0, factory = 0, manager = 0;
        try
        {
            const string runtime = "Windows.UI.Shell.FocusSessionManager";
            Marshal.ThrowExceptionForHR(WindowsCreateString(runtime, runtime.Length, out name));
            Guid iid = new("834df764-cb9a-5d0a-aa9f-73df4f249395");
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(name, ref iid, out factory));
            Marshal.ThrowExceptionForHR(Method<GetBoolean>(factory, 7)(factory, out byte supported));
            if (supported == 0) return null;
            Marshal.ThrowExceptionForHR(Method<GetObject>(factory, 6)(factory, out manager));
            if (manager == 0) return null;
            Marshal.ThrowExceptionForHR(Method<GetBoolean>(manager, 6)(manager, out byte active));
            return active != 0;
        }
        catch { return null; }
        finally { if (manager != 0) Marshal.Release(manager); if (factory != 0) Marshal.Release(factory); if (name != 0) WindowsDeleteString(name); }
    }
    private static T Method<T>(nint instance, int slot) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), slot * nint.Size));
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetBoolean(nint instance, out byte value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetObject(nint instance, out nint value);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] private static extern int WindowsCreateString(string value, int length, out nint handle);
    [DllImport("combase.dll")] private static extern int WindowsDeleteString(nint handle);
    [DllImport("combase.dll")] private static extern int RoGetActivationFactory(nint name, ref Guid iid, out nint factory);
}

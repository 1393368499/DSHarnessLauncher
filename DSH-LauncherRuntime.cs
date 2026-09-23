using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

public static class DshApplicationIdentity
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PROPERTYKEY
    {
        public Guid fmtid;
        public uint pid;
        public PROPERTYKEY(Guid formatId, uint propertyId) { fmtid = formatId; pid = propertyId; }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
        public static PROPVARIANT FromString(string value)
        {
            return new PROPVARIANT { vt = 31, pointerValue = Marshal.StringToCoTaskMemUni(value ?? String.Empty) };
        }
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint propertyCount);
        [PreserveSig] int GetAt(uint propertyIndex, out PROPERTYKEY key);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        [PreserveSig] int Commit();
    }

    private static readonly Guid AppUserModelFormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    private static readonly Guid PropertyStoreInterfaceId = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHGetPropertyStoreFromParsingName([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bindContext, uint flags, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern void SHChangeNotify(uint eventId, uint flags, [MarshalAs(UnmanagedType.LPWStr)] string item1, IntPtr item2);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PROPVARIANT value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr windowHandle);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr windowHandle, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr windowHandle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int RegisterApplicationRestart(string commandLineArgs, int flags);
    [DllImport("kernel32.dll")] private static extern int UnregisterApplicationRestart();

    private static void SetString(IPropertyStore store, uint propertyId, string value)
    {
        var key = new PROPERTYKEY(AppUserModelFormatId, propertyId);
        var propertyValue = PROPVARIANT.FromString(value);
        try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref propertyValue)); }
        finally { PropVariantClear(ref propertyValue); }
    }

    private static void ApplyIdentity(IPropertyStore store, string appId, string relaunchCommand, string displayName, string iconResource)
    {
        SetString(store, 5, appId);
        SetString(store, 2, relaunchCommand);
        SetString(store, 4, displayName);
        SetString(store, 3, iconResource);
        Marshal.ThrowExceptionForHR(store.Commit());
    }

    public static void SetShortcutIdentity(string shortcutPath, string appId, string relaunchCommand, string displayName, string iconResource)
    {
        IPropertyStore store;
        var interfaceId = PropertyStoreInterfaceId;
        SHGetPropertyStoreFromParsingName(shortcutPath, IntPtr.Zero, 2, ref interfaceId, out store);
        try { ApplyIdentity(store, appId, relaunchCommand, displayName, iconResource); }
        finally { if (store != null) Marshal.FinalReleaseComObject(store); }
        SHChangeNotify(0x00002000, 0x0005, shortcutPath, IntPtr.Zero);
    }

    public static bool ActivateExistingWindow()
    {
        var handle = FindWindow(null, "DSH");
        if (handle == IntPtr.Zero) return false;
        ShowWindow(handle, IsIconic(handle) ? 9 : 5);
        return SetForegroundWindow(handle);
    }

    public static int EnableApplicationRestart(string commandLineArgs) { return RegisterApplicationRestart(commandLineArgs, 0); }
    public static void DisableApplicationRestart() { UnregisterApplicationRestart(); }
}

public static class DshAsyncPowerShell
{
    public static IAsyncResult Begin(PowerShell shell, PSDataCollection<PSObject> input, PSDataCollection<PSObject> output)
    {
        return shell.BeginInvoke<PSObject, PSObject>(input, output);
    }
}

public static class DshRunspaceWarmup
{
    public static Task Begin(RunspacePool pool)
    {
        return Task.Factory.StartNew(() =>
        {
            try
            {
                using (var shell = PowerShell.Create())
                {
                    shell.RunspacePool = pool;
                    shell.AddScript("$null = 1");
                    shell.Invoke();
                }
            }
            catch { }
        }, CancellationToken.None, TaskCreationOptions.None, TaskScheduler.Default);
    }
}

public static class DshNetworkProbe
{
    public static Task<bool> Begin(int timeoutMilliseconds)
    {
        return Task.Factory.StartNew(() =>
        {
            using (var client = new TcpClient())
            {
                try
                {
                    var connect = client.ConnectAsync("127.0.0.1", 3080);
                    return connect.Wait(Math.Max(1, timeoutMilliseconds)) && client.Connected;
                }
                catch { return false; }
            }
        }, CancellationToken.None, TaskCreationOptions.None, TaskScheduler.Default);
    }
}

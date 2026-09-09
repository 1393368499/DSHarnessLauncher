using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class LauncherHost
{
    [STAThread]
    private static void Main()
    {
        string launcherDirectory = AppContext.BaseDirectory.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        string launcherScript = Path.Combine(launcherDirectory, "DSH-UI.ps1");
        const string powerShell = @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";

        if (!File.Exists(launcherScript))
        {
            MessageBox.Show(
                "DSH launcher script was not found:\n" + launcherScript,
                "DSH",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = powerShell,
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + launcherScript + "\"",
                WorkingDirectory = launcherDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            Process.Start(startInfo);
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "DSH could not be started.\n\n" + exception.Message,
                "DSH",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}

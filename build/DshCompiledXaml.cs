using System;
using System.Windows;

public static class DshCompiledXaml
{
    public static Window LoadWindow()
    {
        return (Window)Application.LoadComponent(
            new Uri("/DSH-Launcher.Xaml;component/LauncherWindow.xaml", UriKind.Relative));
    }
}

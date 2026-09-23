#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <string>

namespace
{
    const wchar_t* kWindowClass = L"DshNativeSplashWindow";
    const wchar_t* kSplashTitle = L"DSH 正在启动";
    HANDLE g_childProcess = nullptr;
    ULONGLONG g_startedAt = 0;
    int g_progress = 0;

    std::wstring GetExecutableDirectory()
    {
        wchar_t path[MAX_PATH] = {};
        GetModuleFileNameW(nullptr, path, MAX_PATH);
        std::wstring value(path);
        const auto separator = value.find_last_of(L"\\/");
        return separator == std::wstring::npos ? L"." : value.substr(0, separator);
    }

    bool FileExists(const std::wstring& path)
    {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
    }

    void ActivateLauncher(HWND window)
    {
        if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
        else ShowWindow(window, SW_SHOW);
        SetForegroundWindow(window);
    }

    void WriteSplashTiming(ULONGLONG elapsedMilliseconds)
    {
        wchar_t localAppData[MAX_PATH] = {};
        const DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", localAppData, MAX_PATH);
        if (length == 0 || length >= MAX_PATH) return;
        const std::wstring dshDirectory = std::wstring(localAppData) + L"\\DSH";
        const std::wstring logDirectory = dshDirectory + L"\\logs";
        CreateDirectoryW(dshDirectory.c_str(), nullptr);
        CreateDirectoryW(logDirectory.c_str(), nullptr);
        const std::wstring logPath = logDirectory + L"\\launcher-performance.log";
        HANDLE file = CreateFileW(logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return;
        char line[128] = {};
        SYSTEMTIME now = {};
        GetLocalTime(&now);
        const int bytes = wsprintfA(line,
            "[%04u-%02u-%02uT%02u:%02u:%02u.%03u] native-splash-visible|%I64ums\r\n",
            now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
            now.wMilliseconds, elapsedMilliseconds);
        DWORD written = 0;
        WriteFile(file, line, static_cast<DWORD>(bytes), &written, nullptr);
        CloseHandle(file);
    }

    bool StartLauncherProcess(const std::wstring& directory)
    {
        const std::wstring script = directory + L"\\DSH-UI.ps1";
        const std::wstring powershell = L"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
        std::wstring command = L"\"" + powershell +
            L"\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
            script + L"\"";
        STARTUPINFOW startup = {};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION process = {};
        if (!CreateProcessW(powershell.c_str(), &command[0], nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW, nullptr, directory.c_str(), &startup, &process))
        {
            return false;
        }
        CloseHandle(process.hThread);
        g_childProcess = process.hProcess;
        return true;
    }

    void DrawSplash(HWND window, HDC target)
    {
        RECT client = {};
        GetClientRect(window, &client);
        HBRUSH background = CreateSolidBrush(RGB(255, 255, 255));
        FillRect(target, &client, background);
        DeleteObject(background);

        HFONT titleFont = CreateFontW(-22, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            DEFAULT_PITCH, L"Microsoft YaHei UI");
        HFONT detailFont = CreateFontW(-14, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            DEFAULT_PITCH, L"Microsoft YaHei UI");
        SetBkMode(target, TRANSPARENT);
        SetTextColor(target, RGB(29, 29, 31));
        SelectObject(target, titleFont);
        RECT titleRect = { 25, 22, 355, 58 };
        DrawTextW(target, L"DSH  正在启动", -1, &titleRect, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        SetTextColor(target, RGB(110, 110, 115));
        SelectObject(target, detailFont);
        RECT detailRect = { 27, 60, 355, 90 };
        DrawTextW(target, L"正在准备 DeepSeek Harness 启动器…", -1, &detailRect,
            DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        DeleteObject(titleFont);
        DeleteObject(detailFont);

        HBRUSH track = CreateSolidBrush(RGB(230, 238, 248));
        RECT trackRect = { 27, 103, 353, 108 };
        FillRect(target, &trackRect, track);
        DeleteObject(track);
        const int segmentWidth = 80;
        const int start = 27 + (g_progress % (326 + segmentWidth)) - segmentWidth;
        RECT segment = { max(27, start), 103, min(353, start + segmentWidth), 108 };
        if (segment.right > segment.left)
        {
            HBRUSH accent = CreateSolidBrush(RGB(0, 113, 227));
            FillRect(target, &segment, accent);
            DeleteObject(accent);
        }

        HPEN borderPen = CreatePen(PS_SOLID, 1, RGB(229, 229, 234));
        HGDIOBJ oldPen = SelectObject(target, borderPen);
        HGDIOBJ oldBrush = SelectObject(target, GetStockObject(NULL_BRUSH));
        RoundRect(target, 0, 0, client.right, client.bottom, 20, 20);
        SelectObject(target, oldBrush);
        SelectObject(target, oldPen);
        DeleteObject(borderPen);
    }

    LRESULT CALLBACK SplashWindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
    {
        switch (message)
        {
        case WM_TIMER:
        {
            HWND launcher = FindWindowW(nullptr, L"DSH");
            if (launcher)
            {
                KillTimer(window, 1);
                ActivateLauncher(launcher);
                DestroyWindow(window);
                return 0;
            }
            if (g_childProcess && WaitForSingleObject(g_childProcess, 0) == WAIT_OBJECT_0)
            {
                KillTimer(window, 1);
                MessageBoxW(window, L"DSH 未能启动，请检查启动器日志。", L"DSH", MB_OK | MB_ICONERROR);
                DestroyWindow(window);
                return 0;
            }
            if (GetTickCount64() - g_startedAt > 15000)
            {
                KillTimer(window, 1);
                MessageBoxW(window, L"DSH 启动超时，请检查启动器日志后重试。", L"DSH", MB_OK | MB_ICONWARNING);
                DestroyWindow(window);
                return 0;
            }
            g_progress += 10;
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        }
        case WM_PAINT:
        {
            PAINTSTRUCT paint = {};
            HDC dc = BeginPaint(window, &paint);
            DrawSplash(window, dc);
            EndPaint(window, &paint);
            return 0;
        }
        case WM_DESTROY:
            if (g_childProcess) { CloseHandle(g_childProcess); g_childProcess = nullptr; }
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(window, message, wParam, lParam);
        }
    }
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int)
{
    g_startedAt = GetTickCount64();
    SetProcessDPIAware();
    if (HWND existing = FindWindowW(nullptr, L"DSH"))
    {
        ActivateLauncher(existing);
        return 0;
    }

    const std::wstring directory = GetExecutableDirectory();
    const std::wstring script = directory + L"\\DSH-UI.ps1";
    if (!FileExists(script))
    {
        MessageBoxW(nullptr, (L"找不到启动器脚本：\n" + script).c_str(), L"DSH", MB_OK | MB_ICONERROR);
        return 1;
    }

    WNDCLASSEXW windowClass = {};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = SplashWindowProc;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursor(nullptr, IDC_ARROW);
    windowClass.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
    windowClass.hIconSm = windowClass.hIcon;
    windowClass.lpszClassName = kWindowClass;
    if (!RegisterClassExW(&windowClass)) return 2;

    const int width = 380;
    const int height = 150;
    const int x = (GetSystemMetrics(SM_CXSCREEN) - width) / 2;
    const int y = (GetSystemMetrics(SM_CYSCREEN) - height) / 2;
    HWND splash = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kWindowClass, kSplashTitle,
        WS_POPUP, x, y, width, height, nullptr, nullptr, instance, nullptr);
    if (!splash) return 3;
    SetWindowRgn(splash, CreateRoundRectRgn(0, 0, width + 1, height + 1, 20, 20), TRUE);
    ShowWindow(splash, SW_SHOW);
    UpdateWindow(splash);
    WriteSplashTiming(GetTickCount64() - g_startedAt);

    if (!StartLauncherProcess(directory))
    {
        MessageBoxW(splash, L"无法启动 PowerShell 启动器进程。", L"DSH", MB_OK | MB_ICONERROR);
        DestroyWindow(splash);
        return 4;
    }
    SetTimer(splash, 1, 30, nullptr);

    MSG message = {};
    while (GetMessageW(&message, nullptr, 0, 0) > 0)
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return 0;
}

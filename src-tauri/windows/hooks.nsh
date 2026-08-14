!macro NSIS_HOOK_POSTINSTALL
  DetailPrint "DSHarness 基础程序已安装。"
  DetailPrint "即将打开桌面端，完整 Harness、Node.js 与联网搜索会在应用内下载并显示实时日志、进度和预计剩余时间。"
  ExecShell "open" "$INSTDIR\dsharness.exe" "--setup"
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  RMDir /r "$LOCALAPPDATA\DSHarness\runtime"
!macroend

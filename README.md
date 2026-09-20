# DSH 鲸鱼娘启动器 v2

启动器已作为 `dsh-deep-whale` 项目组件分发，不依赖固定盘符或固定 Harness 路径。

## 首次启动

1. 运行 `DSH.exe`。
2. 启动器读取 `%LOCALAPPDATA%\DSH\launcher.json` 并验证已保存的 Harness 路径。
3. 如果未找到完整 Harness，弹出目录选择器。默认选择启动器所在目录，并在其中创建 `deepseek-harness` 子目录。
4. 启动器从 <https://github.com/deepseek-ai/deepseek-harness> 克隆完整源码、安装依赖、生成运行时与 WebUI，并注册项目内的 `maid-atelier` 主题。

## 日常使用

- 启动器采用单实例运行；重复点击 `DSH.exe` 会激活已有窗口，不再重复创建托盘图标或后台进程。Windows 异常退出后可通过应用重启机制恢复。
- 标题栏品牌区和右侧运行信息会从 `launcher-manifest.json` 动态显示当前启动器版本，不再使用容易过期的硬编码版本号。
- “检查更新”按顺序完成：先更新 Harness 核心、重新构建，再校验启动器和新核心的兼容性；构建状态同时记录核心提交与受管兼容补丁哈希，补丁变化也会触发完整重构。只有启动器自身是带远端的干净 Git 工作区时，才会安全地快进更新启动器。便携版会跳过启动器自更新，但仍会记录兼容性结果。
- 当前核心的工具调度器在同一模块经不同软链接路径重复加载时可能产生不同的 `unique symbol`，导致所有 Pwsh/SSH 工具报 `prepare` 未定义。启动器会应用一项可逆的 `Symbol.for(...)` 兼容补丁；检查核心更新前只撤销这项受管修改，更新后重新检测。官方核心包含等价修复后会自动停止打补丁。
- “检查更新”还会读取 Web profile 中已启用的第三方插件，通过禁用系统代理的 GitHub REST API 直连检查 Release、Tag 或默认分支提交，并通过 Harness 插件管理命令应用可用更新；本地 `file:`/`link:` 插件和显式锁定 Git ref 的插件不会被改动。
- 插件更新通道默认为自动：稳定版 Harness 只跟踪稳定版；alpha/beta/rc Harness 会同时检查稳定版和预发布版，读取候选插件的 `peerDependencies`，只安装与当前核心兼容的最高版本。安装时使用明确版本号，因此不会受 npm `latest` 标签限制。
- 同一个 GitHub 仓库提供的多个插件会合并成一次更新；配置的 npm 镜像不可用时自动切换到官方 npm 源。插件更新前后的启用/停用列表会原样保留，避免 Harness 更新命令意外停用插件。
- 对 `dsh-deep-whale` 这类一个仓库包含多个 `#path:` 子包的插件，启动器使用受管源码缓存更新：整仓只下载一次，再从各自子目录安装，避免 `plugin update` 丢失子路径并生成空占位包。
- 插件仓库更换 npm 作用域或包名时，启动器会先安装并验证新身份，再移除旧身份，同时迁移原有启用/停用状态。`dsh-deep-whale` 从 `@dsh-external` 到 `@smalltailqwq` 的升级可直接完成。
- 点击“插件管理”可查看 Web profile 的插件、启用或停用入口，以及更新单个插件。更新后启动器会自动应用已知的核心 API 兼容迁移；离线停用会在 `%USERPROFILE%\\.dsh\\profiles\\web\\backups` 留下可恢复副本。
- 点击“系统诊断”可一次检查启动器文件与语法、Git/Node.js/pnpm、官方核心来源与构建状态、Web profile 插件、服务端口和磁盘空间；结构化报告写入 `%LOCALAPPDATA%\DSH\diagnostics-latest.json`。
- GitHub 查询结果缓存 15 分钟；公共仓库可匿名检查，也可通过当前进程或 Windows 用户级的 `GH_TOKEN`、`GITHUB_TOKEN` 环境变量提高 API 限额。
- “打开 WebUI”使用保存的 Harness 路径启动服务，并等待 Harness 打印出带 token 的地址后再用它打开系统默认浏览器；token 从启动日志解析，避免落在需要手动刷新的未授权页面。
- “打开终端”在保存的 Harness 目录中执行命令。
- 点击关闭按钮后隐藏到托盘；托盘菜单中的“彻底退出”才会结束启动器。

## 文件与状态

- 无控制台入口：`DSH.exe`
- 界面脚本：`DSH-UI.ps1`
- 安装与更新脚本：`DSH-Launcher.ps1`
- 核心兼容补丁管理：`DSH-CoreCompatibility.ps1`
- 插件管理后端：`DSH-PluginManager.ps1`
- 启动器兼容性记录：`%LOCALAPPDATA%\DSH\launcher-core-compatibility.json`
- 位置记录：`%LOCALAPPDATA%\DSH\launcher.json`
- 启动器日志：`%LOCALAPPDATA%\DSH\logs\launcher.log`
- 崩溃日志：`%LOCALAPPDATA%\DSH\logs\launcher-crash.log`
- 系统诊断报告：`%LOCALAPPDATA%\DSH\diagnostics-latest.json`
- 插件更新缓存：`%LOCALAPPDATA%\DSH\github-plugin-cache.json`
- Web 日志：`<Harness 安装目录>\dsh-web.log`

运行前需要系统能够调用 Git、Node.js 和 pnpm。

新版核心的 `fs-ext` 需要本机 C++ 编译环境。启动器会检测已安装的 Visual Studio 与 Windows SDK，并为本次更新设置构建环境；安装成功后记录锁文件和 Node.js 版本。中断或失败后再次检查更新，会先恢复依赖，再重建运行时。

构建输出统一按 UTF-8 解码，并过滤 PowerShell 对原生命令标准错误流生成的伪 `RemoteException`，终端里显示的警告不再被误报成更新失败。

便携版启动器除了 Git 仓库通道，也支持签名散列保护的 ZIP 更新源。可在 `launcher-manifest.json` 的 `update.manifestSources` 中配置清单地址，或设置以分号分隔的 `DSH_LAUNCHER_UPDATE_MANIFESTS`。更新清单需要包含 `schemaVersion`、`version`、`packageUrl` 和 ZIP 的 `sha256`，可选 `packageSize` 与 `publisherThumbprints`。更新器只接受 HTTPS 或本地源，并在解压前阻止目录穿越；应用前校验散列、可选 Authenticode 发布者、文件清单及当前 Harness 兼容性。更新失败自动恢复，备份保留最近 5 份。

启动器日志超过 8 MB、Web 日志超过 20 MB 时会自动轮转，避免长时间运行后日志无限增长。

## 发布打包（仓库维护）

- 打包：`powershell -NoProfile -ExecutionPolicy Bypass -File tools\New-LauncherRelease.ps1`。版本号取自 `launcher-manifest.json`，可用 `-Version` 覆盖；脚本写出 `artifacts\DSH-Launcher-v<版本>-win-x64.zip`，并复制一份到仓库根目录作为对外下载包。ZIP 条目固定使用正斜杠以保持与历史发布包一致，打包完成后自动核对 `launcher-manifest.json` 的 `requiredFiles`，缺项即失败并删除产物。
- GitHub 直连开关：DSH 默认沿用本机已配置的网络路径（Git 的 `http.proxy`、`HTTP(S)_PROXY`）。仅当回环代理客户端已退出、而本机仍留有其代理配置时，才用 `set DSH_GITHUB_DIRECT=1` 启动，让 `Start-DSH-Web.cmd` 为 GitHub 主机强制直连。

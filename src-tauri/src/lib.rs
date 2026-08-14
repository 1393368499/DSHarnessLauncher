use serde::{Deserialize, Serialize};
use std::{
  fs,
  io::{BufRead, BufReader},
  net::{SocketAddr, TcpStream},
  path::PathBuf,
  process::{Child, Command, Stdio},
  sync::Mutex,
  thread,
  time::{Duration, Instant},
};
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

const BOOTSTRAP_SCRIPT: &str = include_str!("../bootstrap/install-components.ps1");
const THEME_INSTALL_SCRIPT: &str = include_str!("../bootstrap/install-theme.ps1");
const CORE_REPOSITORY: &str = "https://github.com/deepseek-ai/deepseek-harness";
const BLACK_WHALE_ICON: &[u8] = include_bytes!("../../public/assets/black-whale-centered.png");
const WHALE_MAID_ICON: &[u8] = include_bytes!("../../public/assets/whale-maid.png");

#[derive(Default)]
struct AppState {
  harness: Mutex<Option<Child>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Capability {
  id: &'static str,
  name: &'static str,
  summary: &'static str,
  size_mb: u32,
  installed: bool,
  status: String,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct RuntimeStatus {
  installed: bool,
  core_commit: Option<String>,
  node_version: Option<String>,
  installed_at: Option<String>,
  source_repository: &'static str,
  runtime_path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UpdateInfo {
  installed_commit: Option<String>,
  latest_commit: String,
  update_available: bool,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct InstallEvent {
  kind: &'static str,
  message: String,
  percent: u8,
  elapsed_seconds: u64,
  eta_seconds: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginRequest {
  task: String,
  kind: String,
  permissions: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PluginResult {
  id: String,
  name: String,
  path: String,
  blueprint: String,
}

fn data_root() -> Result<PathBuf, String> {
  std::env::var_os("LOCALAPPDATA")
    .map(PathBuf::from)
    .map(|path| path.join("DSHarness"))
    .ok_or_else(|| "Windows LOCALAPPDATA 不可用。".to_string())
}

fn runtime_root() -> Result<PathBuf, String> {
  Ok(data_root()?.join("runtime"))
}

fn marker_value() -> Option<serde_json::Value> {
  let marker = runtime_root().ok()?.join("install.json");
  serde_json::from_str(&fs::read_to_string(marker).ok()?).ok()
}

fn runtime_status_value() -> RuntimeStatus {
  let runtime = runtime_root().unwrap_or_default();
  let marker = marker_value();
  let node = runtime.join("node").join("node.exe");
  let core = runtime.join("harness-core").join("apps").join("cli").join("lib").join("bin.js");
  let installed = marker.is_some() && node.is_file() && core.is_file();
  RuntimeStatus {
    installed,
    core_commit: marker.as_ref().and_then(|value| value.get("coreCommit")).and_then(|value| value.as_str()).map(str::to_owned),
    node_version: marker.as_ref().and_then(|value| value.get("nodeVersion")).and_then(|value| value.as_str()).map(str::to_owned),
    installed_at: marker.as_ref().and_then(|value| value.get("installedAt")).and_then(|value| value.as_str()).map(str::to_owned),
    source_repository: CORE_REPOSITORY,
    runtime_path: runtime.display().to_string(),
  }
}

fn bootstrap_path() -> PathBuf {
  std::env::temp_dir().join(format!("dsharness-bootstrap-{}.ps1", std::process::id()))
}

fn prepare_bootstrap() -> Result<PathBuf, String> {
  let path = bootstrap_path();
  fs::write(&path, BOOTSTRAP_SCRIPT).map_err(|error| format!("无法准备安装引导程序：{error}"))?;
  Ok(path)
}

pub fn install_components_cli() -> i32 {
  let script = match prepare_bootstrap() {
    Ok(path) => path,
    Err(error) => {
      eprintln!("{error}");
      return 1;
    }
  };
  let status = Command::new("powershell.exe")
    .args(["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
    .arg(&script)
    .status();
  let _ = fs::remove_file(script);
  match status {
    Ok(status) => status.code().unwrap_or(1),
    Err(error) => {
      eprintln!("无法启动组件安装程序：{error}");
      1
    }
  }
}

fn emit_install_event(app: &AppHandle, started: Instant, kind: &'static str, message: impl Into<String>, percent: u8) {
  let elapsed_seconds = started.elapsed().as_secs();
  let eta_seconds = if (3..100).contains(&percent) {
    Some(((elapsed_seconds as f64) * (100.0 / percent as f64 - 1.0)).round() as u64)
  } else { None };
  let _ = app.emit("install-progress", InstallEvent { kind, message: message.into(), percent, elapsed_seconds, eta_seconds });
}

fn install_components_blocking(app: AppHandle) -> Result<String, String> {
  let script = prepare_bootstrap()?;
  let started = Instant::now();
  emit_install_event(&app, started, "progress", "正在准备完整 Harness 安装…", 1);
  let mut child = Command::new("powershell.exe")
    .args(["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
    .arg(&script)
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .map_err(|error| format!("无法启动组件安装程序：{error}"))?;
  let stdout = child.stdout.take().ok_or_else(|| "无法读取安装输出。".to_string())?;
  let stderr = child.stderr.take().ok_or_else(|| "无法读取安装错误输出。".to_string())?;
  let app_stdout = app.clone();
  let output_started = started;
  let stdout_thread = thread::spawn(move || {
    let mut log = String::new();
    let mut percent = 1u8;
    let mut package_total = 923u32;
    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
      if let Some(state) = line.strip_prefix("@@DSH_PROGRESS@@") {
        let mut parts = state.splitn(2, '|');
        percent = parts.next().and_then(|value| value.parse::<u8>().ok()).unwrap_or(percent);
        let stage = parts.next().unwrap_or("正在处理组件");
        emit_install_event(&app_stdout, output_started, "progress", stage, percent);
        continue;
      }
      if let Some(total) = line.split("Packages: +").nth(1).and_then(|value| value.split_whitespace().next()).and_then(|value| value.parse::<u32>().ok()) { package_total = total.max(1); }
      if line.starts_with("Progress:") {
        if let Some(added) = line.split("added ").nth(1).and_then(|value| value.split(',').next()).and_then(|value| value.trim().parse::<u32>().ok()) {
          percent = (55 + ((added.saturating_mul(25)) / package_total).min(25)) as u8;
          emit_install_event(&app_stdout, output_started, "progress", format!("下载并链接依赖：{added}/{package_total}"), percent);
        }
      }
      emit_install_event(&app_stdout, output_started, "log", line.clone(), percent);
      log.push_str(&line); log.push('\n');
    }
    log
  });
  let app_stderr = app.clone();
  let error_started = started;
  let stderr_thread = thread::spawn(move || {
    let mut log = String::new();
    for line in BufReader::new(stderr).lines().map_while(Result::ok) {
      emit_install_event(&app_stderr, error_started, "log", line.clone(), 1);
      log.push_str(&line); log.push('\n');
    }
    log
  });
  let status = child.wait().map_err(|error| format!("安装进程异常结束：{error}"))?;
  let stdout = stdout_thread.join().unwrap_or_default();
  let stderr = stderr_thread.join().unwrap_or_default();
  let _ = fs::remove_file(script);
  if status.success() {
    emit_install_event(&app, started, "done", "完整 Harness 核心、Node.js 与联网搜索能力已安装。", 100);
    Ok(if stdout.is_empty() { "完整组件安装完成。".into() } else { stdout })
  } else {
    let error = if stderr.is_empty() { stdout } else { stderr };
    emit_install_event(&app, started, "error", error.clone(), 1);
    Err(error)
  }
}

fn plugin_root(app: &tauri::AppHandle) -> Result<PathBuf, String> {
  app.path().app_data_dir().map(|dir| dir.join("plugins")).map_err(|error| error.to_string())
}

#[tauri::command]
fn runtime_status() -> RuntimeStatus {
  runtime_status_value()
}

#[tauri::command]
fn launch_mode() -> String {
  if std::env::args().any(|argument| argument == "--setup") { "setup".into() } else { "normal".into() }
}

#[tauri::command]
fn set_theme_icon(window: tauri::WebviewWindow, theme: String) -> Result<(), String> {
  let bytes = if theme == "whale" { WHALE_MAID_ICON } else { BLACK_WHALE_ICON };
  let image = tauri::image::Image::from_bytes(bytes).map_err(|error| error.to_string())?;
  window.set_icon(image).map_err(|error| error.to_string())
}

#[tauri::command]
fn capabilities() -> Vec<Capability> {
  let status = runtime_status_value();
  vec![
    Capability { id: "harness-core", name: "完整 Harness 核心", summary: "DeepSeek Harness 全部工作区、Agent、会话、模型配置与本地服务", size_mb: 0, installed: status.installed, status: if status.installed { "已安装完整核心".into() } else { "安装时联网获取".into() } },
    Capability { id: "node-runtime", name: "Node.js 官方运行时", summary: "从 nodejs.org 获取 v22 x64，并通过官方 SHA-256 清单校验", size_mb: 0, installed: status.installed, status: if status.installed { status.node_version.unwrap_or_else(|| "已安装".into()) } else { "安装时联网获取".into() } },
    Capability { id: "web-search", name: "联网搜索", summary: "Harness 完整核心内置 DeepSeek、Exa 与 Perplexity 搜索适配器", size_mb: 0, installed: status.installed, status: if status.installed { "随完整核心安装".into() } else { "随完整核心下载".into() } },
    Capability { id: "security-audit", name: "安全审计", summary: "插件权限审查、危险文件拦截与 GitHub 来源约束", size_mb: 0, installed: true, status: "桌面端内置".into() },
  ]
}

#[tauri::command]
async fn install_components(app: AppHandle) -> Result<String, String> {
  tauri::async_runtime::spawn_blocking(move || install_components_blocking(app))
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn install_theme_from_github(repository: String) -> Result<String, String> {
  if !repository.starts_with("https://github.com/") {
    return Err("只允许安装 https://github.com/ 下的主题仓库。".into());
  }
  tauri::async_runtime::spawn_blocking(move || {
    let script = std::env::temp_dir().join(format!("dsharness-theme-{}.ps1", std::process::id()));
    fs::write(&script, THEME_INSTALL_SCRIPT).map_err(|error| error.to_string())?;
    let output = Command::new("powershell.exe")
      .args(["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
      .arg(&script)
      .arg("-Repository")
      .arg(&repository)
      .output()
      .map_err(|error| error.to_string())?;
    let _ = fs::remove_file(script);
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if output.status.success() { Ok(stdout) } else { Err(if stderr.is_empty() { stdout } else { stderr }) }
  }).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn check_core_update() -> Result<UpdateInfo, String> {
  tauri::async_runtime::spawn_blocking(|| {
    let script = "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $h=@{'User-Agent'='DSHarness/4.0'}; $feed=(Invoke-WebRequest -UseBasicParsing -Headers $h -Uri 'https://github.com/deepseek-ai/deepseek-harness/commits/master.atom').Content; [regex]::Match($feed, '/commit/([0-9a-f]{40})').Groups[1].Value";
    let output = Command::new("powershell.exe")
      .args(["-NoLogo", "-NoProfile", "-Command", script])
      .output()
      .map_err(|error| error.to_string())?;
    if !output.status.success() { return Err(String::from_utf8_lossy(&output.stderr).trim().to_string()) }
    let latest = String::from_utf8_lossy(&output.stdout).trim().to_lowercase();
    if latest.len() != 40 || !latest.chars().all(|value| value.is_ascii_hexdigit()) { return Err("GitHub 返回的版本标识无效。".into()) }
    let installed = runtime_status_value().core_commit;
    Ok(UpdateInfo { update_available: installed.as_deref() != Some(latest.as_str()), installed_commit: installed, latest_commit: latest })
  }).await.map_err(|error| error.to_string())?
}

#[tauri::command]
fn launch_harness(state: State<'_, AppState>) -> Result<String, String> {
  let address: SocketAddr = "127.0.0.1:3080".parse().map_err(|error: std::net::AddrParseError| error.to_string())?;
  if TcpStream::connect_timeout(&address, Duration::from_millis(300)).is_ok() {
    return Ok("http://127.0.0.1:3080".into());
  }
  let runtime = runtime_root()?;
  let node = runtime.join("node").join("node.exe");
  let core = runtime.join("harness-core");
  let cli = core.join("apps").join("cli").join("lib").join("bin.js");
  if !node.is_file() || !cli.is_file() { return Err("完整 Harness 核心尚未安装，请先在能力中心完成安装。".into()) }
  let home = data_root()?.join("harness-home");
  let logs = data_root()?.join("logs");
  fs::create_dir_all(&home).map_err(|error| error.to_string())?;
  fs::create_dir_all(&logs).map_err(|error| error.to_string())?;
  let stdout = fs::File::create(logs.join("harness.log")).map_err(|error| error.to_string())?;
  let stderr = stdout.try_clone().map_err(|error| error.to_string())?;
  let node_path = runtime.join("node");
  let current_path = std::env::var_os("PATH").unwrap_or_default();
  let path = format!("{};{}", node_path.display(), current_path.to_string_lossy());
  let child = Command::new(node)
    .arg(&cli)
    .args(["web", "--host", "127.0.0.1", "--port", "3080"])
    .current_dir(core)
    .env("DSH_HOME", home)
    .env("PATH", path)
    .stdout(Stdio::from(stdout))
    .stderr(Stdio::from(stderr))
    .spawn()
    .map_err(|error| format!("Harness 启动失败：{error}"))?;
  *state.harness.lock().map_err(|_| "Harness 进程状态不可用。".to_string())? = Some(child);
  let deadline = Instant::now() + Duration::from_secs(90);
  while Instant::now() < deadline {
    if TcpStream::connect_timeout(&address, Duration::from_millis(300)).is_ok() { return Ok("http://127.0.0.1:3080".into()) }
    thread::sleep(Duration::from_millis(500));
  }
  Err("Harness 启动超时，请查看 DSHarness 日志。".into())
}

#[tauri::command]
fn create_plugin(app: tauri::AppHandle, request: PluginRequest, _state: State<'_, AppState>) -> Result<PluginResult, String> {
  let task = request.task.trim();
  if task.len() < 4 { return Err("请用一句话描述插件要完成的任务。".into()) }
  let allowed = ["workspace:read", "workspace:write", "network"];
  if request.permissions.iter().any(|permission| !allowed.contains(&permission.as_str())) { return Err("插件请求了不受支持的权限。".into()) }
  let root = plugin_root(&app)?;
  fs::create_dir_all(&root).map_err(|error| error.to_string())?;
  let id = format!("task-{}", &Uuid::new_v4().simple().to_string()[..8]);
  let plugin_dir = root.join(&id);
  fs::create_dir_all(plugin_dir.join("src")).map_err(|error| error.to_string())?;
  let name = format!("任务插件：{}", task.chars().take(18).collect::<String>());
  let manifest = serde_json::json!({
    "id": id,
    "name": name,
    "version": "0.1.0",
    "kind": request.kind,
    "permissions": request.permissions,
    "entry": "src/index.js",
    "generatedBy": "DSHarness 插件工坊",
    "audit": { "status": "review-required", "sandbox": true }
  });
  let blueprint = format!("目标：{task}\n类型：{}\n权限：{}\n\n安全策略：默认隔离执行；安装前再次确认权限。\n下一步：配置模型后，可由 Harness 根据本设计继续完善实现。", request.kind, if request.permissions.is_empty() { "无".into() } else { request.permissions.join("、") });
  let source = format!("// {name}\n// 任务：{task}\nexport default async function run(context) {{\n  return {{ message: '插件骨架已创建，请继续实现：{task}', authorized: context.permissions }}\n}}\n");
  fs::write(plugin_dir.join("plugin.json"), serde_json::to_string_pretty(&manifest).map_err(|error| error.to_string())?).map_err(|error| error.to_string())?;
  fs::write(plugin_dir.join("README.md"), &blueprint).map_err(|error| error.to_string())?;
  fs::write(plugin_dir.join("src").join("index.js"), source).map_err(|error| error.to_string())?;
  Ok(PluginResult { id, name, path: plugin_dir.display().to_string(), blueprint })
}

#[tauri::command]
fn plugin_directory(app: tauri::AppHandle) -> Result<String, String> {
  let root = plugin_root(&app)?;
  fs::create_dir_all(&root).map_err(|error| error.to_string())?;
  Ok(root.display().to_string())
}

pub fn run() {
  tauri::Builder::default()
    .manage(AppState::default())
    .invoke_handler(tauri::generate_handler![
      runtime_status,
      launch_mode,
      set_theme_icon,
      capabilities,
      install_components,
      install_theme_from_github,
      check_core_update,
      launch_harness,
      create_plugin,
      plugin_directory
    ])
    .run(tauri::generate_context!())
    .expect("error while running DSHarness")
}

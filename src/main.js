import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'

const native = Boolean(window.__TAURI_INTERNALS__)
const fallbackCapabilities = [
  { id: 'harness-core', name: '完整 Harness 核心', summary: 'DeepSeek Harness 全部工作区、Agent、会话、模型配置与本地服务', sizeMb: 0, installed: false, status: '安装时联网获取' },
  { id: 'node-runtime', name: 'Node.js 官方运行时', summary: '从 nodejs.org 获取 v22 x64，并通过官方 SHA-256 清单校验', sizeMb: 0, installed: false, status: '安装时联网获取' },
  { id: 'web-search', name: '联网搜索', summary: 'Harness 完整核心内置多种搜索适配器', sizeMb: 0, installed: false, status: '随完整核心下载' },
  { id: 'security-audit', name: '安全审计', summary: '插件权限审查、危险文件拦截与 GitHub 来源约束', sizeMb: 0, installed: true, status: '桌面端内置' },
]

const state = {
  view: 'workbench',
  theme: localStorage.getItem('dsh-theme') || 'light',
  capabilities: [],
  plugins: [],
  runtime: { installed: false },
  busy: false,
  message: '',
  harnessUrl: '',
  task: { active: false, percent: 0, stage: '', elapsedSeconds: 0, etaSeconds: null, logs: [] },
}
const app = document.querySelector('#app')

function escape(value) {
  return String(value ?? '').replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char])
}

function nav() {
  return `
    <aside class="sidebar">
      <div class="brand"><img src="/assets/${state.theme === 'whale' ? 'whale-maid.png' : 'black-whale-centered.png'}"><span>DSHarness <small>DESKTOP WORKBENCH</small></span></div>
      <button class="new-task" data-view="workbench">＋ 新建任务</button>
      <nav>
        <button class="nav ${state.view === 'workbench' ? 'active' : ''}" data-view="workbench">◈ 工作台</button>
        <button class="nav ${state.view === 'capabilities' ? 'active' : ''}" data-view="capabilities">◌ 能力中心</button>
        <button class="nav ${state.view === 'workshop' ? 'active' : ''}" data-view="workshop">✦ 插件工坊</button>
        <button class="nav ${state.view === 'settings' ? 'active' : ''}" data-view="settings">⚙ 更新与设置</button>
      </nav>
      <div class="sidebar-foot"><span class="pulse ${state.runtime.installed ? '' : 'pending'}"></span>${state.runtime.installed ? '完整核心 · 就绪' : '完整核心 · 等待安装'}</div>
    </aside>`
}

function topbar() {
  const labels = { workbench: '任务工作台', capabilities: '能力中心', workshop: '插件工坊', settings: '更新与设置' }
  return `<header><div class="crumb">${labels[state.view]}</div><div class="header-controls"><div class="quick-actions"><button id="quick-update" ${state.busy ? 'disabled' : ''}>↻ 更新</button><button id="quick-repair" class="quick-repair" ${state.busy ? 'disabled' : ''}>⌁ 修复</button></div><div class="themes"><button data-theme="dark" class="${state.theme === 'dark' ? 'selected' : ''}">深</button><button data-theme="light" class="${state.theme === 'light' ? 'selected' : ''}">浅</button><button data-theme="whale" class="${state.theme === 'whale' ? 'selected' : ''}">鲸</button></div></div></header>`
}

function whaleCharacters() {
  if (state.theme !== 'whale') return ''
  return `<div class="atelier-scene" aria-hidden="true"><img class="maid maid-left" src="/assets/maid-left.webp"><img class="maid maid-right" src="/assets/maid-right.webp"></div>`
}

function workbench() {
  return `<section class="workbench">${whaleCharacters()}<div class="mast"><span class="eyebrow">DSHARNESS 4.0 DESKTOP</span><h1>完整 Harness，原生桌面工作台。</h1><p>基础安装保持轻量；安装阶段从官方来源获取完整 Harness 核心、Node.js 与联网搜索能力。</p></div><div class="cards"><article><b>完整核心</b><span>Agent、会话、模型、工具与全部工作区</span><i>${state.runtime.installed ? '已安装' : '等待安装'}</i></article><article><b>可信下载</b><span>DeepSeek 官方 GitHub、Node 官方校验清单</span><i>固定可信域名</i></article><article><b>插件工坊</b><span>任务生成、权限声明与安装前审计</span><i>${state.plugins.length} 个本地草案</i></article></div><div class="compose"><span>${state.runtime.installed ? '完整核心已就绪，可以进入 Harness 工作台。' : '请先在能力中心完成完整组件安装。'}</span><button id="launch-core" ${state.busy ? 'disabled' : ''}>${state.runtime.installed ? '进入 Harness →' : '安装完整核心 →'}</button></div>${state.message ? `<div class="status-message">${escape(state.message)}</div>` : ''}</section>`
}

function capabilities() {
  return `<section class="page"><div class="heading"><span class="eyebrow">REQUIRED COMPONENTS</span><h1>完整能力安装</h1><p>Harness 核心不是精简版。下载、依赖安装和构建过程会完整显示在下方的任务面板中；预计安装后占用 1.8–3 GB。</p></div><div class="cap-grid">${state.capabilities.map(cap => `<article class="cap"><div><span class="cap-dot ${cap.installed ? '' : 'pending'}"></span><b>${escape(cap.name)}</b><small>${escape(cap.summary)}</small></div><footer><span>${escape(cap.status)}</span><strong>${cap.installed ? '✓' : '↓'}</strong></footer></article>`).join('')}</div><div class="actions"><button id="install-all" class="primary" ${state.busy ? 'disabled' : ''}>${state.busy ? '正在处理完整组件…' : state.runtime.installed ? '修复完整组件' : '安装完整 Harness 组件'}</button><button id="check-update" ${state.busy ? 'disabled' : ''}>检查并更新核心</button></div>${state.message ? `<div class="status-message">${escape(state.message)}</div>` : ''}<p class="notice">Node 包会按 nodejs.org 的 SHASUMS256.txt 校验；Harness 来源固定为 deepseek-ai/deepseek-harness；npm 依赖按锁文件完整性校验。</p></section>`
}

function workshop() {
  return `<section class="page workshop"><div class="heading"><span class="eyebrow">PLUGIN FORGE</span><h1>内置插件工坊</h1><p>描述任务并声明权限，工坊先生成可审计骨架。完整核心与模型就绪后，可继续由 Harness 完善插件实现。</p></div><div class="github-theme"><div><b>从 GitHub 安装声明式主题</b><small>仅允许 github.com；拒绝脚本和可执行文件，限制 50 MB / 2000 文件。</small></div><div><input id="theme-url" placeholder="https://github.com/owner/theme-repo"><button id="install-theme">安全审计并安装</button></div><p id="theme-result"></p></div><div class="forge"><label>插件要完成什么？<textarea id="task" placeholder="例如：把当前会话导出为带引用的 Markdown 周报"></textarea></label><div class="two"><label>插件类型<select id="kind"><option value="tool">任务工具</option><option value="integration">外部集成</option><option value="theme">界面主题</option></select></label><fieldset><legend>允许的能力</legend><label><input type="checkbox" value="workspace:read"> 读取工作区</label><label><input type="checkbox" value="workspace:write"> 写入工作区</label><label><input type="checkbox" value="network"> 联网</label></fieldset></div><button id="forge" class="primary">生成插件设计与骨架</button><div id="forge-result"></div></div><div class="drafts"><b>本地插件草案</b>${state.plugins.length ? state.plugins.map(item => `<div><span>${escape(item.name)}</span><small>${escape(item.path)}</small></div>`).join('') : '<p>还没有草案。每个草案安装前都需要再次确认权限。</p>'}</div></section>`
}

function settings() {
  const commit = state.runtime.coreCommit ? state.runtime.coreCommit.slice(0, 8) : '未安装'
  return `<section class="page"><div class="heading"><span class="eyebrow">UPDATE & APPEARANCE</span><h1>更新与设置</h1><p>更新会检查 DeepSeek 官方 GitHub 的 Harness 核心提交；下载进度、命令输出和预计剩余时间会持续显示在桌面端。</p></div><div class="settings-card"><div><b>DSHarness 桌面端</b><span>版本 4.0.1 · 原生轻量壳</span></div><div><b>Harness 核心</b><span>提交 ${escape(commit)} · Node ${escape(state.runtime.nodeVersion || '未安装')}</span></div><div><b>当前主题</b><span>${state.theme === 'dark' ? '深色' : state.theme === 'light' ? '浅色' : '鲸鱼娘工坊'}</span></div></div><div class="actions"><button id="settings-update" class="primary" ${state.busy ? 'disabled' : ''}>检查并安装更新</button><button id="settings-repair" ${state.busy ? 'disabled' : ''}>修复完整核心</button></div>${state.message ? `<div class="status-message">${escape(state.message)}</div>` : ''}</section>`
}

function duration(seconds) {
  if (seconds == null || !Number.isFinite(seconds)) return '计算中'
  if (seconds < 60) return `${Math.max(1, Math.round(seconds))} 秒`
  const minutes = Math.floor(seconds / 60)
  const remainder = Math.round(seconds % 60)
  return `${minutes} 分 ${remainder} 秒`
}

function taskPanel() {
  const task = state.task
  if (!task.active && !task.logs.length) return ''
  const heading = task.active ? '完整核心任务正在运行' : task.percent >= 100 ? '完整核心任务已完成' : '最近一次完整核心任务'
  const logs = task.logs.slice(-180).map(escape).join('\n') || '等待命令输出…'
  const eta = task.active ? `预计剩余：${duration(task.etaSeconds)}` : task.percent >= 100 ? `耗时：${duration(task.elapsedSeconds)}` : '任务未完成'
  return `<aside class="install-panel ${task.active ? 'running' : ''}"><div class="install-panel-head"><div><span class="eyebrow">LIVE INSTALL CONSOLE</span><b>${heading}</b></div><button id="close-task" ${task.active ? 'disabled title="任务运行中，不能关闭日志"' : ''}>×</button></div><div class="install-stage"><div><span>${escape(task.stage || '准备中')}</span><strong>${task.percent}%</strong></div><progress max="100" value="${task.percent}"></progress><small>已用时：${duration(task.elapsedSeconds)} · ${eta}</small></div><pre id="install-log" class="install-log">${logs}</pre></aside>`
}

function harnessView() {
  return `<div class="harness-shell"><div class="harness-bar"><button id="leave-harness">← DSHarness</button><span>完整 Harness 工作台</span><i>本地安全连接 · 127.0.0.1</i></div><iframe src="${escape(state.harnessUrl)}" title="Harness 工作台"></iframe></div>`
}

function render() {
  document.documentElement.dataset.theme = state.theme
  if (state.harnessUrl) {
    app.innerHTML = harnessView()
    document.querySelector('#leave-harness').onclick = () => { state.harnessUrl = ''; render() }
    return
  }
  const body = state.view === 'workbench' ? workbench() : state.view === 'capabilities' ? capabilities() : state.view === 'workshop' ? workshop() : settings()
  app.innerHTML = `${nav()}<main>${topbar()}${body}${taskPanel()}</main>`
  bind()
  const installLog = document.querySelector('#install-log')
  if (installLog) installLog.scrollTop = installLog.scrollHeight
}

async function refresh() {
  if (!native) return
  state.runtime = await invoke('runtime_status')
  state.capabilities = await invoke('capabilities')
}

async function runInstall(reason = '正在下载并构建完整 Harness；此过程可能需要较长时间，请不要关闭应用。') {
  state.busy = true
  state.view = 'capabilities'
  state.message = reason
  state.task = { active: true, percent: 1, stage: '正在启动安装任务', elapsedSeconds: 0, etaSeconds: null, logs: ['$ 启动完整 Harness 安装任务…'] }
  render()
  try {
    await invoke('install_components')
    await refresh()
      state.message = '完整 Harness 核心、Node.js 与联网搜索能力已安装。'
  } catch (error) {
    state.message = `安装失败：${String(error)}`
  } finally {
    state.busy = false
    state.task.active = false
    render()
  }
}

async function checkUpdate(installWhenFound = false) {
  state.busy = true
  state.message = '正在检查 DeepSeek 官方 GitHub…'
  render()
  try {
    const result = await invoke('check_core_update')
    if (result.updateAvailable && installWhenFound) {
      state.busy = false
      await runInstall(`发现新提交 ${result.latestCommit.slice(0, 8)}，正在下载并更新完整核心…`)
      return
    } else {
      state.message = result.updateAvailable ? `发现新版本：${result.latestCommit.slice(0, 8)}。点击“修复/重新安装”即可更新。` : '当前 Harness 核心已是最新版。'
    }
  } catch (error) {
    state.message = `检查更新失败：${String(error)}`
  } finally {
    state.busy = false
    render()
  }
}

function bind() {
  document.querySelectorAll('[data-view]').forEach(button => button.onclick = () => { state.view = button.dataset.view; state.message = ''; render() })
  document.querySelectorAll('[data-theme]').forEach(button => button.onclick = async () => {
    state.theme = button.dataset.theme
    localStorage.setItem('dsh-theme', state.theme)
    if (native) await invoke('set_theme_icon', { theme: state.theme }).catch(() => {})
    render()
  })
  document.querySelector('#launch-core')?.addEventListener('click', async () => {
    if (!state.runtime.installed) { state.view = 'capabilities'; render(); return }
    state.busy = true; state.message = '正在启动 Harness…'; render()
    try { state.harnessUrl = await invoke('launch_harness') } catch (error) { state.message = String(error) }
    state.busy = false; render()
  })
  document.querySelector('#install-all')?.addEventListener('click', runInstall)
  document.querySelector('#check-update')?.addEventListener('click', () => checkUpdate(false))
  document.querySelector('#settings-update')?.addEventListener('click', () => checkUpdate(true))
  document.querySelector('#settings-repair')?.addEventListener('click', () => runInstall('正在修复并重新安装完整核心…'))
  document.querySelector('#quick-repair')?.addEventListener('click', () => runInstall('正在修复并重新安装完整核心…'))
  document.querySelector('#quick-update')?.addEventListener('click', () => state.runtime.installed ? checkUpdate(true) : runInstall())
  document.querySelector('#close-task')?.addEventListener('click', () => { if (!state.task.active) { state.task.logs = []; render() } })
  document.querySelector('#install-theme')?.addEventListener('click', async () => {
    const repository = document.querySelector('#theme-url').value.trim()
    const output = document.querySelector('#theme-result')
    output.textContent = '正在从 GitHub 下载并进行静态安全审计…'
    try { output.textContent = native ? await invoke('install_theme_from_github', { repository }) : '预览模式不会下载主题。' }
    catch (error) { output.textContent = `安装被拒绝：${String(error)}` }
  })
  const forgeButton = document.querySelector('#forge')
  if (forgeButton) forgeButton.onclick = async () => {
    const task = document.querySelector('#task').value
    const kind = document.querySelector('#kind').value
    const permissions = [...document.querySelectorAll('fieldset input:checked')].map(input => input.value)
    const output = document.querySelector('#forge-result')
    output.textContent = '正在生成可审计插件骨架…'
    try {
      const plugin = native ? await invoke('create_plugin', { request: { task, kind, permissions } }) : { name: `任务插件：${task}`, path: '预览模式', blueprint: `目标：${task}\n权限：${permissions.join('、') || '无'}` }
      state.plugins.unshift(plugin)
      output.innerHTML = `<b>已生成：${escape(plugin.name)}</b><pre>${escape(plugin.blueprint)}</pre>`
    } catch (error) { output.textContent = String(error) }
  }
}

document.addEventListener('mousemove', event => {
  const x = (event.clientX / window.innerWidth - 0.5) * 2
  const y = (event.clientY / window.innerHeight - 0.5) * 2
  document.documentElement.style.setProperty('--gaze-x', `${x * 7}px`)
  document.documentElement.style.setProperty('--gaze-y', `${y * 4}px`)
})

state.capabilities = native ? await invoke('capabilities') : fallbackCapabilities
state.runtime = native ? await invoke('runtime_status') : { installed: false }
if (native) await invoke('set_theme_icon', { theme: state.theme }).catch(() => {})
if (native) {
  let queued = false
  await listen('install-progress', event => {
    const payload = event.payload
    state.task.percent = Math.max(state.task.percent, Number(payload.percent || 0))
    state.task.stage = payload.message || state.task.stage
    state.task.elapsedSeconds = Number(payload.elapsedSeconds || 0)
    state.task.etaSeconds = payload.etaSeconds == null ? null : Number(payload.etaSeconds)
    if (payload.kind === 'log') state.task.logs.push(payload.message)
    else state.task.logs.push(`[${payload.percent}%] ${payload.message}`)
    if (state.task.logs.length > 500) state.task.logs.splice(0, state.task.logs.length - 500)
    if (!queued) {
      queued = true
      requestAnimationFrame(() => { queued = false; render() })
    }
  })
}
render()
if (native && !state.runtime.installed && await invoke('launch_mode').catch(() => 'normal') === 'setup') {
  setTimeout(() => runInstall('首次启动：正在在桌面端部署完整 Harness、Node.js 与联网搜索能力…'), 500)
}

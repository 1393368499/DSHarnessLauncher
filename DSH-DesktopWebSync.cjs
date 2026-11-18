'use strict'

const fs = require('node:fs/promises')
const { existsSync } = require('node:fs')
const { createHash } = require('node:crypto')
const { createRequire } = require('node:module')
const { homedir } = require('node:os')
const { createConnection } = require('node:net')
const { dirname, join, basename, resolve } = require('node:path')
const { pathToFileURL } = require('node:url')

const manifestName = 'package.json'
const lockName = 'pnpm-lock.yaml'
const workspaceName = 'pnpm-workspace.yaml'
const patchName = 'cordis.patch.yml'
const stagePrefix = '.web-desktop-sync-'
const sourceNames = [manifestName, lockName, patchName]
const targetNames = [manifestName, lockName, workspaceName, patchName]
const packageName = /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/
const registryVersion = /^[~^]?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/
const modelIds = new Set([
  'agent-default-model', 'llm-pi-ai', 'llm-deepseek', 'llm-deepseek-account', 'llm-deepseek-api-key',
])

async function readOptional(path) {
  try { return await fs.readFile(path) }
  catch (error) { if (error.code !== 'ENOENT') throw error }
}

async function fingerprints(directory, names) {
  const hashes = []
  for (const name of names) {
    const file = await readOptional(join(directory, name))
    hashes.push(file === undefined ? null : createHash('sha256').update(file).digest('hex'))
  }
  return hashes
}

function parseManifest(buffer) {
  const manifest = JSON.parse(buffer.toString('utf8').replace(/^\uFEFF/, ''))
  const bundles = manifest.dsh?.profile?.bundles
  const dependencies = Object.entries(manifest.dependencies ?? {}).sort(([a], [b]) => a.localeCompare(b))
  if (!Array.isArray(bundles) || !bundles.includes('@deepseek-ai/dsh-base') || !bundles.includes('@deepseek-ai/dsh-web-app') ||
      bundles.some(name => typeof name !== 'string' || !packageName.test(name)) ||
      dependencies.some(([name, spec]) => !packageName.test(name) || typeof spec !== 'string')) {
    throw new Error('Invalid profile plugin manifest.')
  }
  return { manifest, bundles, dependencies }
}

function validateDesktopSpecs(dependencies) {
  for (const [name, spec] of dependencies) {
    if (registryVersion.test(spec) ||
        /^github:[\w.-]+\/[\w.-]+#[a-f0-9]{40}$/i.test(spec) ||
        /^(?:link|file):[A-Za-z]:[\\/][^\r\n]+$/.test(spec)) continue
    throw new Error('Unsupported or unpinned desktop plugin source: ' + name)
  }
}

async function installedVersions(directory, dependencies) {
  const versions = []
  for (const [name] of dependencies) {
    const file = await readOptional(join(directory, 'node_modules', name, manifestName))
    if (!file) { versions.push(null); continue }
    const manifest = JSON.parse(file.toString('utf8').replace(/^\uFEFF/, ''))
    versions.push(manifest.name === name && typeof manifest.version === 'string' ? manifest.version : null)
  }
  return versions
}

async function copyLockedDesktopCache(desktop, stage, dependencies, sourceLockHash) {
  const from = join(desktop, 'node_modules')
  const into = join(stage, 'node_modules')
  if ((await fingerprints(from, [join('.pnpm', 'lock.yaml')]))[0] !== sourceLockHash) return false
  const links = new Map()
  for (const [name, spec] of dependencies) {
    if (spec.startsWith('link:')) links.set(join(from, name), await fs.realpath(spec.slice(5)))
  }
  const expectedLinks = []
  try {
    await fs.cp(from, into, {
      recursive: true, force: false, errorOnExist: true,
      async filter(source, target) {
        if (!(await fs.lstat(source)).isSymbolicLink()) return true
        const expected = links.get(source)
        if (!expected || await fs.realpath(source) !== expected) throw new Error('Unexpected package link.')
        expectedLinks.push([expected, target])
        return false
      },
    })
    for (const [target, path] of expectedLinks) {
      await fs.mkdir(dirname(path), { recursive: true })
      await fs.symlink(target, path, 'junction')
    }
    return true
  } catch {
    await fs.rm(into, { recursive: true, force: true })
    return false
  }
}

async function setWebStorePath(yaml, stage, web) {
  const file = join(stage, 'node_modules', '.modules.yaml')
  const document = yaml.parseDocument(await fs.readFile(file, 'utf8'), { prettyErrors: false })
  if (document.errors.length > 0 || !yaml.isMap(document.contents)) throw new Error('Invalid profile package-store metadata.')
  document.set('virtualStoreDir', join(web, 'node_modules', '.pnpm'))
  await fs.writeFile(file, document.toString())
}

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b)
}

function yamlTools(harness) {
  const requireYaml = createRequire(join(harness, 'packages', 'boot', 'config-editor', manifestName))
  return requireYaml('yaml')
}

function patchDocument(yaml, text) {
  const document = yaml.parseDocument(text || '[]', { prettyErrors: false })
  if (document.errors.length > 0 || !yaml.isSeq(document.contents)) {
    throw new Error('Invalid profile settings document.')
  }
  return document
}

function modelPatch(yaml, desktop, web) {
  const from = patchDocument(yaml, desktop)
  const into = patchDocument(yaml, web)
  const isModel = row => yaml.isMap(row) && modelIds.has(row.get('id'))
  const source = from.contents.items.filter(isModel)
  for (const row of source) {
    yaml.visit(row, {
      Alias() { throw new Error('A model setting uses a YAML alias outside its profile.') },
      Pair(_, pair) {
        if (/^(?:api.?key|token|password|secret|authorization)$/i.test(String(pair.key?.value ?? ''))) {
          throw new Error('Move inline model credentials to the shared credential store before syncing.')
        }
      },
    })
  }
  if (same(source.map(row => row.toJSON()), into.contents.items.filter(isModel).map(row => row.toJSON()))) return undefined
  into.contents.items = [...into.contents.items.filter(row => !isModel(row)), ...source.map(row => row.clone())]
  return into.toString()
}

async function runtimeTools(harness) {
  const cli = createRequire(join(harness, 'apps', 'cli', manifestName))
  const manager = createRequire(join(harness, 'packages', 'boot', 'plugin-manager', manifestName))
  async function load(requireFrom, name) {
    return import(pathToFileURL(requireFrom.resolve(name)).href)
  }
  return {
    ...await load(cli, '@deepseek-ai/dsh-plugin-manager/operations'),
    ...await load(cli, '@deepseek-ai/dsh-official-bundles'),
    ...await load(manager, '@deepseek-ai/dsh-atomic-write'),
    ...await load(manager, '@deepseek-ai/dsh-app-boot'),
  }
}

function lockDependencies(lock) {
  return lock?.importers?.['.']?.dependencies ?? {}
}

function mismatchedPluginLocks(lock, desktopLock, dependencies, substitutions) {
  const entries = lockDependencies(lock)
  const desktopEntries = lockDependencies(desktopLock)
  return dependencies.filter(([name, spec]) => {
    const entry = entries[name]
    if (entry?.specifier !== spec || typeof entry.version !== 'string') return true
    if (substitutions.has(name)) {
      const resolution = lock.packages?.[`${name}@${spec}`]?.resolution
      return entry.version !== spec || typeof resolution?.integrity !== 'string'
    }
    // pnpm can rebind peer contexts when the official packages change. Match
    // the same package release and its locked resolution, not the peer suffix.
    const reference = desktopEntries[name]?.version?.split('(')[0]
    if (entry.version.split('(')[0] !== reference) return true
    const key = `${name}@${reference}`
    return !same(lock.packages?.[key]?.resolution, desktopLock.packages?.[key]?.resolution)
  }).map(([name]) => name)
}

async function collectPluginFlags(directory, name, tools, pluginIds) {
  const manifest = JSON.parse(await fs.readFile(join(directory, manifestName), 'utf8'))
  if (manifest.name !== name || tools.evaluatePluginCompatibility(manifest)) {
    throw new Error('Web compatibility rejected: ' + name)
  }
  if (!manifest.dsh?.bundle) return
  tools.assertBundlePlatform(manifest.dsh.bundle.platforms, process.platform)
  for (const path of tools.bundlePatchPaths(directory, manifest.dsh.bundle)) {
    for (const patch of tools.loadOverlayPatches('dsh', path)) {
      for (const entry of patch.insert ?? []) if (typeof entry?.id === 'string') pluginIds.add(entry.id)
    }
  }
}

async function preparePlugins(harness, desktop, web, tools) {
  const [source, target] = await Promise.all([fingerprints(desktop, sourceNames), fingerprints(web, targetNames)])
  const raw = await readOptional(join(desktop, manifestName))
  if (!raw) return 'missing'
  const desired = parseManifest(raw)
  validateDesktopSpecs(desired.dependencies)
  const expected = await installedVersions(desktop, desired.dependencies)
  if (expected.includes(null)) throw new Error('Some desktop plugin packages are missing. Repair the desktop profile first.')
  const current = parseManifest(await fs.readFile(join(web, manifestName)))
  if (!source[1] || !target[2]) throw new Error('Desktop lockfile or Web package policy is missing.')

  const yaml = yamlTools(harness)
  const desktopLock = yaml.parse(await fs.readFile(join(desktop, lockName), 'utf8'))
  const webLock = yaml.parse((await readOptional(join(web, lockName)))?.toString('utf8') ?? '')
  const desktopPatch = patchDocument(yaml, (await readOptional(join(desktop, patchName)))?.toString('utf8'))
  const webPatch = patchDocument(yaml, (await readOptional(join(web, patchName)))?.toString('utf8'))
  const substitutions = new Set()
  const dependencies = []
  for (const [index, [name, spec]] of desired.dependencies.entries()) {
    const directory = join(desktop, 'node_modules', name)
    const manifest = JSON.parse(await fs.readFile(join(directory, manifestName), 'utf8'))
    if (!tools.evaluatePluginCompatibility(manifest)) {
      dependencies.push([name, spec])
      continue
    }
    // Official on-demand packages are released in lockstep with the core.
    // Preserve desktop membership, and keep the Web runtime's exact version.
    if (!tools.ON_DEMAND_BUNDLES?.includes(name) || !registryVersion.test(spec)) {
      throw new Error('Web compatibility rejected: ' + name)
    }
    const version = tools.getDshRuntimeVersion()
    substitutions.add(name)
    dependencies.push([name, version])
    expected[index] = version
  }

  const pluginChanges = !same(dependencies, current.dependencies) || !same(desired.bundles, current.bundles) ||
    !same(expected, await installedVersions(web, dependencies)) ||
    (substitutions.size === 0 ? source[1] !== target[1] : mismatchedPluginLocks(webLock, desktopLock, dependencies, substitutions).length > 0)

  const stage = await fs.mkdtemp(join(dirname(web), stagePrefix))
  try {
    if (pluginChanges) {
      current.manifest.dependencies = Object.fromEntries(dependencies)
      current.manifest.dsh.profile.bundles = desired.bundles
      await fs.writeFile(join(stage, manifestName), JSON.stringify(current.manifest, null, 2) + '\n')
      await fs.copyFile(join(desktop, lockName), join(stage, lockName))
      await fs.copyFile(join(web, workspaceName), join(stage, workspaceName))
      if (substitutions.size > 0 || !await copyLockedDesktopCache(desktop, stage, dependencies, source[1])) {
        const proxy = process.env.DSH_PLUGIN_SYNC_HTTPS_PROXY
        const env = proxy && /^http:\/\/127\.0\.0\.1:\d{1,5}\/?$/.test(proxy)
          ? { HTTPS_PROXY: proxy, https_proxy: proxy, npm_config_https_proxy: proxy }
          : {}
        const metadata = await readOptional(join(web, 'node_modules', '.modules.yaml'))
        const existingStore = metadata && yaml.parse(metadata.toString('utf8'))?.storeDir
        const store = typeof existingStore === 'string' && resolve(existingStore) === existingStore
          ? [ '--config.store-dir=' + (/^v\d+$/.test(basename(existingStore)) ? dirname(existingStore) : existingStore) ]
          : []
        const lockMode = substitutions.size > 0 ? '--no-frozen-lockfile' : '--frozen-lockfile'
        const result = await tools.runPluginCommand(
          { profile: 'web', dir: stage, cwd: stage, installAnchor: join(harness, manifestName) },
          ['install', lockMode, '--ignore-scripts', '--prefer-offline', '--fetch-retries=1', '--fetch-timeout=150000', ...store],
          { execution: 'service', outputBytes: 4096, idleTimeoutMs: 180000, activateNewBundles: false, env },
        )
        if (result.exitCode !== 0) {
          const names = [...new Set((result.incompatible ?? []).map(issue => issue.name))].filter(name => packageName.test(name))
          throw new Error(names.length ? 'Web compatibility rejected: ' + names.join(', ') : 'Locked desktop plugin download failed.')
        }
      }
      if (!same(expected, await installedVersions(stage, dependencies))) throw new Error('Staged plugin versions differ from the synchronization plan.')
      if (substitutions.size === 0 && (await fingerprints(stage, [lockName]))[0] !== source[1]) {
        throw new Error('Plugin lockfile changed unexpectedly during installation.')
      }
      if (substitutions.size > 0) {
        const updatedLock = yaml.parse(await fs.readFile(join(stage, lockName), 'utf8'))
        const mismatches = mismatchedPluginLocks(updatedLock, desktopLock, dependencies, substitutions)
        if (mismatches.length) throw new Error('Plugin lockfile changed unexpectedly for: ' + mismatches.join(', '))
      }
      await setWebStorePath(yaml, stage, web)
    }

    const pluginIds = new Set()
    const pluginRoot = join(pluginChanges ? stage : web, 'node_modules')
    for (const [name] of dependencies) await collectPluginFlags(join(pluginRoot, name), name, tools, pluginIds)
    const preference = row => yaml.isMap(row) && pluginIds.has(row.get('id')) && typeof row.get('disabled') === 'boolean'
    const flags = rows => rows.filter(preference).map(row => ({ id: row.get('id'), disabled: row.get('disabled') }))
    const desktopFlags = flags(desktopPatch.contents.items)
    const flagChanges = !same(desktopFlags, flags(webPatch.contents.items))
    if (!pluginChanges && !flagChanges) {
      await fs.rmdir(stage)
      return 'aligned'
    }
    if (flagChanges) {
      const previousFlags = new Set(webPatch.contents.items.filter(preference))
      for (const row of previousFlags) row.delete('disabled')
      webPatch.contents.items = webPatch.contents.items.filter(row => !previousFlags.has(row) || row.items.length > 1)
      for (const flag of desktopFlags) webPatch.contents.items.push(webPatch.createNode(flag))
      await fs.writeFile(join(stage, patchName), webPatch.toString(), { flag: 'wx' })
    }
    await fs.writeFile(join(stage, 'state.json'), JSON.stringify({ source, target, pluginChanges, flagChanges }))
    return stage
  } catch (error) {
    await fs.rm(stage, { recursive: true, force: true }).catch(() => {})
    throw error
  }
}

async function applyPlugins(desktop, web, stage, tools) {
  if (!stage || dirname(stage) !== dirname(web) || !basename(stage).startsWith(stagePrefix) ||
      await fs.realpath(stage) !== stage) throw new Error('Invalid plugin staging directory.')
  const state = JSON.parse(await fs.readFile(join(stage, 'state.json'), 'utf8'))
  return tools.withFileLock(join(web, manifestName), async () => {
    if (!same(state.source, await fingerprints(desktop, sourceNames)) ||
        !same(state.target, await fingerprints(web, targetNames))) {
      throw new Error('A profile changed during the download. Run Check Updates again.')
    }
    const backup = await fs.mkdtemp(join(dirname(web), '.web-before-desktop-sync-'))
    const moves = []
    async function move(from, to) {
      await fs.rename(from, to)
      moves.push([from, to])
    }
    const names = state.pluginChanges ? [manifestName, lockName, 'node_modules'] : []
    if (state.flagChanges) names.push(patchName)
    try {
      for (const name of names) {
        const live = join(web, name)
        if (existsSync(live)) await move(live, join(backup, name))
        await move(join(stage, name), live)
      }
    } catch {
      for (const [from, to] of moves.reverse()) await fs.rename(to, from)
      throw new Error('Could not apply desktop plugins. The previous Web plugin files were restored.')
    }
    return backup
  })
}

function requireStoppedWeb() {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: '127.0.0.1', port: 3080 })
    const blocked = () => {
      socket.destroy()
      reject(new Error('Stop the WebUI before applying staged desktop plugins.'))
    }
    socket.setTimeout(1500)
    socket.once('connect', blocked)
    socket.once('timeout', blocked)
    socket.once('error', error => {
      socket.destroy()
      if (error.code === 'ECONNREFUSED') resolve()
      else reject(new Error('Could not verify that WebUI is stopped.'))
    })
  })
}

async function main([mode, harnessArg, stage]) {
  const harness = resolve(harnessArg)
  const home = await fs.realpath(process.env.DSH_HOME || join(homedir(), '.dsh'))
  const desktop = join(home, 'profiles', 'desktop')
  const web = join(home, 'profiles', 'web')
  const tools = await runtimeTools(harness)
  if (mode === 'stage-plugins') return preparePlugins(harness, desktop, web, tools)
  if (mode === 'apply-plugins') {
    await requireStoppedWeb()
    return applyPlugins(desktop, web, stage, tools)
  }
  if (mode === 'check-models' || mode === 'sync-models') {
    const path = join(web, patchName)
    return tools.withFileLock(path, async () => {
      const from = await fs.readFile(join(desktop, patchName), 'utf8')
      const into = (await readOptional(path))?.toString('utf8')
      const content = modelPatch(yamlTools(harness), from, into)
      if (content === undefined) return 'aligned'
      if (mode === 'check-models') return 'different'
      const backup = await fs.mkdtemp(join(dirname(web), '.web-before-model-sync-'))
      if (into !== undefined) await fs.copyFile(path, join(backup, patchName))
      await tools.writeFileAtomic(path, content, { mode: 0o600 })
      return backup
    })
  }
  throw new Error('Unknown desktop-to-Web sync operation.')
}

module.exports = { modelPatch, parseManifest, validateDesktopSpecs, preparePlugins, applyPlugins }

if (require.main === module) {
  main(process.argv.slice(2)).then(result => console.log(result)).catch(error => {
    // The profile contents and registry output can contain credentials.
    const known = /^(Invalid profile|Unsupported or unpinned|Some desktop plugin|Desktop lockfile|A model setting|Move inline model|Web compatibility rejected|Locked desktop plugin|Staged packages|Plugin lockfile changed|Invalid plugin staging|A profile changed|Could not apply|Stop the WebUI|Could not verify|Unknown desktop-to-Web)/
    console.error(known.test(error.message) ? error.message : 'Desktop-to-Web synchronization failed.')
    process.exitCode = 1
  })
}

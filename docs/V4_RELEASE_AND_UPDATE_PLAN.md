# DSHarness V4 release and update plan

## Goals

Deliver a Windows x64 desktop application that is usable immediately after installation, ships the complete official Harness core, defaults to the light theme, and updates the desktop application from `1393368499/DSHarness`.

## Source and trust boundaries

| Component | Authoritative source | Verification |
| --- | --- | --- |
| DSHarness desktop shell | This repository and its signed GitHub Releases | Signed release metadata and installer signature |
| Harness core | [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) (official upstream) | Pinned commit SHA, locked dependency graph and post-build health check |
| Node.js | nodejs.org | Official SHA-256 manifest |
| User-installed themes | GitHub URL supplied in the workshop | Manifest, size/file limits and static safety audit before activation |

The desktop app never treats a third-party theme or plugin as trusted code merely because it is hosted on GitHub.

## Full offline installer

The release artifact is `DSHarness-<version>-full-x64-setup.exe`. It contains:

1. The signed DSHarness native shell and its UI assets.
2. The centered black-whale application icon, in all Windows icon sizes.
3. A complete Node.js x64 runtime.
4. A tested snapshot of the complete official Harness repository, all production dependencies, build output and an offline package store.
5. The integrated web-search adapter, plugin workshop and security-audit module.

On first launch, the application extracts the local payload to its runtime directory and performs an offline dependency relink. The task panel displays the same progress, elapsed time, remaining-time estimate and detailed command output as an online repair, but it does not download the full runtime again.

This is intentionally not a 200 MB installer. A complete Node + full Harness dependency graph is expected to make the installer roughly 1.2–2.0 GB and the installed footprint roughly 1.7–3.0 GB. The small online installer remains an optional separate channel for people who prefer a fast initial download.

## Update behaviour

### Desktop application update

1. On manual `检查更新`, and once per day in the background, the desktop app reads the signed `latest.json` file from this repository's GitHub Releases.
2. It compares the semantic version with the installed desktop version.
3. If newer, it shows release notes, download size and a single `下载并重启安装` action.
4. The update package is downloaded to a staging directory, its signature is checked, and only then is the NSIS installer launched silently.
5. The app exits, installation completes, and DSHarness restarts. A failed download, signature failure or cancelled action leaves the existing installation untouched.
6. The previous package is retained until the first successful restart so the repair page can recover from an interrupted update.

The updater endpoint is:

```
https://github.com/1393368499/DSHarness/releases/latest/download/latest.json
```

The update signing private key is stored only as the GitHub Actions secret `TAURI_SIGNING_PRIVATE_KEY`; the public key is embedded in the application configuration. No signing material is committed to this repository.

### Harness core update

This is a separate action from updating DSHarness itself. It checks the official `deepseek-ai/deepseek-harness` commit feed, downloads the precise source archive, reuses the bundled runtime where compatible, verifies dependencies against the lock file, builds, health-checks `127.0.0.1:3080`, and atomically switches the runtime. The page clearly labels the action as `更新 Harness 核心` so it cannot be confused with the desktop-shell update.

### Repair

`修复` checks the desktop payload manifest, Node runtime, Harness commit marker, lockfile integrity and local web-search module. It first repairs from the bundled offline payload; it asks before downloading anything that cannot be repaired locally. The task panel keeps the complete install/update log and supports copying it for diagnosis.

## Release flow

1. Merge reviewed changes to `main`.
2. Create an annotated tag such as `v4.1.0`.
3. GitHub Actions builds the release in a clean Windows environment, runs the interface regression test and native checks, and produces the full installer.
4. The workflow signs the installer, generates `latest.json`, creates a GitHub Release and uploads the installer, signature, metadata and checksums.
5. A fresh Windows sandbox installs the artifact, launches Harness, tests web search and executes the update-check path before the release is marked current.

## User-facing UI

- Default: light theme with the centered black-whale icon.
- Dark and whale-maid atelier are available without restart. Selecting the whale-maid theme switches the runtime window icon to the whale-maid icon; returning to light/dark restores the black whale.
- The title bar always exposes `更新` and `修复`.
- The settings page separates `桌面端版本`, `Harness 核心`, `更新状态`, `下载量` and `修复状态`.
- Installer, update and repair all use the same non-technical task panel: phase, percentage, speed/ETA and an expandable detailed log.

## Plugin workshop and safety

- The workshop can scaffold a plugin from a plain-language task, validate its manifest and install it in an isolated user-plugin directory.
- GitHub theme/plugin installs use an allowlisted file set, archive size limits, a required manifest and static inspection for executable scripts, native binaries and suspicious post-install hooks.
- The built-in security audit reports dependency advisories, risky permissions, checksums and plugin provenance before activation.
- Plugins cannot overwrite the DSHarness updater, the full Harness runtime or the app's icon assets.

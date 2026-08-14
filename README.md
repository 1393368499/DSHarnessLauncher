# DSHarness

DSHarness is a Windows desktop workbench for the complete DeepSeek Harness core. It provides a native desktop shell, light/dark/whale-maid themes, a plugin workshop, web-search capability and a local security-audit entry point.

## Current delivery model

- The desktop shell is built with Tauri and uses the centered black-whale icon by default.
- The complete Harness core is sourced only from the official `deepseek-ai/deepseek-harness` repository.
- Node.js and the full Harness runtime are verified during installation; no trimmed core is used.
- Desktop releases are published from this repository's GitHub Releases. Core updates continue to check the official Harness repository.

## Development

```powershell
npm ci
npm run build
npx tauri dev
```

For production releases, use the signed GitHub Releases workflow described in the release plan. Never commit signing keys, downloaded runtimes, build directories or local settings.

## Project layout

- `src/` — desktop workbench interface
- `src-tauri/` — native shell, installer and runtime orchestration
- `public/assets/` — bundled theme and icon assets
- `src-tauri/bootstrap/` — verified Harness, Node.js and theme installation routines

## Artwork attribution

See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for the whale-maid atelier theme's source, creator chain and CC BY-NC-SA 4.0 licence terms, as well as the black-whale icon attribution.

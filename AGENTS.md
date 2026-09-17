# Codex Guidelines

## About

A lightweight, high-performance cross-platform application framework built with Zig. It creates native desktop apps (macOS, Linux, Windows), mobile apps (iOS, Android), and menubar/system tray apps using web technologies. It includes a library of native UI components, advanced GPU rendering (Vulkan/Metal/Direct3D), WebSocket support, a JavaScript bridge, system integration (notifications, clipboard, file dialogs), and a TypeScript SDK (`craft-native`) for building apps without writing Zig directly. Reproducible binary-size and startup benchmarks live in [`benchmarks/`](./benchmarks).

## Linting

- Use **pickier** for linting — never use eslint directly
- Run `bunx --bun pickier .` to lint, `bunx --bun pickier . --fix` to auto-fix
- When fixing unused variable warnings, prefer `// eslint-disable-next-line` comments over prefixing with `_`

## Frontend

- Use **stx** for templating — never write vanilla JS (`var`, `document._`, `window._`) in stx templates
- Use **crosswind** as the default CSS framework which enables standard Tailwind-like utility classes
- stx `<script>` tags should only contain stx-compatible code (signals, composables, directives)

## Dependencies

- **buddy-bot** handles dependency updates — not renovatebot
- **better-dx** provides shared dev tooling as peer dependencies — do not install its peers (e.g., `typescript`, `pickier`, `bun-plugin-dtsx`) separately if `better-dx` is already in `package.json`
- If `better-dx` is in `package.json`, ensure `bunfig.toml` includes `linker = "hoisted"`

## Distribution

- Craft is distributed through the **pantry registry** (`pantry install craft`). The SDK and CLI both expect `craft` to be on PATH and do not probe `zig-out` paths or any monorepo-relative locations at runtime.
- The `release.yml` workflow publishes to pantry on every tag via `home-lang/pantry/packages/action@main` with `publish: 'zig'`.
- Tests / monorepo dev loop: set `CRAFT_BIN=/absolute/path/to/craft` to override the PATH lookup. The SDK's `AppConfig.craftPath` field accepts the same kind of override at app-config time.
- Adding new lookup paths or fallbacks to `binary-resolver.ts` defeats the pantry contract — don't.

## Commits

- Use conventional commit messages (e.g., `fix:`, `feat:`, `chore:`)

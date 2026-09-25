# Codex Guidelines

## About

A lightweight, high-performance cross-platform application framework built with Zig. It creates native desktop apps (macOS, Linux, Windows), mobile apps (iOS, Android), and menubar/system tray apps using web technologies. It includes a library of native UI components, advanced GPU rendering (Vulkan/Metal/Direct3D), WebSocket support, a JavaScript bridge, system integration (notifications, clipboard, file dialogs), and a TypeScript SDK (`craft-native`) for building apps without writing Zig directly. Reproducible binary-size and startup benchmarks live in [`benchmarks/`](./benchmarks).

## Environment

These are the things a fresh checkout cannot tell you, each of which has already cost a separately diagnosed build failure. None is a code defect.

**`zig build` needs the pinned toolchain.** The `zig` on your PATH is almost certainly the wrong snapshot, and the build refuses it by design. Point `CRAFT_ZIG` at the executable `pantry.lock` pins, or activate the pinned Pantry toolchain. `CRAFT_ALLOW_UNPINNED_ZIG=1` exists only for deliberately testing another snapshot.

**`zig build` also needs three sibling checkouts outside the repository.** `packages/zig/build.zig.zon` resolves them by relative path — `../../../../Libraries/zig-js` and likewise `zig-regex` and `zig-gc` — so they must sit four levels above `packages/zig`, beside the repository's own parent. CI provides them through `.github/actions/first-party-zig-deps`, which clones each at the SHA in `pins.env`.

Two traps follow from that. The pins are **not branch tips**, so `git fetch` and `git pull` will not reach them; fetch the commit directly (`git fetch --depth 1 origin <sha>`), which is what the action does and why it says so. And a checkout that merely *exists* is not enough: a local clone at a different revision fails to compile against the pinned Zig with errors that look like Zig bugs.

**A container that installs Zig still cannot build** until both of the above are satisfied. If you cannot satisfy them, say so and let CI's `zig-core` job be the signal rather than fighting it.

**`bun run test` is the Zig suite, not the SDK suite.** The SDK suite is `bun run test:sdk`. A bare `bun test` at the repository root is worse than either: `bunfig.toml` picks up vendored fixtures under `pantry/`, so it reports failures that have nothing to do with your change. Inside a package, plain `bun test` is correct.

**Not every Zig test runs on every runner.** Zig collects tests only from files its lazy analysis reaches, and `src/ios.zig` is skipped off Darwin. The whole of `bridge_error.zig` and every `bridge_mobile_*.zig` module is therefore invisible to the Linux leg of `zig-core`. For iOS bridge work, read the **macos-latest** leg; a green Linux leg means almost nothing.

**A new `scripts/*.test.ts` file does not run until `ci.yml` names it.** The lint job invokes those tests file by file, so a test added to `scripts/` and nowhere else is silently never executed. Add the invocation in the same change.

**`main` is not branch-protected.** There are no required status checks, so a red pull request *can* be merged. Never merge one.

## Verification

Before pushing, run what your machine can actually run:

```sh
bun run test:sdk        # the SDK suite
bun run typecheck
bun run verify:packages # needs the package dists built first
bunx --bun pickier .    # never eslint; 0 errors is the bar
```

`verify:packages` fails on a fresh checkout until the public packages are built, which is why CI runs it after the builds rather than before.

A pull request touching `packages/ios/**`, `packages/android/**` or the mobile Zig bridges also boots a real simulator or emulator on a long job. When that job is red for a reason unrelated to your change, say so on the pull request instead of thrashing on it.

`mobile-e2e.yml` installs with `--frozen-lockfile` while `ci.yml` does not, so a dependency edit without a regenerated `bun.lock` passes one workflow and fails the other.

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
- Do not run `bun audit fix` unreviewed. It is willing to *downgrade* a package to fall below an advisory window rather than upgrade past it, and it reports that as a fix.

## Distribution

- Craft is distributed through the **pantry registry** (`pantry install craft`). The SDK and CLI both expect `craft` to be on PATH and do not probe `zig-out` paths or any monorepo-relative locations at runtime.
- The `release.yml` workflow publishes to pantry on every tag via `home-lang/pantry/packages/action@main` with `publish: 'zig'`.
- Tests / monorepo dev loop: set `CRAFT_BIN=/absolute/path/to/craft` to override the PATH lookup. The SDK's `AppConfig.craftPath` field accepts the same kind of override at app-config time.
- Adding new lookup paths or fallbacks to `binary-resolver.ts` defeats the pantry contract — don't.
- Release archives are built natively, one runner per platform. They are not cross-compiled, so a full release cannot be rehearsed on one machine.

## Commits

- Use conventional commit messages (e.g., `fix:`, `feat:`, `chore:`)
- Keep commits small and focused: 3–5 files each
- Do not add agent attribution trailers to commits or pull requests

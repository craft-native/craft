# Changelog

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.76...v0.0.77)

## 🚀 Features

- **bridge**: let the page ask what native actually serves (#60) ([8f14e43](https://github.com/craft-native/craft/commit/8f14e43)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#60](https://github.com/craft-native/craft/issues/60), [#60](https://github.com/craft-native/craft/issues/60))
- **cli**: --headless, and make DevTools reachable at all (#61) ([f93ad1e](https://github.com/craft-native/craft/commit/f93ad1e)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#61](https://github.com/craft-native/craft/issues/61), [#61](https://github.com/craft-native/craft/issues/61))
- **packaging**: register the URL schemes an app declares (#57) ([bb2d6fd](https://github.com/craft-native/craft/commit/bb2d6fd)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#57](https://github.com/craft-native/craft/issues/57), [#57](https://github.com/craft-native/craft/issues/57))
- **prefs**: a Settings… item and a preference store that keeps its types (#58) ([a391437](https://github.com/craft-native/craft/commit/a391437)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#58](https://github.com/craft-native/craft/issues/58), [#58](https://github.com/craft-native/craft/issues/58))
- **window**: --frame-autosave, so windows come back where they were (#56) ([fbbe035](https://github.com/craft-native/craft/commit/fbbe035)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#56](https://github.com/craft-native/craft/issues/56), [#56](https://github.com/craft-native/craft/issues/56))
- **cli**: --app-name, so an app can be itself without packaging (#55) ([9abf96c](https://github.com/craft-native/craft/commit/9abf96c)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#55](https://github.com/craft-native/craft/issues/55), [#55](https://github.com/craft-native/craft/issues/55))

## 🐛 Bug Fixes

- **shortcuts**: make global hotkeys actually fire (#54) ([1263c79](https://github.com/craft-native/craft/commit/1263c79)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#54](https://github.com/craft-native/craft/issues/54), [#54](https://github.com/craft-native/craft/issues/54))
- **packaging**: stop macOS packages relocating themselves elsewhere (#46) ([ed17bff](https://github.com/craft-native/craft/commit/ed17bff)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#46](https://github.com/craft-native/craft/issues/46), [#46](https://github.com/craft-native/craft/issues/46))

## 🤖 Continuous Integration

- **lifecycle**: run the packaging test as a path, not as a filter (#59) ([ac1f7bb](https://github.com/craft-native/craft/commit/ac1f7bb)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#59](https://github.com/craft-native/craft/issues/59), [#59](https://github.com/craft-native/craft/issues/59))

## 🧹 Chores

- release v0.0.77 ([142c04d](https://github.com/craft-native/craft/commit/142c04d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **release**: set what can be set, and generate the signing request ([724fa28](https://github.com/craft-native/craft/commit/724fa28)) _(by Chris <chrisbreuer93@gmail.com>)_
- **release**: generate the production keypair, and set the one value that is not a credential ([b06a467](https://github.com/craft-native/craft/commit/b06a467)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _Glenn Michael Torregosa <gtorregosa@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.75...v0.0.76)

## ♻️ Code Refactoring

- **release**: read the credentials with `buddy env`, and drop the wrapper ([2a93ede](https://github.com/craft-native/craft/commit/2a93ede)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📚 Documentation

- **env**: say why the credentials script is not `buddy env` yet ([2f5fb96](https://github.com/craft-native/craft/commit/2f5fb96)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.76 ([1684add](https://github.com/craft-native/craft/commit/1684add)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.74...v0.0.75)

## ♻️ Code Refactoring

- **release**: encrypt the credentials with Stacks env, not dotenvx ([909fac7](https://github.com/craft-native/craft/commit/909fac7)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.75 ([7a4da47](https://github.com/craft-native/craft/commit/7a4da47)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.73...v0.0.74)

## 🐛 Bug Fixes

- **release**: restore the env key the credential move took with it ([30912b7](https://github.com/craft-native/craft/commit/30912b7)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.74 ([1b2514f](https://github.com/craft-native/craft/commit/1b2514f)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.72...v0.0.73)

## 🚀 Features

- **packages**: publish the android, react, vue and svelte adapters ([cd6aa37](https://github.com/craft-native/craft/commit/cd6aa37)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **release**: keep the signing credentials encrypted in the repository ([b20e759](https://github.com/craft-native/craft/commit/b20e759)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.73 ([583404a](https://github.com/craft-native/craft/commit/583404a)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.71...v0.0.72)

## 🐛 Bug Fixes

- **packages**: point every published package at the repository that builds it ([26ed5c4](https://github.com/craft-native/craft/commit/26ed5c4)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.72 ([4645615](https://github.com/craft-native/craft/commit/4645615)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.70...v0.0.71)

## 🐛 Bug Fixes

- **release**: stop a missing Apple certificate from blocking every npm publish ([f6ce289](https://github.com/craft-native/craft/commit/f6ce289)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.71 ([0b54496](https://github.com/craft-native/craft/commit/0b54496)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: publish the package, and spell its bin path the way npm wants ([11f4131](https://github.com/craft-native/craft/commit/11f4131)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.69...v0.0.70)

## 🐛 Bug Fixes

- **ios**: find Simulator.app under the selected Xcode, not through its name ([d7b0038](https://github.com/craft-native/craft/commit/d7b0038)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: make `run --simulator` actually install and launch the app ([a819e06](https://github.com/craft-native/craft/commit/a819e06)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.70 ([faab917](https://github.com/craft-native/craft/commit/faab917)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.68...v0.0.69)

## 🐛 Bug Fixes

- **macos**: stop pretending to move the traffic lights ([603f1a1](https://github.com/craft-native/craft/commit/603f1a1)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: finish the TypeScript 7 move across the workspace (#44) ([794ea7b](https://github.com/craft-native/craft/commit/794ea7b)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#44](https://github.com/craft-native/craft/issues/44), [#44](https://github.com/craft-native/craft/issues/44))

## 🧹 Chores

- release v0.0.69 ([df35b6b](https://github.com/craft-native/craft/commit/df35b6b)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _Glenn Michael Torregosa <gtorregosa@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.67...v0.0.68)

## 🚀 Features

- **macos**: give the default menu bar an Edit, App and Window menu (#35) ([dc71b29](https://github.com/craft-native/craft/commit/dc71b29)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#35](https://github.com/craft-native/craft/issues/35), [#35](https://github.com/craft-native/craft/issues/35))

## 🐛 Bug Fixes

- **types**: name the bun types the compiler stopped finding on its own ([da3d131](https://github.com/craft-native/craft/commit/da3d131)) _(by Chris <chrisbreuer93@gmail.com>)_
- **docs**: use the config keys bunpress actually has ([9b9f81d](https://github.com/craft-native/craft/commit/9b9f81d)) _(by Chris <chrisbreuer93@gmail.com>)_
- **release**: stop shipping the wrong binaries, and delete the dead notifier (#43) ([14c3d54](https://github.com/craft-native/craft/commit/14c3d54)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#43](https://github.com/craft-native/craft/issues/43), [#43](https://github.com/craft-native/craft/issues/43))
- **sdk**: ship declarations that resolve under node16/nodenext (#42) ([055d289](https://github.com/craft-native/craft/commit/055d289)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#42](https://github.com/craft-native/craft/issues/42), [#42](https://github.com/craft-native/craft/issues/42))
- **ci**: let the benchmark job comment on pull requests (#41) ([98b5f6d](https://github.com/craft-native/craft/commit/98b5f6d)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#41](https://github.com/craft-native/craft/issues/41), [#41](https://github.com/craft-native/craft/issues/41))
- **build**: keep test declarations out of the published SDK (#40) ([14bce5b](https://github.com/craft-native/craft/commit/14bce5b)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#40](https://github.com/craft-native/craft/issues/40), [#40](https://github.com/craft-native/craft/issues/40))
- **ci**: unblock the three failing native lifecycle legs (#37) ([d8a19ed](https://github.com/craft-native/craft/commit/d8a19ed)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#37](https://github.com/craft-native/craft/issues/37), [#37](https://github.com/craft-native/craft/issues/37))
- **db**: bind SQLITE_TRANSIENT directly instead of through asm stubs (#38) ([b64c9d2](https://github.com/craft-native/craft/commit/b64c9d2)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#38](https://github.com/craft-native/craft/issues/38), [#38](https://github.com/craft-native/craft/issues/38))
- **menu**: give bridge-built items a live target, and roles for standard behaviors (#29) ([1884215](https://github.com/craft-native/craft/commit/1884215)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#29](https://github.com/craft-native/craft/issues/29), [#29](https://github.com/craft-native/craft/issues/29))

## ♻️ Code Refactoring

- **menu**: retire the inert menu implementations, test the real path (#34) ([fe99495](https://github.com/craft-native/craft/commit/fe99495)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#34](https://github.com/craft-native/craft/issues/34), [#34](https://github.com/craft-native/craft/issues/34))

## 📚 Documentation

- **menu**: delete the dead NativeMenus class, document the real menu API (#36) ([b6fea1c](https://github.com/craft-native/craft/commit/b6fea1c)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#36](https://github.com/craft-native/craft/issues/36), [#36](https://github.com/craft-native/craft/issues/36))

## 🤖 Continuous Integration

- pin the first-party Zig dependencies to commits (#39) ([d695897](https://github.com/craft-native/craft/commit/d695897)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#39](https://github.com/craft-native/craft/issues/39), [#39](https://github.com/craft-native/craft/issues/39))

## 🧹 Chores

- release v0.0.68 ([f1badea](https://github.com/craft-native/craft/commit/f1badea)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: bunpress 0.2.13 ([10afcc4](https://github.com/craft-native/craft/commit/10afcc4)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: move the framework wrappers to TypeScript 7 ([2c3b616](https://github.com/craft-native/craft/commit/2c3b616)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _Glenn Michael Torregosa <gtorregosa@gmail.com>_

[Compare changes](https://github.com/craft-native/craft/compare/v0.0.66...v0.0.67)

## 🐛 Bug Fixes

- **cli**: tell the user when `craft` on PATH is the CLI, not the binary (#28) ([85ff14b](https://github.com/craft-native/craft/commit/85ff14b)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#28](https://github.com/craft-native/craft/issues/28), [#28](https://github.com/craft-native/craft/issues/28))
- **menu**: align the injected bridge with the contract native parses (#27) ([6fc212d](https://github.com/craft-native/craft/commit/6fc212d)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#27](https://github.com/craft-native/craft/issues/27), [#27](https://github.com/craft-native/craft/issues/27))
- **ci**: link libc in the test artifacts that need it, retire mobile E2E (#23) ([e1bc449](https://github.com/craft-native/craft/commit/e1bc449)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#23](https://github.com/craft-native/craft/issues/23), [#23](https://github.com/craft-native/craft/issues/23))
- **ci**: get the CI workflow green again (#22) ([3c7bcec](https://github.com/craft-native/craft/commit/3c7bcec)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#22](https://github.com/craft-native/craft/issues/22), [#22](https://github.com/craft-native/craft/issues/22))
- **build**: keep unwind tables on Windows so the release can cross-compile (#21) ([5872e09](https://github.com/craft-native/craft/commit/5872e09)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#21](https://github.com/craft-native/craft/issues/21), [#21](https://github.com/craft-native/craft/issues/21))
- **macos**: trust local development certificates behind an opt-in (#20) ([3e7c589](https://github.com/craft-native/craft/commit/3e7c589)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#20](https://github.com/craft-native/craft/issues/20), [#20](https://github.com/craft-native/craft/issues/20))
- **macos**: anchor titlebar controls to the titlebar band (#19) ([aec7337](https://github.com/craft-native/craft/commit/aec7337)) _(by Glenn Michael Torregosa <gtorregosa@gmail.com>)_ ([#19](https://github.com/craft-native/craft/issues/19), [#19](https://github.com/craft-native/craft/issues/19))
- **build**: move the zig pin past the SEH miscompile ([5930464](https://github.com/craft-native/craft/commit/5930464)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: drop unused vitest to clear critical Go stdlib CVEs from the SBOM gate ([b53392d](https://github.com/craft-native/craft/commit/b53392d)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: stop Buddy Bot's every-minute schedule ([7edbaad](https://github.com/craft-native/craft/commit/7edbaad)) _(by Chris <chrisbreuer93@gmail.com>)_

## ⚡ Performance Improvements

- **build**: stop shipping sourcemaps and declaration maps ([332b96a](https://github.com/craft-native/craft/commit/332b96a)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🤖 Continuous Integration

- **size**: rebaseline the binary gate for the bundled zig-js runtime ([e3c0a65](https://github.com/craft-native/craft/commit/e3c0a65)) _(by Chris Breuer <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.67 ([922c87f](https://github.com/craft-native/craft/commit/922c87f)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: follow the org moves in workflow and doc references ([0e30d01](https://github.com/craft-native/craft/commit/0e30d01)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _Chris Breuer <chrisbreuer93@gmail.com>_
- _Glenn Michael Torregosa <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.65...v0.0.66)

## 🚀 Features

- **ios**: configure supported device families ([26d927f](https://github.com/home-lang/craft/commit/26d927f)) _(by Chris <chrisbreuer93@gmail.com>)_
- **android**: integrate Health Connect workouts ([5298420](https://github.com/home-lang/craft/commit/5298420)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: generate a watchOS companion ([005e075](https://github.com/home-lang/craft/commit/005e075)) _(by Chris <chrisbreuer93@gmail.com>)_
- **health**: save native iOS workouts ([209b2fb](https://github.com/home-lang/craft/commit/209b2fb)) _(by Chris <chrisbreuer93@gmail.com>)_
- **sdk**: expose native activity integrations ([0dcbf38](https://github.com/home-lang/craft/commit/0dcbf38)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: generate native Live Activities ([638e123](https://github.com/home-lang/craft/commit/638e123)) _(by Chris <chrisbreuer93@gmail.com>)_
- **android**: persist background location recordings ([bb9a0b0](https://github.com/home-lang/craft/commit/bb9a0b0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **mobile**: add bundled offline recovery ([989ee6b](https://github.com/home-lang/craft/commit/989ee6b)) _(by Chris <chrisbreuer93@gmail.com>)_
- **android**: add production mobile builder contract ([c6d76ea](https://github.com/home-lang/craft/commit/c6d76ea)) _(by Chris <chrisbreuer93@gmail.com>)_
- **sdk**: expose mobile lifecycle services ([19a61a8](https://github.com/home-lang/craft/commit/19a61a8)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: harden native mobile runtime ([68c6d3a](https://github.com/home-lang/craft/commit/68c6d3a)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **ios**: generate modern watch app metadata ([c63fe15](https://github.com/home-lang/craft/commit/c63fe15)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: validate embedded watch bundle ([aa3c4ec](https://github.com/home-lang/craft/commit/aa3c4ec)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: embed generated web resources ([47423b6](https://github.com/home-lang/craft/commit/47423b6)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: resolve bundled entry point reliably ([3d55ba7](https://github.com/home-lang/craft/commit/3d55ba7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: locate bundled web resources ([3348023](https://github.com/home-lang/craft/commit/3348023)) _(by Chris <chrisbreuer93@gmail.com>)_
- **android**: retain generated stx assets ([722175c](https://github.com/home-lang/craft/commit/722175c)) _(by Chris <chrisbreuer93@gmail.com>)_
- **mobile**: normalize native deep link payloads ([182e42a](https://github.com/home-lang/craft/commit/182e42a)) _(by Chris <chrisbreuer93@gmail.com>)_
- **mobile**: serve bundled routes from secure origins ([5e1c20c](https://github.com/home-lang/craft/commit/5e1c20c)) _(by Chris <chrisbreuer93@gmail.com>)_
- **watchos**: use platform-valid session delegates ([5d03387](https://github.com/home-lang/craft/commit/5d03387)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: generate modern single-target watch apps ([10b6166](https://github.com/home-lang/craft/commit/10b6166)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: generate a real watch extension target ([60cef64](https://github.com/home-lang/craft/commit/60cef64)) _(by Chris <chrisbreuer93@gmail.com>)_
- **android**: preserve release bridge contracts ([546d9f2](https://github.com/home-lang/craft/commit/546d9f2)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: deliver queued watch commands ([832255d](https://github.com/home-lang/craft/commit/832255d)) _(by Chris <chrisbreuer93@gmail.com>)_
- **android**: avoid generated JVM getter clashes ([a83eea7](https://github.com/home-lang/craft/commit/a83eea7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **android**: compile generated Kotlin bridge ([2c93157](https://github.com/home-lang/craft/commit/2c93157)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: compile modern ActivityKit APIs safely ([dbc91b7](https://github.com/home-lang/craft/commit/dbc91b7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: resolve generated Swift conformance errors ([c09963f](https://github.com/home-lang/craft/commit/c09963f)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: complete Live Activity metadata ([b5b92b8](https://github.com/home-lang/craft/commit/b5b92b8)) _(by Chris <chrisbreuer93@gmail.com>)_
- **android**: ship real push and bridge dependencies ([33523a1](https://github.com/home-lang/craft/commit/33523a1)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📦 Build System

- **android**: support current Health Connect SDK ([f914621](https://github.com/home-lang/craft/commit/f914621)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.66 ([0cbecaa](https://github.com/home-lang/craft/commit/0cbecaa)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.64...v0.0.65)

## 🚀 Features

- **sdk**: add browser-safe mobile entrypoint ([e525749](https://github.com/home-lang/craft/commit/e525749)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: expose production project builder ([31d94b2](https://github.com/home-lang/craft/commit/31d94b2)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **ios**: default native capabilities off ([02c97bf](https://github.com/home-lang/craft/commit/02c97bf)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ios**: load bundled app from dist ([facae34](https://github.com/home-lang/craft/commit/facae34)) _(by Chris <chrisbreuer93@gmail.com>)_
- **cli**: report native version reliably ([0985620](https://github.com/home-lang/craft/commit/0985620)) _(by Chris Breuer <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.65 ([99ca57f](https://github.com/home-lang/craft/commit/99ca57f)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _Chris Breuer <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.63...v0.0.64)

## 🚀 Features

- **js**: craft's own JavaScript runs on zig-js, not on the platform engine ([8556d46](https://github.com/home-lang/craft/commit/8556d46)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **window**: parse colours properly instead of silently painting white ([4511f1d](https://github.com/home-lang/craft/commit/4511f1d)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.64 ([9d76958](https://github.com/home-lang/craft/commit/9d76958)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.62...v0.0.63)

## 🧪 Tests

- **js**: run craft's injected JavaScript headlessly against zig-js ([a2c484b](https://github.com/home-lang/craft/commit/a2c484b)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.63 ([3971b7c](https://github.com/home-lang/craft/commit/3971b7c)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.61...v0.0.62)

## 🐛 Bug Fixes

- **zig**: route payloads to the window and app bridges, and unblock the test suite ([d28bdeb](https://github.com/home-lang/craft/commit/d28bdeb)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.62 ([d865750](https://github.com/home-lang/craft/commit/d865750)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.60...v0.0.61)

## 🐛 Bug Fixes

- **macos**: inject the native UI surface for web-sidebar windows too ([bc80637](https://github.com/home-lang/craft/commit/bc80637)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.61 ([5512219](https://github.com/home-lang/craft/commit/5512219)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.59...v0.0.60)

## 🚀 Features

- **spaces**: native switcher for Arc-style sidebar spaces ([2813a86](https://github.com/home-lang/craft/commit/2813a86)) _(by Chris <chrisbreuer93@gmail.com>)_

## ♻️ Code Refactoring

- **sidebar**: one SidebarItem instead of two that disagreed ([0c57dcd](https://github.com/home-lang/craft/commit/0c57dcd)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.60 ([5561d69](https://github.com/home-lang/craft/commit/5561d69)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.58...v0.0.59)

## 💥 Breaking Changes

- feat(menubar)!: drop the always-hidden section ([1ff0ced](https://github.com/home-lang/craft/commit/1ff0ced)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🚀 Features

- **gestures**: forward real trackpad swipe phases to the webview ([51a5a74](https://github.com/home-lang/craft/commit/51a5a74)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **menubar**: take the pressed look off the marker after a click ([e528a3c](https://github.com/home-lang/craft/commit/e528a3c)) _(by Chris <chrisbreuer93@gmail.com>)_
- **menubar**: draw the marker as a divider, not a chevron ([26627f8](https://github.com/home-lang/craft/commit/26627f8)) _(by Chris <chrisbreuer93@gmail.com>)_
- **menubar**: one marker, and the tray icon as the way back ([21ccdaf](https://github.com/home-lang/craft/commit/21ccdaf)) _(by Chris <chrisbreuer93@gmail.com>)_
- **menubar**: pass the auto-collapse delay as a number ([c326d78](https://github.com/home-lang/craft/commit/c326d78)) _(by Chris <chrisbreuer93@gmail.com>)_
- **menubar**: never let a collapse take the app's own icon with it ([4c0d7b5](https://github.com/home-lang/craft/commit/4c0d7b5)) _(by Chris <chrisbreuer93@gmail.com>)_
- **build**: link MIDI in tray tests ([90e9c83](https://github.com/home-lang/craft/commit/90e9c83)) _(by Chris <chrisbreuer93@gmail.com>)_
- **sidebar**: serialize native navigation URLs ([a04ebe9](https://github.com/home-lang/craft/commit/a04ebe9)) _(by Chris <chrisbreuer93@gmail.com>)_
- **menubar**: hide items across the whole bar, not one item's worth ([16b63eb](https://github.com/home-lang/craft/commit/16b63eb)) _(by Chris <chrisbreuer93@gmail.com>)_

## ♻️ Code Refactoring

- **macos**: one JS injection path for every window ([dd27334](https://github.com/home-lang/craft/commit/dd27334)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📦 Build System

- **deps**: pin bun and zig to exact versions ([c2b3542](https://github.com/home-lang/craft/commit/c2b3542)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.59 ([3518b84](https://github.com/home-lang/craft/commit/3518b84)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.57...v0.0.58)

## 🐛 Bug Fixes

- **cli**: honour --benchmark in the system-tray path, and free parsed options ([9e5fe86](https://github.com/home-lang/craft/commit/9e5fe86)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.58 ([3523c8b](https://github.com/home-lang/craft/commit/3523c8b)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.56...v0.0.57)

## 🚀 Features

- **focus**: add a sandbox-legal strategy for running Focus shortcuts ([9dcdbfe](https://github.com/home-lang/craft/commit/9dcdbfe)) _(by Chris <chrisbreuer93@gmail.com>)_
- **cli**: read Contents/Resources/craft.json so craft can be the app executable ([80eb4d8](https://github.com/home-lang/craft/commit/80eb4d8)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.57 ([bd631d6](https://github.com/home-lang/craft/commit/bd631d6)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.55...v0.0.56)

## 🚀 Features

- **cli**: add --html-file for loading a document from disk ([ae62e7d](https://github.com/home-lang/craft/commit/ae62e7d)) _(by Chris <chrisbreuer93@gmail.com>)_
- **focus**: add Focus/DND and screen-sharing detection bridges ([9d74e1b](https://github.com/home-lang/craft/commit/9d74e1b)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **menubar**: make collapsing actually hide items ([5ff5190](https://github.com/home-lang/craft/commit/5ff5190)) _(by Chris <chrisbreuer93@gmail.com>)_
- **bridge**: restore parameter names and payload keys in the JS facade ([b0d1c62](https://github.com/home-lang/craft/commit/b0d1c62)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📚 Documentation

- **focus**: type and document the focus and screenSharing bridges ([4a09fee](https://github.com/home-lang/craft/commit/4a09fee)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.56 ([439e51f](https://github.com/home-lang/craft/commit/439e51f)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.54...v0.0.55)

## 🚀 Features

- **tray**: accept a template image file as the icon ([f49b11c](https://github.com/home-lang/craft/commit/f49b11c)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **sidebar**: expose native document marker ([fbc5118](https://github.com/home-lang/craft/commit/fbc5118)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.55 ([36c43cb](https://github.com/home-lang/craft/commit/36c43cb)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.53...v0.0.54)

## 🐛 Bug Fixes

- **tray**: enable the tray message channel for tray windows ([f72acca](https://github.com/home-lang/craft/commit/f72acca)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.54 ([1670bfb](https://github.com/home-lang/craft/commit/1670bfb)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.52...v0.0.53)

## 🚀 Features

- **tray**: tell left and right click apart ([cff82b9](https://github.com/home-lang/craft/commit/cff82b9)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.53 ([ed675f5](https://github.com/home-lang/craft/commit/ed675f5)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.51...v0.0.52)

## 🐛 Bug Fixes

- **tray**: render the icon setIcon was handed, at menu bar size ([4cef134](https://github.com/home-lang/craft/commit/4cef134)) _(by Chris <chrisbreuer93@gmail.com>)_
- **build**: compile against the pinned Zig again ([7ccaf53](https://github.com/home-lang/craft/commit/7ccaf53)) _(by Chris <chrisbreuer93@gmail.com>)_
- **tray**: draw the icon setIcon assigns ([e74f1fe](https://github.com/home-lang/craft/commit/e74f1fe)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.52 ([a8beb97](https://github.com/home-lang/craft/commit/a8beb97)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.50...v0.0.51)

## 🚀 Features

- export the auto-updater surface top-level ([b594bef](https://github.com/home-lang/craft/commit/b594bef)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.51 ([ddcbd8c](https://github.com/home-lang/craft/commit/ddcbd8c)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.49...v0.0.50)

## 🚀 Features

- export the craft binary resolution contract ([6a74170](https://github.com/home-lang/craft/commit/6a74170)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.50 ([b84b2b6](https://github.com/home-lang/craft/commit/b84b2b6)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.48...v0.0.49)

## 🚀 Features

- **packaging**: bundle helper executables into the macOS .app ([4ecc35b](https://github.com/home-lang/craft/commit/4ecc35b)) _(by Chris <chrisbreuer93@gmail.com>)_
- **packaging**: build signed Mac App Store submission packages ([2d17221](https://github.com/home-lang/craft/commit/2d17221)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📚 Documentation

- link the community as stacksjs.com/discord ([fd1454f](https://github.com/home-lang/craft/commit/fd1454f)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.49 ([22ca683](https://github.com/home-lang/craft/commit/22ca683)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.47...v0.0.48)

## 🐛 Bug Fixes

- **packaging**: retry transient DMG contention ([f14a415](https://github.com/home-lang/craft/commit/f14a415)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.48 ([0b78ba5](https://github.com/home-lang/craft/commit/0b78ba5)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.46...v0.0.47)

## 🐛 Bug Fixes

- **packaging**: encode native MSI architecture ([4c0b1eb](https://github.com/home-lang/craft/commit/4c0b1eb)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.47 ([3f0dda7](https://github.com/home-lang/craft/commit/3f0dda7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **release**: adopt lock-consistent Bumpx ([4b190c5](https://github.com/home-lang/craft/commit/4b190c5)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.45...v0.0.46)

## 🐛 Bug Fixes

- **release**: let bumpx own changelog state ([68a4c4e](https://github.com/home-lang/craft/commit/68a4c4e)) _(by Chris <chrisbreuer93@gmail.com>)_
- **packaging**: harden native installer artifacts ([5c72c4a](https://github.com/home-lang/craft/commit/5c72c4a)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.46 ([076118c](https://github.com/home-lang/craft/commit/076118c)) _(by Chris <chrisbreuer93@gmail.com>)_
- **release**: pin atomic bumpx publisher ([6ac987f](https://github.com/home-lang/craft/commit/6ac987f)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.44...v0.0.45)

## 🐛 Bug Fixes

- **packaging**: perform explicit macOS rollback ([ae2f053](https://github.com/home-lang/craft/commit/ae2f053)) _(by Chris <chrisbreuer93@gmail.com>)_
- **packaging**: retain macOS image diagnostics ([504227e](https://github.com/home-lang/craft/commit/504227e)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.45 ([5c6fd8c](https://github.com/home-lang/craft/commit/5c6fd8c)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.44...HEAD)

## 🐛 Bug Fixes

- **packaging**: perform explicit macOS rollback ([ae2f053](https://github.com/home-lang/craft/commit/ae2f053)) _(by Chris <chrisbreuer93@gmail.com>)_
- **packaging**: retain macOS image diagnostics ([504227e](https://github.com/home-lang/craft/commit/504227e)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.43...v0.0.44)

## 🐛 Bug Fixes

- **evidence**: distinguish source and orchestrator revisions ([9062c8e](https://github.com/home-lang/craft/commit/9062c8e)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.44 ([6058f37](https://github.com/home-lang/craft/commit/6058f37)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.43...HEAD)

## 🐛 Bug Fixes

- **evidence**: distinguish source and orchestrator revisions ([9062c8e](https://github.com/home-lang/craft/commit/9062c8e)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.42...v0.0.43)

## 🧪 Tests

- **packaging**: cover macOS Intel lifecycle ([490a4e3](https://github.com/home-lang/craft/commit/490a4e3)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.43 ([b4469a5](https://github.com/home-lang/craft/commit/b4469a5)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.42...HEAD)

## 🧪 Tests

- **packaging**: cover macOS Intel lifecycle ([490a4e3](https://github.com/home-lang/craft/commit/490a4e3)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.41...v0.0.42)

## 🐛 Bug Fixes

- **packaging**: implement Windows MSI generation ([3116fc9](https://github.com/home-lang/craft/commit/3116fc9)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧪 Tests

- **packaging**: exercise native lifecycle matrix ([59a3fba](https://github.com/home-lang/craft/commit/59a3fba)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.42 ([27f7b06](https://github.com/home-lang/craft/commit/27f7b06)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.41...HEAD)

## 🐛 Bug Fixes

- **packaging**: implement Windows MSI generation ([3116fc9](https://github.com/home-lang/craft/commit/3116fc9)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧪 Tests

- **packaging**: exercise native lifecycle matrix ([59a3fba](https://github.com/home-lang/craft/commit/59a3fba)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.40...v0.0.41)

## 🚀 Features

- **package**: sign and notarize release artifacts ([0e2b094](https://github.com/home-lang/craft/commit/0e2b094)) _(by Chris <chrisbreuer93@gmail.com>)_
- **window**: evaluate scripts in shown windows ([3c146c1](https://github.com/home-lang/craft/commit/3c146c1)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ipc**: open named shared memory ([2a75ec5](https://github.com/home-lang/craft/commit/2a75ec5)) _(by Chris <chrisbreuer93@gmail.com>)_
- **http**: implement clients and websockets ([d4bdf9d](https://github.com/home-lang/craft/commit/d4bdf9d)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **zig**: validate external json shapes ([cd8cbfd](https://github.com/home-lang/craft/commit/cd8cbfd)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: gate releases on supported verified surfaces ([1e50f98](https://github.com/home-lang/craft/commit/1e50f98)) _(by Chris <chrisbreuer93@gmail.com>)_
- **runtime**: harden updates assets and framework bridge ([df69fc7](https://github.com/home-lang/craft/commit/df69fc7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **zig**: correct native ownership and callback lifetimes ([fc11ef8](https://github.com/home-lang/craft/commit/fc11ef8)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ts**: secure devtools and ship the sdk cli ([8e85336](https://github.com/home-lang/craft/commit/8e85336)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.41 ([b77acd1](https://github.com/home-lang/craft/commit/b77acd1)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.40...HEAD)

## 🚀 Features

- **package**: sign and notarize release artifacts ([0e2b094](https://github.com/home-lang/craft/commit/0e2b094)) _(by Chris <chrisbreuer93@gmail.com>)_
- **window**: evaluate scripts in shown windows ([3c146c1](https://github.com/home-lang/craft/commit/3c146c1)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ipc**: open named shared memory ([2a75ec5](https://github.com/home-lang/craft/commit/2a75ec5)) _(by Chris <chrisbreuer93@gmail.com>)_
- **http**: implement clients and websockets ([d4bdf9d](https://github.com/home-lang/craft/commit/d4bdf9d)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **zig**: validate external json shapes ([cd8cbfd](https://github.com/home-lang/craft/commit/cd8cbfd)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: gate releases on supported verified surfaces ([1e50f98](https://github.com/home-lang/craft/commit/1e50f98)) _(by Chris <chrisbreuer93@gmail.com>)_
- **runtime**: harden updates assets and framework bridge ([df69fc7](https://github.com/home-lang/craft/commit/df69fc7)) _(by Chris <chrisbreuer93@gmail.com>)_
- **zig**: correct native ownership and callback lifetimes ([fc11ef8](https://github.com/home-lang/craft/commit/fc11ef8)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ts**: secure devtools and ship the sdk cli ([8e85336](https://github.com/home-lang/craft/commit/8e85336)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.39...v0.0.40)

## 🐛 Bug Fixes

- **zig**: build with zig 0.17.0-dev and activate windowed apps ([894897c](https://github.com/home-lang/craft/commit/894897c)) _(by Chris <chrisbreuer93@gmail.com>)_

## ♻️ Code Refactoring

- **ts**: align tahoe web sidebar styles with the real macOS Tahoe spec ([e1383f5](https://github.com/home-lang/craft/commit/e1383f5)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📚 Documentation

- **ts**: point web sidebar users at the stx macos Sidebar; fix example metrics ([2e34bdc](https://github.com/home-lang/craft/commit/2e34bdc)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.40 ([b1b99d4](https://github.com/home-lang/craft/commit/b1b99d4)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: declare bun ^1.3.14 in deps.yaml ([0dabd54](https://github.com/home-lang/craft/commit/0dabd54)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.39...HEAD)

## 🐛 Bug Fixes

- **zig**: build with zig 0.17.0-dev and activate windowed apps ([894897c](https://github.com/home-lang/craft/commit/894897c)) _(by Chris <chrisbreuer93@gmail.com>)_

## ♻️ Code Refactoring

- **ts**: align tahoe web sidebar styles with the real macOS Tahoe spec ([e1383f5](https://github.com/home-lang/craft/commit/e1383f5)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📚 Documentation

- **ts**: point web sidebar users at the stx macos Sidebar; fix example metrics ([2e34bdc](https://github.com/home-lang/craft/commit/2e34bdc)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- **deps**: declare bun ^1.3.14 in deps.yaml ([0dabd54](https://github.com/home-lang/craft/commit/0dabd54)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.38...v0.0.39)

## 🧹 Chores

- release v0.0.39 ([96cf7d1](https://github.com/home-lang/craft/commit/96cf7d1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([40bfe4a](https://github.com/home-lang/craft/commit/40bfe4a)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.38...HEAD)

## 🧹 Chores

- wip ([40bfe4a](https://github.com/home-lang/craft/commit/40bfe4a)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.37...v0.0.38)

## 🚀 Features

- **macos**: tune web sidebar material opacity ([5949cc3](https://github.com/home-lang/craft/commit/5949cc3)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🐛 Bug Fixes

- **macos**: flip web sidebar toggle icon ([e8a9fd3](https://github.com/home-lang/craft/commit/e8a9fd3)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: tighten web sidebar chrome inset ([9e4d381](https://github.com/home-lang/craft/commit/9e4d381)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: align web sidebar chrome row ([308ef64](https://github.com/home-lang/craft/commit/308ef64)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: stabilize web sidebar material ([fa827b4](https://github.com/home-lang/craft/commit/fa827b4)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: render web sidebar chrome natively ([0914dac](https://github.com/home-lang/craft/commit/0914dac)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: align web sidebar chrome dragging ([75d85e3](https://github.com/home-lang/craft/commit/75d85e3)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: support dragging web chrome ([d82472a](https://github.com/home-lang/craft/commit/d82472a)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: guard transparent webview scroll access ([9442daa](https://github.com/home-lang/craft/commit/9442daa)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: support web sidebar material ([052f2af](https://github.com/home-lang/craft/commit/052f2af)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: render sidebar with native vibrancy ([76a7844](https://github.com/home-lang/craft/commit/76a7844)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: expose native sidebar chrome markers ([3d19b8f](https://github.com/home-lang/craft/commit/3d19b8f)) _(by Chris <chrisbreuer93@gmail.com>)_
- **macos**: make native surfaces translucent ([d3a8d4d](https://github.com/home-lang/craft/commit/d3a8d4d)) _(by Chris <chrisbreuer93@gmail.com>)_

## ♻️ Code Refactoring

- **dev**: drop ws dep, use Bun-native WebSocket servers ([d6f775e](https://github.com/home-lang/craft/commit/d6f775e)) _(by Chris <chrisbreuer93@gmail.com>)_
- **package**: drop archiver dep, zip with a dependency-free writer ([65fb521](https://github.com/home-lang/craft/commit/65fb521)) _(by Chris <chrisbreuer93@gmail.com>)_

## 📚 Documentation

- update JS-engine status through tier-3 (slots + shapes + ICs) ([1c4a853](https://github.com/home-lang/craft/commit/1c4a853)) _(by Chris <chrisbreuer93@gmail.com>)_
- note tier-1 bytecode VM landed in the JS-engine roadmap ([31a7ad3](https://github.com/home-lang/craft/commit/31a7ad3)) _(by Chris <chrisbreuer93@gmail.com>)_
- add homegrown web engine (Loom) + zig-js build plan ([95998d8](https://github.com/home-lang/craft/commit/95998d8)) _(by Chris <chrisbreuer93@gmail.com>)_

## 🧹 Chores

- release v0.0.38 ([36b1ec0](https://github.com/home-lang/craft/commit/36b1ec0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **pkg**: publish the TS package as @stacksjs/ts-craft ([21adc28](https://github.com/home-lang/craft/commit/21adc28)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: refresh lock after dropping archiver ([29adb84](https://github.com/home-lang/craft/commit/29adb84)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: refresh bun.lock to pick up pickier 0.1.37 ([33c8bd0](https://github.com/home-lang/craft/commit/33c8bd0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **deps**: refresh bun.lock to pick up pickier 0.1.35 ([d619105](https://github.com/home-lang/craft/commit/d619105)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **deps**: refresh bun.lock to pick up pickier 0.1.33 ([622d497](https://github.com/home-lang/craft/commit/622d497)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **deps**: pin Zig to 0.17-dev via pantry ([efa5543](https://github.com/home-lang/craft/commit/efa5543)) _(by Chris <chrisbreuer93@gmail.com>)_
- **deps**: refresh bun.lock to pick up @stacksjs/logsmith 0.2.3 ([5bc5e10](https://github.com/home-lang/craft/commit/5bc5e10)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **deps**: refresh bun.lock to pick up buddy-bot 0.9.20 ([3780779](https://github.com/home-lang/craft/commit/3780779)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- **deps**: bump better-dx to ^0.2.15 ([92acb43](https://github.com/home-lang/craft/commit/92acb43)) _(by glennmichael123 <gtorregosa@gmail.com>)_

## 📄 Miscellaneous

- Merge branch 'web-engine-zig-js' ([3f63bdb](https://github.com/home-lang/craft/commit/3f63bdb)) _(by Chris <chrisbreuer93@gmail.com>)_

## Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.36...v0.0.37)

### 🤖 Continuous Integration

- **release**: skip sysrootless linux cross targets ([9d84412](https://github.com/home-lang/craft/commit/9d84412)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.37 ([3a552d8](https://github.com/home-lang/craft/commit/3a552d8)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.36...HEAD)

### 🤖 Continuous Integration

- **release**: skip sysrootless linux cross targets ([9d84412](https://github.com/home-lang/craft/commit/9d84412)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.35...v0.0.36)

### 🤖 Continuous Integration

- **release**: publish zig package from workspace ([8fa0f1f](https://github.com/home-lang/craft/commit/8fa0f1f)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.36 ([a65e01f](https://github.com/home-lang/craft/commit/a65e01f)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.35...HEAD)

### 🤖 Continuous Integration

- **release**: publish zig package from workspace ([8fa0f1f](https://github.com/home-lang/craft/commit/8fa0f1f)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.34...v0.0.35)

### 🐛 Bug Fixes

- **zig**: align native build with Zig 0.17 ([a6917f8](https://github.com/home-lang/craft/commit/a6917f8)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.35 ([85622a3](https://github.com/home-lang/craft/commit/85622a3)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.34...HEAD)

### 🐛 Bug Fixes

- **zig**: align native build with Zig 0.17 ([a6917f8](https://github.com/home-lang/craft/commit/a6917f8)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.33...v0.0.34)

### 🐛 Bug Fixes

- **zig**: centralize sentinel string allocation ([95a263d](https://github.com/home-lang/craft/commit/95a263d)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.34 ([ec02470](https://github.com/home-lang/craft/commit/ec02470)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.33...HEAD)

### 🐛 Bug Fixes

- **zig**: centralize sentinel string allocation ([95a263d](https://github.com/home-lang/craft/commit/95a263d)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.32...v0.0.33)

### 🐛 Bug Fixes

- **zig**: support Zig 0.17 array repeats ([e2fb1c3](https://github.com/home-lang/craft/commit/e2fb1c3)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.33 ([a79edcf](https://github.com/home-lang/craft/commit/a79edcf)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.32...HEAD)

### 🐛 Bug Fixes

- **zig**: support Zig 0.17 array repeats ([e2fb1c3](https://github.com/home-lang/craft/commit/e2fb1c3)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.31...v0.0.32)

### 🤖 Continuous Integration

- filter pantry env shell exports ([4e7cc87](https://github.com/home-lang/craft/commit/4e7cc87)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.32 ([4074c6e](https://github.com/home-lang/craft/commit/4074c6e)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.31...HEAD)

### 🤖 Continuous Integration

- filter pantry env shell exports ([4e7cc87](https://github.com/home-lang/craft/commit/4e7cc87)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.30...v0.0.31)

### 🐛 Bug Fixes

- **macos**: avoid unsafe theme observer array creation ([0882ee0](https://github.com/home-lang/craft/commit/0882ee0)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.31 ([15ec9a4](https://github.com/home-lang/craft/commit/15ec9a4)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.30...HEAD)

### 🐛 Bug Fixes

- **macos**: avoid unsafe theme observer array creation ([0882ee0](https://github.com/home-lang/craft/commit/0882ee0)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.29...v0.0.30)

### ♻️ Code Refactoring

- **typescript**: rename sdk package to craft-native ([e1c295e](https://github.com/home-lang/craft/commit/e1c295e)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.30 ([b198bbe](https://github.com/home-lang/craft/commit/b198bbe)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.29...HEAD)

### ♻️ Code Refactoring

- **typescript**: rename sdk package to craft-native ([e1c295e](https://github.com/home-lang/craft/commit/e1c295e)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.28...v0.0.29)

## 🧹 Chores

- release v0.0.29 ([a8bdb22](https://github.com/home-lang/craft/commit/a8bdb22)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.27...v0.0.28)

### 💅 Styles

- **zig**: format bridge api source ([36ba7d2](https://github.com/home-lang/craft/commit/36ba7d2)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🤖 Continuous Integration

- use pantry stable zig toolchain ([a97b0be](https://github.com/home-lang/craft/commit/a97b0be)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.28 ([4edec57](https://github.com/home-lang/craft/commit/4edec57)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.27...HEAD)

### 💅 Styles

- **zig**: format bridge api source ([36ba7d2](https://github.com/home-lang/craft/commit/36ba7d2)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🤖 Continuous Integration

- use pantry stable zig toolchain ([a97b0be](https://github.com/home-lang/craft/commit/a97b0be)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.26...v0.0.27)

### 🧹 Chores

- release v0.0.27 ([0fe1af5](https://github.com/home-lang/craft/commit/0fe1af5)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.25...v0.0.26)

### 🐛 Bug Fixes

- **native**: implement serial and spotlight bridges ([c86de40](https://github.com/home-lang/craft/commit/c86de40)) _(by Chris <chrisbreuer93@gmail.com>)_
- **packages**: verify publishable package outputs ([7c3b968](https://github.com/home-lang/craft/commit/7c3b968)) _(by Chris <chrisbreuer93@gmail.com>)_
- **zig**: finish Zig 0.17 database migration ([b4221a0](https://github.com/home-lang/craft/commit/b4221a0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **packages**: align SDK and package builds ([eff83a9](https://github.com/home-lang/craft/commit/eff83a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- **zig**: migrate core to Zig 0.17 dev ([1b6f285](https://github.com/home-lang/craft/commit/1b6f285)) _(by Chris <chrisbreuer93@gmail.com>)_
- add setup-bun step to all CI and release jobs ([4b0e0f3](https://github.com/home-lang/craft/commit/4b0e0f3)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 🤖 Continuous Integration

- **sbom**: drop cyclonedx-npm; rely on syft (works with bun.lock) ([b52244a](https://github.com/home-lang/craft/commit/b52244a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- verify pantry builds and publishes ([afe7b95](https://github.com/home-lang/craft/commit/afe7b95)) _(by Chris <chrisbreuer93@gmail.com>)_
- fail real mobile build and test errors ([6a4c077](https://github.com/home-lang/craft/commit/6a4c077)) _(by Chris <chrisbreuer93@gmail.com>)_
- add publish-commit job for TypeScript SDK ([da709e6](https://github.com/home-lang/craft/commit/da709e6)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.26 ([0d03c51](https://github.com/home-lang/craft/commit/0d03c51)) _(by Chris <chrisbreuer93@gmail.com>)_
- **tooling**: use pantry env directly ([0160d17](https://github.com/home-lang/craft/commit/0160d17)) _(by Chris <chrisbreuer93@gmail.com>)_
- **tooling**: add cross-platform verification flow ([52f7628](https://github.com/home-lang/craft/commit/52f7628)) _(by Chris <chrisbreuer93@gmail.com>)_
- **tooling**: resolve Zig through pantry helper ([3ad019c](https://github.com/home-lang/craft/commit/3ad019c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7f520d3](https://github.com/home-lang/craft/commit/7f520d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: bump actions/checkout to v6, actions/cache to v5 ([16979cc](https://github.com/home-lang/craft/commit/16979cc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1e6a828](https://github.com/home-lang/craft/commit/1e6a828)) _(by Chris <chrisbreuer93@gmail.com>)_
- refresh bun.lock ([e7fa32a](https://github.com/home-lang/craft/commit/e7fa32a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ab2f7bb](https://github.com/home-lang/craft/commit/ab2f7bb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f05644c](https://github.com/home-lang/craft/commit/f05644c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([02e4117](https://github.com/home-lang/craft/commit/02e4117)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0282a3e](https://github.com/home-lang/craft/commit/0282a3e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c45459f](https://github.com/home-lang/craft/commit/c45459f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8b33422](https://github.com/home-lang/craft/commit/8b33422)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0ed0654](https://github.com/home-lang/craft/commit/0ed0654)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ce657d0](https://github.com/home-lang/craft/commit/ce657d0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6867722](https://github.com/home-lang/craft/commit/6867722)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a7b1f77](https://github.com/home-lang/craft/commit/a7b1f77)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([228ebfa](https://github.com/home-lang/craft/commit/228ebfa)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6fe683c](https://github.com/home-lang/craft/commit/6fe683c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([04508da](https://github.com/home-lang/craft/commit/04508da)) _(by Chris <chrisbreuer93@gmail.com>)_
- migrate all CI commands from bun to pantry ([4db16c6](https://github.com/home-lang/craft/commit/4db16c6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ee2836d](https://github.com/home-lang/craft/commit/ee2836d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- migrate from bun install to pantry install ([daba266](https://github.com/home-lang/craft/commit/daba266)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([10f2cdb](https://github.com/home-lang/craft/commit/10f2cdb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7eb97e0](https://github.com/home-lang/craft/commit/7eb97e0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([96771c3](https://github.com/home-lang/craft/commit/96771c3)) _(by Chris <chrisbreuer93@gmail.com>)_
- fresh install to pick up pickier 0.1.21 ([042ba29](https://github.com/home-lang/craft/commit/042ba29)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint errors ([51501c7](https://github.com/home-lang/craft/commit/51501c7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([653b4a3](https://github.com/home-lang/craft/commit/653b4a3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e030259](https://github.com/home-lang/craft/commit/e030259)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1c8633d](https://github.com/home-lang/craft/commit/1c8633d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([515fb45](https://github.com/home-lang/craft/commit/515fb45)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8fb1517](https://github.com/home-lang/craft/commit/8fb1517)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7abfa48](https://github.com/home-lang/craft/commit/7abfa48)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([37c3997](https://github.com/home-lang/craft/commit/37c3997)) _(by Chris <chrisbreuer93@gmail.com>)_
- gitignore pantry directory ([80de871](https://github.com/home-lang/craft/commit/80de871)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint errors ([3dc7c18](https://github.com/home-lang/craft/commit/3dc7c18)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- auto-fix lint errors ([0910c2e](https://github.com/home-lang/craft/commit/0910c2e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- include md in pickier lint extensions ([a52f405](https://github.com/home-lang/craft/commit/a52f405)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### ⏪ Reverts

- keep staged-lint kebab + bunx gitlint shorthand ([e21ed11](https://github.com/home-lang/craft/commit/e21ed11)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- restore bun commands in CI until pantry handles npm deps ([2aa2883](https://github.com/home-lang/craft/commit/2aa2883)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- use bun install until pantry handles npm deps (home-lang/pantry#200) ([80882fc](https://github.com/home-lang/craft/commit/80882fc)) _(by glennmichael123 <gtorregosa@gmail.com>)_ ([#200](https://github.com/home-lang/craft/issues/200), [#200](https://github.com/home-lang/craft/issues/200))

### merge

- resolve conflicts keeping pantry commands ([f2c580b](https://github.com/home-lang/craft/commit/f2c580b)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.25...HEAD)

### 🐛 Bug Fixes

- **native**: implement serial and spotlight bridges ([c86de40](https://github.com/home-lang/craft/commit/c86de40)) _(by Chris <chrisbreuer93@gmail.com>)_
- **packages**: verify publishable package outputs ([7c3b968](https://github.com/home-lang/craft/commit/7c3b968)) _(by Chris <chrisbreuer93@gmail.com>)_
- **zig**: finish Zig 0.17 database migration ([b4221a0](https://github.com/home-lang/craft/commit/b4221a0)) _(by Chris <chrisbreuer93@gmail.com>)_
- **packages**: align SDK and package builds ([eff83a9](https://github.com/home-lang/craft/commit/eff83a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- **zig**: migrate core to Zig 0.17 dev ([1b6f285](https://github.com/home-lang/craft/commit/1b6f285)) _(by Chris <chrisbreuer93@gmail.com>)_
- add setup-bun step to all CI and release jobs ([4b0e0f3](https://github.com/home-lang/craft/commit/4b0e0f3)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 🤖 Continuous Integration

- **sbom**: drop cyclonedx-npm; rely on syft (works with bun.lock) ([b52244a](https://github.com/home-lang/craft/commit/b52244a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- verify pantry builds and publishes ([afe7b95](https://github.com/home-lang/craft/commit/afe7b95)) _(by Chris <chrisbreuer93@gmail.com>)_
- fail real mobile build and test errors ([6a4c077](https://github.com/home-lang/craft/commit/6a4c077)) _(by Chris <chrisbreuer93@gmail.com>)_
- add publish-commit job for TypeScript SDK ([da709e6](https://github.com/home-lang/craft/commit/da709e6)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- **tooling**: use pantry env directly ([0160d17](https://github.com/home-lang/craft/commit/0160d17)) _(by Chris <chrisbreuer93@gmail.com>)_
- **tooling**: add cross-platform verification flow ([52f7628](https://github.com/home-lang/craft/commit/52f7628)) _(by Chris <chrisbreuer93@gmail.com>)_
- **tooling**: resolve Zig through pantry helper ([3ad019c](https://github.com/home-lang/craft/commit/3ad019c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7f520d3](https://github.com/home-lang/craft/commit/7f520d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- **ci**: bump actions/checkout to v6, actions/cache to v5 ([16979cc](https://github.com/home-lang/craft/commit/16979cc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1e6a828](https://github.com/home-lang/craft/commit/1e6a828)) _(by Chris <chrisbreuer93@gmail.com>)_
- refresh bun.lock ([e7fa32a](https://github.com/home-lang/craft/commit/e7fa32a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ab2f7bb](https://github.com/home-lang/craft/commit/ab2f7bb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f05644c](https://github.com/home-lang/craft/commit/f05644c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([02e4117](https://github.com/home-lang/craft/commit/02e4117)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0282a3e](https://github.com/home-lang/craft/commit/0282a3e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c45459f](https://github.com/home-lang/craft/commit/c45459f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8b33422](https://github.com/home-lang/craft/commit/8b33422)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0ed0654](https://github.com/home-lang/craft/commit/0ed0654)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ce657d0](https://github.com/home-lang/craft/commit/ce657d0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6867722](https://github.com/home-lang/craft/commit/6867722)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a7b1f77](https://github.com/home-lang/craft/commit/a7b1f77)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([228ebfa](https://github.com/home-lang/craft/commit/228ebfa)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6fe683c](https://github.com/home-lang/craft/commit/6fe683c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([04508da](https://github.com/home-lang/craft/commit/04508da)) _(by Chris <chrisbreuer93@gmail.com>)_
- migrate all CI commands from bun to pantry ([4db16c6](https://github.com/home-lang/craft/commit/4db16c6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ee2836d](https://github.com/home-lang/craft/commit/ee2836d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- migrate from bun install to pantry install ([daba266](https://github.com/home-lang/craft/commit/daba266)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([10f2cdb](https://github.com/home-lang/craft/commit/10f2cdb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7eb97e0](https://github.com/home-lang/craft/commit/7eb97e0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([96771c3](https://github.com/home-lang/craft/commit/96771c3)) _(by Chris <chrisbreuer93@gmail.com>)_
- fresh install to pick up pickier 0.1.21 ([042ba29](https://github.com/home-lang/craft/commit/042ba29)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint errors ([51501c7](https://github.com/home-lang/craft/commit/51501c7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([653b4a3](https://github.com/home-lang/craft/commit/653b4a3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e030259](https://github.com/home-lang/craft/commit/e030259)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1c8633d](https://github.com/home-lang/craft/commit/1c8633d)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([515fb45](https://github.com/home-lang/craft/commit/515fb45)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8fb1517](https://github.com/home-lang/craft/commit/8fb1517)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7abfa48](https://github.com/home-lang/craft/commit/7abfa48)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([37c3997](https://github.com/home-lang/craft/commit/37c3997)) _(by Chris <chrisbreuer93@gmail.com>)_
- gitignore pantry directory ([80de871](https://github.com/home-lang/craft/commit/80de871)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint errors ([3dc7c18](https://github.com/home-lang/craft/commit/3dc7c18)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- auto-fix lint errors ([0910c2e](https://github.com/home-lang/craft/commit/0910c2e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- include md in pickier lint extensions ([a52f405](https://github.com/home-lang/craft/commit/a52f405)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### ⏪ Reverts

- keep staged-lint kebab + bunx gitlint shorthand ([e21ed11](https://github.com/home-lang/craft/commit/e21ed11)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- restore bun commands in CI until pantry handles npm deps ([2aa2883](https://github.com/home-lang/craft/commit/2aa2883)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- use bun install until pantry handles npm deps (home-lang/pantry#200) ([80882fc](https://github.com/home-lang/craft/commit/80882fc)) _(by glennmichael123 <gtorregosa@gmail.com>)_ ([#200](https://github.com/home-lang/craft/issues/200), [#200](https://github.com/home-lang/craft/issues/200))

### merge

- resolve conflicts keeping pantry commands ([f2c580b](https://github.com/home-lang/craft/commit/f2c580b)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.24...v0.0.25)

## 🐛 Bug Fixes

- sidebar navigation uses window.navigate() instead of _sidebarSelectHandler ([01a4ddf](https://github.com/home-lang/craft/commit/01a4ddf)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- enable Cmd+Q to quit desktop windows ([b3ced0a](https://github.com/home-lang/craft/commit/b3ced0a)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 🤖 Continuous Integration

- retrigger with pantry bun fix ([be0734d](https://github.com/home-lang/craft/commit/be0734d)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.25 ([b6e488b](https://github.com/home-lang/craft/commit/b6e488b)) _(by Chris <chrisbreuer93@gmail.com>)_
- update lockfile ([f2a6bb7](https://github.com/home-lang/craft/commit/f2a6bb7)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.24...HEAD)

### 🐛 Bug Fixes

- sidebar navigation uses window.navigate() instead of _sidebarSelectHandler ([01a4ddf](https://github.com/home-lang/craft/commit/01a4ddf)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- enable Cmd+Q to quit desktop windows ([b3ced0a](https://github.com/home-lang/craft/commit/b3ced0a)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 🤖 Continuous Integration

- retrigger with pantry bun fix ([be0734d](https://github.com/home-lang/craft/commit/be0734d)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- update lockfile ([f2a6bb7](https://github.com/home-lang/craft/commit/f2a6bb7)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.23...v0.0.24)

### 🐛 Bug Fixes

- simplify release workflow — pantry handles packaging & release ([f763338](https://github.com/home-lang/craft/commit/f763338)) _(by Chris <chrisbreuer93@gmail.com>)_
- let pantry read versions from pantry.jsonc, use pantry publish ([39c4532](https://github.com/home-lang/craft/commit/39c4532)) _(by Chris <chrisbreuer93@gmail.com>)_
- remove pinned pantry version, use latest ([56822e1](https://github.com/home-lang/craft/commit/56822e1)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry v0.9.15 with TS installer SDK ([a0247e3](https://github.com/home-lang/craft/commit/a0247e3)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry v0.9.14 ([607a5e6](https://github.com/home-lang/craft/commit/607a5e6)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry v0.9.12 with Windows zig PATH fix ([5e532a9](https://github.com/home-lang/craft/commit/5e532a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry v0.9.11 exclusively — no mlugg fallback ([6fd258b](https://github.com/home-lang/craft/commit/6fd258b)) _(by Chris <chrisbreuer93@gmail.com>)_
- pin pantry v0.9.10 to bypass stale toolcache ([6d7425c](https://github.com/home-lang/craft/commit/6d7425c)) _(by Chris <chrisbreuer93@gmail.com>)_
- add bun.sh to pantry.jsonc system deps ([dbad386](https://github.com/home-lang/craft/commit/dbad386)) _(by Chris <chrisbreuer93@gmail.com>)_
- add setup-bun for typescript-sdk job ([eff2d95](https://github.com/home-lang/craft/commit/eff2d95)) _(by Chris <chrisbreuer93@gmail.com>)_
- add mlugg/setup-zig as Windows fallback ([46c1799](https://github.com/home-lang/craft/commit/46c1799)) _(by Chris <chrisbreuer93@gmail.com>)_
- pass zig version explicitly to pantry action packages input ([3ae17a4](https://github.com/home-lang/craft/commit/3ae17a4)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry exclusively for Zig setup, remove mlugg/setup-zig ([4125f61](https://github.com/home-lang/craft/commit/4125f61)) _(by Chris <chrisbreuer93@gmail.com>)_
- use .FALSE enum for BOOL comparison in windows_tray ([289a527](https://github.com/home-lang/craft/commit/289a527)) _(by Chris <chrisbreuer93@gmail.com>)_
- windows_tray BOOL comparison for zig 0.16.0-dev.2984 ([160db7f](https://github.com/home-lang/craft/commit/160db7f)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry for bun + mlugg/setup-zig for zig in CI ([a53981c](https://github.com/home-lang/craft/commit/a53981c)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry for Zig setup in CI, update to zig 0.16.0-dev.2984 ([ca46fcc](https://github.com/home-lang/craft/commit/ca46fcc)) _(by Chris <chrisbreuer93@gmail.com>)_
- align CI Zig version with local (0.16.0-dev.2471) ([cec5ce7](https://github.com/home-lang/craft/commit/cec5ce7)) _(by Chris <chrisbreuer93@gmail.com>)_
- vendor SQLite amalgamation, fix Windows build, fix all tests ([6f209d5](https://github.com/home-lang/craft/commit/6f209d5)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🤖 Continuous Integration

- retrigger with pantry v0.9.10 ([d7a8116](https://github.com/home-lang/craft/commit/d7a8116)) _(by Chris <chrisbreuer93@gmail.com>)_
- retrigger with pantry v0.9.9 (zig direct download fix) ([b9c9317](https://github.com/home-lang/craft/commit/b9c9317)) _(by Chris <chrisbreuer93@gmail.com>)_
- retrigger with updated pantry action ([ff55e25](https://github.com/home-lang/craft/commit/ff55e25)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.24 ([4f5a907](https://github.com/home-lang/craft/commit/4f5a907)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0ed4818](https://github.com/home-lang/craft/commit/0ed4818)) _(by Chris <chrisbreuer93@gmail.com>)_

### 📄 Miscellaneous

- Revert "fix: add setup-bun for typescript-sdk job" ([7aa3593](https://github.com/home-lang/craft/commit/7aa3593)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.23...HEAD)

### 🐛 Bug Fixes

- simplify release workflow — pantry handles packaging & release ([f763338](https://github.com/home-lang/craft/commit/f763338)) _(by Chris <chrisbreuer93@gmail.com>)_
- let pantry read versions from pantry.jsonc, use pantry publish ([39c4532](https://github.com/home-lang/craft/commit/39c4532)) _(by Chris <chrisbreuer93@gmail.com>)_
- remove pinned pantry version, use latest ([56822e1](https://github.com/home-lang/craft/commit/56822e1)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry v0.9.15 with TS installer SDK ([a0247e3](https://github.com/home-lang/craft/commit/a0247e3)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry v0.9.14 ([607a5e6](https://github.com/home-lang/craft/commit/607a5e6)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry v0.9.12 with Windows zig PATH fix ([5e532a9](https://github.com/home-lang/craft/commit/5e532a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry v0.9.11 exclusively — no mlugg fallback ([6fd258b](https://github.com/home-lang/craft/commit/6fd258b)) _(by Chris <chrisbreuer93@gmail.com>)_
- pin pantry v0.9.10 to bypass stale toolcache ([6d7425c](https://github.com/home-lang/craft/commit/6d7425c)) _(by Chris <chrisbreuer93@gmail.com>)_
- add bun.sh to pantry.jsonc system deps ([dbad386](https://github.com/home-lang/craft/commit/dbad386)) _(by Chris <chrisbreuer93@gmail.com>)_
- add setup-bun for typescript-sdk job ([eff2d95](https://github.com/home-lang/craft/commit/eff2d95)) _(by Chris <chrisbreuer93@gmail.com>)_
- add mlugg/setup-zig as Windows fallback ([46c1799](https://github.com/home-lang/craft/commit/46c1799)) _(by Chris <chrisbreuer93@gmail.com>)_
- pass zig version explicitly to pantry action packages input ([3ae17a4](https://github.com/home-lang/craft/commit/3ae17a4)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry exclusively for Zig setup, remove mlugg/setup-zig ([4125f61](https://github.com/home-lang/craft/commit/4125f61)) _(by Chris <chrisbreuer93@gmail.com>)_
- use .FALSE enum for BOOL comparison in windows_tray ([289a527](https://github.com/home-lang/craft/commit/289a527)) _(by Chris <chrisbreuer93@gmail.com>)_
- windows_tray BOOL comparison for zig 0.16.0-dev.2984 ([160db7f](https://github.com/home-lang/craft/commit/160db7f)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry for bun + mlugg/setup-zig for zig in CI ([a53981c](https://github.com/home-lang/craft/commit/a53981c)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry for Zig setup in CI, update to zig 0.16.0-dev.2984 ([ca46fcc](https://github.com/home-lang/craft/commit/ca46fcc)) _(by Chris <chrisbreuer93@gmail.com>)_
- align CI Zig version with local (0.16.0-dev.2471) ([cec5ce7](https://github.com/home-lang/craft/commit/cec5ce7)) _(by Chris <chrisbreuer93@gmail.com>)_
- vendor SQLite amalgamation, fix Windows build, fix all tests ([6f209d5](https://github.com/home-lang/craft/commit/6f209d5)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🤖 Continuous Integration

- retrigger with pantry v0.9.10 ([d7a8116](https://github.com/home-lang/craft/commit/d7a8116)) _(by Chris <chrisbreuer93@gmail.com>)_
- retrigger with pantry v0.9.9 (zig direct download fix) ([b9c9317](https://github.com/home-lang/craft/commit/b9c9317)) _(by Chris <chrisbreuer93@gmail.com>)_
- retrigger with updated pantry action ([ff55e25](https://github.com/home-lang/craft/commit/ff55e25)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- wip ([0ed4818](https://github.com/home-lang/craft/commit/0ed4818)) _(by Chris <chrisbreuer93@gmail.com>)_

### 📄 Miscellaneous

- Revert "fix: add setup-bun for typescript-sdk job" ([7aa3593](https://github.com/home-lang/craft/commit/7aa3593)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.22...v0.0.23)

### 🐛 Bug Fixes

- gracefully skip cross-compile targets missing system libraries ([b4805bf](https://github.com/home-lang/craft/commit/b4805bf)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.23 ([d0ec498](https://github.com/home-lang/craft/commit/d0ec498)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.22...HEAD)

### 🐛 Bug Fixes

- gracefully skip cross-compile targets missing system libraries ([b4805bf](https://github.com/home-lang/craft/commit/b4805bf)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.21...v0.0.22)

### 🐛 Bug Fixes

- only link sqlite3 on macOS/Linux, not cross-compile targets ([0a18e05](https://github.com/home-lang/craft/commit/0a18e05)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.22 ([692ec39](https://github.com/home-lang/craft/commit/692ec39)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.21...HEAD)

### 🐛 Bug Fixes

- only link sqlite3 on macOS/Linux, not cross-compile targets ([0a18e05](https://github.com/home-lang/craft/commit/0a18e05)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.20...v0.0.21)

### 🧹 Chores

- release v0.0.21 ([3538421](https://github.com/home-lang/craft/commit/3538421)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.19...v0.0.20)

### 🚀 Features

- use pantry action for GitHub releases, add release:patch script ([d58ca31](https://github.com/home-lang/craft/commit/d58ca31)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.20 ([b01861d](https://github.com/home-lang/craft/commit/b01861d)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.19...HEAD)

### 🚀 Features

- use pantry action for GitHub releases, add release:patch script ([d58ca31](https://github.com/home-lang/craft/commit/d58ca31)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.18...v0.0.19)

### 🐛 Bug Fixes

- use -Dmacos-sdk instead of --sysroot for cross-compilation ([f94ccd5](https://github.com/home-lang/craft/commit/f94ccd5)) _(by Chris <chrisbreuer93@gmail.com>)_
- only add framework paths from sysroot, not include/lib ([fcea9f2](https://github.com/home-lang/craft/commit/fcea9f2)) _(by Chris <chrisbreuer93@gmail.com>)_
- add sysroot framework search paths for zig cross-compilation ([dc3d85c](https://github.com/home-lang/craft/commit/dc3d85c)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.19 ([ab21916](https://github.com/home-lang/craft/commit/ab21916)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.18...HEAD)

### 🐛 Bug Fixes

- use -Dmacos-sdk instead of --sysroot for cross-compilation ([f94ccd5](https://github.com/home-lang/craft/commit/f94ccd5)) _(by Chris <chrisbreuer93@gmail.com>)_
- only add framework paths from sysroot, not include/lib ([fcea9f2](https://github.com/home-lang/craft/commit/fcea9f2)) _(by Chris <chrisbreuer93@gmail.com>)_
- add sysroot framework search paths for zig cross-compilation ([dc3d85c](https://github.com/home-lang/craft/commit/dc3d85c)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.17...v0.0.18)

### 🐛 Bug Fixes

- resolve release and mobile E2E CI failures ([201d5fa](https://github.com/home-lang/craft/commit/201d5fa)) _(by Chris <chrisbreuer93@gmail.com>)_

### ♻️ Code Refactoring

- merge code coverage into CI workflow ([747f03b](https://github.com/home-lang/craft/commit/747f03b)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.18 ([8d56679](https://github.com/home-lang/craft/commit/8d56679)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d6c8bd8](https://github.com/home-lang/craft/commit/d6c8bd8)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.17...HEAD)

### 🐛 Bug Fixes

- resolve release and mobile E2E CI failures ([201d5fa](https://github.com/home-lang/craft/commit/201d5fa)) _(by Chris <chrisbreuer93@gmail.com>)_

### ♻️ Code Refactoring

- merge code coverage into CI workflow ([747f03b](https://github.com/home-lang/craft/commit/747f03b)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- wip ([d6c8bd8](https://github.com/home-lang/craft/commit/d6c8bd8)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.16...v0.0.17)

### 🚀 Features

- build all platform binaries matching pantry's release matrix ([92f22c9](https://github.com/home-lang/craft/commit/92f22c9)) _(by Chris <chrisbreuer93@gmail.com>)_
- attach platform binaries and checksums to GitHub releases ([725ae5a](https://github.com/home-lang/craft/commit/725ae5a)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🐛 Bug Fixes

- correct SBOM vulnerability-scan job dependency name ([e1549e4](https://github.com/home-lang/craft/commit/e1549e4)) _(by Chris <chrisbreuer93@gmail.com>)_
- iOS simulator build and add cross-compiled release binaries ([025c080](https://github.com/home-lang/craft/commit/025c080)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.17 ([990533d](https://github.com/home-lang/craft/commit/990533d)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.16...HEAD)

### 🚀 Features

- build all platform binaries matching pantry's release matrix ([92f22c9](https://github.com/home-lang/craft/commit/92f22c9)) _(by Chris <chrisbreuer93@gmail.com>)_
- attach platform binaries and checksums to GitHub releases ([725ae5a](https://github.com/home-lang/craft/commit/725ae5a)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🐛 Bug Fixes

- correct SBOM vulnerability-scan job dependency name ([e1549e4](https://github.com/home-lang/craft/commit/e1549e4)) _(by Chris <chrisbreuer93@gmail.com>)_
- iOS simulator build and add cross-compiled release binaries ([025c080](https://github.com/home-lang/craft/commit/025c080)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.15...v0.0.16)

### 🐛 Bug Fixes

- iOS build uses dedicated build steps instead of default target ([a206b89](https://github.com/home-lang/craft/commit/a206b89)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.16 ([0d6fb97](https://github.com/home-lang/craft/commit/0d6fb97)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.15...HEAD)

### 🐛 Bug Fixes

- iOS build uses dedicated build steps instead of default target ([a206b89](https://github.com/home-lang/craft/commit/a206b89)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.14...v0.0.15)

### 🐛 Bug Fixes

- move GitHub Release to pantry job, use PAT token ([843df80](https://github.com/home-lang/craft/commit/843df80)) _(by Chris <chrisbreuer93@gmail.com>)_

### ♻️ Code Refactoring

- consolidate signed release into release.yml ([31d55fc](https://github.com/home-lang/craft/commit/31d55fc)) _(by Chris <chrisbreuer93@gmail.com>)_
- rename release jobs to pantry and npm ([ade5493](https://github.com/home-lang/craft/commit/ade5493)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.15 ([618677b](https://github.com/home-lang/craft/commit/618677b)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.14...HEAD)

### 🐛 Bug Fixes

- move GitHub Release to pantry job, use PAT token ([843df80](https://github.com/home-lang/craft/commit/843df80)) _(by Chris <chrisbreuer93@gmail.com>)_

### ♻️ Code Refactoring

- consolidate signed release into release.yml ([31d55fc](https://github.com/home-lang/craft/commit/31d55fc)) _(by Chris <chrisbreuer93@gmail.com>)_
- rename release jobs to pantry and npm ([ade5493](https://github.com/home-lang/craft/commit/ade5493)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.13...v0.0.14)

### 🚀 Features

- build and publish platform-specific binaries ([20beeef](https://github.com/home-lang/craft/commit/20beeef)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🐛 Bug Fixes

- inject version from package.json into Zig binary ([31deb16](https://github.com/home-lang/craft/commit/31deb16)) _(by Chris <chrisbreuer93@gmail.com>)_
- use AWS CLI for S3 upload instead of pantry publish:binary ([5193e86](https://github.com/home-lang/craft/commit/5193e86)) _(by Chris <chrisbreuer93@gmail.com>)_
- rename all @craft-native/ts references to craft-native ([b21c48d](https://github.com/home-lang/craft/commit/b21c48d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix broken imports in ecommerce and social templates ([693d81d](https://github.com/home-lang/craft/commit/693d81d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- pass iOS Simulator SDK sysroot for cross-compilation ([b3e381b](https://github.com/home-lang/craft/commit/b3e381b)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.14 ([be032f7](https://github.com/home-lang/craft/commit/be032f7)) _(by Chris <chrisbreuer93@gmail.com>)_
- update lockfile ([1fd9ee9](https://github.com/home-lang/craft/commit/1fd9ee9)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/main...HEAD)

### 🐛 Bug Fixes

- inject version from package.json into Zig binary ([31deb16](https://github.com/home-lang/craft/commit/31deb16)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- update lockfile ([1fd9ee9](https://github.com/home-lang/craft/commit/1fd9ee9)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.12...v0.0.13)

### 🧹 Chores

- release v0.0.13 ([43df471](https://github.com/home-lang/craft/commit/43df471)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.11...v0.0.12)

### 🐛 Bug Fixes

- use PANTRY_TOKEN for registry upload instead of AWS credentials ([cbe24bc](https://github.com/home-lang/craft/commit/cbe24bc)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.12 ([82d4be4](https://github.com/home-lang/craft/commit/82d4be4)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.11...HEAD)

### 🐛 Bug Fixes

- use PANTRY_TOKEN for registry upload instead of AWS credentials ([cbe24bc](https://github.com/home-lang/craft/commit/cbe24bc)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.10...v0.0.11)

### 🧹 Chores

- release v0.0.11 ([81eaad4](https://github.com/home-lang/craft/commit/81eaad4)) _(by Chris <chrisbreuer93@gmail.com>)_
- get craft bins to work ([55fdcd4](https://github.com/home-lang/craft/commit/55fdcd4)) _(by Chris <chrisbreuer93@gmail.com>)_
- update org name ([94aa0eb](https://github.com/home-lang/craft/commit/94aa0eb)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.10...HEAD)

### 🧹 Chores

- get craft bins to work ([55fdcd4](https://github.com/home-lang/craft/commit/55fdcd4)) _(by Chris <chrisbreuer93@gmail.com>)_
- update org name ([94aa0eb](https://github.com/home-lang/craft/commit/94aa0eb)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.9...v0.0.10)

### 🧹 Chores

- release v0.0.10 ([4edd950](https://github.com/home-lang/craft/commit/4edd950)) _(by Chris <chrisbreuer93@gmail.com>)_
- rename ([e098db0](https://github.com/home-lang/craft/commit/e098db0)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.9...HEAD)

### 🧹 Chores

- rename ([e098db0](https://github.com/home-lang/craft/commit/e098db0)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.8...v0.0.9)

### 🐛 Bug Fixes

- install GTK3 and WebKit2GTK before building on Linux CI ([fd2e63f](https://github.com/home-lang/craft/commit/fd2e63f)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.9 ([21d4688](https://github.com/home-lang/craft/commit/21d4688)) _(by Chris <chrisbreuer93@gmail.com>)_
- update lockfile ([4289a2e](https://github.com/home-lang/craft/commit/4289a2e)) _(by Chris <chrisbreuer93@gmail.com>)_
- rename package ([2704f3c](https://github.com/home-lang/craft/commit/2704f3c)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.8...HEAD)

### 🐛 Bug Fixes

- install GTK3 and WebKit2GTK before building on Linux CI ([fd2e63f](https://github.com/home-lang/craft/commit/fd2e63f)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- update lockfile ([4289a2e](https://github.com/home-lang/craft/commit/4289a2e)) _(by Chris <chrisbreuer93@gmail.com>)_
- rename package ([2704f3c](https://github.com/home-lang/craft/commit/2704f3c)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.7...v0.0.8)

### 🧹 Chores

- release v0.0.8 ([10f2c63](https://github.com/home-lang/craft/commit/10f2c63)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f9cf542](https://github.com/home-lang/craft/commit/f9cf542)) _(by Chris <chrisbreuer93@gmail.com>)_
- minor action adjustments ([fb5e0bf](https://github.com/home-lang/craft/commit/fb5e0bf)) _(by Chris <chrisbreuer93@gmail.com>)_
- minor adjustments ([ad7893a](https://github.com/home-lang/craft/commit/ad7893a)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.7...HEAD)

### 🧹 Chores

- wip ([f9cf542](https://github.com/home-lang/craft/commit/f9cf542)) _(by Chris <chrisbreuer93@gmail.com>)_
- minor action adjustments ([fb5e0bf](https://github.com/home-lang/craft/commit/fb5e0bf)) _(by Chris <chrisbreuer93@gmail.com>)_
- minor adjustments ([ad7893a](https://github.com/home-lang/craft/commit/ad7893a)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.6...v0.0.7)

### 🚀 Features

- publish craft binary via pantry publish ([ab86762](https://github.com/home-lang/craft/commit/ab86762)) _(by Chris <chrisbreuer93@gmail.com>)_
- publish native binary to pantry S3 registry on release ([56bc4b5](https://github.com/home-lang/craft/commit/56bc4b5)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.7 ([cf5e2f0](https://github.com/home-lang/craft/commit/cf5e2f0)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.6...HEAD)

### 🚀 Features

- publish craft binary via pantry publish ([ab86762](https://github.com/home-lang/craft/commit/ab86762)) _(by Chris <chrisbreuer93@gmail.com>)_
- publish native binary to pantry S3 registry on release ([56bc4b5](https://github.com/home-lang/craft/commit/56bc4b5)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.5...v0.0.6)

### 🐛 Bug Fixes

- update zig source for 0.16.0-dev.2962+ compatibility ([861307e](https://github.com/home-lang/craft/commit/861307e)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- release v0.0.6 ([c155d12](https://github.com/home-lang/craft/commit/c155d12)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9afde30](https://github.com/home-lang/craft/commit/9afde30)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.5...HEAD)

### 🐛 Bug Fixes

- update zig source for 0.16.0-dev.2962+ compatibility ([861307e](https://github.com/home-lang/craft/commit/861307e)) _(by Chris <chrisbreuer93@gmail.com>)_

### 🧹 Chores

- wip ([9afde30](https://github.com/home-lang/craft/commit/9afde30)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.4...v0.0.5)

### 🚀 Features

- add virtual scrolling and testing utilities ([4a186d8](https://github.com/home-lang/craft/commit/4a186d8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add partial hydration (islands architecture) ([8c8ef10](https://github.com/home-lang/craft/commit/8c8ef10)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add transitions, error boundaries, and keep-alive ([ffd1ca2](https://github.com/home-lang/craft/commit/ffd1ca2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add stores, form validation, and browser composables ([aa431da](https://github.com/home-lang/craft/commit/aa431da)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- scope isolation fix, new primitives, composables, expanded auto-imports ([65651b2](https://github.com/home-lang/craft/commit/65651b2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add client-side router, StxLink component, and app shell support ([fed7282](https://github.com/home-lang/craft/commit/fed7282)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- align SFC compiler with stx v2 syntax migration ([f41901c](https://github.com/home-lang/craft/commit/f41901c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- dark mode, SFC compiler, tests, template migrations, create-craft update ([3528be9](https://github.com/home-lang/craft/commit/3528be9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add crosswind CSS and migrate templates to stx ([2e3b666](https://github.com/home-lang/craft/commit/2e3b666)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add stx component library and unified cross-platform build system ([934e30c](https://github.com/home-lang/craft/commit/934e30c)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 🐛 Bug Fixes

- resolve typecheck error in hot-reload ([c482985](https://github.com/home-lang/craft/commit/c482985)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- replace hardcoded CSS with crosswind JIT generation ([10464f6](https://github.com/home-lang/craft/commit/10464f6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- split release into pantry + npm jobs, use domain names in deps ([02b38df](https://github.com/home-lang/craft/commit/02b38df)) _(by Chris <chrisbreuer93@gmail.com>)_

### ♻️ Code Refactoring

- remove stx package from craft repo ([e529d45](https://github.com/home-lang/craft/commit/e529d45)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- align stx runtime with stx syntax migration ([3dc4daf](https://github.com/home-lang/craft/commit/3dc4daf)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 🧹 Chores

- release v0.0.5 ([9ddf318](https://github.com/home-lang/craft/commit/9ddf318)) _(by Chris <chrisbreuer93@gmail.com>)_
- update zig to 0.16.0-dev.2962+08416b44f ([84d1cd9](https://github.com/home-lang/craft/commit/84d1cd9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([836e2f6](https://github.com/home-lang/craft/commit/836e2f6)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([aac723a](https://github.com/home-lang/craft/commit/aac723a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e64c035](https://github.com/home-lang/craft/commit/e64c035)) _(by Chris <chrisbreuer93@gmail.com>)_
- repo cleanup and modernization ([ca2f1dc](https://github.com/home-lang/craft/commit/ca2f1dc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9abafdd](https://github.com/home-lang/craft/commit/9abafdd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add git-hooks config ([531917c](https://github.com/home-lang/craft/commit/531917c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- remove version-specific language from stx compiler and tests ([22eecc0](https://github.com/home-lang/craft/commit/22eecc0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a3a8bd6](https://github.com/home-lang/craft/commit/a3a8bd6)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5a59295](https://github.com/home-lang/craft/commit/5a59295)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d5bf643](https://github.com/home-lang/craft/commit/d5bf643)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([42cfe6a](https://github.com/home-lang/craft/commit/42cfe6a)) _(by Chris <chrisbreuer93@gmail.com>)_
- fix remaining lint warning ([ed9120c](https://github.com/home-lang/craft/commit/ed9120c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint warnings ([b4af828](https://github.com/home-lang/craft/commit/b4af828)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e732101](https://github.com/home-lang/craft/commit/e732101)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9387129](https://github.com/home-lang/craft/commit/9387129)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f58f74b](https://github.com/home-lang/craft/commit/f58f74b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([98783e0](https://github.com/home-lang/craft/commit/98783e0)) _(by Chris <chrisbreuer93@gmail.com>)_
- fix lint warnings ([35da09e](https://github.com/home-lang/craft/commit/35da09e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint warnings ([3c74dea](https://github.com/home-lang/craft/commit/3c74dea)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.4...HEAD)

### 🚀 Features

- add virtual scrolling and testing utilities ([4a186d8](https://github.com/home-lang/craft/commit/4a186d8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add partial hydration (islands architecture) ([8c8ef10](https://github.com/home-lang/craft/commit/8c8ef10)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add transitions, error boundaries, and keep-alive ([ffd1ca2](https://github.com/home-lang/craft/commit/ffd1ca2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add stores, form validation, and browser composables ([aa431da](https://github.com/home-lang/craft/commit/aa431da)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- scope isolation fix, new primitives, composables, expanded auto-imports ([65651b2](https://github.com/home-lang/craft/commit/65651b2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add client-side router, StxLink component, and app shell support ([fed7282](https://github.com/home-lang/craft/commit/fed7282)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- align SFC compiler with stx v2 syntax migration ([f41901c](https://github.com/home-lang/craft/commit/f41901c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- dark mode, SFC compiler, tests, template migrations, create-craft update ([3528be9](https://github.com/home-lang/craft/commit/3528be9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add crosswind CSS and migrate templates to stx ([2e3b666](https://github.com/home-lang/craft/commit/2e3b666)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add stx component library and unified cross-platform build system ([934e30c](https://github.com/home-lang/craft/commit/934e30c)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 🐛 Bug Fixes

- resolve typecheck error in hot-reload ([c482985](https://github.com/home-lang/craft/commit/c482985)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- replace hardcoded CSS with crosswind JIT generation ([10464f6](https://github.com/home-lang/craft/commit/10464f6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- split release into pantry + npm jobs, use domain names in deps ([02b38df](https://github.com/home-lang/craft/commit/02b38df)) _(by Chris <chrisbreuer93@gmail.com>)_

### ♻️ Code Refactoring

- remove stx package from craft repo ([e529d45](https://github.com/home-lang/craft/commit/e529d45)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- align stx runtime with stx syntax migration ([3dc4daf](https://github.com/home-lang/craft/commit/3dc4daf)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 🧹 Chores

- update zig to 0.16.0-dev.2962+08416b44f ([84d1cd9](https://github.com/home-lang/craft/commit/84d1cd9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([836e2f6](https://github.com/home-lang/craft/commit/836e2f6)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([aac723a](https://github.com/home-lang/craft/commit/aac723a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e64c035](https://github.com/home-lang/craft/commit/e64c035)) _(by Chris <chrisbreuer93@gmail.com>)_
- repo cleanup and modernization ([ca2f1dc](https://github.com/home-lang/craft/commit/ca2f1dc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9abafdd](https://github.com/home-lang/craft/commit/9abafdd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add git-hooks config ([531917c](https://github.com/home-lang/craft/commit/531917c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- remove version-specific language from stx compiler and tests ([22eecc0](https://github.com/home-lang/craft/commit/22eecc0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a3a8bd6](https://github.com/home-lang/craft/commit/a3a8bd6)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5a59295](https://github.com/home-lang/craft/commit/5a59295)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d5bf643](https://github.com/home-lang/craft/commit/d5bf643)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([42cfe6a](https://github.com/home-lang/craft/commit/42cfe6a)) _(by Chris <chrisbreuer93@gmail.com>)_
- fix remaining lint warning ([ed9120c](https://github.com/home-lang/craft/commit/ed9120c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint warnings ([b4af828](https://github.com/home-lang/craft/commit/b4af828)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e732101](https://github.com/home-lang/craft/commit/e732101)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9387129](https://github.com/home-lang/craft/commit/9387129)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f58f74b](https://github.com/home-lang/craft/commit/f58f74b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([98783e0](https://github.com/home-lang/craft/commit/98783e0)) _(by Chris <chrisbreuer93@gmail.com>)_
- fix lint warnings ([35da09e](https://github.com/home-lang/craft/commit/35da09e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- fix lint warnings ([3c74dea](https://github.com/home-lang/craft/commit/3c74dea)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.3...v0.0.4)

### 🧹 Chores

- release v0.0.4 ([685e553](https://github.com/home-lang/craft/commit/685e553)) _(by Chris <chrisbreuer93@gmail.com>)_
- publish to both pantry registry and npm ([3c59fd3](https://github.com/home-lang/craft/commit/3c59fd3)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.3...HEAD)

### 🧹 Chores

- publish to both pantry registry and npm ([3c59fd3](https://github.com/home-lang/craft/commit/3c59fd3)) _(by Chris <chrisbreuer93@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_

[Compare changes](https://github.com/home-lang/craft/compare/v0.0.2...v0.0.3)

### 🧹 Chores

- release v0.0.3 ([60e204f](https://github.com/home-lang/craft/commit/60e204f)) _(by Chris <chrisbreuer93@gmail.com>)_
- use pantry action for release, fix deps.yaml domain names ([862c9d3](https://github.com/home-lang/craft/commit/862c9d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9617bae](https://github.com/home-lang/craft/commit/9617bae)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([203c441](https://github.com/home-lang/craft/commit/203c441)) _(by Chris <chrisbreuer93@gmail.com>)_
- enrich CLAUDE.md with detailed project context from README ([296b7a7](https://github.com/home-lang/craft/commit/296b7a7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- update CLAUDE.md with project context and crosswind details ([8692fd0](https://github.com/home-lang/craft/commit/8692fd0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add proper claude code guidelines ([b32a0fd](https://github.com/home-lang/craft/commit/b32a0fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- use pantry monorepo action instead of pantry-setup ([1513083](https://github.com/home-lang/craft/commit/1513083)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- ignore claude config in linter ([ea90340](https://github.com/home-lang/craft/commit/ea90340)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add claude code guidelines ([0125d75](https://github.com/home-lang/craft/commit/0125d75)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([77dd226](https://github.com/home-lang/craft/commit/77dd226)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([48e7f91](https://github.com/home-lang/craft/commit/48e7f91)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([bfc25d8](https://github.com/home-lang/craft/commit/bfc25d8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b768617](https://github.com/home-lang/craft/commit/b768617)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8c783ac](https://github.com/home-lang/craft/commit/8c783ac)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([74e5b72](https://github.com/home-lang/craft/commit/74e5b72)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c0319af](https://github.com/home-lang/craft/commit/c0319af)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a21f632](https://github.com/home-lang/craft/commit/a21f632)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1f29236](https://github.com/home-lang/craft/commit/1f29236)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3fc48c1](https://github.com/home-lang/craft/commit/3fc48c1)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e4c927e](https://github.com/home-lang/craft/commit/e4c927e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c5050c5](https://github.com/home-lang/craft/commit/c5050c5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5eb6225](https://github.com/home-lang/craft/commit/5eb6225)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([07efbef](https://github.com/home-lang/craft/commit/07efbef)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5d2c51d](https://github.com/home-lang/craft/commit/5d2c51d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([989962c](https://github.com/home-lang/craft/commit/989962c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2ea6289](https://github.com/home-lang/craft/commit/2ea6289)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2a4ec4c](https://github.com/home-lang/craft/commit/2a4ec4c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([093755a](https://github.com/home-lang/craft/commit/093755a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([89d9cde](https://github.com/home-lang/craft/commit/89d9cde)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([46906c3](https://github.com/home-lang/craft/commit/46906c3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7952d04](https://github.com/home-lang/craft/commit/7952d04)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9e40be7](https://github.com/home-lang/craft/commit/9e40be7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([cc5d461](https://github.com/home-lang/craft/commit/cc5d461)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([fc9d25b](https://github.com/home-lang/craft/commit/fc9d25b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3ed0121](https://github.com/home-lang/craft/commit/3ed0121)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7e67755](https://github.com/home-lang/craft/commit/7e67755)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8532b39](https://github.com/home-lang/craft/commit/8532b39)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e13e475](https://github.com/home-lang/craft/commit/e13e475)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2f232ad](https://github.com/home-lang/craft/commit/2f232ad)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([46b1e42](https://github.com/home-lang/craft/commit/46b1e42)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d4eae10](https://github.com/home-lang/craft/commit/d4eae10)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8663714](https://github.com/home-lang/craft/commit/8663714)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b919a1b](https://github.com/home-lang/craft/commit/b919a1b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c0d8c44](https://github.com/home-lang/craft/commit/c0d8c44)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([28e2d1e](https://github.com/home-lang/craft/commit/28e2d1e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([dd69365](https://github.com/home-lang/craft/commit/dd69365)) _(by Chris <chrisbreuer93@gmail.com>)_
- release v0.0.2 ([bb939be](https://github.com/home-lang/craft/commit/bb939be)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### 📄 Miscellaneous

- Merge pull request #7 from home-lang/renovate/oven-sh-setup-bun-2.x ([60d7f0b](https://github.com/home-lang/craft/commit/60d7f0b)) _(by [renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>](https://github.com/renovate[bot]))_ ([#7](https://github.com/home-lang/craft/issues/7), [#7](https://github.com/home-lang/craft/issues/7))

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _[renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>](https://github.com/renovate[bot])_
- _glennmichael123 <gtorregosa@gmail.com>_

### 🧹 Chores

- use pantry action for release, fix deps.yaml domain names ([862c9d3](https://github.com/home-lang/craft/commit/862c9d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9617bae](https://github.com/home-lang/craft/commit/9617bae)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([203c441](https://github.com/home-lang/craft/commit/203c441)) _(by Chris <chrisbreuer93@gmail.com>)_
- enrich CLAUDE.md with detailed project context from README ([296b7a7](https://github.com/home-lang/craft/commit/296b7a7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- update CLAUDE.md with project context and crosswind details ([8692fd0](https://github.com/home-lang/craft/commit/8692fd0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add proper claude code guidelines ([b32a0fd](https://github.com/home-lang/craft/commit/b32a0fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- use pantry monorepo action instead of pantry-setup ([1513083](https://github.com/home-lang/craft/commit/1513083)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- ignore claude config in linter ([ea90340](https://github.com/home-lang/craft/commit/ea90340)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- add claude code guidelines ([0125d75](https://github.com/home-lang/craft/commit/0125d75)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([77dd226](https://github.com/home-lang/craft/commit/77dd226)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([48e7f91](https://github.com/home-lang/craft/commit/48e7f91)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([bfc25d8](https://github.com/home-lang/craft/commit/bfc25d8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b768617](https://github.com/home-lang/craft/commit/b768617)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8c783ac](https://github.com/home-lang/craft/commit/8c783ac)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([74e5b72](https://github.com/home-lang/craft/commit/74e5b72)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c0319af](https://github.com/home-lang/craft/commit/c0319af)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a21f632](https://github.com/home-lang/craft/commit/a21f632)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1f29236](https://github.com/home-lang/craft/commit/1f29236)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3fc48c1](https://github.com/home-lang/craft/commit/3fc48c1)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e4c927e](https://github.com/home-lang/craft/commit/e4c927e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c5050c5](https://github.com/home-lang/craft/commit/c5050c5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5eb6225](https://github.com/home-lang/craft/commit/5eb6225)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([07efbef](https://github.com/home-lang/craft/commit/07efbef)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5d2c51d](https://github.com/home-lang/craft/commit/5d2c51d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([989962c](https://github.com/home-lang/craft/commit/989962c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2ea6289](https://github.com/home-lang/craft/commit/2ea6289)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2a4ec4c](https://github.com/home-lang/craft/commit/2a4ec4c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([093755a](https://github.com/home-lang/craft/commit/093755a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([89d9cde](https://github.com/home-lang/craft/commit/89d9cde)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([46906c3](https://github.com/home-lang/craft/commit/46906c3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7952d04](https://github.com/home-lang/craft/commit/7952d04)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9e40be7](https://github.com/home-lang/craft/commit/9e40be7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([cc5d461](https://github.com/home-lang/craft/commit/cc5d461)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([fc9d25b](https://github.com/home-lang/craft/commit/fc9d25b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3ed0121](https://github.com/home-lang/craft/commit/3ed0121)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7e67755](https://github.com/home-lang/craft/commit/7e67755)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8532b39](https://github.com/home-lang/craft/commit/8532b39)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e13e475](https://github.com/home-lang/craft/commit/e13e475)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2f232ad](https://github.com/home-lang/craft/commit/2f232ad)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([46b1e42](https://github.com/home-lang/craft/commit/46b1e42)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d4eae10](https://github.com/home-lang/craft/commit/d4eae10)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8663714](https://github.com/home-lang/craft/commit/8663714)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b919a1b](https://github.com/home-lang/craft/commit/b919a1b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c0d8c44](https://github.com/home-lang/craft/commit/c0d8c44)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([28e2d1e](https://github.com/home-lang/craft/commit/28e2d1e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([dd69365](https://github.com/home-lang/craft/commit/dd69365)) _(by Chris <chrisbreuer93@gmail.com>)_
- release v0.0.2 ([bb939be](https://github.com/home-lang/craft/commit/bb939be)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7ab510d](https://github.com/home-lang/craft/commit/7ab510d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5df3c63](https://github.com/home-lang/craft/commit/5df3c63)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8eda328](https://github.com/home-lang/craft/commit/8eda328)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d2f39bd](https://github.com/home-lang/craft/commit/d2f39bd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([567efed](https://github.com/home-lang/craft/commit/567efed)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d3ec5c6](https://github.com/home-lang/craft/commit/d3ec5c6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5bd6875](https://github.com/home-lang/craft/commit/5bd6875)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1570b94](https://github.com/home-lang/craft/commit/1570b94)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([45b7f2f](https://github.com/home-lang/craft/commit/45b7f2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ccc0d26](https://github.com/home-lang/craft/commit/ccc0d26)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a14ea2c](https://github.com/home-lang/craft/commit/a14ea2c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ae94b04](https://github.com/home-lang/craft/commit/ae94b04)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7669cf7](https://github.com/home-lang/craft/commit/7669cf7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0b3136f](https://github.com/home-lang/craft/commit/0b3136f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([10df7fe](https://github.com/home-lang/craft/commit/10df7fe)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4dea542](https://github.com/home-lang/craft/commit/4dea542)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b98ecf4](https://github.com/home-lang/craft/commit/b98ecf4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([883df1c](https://github.com/home-lang/craft/commit/883df1c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4790d89](https://github.com/home-lang/craft/commit/4790d89)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4c2673b](https://github.com/home-lang/craft/commit/4c2673b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e59c9ac](https://github.com/home-lang/craft/commit/e59c9ac)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a64c5](https://github.com/home-lang/craft/commit/36a64c5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c7e973b](https://github.com/home-lang/craft/commit/c7e973b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2395f0b](https://github.com/home-lang/craft/commit/2395f0b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([962c0b7](https://github.com/home-lang/craft/commit/962c0b7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b8f3c7b](https://github.com/home-lang/craft/commit/b8f3c7b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([18b68ef](https://github.com/home-lang/craft/commit/18b68ef)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ec8a79b](https://github.com/home-lang/craft/commit/ec8a79b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([87ace3f](https://github.com/home-lang/craft/commit/87ace3f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f57af45](https://github.com/home-lang/craft/commit/f57af45)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7389903](https://github.com/home-lang/craft/commit/7389903)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1a03aec](https://github.com/home-lang/craft/commit/1a03aec)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8780f08](https://github.com/home-lang/craft/commit/8780f08)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2003c87](https://github.com/home-lang/craft/commit/2003c87)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([822f28e](https://github.com/home-lang/craft/commit/822f28e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0f9109e](https://github.com/home-lang/craft/commit/0f9109e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dedcd7f](https://github.com/home-lang/craft/commit/dedcd7f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a2ed5](https://github.com/home-lang/craft/commit/36a2ed5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([cd836a0](https://github.com/home-lang/craft/commit/cd836a0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f916bca](https://github.com/home-lang/craft/commit/f916bca)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([139e3e4](https://github.com/home-lang/craft/commit/139e3e4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([eabf49f](https://github.com/home-lang/craft/commit/eabf49f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([435dfea](https://github.com/home-lang/craft/commit/435dfea)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b2b126b](https://github.com/home-lang/craft/commit/b2b126b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e82c573](https://github.com/home-lang/craft/commit/e82c573)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d42239c](https://github.com/home-lang/craft/commit/d42239c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([975b092](https://github.com/home-lang/craft/commit/975b092)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b10788c](https://github.com/home-lang/craft/commit/b10788c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5bbb53c](https://github.com/home-lang/craft/commit/5bbb53c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([341831c](https://github.com/home-lang/craft/commit/341831c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7fef9fd](https://github.com/home-lang/craft/commit/7fef9fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4b3a160](https://github.com/home-lang/craft/commit/4b3a160)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a4d3a73](https://github.com/home-lang/craft/commit/a4d3a73)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2c2889a](https://github.com/home-lang/craft/commit/2c2889a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e340937](https://github.com/home-lang/craft/commit/e340937)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([01b733a](https://github.com/home-lang/craft/commit/01b733a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([10f8104](https://github.com/home-lang/craft/commit/10f8104)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3ec38bd](https://github.com/home-lang/craft/commit/3ec38bd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1a4fbd8](https://github.com/home-lang/craft/commit/1a4fbd8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d02f1c9](https://github.com/home-lang/craft/commit/d02f1c9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([84cdd45](https://github.com/home-lang/craft/commit/84cdd45)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9431747](https://github.com/home-lang/craft/commit/9431747)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a7972fc](https://github.com/home-lang/craft/commit/a7972fc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f1ebdec](https://github.com/home-lang/craft/commit/f1ebdec)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([35a6503](https://github.com/home-lang/craft/commit/35a6503)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([74d5a99](https://github.com/home-lang/craft/commit/74d5a99)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([872fdc8](https://github.com/home-lang/craft/commit/872fdc8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([19582a4](https://github.com/home-lang/craft/commit/19582a4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3835a83](https://github.com/home-lang/craft/commit/3835a83)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([867e95f](https://github.com/home-lang/craft/commit/867e95f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([359387c](https://github.com/home-lang/craft/commit/359387c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([839b51b](https://github.com/home-lang/craft/commit/839b51b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f2e171d](https://github.com/home-lang/craft/commit/f2e171d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([92cf21b](https://github.com/home-lang/craft/commit/92cf21b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a0db486](https://github.com/home-lang/craft/commit/a0db486)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f52347e](https://github.com/home-lang/craft/commit/f52347e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([690d3c3](https://github.com/home-lang/craft/commit/690d3c3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e0624a8](https://github.com/home-lang/craft/commit/e0624a8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ecc9aef](https://github.com/home-lang/craft/commit/ecc9aef)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([487f873](https://github.com/home-lang/craft/commit/487f873)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([79ed166](https://github.com/home-lang/craft/commit/79ed166)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5435678](https://github.com/home-lang/craft/commit/5435678)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c211b2f](https://github.com/home-lang/craft/commit/c211b2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ff5f272](https://github.com/home-lang/craft/commit/ff5f272)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([792a81f](https://github.com/home-lang/craft/commit/792a81f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([67fae65](https://github.com/home-lang/craft/commit/67fae65)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a1f00af](https://github.com/home-lang/craft/commit/a1f00af)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c73954c](https://github.com/home-lang/craft/commit/c73954c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([136ee60](https://github.com/home-lang/craft/commit/136ee60)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e73633a](https://github.com/home-lang/craft/commit/e73633a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a468722](https://github.com/home-lang/craft/commit/a468722)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([bf73501](https://github.com/home-lang/craft/commit/bf73501)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([43b12f0](https://github.com/home-lang/craft/commit/43b12f0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1557ab8](https://github.com/home-lang/craft/commit/1557ab8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a064f53](https://github.com/home-lang/craft/commit/a064f53)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ee31b3b](https://github.com/home-lang/craft/commit/ee31b3b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([65e4270](https://github.com/home-lang/craft/commit/65e4270)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0bc0e44](https://github.com/home-lang/craft/commit/0bc0e44)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3356ae2](https://github.com/home-lang/craft/commit/3356ae2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4982ced](https://github.com/home-lang/craft/commit/4982ced)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c0beb8b](https://github.com/home-lang/craft/commit/c0beb8b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dfad951](https://github.com/home-lang/craft/commit/dfad951)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f7b2204](https://github.com/home-lang/craft/commit/f7b2204)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6592531](https://github.com/home-lang/craft/commit/6592531)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([75119f2](https://github.com/home-lang/craft/commit/75119f2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0211031](https://github.com/home-lang/craft/commit/0211031)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([414651c](https://github.com/home-lang/craft/commit/414651c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([080f8e7](https://github.com/home-lang/craft/commit/080f8e7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d4a9c66](https://github.com/home-lang/craft/commit/d4a9c66)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([aa32391](https://github.com/home-lang/craft/commit/aa32391)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([30f6a26](https://github.com/home-lang/craft/commit/30f6a26)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6d7e4de](https://github.com/home-lang/craft/commit/6d7e4de)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([440c9e9](https://github.com/home-lang/craft/commit/440c9e9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([85dec09](https://github.com/home-lang/craft/commit/85dec09)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7434672](https://github.com/home-lang/craft/commit/7434672)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8dc77c2](https://github.com/home-lang/craft/commit/8dc77c2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8eec291](https://github.com/home-lang/craft/commit/8eec291)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([07ab769](https://github.com/home-lang/craft/commit/07ab769)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5bebe22](https://github.com/home-lang/craft/commit/5bebe22)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9864be1](https://github.com/home-lang/craft/commit/9864be1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a19bd0e](https://github.com/home-lang/craft/commit/a19bd0e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7a35a2e](https://github.com/home-lang/craft/commit/7a35a2e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([281e7db](https://github.com/home-lang/craft/commit/281e7db)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([62ffb3c](https://github.com/home-lang/craft/commit/62ffb3c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2e0914f](https://github.com/home-lang/craft/commit/2e0914f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2c0724e](https://github.com/home-lang/craft/commit/2c0724e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([adea193](https://github.com/home-lang/craft/commit/adea193)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d934a44](https://github.com/home-lang/craft/commit/d934a44)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([317657c](https://github.com/home-lang/craft/commit/317657c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([28f58d2](https://github.com/home-lang/craft/commit/28f58d2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d27a015](https://github.com/home-lang/craft/commit/d27a015)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([bcdf4bd](https://github.com/home-lang/craft/commit/bcdf4bd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([731d6dd](https://github.com/home-lang/craft/commit/731d6dd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2d64f0a](https://github.com/home-lang/craft/commit/2d64f0a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b5e43bd](https://github.com/home-lang/craft/commit/b5e43bd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8863f19](https://github.com/home-lang/craft/commit/8863f19)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([fed5734](https://github.com/home-lang/craft/commit/fed5734)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c0b4837](https://github.com/home-lang/craft/commit/c0b4837)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([51806bb](https://github.com/home-lang/craft/commit/51806bb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d192f85](https://github.com/home-lang/craft/commit/d192f85)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b6f529f](https://github.com/home-lang/craft/commit/b6f529f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e164c51](https://github.com/home-lang/craft/commit/e164c51)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9a415b2](https://github.com/home-lang/craft/commit/9a415b2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0fb5d94](https://github.com/home-lang/craft/commit/0fb5d94)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([edd6c30](https://github.com/home-lang/craft/commit/edd6c30)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f191f5c](https://github.com/home-lang/craft/commit/f191f5c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cc95e2f](https://github.com/home-lang/craft/commit/cc95e2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ab6009b](https://github.com/home-lang/craft/commit/ab6009b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9751414](https://github.com/home-lang/craft/commit/9751414)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5582909](https://github.com/home-lang/craft/commit/5582909)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cf6f9a9](https://github.com/home-lang/craft/commit/cf6f9a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([824b8d3](https://github.com/home-lang/craft/commit/824b8d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a56eab5](https://github.com/home-lang/craft/commit/a56eab5)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3eb3fdf](https://github.com/home-lang/craft/commit/3eb3fdf)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([88a6d9f](https://github.com/home-lang/craft/commit/88a6d9f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5e09c35](https://github.com/home-lang/craft/commit/5e09c35)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([539cafc](https://github.com/home-lang/craft/commit/539cafc)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([af72624](https://github.com/home-lang/craft/commit/af72624)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e623334](https://github.com/home-lang/craft/commit/e623334)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([64c00f0](https://github.com/home-lang/craft/commit/64c00f0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6b2c7ac](https://github.com/home-lang/craft/commit/6b2c7ac)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a750334](https://github.com/home-lang/craft/commit/a750334)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6cfa448](https://github.com/home-lang/craft/commit/6cfa448)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3ec7d2f](https://github.com/home-lang/craft/commit/3ec7d2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9793d79](https://github.com/home-lang/craft/commit/9793d79)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f2a1e47](https://github.com/home-lang/craft/commit/f2a1e47)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([76325d0](https://github.com/home-lang/craft/commit/76325d0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c75a4d2](https://github.com/home-lang/craft/commit/c75a4d2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4435785](https://github.com/home-lang/craft/commit/4435785)) _(by Chris <chrisbreuer93@gmail.com>)_
- initial commit ([5086dfc](https://github.com/home-lang/craft/commit/5086dfc)) _(by Chris <chrisbreuer93@gmail.com>)_

### 📄 Miscellaneous

- Merge pull request #7 from home-lang/renovate/oven-sh-setup-bun-2.x ([60d7f0b](https://github.com/home-lang/craft/commit/60d7f0b)) _(by [renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>](https://github.com/renovate[bot]))_ ([#7](https://github.com/home-lang/craft/issues/7), [#7](https://github.com/home-lang/craft/issues/7))
- Create ml.zig ([060e4fd](https://github.com/home-lang/craft/commit/060e4fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _[renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>](https://github.com/renovate[bot])_
- _glennmichael123 <gtorregosa@gmail.com>_

### 🧹 Chores

- wip ([9c9579f](https://github.com/home-lang/craft/commit/9c9579f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- release v0.0.2 ([2deedb6](https://github.com/home-lang/craft/commit/2deedb6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6dc6be5](https://github.com/home-lang/craft/commit/6dc6be5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- release v0.0.2 ([0d72531](https://github.com/home-lang/craft/commit/0d72531)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7ab510d](https://github.com/home-lang/craft/commit/7ab510d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5df3c63](https://github.com/home-lang/craft/commit/5df3c63)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8eda328](https://github.com/home-lang/craft/commit/8eda328)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d2f39bd](https://github.com/home-lang/craft/commit/d2f39bd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([567efed](https://github.com/home-lang/craft/commit/567efed)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d3ec5c6](https://github.com/home-lang/craft/commit/d3ec5c6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5bd6875](https://github.com/home-lang/craft/commit/5bd6875)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1570b94](https://github.com/home-lang/craft/commit/1570b94)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([45b7f2f](https://github.com/home-lang/craft/commit/45b7f2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ccc0d26](https://github.com/home-lang/craft/commit/ccc0d26)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a14ea2c](https://github.com/home-lang/craft/commit/a14ea2c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ae94b04](https://github.com/home-lang/craft/commit/ae94b04)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7669cf7](https://github.com/home-lang/craft/commit/7669cf7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0b3136f](https://github.com/home-lang/craft/commit/0b3136f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([10df7fe](https://github.com/home-lang/craft/commit/10df7fe)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4dea542](https://github.com/home-lang/craft/commit/4dea542)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b98ecf4](https://github.com/home-lang/craft/commit/b98ecf4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([883df1c](https://github.com/home-lang/craft/commit/883df1c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4790d89](https://github.com/home-lang/craft/commit/4790d89)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4c2673b](https://github.com/home-lang/craft/commit/4c2673b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e59c9ac](https://github.com/home-lang/craft/commit/e59c9ac)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a64c5](https://github.com/home-lang/craft/commit/36a64c5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c7e973b](https://github.com/home-lang/craft/commit/c7e973b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2395f0b](https://github.com/home-lang/craft/commit/2395f0b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([962c0b7](https://github.com/home-lang/craft/commit/962c0b7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b8f3c7b](https://github.com/home-lang/craft/commit/b8f3c7b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([18b68ef](https://github.com/home-lang/craft/commit/18b68ef)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ec8a79b](https://github.com/home-lang/craft/commit/ec8a79b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([87ace3f](https://github.com/home-lang/craft/commit/87ace3f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f57af45](https://github.com/home-lang/craft/commit/f57af45)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7389903](https://github.com/home-lang/craft/commit/7389903)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1a03aec](https://github.com/home-lang/craft/commit/1a03aec)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8780f08](https://github.com/home-lang/craft/commit/8780f08)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2003c87](https://github.com/home-lang/craft/commit/2003c87)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([822f28e](https://github.com/home-lang/craft/commit/822f28e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0f9109e](https://github.com/home-lang/craft/commit/0f9109e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dedcd7f](https://github.com/home-lang/craft/commit/dedcd7f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a2ed5](https://github.com/home-lang/craft/commit/36a2ed5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([cd836a0](https://github.com/home-lang/craft/commit/cd836a0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f916bca](https://github.com/home-lang/craft/commit/f916bca)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([139e3e4](https://github.com/home-lang/craft/commit/139e3e4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([eabf49f](https://github.com/home-lang/craft/commit/eabf49f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([435dfea](https://github.com/home-lang/craft/commit/435dfea)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b2b126b](https://github.com/home-lang/craft/commit/b2b126b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e82c573](https://github.com/home-lang/craft/commit/e82c573)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d42239c](https://github.com/home-lang/craft/commit/d42239c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([975b092](https://github.com/home-lang/craft/commit/975b092)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b10788c](https://github.com/home-lang/craft/commit/b10788c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5bbb53c](https://github.com/home-lang/craft/commit/5bbb53c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([341831c](https://github.com/home-lang/craft/commit/341831c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7fef9fd](https://github.com/home-lang/craft/commit/7fef9fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4b3a160](https://github.com/home-lang/craft/commit/4b3a160)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a4d3a73](https://github.com/home-lang/craft/commit/a4d3a73)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2c2889a](https://github.com/home-lang/craft/commit/2c2889a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e340937](https://github.com/home-lang/craft/commit/e340937)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([01b733a](https://github.com/home-lang/craft/commit/01b733a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([10f8104](https://github.com/home-lang/craft/commit/10f8104)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3ec38bd](https://github.com/home-lang/craft/commit/3ec38bd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1a4fbd8](https://github.com/home-lang/craft/commit/1a4fbd8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d02f1c9](https://github.com/home-lang/craft/commit/d02f1c9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([84cdd45](https://github.com/home-lang/craft/commit/84cdd45)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9431747](https://github.com/home-lang/craft/commit/9431747)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a7972fc](https://github.com/home-lang/craft/commit/a7972fc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f1ebdec](https://github.com/home-lang/craft/commit/f1ebdec)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([35a6503](https://github.com/home-lang/craft/commit/35a6503)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([74d5a99](https://github.com/home-lang/craft/commit/74d5a99)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([872fdc8](https://github.com/home-lang/craft/commit/872fdc8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([19582a4](https://github.com/home-lang/craft/commit/19582a4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3835a83](https://github.com/home-lang/craft/commit/3835a83)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([867e95f](https://github.com/home-lang/craft/commit/867e95f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([359387c](https://github.com/home-lang/craft/commit/359387c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([839b51b](https://github.com/home-lang/craft/commit/839b51b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f2e171d](https://github.com/home-lang/craft/commit/f2e171d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([92cf21b](https://github.com/home-lang/craft/commit/92cf21b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a0db486](https://github.com/home-lang/craft/commit/a0db486)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f52347e](https://github.com/home-lang/craft/commit/f52347e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([690d3c3](https://github.com/home-lang/craft/commit/690d3c3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e0624a8](https://github.com/home-lang/craft/commit/e0624a8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ecc9aef](https://github.com/home-lang/craft/commit/ecc9aef)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([487f873](https://github.com/home-lang/craft/commit/487f873)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([79ed166](https://github.com/home-lang/craft/commit/79ed166)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5435678](https://github.com/home-lang/craft/commit/5435678)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c211b2f](https://github.com/home-lang/craft/commit/c211b2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ff5f272](https://github.com/home-lang/craft/commit/ff5f272)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([792a81f](https://github.com/home-lang/craft/commit/792a81f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([67fae65](https://github.com/home-lang/craft/commit/67fae65)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a1f00af](https://github.com/home-lang/craft/commit/a1f00af)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c73954c](https://github.com/home-lang/craft/commit/c73954c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([136ee60](https://github.com/home-lang/craft/commit/136ee60)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e73633a](https://github.com/home-lang/craft/commit/e73633a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a468722](https://github.com/home-lang/craft/commit/a468722)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([bf73501](https://github.com/home-lang/craft/commit/bf73501)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([43b12f0](https://github.com/home-lang/craft/commit/43b12f0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1557ab8](https://github.com/home-lang/craft/commit/1557ab8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a064f53](https://github.com/home-lang/craft/commit/a064f53)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ee31b3b](https://github.com/home-lang/craft/commit/ee31b3b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([65e4270](https://github.com/home-lang/craft/commit/65e4270)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0bc0e44](https://github.com/home-lang/craft/commit/0bc0e44)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3356ae2](https://github.com/home-lang/craft/commit/3356ae2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4982ced](https://github.com/home-lang/craft/commit/4982ced)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c0beb8b](https://github.com/home-lang/craft/commit/c0beb8b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dfad951](https://github.com/home-lang/craft/commit/dfad951)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f7b2204](https://github.com/home-lang/craft/commit/f7b2204)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6592531](https://github.com/home-lang/craft/commit/6592531)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([75119f2](https://github.com/home-lang/craft/commit/75119f2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0211031](https://github.com/home-lang/craft/commit/0211031)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([414651c](https://github.com/home-lang/craft/commit/414651c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([080f8e7](https://github.com/home-lang/craft/commit/080f8e7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d4a9c66](https://github.com/home-lang/craft/commit/d4a9c66)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([aa32391](https://github.com/home-lang/craft/commit/aa32391)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([30f6a26](https://github.com/home-lang/craft/commit/30f6a26)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6d7e4de](https://github.com/home-lang/craft/commit/6d7e4de)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([440c9e9](https://github.com/home-lang/craft/commit/440c9e9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([85dec09](https://github.com/home-lang/craft/commit/85dec09)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7434672](https://github.com/home-lang/craft/commit/7434672)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8dc77c2](https://github.com/home-lang/craft/commit/8dc77c2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8eec291](https://github.com/home-lang/craft/commit/8eec291)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([07ab769](https://github.com/home-lang/craft/commit/07ab769)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5bebe22](https://github.com/home-lang/craft/commit/5bebe22)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9864be1](https://github.com/home-lang/craft/commit/9864be1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a19bd0e](https://github.com/home-lang/craft/commit/a19bd0e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7a35a2e](https://github.com/home-lang/craft/commit/7a35a2e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([281e7db](https://github.com/home-lang/craft/commit/281e7db)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([62ffb3c](https://github.com/home-lang/craft/commit/62ffb3c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2e0914f](https://github.com/home-lang/craft/commit/2e0914f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2c0724e](https://github.com/home-lang/craft/commit/2c0724e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([adea193](https://github.com/home-lang/craft/commit/adea193)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d934a44](https://github.com/home-lang/craft/commit/d934a44)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([317657c](https://github.com/home-lang/craft/commit/317657c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([28f58d2](https://github.com/home-lang/craft/commit/28f58d2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d27a015](https://github.com/home-lang/craft/commit/d27a015)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([bcdf4bd](https://github.com/home-lang/craft/commit/bcdf4bd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([731d6dd](https://github.com/home-lang/craft/commit/731d6dd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2d64f0a](https://github.com/home-lang/craft/commit/2d64f0a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b5e43bd](https://github.com/home-lang/craft/commit/b5e43bd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8863f19](https://github.com/home-lang/craft/commit/8863f19)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([fed5734](https://github.com/home-lang/craft/commit/fed5734)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c0b4837](https://github.com/home-lang/craft/commit/c0b4837)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([51806bb](https://github.com/home-lang/craft/commit/51806bb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d192f85](https://github.com/home-lang/craft/commit/d192f85)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b6f529f](https://github.com/home-lang/craft/commit/b6f529f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e164c51](https://github.com/home-lang/craft/commit/e164c51)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9a415b2](https://github.com/home-lang/craft/commit/9a415b2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0fb5d94](https://github.com/home-lang/craft/commit/0fb5d94)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([edd6c30](https://github.com/home-lang/craft/commit/edd6c30)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f191f5c](https://github.com/home-lang/craft/commit/f191f5c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cc95e2f](https://github.com/home-lang/craft/commit/cc95e2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ab6009b](https://github.com/home-lang/craft/commit/ab6009b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9751414](https://github.com/home-lang/craft/commit/9751414)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5582909](https://github.com/home-lang/craft/commit/5582909)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cf6f9a9](https://github.com/home-lang/craft/commit/cf6f9a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([824b8d3](https://github.com/home-lang/craft/commit/824b8d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a56eab5](https://github.com/home-lang/craft/commit/a56eab5)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3eb3fdf](https://github.com/home-lang/craft/commit/3eb3fdf)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([88a6d9f](https://github.com/home-lang/craft/commit/88a6d9f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5e09c35](https://github.com/home-lang/craft/commit/5e09c35)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([539cafc](https://github.com/home-lang/craft/commit/539cafc)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([af72624](https://github.com/home-lang/craft/commit/af72624)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e623334](https://github.com/home-lang/craft/commit/e623334)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([64c00f0](https://github.com/home-lang/craft/commit/64c00f0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6b2c7ac](https://github.com/home-lang/craft/commit/6b2c7ac)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a750334](https://github.com/home-lang/craft/commit/a750334)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6cfa448](https://github.com/home-lang/craft/commit/6cfa448)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3ec7d2f](https://github.com/home-lang/craft/commit/3ec7d2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9793d79](https://github.com/home-lang/craft/commit/9793d79)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f2a1e47](https://github.com/home-lang/craft/commit/f2a1e47)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([76325d0](https://github.com/home-lang/craft/commit/76325d0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c75a4d2](https://github.com/home-lang/craft/commit/c75a4d2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4435785](https://github.com/home-lang/craft/commit/4435785)) _(by Chris <chrisbreuer93@gmail.com>)_
- initial commit ([5086dfc](https://github.com/home-lang/craft/commit/5086dfc)) _(by Chris <chrisbreuer93@gmail.com>)_

### 📄 Miscellaneous

- Revert "chore: release v0.0.2" ([de610b9](https://github.com/home-lang/craft/commit/de610b9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- Create ml.zig ([060e4fd](https://github.com/home-lang/craft/commit/060e4fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

### 🧹 Chores

- wip ([6dc6be5](https://github.com/home-lang/craft/commit/6dc6be5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- release v0.0.2 ([0d72531](https://github.com/home-lang/craft/commit/0d72531)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7ab510d](https://github.com/home-lang/craft/commit/7ab510d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5df3c63](https://github.com/home-lang/craft/commit/5df3c63)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8eda328](https://github.com/home-lang/craft/commit/8eda328)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d2f39bd](https://github.com/home-lang/craft/commit/d2f39bd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([567efed](https://github.com/home-lang/craft/commit/567efed)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d3ec5c6](https://github.com/home-lang/craft/commit/d3ec5c6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5bd6875](https://github.com/home-lang/craft/commit/5bd6875)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1570b94](https://github.com/home-lang/craft/commit/1570b94)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([45b7f2f](https://github.com/home-lang/craft/commit/45b7f2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ccc0d26](https://github.com/home-lang/craft/commit/ccc0d26)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a14ea2c](https://github.com/home-lang/craft/commit/a14ea2c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ae94b04](https://github.com/home-lang/craft/commit/ae94b04)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7669cf7](https://github.com/home-lang/craft/commit/7669cf7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0b3136f](https://github.com/home-lang/craft/commit/0b3136f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([10df7fe](https://github.com/home-lang/craft/commit/10df7fe)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4dea542](https://github.com/home-lang/craft/commit/4dea542)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b98ecf4](https://github.com/home-lang/craft/commit/b98ecf4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([883df1c](https://github.com/home-lang/craft/commit/883df1c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4790d89](https://github.com/home-lang/craft/commit/4790d89)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4c2673b](https://github.com/home-lang/craft/commit/4c2673b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e59c9ac](https://github.com/home-lang/craft/commit/e59c9ac)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a64c5](https://github.com/home-lang/craft/commit/36a64c5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c7e973b](https://github.com/home-lang/craft/commit/c7e973b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2395f0b](https://github.com/home-lang/craft/commit/2395f0b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([962c0b7](https://github.com/home-lang/craft/commit/962c0b7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b8f3c7b](https://github.com/home-lang/craft/commit/b8f3c7b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([18b68ef](https://github.com/home-lang/craft/commit/18b68ef)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ec8a79b](https://github.com/home-lang/craft/commit/ec8a79b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([87ace3f](https://github.com/home-lang/craft/commit/87ace3f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f57af45](https://github.com/home-lang/craft/commit/f57af45)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7389903](https://github.com/home-lang/craft/commit/7389903)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1a03aec](https://github.com/home-lang/craft/commit/1a03aec)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8780f08](https://github.com/home-lang/craft/commit/8780f08)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2003c87](https://github.com/home-lang/craft/commit/2003c87)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([822f28e](https://github.com/home-lang/craft/commit/822f28e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0f9109e](https://github.com/home-lang/craft/commit/0f9109e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dedcd7f](https://github.com/home-lang/craft/commit/dedcd7f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a2ed5](https://github.com/home-lang/craft/commit/36a2ed5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([cd836a0](https://github.com/home-lang/craft/commit/cd836a0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f916bca](https://github.com/home-lang/craft/commit/f916bca)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([139e3e4](https://github.com/home-lang/craft/commit/139e3e4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([eabf49f](https://github.com/home-lang/craft/commit/eabf49f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([435dfea](https://github.com/home-lang/craft/commit/435dfea)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b2b126b](https://github.com/home-lang/craft/commit/b2b126b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e82c573](https://github.com/home-lang/craft/commit/e82c573)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d42239c](https://github.com/home-lang/craft/commit/d42239c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([975b092](https://github.com/home-lang/craft/commit/975b092)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b10788c](https://github.com/home-lang/craft/commit/b10788c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5bbb53c](https://github.com/home-lang/craft/commit/5bbb53c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([341831c](https://github.com/home-lang/craft/commit/341831c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7fef9fd](https://github.com/home-lang/craft/commit/7fef9fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4b3a160](https://github.com/home-lang/craft/commit/4b3a160)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a4d3a73](https://github.com/home-lang/craft/commit/a4d3a73)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2c2889a](https://github.com/home-lang/craft/commit/2c2889a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e340937](https://github.com/home-lang/craft/commit/e340937)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([01b733a](https://github.com/home-lang/craft/commit/01b733a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([10f8104](https://github.com/home-lang/craft/commit/10f8104)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3ec38bd](https://github.com/home-lang/craft/commit/3ec38bd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1a4fbd8](https://github.com/home-lang/craft/commit/1a4fbd8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d02f1c9](https://github.com/home-lang/craft/commit/d02f1c9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([84cdd45](https://github.com/home-lang/craft/commit/84cdd45)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9431747](https://github.com/home-lang/craft/commit/9431747)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a7972fc](https://github.com/home-lang/craft/commit/a7972fc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f1ebdec](https://github.com/home-lang/craft/commit/f1ebdec)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([35a6503](https://github.com/home-lang/craft/commit/35a6503)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([74d5a99](https://github.com/home-lang/craft/commit/74d5a99)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([872fdc8](https://github.com/home-lang/craft/commit/872fdc8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([19582a4](https://github.com/home-lang/craft/commit/19582a4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3835a83](https://github.com/home-lang/craft/commit/3835a83)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([867e95f](https://github.com/home-lang/craft/commit/867e95f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([359387c](https://github.com/home-lang/craft/commit/359387c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([839b51b](https://github.com/home-lang/craft/commit/839b51b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f2e171d](https://github.com/home-lang/craft/commit/f2e171d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([92cf21b](https://github.com/home-lang/craft/commit/92cf21b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a0db486](https://github.com/home-lang/craft/commit/a0db486)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f52347e](https://github.com/home-lang/craft/commit/f52347e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([690d3c3](https://github.com/home-lang/craft/commit/690d3c3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e0624a8](https://github.com/home-lang/craft/commit/e0624a8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ecc9aef](https://github.com/home-lang/craft/commit/ecc9aef)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([487f873](https://github.com/home-lang/craft/commit/487f873)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([79ed166](https://github.com/home-lang/craft/commit/79ed166)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5435678](https://github.com/home-lang/craft/commit/5435678)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c211b2f](https://github.com/home-lang/craft/commit/c211b2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ff5f272](https://github.com/home-lang/craft/commit/ff5f272)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([792a81f](https://github.com/home-lang/craft/commit/792a81f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([67fae65](https://github.com/home-lang/craft/commit/67fae65)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a1f00af](https://github.com/home-lang/craft/commit/a1f00af)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c73954c](https://github.com/home-lang/craft/commit/c73954c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([136ee60](https://github.com/home-lang/craft/commit/136ee60)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e73633a](https://github.com/home-lang/craft/commit/e73633a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a468722](https://github.com/home-lang/craft/commit/a468722)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([bf73501](https://github.com/home-lang/craft/commit/bf73501)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([43b12f0](https://github.com/home-lang/craft/commit/43b12f0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1557ab8](https://github.com/home-lang/craft/commit/1557ab8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a064f53](https://github.com/home-lang/craft/commit/a064f53)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ee31b3b](https://github.com/home-lang/craft/commit/ee31b3b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([65e4270](https://github.com/home-lang/craft/commit/65e4270)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0bc0e44](https://github.com/home-lang/craft/commit/0bc0e44)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3356ae2](https://github.com/home-lang/craft/commit/3356ae2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4982ced](https://github.com/home-lang/craft/commit/4982ced)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c0beb8b](https://github.com/home-lang/craft/commit/c0beb8b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dfad951](https://github.com/home-lang/craft/commit/dfad951)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f7b2204](https://github.com/home-lang/craft/commit/f7b2204)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6592531](https://github.com/home-lang/craft/commit/6592531)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([75119f2](https://github.com/home-lang/craft/commit/75119f2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0211031](https://github.com/home-lang/craft/commit/0211031)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([414651c](https://github.com/home-lang/craft/commit/414651c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([080f8e7](https://github.com/home-lang/craft/commit/080f8e7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d4a9c66](https://github.com/home-lang/craft/commit/d4a9c66)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([aa32391](https://github.com/home-lang/craft/commit/aa32391)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([30f6a26](https://github.com/home-lang/craft/commit/30f6a26)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6d7e4de](https://github.com/home-lang/craft/commit/6d7e4de)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([440c9e9](https://github.com/home-lang/craft/commit/440c9e9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([85dec09](https://github.com/home-lang/craft/commit/85dec09)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7434672](https://github.com/home-lang/craft/commit/7434672)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8dc77c2](https://github.com/home-lang/craft/commit/8dc77c2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8eec291](https://github.com/home-lang/craft/commit/8eec291)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([07ab769](https://github.com/home-lang/craft/commit/07ab769)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5bebe22](https://github.com/home-lang/craft/commit/5bebe22)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9864be1](https://github.com/home-lang/craft/commit/9864be1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a19bd0e](https://github.com/home-lang/craft/commit/a19bd0e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7a35a2e](https://github.com/home-lang/craft/commit/7a35a2e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([281e7db](https://github.com/home-lang/craft/commit/281e7db)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([62ffb3c](https://github.com/home-lang/craft/commit/62ffb3c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2e0914f](https://github.com/home-lang/craft/commit/2e0914f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2c0724e](https://github.com/home-lang/craft/commit/2c0724e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([adea193](https://github.com/home-lang/craft/commit/adea193)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d934a44](https://github.com/home-lang/craft/commit/d934a44)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([317657c](https://github.com/home-lang/craft/commit/317657c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([28f58d2](https://github.com/home-lang/craft/commit/28f58d2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d27a015](https://github.com/home-lang/craft/commit/d27a015)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([bcdf4bd](https://github.com/home-lang/craft/commit/bcdf4bd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([731d6dd](https://github.com/home-lang/craft/commit/731d6dd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2d64f0a](https://github.com/home-lang/craft/commit/2d64f0a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b5e43bd](https://github.com/home-lang/craft/commit/b5e43bd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8863f19](https://github.com/home-lang/craft/commit/8863f19)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([fed5734](https://github.com/home-lang/craft/commit/fed5734)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c0b4837](https://github.com/home-lang/craft/commit/c0b4837)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([51806bb](https://github.com/home-lang/craft/commit/51806bb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d192f85](https://github.com/home-lang/craft/commit/d192f85)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b6f529f](https://github.com/home-lang/craft/commit/b6f529f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e164c51](https://github.com/home-lang/craft/commit/e164c51)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9a415b2](https://github.com/home-lang/craft/commit/9a415b2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0fb5d94](https://github.com/home-lang/craft/commit/0fb5d94)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([edd6c30](https://github.com/home-lang/craft/commit/edd6c30)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f191f5c](https://github.com/home-lang/craft/commit/f191f5c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cc95e2f](https://github.com/home-lang/craft/commit/cc95e2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ab6009b](https://github.com/home-lang/craft/commit/ab6009b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9751414](https://github.com/home-lang/craft/commit/9751414)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5582909](https://github.com/home-lang/craft/commit/5582909)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cf6f9a9](https://github.com/home-lang/craft/commit/cf6f9a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([824b8d3](https://github.com/home-lang/craft/commit/824b8d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a56eab5](https://github.com/home-lang/craft/commit/a56eab5)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3eb3fdf](https://github.com/home-lang/craft/commit/3eb3fdf)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([88a6d9f](https://github.com/home-lang/craft/commit/88a6d9f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5e09c35](https://github.com/home-lang/craft/commit/5e09c35)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([539cafc](https://github.com/home-lang/craft/commit/539cafc)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([af72624](https://github.com/home-lang/craft/commit/af72624)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e623334](https://github.com/home-lang/craft/commit/e623334)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([64c00f0](https://github.com/home-lang/craft/commit/64c00f0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6b2c7ac](https://github.com/home-lang/craft/commit/6b2c7ac)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a750334](https://github.com/home-lang/craft/commit/a750334)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6cfa448](https://github.com/home-lang/craft/commit/6cfa448)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3ec7d2f](https://github.com/home-lang/craft/commit/3ec7d2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9793d79](https://github.com/home-lang/craft/commit/9793d79)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f2a1e47](https://github.com/home-lang/craft/commit/f2a1e47)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([76325d0](https://github.com/home-lang/craft/commit/76325d0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c75a4d2](https://github.com/home-lang/craft/commit/c75a4d2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4435785](https://github.com/home-lang/craft/commit/4435785)) _(by Chris <chrisbreuer93@gmail.com>)_
- initial commit ([5086dfc](https://github.com/home-lang/craft/commit/5086dfc)) _(by Chris <chrisbreuer93@gmail.com>)_

### 📄 Miscellaneous

- Revert "chore: release v0.0.2" ([de610b9](https://github.com/home-lang/craft/commit/de610b9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- Create ml.zig ([060e4fd](https://github.com/home-lang/craft/commit/060e4fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

### 🧹 Chores

- wip ([6dc6be5](https://github.com/home-lang/craft/commit/6dc6be5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- release v0.0.2 ([0d72531](https://github.com/home-lang/craft/commit/0d72531)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7ab510d](https://github.com/home-lang/craft/commit/7ab510d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5df3c63](https://github.com/home-lang/craft/commit/5df3c63)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8eda328](https://github.com/home-lang/craft/commit/8eda328)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d2f39bd](https://github.com/home-lang/craft/commit/d2f39bd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([567efed](https://github.com/home-lang/craft/commit/567efed)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d3ec5c6](https://github.com/home-lang/craft/commit/d3ec5c6)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5bd6875](https://github.com/home-lang/craft/commit/5bd6875)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1570b94](https://github.com/home-lang/craft/commit/1570b94)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([45b7f2f](https://github.com/home-lang/craft/commit/45b7f2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ccc0d26](https://github.com/home-lang/craft/commit/ccc0d26)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a14ea2c](https://github.com/home-lang/craft/commit/a14ea2c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ae94b04](https://github.com/home-lang/craft/commit/ae94b04)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7669cf7](https://github.com/home-lang/craft/commit/7669cf7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0b3136f](https://github.com/home-lang/craft/commit/0b3136f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([10df7fe](https://github.com/home-lang/craft/commit/10df7fe)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4dea542](https://github.com/home-lang/craft/commit/4dea542)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b98ecf4](https://github.com/home-lang/craft/commit/b98ecf4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([883df1c](https://github.com/home-lang/craft/commit/883df1c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4790d89](https://github.com/home-lang/craft/commit/4790d89)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4c2673b](https://github.com/home-lang/craft/commit/4c2673b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e59c9ac](https://github.com/home-lang/craft/commit/e59c9ac)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a64c5](https://github.com/home-lang/craft/commit/36a64c5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c7e973b](https://github.com/home-lang/craft/commit/c7e973b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2395f0b](https://github.com/home-lang/craft/commit/2395f0b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([962c0b7](https://github.com/home-lang/craft/commit/962c0b7)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b8f3c7b](https://github.com/home-lang/craft/commit/b8f3c7b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([18b68ef](https://github.com/home-lang/craft/commit/18b68ef)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ec8a79b](https://github.com/home-lang/craft/commit/ec8a79b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([87ace3f](https://github.com/home-lang/craft/commit/87ace3f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f57af45](https://github.com/home-lang/craft/commit/f57af45)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7389903](https://github.com/home-lang/craft/commit/7389903)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([1a03aec](https://github.com/home-lang/craft/commit/1a03aec)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([8780f08](https://github.com/home-lang/craft/commit/8780f08)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2003c87](https://github.com/home-lang/craft/commit/2003c87)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([822f28e](https://github.com/home-lang/craft/commit/822f28e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0f9109e](https://github.com/home-lang/craft/commit/0f9109e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dedcd7f](https://github.com/home-lang/craft/commit/dedcd7f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([36a2ed5](https://github.com/home-lang/craft/commit/36a2ed5)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([cd836a0](https://github.com/home-lang/craft/commit/cd836a0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f916bca](https://github.com/home-lang/craft/commit/f916bca)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([139e3e4](https://github.com/home-lang/craft/commit/139e3e4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([eabf49f](https://github.com/home-lang/craft/commit/eabf49f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([435dfea](https://github.com/home-lang/craft/commit/435dfea)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b2b126b](https://github.com/home-lang/craft/commit/b2b126b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e82c573](https://github.com/home-lang/craft/commit/e82c573)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d42239c](https://github.com/home-lang/craft/commit/d42239c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([975b092](https://github.com/home-lang/craft/commit/975b092)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([b10788c](https://github.com/home-lang/craft/commit/b10788c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([5bbb53c](https://github.com/home-lang/craft/commit/5bbb53c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([341831c](https://github.com/home-lang/craft/commit/341831c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([7fef9fd](https://github.com/home-lang/craft/commit/7fef9fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4b3a160](https://github.com/home-lang/craft/commit/4b3a160)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a4d3a73](https://github.com/home-lang/craft/commit/a4d3a73)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([2c2889a](https://github.com/home-lang/craft/commit/2c2889a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e340937](https://github.com/home-lang/craft/commit/e340937)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([01b733a](https://github.com/home-lang/craft/commit/01b733a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([10f8104](https://github.com/home-lang/craft/commit/10f8104)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3ec38bd](https://github.com/home-lang/craft/commit/3ec38bd)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1a4fbd8](https://github.com/home-lang/craft/commit/1a4fbd8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([d02f1c9](https://github.com/home-lang/craft/commit/d02f1c9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([84cdd45](https://github.com/home-lang/craft/commit/84cdd45)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([9431747](https://github.com/home-lang/craft/commit/9431747)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a7972fc](https://github.com/home-lang/craft/commit/a7972fc)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f1ebdec](https://github.com/home-lang/craft/commit/f1ebdec)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([35a6503](https://github.com/home-lang/craft/commit/35a6503)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([74d5a99](https://github.com/home-lang/craft/commit/74d5a99)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([872fdc8](https://github.com/home-lang/craft/commit/872fdc8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([19582a4](https://github.com/home-lang/craft/commit/19582a4)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3835a83](https://github.com/home-lang/craft/commit/3835a83)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([867e95f](https://github.com/home-lang/craft/commit/867e95f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([359387c](https://github.com/home-lang/craft/commit/359387c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([839b51b](https://github.com/home-lang/craft/commit/839b51b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f2e171d](https://github.com/home-lang/craft/commit/f2e171d)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([92cf21b](https://github.com/home-lang/craft/commit/92cf21b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a0db486](https://github.com/home-lang/craft/commit/a0db486)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f52347e](https://github.com/home-lang/craft/commit/f52347e)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([690d3c3](https://github.com/home-lang/craft/commit/690d3c3)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e0624a8](https://github.com/home-lang/craft/commit/e0624a8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ecc9aef](https://github.com/home-lang/craft/commit/ecc9aef)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([487f873](https://github.com/home-lang/craft/commit/487f873)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([79ed166](https://github.com/home-lang/craft/commit/79ed166)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5435678](https://github.com/home-lang/craft/commit/5435678)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c211b2f](https://github.com/home-lang/craft/commit/c211b2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ff5f272](https://github.com/home-lang/craft/commit/ff5f272)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([792a81f](https://github.com/home-lang/craft/commit/792a81f)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([67fae65](https://github.com/home-lang/craft/commit/67fae65)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a1f00af](https://github.com/home-lang/craft/commit/a1f00af)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c73954c](https://github.com/home-lang/craft/commit/c73954c)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([136ee60](https://github.com/home-lang/craft/commit/136ee60)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([e73633a](https://github.com/home-lang/craft/commit/e73633a)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a468722](https://github.com/home-lang/craft/commit/a468722)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([bf73501](https://github.com/home-lang/craft/commit/bf73501)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([43b12f0](https://github.com/home-lang/craft/commit/43b12f0)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([1557ab8](https://github.com/home-lang/craft/commit/1557ab8)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([a064f53](https://github.com/home-lang/craft/commit/a064f53)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([ee31b3b](https://github.com/home-lang/craft/commit/ee31b3b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([65e4270](https://github.com/home-lang/craft/commit/65e4270)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([0bc0e44](https://github.com/home-lang/craft/commit/0bc0e44)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([3356ae2](https://github.com/home-lang/craft/commit/3356ae2)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([4982ced](https://github.com/home-lang/craft/commit/4982ced)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([c0beb8b](https://github.com/home-lang/craft/commit/c0beb8b)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([dfad951](https://github.com/home-lang/craft/commit/dfad951)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([f7b2204](https://github.com/home-lang/craft/commit/f7b2204)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- wip ([6592531](https://github.com/home-lang/craft/commit/6592531)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([75119f2](https://github.com/home-lang/craft/commit/75119f2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0211031](https://github.com/home-lang/craft/commit/0211031)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([414651c](https://github.com/home-lang/craft/commit/414651c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([080f8e7](https://github.com/home-lang/craft/commit/080f8e7)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d4a9c66](https://github.com/home-lang/craft/commit/d4a9c66)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([aa32391](https://github.com/home-lang/craft/commit/aa32391)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([30f6a26](https://github.com/home-lang/craft/commit/30f6a26)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6d7e4de](https://github.com/home-lang/craft/commit/6d7e4de)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([440c9e9](https://github.com/home-lang/craft/commit/440c9e9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([85dec09](https://github.com/home-lang/craft/commit/85dec09)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7434672](https://github.com/home-lang/craft/commit/7434672)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8dc77c2](https://github.com/home-lang/craft/commit/8dc77c2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8eec291](https://github.com/home-lang/craft/commit/8eec291)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([07ab769](https://github.com/home-lang/craft/commit/07ab769)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5bebe22](https://github.com/home-lang/craft/commit/5bebe22)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9864be1](https://github.com/home-lang/craft/commit/9864be1)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a19bd0e](https://github.com/home-lang/craft/commit/a19bd0e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([7a35a2e](https://github.com/home-lang/craft/commit/7a35a2e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([281e7db](https://github.com/home-lang/craft/commit/281e7db)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([62ffb3c](https://github.com/home-lang/craft/commit/62ffb3c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2e0914f](https://github.com/home-lang/craft/commit/2e0914f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2c0724e](https://github.com/home-lang/craft/commit/2c0724e)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([adea193](https://github.com/home-lang/craft/commit/adea193)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d934a44](https://github.com/home-lang/craft/commit/d934a44)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([317657c](https://github.com/home-lang/craft/commit/317657c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([28f58d2](https://github.com/home-lang/craft/commit/28f58d2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d27a015](https://github.com/home-lang/craft/commit/d27a015)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([bcdf4bd](https://github.com/home-lang/craft/commit/bcdf4bd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([731d6dd](https://github.com/home-lang/craft/commit/731d6dd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([2d64f0a](https://github.com/home-lang/craft/commit/2d64f0a)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b5e43bd](https://github.com/home-lang/craft/commit/b5e43bd)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([8863f19](https://github.com/home-lang/craft/commit/8863f19)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([fed5734](https://github.com/home-lang/craft/commit/fed5734)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c0b4837](https://github.com/home-lang/craft/commit/c0b4837)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([51806bb](https://github.com/home-lang/craft/commit/51806bb)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([d192f85](https://github.com/home-lang/craft/commit/d192f85)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([b6f529f](https://github.com/home-lang/craft/commit/b6f529f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e164c51](https://github.com/home-lang/craft/commit/e164c51)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9a415b2](https://github.com/home-lang/craft/commit/9a415b2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([0fb5d94](https://github.com/home-lang/craft/commit/0fb5d94)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([edd6c30](https://github.com/home-lang/craft/commit/edd6c30)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f191f5c](https://github.com/home-lang/craft/commit/f191f5c)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cc95e2f](https://github.com/home-lang/craft/commit/cc95e2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([ab6009b](https://github.com/home-lang/craft/commit/ab6009b)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9751414](https://github.com/home-lang/craft/commit/9751414)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5582909](https://github.com/home-lang/craft/commit/5582909)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([cf6f9a9](https://github.com/home-lang/craft/commit/cf6f9a9)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([824b8d3](https://github.com/home-lang/craft/commit/824b8d3)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a56eab5](https://github.com/home-lang/craft/commit/a56eab5)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3eb3fdf](https://github.com/home-lang/craft/commit/3eb3fdf)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([88a6d9f](https://github.com/home-lang/craft/commit/88a6d9f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([5e09c35](https://github.com/home-lang/craft/commit/5e09c35)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([539cafc](https://github.com/home-lang/craft/commit/539cafc)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([af72624](https://github.com/home-lang/craft/commit/af72624)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([e623334](https://github.com/home-lang/craft/commit/e623334)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([64c00f0](https://github.com/home-lang/craft/commit/64c00f0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6b2c7ac](https://github.com/home-lang/craft/commit/6b2c7ac)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([a750334](https://github.com/home-lang/craft/commit/a750334)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([6cfa448](https://github.com/home-lang/craft/commit/6cfa448)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([3ec7d2f](https://github.com/home-lang/craft/commit/3ec7d2f)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([9793d79](https://github.com/home-lang/craft/commit/9793d79)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([f2a1e47](https://github.com/home-lang/craft/commit/f2a1e47)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([76325d0](https://github.com/home-lang/craft/commit/76325d0)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([c75a4d2](https://github.com/home-lang/craft/commit/c75a4d2)) _(by Chris <chrisbreuer93@gmail.com>)_
- wip ([4435785](https://github.com/home-lang/craft/commit/4435785)) _(by Chris <chrisbreuer93@gmail.com>)_
- initial commit ([5086dfc](https://github.com/home-lang/craft/commit/5086dfc)) _(by Chris <chrisbreuer93@gmail.com>)_

### 📄 Miscellaneous

- Revert "chore: release v0.0.2" ([de610b9](https://github.com/home-lang/craft/commit/de610b9)) _(by glennmichael123 <gtorregosa@gmail.com>)_
- Create ml.zig ([060e4fd](https://github.com/home-lang/craft/commit/060e4fd)) _(by glennmichael123 <gtorregosa@gmail.com>)_

### Contributors

- _Chris <chrisbreuer93@gmail.com>_
- _glennmichael123 <gtorregosa@gmail.com>_

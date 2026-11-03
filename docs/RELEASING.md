# Releasing Craft

`bun run release:patch` bumps the public workspace and Zig versions, commits the
changelog, creates a tag, and pushes both. Run it only from a clean `main` that
matches `origin/main`, after the SDK, package, lint, and type checks are green.
Run `bun run test:release` too; it exercises the release gates and performs an
isolated bumpx commit/tag rehearsal without publishing or pushing a tag.
CI runs the SDK suite on both Linux and macOS for ordinary pushes and pull
requests to `main`. The dedicated `TypeScript SDK (macOS)` job exercises Darwin-only
DMG and App Store packaging tests before a version is tagged, independently of
Mobile E2E's path filters. Both SDK jobs gate commit publication and source
acceptance; a green Linux run alone does not validate macOS packaging.
Before tagging, the CI installed-app jobs must be green: they launch real PKG,
DEB, and MSI installs and exercise child-window event routing from each package.
They also read addressed native state from the main, child, and adopted windows.
Each installed-app smoke also checks creator teardown and adoption of a
surviving, unparented grandchild. The PKG case explicitly destroys the retained
macOS creator after close; DEB and MSI close already releases it.
The release command registers the workspace and Zig release manifests with
Bumpx so their versions update and roll back together. The release hook
generates the next changelog section before that commit,
deduplicates repeated issue references, and links the previous and new tags.
Do not run the hook again after it has written the section.

The tag starts [Releaser](../.github/workflows/release.yml); pushing a tag is
the publication trigger, not proof that the release finished.

Both release and CI setup pin Pantry CLI 0.11.120 as well as the Pantry action
revision; leaving the CLI at `latest` would add a GitHub API lookup before the
build can even start.
The Windows Vulkan acceptance job declares Bun, Zig, and Git explicitly, just
like the ABI matrix. The workspace manifest does not install managed Git;
using only the default workspace install leaves `managed-git.ts --verify`
without a provider. Keep the provider verification before driver provisioning
and scene tests; the runner's preinstalled Git is not an acceptable substitute.


## Publication gates

The macOS and Linux jobs build, sign where credentials exist, scan, and upload
their platform archives to a **draft** GitHub release. The Linux job also
provides the Windows cross-build. A failed job may leave a private draft, but
cannot make a partial GitHub release or Zig registry version public.

After both native jobs succeed, the workflow checks the four required archives,
publishes and verifies a SHA-256 manifest, runs downloaded binaries on both
macOS architectures plus Linux and Windows, and attaches and verifies all three
SBOMs. A final job
downloads the staged files again, checks the draft and manifest, and only then
publishes the GitHub release. Only then does a separate job publish the Zig
package to pantry and notify the registry to index the complete release.
Discord is notified only after the complete release is public, never from an
individual platform's staging job.
The npm preparation job builds and scans the exact public JavaScript archives.
The npm publication job waits for the verified GitHub release to become public
and publishes those scanned archives without rebuilding them.

Watch the entire Releaser run, not just the release page. Confirm its final
status is green, the page contains all four `craft-*.zip` archives plus the
manifest and SBOMs, and the intended npm versions resolve in the registry.

## When a leg fails

Leave the draft unpublished. Inspect the failed job and correct the build,
signing, scan, or verification problem. A retry can reuse the draft and replace
its staged archives; the final job still requires all gates to pass. If a code
change is needed, make it on `main` and cut a new tag rather than manually
publishing the incomplete draft. Do not interpret a successful tag push or a
partial set of staged archives as a completed release.

The GitHub release is gated as a unit; the underlying package registries do not
offer a cross-registry transaction. Both Zig and npm publication wait for the completed GitHub release. Either
registry publication can still fail after the native archives become public, so
the final workflow status remains the release signal. If a post-release registry
publication fails, the GitHub release still contains the full verified archive
set; inspect and rerun the failed job rather than republishing the draft.

## Release prerequisites and failed tags

Install the locked release tools with `bun install --frozen-lockfile` first.
Preflight now checks the Bumpx and Logsmith CLIs, a clean `main`, and the current
`origin/main` before changing versions. Use a separate release clone if `main`
is in use by another worktree. Required release commands fail before committing,
tagging or pushing; Bumpx restores the version files when they fail.

Retain a tag that failed publication. Choose a new unused version with
`bun run release:version <version>` and set `CRAFT_CHANGELOG_FROM` to the last
successfully published tag. The standard version and patch commands run the
same manifest synchronization, changelog generator and publication gates.
Confirm the final Releaser result and actual registry artifacts before apps
adopt the new version.

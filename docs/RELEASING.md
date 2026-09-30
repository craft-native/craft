# Releasing Craft

`bun run release:patch` bumps the public workspace and Zig versions, commits the
changelog, creates a tag, and pushes both. Run it only from a clean `main` that
matches `origin/main`, after the SDK, package, lint, and type checks are green.
Run `bun run test:release` too; it exercises the release gates and performs an
isolated bumpx commit/tag rehearsal without publishing or pushing a tag.
Before tagging, the CI installed-app jobs must be green: they launch real PKG,
DEB, and MSI installs and exercise child-window event routing from each package.
The release hook generates the next changelog section before that commit,
deduplicates repeated issue references, and links the previous and new tags.
Do not run the hook again after it has written the section.

The tag starts [Releaser](../.github/workflows/release.yml); pushing a tag is
the publication trigger, not proof that the release finished.

Both release and CI setup pin Pantry CLI 0.11.64 as well as the Pantry action
revision; leaving the CLI at `latest` would add a GitHub API lookup before the
build can even start.

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
The npm job separately scans and publishes the public JavaScript packages.

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
offer a cross-registry transaction. The Zig package waits for the completed
GitHub release, but npm publication is deliberately independent and may become
visible earlier. The final workflow status remains the release signal. If the
post-release Zig publication fails, the GitHub release still contains the full
verified archive set; rerun that failed job rather than republishing the draft.

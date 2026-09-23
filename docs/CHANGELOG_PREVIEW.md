# Preview release notes safely

After `bun install`, preview changes since the latest reachable tag without
writing release notes into the checkout:

```sh
bun run changelog:preview
bun run changelog:preview --from v0.0.92 --to HEAD
```

The preview resolves both refs to commits, directs the installed logsmith CLI
to an isolated temporary file, prints its contents, and removes that temporary
directory. Existing edits to `CHANGELOG.md` are preserved. Only `--from` and
`--to` are accepted; output overrides are deliberately unavailable.

Do not use logsmith 0.2.3's `--no-output` for a dry preview: its CLI currently
writes `CHANGELOG.md` despite that flag. This command is a Craft workaround,
not a fix to the upstream parser or its duplicate issue-reference rendering
(tracked in [#283](https://github.com/craft-native/craft/issues/283)). Review
generated issue links before releasing.

`bun run changelog:generate` remains the intentional command for updating
`CHANGELOG.md`. Neither command publishes packages or creates a release tag.

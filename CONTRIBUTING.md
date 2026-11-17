# Contributing

The action is [`action.yml`](action.yml), which runs one script,
[`install.sh`](install.sh), with `bash` on every system (Git Bash on Windows). All the
logic is in the script so that it can be run outside GitHub Actions.

## Testing

```sh
shellcheck install.sh
actionlint

# On this machine, into a temporary folder:
work=$(mktemp -d)
INPUT_VERSION=latest RUNNER_TOOL_CACHE="$work/cache" GITHUB_PATH="$work/path" \
  GITHUB_ENV="$work/env" GITHUB_OUTPUT="$work/output" ./install.sh
cat "$work/path" "$work/env" "$work/output"
```

`INPUT_TOKEN` is the `token` input; without it, `gh` uses its own login. On Linux (in a
container of the host's architecture, say) the same run installs the AppImage tools, and
`roadcase release linux --format appimage --skip-build --config test/fixture/roadcase.toml`
packages the fixture with them once `PATH` and the variables in `$work/env` are set.

[`ci.yml`](.github/workflows/ci.yml) runs the action from the checkout on every system
and architecture roadcase is released for, and makes the fixture's AppImage on Linux.

Commits follow [Conventional Commits](https://www.conventionalcommits.org). Actions in
the workflows are pinned by full commit SHA, with the version in a comment.

## Bumping the pinned tools

The versions and checksums are at the top of `install.sh`. Never point at a moving
release (`continuous`, `latest`): take an exact one.

1. Pick the release: [appimagetool](https://github.com/AppImage/appimagetool/releases),
   the [type-2 runtime](https://github.com/AppImage/type2-runtime/releases),
   [NSIS](https://sourceforge.net/projects/nsis/files/NSIS%203/).
2. Download each file and take its SHA-256 (`sha256sum`, or `shasum -a 256`), for both
   architectures. For the AppImage projects, compare with what GitHub computed:
   `gh api repos/AppImage/appimagetool/releases/tags/<tag> --jq '.assets[] | .name + " " + .digest'`.
3. Change the version and the checksums in `install.sh`, and the versions in the README's
   table. CI makes an AppImage with the new tools on both architectures.

`ACTIONLINT_VERSION` and its checksum in `ci.yml` move the same way.

## Releasing

1. On `main`, with CI green, draft a GitHub release with a new tag `vX.Y.Z`.
2. In the release form, tick **Publish this Action to the GitHub Marketplace** (the first
   time, GitHub asks you to accept the Marketplace agreement, and checks the name,
   description and branding in `action.yml`), choose the categories, and publish. Only a
   person can do this, in the release form: there is no API for the Marketplace.
3. [`release.yml`](.github/workflows/release.yml) then moves the major tag (`v1`) to the
   release. A prerelease moves nothing.

The workflow moves `v1` with its own token, so the repository's tag ruleset must leave
major tags to it: restrict creating, updating and deleting `refs/tags/v*.*.*` (the
releases, which never move) rather than `refs/tags/v*`. With a ruleset over `v*`, the
workflow fails, and an administrator moves the tag instead:

```sh
git tag -f v1 vX.Y.Z && git push -f origin v1
```

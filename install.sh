#!/usr/bin/env bash
# setup-roadcase: installs the `roadcase` program from its GitHub release, and
# what `roadcase release` needs on this system. action.yml runs this script and
# nothing else, so it can be run and tested outside GitHub Actions:
#
#   INPUT_VERSION=0.1.0 RUNNER_TEMP=/tmp/setup ./install.sh
#
# Inputs, from the environment (action.yml fills them from the action's
# inputs):
#
#   INPUT_VERSION             `latest`, or a version: `0.1.0` or `v0.1.0`
#   INPUT_TOKEN               a GitHub token, for the API request that resolves
#                             `latest` and for `gh attestation verify`. Never
#                             printed, never sent anywhere but api.github.com
#                             and to `gh`
#   INPUT_VERIFY_ATTESTATION  `true` (default) or `false`
#   INPUT_TOOLS               `true` (default) or `false`
#
# From the runner, each optional outside Actions: RUNNER_OS and RUNNER_ARCH
# (else `uname`), RUNNER_TOOL_CACHE or RUNNER_TEMP (where things are installed;
# else a temporary folder), GITHUB_PATH, GITHUB_ENV and GITHUB_OUTPUT (the
# files a step writes to; else nothing is written).
#
# Needs bash, curl, tar, and sha256sum or shasum; unzip on Windows; `gh` for
# the attestation. GitHub's own runners have them all.
set -euo pipefail

REPOSITORY=transcodeworks/roadcase

# The tools `roadcase release` runs, pinned: an exact release and the SHA-256
# of each file. README.md, "Bumping the pinned tools", says how to move them.
# shellcheck disable=SC2034  # read through ${!name}, by architecture
{
  APPIMAGETOOL_VERSION=1.9.1
  APPIMAGETOOL_SHA256_x86_64=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
  APPIMAGETOOL_SHA256_aarch64=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
  APPIMAGE_RUNTIME_VERSION=20251108
  APPIMAGE_RUNTIME_SHA256_x86_64=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
  APPIMAGE_RUNTIME_SHA256_aarch64=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
}
# Only where a Windows machine has no NSIS: GitHub's own images ship it.
NSIS_VERSION=3.11
NSIS_SHA256=c7d27f780ddb6cffb4730138cd1591e841f4b7edb155856901cdf5f214394fa1

fail() {
  echo "::error title=setup-roadcase::$*" >&2
  exit 1
}
warn() { echo "::warning title=setup-roadcase::$*" >&2; }
info() { echo "setup-roadcase: $*" >&2; }

# `true` or `false` from an input, which may be empty (its default).
flag() {
  case "$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')" in
    '' ) echo "$3" ;;
    true | false) printf '%s' "$2" | tr '[:upper:]' '[:lower:]' ;;
    *) fail "the input \`$1\` is \`$2\`: it takes true or false" ;;
  esac
}

# Downloads $1 to the file $2: HTTPS only, and again when the network or the
# server fails (not when the file is not there).
download() {
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 5 --retry-delay 2 --retry-connrefused --connect-timeout 20 \
    --output "$2" "$1" || fail "could not download $1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    fail "neither sha256sum nor shasum is installed: nothing can be verified"
  fi
}

# Stops unless the file $1 has the SHA-256 $2.
verify_sha256() {
  local actual
  actual=$(sha256_of "$1")
  [ "$actual" = "$2" ] ||
    fail "$(basename "$1") has the SHA-256 $actual, not the expected $2: not installing it"
}

# A path as this system's programs write it: C:\... on Windows.
native() {
  if [ "$os" = windows ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

add_path() {
  export PATH="$1:$PATH"
  if [ -n "${GITHUB_PATH:-}" ]; then native "$1" >>"$GITHUB_PATH"; fi
}
set_env() {
  export "$1=$2"
  if [ -n "${GITHUB_ENV:-}" ]; then echo "$1=$2" >>"$GITHUB_ENV"; fi
}
set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}

verify_attestation=$(flag verify-attestation "${INPUT_VERIFY_ATTESTATION:-}" true)
tools=$(flag tools "${INPUT_TOOLS:-}" true)
token=${INPUT_TOKEN:-}

# The system and the architecture, and the release's archive for them.
case "${RUNNER_OS:-$(uname -s)}" in
  Linux) os=linux ;;
  macOS | Darwin) os=macos ;;
  Windows | MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) fail "roadcase has no release for the system ${RUNNER_OS:-$(uname -s)}: it runs on Linux, macOS and Windows" ;;
esac
case "${RUNNER_ARCH:-$(uname -m)}" in
  X64 | x86_64 | amd64) arch=x86_64 ;;
  ARM64 | arm64 | aarch64) arch=aarch64 ;;
  *) fail "roadcase has no release for the architecture ${RUNNER_ARCH:-$(uname -m)}: it runs on x86_64 and aarch64" ;;
esac
case "$os-$arch" in
  linux-*) target="$arch-unknown-linux-musl" extension=tar.gz ;;
  macos-*) target="$arch-apple-darwin" extension=tar.gz ;;
  windows-x86_64) target=x86_64-pc-windows-msvc extension=zip ;;
  *) fail "roadcase has no release for Windows on $arch: use an x86_64 Windows runner" ;;
esac

# The version: the one asked for, or the latest release's.
version=${INPUT_VERSION:-latest}
if [ "$version" = latest ]; then
  api=(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2
    --retry 5 --retry-delay 2 --retry-connrefused --connect-timeout 20
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28')
  if [ -n "$token" ]; then api+=(--header "Authorization: Bearer $token"); fi
  release=$("${api[@]}" "https://api.github.com/repos/$REPOSITORY/releases/latest") ||
    fail "could not ask GitHub for the latest release of $REPOSITORY: name a version in the input \`version\`, or check the input \`token\`"
  version=$(printf '%s' "$release" | tr -d '\n' |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$version" ] || fail "GitHub named no latest release of $REPOSITORY"
fi
version=${version#v}
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
  fail "the input \`version\` is \`${INPUT_VERSION:-}\`: it takes latest, or a version such as 0.1.0 or v0.1.0"
fi

# Where things go: the runner's tool cache, or its temporary folder.
if [ -n "${RUNNER_TOOL_CACHE:-}" ]; then
  root=$RUNNER_TOOL_CACHE
elif [ -n "${RUNNER_TEMP:-}" ]; then
  root=$RUNNER_TEMP
else
  root=$(mktemp -d)
fi
if [ "$os" = windows ] && command -v cygpath >/dev/null 2>&1; then
  root=$(cygpath -u "$root")
fi
mkdir -p "$root"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The archive and its checksum.
archive="roadcase-$target.$extension"
base="https://github.com/$REPOSITORY/releases/download/v$version"
info "roadcase $version for $target"
download "$base/$archive" "$work/$archive"
download "$base/$archive.sha256" "$work/$archive.sha256"
expected=$(tr -d '\r' <"$work/$archive.sha256" | awk 'NR == 1 { print tolower($1) }')
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "$archive.sha256 holds no SHA-256"
verify_sha256 "$work/$archive" "$expected"
info "$archive: the SHA-256 is $expected, as the release says"

# Its build provenance: that the release workflow of the repository built it.
if [ "$verify_attestation" = true ]; then
  if command -v gh >/dev/null 2>&1 && gh attestation verify --help >/dev/null 2>&1; then
    log="$work/attestation.log"
    if [ -n "$token" ]; then
      GH_TOKEN=$token gh attestation verify "$work/$archive" --repo "$REPOSITORY" >"$log" 2>&1
    else
      gh attestation verify "$work/$archive" --repo "$REPOSITORY" >"$log" 2>&1
    fi || {
      cat "$log" >&2
      fail "$archive has no valid build provenance attestation from $REPOSITORY: not installing it"
    }
    info "$archive: the build provenance attestation is from $REPOSITORY"
  else
    warn "the GitHub CLI (gh, 2.49 or later) is not installed, so the build provenance attestation was not verified; the SHA-256 matched the release's. Install gh, or set verify-attestation to false to say so yourself."
  fi
fi

# Unpacked beside the tool cache's other tools, and on PATH.
bin="$root/roadcase/$version/$arch"
rm -rf "$bin"
mkdir -p "$bin"
if [ "$extension" = zip ]; then
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$work/$archive" -d "$bin"
  else
    powershell -NoProfile -Command \
      "Expand-Archive -LiteralPath '$(native "$work/$archive")' -DestinationPath '$(native "$bin")' -Force"
  fi
  program="$bin/roadcase.exe"
else
  tar -xzf "$work/$archive" -C "$bin"
  program="$bin/roadcase"
fi
[ -f "$program" ] || fail "$archive holds no $(basename "$program")"
chmod +x "$program"
add_path "$bin"

# What `roadcase release` runs on this system.
if [ "$tools" = true ]; then
  case "$os" in
    linux)
      # appimagetool and the type-2 runtime it puts at the head of an
      # AppImage. roadcase reads both names from the environment, and gives
      # appimagetool the runtime, so that it downloads none.
      folder="$root/roadcase-tools/appimage/$APPIMAGETOOL_VERSION-$APPIMAGE_RUNTIME_VERSION/$arch"
      mkdir -p "$folder"
      tool_sha=APPIMAGETOOL_SHA256_$arch
      runtime_sha=APPIMAGE_RUNTIME_SHA256_$arch
      download "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-$arch.AppImage" \
        "$work/appimagetool"
      verify_sha256 "$work/appimagetool" "${!tool_sha}"
      download "https://github.com/AppImage/type2-runtime/releases/download/$APPIMAGE_RUNTIME_VERSION/runtime-$arch" \
        "$work/runtime-$arch"
      verify_sha256 "$work/runtime-$arch" "${!runtime_sha}"
      mv -f "$work/appimagetool" "$folder/appimagetool"
      mv -f "$work/runtime-$arch" "$folder/runtime-$arch"
      chmod +x "$folder/appimagetool"
      add_path "$folder"
      set_env APPIMAGETOOL "$folder/appimagetool"
      set_env APPIMAGE_RUNTIME "$folder/runtime-$arch"
      # Hosted runners and containers have no FUSE 2, which an AppImage
      # (appimagetool is one) mounts itself with: it unpacks itself instead.
      set_env APPIMAGE_EXTRACT_AND_RUN 1
      info "appimagetool $APPIMAGETOOL_VERSION and the AppImage runtime $APPIMAGE_RUNTIME_VERSION, checksums verified"
      command -v file >/dev/null 2>&1 ||
        warn "appimagetool needs the \`file\` program, which is not installed here: install it (apt-get install file) before \`roadcase release linux\`."
      ;;
    windows)
      if command -v makensis >/dev/null 2>&1; then
        info "makensis is on PATH: $(command -v makensis)"
      else
        nsis=
        for folder in "/c/Program Files (x86)/NSIS" "/c/Program Files/NSIS"; do
          if [ -f "$folder/makensis.exe" ]; then
            nsis=$folder
            break
          fi
        done
        if [ -z "$nsis" ]; then
          download "https://downloads.sourceforge.net/project/nsis/NSIS%203/$NSIS_VERSION/nsis-$NSIS_VERSION.zip" \
            "$work/nsis.zip"
          verify_sha256 "$work/nsis.zip" "$NSIS_SHA256"
          rm -rf "$root/roadcase-tools/nsis/$NSIS_VERSION"
          mkdir -p "$root/roadcase-tools/nsis/$NSIS_VERSION"
          unzip -q -o "$work/nsis.zip" -d "$root/roadcase-tools/nsis/$NSIS_VERSION"
          nsis="$root/roadcase-tools/nsis/$NSIS_VERSION/nsis-$NSIS_VERSION"
          [ -f "$nsis/makensis.exe" ] || fail "nsis-$NSIS_VERSION.zip holds no makensis.exe"
          info "NSIS $NSIS_VERSION installed, checksum verified"
        fi
        add_path "$nsis"
        info "makensis: $nsis"
      fi
      ;;
    macos)
      # codesign, notarytool and hdiutil come with macOS and Xcode's
      # command-line tools, which every macOS runner has.
      ;;
  esac
fi

installed=$("$program" --version) || fail "$(basename "$program") does not run on this machine"
info "$installed, in $(native "$bin")"
set_output version "$version"
set_output path "$(native "$bin")"

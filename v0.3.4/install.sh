#!/usr/bin/env bash

# This work is dedicated to the public domain under CC0 1.0.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# To the extent possible under law, the author has waived all
# copyright and related or neighboring rights to this work.

set -eu
# Check pipefail support in a subshell, ignore if unsupported
# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

help() {
  cat <<'EOF'
Install a binary release of celq hosted on GitHub

This script detects what platform you're on and fetches an appropriate archive from
https://github.com/IvanIsCoding/celq/releases
then unpacks the binaries and installs them to either
$CARGO_HOME/bin, $HOME/.cargo/bin, $HOME/.local/bin or $HOME/bin.

USAGE:
    install.sh [options]

FLAGS:
    -h, --help      Display this message
    -f, --force     Force overwriting an existing binary

OPTIONS:
    --to LOCATION   Where to install the binary [default: $CARGO_HOME/bin, $HOME/.cargo/bin, $HOME/.local/bin or $HOME/bin]
    --target TARGET Following Rust target triple conventions (e.g. x86_64-unknown-linux-gnu).
    --verify-checksum    Verify the downloaded archive's SHA256 checksum
    --verify-attestation  Verify the binary's GitHub Actions attestation (requires GitHub CLI with authentication)
EOF
}

crate=celq
url=https://github.com/IvanIsCoding/celq
releases=$url/releases

say() {
  echo "install: $*" >&2
}

err() {
  if [ -n "${td-}" ]; then
    rm -rf "$td"
  fi

  say "error: $*"
  exit 1
}

need() {
  if ! command -v "$1" > /dev/null 2>&1; then
    err "need $1 (command not found)"
  fi
}

download() {
  url="$1"
  output="$2"
  args=()

  if [ -n "${GITHUB_TOKEN+x}" ]; then
    args+=(--header "Authorization: Bearer $GITHUB_TOKEN")
  fi

  if command -v curl > /dev/null; then
    curl --proto =https --tlsv1.2 -sSfL ${args[@]+"${args[@]}"} "$url" -o"$output"
  else
    wget --https-only --secure-protocol=TLSv1_2 --quiet ${args[@]+"${args[@]}"} "$url" -O"$output"
  fi
}

check_attestation() {
  local archive_file="$1"
  
  say "Verifying attestation for $archive_file"
  
  if ! gh attestation verify "$archive_file" --repo IvanIsCoding/celq; then
    say "error: attestation verification failed"
    return 1
  fi
  
  say "Attestation verification successful"
  return 0
}

# Get expected SHA256 checksum for a target
get_expected_checksum() {
  local rust_target="$1"
  
  case "$rust_target" in
    aarch64-apple-darwin)
      echo "183794f8efb6bce99c0a0a7b8b0ea8c54104115189995965815e21d2a4866bbf"
      ;;
    x86_64-apple-darwin)
      echo "583628fd9117c0672cf3d4a622668b0e5abbca72bc5b249f4566a954fd2a805c"
      ;;
    x86_64-pc-windows-msvc)
      echo "853715db3ea1a5b78200e3163577412aa42f9de9b6366ea4e31aa4115777f14d"
      ;;
    x86_64-unknown-linux-musl)
      echo "84d0a1b20de4747a71fd4601ec0664521f49152caf2d37b11303634b3ac360c3"
      ;;
    aarch64-unknown-linux-musl)
      echo "81653a54aba1d405aa1ca44bc678922ca4439202824818d18168200e4b472084"
      ;;
    x86_64-unknown-linux-gnu)
      echo "d45753f8917dd99e8de51ae6c105ddb5fce115edfc191d50ba27d8aff069efe4"
      ;;
    aarch64-unknown-linux-gnu)
      echo "ced6703e4caf21ab74b5fd8177ea833754a887cc42b02cf3adacd6461cfa67c1"
      ;;
    *)
      err "No checksum available for target: $rust_target"
      ;;
  esac
}

verify_checksum() {
  local file="$1"
  local target="$2"
  
  say "Verifying checksum for $file"
  
  local expected_checksum
  expected_checksum=$(get_expected_checksum "$target")
  
  if [ -z "$expected_checksum" ] || [ "$expected_checksum" = "{{CHECKSUM_"* ]; then
    err "Checksum template not populated for target: $target"
  fi
  
  local actual_checksum
  if command -v sha256sum > /dev/null 2>&1; then
    actual_checksum=$(sha256sum "$file" | cut -d' ' -f1)
  elif command -v shasum > /dev/null 2>&1; then
    actual_checksum=$(shasum -a 256 "$file" | cut -d' ' -f1)
  else
    err "need sha256sum or shasum (command not found)"
  fi
  
  if [ "$actual_checksum" != "$expected_checksum" ]; then
    say "error: checksum mismatch"
    say "  expected: $expected_checksum"
    say "  actual:   $actual_checksum"
    return 1
  fi
  
  say "Checksum verification successful"
  return 0
}

# Map Rust target triple to pretty download name
target_to_pretty_name() {
  local rust_target="$1"
  
  case "$rust_target" in
    aarch64-apple-darwin) echo "macos-aarch64";;
    x86_64-apple-darwin) echo "macos-x86_64";;
    x86_64-pc-windows-msvc) echo "windows-x86_64";;
    x86_64-unknown-linux-musl) echo "linux-x86_64-musl";;
    aarch64-unknown-linux-musl) echo "linux-aarch64-musl";;
    x86_64-unknown-linux-gnu) echo "linux-x86_64-gnu";;
    aarch64-unknown-linux-gnu) echo "linux-aarch64-gnu";;
    *)
      err "Unsupported target: $rust_target"
      ;;
  esac
}

force=false
verify_attestation=false
verify_checksums=false
while test $# -gt 0; do
  case $1 in
    --force | -f)
      force=true
      ;;
    --help | -h)
      help
      exit 0
      ;;
    --target)
      target=$2
      shift
      ;;
    --to)
      dest=$2
      shift
      ;;
    --verify-attestation)
      verify_attestation=true
      ;;
    --verify-checksum)
      verify_checksums=true
      ;;
    *)
      say "error: unrecognized argument '$1'. Usage:"
      help
      exit 1
      ;;
  esac
  shift
done

command -v curl > /dev/null 2>&1 ||
  command -v wget > /dev/null 2>&1 ||
  err "need wget or curl (command not found)"

need mkdir
need mktemp

if [ -z "${target-}" ]; then
  need cut
fi

if [ "$verify_attestation" = true ]; then
  need gh
fi

if [ "$verify_checksums" = true ]; then
  command -v sha256sum > /dev/null 2>&1 ||
    command -v shasum > /dev/null 2>&1 ||
    err "need sha256sum or shasum (command not found)"
fi

if [ -z "${dest-}" ]; then
  # Try to determine installation directory following Cargo conventions
  if [ -n "${CARGO_HOME-}" ]; then
    dest="$CARGO_HOME/bin"
  elif [ -n "${HOME-}" ]; then
    # Try $HOME/.cargo/bin first (standard Cargo location)
    if [ -d "$HOME/.cargo/bin" ]; then
      dest="$HOME/.cargo/bin"
    # Fall back to $HOME/.local/bin if it exists
    elif [ -d "$HOME/.local/bin" ]; then
      dest="$HOME/.local/bin"
    else
      dest="$HOME/bin"
    fi
  else
    err "Cannot determine installation directory. Re-run with the --to option"
  fi
fi

if [ -z "${target-}" ]; then
  # bash compiled with MINGW (e.g. git-bash, used in github windows runners),
  # unhelpfully includes a version suffix in `uname -s` output, so handle that.
  # e.g. MINGW64_NT-10-0.19044
  kernel=$(uname -s | cut -d- -f1)
  uname_target="$(uname -m)-$kernel"

  case $uname_target in
    aarch64-Linux) target=aarch64-unknown-linux-musl;;
    arm64-Darwin) target=aarch64-apple-darwin;;
    x86_64-Darwin) target=x86_64-apple-darwin;;
    x86_64-Linux) target=x86_64-unknown-linux-musl;;
    x86_64-MINGW64_NT) target=x86_64-pc-windows-msvc;;
    x86_64-Windows_NT) target=x86_64-pc-windows-msvc;;
    *)
      # shellcheck disable=SC2016
      err 'Could not determine target from output of `uname -m`/`uname -s`, please use `--target`:' "$uname_target"
    ;;
  esac
fi

# Convert target to pretty name for download URL
pretty_target=$(target_to_pretty_name "$target")

case $target in
  x86_64-pc-windows-msvc) 
    extension=zip
    need unzip
    celq_suffix=".exe"
    ;;
  *) 
    extension=tar.gz
    need tar
    celq_suffix=""
    ;;
esac

archive="$releases/download/v0.3.4/$crate-$pretty_target.$extension"

say "Repository:  $url"
say "Crate:       $crate"
say "Tag:         v0.3.4"
say "Target:      $target"
say "Destination: $dest"
say "Archive:     $archive"

# Check if destination is in PATH
if [[ ":$PATH:" != *":$dest:"* ]]; then
  say ""
  say "Warning: $dest is not in your PATH"
  say "Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
  say ""
  say "    export PATH=\"$dest:\$PATH\""
  say ""
fi

td=$(mktemp -d || mktemp -d -t tmp)

if [ "$extension" = "zip" ]; then
  download "$archive" "$td/celq.zip"
  archive_file="$td/celq.zip"
  
  if [ "$verify_checksums" = true ]; then
    verify_checksum "$archive_file" "$target" || err "Checksum verification failed"
  fi
  
  if [ "$verify_attestation" = true ]; then
    check_attestation "$archive_file" || err "Attestation verification failed"
  fi
  
  unzip -d "$td" "$archive_file"
else
  download "$archive" "$td/celq.tar.gz"
  archive_file="$td/celq.tar.gz"
  
  if [ "$verify_checksums" = true ]; then
    verify_checksum "$archive_file" "$target" || err "Checksum verification failed"
  fi
  
  if [ "$verify_attestation" = true ]; then
    check_attestation "$archive_file" || err "Attestation verification failed"
  fi
  
  tar -C "$td" -xzf "$archive_file"
fi

if [ -e "$dest/celq${celq_suffix}" ] && [ "$force" = false ]; then
  err "\`$dest/celq${celq_suffix}\` already exists"
else
  mkdir -p "$dest"
  cp "$td/celq${celq_suffix}" "$dest/celq${celq_suffix}"
  chmod 755 "$dest/celq${celq_suffix}"
fi

rm -rf "$td"
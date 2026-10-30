#!/usr/bin/env bash
# Build helium-bin with a throwaway GnuPG home that contains upstream's
# signing key. This avoids importing the key into the user's keyring.
#
# Environment:
#   BUILD_WORKDIR   directory containing PKGBUILD (default: repository root)
#   BUILD_SRCDEST   exported as SRCDEST when set
#   BUILD_PKGDEST   exported as PKGDEST when set
#   BUILD_GNUPG     GnuPG home (default: ~/.cache/helium-arch/gnupg); the
#                   automation passes its isolated workspace keyring
set -euo pipefail

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_workdir="${BUILD_WORKDIR:-$_root}"
_key="BE677C1989D35EAB2C5F26C9351601AD01D6378E"
_cache="${XDG_CACHE_HOME:-$HOME/.cache}/helium-arch"
_gnupg="${BUILD_GNUPG:-${_cache}/gnupg}"

if [[ ! -d "$_workdir" ]]; then
  echo "error: build directory does not exist: $_workdir" >&2
  exit 1
fi
if [[ ! -f "${_workdir}/PKGBUILD" ]]; then
  echo "error: PKGBUILD not found in ${_workdir}" >&2
  exit 1
fi

if [[ -n "${BUILD_SRCDEST:-}" ]]; then
  export SRCDEST="$BUILD_SRCDEST"
fi
if [[ -n "${BUILD_PKGDEST:-}" ]]; then
  export PKGDEST="$BUILD_PKGDEST"
fi

mkdir -p "$_gnupg"
chmod 700 "$_gnupg"
export GNUPGHOME="$_gnupg"

if ! gpg --batch --list-keys "$_key" >/dev/null 2>&1; then
  gpg --batch --quiet --import "${_root}/keys/pgp/${_key}.asc"
fi

cd "$_workdir"
exec makepkg "$@"

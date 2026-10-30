#!/usr/bin/env bash
# Update PKGBUILD to a new (or the latest) upstream Helium release.
#
# The default invocation keeps the historical behaviour: the PKGBUILD and
# .SRCINFO in the repository root are updated after the release has been
# downloaded and its PGP signature verified. Files are prepared in a staging
# directory on the same filesystem and moved into place only at the end, so a
# failure does not leave partially rewritten packaging files behind.
#
# Usage:
#   scripts/update.sh                    # update to GitHub's latest release
#   scripts/update.sh 0.20.1.1           # update to a specific version
#   scripts/update.sh --workdir DIR ...  # update an isolated workspace copy
#   scripts/update.sh --check 0.20.1.1   # verify only, modify nothing
#
# Options:
#   --workdir DIR    directory containing PKGBUILD/.SRCINFO (default: repo)
#   --cache DIR      source download cache (default: $SRCDEST or --workdir)
#   --gnupg DIR      use this GnuPG home instead of a temporary one
#   --check          download and verify the release, then exit without edits
#   --reset-pkgrel   force pkgrel=1 even when pkgver is unchanged
#
# Environment:
#   SRCDEST          source cache, kept for backwards compatibility
#   UPDATE_WORKDIR   alternative to --workdir
#   UPDATE_CACHE     alternative to --cache
#   UPDATE_GNUPG     alternative to --gnupg
#
# pkgrel policy:
#   - when pkgver changes, pkgrel is reset to 1;
#   - when pkgver is unchanged, the existing pkgrel is preserved unless
#     --reset-pkgrel is given.
set -euo pipefail

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_key="BE677C1989D35EAB2C5F26C9351601AD01D6378E"
_version=""
_workdir="${UPDATE_WORKDIR:-$_root}"
_cache_arg=""
_gnupg_arg="${UPDATE_GNUPG:-}"
_check_only=0
_reset_pkgrel=0

_usage() {
  cat <<'EOF'
Usage: update.sh [options] [version]

Options:
  --workdir DIR    directory containing PKGBUILD/.SRCINFO (default: repo)
  --cache DIR      source download cache (default: $SRCDEST or --workdir)
  --gnupg DIR      use this GnuPG home instead of a temporary one
  --check          download and verify the release, then exit without edits
  --reset-pkgrel   force pkgrel=1 even when pkgver is unchanged
  -h, --help       show this help
EOF
}

_need_arg() {
  if (( $# < 2 )) || [[ -z "$2" ]]; then
    echo "error: $1 requires an argument" >&2
    exit 2
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --workdir)
      _need_arg "$@"
      _workdir="$2"
      shift 2
      ;;
    --cache)
      _need_arg "$@"
      _cache_arg="$2"
      shift 2
      ;;
    --gnupg)
      _need_arg "$@"
      _gnupg_arg="$2"
      shift 2
      ;;
    --check)
      _check_only=1
      shift
      ;;
    --reset-pkgrel)
      _reset_pkgrel=1
      shift
      ;;
    -h|--help)
      _usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown argument: $1" >&2
      _usage >&2
      exit 2
      ;;
    *)
      _version="$1"
      shift
      ;;
  esac
done

for _cmd in curl gpg makepkg updpkgsums; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "error: '$_cmd' is required (updpkgsums is in pacman-contrib)" >&2
    exit 1
  fi
done

if [[ -z "$_workdir" ]]; then
  echo 'error: --workdir must not be empty' >&2
  exit 2
fi
mkdir -p "$_workdir"
_workdir="$(cd "$_workdir" && pwd)"
_pkgbuild="${_workdir}/PKGBUILD"
if [[ ! -f "$_pkgbuild" ]]; then
  echo "error: PKGBUILD not found in ${_workdir}" >&2
  exit 1
fi

if [[ -z "$_version" ]]; then
  _version="$(curl -fsSL --max-time 30 --retry 3 \
    https://api.github.com/repos/imputnet/helium-linux/releases/latest |
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
fi

if [[ "$_version" == v* ]]; then
  _version="${_version#v}"
fi

if [[ ! "$_version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo "error: invalid or missing upstream version: '${_version}'" >&2
  exit 1
fi

_source_dir="${UPDATE_CACHE:-${SRCDEST:-$_workdir}}"
if [[ -n "$_cache_arg" ]]; then
  _source_dir="$_cache_arg"
fi
mkdir -p "$_source_dir"
_source_dir="$(cd "$_source_dir" && pwd)"

_tarball="helium-${_version}-x86_64_linux.tar.xz"
_asc="${_tarball}.asc"
_release_url="https://github.com/imputnet/helium-linux/releases/download/${_version}"
_raw_url="https://raw.githubusercontent.com/imputnet/helium-linux/${_version}"

_download() {
  local url="$1" out="$2"
  echo "download: ${url}"
  curl -fL --connect-timeout 30 --retry 3 --retry-delay 2 -o "${out}.part" "$url"
  mv "${out}.part" "$out"
}

_fetch_cached() {
  local url="$1" out="$2"
  if [[ -s "$out" ]]; then
    echo "cached: ${out}"
  else
    _download "$url" "$out"
  fi
}

# Release artifacts include the version in their filename, so a cache hit is
# safe. Metadata filenames do not change between releases, so always refresh
# them; otherwise a new version could be paired with an old LICENSE/metainfo.
_fetch_cached "${_release_url}/${_tarball}" "${_source_dir}/${_tarball}"
_fetch_cached "${_release_url}/${_asc}" "${_source_dir}/${_asc}"
_download "${_raw_url}/LICENSE" "${_source_dir}/helium-LICENSE"
_download "${_raw_url}/LICENSE.ungoogled_chromium" \
  "${_source_dir}/helium-LICENSE.ungoogled_chromium"
_download "${_raw_url}/package/net.imput.helium.metainfo.xml" \
  "${_source_dir}/net.imput.helium.metainfo.xml"

_remove_gnupg=0
if [[ -n "$_gnupg_arg" ]]; then
  mkdir -p "$_gnupg_arg"
  chmod 700 "$_gnupg_arg"
  _gnupg="$(cd "$_gnupg_arg" && pwd)"
else
  _gnupg="$(mktemp -d)"
  chmod 700 "$_gnupg"
  _remove_gnupg=1
fi
export GNUPGHOME="$_gnupg"
if (( _remove_gnupg == 1 )); then
  # Also clean up when verification fails before the main cleanup trap exists.
  trap 'rm -rf "$_gnupg"' EXIT
fi
gpg --batch --quiet --import "${_root}/keys/pgp/${_key}.asc"
gpg --batch --verify "${_source_dir}/${_asc}" "${_source_dir}/${_tarball}"

if (( _check_only == 1 )); then
  _sha="$(sha256sum "${_source_dir}/${_tarball}" | awk '{print $1}')"
  echo "verified: Helium ${_version} (sha256 ${_sha})"
  echo 'check-only mode: no files were modified'
  if (( _remove_gnupg == 1 )); then
    rm -rf "$_gnupg"
  fi
  exit 0
fi

_old_pkgver="$(sed -n 's/^pkgver=//p' "$_pkgbuild" | head -n1)"
_pkgrel=1
if [[ "$_version" == "$_old_pkgver" ]] && (( _reset_pkgrel == 0 )); then
  _pkgrel="$(sed -n 's/^pkgrel=//p' "$_pkgbuild" | head -n1)"
  [[ "$_pkgrel" =~ ^[0-9]+$ ]] || _pkgrel=1
  echo "note: pkgver is unchanged; keeping pkgrel=${_pkgrel}"
else
  echo "note: pkgver change resets pkgrel to 1"
fi

_stage="$(mktemp -d "${_workdir}/.update.XXXXXX")"
_old_pkg=""
_old_src=""
_had_src=0
_committed=0

_cleanup() {
  local rc=$?
  if (( _committed == 0 )) && [[ -n "$_old_pkg" && -f "$_old_pkg" ]]; then
    cp -p "$_old_pkg" "$_pkgbuild"
  fi
  if (( _committed == 0 )) && [[ -n "$_old_src" ]]; then
    if (( _had_src == 1 )); then
      cp -p "$_old_src" "${_workdir}/.SRCINFO"
    else
      rm -f "${_workdir}/.SRCINFO"
    fi
  fi
  rm -f "$_old_pkg" "$_old_src"
  rm -rf "$_stage"
  if (( _remove_gnupg == 1 )); then
    rm -rf "$_gnupg"
  fi
  exit "$rc"
}
trap _cleanup EXIT

_old_pkg="$(mktemp)"
cp -p "$_pkgbuild" "$_old_pkg"
if [[ -f "${_workdir}/.SRCINFO" ]]; then
  _old_src="$(mktemp)"
  cp -p "${_workdir}/.SRCINFO" "$_old_src"
  _had_src=1
fi

cp -p "$_pkgbuild" "${_stage}/PKGBUILD"
sed -i "s/^pkgver=.*/pkgver=${_version}/; s/^pkgrel=.*/pkgrel=${_pkgrel}/" \
  "${_stage}/PKGBUILD"

(
  cd "$_stage"
  SRCDEST="$_source_dir" updpkgsums
)

# updpkgsums deliberately writes SKIP for signature files. Keep a pinned hash
# as well so that the .asc file itself cannot silently change.
if grep -q "'SKIP'" "${_stage}/PKGBUILD"; then
  _asc_hash="$(sha256sum "${_source_dir}/${_asc}" | awk '{print $1}')"
  sed -i "0,/'SKIP'/s//'${_asc_hash}'/" "${_stage}/PKGBUILD"
fi

if grep -q "'SKIP'" "${_stage}/PKGBUILD"; then
  echo 'error: unresolved SKIP checksum in PKGBUILD' >&2
  exit 1
fi

(
  cd "$_stage"
  makepkg --printsrcinfo >.SRCINFO
)

# Commit the candidate. .SRCINFO is replaced first and PKGBUILD last so the
# PKGBUILD, which drives the build, is the final write.
mv -f "${_stage}/.SRCINFO" "${_workdir}/.SRCINFO"
mv -f "${_stage}/PKGBUILD" "$_pkgbuild"
_committed=1

echo
echo "Updated to Helium ${_version} (pkgrel ${_pkgrel}). Review the diff, then build with:"
echo "  ./scripts/build.sh -si"

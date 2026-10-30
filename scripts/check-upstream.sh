#!/usr/bin/env bash
# Read-only check for a newer upstream Helium Linux release.
#
# This script never writes to the repository and never downloads a release
# artifact. It only queries the GitHub releases API and reads local files.
#
# Usage:
#   scripts/check-upstream.sh [--json] [--repo DIR] [--timeout SECONDS]
#
# Exit codes:
#   0   no update is needed (up to date, local ahead, or already built)
#   10  an update is available (or the current version was never built)
#   20  operational error (network, API, malformed response, invalid version)
#   2   usage error
#
# Environment:
#   HELIUM_REPO   repository root (default: parent of this script's directory)
#   GITHUB_TOKEN  optional token, used to raise the GitHub API rate limit
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_UPDATE=10
readonly EXIT_ERROR=20
readonly EXIT_USAGE=2

_api_url="https://api.github.com/repos/imputnet/helium-linux/releases/latest"
_repo="${HELIUM_REPO:-}"
_timeout=20
_json=0

_upstream_version=""
_upstream_tag=""
_tag_prefix=""
_current_version=""
_last_version=""
_last_manifest=""

_usage() {
  cat <<'EOF'
Usage: check-upstream.sh [--json] [--repo DIR] [--timeout SECONDS]

Exit codes:
  0   no update needed
  10  update available
  20  operational error
  2   usage error
EOF
}

_need_arg() {
  if (( $# < 2 )) || [[ -z "$2" ]]; then
    echo "error: $1 requires an argument" >&2
    exit "$EXIT_USAGE"
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --json)
      _json=1
      shift
      ;;
    --repo)
      _need_arg "$@"
      _repo="$2"
      shift 2
      ;;
    --timeout)
      _need_arg "$@"
      _timeout="$2"
      shift 2
      ;;
    -h|--help)
      _usage
      exit "$EXIT_OK"
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      _usage >&2
      exit "$EXIT_USAGE"
      ;;
  esac
done

if [[ ! "$_timeout" =~ ^[0-9]+$ ]] || (( _timeout < 1 )); then
  echo "error: --timeout must be a positive integer" >&2
  exit "$EXIT_USAGE"
fi

if [[ -z "$_repo" ]]; then
  _repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
_repo="$(cd "$_repo" && pwd)" || {
  echo "error: repository directory does not exist" >&2
  exit "$EXIT_ERROR"
}

for _cmd in curl python3; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "error: '$_cmd' is required" >&2
    exit "$EXIT_ERROR"
  fi
done

# Numeric version comparison. Prints -1, 0, or 1.
_vercmp() {
  local -a a b
  local i n x y
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  n=${#a[@]}
  (( ${#b[@]} > n )) && n=${#b[@]}
  for ((i = 0; i < n; i++)); do
    x=${a[i]:-0}
    y=${b[i]:-0}
    if (( 10#$x > 10#$y )); then
      printf '1\n'
      return 0
    fi
    if (( 10#$x < 10#$y )); then
      printf '%s\n' '-1'
      return 0
    fi
  done
  printf '0\n'
}

# Print the version of the newest successful automation manifest, if any.
_read_last_success() {
  python3 - "$_repo/out" <<'PY'
import json
import os
import sys

out_dir = sys.argv[1]
candidates = []

latest = os.path.join(out_dir, "latest", "manifest.json")
paths = [latest] if os.path.isfile(latest) else []
if not paths:
    try:
        entries = os.listdir(out_dir)
    except OSError:
        entries = []
    for name in entries:
        path = os.path.join(out_dir, name, "manifest.json")
        if os.path.isfile(path):
            paths.append(path)

for path in paths:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        continue
    if data.get("result") != "success":
        continue
    version = (data.get("upstream") or {}).get("version")
    if not isinstance(version, str):
        continue
    candidates.append((version, path))

if not candidates:
    print()
    print()
else:
    version, path = candidates[0]
    print(version)
    print(path)
PY
}

_emit() {
  local status="$1" reason="$2" rc="$3"
  local checked_at
  checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if (( _json == 1 )); then
    STATUS="$status" REASON="$reason" CHECKED_AT="$checked_at" \
    UPSTREAM="$_upstream_version" TAG="$_upstream_tag" PREFIX="$_tag_prefix" \
    CURRENT="$_current_version" LAST="$_last_version" MANIFEST="$_last_manifest" \
    python3 <<'PY'
import json
import os

payload = {
    "status": os.environ["STATUS"],
    "reason": os.environ["REASON"],
    "checked_at": os.environ["CHECKED_AT"],
    "upstream_version": os.environ["UPSTREAM"] or None,
    "upstream_tag": os.environ["TAG"] or None,
    "tag_prefix": os.environ["PREFIX"] or None,
    "current_version": os.environ["CURRENT"] or None,
    "last_success_version": os.environ["LAST"] or None,
    "latest_manifest": os.environ["MANIFEST"] or None,
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY
  else
    printf 'checked_at      : %s\n' "$checked_at"
    printf 'upstream version: %s\n' "${_upstream_version:-unknown}"
    printf 'upstream tag    : %s\n' "${_upstream_tag:-unknown}"
    printf 'current pkgver  : %s\n' "${_current_version:-unknown}"
    printf 'last built      : %s\n' "${_last_version:-none}"
    printf 'result          : %s\n' "$status"
    printf 'reason          : %s\n' "$reason"
    if [[ -n "$_tag_prefix" ]]; then
      printf 'note            : upstream tag uses a "%s" prefix (normalized)\n' "$_tag_prefix"
    fi
    if [[ -n "$_last_manifest" ]]; then
      printf 'manifest        : %s\n' "$_last_manifest"
    fi
  fi

  exit "$rc"
}

_die() {
  _emit error "$1" "$EXIT_ERROR"
}

_pkgbuild="$_repo/PKGBUILD"
if [[ ! -f "$_pkgbuild" ]]; then
  _die "PKGBUILD not found in $_repo"
fi

_current_version="$(sed -n 's/^pkgver=//p' "$_pkgbuild" | head -n1)"
if [[ ! "$_current_version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  _die "PKGBUILD has an invalid pkgver: '${_current_version}'"
fi

_last_info="$(_read_last_success)" || _die "unable to read output manifests"
_last_version="$(sed -n '1p' <<<"$_last_info")"
_last_manifest="$(sed -n '2p' <<<"$_last_info")"

_body="$(mktemp)"
_headers="$(mktemp)"
_curl_config=""
_cleanup() {
  rm -f "$_body" "$_headers"
  if [[ -n "$_curl_config" ]]; then
    rm -f "$_curl_config"
  fi
}
trap _cleanup EXIT

_curl_args=(
  -sS
  --max-time "$_timeout"
  --retry 2
  --retry-delay 1
  -H 'Accept: application/vnd.github+json'
  -D "$_headers"
  -o "$_body"
  -w '%{http_code}'
  "$_api_url"
)

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  _curl_config="$(mktemp)"
  chmod 600 "$_curl_config"
  printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" >"$_curl_config"
  _curl_args+=(-K "$_curl_config")
fi

set +e
_http_code="$(curl "${_curl_args[@]}")"
_curl_rc=$?
set -e

if (( _curl_rc != 0 )); then
  _die "GitHub API request failed (curl exit ${_curl_rc})"
fi

if [[ "$_http_code" != "200" ]]; then
  _remaining="$(awk 'tolower($1) == "x-ratelimit-remaining:" {gsub("\r", ""); print $2}' "$_headers" | tail -n1)"
  case "$_http_code" in
    403|429)
      _die "GitHub API rate limit or access denied (HTTP ${_http_code}, remaining=${_remaining:-unknown}); set GITHUB_TOKEN"
      ;;
    *)
      _die "GitHub API returned HTTP ${_http_code}"
      ;;
  esac
fi

if ! _upstream_tag="$(python3 -c \
  'import json,sys; data=json.load(open(sys.argv[1])); tag=data["tag_name"]; assert isinstance(tag,str) and tag; print(tag)' \
  "$_body" 2>/dev/null)"; then
  _die "malformed GitHub API response (missing tag_name)"
fi

if [[ ! "$_upstream_tag" =~ ^v?([0-9]+(\.[0-9]+)+)$ ]]; then
  _die "unsupported release tag '${_upstream_tag}' (expected X.Y[.Z...] or vX.Y[.Z...])"
fi
_upstream_version="${BASH_REMATCH[1]}"
if [[ "$_upstream_tag" == v* ]]; then
  _tag_prefix="v"
fi

_cmp_up_current="$(_vercmp "$_upstream_version" "$_current_version")"

if (( _cmp_up_current < 0 )); then
  _emit up-to-date local-ahead "$EXIT_OK"
fi

if [[ -n "$_last_version" ]]; then
  _cmp_last_upstream="$(_vercmp "$_last_version" "$_upstream_version")"
else
  _cmp_last_upstream=-1
fi

if (( _cmp_up_current == 0 )); then
  if [[ -n "$_last_version" ]] && (( _cmp_last_upstream >= 0 )); then
    _emit up-to-date already-built "$EXIT_OK"
  fi
  _emit update-available no-successful-build-for-current-version "$EXIT_UPDATE"
fi

if (( _cmp_last_upstream >= 0 )); then
  _emit up-to-date already-built "$EXIT_OK"
fi

_emit update-available new-upstream-release "$EXIT_UPDATE"

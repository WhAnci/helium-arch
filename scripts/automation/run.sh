#!/usr/bin/env bash
# Safe, idempotent Helium package automation.
#
# This orchestrator builds a candidate package in an isolated workspace and
# publishes it to out/<pkgver>-<pkgrel>/ only after every required validation
# passes. It never installs the package, never uses sudo, never uploads
# anything, and never edits the canonical PKGBUILD/.SRCINFO.
#
# Usage:
#   scripts/automation/run.sh
#
# Environment:
#   HELIUM_REPO        repository root (default: two levels above this script)
#   HELIUM_WORK_ROOT   workspace root (default: $HELIUM_REPO/work)
#   HELIUM_SRCDEST     source download cache
#                      (default: ${XDG_CACHE_HOME:-$HOME/.cache}/helium-arch/srcdest)
#   HELIUM_OUT         published artifacts (default: $HELIUM_REPO/out)
#   HELIUM_STATE       lock/status files (default: $HELIUM_REPO/state)
#   HELIUM_LOG_DIR     run logs (default: $HELIUM_REPO/logs)
#   HELIUM_KEEP        successful versions to retain (default: 3)
#   HELIUM_FORCE=1     rebuild even when a successful manifest exists
#   HELIUM_VERSION=X   build a specific upstream version (skips the API check)
#   HELIUM_SANDBOX     auto (default) | skip | require
#   HELIUM_KEEP_WORK=1 keep a failed workspace for inspection
#
# Exit codes:
#   0   success, or no update available (nothing to do)
#   20  operational error (arguments, dependencies, upstream check, prepare)
#   30  build failed
#   40  validation failed (artifact, static tests, sandbox)
#   75  another run holds the lock
#
# Result semantics:
#   passed   the check ran and succeeded
#   failed   the check ran and failed (the run is aborted)
#   skipped  the check could not run; a reason is recorded
set -Eeuo pipefail

readonly AUTOMATION_VERSION="1"

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_default_repo="$(cd "${_script_dir}/../.." && pwd)"

_repo="${HELIUM_REPO:-$_default_repo}"
_repo="$(cd "$_repo" && pwd)"
_work_root="${HELIUM_WORK_ROOT:-${_repo}/work}"
_cache_dir="${HELIUM_SRCDEST:-${XDG_CACHE_HOME:-$HOME/.cache}/helium-arch/srcdest}"
_out_dir="${HELIUM_OUT:-${_repo}/out}"
_state_dir="${HELIUM_STATE:-${_repo}/state}"
_log_dir="${HELIUM_LOG_DIR:-${_repo}/logs}"
_keep="${HELIUM_KEEP:-3}"
_force="${HELIUM_FORCE:-0}"
_sandbox_mode="${HELIUM_SANDBOX:-auto}"
_version_override="${HELIUM_VERSION:-}"
_keep_work="${HELIUM_KEEP_WORK:-0}"

_status_written=0
_work_dir=""
_publish_tmp=""
_upstream_version=""
_upstream_tag=""
_package_version=""
_manifest_path=""
_latest_path=""

_usage() {
  cat <<'EOF'
Usage: run.sh

Runs one automation attempt. See docs/AUTOMATION.md for configuration,
exit codes, and output layout.
EOF
}

if (( $# > 0 )); then
  case "$1" in
    -h|--help)
      _usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      _usage >&2
      exit 20
      ;;
  esac
fi

if (( EUID == 0 )); then
  echo 'error: run as an unprivileged user; makepkg must not run as root' >&2
  exit 20
fi

if [[ ! "$_keep" =~ ^[0-9]+$ ]] || (( _keep < 1 )); then
  echo "error: HELIUM_KEEP must be a positive integer" >&2
  exit 20
fi
case "$_force" in
  0|1) ;;
  *)
    echo "error: HELIUM_FORCE must be 0 or 1" >&2
    exit 20
    ;;
esac
case "$_sandbox_mode" in
  auto|skip|require) ;;
  *)
    echo "error: HELIUM_SANDBOX must be auto, skip, or require" >&2
    exit 20
    ;;
esac

for _cmd in python3 flock bsdtar sha256sum curl gpg makepkg updpkgsums; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "error: required command not found: $_cmd" >&2
    exit 20
  fi
done

mkdir -p "$_work_root" "$_cache_dir" "$_state_dir" "$_log_dir"

exec 9>"${_state_dir}/lock"
if ! flock -n 9; then
  echo 'error: another automation run holds the lock' >&2
  exit 75
fi

_run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
_log_file="${_log_dir}/${_run_id}.log"
: >"$_log_file"
exec > >(tee -a "$_log_file") 2>&1

_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

_json_get() {
  python3 - "$1" "$2" <<'PY'
import json
import os
import sys

path, dotted = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
for part in dotted.split("."):
    if not isinstance(value, dict):
        raise SystemExit(1)
    value = value.get(part)
if value is None:
    print()
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

_write_status() {
  local result="$1" stage="$2" message="$3"

  ST_FILE="${_state_dir}/status.json" \
  ST_RESULT="$result" \
  ST_STAGE="$stage" \
  ST_MESSAGE="$message" \
  ST_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  ST_AUTOMATION_VERSION="$AUTOMATION_VERSION" \
  ST_RUN_ID="$_run_id" \
  ST_UPSTREAM_VERSION="$_upstream_version" \
  ST_PACKAGE_VERSION="$_package_version" \
  ST_MANIFEST_PATH="$_manifest_path" \
  ST_LOG_FILE="$_log_file" \
  ST_LATEST_PATH="$_latest_path" \
  python3 <<'PY'
import json
import os

target = os.environ["ST_FILE"]
payload = {
    "automation_version": os.environ["ST_AUTOMATION_VERSION"],
    "run_id": os.environ["ST_RUN_ID"],
    "timestamp": os.environ["ST_TIME"],
    "result": os.environ["ST_RESULT"],
    "stage": os.environ["ST_STAGE"],
    "message": os.environ["ST_MESSAGE"],
    "upstream_version": os.environ["ST_UPSTREAM_VERSION"] or None,
    "package_version": os.environ["ST_PACKAGE_VERSION"] or None,
    "manifest": os.environ["ST_MANIFEST_PATH"] or None,
    "log": os.environ["ST_LOG_FILE"],
    "latest": os.environ["ST_LATEST_PATH"] or None,
}
temporary = target + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, target)
PY
  _status_written=1
}

_fail() {
  local code="$1" stage="$2" message="$3"
  echo "ERROR [${stage}] ${message}" >&2
  _write_status failed "$stage" "$message" || true
  exit "$code"
}

_error() {
  local code="$1" stage="$2" message="$3"
  echo "ERROR [${stage}] ${message}" >&2
  _write_status error "$stage" "$message" || true
  exit "$code"
}

_on_err() {
  local rc="$1"
  (( rc == 0 )) && return 0
  (( _status_written == 0 )) || return 0
  echo "ERROR: unexpected command failure (exit ${rc})" >&2 || true
  _write_status error unexpected "unexpected command failure (exit ${rc})" || true
}

_cleanup() {
  local rc=$?
  if [[ -n "$_publish_tmp" && -d "$_publish_tmp" ]]; then
    rm -rf "$_publish_tmp"
  fi
  # The workspace is reproducible from the cache and the canonical PKGBUILD.
  # Keep it only when explicitly requested (useful after a failure).
  if [[ "$_keep_work" != 1 ]] && [[ -n "$_work_dir" && -d "$_work_dir" ]]; then
    rm -rf "$_work_dir"
  fi
  exit "$rc"
}

trap '_on_err $?' ERR
trap _cleanup EXIT

echo "==> Helium automation ${AUTOMATION_VERSION} (run ${_run_id})"
echo "    repo:  ${_repo}"
echo "    cache: ${_cache_dir}"
echo "    out:   ${_out_dir}"

# ---------------------------------------------------------------------------
# 1. Upstream check
# ---------------------------------------------------------------------------
_check_json="${_state_dir}/check-${_run_id}.json"
if [[ -n "$_version_override" ]]; then
  if [[ ! "$_version_override" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    _error 20 check "invalid HELIUM_VERSION: ${_version_override}"
  fi
  _upstream_version="$_version_override"
  _upstream_tag="$_version_override"
  echo "==> using requested version ${_upstream_version} (API check skipped)"
else
  # A non-zero exit (10 = update available) is expected. Keeping the command
  # in an if-condition prevents the ERR trap from treating it as a failure.
  if "$_repo/scripts/check-upstream.sh" --json >"$_check_json"; then
    _check_rc=0
  else
    _check_rc=$?
  fi

  case "$_check_rc" in
    0|10) ;;
    *)
      _error 20 check "upstream version check failed (exit ${_check_rc})"
      ;;
  esac

  _upstream_version="$(_json_get "$_check_json" upstream_version)" ||
    _error 20 check "cannot parse upstream check output"
  _upstream_tag="$(_json_get "$_check_json" upstream_tag)" || _upstream_tag=""
  _check_reason="$(_json_get "$_check_json" reason)" || _check_reason=""

  if (( _check_rc == 0 )); then
    if [[ "$_check_reason" == "local-ahead" ]] && [[ "$_force" == 1 ]]; then
      _error 20 check "canonical pkgver is newer than upstream; refusing to force-build an older version"
    fi
    if [[ "$_force" != 1 ]]; then
      _package_version="$(sed -n 's/^pkgver=//p' "${_repo}/PKGBUILD" | head -n1)"
      _latest_path="$(readlink "${_out_dir}/latest" 2>/dev/null || true)"
      _manifest_path="$(_json_get "$_check_json" latest_manifest)" || _manifest_path=""
      echo "==> no update available (${_upstream_version:-unknown})"
      _write_status no-op check "no update available"
      exit 0
    fi
  fi
fi

if [[ -z "$_upstream_version" ]]; then
  _error 20 check "upstream version is empty"
fi
echo "==> target upstream version: ${_upstream_version}"

# ---------------------------------------------------------------------------
# 2. Idempotence: a successful build for this version already exists
# ---------------------------------------------------------------------------
_find_success_manifest() {
  python3 - "$_out_dir" "$1" <<'PY'
import glob
import json
import os
import sys

out_dir, wanted = sys.argv[1], sys.argv[2]
for path in sorted(glob.glob(os.path.join(out_dir, "*", "manifest.json"))):
    if os.path.islink(os.path.dirname(path)):
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        continue
    if data.get("result") != "success":
        continue
    if (data.get("upstream") or {}).get("version") == wanted:
        print(path)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

if [[ "$_force" != 1 ]]; then
  if _existing_manifest="$(_find_success_manifest "$_upstream_version")"; then
    _manifest_path="$_existing_manifest"
    _package_version="$(sed -n 's/^pkgver=//p' "${_repo}/PKGBUILD" | head -n1)"
    _latest_path="$(readlink "${_out_dir}/latest" 2>/dev/null || true)"
    echo "==> successful build already published: ${_existing_manifest}"
    echo "    use HELIUM_FORCE=1 to rebuild"
    _write_status no-op idempotent "successful build already exists for version ${_upstream_version}"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 3. Prepare an isolated candidate workspace
# ---------------------------------------------------------------------------
_work_dir="${_work_root}/${_run_id}"
mkdir -p "$_work_dir"
cp -p "${_repo}/PKGBUILD" "${_work_dir}/PKGBUILD"
_gpg_dir="${_work_dir}/gnupg"
mkdir -p "$_gpg_dir"
chmod 700 "$_gpg_dir"

echo "==> preparing candidate in ${_work_dir}"
if ! "$_repo/scripts/update.sh" \
  --workdir "$_work_dir" \
  --cache "$_cache_dir" \
  --gnupg "$_gpg_dir" \
  "$_upstream_version"; then
  _fail 20 prepare "update.sh failed (signature, download, or checksum problem)"
fi

_package_version="$(sed -n 's/^pkgver=//p' "${_work_dir}/PKGBUILD" | head -n1)"
_package_release="$(sed -n 's/^pkgrel=//p' "${_work_dir}/PKGBUILD" | head -n1)"

if [[ "$_package_version" != "$_upstream_version" ]]; then
  _fail 20 prepare "workspace pkgver ${_package_version} does not match upstream ${_upstream_version}"
fi
if [[ ! "$_package_release" =~ ^[0-9]+$ ]]; then
  _fail 20 prepare "workspace pkgrel is invalid: ${_package_release}"
fi

# ---------------------------------------------------------------------------
# 4. Build
# ---------------------------------------------------------------------------
echo "==> building helium-bin ${_package_version}-${_package_release}"
if ! (
  cd "$_work_dir"
  BUILD_WORKDIR="$_work_dir" \
  BUILD_SRCDEST="$_cache_dir" \
  BUILD_PKGDEST="$_work_dir" \
  BUILD_GNUPG="$_gpg_dir" \
  "$_repo/scripts/build.sh" -f --nodeps --noconfirm
); then
  _fail 30 build "makepkg failed"
fi

_artifact="${_work_dir}/helium-bin-${_package_version}-${_package_release}-x86_64.pkg.tar.zst"
if [[ ! -f "$_artifact" ]]; then
  _fail 40 artifact "expected artifact not found: ${_artifact}"
fi

# ---------------------------------------------------------------------------
# 5. Artifact and metadata consistency
# ---------------------------------------------------------------------------
if ! bsdtar -tf "$_artifact" >/dev/null; then
  _fail 40 artifact "package archive is not readable"
fi

_pkginfo="$(bsdtar -xOf "$_artifact" .PKGINFO 2>/dev/null)" ||
  _fail 40 artifact "package has no .PKGINFO"
if ! grep -qx 'pkgname = helium-bin' <<<"$_pkginfo"; then
  _fail 40 artifact "PKGINFO pkgname mismatch"
fi
if ! grep -qx "pkgver = ${_package_version}-${_package_release}" <<<"$_pkginfo"; then
  _fail 40 artifact "PKGINFO pkgver mismatch"
fi
if ! grep -qx 'arch = x86_64' <<<"$_pkginfo"; then
  _fail 40 artifact "PKGINFO arch mismatch"
fi

if ! grep -Eq "^[[:space:]]*pkgver = ${_package_version}$" "${_work_dir}/.SRCINFO"; then
  _fail 40 artifact ".SRCINFO pkgver mismatch"
fi
if ! grep -Eq "^[[:space:]]*pkgrel = ${_package_release}$" "${_work_dir}/.SRCINFO"; then
  _fail 40 artifact ".SRCINFO pkgrel mismatch"
fi
if ! grep -qx 'pkgbase = helium-bin' "${_work_dir}/.SRCINFO"; then
  _fail 40 artifact ".SRCINFO pkgbase mismatch"
fi

_artifact_sha="$(sha256sum "$_artifact" | awk '{print $1}')"
echo "==> artifact: $(basename "$_artifact") (sha256 ${_artifact_sha})"

# ---------------------------------------------------------------------------
# 6. Static validation
# ---------------------------------------------------------------------------
echo '==> static checks: bash -n'
_bash_files=("${_repo}/PKGBUILD")
shopt -s nullglob
_bash_files+=("${_repo}"/scripts/*.sh "${_repo}"/scripts/automation/*.sh)
_bash_files+=("${_repo}"/tests/*.sh "${_repo}"/tests/automation/*.sh)
shopt -u nullglob
for _file in "${_bash_files[@]}"; do
  if ! bash -n "$_file"; then
    _fail 40 validation "bash syntax check failed: ${_file}"
  fi
done

echo '==> static checks: shellcheck'
_shellcheck_status="passed"
_shellcheck_reason=""
if command -v shellcheck >/dev/null 2>&1; then
  shopt -s nullglob
  _sc_files=("${_repo}"/scripts/*.sh "${_repo}"/scripts/automation/*.sh)
  _sc_files+=("${_repo}"/tests/*.sh "${_repo}"/tests/automation/*.sh)
  shopt -u nullglob
  if ! shellcheck -S warning "${_sc_files[@]}"; then
    _fail 40 validation "shellcheck reported warnings"
  fi
else
  _shellcheck_status="skipped"
  _shellcheck_reason="shellcheck-not-installed"
  echo "    SKIPPED: ${_shellcheck_reason}"
fi

echo '==> static checks: namcap'
_namcap_status="passed"
_namcap_reason=""
if command -v namcap >/dev/null 2>&1; then
  if ! namcap "$_artifact"; then
    _fail 40 validation "namcap reported errors"
  fi
else
  _namcap_status="skipped"
  _namcap_reason="namcap-not-installed"
  echo "    SKIPPED: ${_namcap_reason}"
fi

echo '==> package checks: tests/check-package.sh'
if ! "$_repo/tests/check-package.sh" "$_artifact"; then
  _fail 40 validation "package content validation failed"
fi

# ---------------------------------------------------------------------------
# 7. Sandbox validation
# ---------------------------------------------------------------------------
_probe_sandbox() {
  local max_namespaces clone
  if (( EUID == 0 )); then
    echo 'running-as-root'
    return 1
  fi
  if [[ ! -r /proc/sys/user/max_user_namespaces ]]; then
    echo 'userns-counter-unavailable'
    return 1
  fi
  max_namespaces="$(cat /proc/sys/user/max_user_namespaces)"
  if [[ ! "$max_namespaces" =~ ^[0-9]+$ ]] || (( max_namespaces < 1 )); then
    echo 'userns-disabled'
    return 1
  fi
  if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]]; then
    clone="$(cat /proc/sys/kernel/unprivileged_userns_clone)"
    if [[ "$clone" == 0 ]]; then
      echo 'userns-restricted'
      return 1
    fi
  fi
  if ! grep -q '^Seccomp:' /proc/self/status; then
    echo 'seccomp-unavailable'
    return 1
  fi
  if ! command -v unshare >/dev/null 2>&1; then
    echo 'unshare-not-installed'
    return 1
  fi
  if ! unshare -Ur true 2>/dev/null; then
    echo 'userns-unshare-failed'
    return 1
  fi
  echo ''
  return 0
}

_sandbox_status="skipped"
_sandbox_reason=""

if [[ "$_sandbox_mode" == "skip" ]]; then
  _sandbox_reason="disabled-by-configuration (HELIUM_SANDBOX=skip)"
  echo "==> sandbox check skipped: ${_sandbox_reason}"
else
  if _probe_reason="$(_probe_sandbox)"; then
    echo '==> sandbox check: running tests/check-sandbox.sh'
    _extract_dir="${_work_dir}/extract"
    mkdir -p "$_extract_dir"
    if ! bsdtar -xf "$_artifact" -C "$_extract_dir"; then
      _fail 40 sandbox "cannot extract package for sandbox test"
    fi
    _sandbox_bin="${_extract_dir}/usr/lib/helium/helium"
    if timeout 180 "$_repo/tests/check-sandbox.sh" "$_sandbox_bin"; then
      _sandbox_rc=0
    else
      _sandbox_rc=$?
    fi
    if (( _sandbox_rc == 0 )); then
      _sandbox_status="passed"
    elif (( _sandbox_rc == 124 )); then
      _fail 40 sandbox "sandbox test timed out"
    else
      _fail 40 sandbox "sandbox test failed (exit ${_sandbox_rc})"
    fi
  else
    _sandbox_reason="environment-unsupported: ${_probe_reason}"
    if [[ "$_sandbox_mode" == "require" ]]; then
      _fail 40 sandbox "sandbox test required but cannot run: ${_probe_reason}"
    fi
    echo "==> sandbox check skipped: ${_sandbox_reason}"
  fi
fi

# ---------------------------------------------------------------------------
# 8. Manifest
# ---------------------------------------------------------------------------
_manifest_file="${_work_dir}/manifest.json"
_published_dir="${_package_version}-${_package_release}"

MF_FILE="$_manifest_file" \
MF_AUTOMATION_VERSION="$AUTOMATION_VERSION" \
MF_RUN_ID="$_run_id" \
MF_STARTED="$_started_at" \
MF_FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
MF_UPSTREAM_VERSION="$_upstream_version" \
MF_UPSTREAM_TAG="$_upstream_tag" \
MF_PKGVER="$_package_version" \
MF_PKGREL="$_package_release" \
MF_FILENAME="$(basename "$_artifact")" \
MF_SHA256="$_artifact_sha" \
MF_PUBLISHED_DIR="$_published_dir" \
MF_SHELLCHECK="$_shellcheck_status" \
MF_SHELLCHECK_REASON="$_shellcheck_reason" \
MF_NAMCAP="$_namcap_status" \
MF_NAMCAP_REASON="$_namcap_reason" \
MF_SANDBOX="$_sandbox_status" \
MF_SANDBOX_REASON="$_sandbox_reason" \
python3 <<'PY'
import json
import os

def value(name):
    return os.environ[name] or None

payload = {
    "automation_version": os.environ["MF_AUTOMATION_VERSION"],
    "run_id": os.environ["MF_RUN_ID"],
    "started_at": os.environ["MF_STARTED"],
    "finished_at": os.environ["MF_FINISHED"],
    "result": "success",
    "upstream": {
        "version": os.environ["MF_UPSTREAM_VERSION"],
        "tag": os.environ["MF_UPSTREAM_TAG"],
        "url": "https://github.com/imputnet/helium-linux/releases/tag/"
        + os.environ["MF_UPSTREAM_TAG"],
    },
    "package": {
        "name": "helium-bin",
        "version": os.environ["MF_PKGVER"],
        "release": os.environ["MF_PKGREL"],
        "arch": "x86_64",
    },
    "artifact": {
        "filename": os.environ["MF_FILENAME"],
        "sha256": os.environ["MF_SHA256"],
        "path": os.environ["MF_PUBLISHED_DIR"] + "/" + os.environ["MF_FILENAME"],
    },
    "validation": {
        "signature": "passed",
        "checksums": "passed",
        "metadata": "passed",
    },
    "tests": {
        "bash_syntax": {"status": "passed"},
        "shellcheck": {
            "status": os.environ["MF_SHELLCHECK"],
            "reason": value("MF_SHELLCHECK_REASON"),
        },
        "namcap": {
            "status": os.environ["MF_NAMCAP"],
            "reason": value("MF_NAMCAP_REASON"),
        },
        "package_content": {"status": "passed"},
        "sandbox": {
            "status": os.environ["MF_SANDBOX"],
            "reason": value("MF_SANDBOX_REASON"),
        },
    },
}
with open(os.environ["MF_FILE"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

# ---------------------------------------------------------------------------
# 9. Atomic publication
# ---------------------------------------------------------------------------
mkdir -p "$_out_dir"
_final_dir="${_out_dir}/${_published_dir}"
_publish_tmp="${_out_dir}/.tmp-${_run_id}"
_old_dir=""

mkdir -p "$_publish_tmp"
cp -p "$_artifact" "$_publish_tmp/"
cp -p "${_work_dir}/PKGBUILD" "${_work_dir}/.SRCINFO" "$_manifest_file" "$_publish_tmp/"

if [[ -e "$_final_dir" ]]; then
  if [[ "$_force" != 1 ]]; then
    _fail 40 publish "destination already exists: ${_final_dir}"
  fi
  _old_dir="${_out_dir}/.old-${_run_id}"
  mv "$_final_dir" "$_old_dir" ||
    _fail 40 publish "cannot move existing destination aside"
fi

if ! mv "$_publish_tmp" "$_final_dir"; then
  if [[ -n "$_old_dir" && -d "$_old_dir" ]]; then
    mv "$_old_dir" "$_final_dir"
  fi
  _fail 40 publish "atomic rename failed"
fi
_publish_tmp=""

if ! ln -s "$_published_dir" "${_out_dir}/.latest-${_run_id}"; then
  _fail 40 publish "cannot create latest symlink"
fi
if ! mv -Tf "${_out_dir}/.latest-${_run_id}" "${_out_dir}/latest"; then
  _fail 40 publish "cannot update latest symlink"
fi
_latest_path="$(readlink "${_out_dir}/latest" 2>/dev/null || true)"
_manifest_path="${_final_dir}/manifest.json"

if [[ -n "$_old_dir" && -d "$_old_dir" ]]; then
  rm -rf "$_old_dir"
fi

# Retention is best effort: a cleanup failure must not invalidate a good build.
_retain_old() {
  python3 - "$_out_dir" "$_keep" <<'PY'
import glob
import json
import os
import sys

out_dir = os.environ["OUT_DIR"] if "OUT_DIR" in os.environ else sys.argv[1]
keep = int(sys.argv[2])
latest = ""
link = os.path.join(out_dir, "latest")
try:
    latest = os.path.basename(os.readlink(link))
except OSError:
    latest = ""

entries = []
for path in glob.glob(os.path.join(out_dir, "*", "manifest.json")):
    directory = os.path.dirname(path)
    name = os.path.basename(directory)
    if name.startswith(".") or name == "latest":
        continue
    # glob() follows the "latest" symlink, which would otherwise be counted as
    # an extra entry and cause an older real directory to be pruned too early.
    if os.path.islink(directory):
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        continue
    if data.get("result") != "success":
        continue
    if "automation_version" not in data:
        continue
    try:
        mtime = os.stat(directory).st_mtime
    except OSError:
        continue
    entries.append((mtime, name))

entries.sort(reverse=True)
remove = []
for index, (_, name) in enumerate(entries):
    if index < keep:
        continue
    if name == latest:
        continue
    remove.append(name)

print("\n".join(remove))
PY
}

if ! _remove_list="$(_retain_old)"; then
  echo 'warning: retention scan failed; keeping all artifacts'
else
  while IFS= read -r _old_name; do
    [[ -z "$_old_name" ]] && continue
    if [[ "$_old_name" == "$_published_dir" ]]; then
      continue
    fi
    echo "==> retention: removing ${_old_name}"
    rm -rf "${_out_dir:?}/${_old_name}"
  done <<<"$_remove_list"
fi

echo
echo "==> success: ${_published_dir}"
echo "    package:  ${_final_dir}/$(basename "$_artifact")"
echo "    manifest: ${_final_dir}/manifest.json"
echo "    latest:   ${_out_dir}/latest -> ${_published_dir}"
echo "    install (manual, not performed): sudo pacman -U ${_final_dir}/$(basename "$_artifact")"

_write_status success publish "published ${_published_dir}"
exit 0

#!/usr/bin/env bash
# Shared helpers for the automation orchestration tests.
#
# The helpers build a throwaway repository containing the real orchestration
# scripts but a minimal fake PKGBUILD, stub validation tests, and a mock PATH.
# Nothing here touches the real repository's PKGBUILD, artifacts, or output
# directories.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO="$(cd "${TESTS_DIR}/../.." && pwd)"
MOCKS_DIR="${TESTS_DIR}/mocks"
TEST_TMP_ROOT="${TEST_TMP_ROOT:-/tmp/opencode/helium-automation-tests}"

PASS=0
FAIL=0
CURRENT_TEST=""
FAILED_TESTS=()
TEST_ROOT=""

init_test_env() {
  mkdir -p "$TEST_TMP_ROOT"
  TEST_ROOT="$(mktemp -d "${TEST_TMP_ROOT}/run.XXXXXX")"
}

cleanup_test_env() {
  [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] || return 0
  if (( FAIL > 0 )) || [[ "${KEEP_TEST_TMP:-0}" == "1" ]]; then
    echo "kept test directory: ${TEST_ROOT}"
    return 0
  fi
  rm -rf "$TEST_ROOT"
}

begin_test() {
  CURRENT_TEST="$1"
  printf '\n== %s\n' "$CURRENT_TEST"
}

pass() {
  PASS=$((PASS + 1))
  printf '  ok: %s\n' "$*"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("${CURRENT_TEST}: $*")
  printf '  FAIL: %s\n' "$*" >&2
}

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label (expected '${expected}', got '${actual}')"
  fi
}

check_ne() {
  local label="$1" not_expected="$2" actual="$3"
  if [[ "$not_expected" != "$actual" ]]; then
    pass "$label"
  else
    fail "$label (did not expect '${actual}')"
  fi
}

check_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (missing '${needle}')"
  fi
}

check_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (unexpected '${needle}')"
  fi
}

check_file() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label (missing file ${path})"
  fi
}

check_executable() {
  local label="$1" path="$2"
  if [[ -x "$path" ]]; then
    pass "$label"
  else
    fail "$label (not executable: ${path})"
  fi
}

check_absent() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    pass "$label"
  else
    fail "$label (unexpected path ${path})"
  fi
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, dotted = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)
for part in dotted.split("."):
    if not isinstance(value, dict):
        value = None
        break
    value = value.get(part)
if value is None:
    print()
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

canonical_digest() {
  local repo="$1"
  {
    sha256sum "${repo}/PKGBUILD"
    if [[ -f "${repo}/.SRCINFO" ]]; then
      sha256sum "${repo}/.SRCINFO"
    fi
  } | sha256sum | awk '{print $1}'
}

published_count() {
  local repo="$1"
  find "${repo}/out" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l
}

# Create a fake repository. Prints its path.
new_repo() {
  local version="${1:-0.1.0}"
  local repo
  repo="$(mktemp -d "${TEST_ROOT}/case.XXXXXX")"

  mkdir -p "$repo"/scripts/automation "$repo"/tests "$repo"/keys/pgp
  mkdir -p "$repo"/out "$repo"/work "$repo"/state "$repo"/logs "$repo"/cache

  cp "${SOURCE_REPO}/scripts/build.sh" "$repo/scripts/build.sh"
  cp "${SOURCE_REPO}/scripts/update.sh" "$repo/scripts/update.sh"
  cp "${SOURCE_REPO}/scripts/check-upstream.sh" "$repo/scripts/check-upstream.sh"
  cp "${SOURCE_REPO}/scripts/automation/run.sh" "$repo/scripts/automation/run.sh"
  chmod 755 "$repo/scripts/build.sh" "$repo/scripts/update.sh" \
    "$repo/scripts/check-upstream.sh" "$repo/scripts/automation/run.sh"

  printf 'fake upstream signing key\n' \
    >"$repo/keys/pgp/BE677C1989D35EAB2C5F26C9351601AD01D6378E.asc"

  cat >"$repo/PKGBUILD" <<EOF
pkgname=helium-bin
_pkgname=helium
pkgver=${version}
pkgrel=1
pkgdesc='Fake Helium package for orchestration tests'
arch=('x86_64')
url='https://example.invalid/helium'
license=('GPL-3.0-only')
makedepends=('curl' 'gnupg')

source=(
  "\${_pkgname}-\${pkgver}-x86_64_linux.tar.xz::https://example.invalid/releases/download/\${pkgver}/\${_pkgname}-\${pkgver}-x86_64_linux.tar.xz"
  "\${_pkgname}-\${pkgver}-x86_64_linux.tar.xz.asc::https://example.invalid/releases/download/\${pkgver}/\${_pkgname}-\${pkgver}-x86_64_linux.tar.xz.asc"
  "helium-LICENSE::https://example.invalid/raw/\${pkgver}/LICENSE"
  "helium-LICENSE.ungoogled_chromium::https://example.invalid/raw/\${pkgver}/LICENSE.ungoogled_chromium"
  "net.imput.helium.metainfo.xml::https://example.invalid/raw/\${pkgver}/package/net.imput.helium.metainfo.xml"
)

sha256sums=('0000000000000000000000000000000000000000000000000000000000000000'
            '1111111111111111111111111111111111111111111111111111111111111111'
            '2222222222222222222222222222222222222222222222222222222222222222'
            '3333333333333333333333333333333333333333333333333333333333333333'
            '4444444444444444444444444444444444444444444444444444444444444444')

validpgpkeys=('BE677C1989D35EAB2C5F26C9351601AD01D6378E')
EOF

  cat >"$repo/tests/check-package.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_PACKAGE_FAIL:-0}" == "1" ]]; then
  echo 'fake check-package: simulated failure' >&2
  exit 1
fi
pkg="${1:?artifact path required}"
bsdtar -tf "$pkg" | grep -qx 'usr/lib/helium/helium'
echo 'fake check-package: PASS'
EOF

  cat >"$repo/tests/check-sandbox.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_SANDBOX_FAIL:-0}" == "1" ]]; then
  echo 'fake check-sandbox: simulated failure' >&2
  exit 1
fi
[[ -x "${1:-}" ]] || { echo 'fake check-sandbox: binary not executable' >&2; exit 1; }
echo 'fake check-sandbox: PASS'
EOF

  chmod 755 "$repo/tests/check-package.sh" "$repo/tests/check-sandbox.sh"
  printf '%s\n' "$repo"
}

# Run the orchestrator against a fake repository. Reads FAKE_* and HELIUM_*
# variables from the exported environment; extra arguments are env assignments.
run_runner() {
  local repo="$1"
  shift
  env PATH="${MOCKS_DIR}:${PATH}" \
    HELIUM_REPO="$repo" \
    HELIUM_WORK_ROOT="${repo}/work" \
    HELIUM_SRCDEST="${repo}/cache" \
    HELIUM_OUT="${repo}/out" \
    HELIUM_STATE="${repo}/state" \
    HELIUM_LOG_DIR="${repo}/logs" \
    HELIUM_SANDBOX="${HELIUM_SANDBOX:-skip}" \
    "$@" \
    "${repo}/scripts/automation/run.sh"
}

# Run the read-only upstream check against a fake repository.
run_check() {
  local repo="$1"
  shift
  env PATH="${MOCKS_DIR}:${PATH}" \
    "${repo}/scripts/check-upstream.sh" --repo "$repo" "$@"
}

write_success_manifest() {
  local repo="$1" version="$2" directory="${2}-1"
  mkdir -p "${repo}/out/${directory}"
  cat >"${repo}/out/${directory}/manifest.json" <<EOF
{
  "automation_version": "1",
  "result": "success",
  "upstream": {"version": "${version}"},
  "package": {"version": "${version}", "release": "1"}
}
EOF
  ln -sfn "$directory" "${repo}/out/latest"
}

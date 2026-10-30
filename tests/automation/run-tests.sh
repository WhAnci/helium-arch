#!/usr/bin/env bash
# Focused tests for scripts/automation/run.sh, scripts/check-upstream.sh, and
# their failure paths. Everything runs in throwaway directories with mocked
# network, GPG, makepkg, shellcheck, and namcap commands.
set -uo pipefail

# shellcheck source=tests/automation/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REAL_PKGBUILD_DIGEST=""
REAL_ARTIFACT_SHA=""
REAL_ARTIFACT=""

reset_fakes() {
  unset FAKE_CURL_FAIL FAKE_HTTP_CODE FAKE_TAG FAKE_API_BODY FAKE_PGP_FAIL \
    FAKE_BUILD_FAIL FAKE_NAMCAP_FAIL FAKE_SHELLCHECK_FAIL FAKE_PACKAGE_FAIL \
    FAKE_SANDBOX_FAIL HELIUM_FORCE HELIUM_VERSION HELIUM_SANDBOX \
    HELIUM_KEEP_WORK
}

test_no_update() {
  begin_test "no update available"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.1.0)"
  write_success_manifest "$repo" 0.1.0
  export FAKE_TAG=v0.1.0

  out="$(run_check "$repo" --json 2>&1)"
  rc=$?
  check_eq "check-upstream exit code" 0 "$rc"
  check_contains "check reports up-to-date" "$out" '"status": "up-to-date"'
  check_contains "check reports already built" "$out" '"reason": "already-built"'

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 0 "$rc"
  check_contains "orchestrator reports no update" "$out" "no update available"
  check_eq "status result" "no-op" "$(json_get "${repo}/state/status.json" result)"
  check_eq "status stage" "check" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "nothing published" 1 "$(published_count "$repo")"
  reset_fakes
}

test_new_release() {
  begin_test "new release detected"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.1.0)"
  export FAKE_TAG=v0.2.0

  out="$(run_check "$repo" --json 2>&1)"
  rc=$?
  check_eq "check-upstream exit code" 10 "$rc"
  check_contains "status is update-available" "$out" '"status": "update-available"'
  check_contains "reason is new-upstream-release" "$out" '"reason": "new-upstream-release"'
  check_contains "v prefix is reported" "$out" '"tag_prefix": "v"'
  check_contains "version is normalized" "$out" '"upstream_version": "0.2.0"'
  check_eq "no artifacts created" 0 "$(published_count "$repo")"
  reset_fakes
}

test_api_failure() {
  begin_test "API / network failure"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.1.0)"
  export FAKE_CURL_FAIL=1

  out="$(run_check "$repo" --json 2>&1)"
  rc=$?
  check_eq "check-upstream exit code" 20 "$rc"
  check_contains "status is error" "$out" '"status": "error"'
  check_contains "curl failure is reported" "$out" "curl exit 7"

  unset FAKE_CURL_FAIL
  export FAKE_HTTP_CODE=403
  out="$(run_check "$repo" --json 2>&1)"
  rc=$?
  check_eq "rate limit exit code" 20 "$rc"
  check_contains "rate limit is reported" "$out" "rate limit"

  unset FAKE_HTTP_CODE
  export FAKE_API_BODY='{"message":"not a release"}'
  out="$(run_check "$repo" --json 2>&1)"
  rc=$?
  check_eq "malformed response exit code" 20 "$rc"
  check_contains "malformed response is reported" "$out" "malformed GitHub API response"
  unset FAKE_API_BODY

  export FAKE_CURL_FAIL=1
  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 20 "$rc"
  check_eq "status result" "error" "$(json_get "${repo}/state/status.json" result)"
  check_eq "status stage" "check" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "no artifacts created" 0 "$(published_count "$repo")"
  reset_fakes
}

test_invalid_version() {
  begin_test "invalid release version"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.1.0)"
  export FAKE_TAG=vnext

  out="$(run_check "$repo" --json 2>&1)"
  rc=$?
  check_eq "check-upstream exit code" 20 "$rc"
  check_contains "invalid tag is reported" "$out" "unsupported release tag"

  export HELIUM_VERSION=v1.2.3
  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator rejects invalid HELIUM_VERSION" 20 "$rc"
  check_contains "invalid override is reported" "$out" "invalid HELIUM_VERSION"
  reset_fakes
}

test_force_downgrade_guard() {
  begin_test "force rebuild refuses to downgrade below the canonical pkgver"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.3.0)"
  export FAKE_TAG=v0.2.0 HELIUM_FORCE=1

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 20 "$rc"
  check_contains "downgrade is refused" "$out" "refusing to force-build an older version"
  check_eq "status stage" "check" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "no artifacts created" 0 "$(published_count "$repo")"
  reset_fakes
}

test_update_check_only() {
  begin_test "update.sh check-only mode modifies nothing"
  reset_fakes
  local repo out rc digest

  repo="$(new_repo 0.1.0)"
  digest="$(canonical_digest "$repo")"

  out="$(env PATH="${MOCKS_DIR}:${PATH}" \
    "${repo}/scripts/update.sh" --workdir "$repo" --cache "${repo}/cache" \
    --gnupg "${repo}/gnupg-check" --check 0.2.0 2>&1)"
  rc=$?
  check_eq "update.sh exit code" 0 "$rc"
  check_contains "check-only notice" "$out" "no files were modified"
  check_eq "canonical files are unchanged" "$digest" "$(canonical_digest "$repo")"
  check_absent "no .SRCINFO was created" "${repo}/.SRCINFO"
  check_file "release tarball cached" \
    "${repo}/cache/helium-0.2.0-x86_64_linux.tar.xz"
  check_file "signature cached" \
    "${repo}/cache/helium-0.2.0-x86_64_linux.tar.xz.asc"
  reset_fakes
}

test_pgp_failure() {
  begin_test "PGP verification failure"
  reset_fakes
  local repo out rc digest

  repo="$(new_repo 0.1.0)"
  digest="$(canonical_digest "$repo")"
  export HELIUM_VERSION=0.2.0 FAKE_PGP_FAIL=1

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 20 "$rc"
  check_contains "prepare failure is reported" "$out" "update.sh failed"
  check_eq "canonical PKGBUILD is unchanged" "$digest" "$(canonical_digest "$repo")"
  check_eq "status result" "failed" "$(json_get "${repo}/state/status.json" result)"
  check_eq "status stage" "prepare" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "no artifacts created" 0 "$(published_count "$repo")"
  reset_fakes
}

test_build_failure() {
  begin_test "build failure"
  reset_fakes
  local repo out rc digest

  repo="$(new_repo 0.1.0)"
  digest="$(canonical_digest "$repo")"
  export HELIUM_VERSION=0.2.0 FAKE_BUILD_FAIL=1

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 30 "$rc"
  check_contains "makepkg failure is reported" "$out" "makepkg failed"
  check_eq "status result" "failed" "$(json_get "${repo}/state/status.json" result)"
  check_eq "status stage" "build" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "canonical PKGBUILD is unchanged" "$digest" "$(canonical_digest "$repo")"
  check_eq "no artifacts created" 0 "$(published_count "$repo")"
  reset_fakes
}

test_namcap_failure() {
  begin_test "required static validation failure (namcap)"
  reset_fakes
  local repo out rc digest

  repo="$(new_repo 0.1.0)"
  digest="$(canonical_digest "$repo")"
  export HELIUM_VERSION=0.2.0 FAKE_NAMCAP_FAIL=1

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 40 "$rc"
  check_contains "namcap failure is reported" "$out" "namcap reported errors"
  check_eq "status result" "failed" "$(json_get "${repo}/state/status.json" result)"
  check_eq "status stage" "validation" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "canonical PKGBUILD is unchanged" "$digest" "$(canonical_digest "$repo")"
  check_eq "no artifacts created" 0 "$(published_count "$repo")"
  reset_fakes
}

test_package_failure() {
  begin_test "required package validation failure"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.1.0)"
  export HELIUM_VERSION=0.2.0 FAKE_PACKAGE_FAIL=1

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 40 "$rc"
  check_contains "package validation failure is reported" "$out" "package content validation failed"
  check_eq "status stage" "validation" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "no artifacts created" 0 "$(published_count "$repo")"
  reset_fakes
}

test_sandbox_skipped() {
  begin_test "sandbox test skipped"
  reset_fakes
  local repo out rc manifest

  repo="$(new_repo 0.1.0)"
  export HELIUM_VERSION=0.2.0 HELIUM_SANDBOX=skip

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 0 "$rc"
  check_contains "skip is announced" "$out" "sandbox check skipped"

  manifest="${repo}/out/0.2.0-1/manifest.json"
  check_file "manifest published" "$manifest"
  check_eq "sandbox status" "skipped" "$(json_get "$manifest" tests.sandbox.status)"
  check_contains "skip reason" "$(json_get "$manifest" tests.sandbox.reason)" \
    "disabled-by-configuration"
  check_eq "overall result" "success" "$(json_get "$manifest" result)"
  check_eq "shellcheck still ran" "passed" "$(json_get "$manifest" tests.shellcheck.status)"
  reset_fakes
}

test_successful_publication() {
  begin_test "successful publication"
  reset_fakes
  local repo out rc manifest directory artifact sha sandbox_status sandbox_reason expected_sha

  repo="$(new_repo 0.1.0)"
  export FAKE_TAG=v0.2.0 HELIUM_SANDBOX=auto

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 0 "$rc"
  check_not_contains "expected update exit does not trip the ERR trap" "$out" \
    "unexpected command failure"
  check_contains "publication is reported" "$out" "success: 0.2.0-1"

  directory="${repo}/out/0.2.0-1"
  manifest="${directory}/manifest.json"
  artifact="${directory}/helium-bin-0.2.0-1-x86_64.pkg.tar.zst"

  check_file "package archive published" "$artifact"
  check_file "candidate PKGBUILD published" "${directory}/PKGBUILD"
  check_file "candidate .SRCINFO published" "${directory}/.SRCINFO"
  check_file "manifest published" "$manifest"
  check_eq "latest points at the new version" "0.2.0-1" "$(readlink "${repo}/out/latest")"
  check_eq "one published version" 1 "$(published_count "$repo")"

  sha="$(sha256sum "$artifact" | awk '{print $1}')"
  expected_sha="$(json_get "$manifest" artifact.sha256)"
  check_eq "manifest artifact checksum matches" "$sha" "$expected_sha"
  check_eq "manifest artifact filename" "helium-bin-0.2.0-1-x86_64.pkg.tar.zst" \
    "$(json_get "$manifest" artifact.filename)"
  check_eq "manifest upstream version" "0.2.0" "$(json_get "$manifest" upstream.version)"
  check_eq "manifest upstream URL" \
    "https://github.com/imputnet/helium-linux/releases/tag/v0.2.0" \
    "$(json_get "$manifest" upstream.url)"
  check_eq "manifest package version" "0.2.0" "$(json_get "$manifest" package.version)"
  check_eq "manifest package release" "1" "$(json_get "$manifest" package.release)"
  check_eq "manifest signature validation" "passed" "$(json_get "$manifest" validation.signature)"
  check_eq "manifest overall result" "success" "$(json_get "$manifest" result)"
  check_eq "candidate PKGBUILD version" "0.2.0" \
    "$(sed -n 's/^pkgver=//p' "${directory}/PKGBUILD" | head -n1)"
  check_contains "candidate .SRCINFO version" \
    "$(cat "${directory}/.SRCINFO")" "pkgver = 0.2.0"
  check_eq "canonical PKGBUILD is unchanged" "0.1.0" \
    "$(sed -n 's/^pkgver=//p' "${repo}/PKGBUILD" | head -n1)"

  sandbox_status="$(json_get "$manifest" tests.sandbox.status)"
  case "$sandbox_status" in
    passed)
      pass "sandbox test passed and is recorded as passed"
      ;;
    skipped)
      sandbox_reason="$(json_get "$manifest" tests.sandbox.reason)"
      if [[ -n "$sandbox_reason" ]]; then
        pass "sandbox skipped with a recorded reason: ${sandbox_reason}"
      else
        fail "sandbox skipped without a reason"
      fi
      ;;
    *)
      fail "unexpected sandbox status: ${sandbox_status}"
      ;;
  esac

  check_eq "status result" "success" "$(json_get "${repo}/state/status.json" result)"
  check_eq "status stage" "publish" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "status manifest points at the published copy" "$manifest" \
    "$(json_get "${repo}/state/status.json" manifest)"
  check_eq "a log was written" 1 "$(find "${repo}/logs" -maxdepth 1 -name '*.log' | wc -l)"

  if [[ -n "$REAL_ARTIFACT" ]]; then
    check_eq "repository artifact untouched" "$REAL_ARTIFACT_SHA" \
      "$(sha256sum "$REAL_ARTIFACT" | awk '{print $1}')"
  fi
  reset_fakes
}

test_latest_preserved() {
  begin_test "latest preserved after a later failure"
  reset_fakes
  local repo out rc artifact

  repo="$(new_repo 0.1.0)"
  export HELIUM_VERSION=0.2.0

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "initial run succeeds" 0 "$rc"
  check_eq "latest points at 0.2.0-1" "0.2.0-1" "$(readlink "${repo}/out/latest")"
  artifact="${repo}/out/0.2.0-1/helium-bin-0.2.0-1-x86_64.pkg.tar.zst"
  check_file "initial artifact exists" "$artifact"

  export FAKE_BUILD_FAIL=1
  out="$(run_runner "$repo" HELIUM_VERSION=0.3.0 2>&1)"
  rc=$?
  check_eq "failing run exit code" 30 "$rc"
  check_eq "latest still points at 0.2.0-1" "0.2.0-1" "$(readlink "${repo}/out/latest")"
  check_file "previous artifact is preserved" "$artifact"
  check_absent "failed version is not published" "${repo}/out/0.3.0-1"
  check_eq "status records the failure" "failed" \
    "$(json_get "${repo}/state/status.json" result)"
  reset_fakes
}

test_lock_contention() {
  begin_test "concurrent-run lock handling"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.1.0)"
  exec 8>"${repo}/state/lock"
  flock -n 8

  out="$(run_runner "$repo" HELIUM_VERSION=0.2.0 2>&1)"
  rc=$?
  exec 8>&-
  check_eq "orchestrator exit code" 75 "$rc"
  check_contains "lock message" "$out" "another automation run holds the lock"
  check_eq "nothing published" 0 "$(published_count "$repo")"
  reset_fakes
}

test_idempotence() {
  begin_test "repeated execution is idempotent"
  reset_fakes
  local repo out rc before_latest before_count before_sha first_run second_run

  repo="$(new_repo 0.1.0)"
  export FAKE_TAG=v0.2.0

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "first run succeeds" 0 "$rc"
  before_latest="$(readlink "${repo}/out/latest")"
  before_count="$(published_count "$repo")"
  before_sha="$(sha256sum "${repo}/out/0.2.0-1/helium-bin-0.2.0-1-x86_64.pkg.tar.zst" | awk '{print $1}')"
  first_run="$(json_get "${repo}/out/0.2.0-1/manifest.json" run_id)"

  out="$(run_runner "$repo" HELIUM_VERSION=0.2.0 2>&1)"
  rc=$?
  check_eq "second run succeeds as a no-op" 0 "$rc"
  check_contains "second run announces idempotence" "$out" "already published"
  check_eq "status result" "no-op" "$(json_get "${repo}/state/status.json" result)"
  check_eq "status stage" "idempotent" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "latest is unchanged" "$before_latest" "$(readlink "${repo}/out/latest")"
  check_eq "published count is unchanged" "$before_count" "$(published_count "$repo")"
  check_eq "artifact checksum is unchanged" "$before_sha" \
    "$(sha256sum "${repo}/out/0.2.0-1/helium-bin-0.2.0-1-x86_64.pkg.tar.zst" | awk '{print $1}')"
  check_eq "manifest was not rewritten" "$first_run" \
    "$(json_get "${repo}/out/0.2.0-1/manifest.json" run_id)"
  reset_fakes
}

test_force_rebuild() {
  begin_test "forced rebuild replaces the published directory"
  reset_fakes
  local repo out rc first_run second_run

  repo="$(new_repo 0.1.0)"
  export FAKE_TAG=v0.2.0

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "initial run succeeds" 0 "$rc"
  first_run="$(json_get "${repo}/out/0.2.0-1/manifest.json" run_id)"

  export HELIUM_FORCE=1
  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "forced run succeeds" 0 "$rc"
  check_eq "status result" "success" "$(json_get "${repo}/state/status.json" result)"
  check_eq "still one published version" 1 "$(published_count "$repo")"
  check_eq "latest still points at 0.2.0-1" "0.2.0-1" "$(readlink "${repo}/out/latest")"
  second_run="$(json_get "${repo}/out/0.2.0-1/manifest.json" run_id)"
  check_ne "manifest was regenerated" "$first_run" "$second_run"
  check_absent "no temporary publish directory left" "${repo}/out/.tmp-${second_run}"
  reset_fakes
}

test_sandbox_failure() {
  begin_test "sandbox failure blocks publication"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.1.0)"
  export HELIUM_VERSION=0.2.0 HELIUM_SANDBOX=require FAKE_SANDBOX_FAIL=1

  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "orchestrator exit code" 40 "$rc"
  check_eq "status stage" "sandbox" "$(json_get "${repo}/state/status.json" stage)"
  check_eq "nothing published" 0 "$(published_count "$repo")"
  reset_fakes
}

test_retention() {
  begin_test "retention keeps the last three successful versions"
  reset_fakes
  local repo out rc

  repo="$(new_repo 0.1.0)"
  write_success_manifest "$repo" 0.2.0
  write_success_manifest "$repo" 0.3.0
  write_success_manifest "$repo" 0.4.0
  write_success_manifest "$repo" 0.5.0
  touch -d '2026-01-01 00:00:00' "${repo}/out/0.2.0-1"
  touch -d '2026-01-02 00:00:00' "${repo}/out/0.3.0-1"
  touch -d '2026-01-03 00:00:00' "${repo}/out/0.4.0-1"
  touch -d '2026-01-04 00:00:00' "${repo}/out/0.5.0-1"

  export HELIUM_VERSION=0.9.0
  out="$(run_runner "$repo" 2>&1)"
  rc=$?
  check_eq "publishing run succeeds" 0 "$rc"
  check_eq "three versions are retained" 3 "$(published_count "$repo")"
  check_file "newest version is kept" "${repo}/out/0.9.0-1/manifest.json"
  check_file "second newest is kept" "${repo}/out/0.5.0-1/manifest.json"
  check_file "third newest is kept" "${repo}/out/0.4.0-1/manifest.json"
  check_absent "oldest version is pruned" "${repo}/out/0.2.0-1"
  check_absent "second oldest version is pruned" "${repo}/out/0.3.0-1"
  check_eq "latest points at the new version" "0.9.0-1" "$(readlink "${repo}/out/latest")"
  reset_fakes
}

main() {
  init_test_env
  trap cleanup_test_env EXIT

  REAL_PKGBUILD_DIGEST="$(canonical_digest "$SOURCE_REPO")"
  REAL_ARTIFACT="$(ls -t "${SOURCE_REPO}"/helium-bin-*-x86_64.pkg.tar.zst 2>/dev/null | head -n1 || true)"
  if [[ -n "$REAL_ARTIFACT" ]]; then
    REAL_ARTIFACT_SHA="$(sha256sum "$REAL_ARTIFACT" | awk '{print $1}')"
  fi

  test_no_update
  test_new_release
  test_api_failure
  test_invalid_version
  test_force_downgrade_guard
  test_update_check_only
  test_pgp_failure
  test_build_failure
  test_namcap_failure
  test_package_failure
  test_sandbox_skipped
  test_successful_publication
  test_latest_preserved
  test_lock_contention
  test_idempotence
  test_force_rebuild
  test_retention
  test_sandbox_failure

  check_eq "real repository PKGBUILD/.SRCINFO unchanged" "$REAL_PKGBUILD_DIGEST" \
    "$(canonical_digest "$SOURCE_REPO")"

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  if (( FAIL > 0 )); then
    printf 'failed checks:\n' >&2
    printf '  - %s\n' "${FAILED_TESTS[@]}" >&2
    exit 1
  fi
  exit 0
}

main "$@"

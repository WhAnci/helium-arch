#!/usr/bin/env bash
# Launch Helium headlessly and verify that renderer processes are sandboxed
# (seccomp filter + user namespace). Run as a normal user, not root.
set -euo pipefail

_bin="${1:-/usr/lib/helium/helium}"
if [[ ! -x "$_bin" ]]; then
  echo "error: $_bin is not executable" >&2
  exit 1
fi
if [[ $EUID -eq 0 ]]; then
  echo 'error: do not run the browser (or this test) as root' >&2
  exit 1
fi

_profile="$(mktemp -d /tmp/helium-sandbox-test.XXXXXX)"
_log="$(mktemp /tmp/helium-sandbox-log.XXXXXX)"
export XDG_CONFIG_HOME="${_profile}/config"
export XDG_CACHE_HOME="${_profile}/cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

_cleanup() {
  if [[ -n "${_pid:-}" ]] && kill -0 "$_pid" 2>/dev/null; then
    kill "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true
  fi
  rm -rf "$_profile" "$_log"
}
trap _cleanup EXIT

"$_bin" --headless=new --disable-gpu --no-first-run \
  --user-data-dir="$_profile" --remote-debugging-port=0 about:blank \
  >"$_log" 2>&1 &
_pid=$!

_port_file="$_profile/DevToolsActivePort"
for _ in $(seq 1 60); do
  [[ -s "$_port_file" ]] && break
  kill -0 "$_pid" 2>/dev/null || {
    echo 'FAIL: browser exited during startup' >&2
    cat "$_log" >&2
    exit 1
  }
  sleep 0.5
done

if [[ ! -s "$_port_file" ]]; then
  echo 'FAIL: browser did not open a DevTools port' >&2
  cat "$_log" >&2
  exit 1
fi

_port="$(head -n1 "$_port_file")"
curl -fsS "http://127.0.0.1:${_port}/json/version" >/dev/null ||
  { echo 'FAIL: DevTools endpoint unreachable' >&2; exit 1; }
sleep 2

_browser_userns="$(readlink "/proc/${_pid}/ns/user")"
_sandboxed=0
_renderers=0
for _p in $(pgrep -f -- "user-data-dir=${_profile}" || true); do
  [[ "$_p" == "$_pid" ]] && continue
  _cmd="$(tr '\0' ' ' <"/proc/${_p}/cmdline" 2>/dev/null || true)"
  [[ "$_cmd" == *'--type=renderer'* ]] || continue
  _renderers=$((_renderers + 1))
  _seccomp="$(awk '/^Seccomp:/ {print $2}' "/proc/${_p}/status" 2>/dev/null || echo 0)"
  _userns="$(readlink "/proc/${_p}/ns/user" 2>/dev/null || true)"
  echo "renderer ${_p}: Seccomp=${_seccomp} userns=${_userns}"
  if [[ "$_seccomp" == 2 && -n "$_userns" && "$_userns" != "$_browser_userns" ]]; then
    _sandboxed=$((_sandboxed + 1))
  fi
done

if (( _renderers == 0 )); then
  echo 'FAIL: no renderer process found' >&2
  cat "$_log" >&2
  exit 1
fi
if (( _sandboxed == 0 )); then
  echo 'FAIL: no sandboxed renderer (seccomp + user namespace) found' >&2
  exit 1
fi

echo "PASS: ${_sandboxed}/${_renderers} renderer(s) use seccomp and a private user namespace"

#!/usr/bin/env bash
# Verify the contents of a built helium-bin package without installing it.
set -euo pipefail

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_pkg="${1:-}"
if [[ -z "$_pkg" ]]; then
  _pkg="$(ls -t "$_root"/helium-bin-*-x86_64.pkg.tar.zst 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$_pkg" || ! -f "$_pkg" ]]; then
  echo "usage: $0 <helium-bin-...pkg.tar.zst>" >&2
  exit 1
fi

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
bsdtar -xf "$_pkg" -C "$_tmp"

# Derive the expected browser version from the package itself, not from the
# repository PKGBUILD: automation validates a candidate artifact built in a
# temporary workspace before promoting it.
_expected_ver="$(bsdtar -xOf "$_pkg" .PKGINFO 2>/dev/null |
  sed -n 's/^pkgver = //p' | head -n1)"
_expected_ver="${_expected_ver%-*}"
if [[ -z "$_expected_ver" ]]; then
  echo "FAIL: package has no readable .PKGINFO pkgver" >&2
  exit 1
fi

_fail=0
check() {
  if eval "$2"; then
    echo "ok: $1"
  else
    echo "FAIL: $1" >&2
    _fail=1
  fi
}

check 'helium binary' '[[ -x "$_tmp/usr/lib/helium/helium" ]]'
check 'upstream wrapper' '[[ -x "$_tmp/usr/lib/helium/helium-wrapper" ]]'
check '/usr/bin/helium symlink' '[[ -L "$_tmp/usr/bin/helium" ]]'
check 'symlink target' '[[ "$(readlink "$_tmp/usr/bin/helium")" == /usr/lib/helium/helium-wrapper ]]'
check 'desktop entry' '[[ -f "$_tmp/usr/share/applications/helium.desktop" ]]'
check 'icon' '[[ -f "$_tmp/usr/share/icons/hicolor/256x256/apps/helium.png" ]]'
check 'AppStream metadata' '[[ -f "$_tmp/usr/share/metainfo/net.imput.helium.metainfo.xml" ]]'
check 'licenses' '[[ -f "$_tmp/usr/share/licenses/helium-bin/LICENSE" && -f "$_tmp/usr/share/licenses/helium-bin/LICENSE.ungoogled_chromium" ]]'
check 'AppArmor profile' '[[ -f "$_tmp/etc/apparmor.d/helium-bin" ]]'
check 'AppArmor profile path' 'grep -q "profile helium-bin \"/usr/lib/helium/helium\"" "$_tmp/etc/apparmor.d/helium-bin"'
check 'AppArmor profile path (upstream copy)' 'grep -q "profile helium-bin \"/usr/lib/helium/helium\"" "$_tmp/usr/lib/helium/apparmor.cfg"'
check 'CHROME_VERSION_EXTRA' 'grep -q "^export CHROME_VERSION_EXTRA=\"Arch Linux\"$" "$_tmp/usr/lib/helium/helium-wrapper"'
check 'no --no-sandbox in desktop file' '! grep -q -- --no-sandbox "$_tmp/usr/share/applications/helium.desktop"'
check 'no --no-sandbox in wrapper' '! grep -q -- --no-sandbox "$_tmp/usr/lib/helium/helium-wrapper"'
check 'shared libraries resolvable' '! ldd "$_tmp/usr/lib/helium/helium" | grep -q "not found"'
check 'desktop file valid' 'desktop-file-validate "$_tmp/usr/share/applications/helium.desktop"'
check 'AppStream XML well-formed' 'xmllint --noout "$_tmp/usr/share/metainfo/net.imput.helium.metainfo.xml"'
check 'binary version' '"$_tmp/usr/lib/helium/helium" --version | grep -q "$_expected_ver"'

echo
echo "package: $_pkg"
du -h "$_pkg"
exit "$_fail"

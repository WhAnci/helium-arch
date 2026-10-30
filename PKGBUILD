# Maintainer: helium-arch contributors
#
# Arch Linux package for the official Helium Linux release tarball.
# Upstream: https://github.com/imputnet/helium-linux
#
# The package installs the signed upstream binary release. No distro-specific
# feature flags are added and the Chromium sandbox is left untouched.

pkgname=helium-bin
_pkgname=helium
pkgver=0.20.2.1
pkgrel=1
pkgdesc='Private, fast, and honest web browser based on Chromium (official binary release)'
arch=('x86_64')
url='https://github.com/imputnet/helium-linux'
license=('GPL-3.0-only AND BSD-3-Clause')
options=('!strip' '!debug')

makedepends=('curl' 'gnupg')

depends=(
  'alsa-lib'
  'at-spi2-core'
  'ca-certificates'
  'cairo'
  'dbus'
  'expat'
  'gcc-libs'
  'glib2'
  'glibc'
  'gtk3'
  'hicolor-icon-theme'
  'libcups'
  'libpulse'
  'libva'
  'libx11'
  'libxcb'
  'libxcomposite'
  'libxdamage'
  'libxext'
  'libxfixes'
  'libxkbcommon'
  'libxrandr'
  'libxss'
  'mesa'
  'nspr'
  'nss'
  'pango'
  'systemd-libs'
  'ttf-liberation'
  'xdg-utils'
)

optdepends=(
  'apparmor: load the shipped AppArmor profile'
  'desktop-file-utils: refresh the desktop MIME database via the pacman hook'
  'gnome-keyring: Secret Service password storage on GNOME'
  'kdialog: native KDE dialogs'
  'kwallet: password storage on KDE Plasma'
  'pciutils: GPU diagnostics (lspci)'
  'pipewire: WebRTC desktop sharing and screen capture on Wayland'
  'qt5-base: Qt 5 theme integration (bundled Qt shim)'
  'qt6-base: Qt 6 theme integration (bundled Qt shim)'
  'upower: Battery Status API support'
  'xdg-desktop-portal: native file chooser and screen sharing on Wayland'
)

conflicts=('helium-browser-bin' 'helium-browser-beta-bin')

# Upstream uses the GitHub release tarball for every architecture. Only
# x86_64 is packaged and tested here; add arm64 source arrays if needed.
_arch=x86_64
_release_url="https://github.com/imputnet/helium-linux/releases/download/${pkgver}"
_raw_url="https://raw.githubusercontent.com/imputnet/helium-linux/${pkgver}"

source=(
  "${_pkgname}-${pkgver}-${_arch}_linux.tar.xz::${_release_url}/${_pkgname}-${pkgver}-${_arch}_linux.tar.xz"
  "${_pkgname}-${pkgver}-${_arch}_linux.tar.xz.asc::${_release_url}/${_pkgname}-${pkgver}-${_arch}_linux.tar.xz.asc"
  "helium-LICENSE::${_raw_url}/LICENSE"
  "helium-LICENSE.ungoogled_chromium::${_raw_url}/LICENSE.ungoogled_chromium"
  "net.imput.helium.metainfo.xml::${_raw_url}/package/net.imput.helium.metainfo.xml"
)

# The .asc checksum is pinned too; the signature is additionally verified by
# makepkg against validpgpkeys. Update all values with scripts/update.sh.
sha256sums=('ba92acb27ec6cda36a8b948e2154009aaee0d633222ad244be25e736a143e6fa'
            '2f6d80133eebbc8b71e32a976e179780bb2d9ff7754e38c66f925cbb50f5347e'
            'a0279a9937ce228eb71ea2a0252d0830458708570fee3df516fa4bd4c8a134bc'
            '9539b394e4179952698894bd62ef6566b6804ab0ff360dcf3a511cfaf7f78c4d'
            '398cbaa541df9c214e18918c0a0a957255441c8ac7e5dfa079fe549a28502298')

validpgpkeys=('BE677C1989D35EAB2C5F26C9351601AD01D6378E') # Helium signing key <helium@imput.net>

_srcdir_name="${_pkgname}-${pkgver}-${_arch}_linux"

prepare() {
  # Tell upstream bug reports which packaging the user runs. This is the only
  # change made to the upstream wrapper.
  sed -i 's|^export CHROME_VERSION_EXTRA="custom"$|export CHROME_VERSION_EXTRA="Arch Linux"|' \
    "${srcdir}/${_srcdir_name}/helium-wrapper"

  if ! grep -q '^export CHROME_VERSION_EXTRA="Arch Linux"$' \
    "${srcdir}/${_srcdir_name}/helium-wrapper"; then
    echo 'error: failed to set CHROME_VERSION_EXTRA in helium-wrapper' >&2
    exit 1
  fi

  # The upstream profile hardcodes /opt/helium; this package uses /usr/lib.
  sed -i "s|/opt/${_pkgname}/${_pkgname}|/usr/lib/${_pkgname}/${_pkgname}|" \
    "${srcdir}/${_srcdir_name}/apparmor.cfg"
  if ! grep -q "/usr/lib/${_pkgname}/${_pkgname}" \
    "${srcdir}/${_srcdir_name}/apparmor.cfg"; then
    echo 'error: failed to adjust the AppArmor profile path' >&2
    exit 1
  fi
}

package() {
  local src="${srcdir}/${_srcdir_name}"

  # Arch packages must not place ELF files in /opt, so the upstream bundle is
  # relocated to /usr/lib. The wrapper resolves resources relative to itself.
  install -dm755 "${pkgdir}/usr/lib/${_pkgname}"
  cp -a "${src}/." "${pkgdir}/usr/lib/${_pkgname}/"

  install -Dm644 "${src}/helium.desktop" \
    "${pkgdir}/usr/share/applications/helium.desktop"
  install -Dm644 "${src}/product_logo_256.png" \
    "${pkgdir}/usr/share/icons/hicolor/256x256/apps/helium.png"
  install -Dm644 "${srcdir}/net.imput.helium.metainfo.xml" \
    "${pkgdir}/usr/share/metainfo/net.imput.helium.metainfo.xml"

  # Upstream ships this profile for distributions that restrict unprivileged
  # user namespaces. It is inert unless AppArmor is enabled. The path was
  # adjusted to the Arch layout in prepare().
  install -Dm644 "${src}/apparmor.cfg" "${pkgdir}/etc/apparmor.d/helium-bin"

  install -Dm644 "${srcdir}/helium-LICENSE" \
    "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  install -Dm644 "${srcdir}/helium-LICENSE.ungoogled_chromium" \
    "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE.ungoogled_chromium"

  install -dm755 "${pkgdir}/usr/bin"
  ln -s "/usr/lib/${_pkgname}/helium-wrapper" "${pkgdir}/usr/bin/helium"
}

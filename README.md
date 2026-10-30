# Helium Browser for Arch Linux

**English** | [한국어](README.ko.md)

An Arch Linux package for **Helium Browser**. It packages the official,
upstream-signed Linux binary tarball with a `PKGBUILD` and keeps the Chromium
sandbox intact.

> **Personal project, provided as-is.** This package is maintained for personal
> use and was developed with AI assistance. It is not an official Helium
> project. Updates may be slow, and bugs or breakage are possible. Contributions
> (issues and pull requests) are not accepted. Use at your own risk.

| Item | Value |
| --- | --- |
| Repository | [WhAnci/helium-arch](https://github.com/WhAnci/helium-arch) |
| Upstream | [imputnet/helium-linux](https://github.com/imputnet/helium-linux) |
| Browser source | [imputnet/helium](https://github.com/imputnet/helium) |
| Package version | `helium-bin 0.20.2.1-1` |
| Helium / Chromium | `0.20.2.1` / `156.0.8078.73` |
| Architecture | `x86_64` (tested) |
| Install paths | `/usr/lib/helium`, `/usr/bin/helium` |
| License | GPL-3.0-only, BSD-3-Clause (ungoogled-chromium parts) |

## Why this packaging approach

This repository builds a **binary package from the PGP-signed `tar.xz` published
on the official GitHub release**.

- Upstream officially publishes `x86_64`/`arm64` tarballs with `.asc` signatures.
- The tarball is a complete binary that includes Chromium's namespace sandbox
  and works without a `setuid` helper.
- The package manager can verify the version, checksum, and signature, and
  install, update, and remove the browser consistently with `pacman`.
- A full Chromium source build needs tens of GB of disk and a long build time,
  so it is not the default approach here.
- AppImages depend on FUSE or `--appimage-extract-and-run`, their zsync
  self-update conflicts with pacman's file ownership and update policy, and
  desktop integration has to be done separately. Upstream also recommends
  AppImage only when no distribution package exists.
- The AUR currently has `helium-browser-bin`, but this repository is an
  independent package that follows the upstream naming convention (`-bin`
  suffix, `helium` executable). The two packages would install the same browser
  twice, so they deliberately `conflicts` with each other. This repository is
  not registered on the AUR yet (see [AUR publication](#aur-publication)).

Files are installed under `/usr/lib/helium` instead of `/opt` to follow Arch
packaging conventions. The upstream wrapper locates its resources relative to
its own path, so it keeps working after the move, and the AppArmor profile's
execution path is adjusted to match.

## Requirements

- Arch Linux (rolling), `x86_64`
- `base-devel` (makepkg, fakeroot, gcc, etc.)
- Network access (about 120 MB / 115 MiB downloaded on the first build)
- `pacman-contrib` (`updpkgsums`) when using the version update script
- `python`, `flock`, `zstd`, `libarchive` (`bsdtar`) when using automation
- `desktop-file-utils`, `libxml2` (`xmllint`) when validating the package
- Unprivileged user namespace support in the Linux kernel (the Arch default)

```bash
sudo pacman -S --needed base-devel
# Optional: only when using the version update script
sudo pacman -S --needed pacman-contrib
```

Runtime dependencies are declared in `depends` in the `PKGBUILD` and are handled
by `makepkg -s` or `pacman -U`. You do not need to install all of them
separately.

## Install from a release

You can install a prebuilt package from GitHub Releases without building it.

```bash
base=https://github.com/WhAnci/helium-arch/releases/download/v0.20.2.1-1
curl -LO "$base/helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst"
curl -LO "$base/helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst.sha256"
sha256sum -c helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst.sha256
sudo pacman -U helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst
```

The SHA-256 is
`6a914e61ab45836bb263aaf7d47b342bf56c1d48e5e5cfa0d5849f32907ddcf9`.
This is the fastest installation path until the AUR package is registered.

## Build and install

From the repository directory:

```bash
# Import the upstream signing key into a temporary GnuPG home and run makepkg
# (-s: install dependencies, -i: install the package)
./scripts/build.sh -si
```

`scripts/build.sh` imports the Helium signing key into
`~/.cache/helium-arch/gnupg` without touching your default keyring, then runs
`makepkg`. The install step may ask for your sudo password.

To do it manually:

```bash
gpg --import keys/pgp/BE677C1989D35EAB2C5F26C9351601AD01D6378E.asc
makepkg -si
```

`makepkg` verifies:

- the SHA-256 of `helium-0.20.2.1-x86_64_linux.tar.xz`
- the SHA-256 of the `.asc`
- the PGP signature made by the Helium signing key
  `BE67 7C19 89D3 5EAB 2C5F 26C9 3516 01AD 01D6 378E`
- the SHA-256 of the license and AppStream metadata files

Do not use `--skippgpcheck`, which bypasses signature verification.

If you already downloaded the sources, you can reuse them with `SRCDEST`.

```bash
SRCDEST=/path/to/sources ./scripts/build.sh -si
```

To build the package file only:

```bash
./scripts/build.sh          # helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst
```

## Run

```bash
helium
```

It appears as **Helium** in the application menu. The `.desktop` file is
installed to `/usr/share/applications/helium.desktop` and the icon to
`/usr/share/icons/hicolor/256x256/apps/helium.png`.

### Set as the default browser

```bash
xdg-settings set default-web-browser helium.desktop
```

You can also select Helium in your desktop environment's default application
settings. The package does not modify the user's `~/.config/mimeapps.list`.

> Note: if the system has no explicit HTTP/HTTPS default application, the newly
> registered `helium.desktop` may receive `xdg-utils`' fallback selection and
> appear to be the default. If you do not want to change your default browser,
> explicitly set the browser you want with the command above.

## Update

The Linux tarball and Debian package have no browser self-update feature; only
the AppImage provides zsync self-update. Because this package does not use
AppImage zsync, it is **updated through pacman**.

```bash
# 1. Update the PKGBUILD to the latest upstream release (includes signature verification)
./scripts/update.sh

# Pin to a specific version
./scripts/update.sh 0.20.1.1

# 2. Review the changes, then build/install
./scripts/build.sh -si

# 3. Verify
pacman -Q helium-bin
helium --version
```

`scripts/update.sh` reads the latest stable tag from the GitHub API, downloads
the tarball and signature, verifies the PGP signature, and updates `pkgver`,
`sha256sums`, and `.SRCINFO`. `updpkgsums` writes `SKIP` for the signature file,
but the script fills in the real SHA-256 of the `.asc`. This repository
therefore never keeps an unverified `SKIP`.

If you only change packaging (for example, the `.desktop` file), bump `pkgrel`.

```bash
vim PKGBUILD            # pkgrel=2
./scripts/build.sh -si
```

Updating keeps your browser profile. The profile lives in your home directory,
not in the package:

- `~/.config/net.imput.helium`
- `~/.cache/net.imput.helium`

## Automation (optional)

The manual workflow remains available, and there is also a script that detects a
new release, verifies the signature and checksums, builds in an isolated
workspace, runs static/package/sandbox checks, and publishes atomically. **The
automation does not modify `PKGBUILD`/`.SRCINFO` at the repository root.** Only
successful candidates are published to `out/<pkgver>-<pkgrel>/`.

```bash
# Read-only check (no file changes or downloads)
./scripts/check-upstream.sh
./scripts/check-upstream.sh --json

# Full run: does nothing when there is no new version
./scripts/automation/run.sh

# Force a rebuild of an already successful version
HELIUM_FORCE=1 ./scripts/automation/run.sh

# Reproduce a specific version without the API check (signature verification still runs)
HELIUM_VERSION=0.20.1.1 ./scripts/automation/run.sh

# Orchestration tests (mock commands, no network or real build)
./tests/automation/run-tests.sh
```

Output layout:

```text
out/latest -> 0.20.2.1-1
out/0.20.2.1-1/
  helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst
  PKGBUILD
  .SRCINFO
  manifest.json
state/status.json     # last run result (including failures)
logs/<run-id>.log     # full log
```

`check-upstream.sh` exit codes: `0` no update, `10` update available,
`20` operational error (network/API/invalid tag), `2` usage error.
`run.sh` exit codes: `0` success/no change, `20` preparation error, `30` build
failure, `40` verification/publication failure, `75` another run holds the lock.

Test results are recorded in the manifest as `passed`/`failed`/`skipped` with a
reason. With `HELIUM_SANDBOX=auto` (the default), if the environment cannot
support the sandbox test it is recorded as `skipped` and never reported as
`passed`. Use `require` to enforce it, or `skip` to skip it explicitly. If a
required check fails, nothing is published and the previous `out/latest` and
existing artifacts are preserved.

Required packages: `base-devel`, `curl`, `gnupg`, `pacman-contrib`, `python`,
`zstd`, `libarchive`, `desktop-file-utils`, `libxml2`, and optionally
`shellcheck` and `namcap`. Running the sandbox test also requires the runtime
dependencies from the `PKGBUILD` and unprivileged user namespaces. See
[`docs/AUTOMATION.md`](docs/AUTOMATION.md) for all options, failure recovery,
and systemd template deployment.

The automation does not install packages (no `sudo`, `pacman -U`, or
`makepkg -i`), does not publish or upload to the AUR, GitHub, or other external
services, and does not run Git commands. The units in `packaging/systemd/` are
templates only and are not enabled or started by this repository.

## Removal

```bash
sudo pacman -Rns helium-bin
```

Removal deletes `/usr/bin/helium`, `/usr/lib/helium`, the `.desktop` file, icons,
AppStream metadata, licenses, and the AppArmor profile. **Browser profiles and
caches are not deleted.** To remove them completely, delete them yourself:

```bash
rm -rf ~/.config/net.imput.helium ~/.cache/net.imput.helium
```

## Sandbox and security

- `--no-sandbox` is not added to the default launch options.
- Do not run as root. Running as root disables the Chromium sandbox.
- The upstream tarball has no `chrome-sandbox` setuid helper. Chromium 156 uses
  a sandbox based on unprivileged user namespaces plus seccomp-bpf.
- Arch Linux allows unprivileged user namespaces by default. Check with:

  ```bash
  cat /proc/sys/user/max_user_namespaces
  sysctl kernel.unprivileged_userns_clone 2>/dev/null || true
  ```

- If user namespaces are blocked by container or kernel settings, Helium will
  not run correctly. Do not bypass this with `--no-sandbox`; allow namespaces
  or run in an environment that supports the sandbox.
- For distributions whose AppArmor configuration restricts unprivileged user
  namespaces, the upstream profile is installed to
  `/etc/apparmor.d/helium-bin`. Because upstream also keeps the same profile in
  `/usr/lib/helium/apparmor.cfg`, `prepare()` adjusts both files to point at this
  package's real executable path (`/usr/lib/helium/helium`) instead of
  `/opt/helium`. AppArmor was disabled in this environment, so actual
  enforcement was not verified. If your system uses AppArmor, load the profile:

  ```bash
  sudo apparmor_parser -r -W /etc/apparmor.d/helium-bin
  ```

- The package does not change settings that disable SELinux or AppArmor.

## Desktop / Wayland

- Wayland: on Hyprland 0.56.2, native Wayland (`xwayland=false`) window creation,
  HTTPS page loading, opening a new window, and clean shutdown were verified.
- X11: window creation and HTTPS loading were verified under XWayland with
  `--ozone-platform=x11`. The default is selected automatically depending on the
  environment.
- If you have problems on Wayland, first check upstream's default behavior, and
  only use `--ozone-platform=wayland` or `--ozone-platform=x11` for diagnostics
  when needed. The package does not force a specific platform.
- Screen sharing/file picker: `pipewire`, `xdg-desktop-portal`, and a
  desktop-specific portal backend may be required. See `optdepends`.
- For Qt theme integration on KDE, install `qt5-base`/`qt6-base`. Upstream ships
  `libqt5_shim.so` and `libqt6_shim.so`.
- Password storage: `gnome-keyring` on GNOME, `kwallet` on KDE.
- Battery status: `upower`.
- GPU diagnostics: `pciutils` (`lspci`).

## Known issues

- **No Widevine DRM**: DRM streaming such as Netflix may not work. The upstream
  tarball does not include the Widevine CDM.
- **No automatic updates**: updates come only through the package manager. Do not
  expect in-browser updates.
- **Conflicts with AUR packages**: if `helium-browser-bin` or
  `helium-browser-beta-bin` is installed, remove it first. These conflicts are
  intentional to avoid installing the same browser twice.
- **AppArmor profile not verified**: AppArmor was disabled in the test
  environment, so actual profile enforcement was not verified.
- **No aarch64 support**: upstream also provides an arm64 tarball, but this
  repository packages and tests only x86_64. If needed, add `source_aarch64` and
  `sha256sums_aarch64` and test them separately.
- **Qt5 shim warning**: `namcap` warns that the Qt5 libraries used by
  `libqt5_shim.so` are an "uninstalled dependency". Qt5 theme integration is
  optional; installing `qt5-base` resolves it.
- **`namcap` "may not be needed" warnings**: `gtk3`, `libpulse`, `libva`,
  `libxss`, `pciutils`, `xdg-utils`, `ca-certificates`, and `ttf-liberation` are
  not linked directly into the ELF binary and are used through dlopen/exec or at
  runtime. They are intentionally kept in `depends`/`optdepends`.

## Verification results

Environment: Arch Linux rolling, kernel `7.2.11-arch1-1`, Hyprland 0.56.2
(Wayland) + XWayland, `x86_64`.

### 0.20.2.1 automated build (2026-10-30)

`./scripts/automation/run.sh` performed detection, signature/checksum
verification, build, checks, and atomic publication in one run. The package was
not actually installed (`pacman -U`).

- Updated 0.20.1.1 → 0.20.2.1 with `scripts/update.sh`; PGP `Good signature`
  (fingerprint `BE67 7C19 89D3 5EAB 2C5F 26C9 3516 01AD 01D6 378E`)
- `makepkg` build succeeded:
  `helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst`
  (SHA-256 `6a914e61ab45836bb263aaf7d47b342bf56c1d48e5e5cfa0d5849f32907ddcf9`)
- Binary version check: `Helium 0.20.2.1 (Chromium 156.0.8078.73)`
- `bash -n` (all scripts and the `PKGBUILD`) and `shellcheck -S warning`
  (`scripts/`, `tests/`) passed
- `namcap` reported 0 errors. Warnings were only informational: the Qt5 shim,
  glibc-merged `libdl`/`libpthread`, and dlopen/exec-based dependencies
- `tests/check-package.sh` passed 18/18: file paths, symlinks, desktop file,
  icons, licenses, AppStream XML, AppArmor paths, absence of `--no-sandbox`,
  dynamic library resolution, and binary version
- `tests/check-sandbox.sh`: renderer 3/3 with `Seccomp=2` and separate user
  namespaces
- Atomic publication: package, `PKGBUILD`, `.SRCINFO`, and `manifest.json`
  recorded under `out/0.20.2.1-1/`, with `out/latest` → `0.20.2.1-1`
- `tests/automation/run-tests.sh`: 133 checks passed. With mock
  `curl`/`gpg`/`updpkgsums`/`makepkg`/`namcap`/`shellcheck`, it verifies
  no-update, new release, API failure/rate limit/invalid response, invalid tag,
  PGP failure, build/verification failure, sandbox skip, successful publication,
  preserving `latest` after failure, lock contention (75), idempotent rerun,
  forced rebuild, and 3-version retention

### 0.20.1.1 install/removal (2026-10-24)

This is the record of actually installing, running, and removing the `0.20.1.1`
package.

- `pacman -U` installation; `pacman -Qkk` verified 263 files
- After `pacman -R`, no package files remained and the test profile files were
  preserved
- Wayland native window, XWayland X11 window, HTTPS `https://example.com` load,
  opening a new window, clean SIGTERM shutdown
- Reinstalled `release` and ran again with the same profile, confirming the
  profile files persist
- Updated 0.20.1.1 → 0.19.4.1 with `scripts/update.sh`, built/checked, then
  restored 0.20.1.1 to verify the version update path

Not verified:

- Actual install/removal of the 0.20.2.1 package and running the browser (only
  build, structure, and sandbox checks were performed)
- aarch64 build/run
- AppArmor/SELinux enforcing environments
- Actual streaming with Widevine, proprietary media codecs, or screen sharing
- AUR publication and installation in an AUR user environment
- systemd service/timer deployment and execution on a real Arch VM
- PGP signing of this repository's package itself (currently an unsigned package)

## Repository layout

```
PKGBUILD                                  Arch package definition
.SRCINFO                                  makepkg --printsrcinfo output (AUR format)
README.md                                 English documentation (default)
README.ko.md                              Korean documentation
keys/pgp/BE67...378E.asc                  Upstream signing public key
scripts/build.sh                          Run makepkg with a temporary GnuPG home
scripts/update.sh                         Update upstream version/checksums/.SRCINFO
scripts/check-upstream.sh                 Read-only new-release check
scripts/automation/run.sh                 Build/verify/atomic-publish orchestration
tests/check-package.sh                    Inspect the built package structure/metadata
tests/check-sandbox.sh                    Renderer seccomp + user namespace check
tests/automation/                          Mock-command orchestration tests
packaging/systemd/                         service/timer templates for future VM deployment
docs/AUTOMATION.md                         Automation usage/exit codes/recovery
LICENSE                                    0BSD license for this repository's packaging files
```

Build artifacts (`src/`, `pkg/`, `*.pkg.tar.zst`) and automation runtime
directories (`out/`, `work/`, `state/`, `logs/`) are excluded by `.gitignore`.
`helium-bin-0.20.1.1-1-x86_64.pkg.tar.zst` is a real artifact built and
installed in this environment; the automation does not delete or overwrite it.

## AUR publication

The AUR name is reserved as `helium-bin` (unused as of 2026-10-30). The AUR
repository contains only `PKGBUILD` and `.SRCINFO`; build artifacts are never
uploaded. The GitHub repository is the source, and the AUR mirrors those files.

```bash
# After the AUR account and SSH public key are registered
git clone ssh://aur@aur.archlinux.org/helium-bin.git
cp PKGBUILD .SRCINFO helium-bin/
cd helium-bin
git add PKGBUILD .SRCINFO
git commit -m "helium-bin 0.20.2.1-1"
git push
```

For initial registration, create an account on the AUR website and register
your SSH public key at <https://aur.archlinux.org/account/>. AUR SSH uses port
22.

> As of 2026-10-30, the AUR has **temporarily paused new account registration**
> in response to a wave of automated account creation. Check the aur-general
> mailing list and the Arch news feed for reopening announcements. Once
> registration reopens, the procedure above can be followed as written.

## Manual upstream update procedure

1. Check the stable tag at
   <https://github.com/imputnet/helium-linux/releases/latest> or
   `https://api.github.com/repos/imputnet/helium-linux/releases/latest`
2. Run `./scripts/update.sh <version>`
3. Review the `pkgver`, `sha256sums`, and `.SRCINFO` diff in `PKGBUILD`
4. Build with `./scripts/build.sh`
5. Run `./tests/check-package.sh`, `namcap <pkgfile>`, and
   `./tests/check-sandbox.sh /usr/lib/helium/helium`
6. Install for real and verify Wayland/X11 launch and profile persistence

## License

- Packaging files in this repository: 0BSD (`LICENSE`)
- Helium: GPL-3.0-only. The full license is installed to
  `/usr/share/licenses/helium-bin/LICENSE`.
- Parts from ungoogled-chromium: BSD-3-Clause
  (`/usr/share/licenses/helium-bin/LICENSE.ungoogled_chromium`)
- Licenses for upstream code, patches, and binaries follow the upstream
  repository.

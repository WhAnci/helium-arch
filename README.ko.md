# Helium Browser for Arch Linux

[English](README.md) | **한국어**

Arch Linux용 **Helium Browser** 패키지입니다. upstream이 서명해서 배포하는
공식 Linux 바이너리 tarball을 `PKGBUILD`로 패키징하며, Chromium sandbox를
그대로 유지합니다.

> **개인용 프로젝트이며 있는 그대로 제공됩니다.** 이 패키지는 개인 사용을 위해
> 유지되며 AI의 도움을 받아 개발했습니다. 공식 Helium 프로젝트가 아닙니다.
> 업데이트가 느릴 수 있고 오류나 동작하지 않는 부분이 있을 수 있습니다.
> 기여(이슈, 풀 리퀘스트)는 받지 않습니다. 사용에 따른 책임은 사용자에게
> 있습니다.

| 항목 | 값 |
| --- | --- |
| 저장소 | [WhAnci/helium-arch](https://github.com/WhAnci/helium-arch) |
| upstream | [imputnet/helium-linux](https://github.com/imputnet/helium-linux) |
| browser source | [imputnet/helium](https://github.com/imputnet/helium) |
| 패키지 버전 | `helium-bin 0.20.2.1-1` |
| Helium / Chromium | `0.20.2.1` / `156.0.8078.73` |
| 아키텍처 | `x86_64` (검증됨) |
| 설치 경로 | `/usr/lib/helium`, `/usr/bin/helium` |
| 라이선스 | GPL-3.0-only, BSD-3-Clause (ungoogled-chromium 부분) |

## 선택한 패키징 방식

**공식 GitHub 릴리스의 PGP 서명된 `tar.xz`를 사용하는 바이너리 패키지**를
선택했습니다.

- upstream이 `x86_64`/`arm64` tarball과 `.asc` 서명을 공식 배포합니다.
- tarball은 Chromium의 namespace sandbox를 포함한 완전한 바이너리이며,
  `setuid` helper 없이 동작합니다.
- 패키지 관리자가 버전, 체크섬, 서명을 검증하고 설치/업데이트/제거를
  `pacman`으로 일관되게 수행할 수 있습니다.
- Chromium 전체 소스 빌드는 수십 GB의 디스크와 긴 빌드 시간이 필요해
  기본 방식으로 선택하지 않았습니다.
- AppImage는 FUSE 또는 `--appimage-extract-and-run` 환경에 의존하고,
  zsync 자체 업데이트가 pacman의 파일 소유권/업데이트 정책과 충돌하며,
  데스크톱 통합을 별도로 해야 하므로 선택하지 않았습니다. upstream도
  배포판 패키지가 없을 때만 AppImage를 권장합니다.
- AUR에는 현재 `helium-browser-bin`이 있지만, 이 저장소는 upstream 명명
  규칙(`-bin` 접미사, 실행 파일 `helium`)을 따르는 독립 패키지입니다.
  두 패키지는 같은 브라우저를 중복 설치하므로 `conflicts`로 막아 두었습니다.
  이 저장소는 아직 AUR에 등록되지 않았습니다(절차는 [AUR 게시](#aur-게시) 참조).

설치 파일은 Arch 패키징 규칙에 맞게 `/opt` 대신 `/usr/lib/helium`에
배치했습니다. upstream wrapper는 자신의 위치를 기준으로 리소스를 찾기 때문에
경로 이동 후에도 동작하며, AppArmor 프로필의 실행 경로도 그에 맞게
조정합니다.

## 요구 사항

- Arch Linux (rolling), `x86_64`
- `base-devel` (makepkg, fakeroot, gcc 등)
- 네트워크 access (최초 빌드 시 약 120 MB / 115 MiB 다운로드)
- 패키지 업데이트 스크립트 사용 시 `pacman-contrib` (`updpkgsums`)
- 자동화 사용 시 `python`, `flock`, `zstd`, `libarchive` (`bsdtar`)
- 패키지 검증 시 `desktop-file-utils`, `libxml2` (`xmllint`)
- Linux kernel의 unprivileged user namespace 지원 (Arch 기본값)

```bash
sudo pacman -S --needed base-devel
# 선택: 버전 갱신 스크립트를 사용할 때만
sudo pacman -S --needed pacman-contrib
```

런타임 의존성은 `PKGBUILD`의 `depends`에 선언되어 있으며 `makepkg -s` 또는
`pacman -U`가 처리합니다. 별도로 모두 설치할 필요는 없습니다.

## 릴리스에서 설치

직접 빌드하지 않고 GitHub Release의 패키지를 내려받아 설치할 수 있습니다.

```bash
base=https://github.com/WhAnci/helium-arch/releases/download/v0.20.2.1-1
curl -LO "$base/helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst"
curl -LO "$base/helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst.sha256"
sha256sum -c helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst.sha256
sudo pacman -U helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst
```

SHA-256은 `6a914e61ab45836bb263aaf7d47b342bf56c1d48e5e5cfa0d5849f32907ddcf9`입니다.
AUR 등록 전까지 가장 빠른 설치 방법입니다.

## 빌드 및 설치

저장소 디렉터리에서:

```bash
# upstream 서명 키를 임시 GnuPG home에 넣고 makepkg 실행 (-s: 의존성 설치, -i: 패키지 설치)
./scripts/build.sh -si
```

`scripts/build.sh`는 사용자의 기본 keyring을 건드리지 않고
`~/.cache/helium-arch/gnupg`에 Helium 서명 키를 import한 뒤 `makepkg`를
실행합니다. 설치 단계에서 sudo 암호를 물을 수 있습니다.

수동으로 하려면:

```bash
gpg --import keys/pgp/BE677C1989D35EAB2C5F26C9351601AD01D6378E.asc
makepkg -si
```

`makepkg`는 다음을 검증합니다.

- `helium-0.20.2.1-x86_64_linux.tar.xz`의 SHA-256
- `.asc`의 SHA-256
- Helium signing key `BE67 7C19 89D3 5EAB 2C5F 26C9 3516 01AD 01D6 378E`에
  의한 PGP 서명
- 라이선스/AppStream 메타데이터 파일의 SHA-256

서명 검증을 우회하는 `--skippgpcheck`는 사용하지 마십시오.

이미 내려받은 소스가 있다면 `SRCDEST`로 재사용할 수 있습니다.

```bash
SRCDEST=/path/to/sources ./scripts/build.sh -si
```

패키지 파일만 만들려면:

```bash
./scripts/build.sh          # helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst
```

## 실행

```bash
helium
```

애플리케이션 메뉴에는 **Helium**으로 나타납니다. `.desktop` 파일은
`/usr/share/applications/helium.desktop`, 아이콘은
`/usr/share/icons/hicolor/256x256/apps/helium.png`에 설치됩니다.

### 기본 브라우저로 설정

```bash
xdg-settings set default-web-browser helium.desktop
```

데스크톱 환경의 기본 앱 설정 GUI에서 Helium을 선택해도 됩니다. 패키지는
사용자의 `~/.config/mimeapps.list`를 수정하지 않습니다.

> 참고: 시스템에 명시적인 HTTP/HTTPS 기본 앱이 없으면, 새로 등록된
> `helium.desktop`이 `xdg-utils`의 fallback 선택을 받아 기본처럼 보일 수
> 있습니다. 기본 브라우저를 바꾸지 않으려면 위 명령으로 원하는 브라우저를
> 명시적으로 지정하십시오.

## 업데이트

Linux tarball과 Debian 패키지에는 브라우저 자체 업데이트 기능이 없고,
AppImage만 zsync 자체 업데이트를 제공합니다. 이 패키지는 AppImage의 zsync를
사용하지 않으므로 **pacman 기반으로 업데이트**합니다.

```bash
# 1. 최신 upstream 릴리스로 PKGBUILD 갱신 (서명 검증 포함)
./scripts/update.sh

# 특정 버전으로 고정
./scripts/update.sh 0.20.1.1

# 2. 변경 사항 확인 후 빌드/설치
./scripts/build.sh -si

# 3. 확인
pacman -Q helium-bin
helium --version
```

`scripts/update.sh`는 GitHub API에서 최신 stable 태그를 읽고, tarball과
서명을 내려받아 PGP 검증한 뒤 `pkgver`, `sha256sums`, `.SRCINFO`를
갱신합니다. `updpkgsums`는 서명 파일에 `SKIP`을 쓰지만, 스크립트가 `.asc`의
실제 SHA-256을 다시 채웁니다. 따라서 이 저장소에는 검증되지 않은 `SKIP`이
남지 않습니다.

패키징만 수정한 경우(예: `.desktop` 변경) `pkgrel`을 올립니다.

```bash
vim PKGBUILD            # pkgrel=2
./scripts/build.sh -si
```

업데이트해도 브라우저 프로필은 유지됩니다. 프로필은 패키지가 아니라
사용자 디렉터리에 있습니다.

- `~/.config/net.imput.helium`
- `~/.cache/net.imput.helium`

## 자동화 (선택)

수동 워크플로를 그대로 유지하면서, 새 릴리스 감지 → 서명/체크섬 검증 →
격리된 작업 공간에서 빌드 → 정적/패키지/샌드박스 검사 → 원자적 게시를
수행하는 스크립트가 있습니다. **저장소 루트의 `PKGBUILD`/`.SRCINFO`는
자동화가 수정하지 않습니다.** 성공한 후보만 `out/<pkgver>-<pkgrel>/`에
게시됩니다.

```bash
# 읽기 전용 확인 (파일 수정/다운로드 없음)
./scripts/check-upstream.sh
./scripts/check-upstream.sh --json

# 전체 실행: 새 버전이 없으면 아무 것도 하지 않음
./scripts/automation/run.sh

# 이미 성공한 버전을 강제로 다시 빌드
HELIUM_FORCE=1 ./scripts/automation/run.sh

# API 확인 없이 특정 버전 재현 (서명 검증은 그대로 수행)
HELIUM_VERSION=0.20.1.1 ./scripts/automation/run.sh

# 오케스트레이션 테스트 (모의 명령 사용, 네트워크/실제 빌드 없음)
./tests/automation/run-tests.sh
```

출력 구조:

```text
out/latest -> 0.20.2.1-1
out/0.20.2.1-1/
  helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst
  PKGBUILD
  .SRCINFO
  manifest.json
state/status.json     # 마지막 실행 결과(실패 포함)
logs/<run-id>.log     # 전체 로그
```

`check-upstream.sh` 종료 코드: `0` 업데이트 없음, `10` 업데이트 있음,
`20` 운영 오류(네트워크/API/잘못된 태그), `2` 사용법 오류.
`run.sh` 종료 코드: `0` 성공/변경 없음, `20` 준비 오류, `30` 빌드 실패,
`40` 검증/게시 실패, `75` 다른 실행이 잠금 보유.

테스트 결과는 manifest에 `passed`/`failed`/`skipped`와 사유로 기록됩니다.
`HELIUM_SANDBOX=auto`(기본)에서 환경이 샌드박스 테스트를 지원하지 못하면
`skipped`로 기록하며, 이를 `passed`로 보고하지 않습니다. `require`로
강제할 수 있고 `skip`은 명시적으로 건너뜁니다. 필수 검증이 실패하면
게시하지 않고 이전 `out/latest`와 기존 산출물을 보존합니다.

필요 패키지: `base-devel`, `curl`, `gnupg`, `pacman-contrib`, `python`,
`zstd`, `libarchive`, `desktop-file-utils`, `libxml2`, 그리고 선택적으로
`shellcheck`, `namcap`. 샌드박스
테스트를 실행하려면 `PKGBUILD`의 런타임 의존성과 unprivileged user
namespace가 필요합니다. 전체 옵션, 실패 복구, systemd 템플릿 배포 절차는
[`docs/AUTOMATION.md`](docs/AUTOMATION.md)를 참고하십시오.

자동화는 패키지를 설치하지 않고(`sudo`, `pacman -U`, `makepkg -i` 없음),
AUR/GitHub 등 외부에 게시/업로드하지 않으며, Git 명령을 실행하지 않습니다.
`packaging/systemd/`의 유닛은 템플릿일 뿐이며 이 저장소에서는 enable/start
하지 않습니다.

## 제거

```bash
sudo pacman -Rns helium-bin
```

제거 시 `/usr/bin/helium`, `/usr/lib/helium`, `.desktop`, 아이콘,
AppStream 메타데이터, 라이선스, AppArmor 프로필이 함께 제거됩니다.
**브라우저 프로필과 캐시는 삭제되지 않습니다.** 완전히 지우려면 사용자가
직접 삭제합니다.

```bash
rm -rf ~/.config/net.imput.helium ~/.cache/net.imput.helium
```

## Sandbox 및 보안

- 기본 실행 옵션에 `--no-sandbox`를 넣지 않았습니다.
- root로 실행하지 마십시오. root 실행은 Chromium sandbox를 무력화합니다.
- upstream tarball에는 `chrome-sandbox` setuid helper가 없습니다. Chromium
  156은 unprivileged user namespace + seccomp-bpf 기반 sandbox를 사용합니다.
- Arch Linux는 unprivileged user namespace를 기본 허용합니다. 확인:

  ```bash
  cat /proc/sys/user/max_user_namespaces
  sysctl kernel.unprivileged_userns_clone 2>/dev/null || true
  ```

- 컨테이너/커널 설정에서 user namespace가 막혀 있으면 Helium이 정상
  실행되지 않습니다. 이때 `--no-sandbox`로 우회하지 말고 namespace를
  허용하거나 sandbox를 지원하는 환경에서 실행하십시오.
- AppArmor가 unprivileged user namespace를 제한하는 배포판 설정을 위해
  upstream 프로필을 `/etc/apparmor.d/helium-bin`에 설치합니다. upstream이
  `/usr/lib/helium/apparmor.cfg`에도 같은 프로필을 두므로, 두 파일 모두
  `/opt/helium` 대신 이 패키지의 실제 실행 경로(`/usr/lib/helium/helium`)를
  가리키도록 `prepare()`에서 수정합니다. 이 환경에서는 AppArmor가 비활성
  상태라 실제 강제 적용은 검증하지 못했습니다. AppArmor를 쓰는 시스템이라면
  프로필을 로드하십시오.

  ```bash
  sudo apparmor_parser -r -W /etc/apparmor.d/helium-bin
  ```

- SELinux/AppArmor를 비활성화하는 설정을 패키지가 임의로 변경하지 않습니다.

## 데스크톱 / Wayland

- Wayland: Hyprland 0.56.2에서 native Wayland(`xwayland=false`)로 창 생성,
  HTTPS 페이지 로드, 새 창 열기, 정상 종료를 확인했습니다.
- X11: XWayland에서 `--ozone-platform=x11`로 창 생성과 HTTPS 로드를
  확인했습니다. 기본값은 환경에 따라 자동 선택됩니다.
- Wayland에서 문제가 있으면 먼저 upstream 기본 동작을 확인하고, 필요할 때만
  `--ozone-platform=wayland` 또는 `--ozone-platform=x11`을 진단용으로
  사용하십시오. 패키지는 특정 플랫폼을 강제하지 않습니다.
- 화면 공유/파일 선택기: `pipewire`, `xdg-desktop-portal` 및 데스크톱별
  portal backend가 필요할 수 있습니다. `optdepends`를 참고하십시오.
- KDE에서 Qt 테마 통합을 쓰려면 `qt5-base`/`qt6-base`를 설치합니다.
  upstream이 `libqt5_shim.so`, `libqt6_shim.so`를 함께 배포합니다.
- 비밀번호 저장: GNOME은 `gnome-keyring`, KDE는 `kwallet`.
- 배터리 상태: `upower`.
- GPU 진단: `pciutils` (`lspci`).

## 알려진 문제

- **Widevine DRM 미포함**: Netflix 등 DRM 스트리밍은 동작하지 않을 수
  있습니다. upstream tarball에 Widevine CDM이 포함되어 있지 않습니다.
- **자동 업데이트 없음**: 패키지 관리자로만 업데이트합니다. 브라우저 내부
  업데이트를 기대하지 마십시오.
- **AUR 패키지와 충돌**: `helium-browser-bin` 또는
  `helium-browser-beta-bin`이 설치되어 있으면 먼저 제거해야 합니다.
  같은 브라우저를 두 번 설치하지 않기 위한 의도적인 conflicts입니다.
- **AppArmor 프로필 미검증**: 테스트 환경에서 AppArmor가 꺼져 있어 실제
  프로필 강제 적용을 확인하지 못했습니다.
- **aarch64 미지원**: upstream은 arm64 tarball도 제공하지만 이 저장소는
  x86_64만 패키징/검증했습니다. 필요하면 `source_aarch64`,
  `sha256sums_aarch64`를 추가하고 별도로 테스트하십시오.
- **Qt5 shim 경고**: `namcap`은 `libqt5_shim.so`의 Qt5 라이브러리를
  "uninstalled dependency"로 경고합니다. Qt5 테마 통합은 선택 사항이며
  `qt5-base`를 설치하면 해결됩니다.
- **`namcap`의 "may not be needed" 경고**: `gtk3`, `libpulse`, `libva`,
  `libxss`, `pciutils`, `xdg-utils`, `ca-certificates`, `ttf-liberation`은
  ELF에 직접 링크되지 않고 dlopen/exec/런타임 기능으로 사용됩니다. 의도적으로
  `depends`/`optdepends`에 둔 항목입니다.

## 검증 결과

환경: Arch Linux rolling, kernel `7.2.11-arch1-1`, Hyprland 0.56.2
(Wayland) + XWayland, `x86_64`.

### 0.20.2.1 자동화 빌드 (2026-10-30)

`./scripts/automation/run.sh`로 감지 → 서명/체크섬 검증 → 빌드 → 검사 →
원자적 게시까지 한 번에 수행했습니다. 실제 설치(`pacman -U`)는 하지 않았습니다.

- `scripts/update.sh`로 0.20.1.1 → 0.20.2.1 갱신, PGP `Good signature` 확인
  (fingerprint `BE67 7C19 89D3 5EAB 2C5F 26C9 3516 01AD 01D6 378E`)
- `makepkg` 빌드 성공:
  `helium-bin-0.20.2.1-1-x86_64.pkg.tar.zst`
  (SHA-256 `6a914e61ab45836bb263aaf7d47b342bf56c1d48e5e5cfa0d5849f32907ddcf9`)
- 바이너리 버전 확인: `Helium 0.20.2.1 (Chromium 156.0.8078.73)`
- `bash -n` (모든 스크립트와 `PKGBUILD`), `shellcheck -S warning`
  (`scripts/`, `tests/`) 통과
- `namcap` 오류 0건. 경고는 Qt5 shim, glibc에 병합된 `libdl`/`libpthread`,
  dlopen/exec 기반 의존성에 대한 정보성 경고뿐
- `tests/check-package.sh` 18/18 통과: 파일 경로, symlink, desktop,
  아이콘, 라이선스, AppStream XML, AppArmor 경로, `--no-sandbox` 부재,
  동적 라이브러리 해석, 바이너리 버전
- `tests/check-sandbox.sh`: renderer 3/3이 `Seccomp=2` + 별도 user namespace
- 원자적 게시: `out/0.20.2.1-1/`에 패키지, `PKGBUILD`, `.SRCINFO`,
  `manifest.json` 기록, `out/latest` → `0.20.2.1-1`
- `tests/automation/run-tests.sh`: 133개 검사 통과. 모의 `curl`/`gpg`/
  `updpkgsums`/`makepkg`/`namcap`/`shellcheck`으로 no-update, 신규 릴리스,
  API 실패/rate limit/잘못된 응답, 잘못된 태그, PGP 실패, 빌드/검증 실패,
  sandbox skip, 성공 게시, 실패 후 `latest` 보존, 잠금 경합(75), 멱등
  재실행, 강제 재빌드, 3-버전 보존을 검증

### 0.20.1.1 설치/제거 (2026-10-24)

`0.20.1.1` 패키지로 실제 설치·실행·제거를 확인한 기록입니다.

- `pacman -U` 실제 설치, `pacman -Qkk` 263개 파일 무결성 확인
- `pacman -R` 제거 후 패키지 파일이 남지 않고, 테스트 프로필 파일은 유지됨
- Wayland native 창, XWayland X11 창, HTTPS `https://example.com` 로드,
  새 창 열기, SIGTERM 정상 종료
- `release` 재설치 후 동일 프로필로 재실행하여 프로필 파일 유지 확인
- `scripts/update.sh`로 0.20.1.1 → 0.19.4.1 갱신/빌드/검사 후 0.20.1.1로 복원하여 버전 갱신 경로 확인

검증하지 못한 것:

- 0.20.2.1 패키지의 실제 설치/제거 및 브라우저 실행 (빌드·구조·sandbox
  검사만 수행)
- aarch64 빌드/실행
- AppArmor/SELinux 강제 적용 환경
- Widevine, 독점 미디어 코덱, 화면 공유의 실제 스트리밍
- AUR 게시 및 AUR 사용자 환경에서의 설치
- 실제 Arch VM에서의 systemd service/timer 배포 및 실행
- 이 저장소 패키지 자체의 PGP 서명 (현재 unsigned package)

## 저장소 구조

```
PKGBUILD                                  Arch 패키지 정의
.SRCINFO                                  makepkg --printsrcinfo 결과 (AUR 형식)
README.md                                 영문 문서 (기본)
README.ko.md                              한국어 문서
keys/pgp/BE67...378E.asc                   upstream 서명 공개 키
scripts/build.sh                           임시 GnuPG home으로 makepkg 실행
scripts/update.sh                          upstream 버전/체크섬/.SRCINFO 갱신
scripts/check-upstream.sh                  읽기 전용 새 릴리스 확인
scripts/automation/run.sh                  빌드/검증/원자적 게시 오케스트레이션
tests/check-package.sh                     빌드된 패키지 구조/메타데이터 검사
tests/check-sandbox.sh                     renderer seccomp + user namespace 검사
tests/automation/                          모의 명령 기반 오케스트레이션 테스트
packaging/systemd/                         향후 VM 배포용 service/timer 템플릿
docs/AUTOMATION.md                         자동화 사용법/종료 코드/복구 절차
LICENSE                                    이 저장소 패키징 파일의 0BSD 라이선스
```

빌드 산출물(`src/`, `pkg/`, `*.pkg.tar.zst`)과 자동화 런타임 디렉터리
(`out/`, `work/`, `state/`, `logs/`)는 `.gitignore`로 제외되어 있습니다.
`helium-bin-0.20.1.1-1-x86_64.pkg.tar.zst`는 이 환경에서 실제로
빌드/설치한 결과물이며 자동화가 삭제/덮어쓰지 않습니다.

## AUR 게시

AUR 이름은 `helium-bin`으로 잡아 두었습니다(2026-10-30 확인 시 미사용).
AUR 저장소에는 `PKGBUILD`와 `.SRCINFO`만 올라가며, 빌드 산출물은 올리지
않습니다. GitHub 저장소가 원본이고 AUR은 그 파일을 그대로 미러링합니다.

```bash
# AUR 계정과 SSH 공개키 등록이 끝난 뒤
git clone ssh://aur@aur.archlinux.org/helium-bin.git
cp PKGBUILD .SRCINFO helium-bin/
cd helium-bin
git add PKGBUILD .SRCINFO
git commit -m "helium-bin 0.20.2.1-1"
git push
```

초기 등록은 AUR 웹에서 계정을 만든 뒤
<https://aur.archlinux.org/account/>에 SSH 공개키를 등록해야 합니다.
AUR SSH는 22번 포트를 사용합니다.

> 2026-10-30 기준 AUR은 자동 가입 공격 대응으로 **신규 계정 생성을 일시
> 중단**했습니다. 재개 소식은 aur-general 메일링 리스트와 Arch news에서
> 확인하십시오. 재개 후 위 절차를 그대로 진행하면 됩니다.

## Upstream 버전 갱신 절차 (수동)

1. <https://github.com/imputnet/helium-linux/releases/latest> 또는
   `https://api.github.com/repos/imputnet/helium-linux/releases/latest`에서
   stable 태그 확인
2. `./scripts/update.sh <version>` 실행
3. `PKGBUILD`의 `pkgver`, `sha256sums`, `.SRCINFO` diff 확인
4. `./scripts/build.sh`로 빌드
5. `./tests/check-package.sh`, `namcap <pkgfile>`,
   `./tests/check-sandbox.sh /usr/lib/helium/helium` 실행
6. 실제 설치 후 Wayland/X11 실행 및 프로필 유지 확인

## 라이선스

- 이 저장소의 패키징 파일: 0BSD (`LICENSE`)
- Helium: GPL-3.0-only. 설치 시
  `/usr/share/licenses/helium-bin/LICENSE`에 전체 라이선스가 설치됩니다.
- ungoogled-chromium에서 온 부분: BSD-3-Clause
  (`/usr/share/licenses/helium-bin/LICENSE.ungoogled_chromium`)
- upstream 코드/패치/바이너리의 라이선스는 upstream 저장소를 따릅니다.

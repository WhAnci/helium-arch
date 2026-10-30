# Helium package automation

This document describes the optional automation around the existing manual
workflow. The canonical `PKGBUILD` and `.SRCINFO` in the repository root are
**never modified** by the automation. A successful run publishes a separate,
self-contained candidate under `out/`.

## Non-goals and safety guarantees

The automation never:

- installs or upgrades `helium-bin` (`pacman -U`, `makepkg -i`, and `sudo` are
  never invoked);
- installs packages or changes system services;
- enables or starts the supplied systemd units;
- uploads artifacts anywhere (no AUR, GitHub, rsync, S3, or webhook);
- runs Git commands or requires the repository to be a Git checkout;
- weakens the Chromium sandbox or disables PGP verification;
- deletes `src/`, `pkg/`, or existing package archives in the repository root.

`makepkg` runs as the invoking unprivileged user. Root is rejected.

## Required dependencies

Arch Linux, `x86_64`:

| Purpose | Package / command |
| --- | --- |
| Build | `base-devel` (`makepkg`, `fakeroot`), `curl`, `gnupg` |
| Checksums / `.SRCINFO` | `pacman-contrib` (`updpkgsums`) |
| JSON and archive handling | `python3`, `zstd`, `libarchive` (`bsdtar`) |
| Locking | `util-linux` (`flock`) |
| Package content validation | `desktop-file-utils` (`desktop-file-validate`), `libxml2` (`xmllint`), `ldd` from `glibc` |
| Static checks (optional, recorded as skipped if missing) | `shellcheck`, `namcap` |
| Sandbox test | unprivileged user namespaces, `unshare`, runtime libraries from `depends` |

The build itself mostly repacks a downloaded binary, so `/usr/lib/helium/helium`
is not compiled. However, package validation resolves the binary's shared
libraries (`ldd`) and the sandbox test executes it: the host (or VM) must have
the runtime dependencies from `PKGBUILD` available, otherwise those checks fail
and the candidate is not published. Use `HELIUM_SANDBOX=skip` only when you
explicitly accept a skipped sandbox test; package content validation remains
required.

## Paths

Defaults, all configurable:

| Path | Default | Contents |
| --- | --- | --- |
| Workspace | `work/<run-id>/` | Candidate `PKGBUILD`, `.SRCINFO`, downloads, package |
| Source cache | `${XDG_CACHE_HOME:-$HOME/.cache}/helium-arch/srcdest` | Tarball, signature, metadata |
| Output | `out/` | Published candidates and `latest` symlink |
| State | `state/` | `lock`, `status.json`, upstream-check output |
| Logs | `logs/<run-id>.log` | Full stdout/stderr of each run |

Workspaces are removed after the run unless `HELIUM_KEEP_WORK=1` is set, which
is useful for inspecting a failure.

## Usage

### Dry check (read-only)

```bash
./scripts/check-upstream.sh
./scripts/check-upstream.sh --json
```

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | No update needed: up to date, local version ahead, or already built |
| `10` | Update available, or the current version has never been built |
| `20` | Operational error: network, HTTP error/rate limit, malformed API response, invalid tag, invalid local `pkgver` |
| `2` | Usage error |

The check only queries
`https://api.github.com/repos/imputnet/helium-linux/releases/latest` and reads
local files. Tags must match `X.Y[.Z...]` optionally prefixed by `v`; the `v`
prefix is normalized and reported. Set `GITHUB_TOKEN` to raise the API rate
limit (it is passed through a temporary curl config file, not argv). Use
`--repo DIR` to inspect another checkout.

### Full automation run

```bash
./scripts/automation/run.sh
```

Typical first run on a new release:

```text
check-upstream (10) -> prepare workspace (download, PGP, checksums, .SRCINFO)
-> makepkg -> metadata/artifact checks -> bash -n -> shellcheck -> namcap
-> tests/check-package.sh -> sandbox -> manifest -> atomic publish
```

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | Success, or no update / already published (no-op) |
| `20` | Operational error: arguments, dependencies, upstream check, download, PGP, checksums |
| `30` | Build failed |
| `40` | Validation or publication failed |
| `75` | Another run holds `state/lock` |

### Force a rebuild

```bash
HELIUM_FORCE=1 ./scripts/automation/run.sh
```

`HELIUM_FORCE=1` ignores the existing-success short circuit and republishes the
same `<pkgver>-<pkgrel>` directory through a temporary directory and rename.
Without it, a version that already has a successful manifest is a no-op. If the
canonical `pkgver` is newer than the upstream release (local-ahead), a forced
run is refused with exit `20` instead of silently building an older version.

### Build a specific version without the API

```bash
HELIUM_VERSION=0.20.1.1 ./scripts/automation/run.sh
```

This still downloads and PGP-verifies the release, so it is suitable for
reproducing a build or testing a version whose API check is unavailable.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `HELIUM_REPO` | repository root | Checkout to operate on |
| `HELIUM_WORK_ROOT` | `$HELIUM_REPO/work` | Per-run workspaces |
| `HELIUM_SRCDEST` | `${XDG_CACHE_HOME:-$HOME/.cache}/helium-arch/srcdest` | Source cache |
| `HELIUM_OUT` | `$HELIUM_REPO/out` | Published artifacts |
| `HELIUM_STATE` | `$HELIUM_REPO/state` | Lock and status |
| `HELIUM_LOG_DIR` | `$HELIUM_REPO/logs` | Run logs |
| `HELIUM_KEEP` | `3` | Number of successful automation versions retained |
| `HELIUM_FORCE` | `0` | `1` rebuilds despite an existing success |
| `HELIUM_VERSION` | unset | Build this version, skip the API check |
| `HELIUM_SANDBOX` | `auto` | `auto`, `skip`, or `require` |
| `HELIUM_KEEP_WORK` | `0` | `1` keeps the workspace after the run |

`HELIUM_SANDBOX` semantics:

- `auto`: probe the environment; run the test if supported, otherwise record
  `skipped` with the probe reason.
- `skip`: never run the test; always record `skipped` with
  `disabled-by-configuration`.
- `require`: the test must run and pass; an unsupported environment fails the
  run with exit `40`.

A skipped test is **never** reported as passed. A supported environment where
the test fails aborts publication.

## Output layout and manifest

```text
out/
├── latest -> 0.20.1.1-1
└── 0.20.1.1-1/
    ├── helium-bin-0.20.1.1-1-x86_64.pkg.tar.zst
    ├── PKGBUILD
    ├── .SRCINFO
    └── manifest.json
```

The published `PKGBUILD`/`.SRCINFO` are the verified candidate, not the
canonical files in the repository root. To promote a candidate manually, review
the diff and copy the files yourself; automation deliberately does not.

`manifest.json` contains:

- automation version, run id, UTC start/finish timestamps;
- upstream version, tag, and release URL;
- package name/version/release/architecture;
- artifact filename, SHA-256, and published relative path;
- validation status for signature, checksums, and metadata;
- per-test status (`passed`, `failed`, `skipped`) and skip reasons;
- overall `result` (`success`).

Only successful runs publish a manifest. Failed runs update
`state/status.json` with the result (`failed` or `error`), stage, message, run
id, log path, and last known versions. `state/status.json` is written
atomically. Values for `no-op` and `success` runs are also recorded. Usage
errors and preflight dependency failures exit before the lock is acquired, so
they only print to stderr and do not update the status file.

## Publication, retention, and recovery

Publication is staged in `out/.tmp-<run-id>/` and moved to
`out/<pkgver>-<pkgrel>` with a rename on the same filesystem. `out/latest` is
replaced only after the version directory exists. If publication fails, the
previous version and `latest` remain unchanged.

Retention keeps the newest `HELIUM_KEEP` (default 3) successful automation
manifests. The version referenced by `latest` is never removed, and a failed
run never deletes anything. Retention runs after a successful publish and is
best effort; a cleanup error leaves extra versions in place.

Recovery steps after a failure:

1. Read `state/status.json` (stage and message) and `logs/<run-id>.log`.
2. For prepare failures, check the cache and PGP key; `curl`/API problems are
   reported by `check-upstream.sh`.
3. For build or validation failures, re-run with `HELIUM_KEEP_WORK=1` and
   inspect `work/<run-id>/`.
4. Fix the cause and re-run. No cleanup is normally required; successful
   workspaces are removed automatically.
5. Use `HELIUM_FORCE=1` to rebuild a version that already has a manifest.
   This also recovers a rare failure that occurred after the version directory
   was renamed into place but before `latest` was updated: the directory is
   replaced atomically instead of conflicting with the existing path.

Stale `work/` directories from a killed process (SIGKILL) can be removed
manually; they are never reused.

## Version and `pkgrel` policy

`scripts/update.sh` documents and enforces this policy:

- when `pkgver` changes, `pkgrel` is reset to `1`;
- when `pkgver` is unchanged, the existing `pkgrel` is preserved;
- `--reset-pkgrel` forces `pkgrel=1`.

The automation prepares versions in a workspace, so the canonical `pkgrel` is
untouched. Packaging-only changes still require a human to bump `pkgrel` and
commit the canonical files if desired.

## Existing scripts

The manual workflow remains supported:

```bash
./scripts/update.sh [version]      # update canonical PKGBUILD/.SRCINFO
./scripts/build.sh -si             # build (and install only because -i was passed)
```

Automation-specific flags, all optional:

```bash
# Prepare/verify a throwaway workspace; never touch canonical files.
./scripts/update.sh --workdir /tmp/helium-candidate --cache ~/.cache/helium-src \
  --gnupg /tmp/helium-gpg 0.20.1.1

# Download and verify only.
./scripts/update.sh --check 0.20.1.1
```

`update.sh` downloads to the cache, verifies the pinned `.asc`, verifies the
release tarball with the upstream key, computes checksums with `updpkgsums`,
replaces any `SKIP` for the signature with the real SHA-256, regenerates
`.SRCINFO`, and only then renames files into the target directory. On failure it
restores the previous files.

`build.sh` accepts `BUILD_WORKDIR`, `BUILD_SRCDEST`, `BUILD_PKGDEST`, and
`BUILD_GNUPG`. Manual behaviour (temporary GnuPG home under
`~/.cache/helium-arch/gnupg`) is unchanged when those are unset.

## Testing

Focused orchestration tests use mocked `curl`, `gpg`, `updpkgsums`, `makepkg`,
`namcap`, `shellcheck`, and stubbed package/sandbox checks in a temporary fake
repository. They do not contact the network, build the real Helium tarball, or
touch the real output directories.

```bash
./tests/automation/run-tests.sh
```

Covered scenarios: no update, new release, API/network failure (including rate
limits and malformed JSON), invalid tag, check-only update, PGP failure, build
failure, validation failure, sandbox skipped, sandbox failure, successful
publication, `latest` preserved after failure, lock contention, idempotent
repeat runs, forced rebuild, and three-version retention.

## systemd deployment (future Arch VM)

The units in `packaging/systemd/` are templates and are **not installed or
enabled** by this repository. On a dedicated Arch build VM:

1. Create a non-root user and the writable paths:

   ```bash
   sudo useradd --system --home-dir /var/lib/helium-arch --create-home \
     --shell /usr/bin/nologin helium
   sudo install -d -o helium -g helium /srv/helium-arch /var/lib/helium-arch/work \
     /var/lib/helium-arch/state /var/cache/helium-arch/srcdest \
     /var/log/helium-arch /srv/helium-arch/out
   ```

2. Place the checkout at `/srv/helium-arch` and make it owned by `helium`
   (read-only for the service is enough; the service writes only to `out/`,
   `work/`, `state/`, and `logs/` if you override the defaults).
3. Install runtime and build dependencies with `pacman` (root, performed by a
   human; the automation never does this).
4. Install the units and enable the timer only when you are ready:

   ```bash
   sudo install -m644 packaging/systemd/helium-arch-build.service \
     packaging/systemd/helium-arch-build.timer /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now helium-arch-build.timer
   ```

5. Verify the first manual run as `helium` before enabling the timer:

   ```bash
   sudo -u helium env HELIUM_REPO=/srv/helium-arch \
     /srv/helium-arch/scripts/automation/run.sh
   ```

The service uses `User=helium`, `Nice=10`, idle I/O scheduling,
`CPUQuota=150%`, `MemoryMax=3G`, `TimeoutStartSec=1h`, and several sandboxing
options (`ProtectSystem=strict`, `ProtectHome=yes`,
`NoNewPrivileges=yes`, `PrivateTmp=yes`, and a narrow `ReadWritePaths` list).
No `OnFailure=` unit is shipped because no notifier is implemented; failures
are visible in `state/status.json` and the journal.

Retention and publication are local to the VM. Copying artifacts to another
host is a separate, manual operation and is intentionally not automated.

## What is not verified by this automation

- The AppArmor profile is not enforced in a typical test environment.
- A full VM/container sandbox run has not been performed as part of the test
  suite; the sandbox test runs only on a supported host.
- No AUR publication, package signing, or remote upload.
- The existing package artifact in the repository root is not rebuilt or
  replaced by automation.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| exit `75` | Another run is active; check `state/lock` and `ps` |
| exit `20`, "rate limit" | Set `GITHUB_TOKEN` or retry later |
| exit `20`, signature failure | Upstream key rotation or corrupted cache; re-download |
| exit `30` | `makepkg` failure; rerun with `HELIUM_KEEP_WORK=1` |
| exit `40`, sandbox | Runtime dependencies missing or user namespaces blocked |
| `skipped` in manifest | The specific test could not run; read `reason` |
| No update but a new tag exists | Tag is not `X.Y[.Z...]`/`vX.Y[.Z...]`; run the check with `--json` |

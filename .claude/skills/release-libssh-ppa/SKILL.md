---
name: release-libssh-ppa
description: Release a new upstream libssh version to the Ubuntu PPA — import/pull the upstream tarball, re-apply the .deb build patches, regenerate debian symbols, build per-series source packages and dput them to ppa:kedazo/libssh-0.7.x. Use for "new libssh release", "import 0.12.x", "update the PPA", "build source packages", "upload to launchpad", "bump libssh".
---

# Release libssh to the Ubuntu PPA

This repo is an upstream libssh tarball import plus Debian packaging, released as
**source-only uploads** to `ppa:kedazo/libssh-0.7.x`. Launchpad does the binary builds.

Everything is driven by **`.claude/skills/release-libssh-ppa/release.sh`**. It reproduces
the manual cycle that the git history shows, one subcommand per step, and produces the same
four commits:

```
Import from https://www.libssh.org/files/0.12/libssh-0.12.2.tar.xz
Patching for .deb building.
dch up
Releases for Ubuntu (PPA repo).
```

Paths below are relative to the repo root. `upload` is the only irreversible step and is
never run as part of `cycle`.

## Prerequisites

Already present on this machine; this is the line that installs them:

```bash
sudo apt-get install -y build-essential devscripts dput fakeroot cmake \
    libssl-dev libgcrypt20-dev libkrb5-dev zlib1g-dev pkg-config doxygen
```

Signing needs the GPG key for `kedz@kedz.eu` (`79BDBEA0AA585001`). Verify with:

```bash
.claude/skills/release-libssh-ppa/release.sh check
```

`check` reports the packaged version, the signing key, tree state, untracked files that
would leak into the source package, and whether the target series list is stale.

## Release a new version (agent path)

One command does everything except the upload:

```bash
.claude/skills/release-libssh-ppa/release.sh cycle 0.12.2
```

That runs `check → fetch → import → patch → build → symbols → changelog` and stops.
Review `git log -4` and `git show`, then:

```bash
.claude/skills/release-libssh-ppa/release.sh source-packages   # signed .dsc/.changes per series
.claude/skills/release-libssh-ppa/release.sh upload            # dput, asks for confirmation
```

Artifacts land in `../libssh-ppa-out/` (override with `LIBSSH_OUTDIR`).

### Individual steps

Run these instead of `cycle` when something needs attention mid-way:

```bash
D=.claude/skills/release-libssh-ppa/release.sh
$D check                          # preflight + series drift
$D series                         # Launchpad's supported series vs our list
$D fetch 0.12.2                   # download + verify upstream GPG signature
$D import 0.12.2                  # extract over the tree, commit the import
$D patch                          # cherry-pick the .deb patch set, auto-resolve conflicts
$D build                          # build openssl + gcrypt flavours
$D symbols 0.12.2-1up1            # regenerate debian/*.symbols, report new/removed
$D changelog 0.12.2               # dch UNRELEASED entry + commit "dch up"
$D source-packages --unsigned     # dry run: build source packages without signing
$D clean                          # remove build-*/ and tmp/release/
```

Add `--no-commit` to stage instead of commit.

## What each step actually does

- **fetch** — downloads `libssh-<ver>.tar.xz` + `.asc` from `www.libssh.org/files/<series>/`
  and verifies the signature against the libssh release key
  `88A228D89B07C2C77D0C780903D5DF8CFDD3E8E7` in a throwaway keyring under `tmp/release/`.
  Your manual flow skipped this. It hard-fails on a bad signature.
- **import** — extracts with `--strip-components=1` over the tree and stages **only the
  paths the tarball contains**, so untracked local files never end up in the import commit.
  It also lists tracked files that are absent from the new tarball (43 of them as of
  0.12.2 — e.g. `examples/ssh_server_fork.c`, `doc/that_style/`, `tests/keys/ssh_host_dsa_key`).
  Nothing is deleted automatically; `git rm` the dead ones yourself.
- **patch** — cherry-picks the most recent `Patching for .deb building.` commit
  (`git log --all --grep`). Conflicts are resolved automatically, see Gotchas.
- **build** — configures and builds both flavours with the same flags `debian/rules` uses,
  into `build-openssl/` and `build-gcrypt/`. Logs in `tmp/release/`.
- **symbols** — runs `dpkg-gensymbols` against both freshly built `.so`s and rewrites
  `debian/libssh-4.symbols` and `debian/libssh-gcrypt-4.symbols`. Reports added symbols and
  **warns loudly on disappeared ones** (ABI break). This is the step that saves a failed
  Launchpad build: source-only uploads never run `dh_makeshlibs` locally, so a stale symbols
  file only explodes on the builders, after the version number is burned.
- **changelog** — `dch --newversion <ver>-1up1 --distribution UNRELEASED`, then commits the
  changelog together with the regenerated symbols as `dch up`.
- **source-packages** — per series: `debchange --team --distribution=<series> "Release for
  <series>."` (which bumps `-1up2`, `-1up3`, …) then `dpkg-buildpackage -rfakeroot -S -I
  -I.claude -Itmp`. Commits `Releases for Ubuntu (PPA repo).`
- **upload** — refuses unsigned `.changes`, prints what it is about to push, requires you to
  type the PPA name, then `dput`s each one.

## Gotchas

- **The source package is format 1.0 NATIVE.** There is no `debian/source/format` and no
  `.orig.tar.xz` — `dpkg-source` packs *the entire working directory* into one
  `libssh_<ver>.tar.gz`. Anything sitting in the tree is uploaded to Launchpad.
- **Your existing uploads ship `.git/`.** `libssh_0.12.0-1up4.tar.gz` contains 816 `.git/`
  entries. The driver passes `-I` (plus `-I.claude -Itmp`), which drops the tarball from
  **5.03 MB to 1.18 MB** and leaves all 598 tracked files intact.
- **`-Zxz` does not work here**: `dpkg-source: error: can't build with source format '1.0':
  only supports gzip compression`.
- **`cherry-pick` of the patch commit conflicts in exactly two files, both handled:**
  - `CMakeLists.txt` — upstream bumps `project(libssh VERSION …)`, the patch pins the old
    literal. Resolved by keeping the patch's cmake-2.8-compat `if/else` block and
    substituting upstream's version into both `project()` and `set(PROJECT_VERSION …)`.
  - `release_libssh_stable_ppa.sh` (and `debian/changelog`, `debian/*.symbols`) — the patch
    commit carries these from the cycle it was authored in, so **HEAD always wins**. This
    is why editing the series list no longer breaks the next cherry-pick.
- **`debian/rules` passes `-DWITH_STATIC_LIB=ON`, which libssh 0.12 ignores**
  (`CMake Warning: Manually-specified variables were not used by the project`). Harmless.
  `BUILD_STATIC_LIB` is the live one, and it puts `libssh.a` in `<build>/src/`, not `<build>/lib/`.
- **The gcrypt MLKEM gate in the patch set is still load-bearing.** The patch raises the
  `ConfigureChecks.cmake` gate from `1.10.1` to `1.11.0`; this host has libgcrypt 1.10.3, so
  `HAVE_GCRYPT_MLKEM` stays off and the bundled `external/sntrup761.c` is compiled instead.
  Do not drop that hunk until the oldest target series ships libgcrypt ≥ 1.11.
- **`rm -fv ../libssh*` in `release_libssh_stable_ppa.sh` globs the parent directory**, which
  also holds `libssh-0.9.0/`, `libssh-git/`, `libssh-orig/` and this checkout. It survives
  only because `rm` has no `-r`. The driver deletes version-scoped filenames instead and
  moves artifacts to `../libssh-ppa-out/`.
- **`grep` on this machine is ugrep 7.5.0**, which rejects patterns GNU grep accepts —
  `grep -v '^\+\+'` dies with `ugrep: error: error at position 5 (?m)^++`. The driver uses
  `sed -n 's/^+ //p'` instead.
- **The tarball's top-level directory is the checkout directory name** (`libssh_stable_ppa`),
  not `libssh-0.12.2`. `dpkg-source` warns; Launchpad does not care. Pre-existing behaviour.
- **`questing` (25.10) is EOL** and no longer in Launchpad's supported list; `resolute`
  (26.04 LTS) was added on 2026-08-17. `check`/`series` diff the script's list against
  the live Launchpad API so this does not go stale silently.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `working tree has uncommitted tracked changes` | `import`/`source-packages` refuse to run dirty. Commit or stash. Untracked `build-*/`, `tmp/`, `compile_commands.json` are fine. |
| `unexpected conflicts — resolve by hand` | The patch set conflicts somewhere other than the four known files. Resolve, `git add`, `git cherry-pick --continue`, then `$D build && $D symbols <ver>`. |
| `signature check FAILED for libssh-<v>.tar.xz` | Wrong/tampered tarball, or upstream rotated the key. Check `tmp/release/dl/` and the key at `https://www.libssh.org/files/0x03D5DF8CFDD3E8E7_libssh_libssh_org_gpgkey.asc`. |
| `symbols DISAPPEARED — possible ABI break` | Upstream removed exported symbols. Do not upload; decide whether the SONAME must change. |
| `no built library in build-openssl` | Run `$D build` first. `$D clean` removes the build dirs. |
| `<file> is not signed — rebuild without --unsigned` | You built with `--unsigned`. Re-run `$D source-packages` (needs the GPG passphrase). |
| `dpkg-source: error: can't build with source format '1.0': only supports gzip` | Something added `-Z<compressor>`. Format 1.0 is gzip-only. |
| Launchpad rejects the upload as a duplicate version | Version numbers are burned on upload. Bump with another `debchange` and rebuild. |

## Verified on

Ubuntu 24.04.4 LTS, x86_64, cmake 3.28.3, gcc 13.3.0, libgcrypt 1.10.3, dpkg-source 1.0.
The full `cycle 0.12.2` → `source-packages --unsigned` path was run in a sandbox clone on
2026-08-17: 4 commits produced, 4 source packages built (`-1up2` jammy, `-1up3` noble,
`-1up4` questing, `-1up5` resolute), 1.18 MB each. `upload` was deliberately not run.

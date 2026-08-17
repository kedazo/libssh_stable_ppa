#!/bin/bash
# release.sh — drive the libssh -> Ubuntu PPA release cycle.
#
# Automates the manual cycle visible in git history:
#   Import from <url>  ->  Patching for .deb building.  ->  dch up  ->  Releases for Ubuntu (PPA repo).
#
# Every step is a separate subcommand so you can stop, inspect, fix and resume.
# `upload` is deliberately NOT part of `cycle` — it is the only irreversible step.
#
# David Kedves <kedz@kedz.eu> / agent tooling for .claude/skills/release-libssh-ppa

set -euo pipefail

SELF="$(basename "$0")"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$REPO/tmp/release"          # scratch: downloads, logs, keyring
PPA="${LIBSSH_PPA:-ppa:kedazo/libssh-0.7.x}"
UPSTREAM_BASE="https://www.libssh.org/files"
UPSTREAM_KEY_URL="$UPSTREAM_BASE/0x03D5DF8CFDD3E8E7_libssh_libssh_org_gpgkey.asc"
UPSTREAM_KEY_FPR="88A228D89B07C2C77D0C780903D5DF8CFDD3E8E7"
export DEBEMAIL="${DEBEMAIL:-kedz@kedz.eu}"
export DEBFULLNAME="${DEBFULLNAME:-David Kedves}"

NO_COMMIT=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- helpers

# Upstream series dir: 0.12.2 -> 0.12
series_of() { printf '%s\n' "${1%.*}"; }

tarball_url() { printf '%s/%s/libssh-%s.tar.xz\n' "$UPSTREAM_BASE" "$(series_of "$1")" "$1"; }

# Current upstream+debian version from debian/changelog, e.g. 0.12.0-1up4
deb_version() { dpkg-parsechangelog -l"$REPO/debian/changelog" -SVersion; }
upstream_version() { local v; v="$(deb_version)"; printf '%s\n' "${v%-*}"; }

require_tools() {
    local missing=()
    for t in curl gpg tar git cmake dpkg-buildpackage dpkg-gensymbols \
             dpkg-parsechangelog dch debchange fakeroot dput python3; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]}
  sudo apt-get install -y build-essential devscripts dput fakeroot cmake \
       libssl-dev libgcrypt20-dev libkrb5-dev zlib1g-dev pkg-config doxygen"
}

require_clean_tree() {
    # Untracked build dirs / compile_commands.json are fine; tracked changes are not.
    if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
        git -C "$REPO" status --short --untracked-files=no >&2
        die "working tree has uncommitted tracked changes — commit or stash first"
    fi
}

commit() {
    local msg="$1"; shift
    # No paths => caller already staged exactly what it wants committed.
    (($# == 0)) || git -C "$REPO" add -- "$@"
    if [ "$NO_COMMIT" = 1 ]; then
        warn "--no-commit: staged but not committed ($msg)"
        return
    fi
    if git -C "$REPO" diff --cached --quiet; then
        warn "nothing to commit for: $msg"
        return
    fi
    git -C "$REPO" commit -q -m "$msg"
    ok "committed: $msg"
}

# ---------------------------------------------------------------- check

cmd_check() {
    require_tools
    ok "toolchain present"

    local v; v="$(deb_version)"
    say "current packaged version: $v  (upstream $(upstream_version))"

    if gpg --list-secret-keys "$DEBEMAIL" >/dev/null 2>&1; then
        ok "signing key found for $DEBEMAIL"
    else
        warn "no secret GPG key for $DEBEMAIL — 'source-packages' cannot sign"
    fi

    say "upload target: $PPA"

    if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
        warn "tracked changes present:"
        git -C "$REPO" status --short --untracked-files=no >&2
    else
        ok "working tree clean (tracked files)"
    fi

    # The source package is format 1.0 NATIVE: whatever sits in the tree is shipped.
    local stray
    # --untracked-files=normal collapses directories to one entry each.
    stray="$(git -C "$REPO" status --porcelain --untracked-files=normal \
             | sed -n 's/^?? //p' | grep -v '^tmp/\|^build-openssl/$\|^build-gcrypt/$' || true)"
    if [ -n "$stray" ]; then
        warn "untracked files that WOULD be shipped in the native tarball:"
        printf '       %s\n' $stray >&2
        warn "  (build-*/ are removed by 'debian/rules clean'; .git is skipped via -I)"
    fi

    cmd_series
}

# ---------------------------------------------------------------- series

# Ubuntu series that Launchpad still accepts, intersected with what libssh needs
# (libssh >= 0.11 needs libssl >= 1.1.1, so jammy is the oldest usable).
lp_series() {
    curl -sSf --max-time 40 "https://api.launchpad.net/1.0/ubuntu/series" \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
keep={"Active Development","Current Stable Release","Supported","Pre-release Freeze"}
out=[]
for e in d["entries"]:
    if e["status"] in keep:
        try: ver=float(e["version"])
        except ValueError: continue
        if ver >= 22.04:                      # libssl >= 1.1.1
            out.append((ver, e["name"], e["version"], e["status"]))
for ver,name,v,s in sorted(out):
    print(f"{name}\t{v}\t{s}")
'
}

script_series() {
    sed -n 's/^ *for distro in \(.*\); do.*/\1/p' "$REPO/release_libssh_stable_ppa.sh" | tr ' ' '\n' | sed '/^$/d'
}

cmd_series() {
    say "Ubuntu series Launchpad accepts (>= 22.04):"
    local live; live="$(lp_series)" || { warn "could not reach Launchpad API"; return 0; }
    printf '%s\n' "$live" | while IFS=$'\t' read -r n v s; do printf '       %-10s %-7s %s\n' "$n" "$v" "$s"; done

    local live_names cur
    live_names="$(printf '%s\n' "$live" | cut -f1 | sort)"
    cur="$(script_series | sort)"
    say "release_libssh_stable_ppa.sh currently targets: $(script_series | tr '\n' ' ')"

    local stale fresh
    stale="$(comm -23 <(printf '%s\n' "$cur") <(printf '%s\n' "$live_names") || true)"
    fresh="$(comm -13 <(printf '%s\n' "$cur") <(printf '%s\n' "$live_names") || true)"
    [ -z "$stale" ] || warn "EOL / not accepted any more: $(printf '%s' "$stale" | tr '\n' ' ')"
    [ -z "$fresh" ] || warn "supported but NOT targeted:   $(printf '%s' "$fresh" | tr '\n' ' ')"
    [ -n "$stale$fresh" ] || ok "series list is current"
}

# ---------------------------------------------------------------- fetch

cmd_fetch() {
    local v="${1:?usage: $SELF fetch <upstream-version>}"
    mkdir -p "$WORK/dl"
    local tb="libssh-$v.tar.xz" url; url="$(tarball_url "$v")"

    say "downloading $url"
    [ -f "$WORK/dl/$tb" ]      || curl -sSfL --max-time 300 -o "$WORK/dl/$tb"      "$url"
    [ -f "$WORK/dl/$tb.asc" ]  || curl -sSfL --max-time 120 -o "$WORK/dl/$tb.asc"  "$url.asc"
    ok "$(cd "$WORK/dl" && sha256sum "$tb")"

    say "verifying upstream signature"
    local gh="$WORK/gpghome"
    if [ ! -d "$gh" ]; then
        mkdir -p "$gh"; chmod 700 "$gh"
        curl -sSfL --max-time 60 -o "$WORK/dl/upstream-key.asc" "$UPSTREAM_KEY_URL"
        GNUPGHOME="$gh" gpg --batch --quiet --import "$WORK/dl/upstream-key.asc"
    fi
    GNUPGHOME="$gh" gpg --batch --status-fd 1 --verify "$WORK/dl/$tb.asc" "$WORK/dl/$tb" 2>/dev/null \
        | grep -q "VALIDSIG $UPSTREAM_KEY_FPR" \
        || die "signature check FAILED for $tb (expected key $UPSTREAM_KEY_FPR)"
    ok "good signature from libssh release key $UPSTREAM_KEY_FPR"
}

# ---------------------------------------------------------------- import

cmd_import() {
    local v="${1:?usage: $SELF import <upstream-version>}"
    require_clean_tree
    local tb="$WORK/dl/libssh-$v.tar.xz"
    [ -f "$tb" ] || die "no verified tarball — run: $SELF fetch $v"

    say "extracting $v over the working tree"
    # Overwrite-only, like the manual workflow: files dropped upstream are NOT
    # deleted here. They are reported below so you can decide what to do.
    local members="$WORK/members-$v.txt"
    tar -tf "$tb" | sed -e 's#^[^/]*/##' -e '/^$/d' -e '\#/$#d' | sort -u > "$members"
    tar -xf "$tb" --strip-components=1 -C "$REPO"

    # Stage EXACTLY what upstream ships — never sweep up unrelated untracked
    # files (agent tooling, scratch, local notes) into the import commit.
    local n; n="$(wc -l < "$members")"
    say "upstream ships $n files; staging those paths only"
    ( cd "$REPO" && git add --pathspec-from-file="$members" -- )

    local touched; touched="$(git -C "$REPO" diff --cached --name-only | wc -l)"
    ok "$touched path(s) changed by the import"
    git -C "$REPO" diff --cached --stat | tail -1

    local stale
    stale="$(comm -23 <(git -C "$REPO" ls-files | sort) "$members" \
             | grep -v '^debian/\|^release_libssh_stable_ppa.sh$\|^\.claude/' || true)"
    if [ -n "$stale" ]; then
        warn "$(printf '%s\n' "$stale" | wc -l) tracked file(s) are absent from the $v tarball:"
        printf '       %s\n' $stale >&2
        warn "  either dropped by upstream or never shipped in tarballs (CI configs)."
        warn "  We still ship them in the native source package. 'git rm' the dead ones."
    fi

    commit "Import from $(tarball_url "$v")"
}

# ---------------------------------------------------------------- patch

# The recurring downstream patch set lives in the previous cycle's
# "Patching for .deb building." commit. Cherry-pick it forward.
last_patch_commit() {
    git -C "$REPO" log --format='%H %s' --all \
        | grep -i 'Patching for .deb building' \
        | head -1 | cut -d' ' -f1
}

cmd_patch() {
    local pc="${1:-$(last_patch_commit)}"
    [ -n "$pc" ] || die "could not find a previous 'Patching for .deb building.' commit"
    say "cherry-picking $(git -C "$REPO" log --oneline -1 "$pc")"

    if git -C "$REPO" cherry-pick -x "$pc"; then
        ok "applied cleanly"
        return
    fi

    local conflicts; conflicts="$(git -C "$REPO" diff --name-only --diff-filter=U)"
    say "conflicts: $(printf '%s' "$conflicts" | tr '\n' ' ')"

    # The patch commit also carries packaging state (the series list, the symbols
    # files, the changelog) from the cycle it was authored in. Those are stale by
    # definition: HEAD's copy is authoritative and the symbols get regenerated
    # later by `symbols`. So for these paths, ours (HEAD) always wins.
    local f
    for f in $conflicts; do
        case "$f" in
            release_libssh_stable_ppa.sh|debian/changelog|debian/*.symbols)
                git -C "$REPO" checkout --ours -- "$f"
                git -C "$REPO" add -- "$f"
                ok "kept HEAD's $f (patch commit's copy is from an older cycle)"
                ;;
        esac
    done
    conflicts="$(git -C "$REPO" diff --name-only --diff-filter=U)"

    # The remaining expected conflict is the version literal in CMakeLists.txt:
    # upstream bumps it, the patch pins the old one. Keep the patch's cmake-compat
    # structure and adopt upstream's version.
    if [ -z "$conflicts" ]; then
        git -C "$REPO" -c core.editor=true cherry-pick --continue >/dev/null
        ok "resolved and committed"
        return
    fi

    if [ "$conflicts" = "CMakeLists.txt" ]; then
        local upv
        upv="$(git -C "$REPO" show :2:CMakeLists.txt | sed -n 's/^project(libssh VERSION \([0-9][0-9.]*\).*/\1/p' | head -1)"
        [ -n "$upv" ] || die "cannot read upstream version from CMakeLists.txt — resolve by hand"
        say "auto-resolving CMakeLists.txt to upstream version $upv"
        ( cd "$REPO" && UPV="$upv" python3 - <<'PY'
import re, os
v = os.environ['UPV']
s = open('CMakeLists.txt').read()
pat = re.compile(r'^<{7}[^\n]*\n(.*?)^={7}\n(.*?)^>{7}[^\n]*\n', re.S | re.M)
def fix(m):
    theirs = m.group(2)
    theirs = re.sub(r'(project\(libssh VERSION )[0-9][0-9.]*', r'\g<1>'+v, theirs)
    theirs = re.sub(r'(set\(PROJECT_VERSION ")[0-9][0-9.]*', r'\g<1>'+v, theirs)
    return theirs
s, n = pat.subn(fix, s)
if '<<<<<<<' in s or '>>>>>>>' in s:
    raise SystemExit('unresolved conflict markers remain in CMakeLists.txt')
open('CMakeLists.txt','w').write(s)
print(f'resolved {n} conflict block(s) -> {v}')
PY
        )
        git -C "$REPO" add CMakeLists.txt
        git -C "$REPO" -c core.editor=true cherry-pick --continue >/dev/null
        ok "resolved and committed"
    else
        die "unexpected conflicts — resolve by hand, then:
  git add <files> && git cherry-pick --continue
  $SELF build && $SELF symbols <new-deb-version>"
    fi
}

# ---------------------------------------------------------------- build

flavour_lib() {  # echo path of the built .so for a flavour
    local d="$1"
    find "$REPO/$d/lib" -maxdepth 1 -name '*.so.4.*' -print -quit 2>/dev/null
}

cmd_build() {
    # CMake 4.x removed compatibility with cmake_minimum_required < 3.5, so a
    # too-low minimum configures fine here but hard-fails on the newer builders
    # (this killed 0.12.2-1up4/-1up5 on resolute/stonking). Catch it locally,
    # where the version number has not been burned yet.
    local minreq
    minreq="$(sed -n 's/^[[:space:]]*cmake_minimum_required([[:space:]]*VERSION[[:space:]]*\([0-9][0-9.]*\).*/\1/Ip' \
        "$REPO/CMakeLists.txt" | head -1)"
    [ -n "$minreq" ] || die "cannot read cmake_minimum_required from CMakeLists.txt"
    if [ "$(printf '%s\n3.5\n' "$minreq" | sort -V | head -1)" != "3.5" ]; then
        die "cmake_minimum_required is $minreq — CMake 4.x rejects anything below 3.5.
  Builds would fail on resolute/stonking. Restore upstream's value in CMakeLists.txt."
    fi
    ok "cmake_minimum_required $minreq (>= 3.5, safe for CMake 4.x builders)"

    say "building both flavours (same flags as debian/rules)"
    local common=(-DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_STATIC_LIB=ON
                  -DWITH_GSSAPI=ON -DWITH_NACL=0)
    mkdir -p "$WORK"

    cmake -B "$REPO/build-openssl" -S "$REPO" "${common[@]}" \
        > "$WORK/configure-openssl.log" 2>&1 || { tail -20 "$WORK/configure-openssl.log"; die "configure (openssl) failed"; }
    cmake --build "$REPO/build-openssl" -j"$(nproc)" \
        > "$WORK/build-openssl.log" 2>&1 || { tail -40 "$WORK/build-openssl.log"; die "build (openssl) failed"; }
    ok "openssl flavour: $(basename "$(flavour_lib build-openssl)")"

    cmake -B "$REPO/build-gcrypt" -S "$REPO" "${common[@]}" \
        -DWITH_GCRYPT=ON -DLIBSSH_LIBRARY_NAME=ssh-gcrypt \
        -DCMAKE_SHARED_LIBRARY_SUFFIX="-gcrypt" \
        > "$WORK/configure-gcrypt.log" 2>&1 || { tail -20 "$WORK/configure-gcrypt.log"; die "configure (gcrypt) failed"; }
    cmake --build "$REPO/build-gcrypt" -j"$(nproc)" \
        > "$WORK/build-gcrypt.log" 2>&1 || { tail -40 "$WORK/build-gcrypt.log"; die "build (gcrypt) failed"; }
    ok "gcrypt flavour:  $(basename "$(flavour_lib build-gcrypt)")"
}

# ---------------------------------------------------------------- symbols

# Launchpad builders run dh_makeshlibs, which FAILS the binary build when the
# shipped .so exports symbols missing from debian/*.symbols. Source-only uploads
# do not catch that locally — so regenerate and diff here, before uploading.
one_symbols() {
    local pkg="$1" dir="$2" ver="$3"
    local lib; lib="$(flavour_lib "$dir")"
    [ -n "$lib" ] || die "no built library in $dir — run: $SELF build"
    local cur="$REPO/debian/$pkg.symbols" new="$WORK/$pkg.symbols.new"

    dpkg-gensymbols -q -p"$pkg" -v"$ver" -e"$lib" -I"$cur" -O"$new"

    local added removed
    added="$(diff -u "$cur" "$new" | sed -n 's/^+ //p' | grep -F "$ver" || true)"
    removed="$(comm -23 \
        <(sed -n 's/^ \([A-Za-z_][A-Za-z0-9_]*@[A-Z0-9_]*\).*/\1/p' "$cur" | sort -u) \
        <(sed -n 's/^ \([A-Za-z_][A-Za-z0-9_]*@[A-Z0-9_]*\).*/\1/p' "$new" | sort -u))"

    if [ -n "$added" ]; then
        say "$pkg: new symbols"
        printf '       %s\n' $(printf '%s\n' "$added" | cut -d@ -f1)
    else
        ok "$pkg: no new symbols"
    fi
    if [ -n "$removed" ]; then
        warn "$pkg: symbols DISAPPEARED — possible ABI break, review before uploading:"
        printf '       %s\n' $removed >&2
        SYMBOLS_ABI_WARN=1
    fi
    cp "$new" "$cur"
}

cmd_symbols() {
    local ver="${1:-$(deb_version)}"
    SYMBOLS_ABI_WARN=0
    mkdir -p "$WORK"
    say "regenerating symbols files at version $ver"
    one_symbols libssh-4        build-openssl "$ver"
    one_symbols libssh-gcrypt-4 build-gcrypt  "$ver"
    [ "$SYMBOLS_ABI_WARN" = 0 ] || warn "ABI warnings above — do not upload until understood"
    if git -C "$REPO" diff --quiet -- debian/libssh-4.symbols debian/libssh-gcrypt-4.symbols; then
        ok "symbols files already up to date"
    else
        ok "symbols files updated (commit them with the 'dch up' step)"
    fi
}

# ---------------------------------------------------------------- changelog

cmd_changelog() {
    local v="${1:?usage: $SELF changelog <upstream-version> [deb-rev]}"
    local rev="${2:-1up1}"
    say "adding changelog entry $v-$rev (UNRELEASED)"
    ( cd "$REPO" && dch --newversion "$v-$rev" --distribution UNRELEASED \
        "Import from $(tarball_url "$v")" )
    sed -n '1,6p' "$REPO/debian/changelog"
    commit "dch up" debian/changelog debian/libssh-4.symbols debian/libssh-gcrypt-4.symbols
}

# ---------------------------------------------------------------- source packages

OUTDIR_DEFAULT="$REPO/../libssh-ppa-out"

cmd_source_packages() {
    local sign=1
    [ "${1:-}" != "--unsigned" ] || { sign=0; shift; }
    local -a distros=("$@")
    if ((${#distros[@]} == 0)); then
        mapfile -t distros < <(script_series)
    fi
    ((${#distros[@]} > 0)) || die "no target series"

    require_clean_tree
    local upv; upv="$(upstream_version)"
    local out="${LIBSSH_OUTDIR:-$OUTDIR_DEFAULT}"
    mkdir -p "$out"

    say "building source packages for: ${distros[*]}"
    say "artifacts -> $out"

    # dpkg-buildpackage always writes to the parent dir; clear only THIS version's
    # files there (the upstream script's 'rm -fv ../libssh*' also matches sibling
    # checkout directories).
    rm -f "$REPO"/../libssh_"$upv"-*.dsc "$REPO"/../libssh_"$upv"-*.tar.gz \
          "$REPO"/../libssh_"$upv"-*_source.* 2>/dev/null || true

    local d
    for d in "${distros[@]}"; do
        say "--- $d ---"
        ( cd "$REPO" && debchange --team --distribution="$d" "Release for $d." )
        local ver; ver="$(deb_version)"
        # -I  : default VCS excludes, keeps .git out of the native tarball (~4 MB)
        # -I. : agent tooling and scratch are not part of the source package
        local -a flags=(-rfakeroot -S -I -I.claude -Itmp)
        [ "$sign" = 1 ] || flags+=(-us -uc)
        ( cd "$REPO" && dpkg-buildpackage "${flags[@]}" ) > "$WORK/src-$d.log" 2>&1 \
            || { tail -25 "$WORK/src-$d.log"; die "source build for $d failed (log: $WORK/src-$d.log)"; }
        ok "$ver -> $d  ($(du -h "$REPO/../libssh_$ver.tar.gz" | cut -f1) tarball)"
        mv -f "$REPO"/../libssh_"$ver".dsc "$REPO"/../libssh_"$ver".tar.gz \
              "$REPO"/../libssh_"$ver"_source.* "$out"/ 2>/dev/null || true
    done

    say "built:"
    ls -1 "$out"/*_source.changes | while read -r c; do printf '       %s\n' "$(basename "$c")"; done
    commit "Releases for Ubuntu (PPA repo)." debian/changelog
    warn "nothing uploaded yet — review, then: $SELF upload"
}

# ---------------------------------------------------------------- upload

cmd_upload() {
    local out="${LIBSSH_OUTDIR:-$OUTDIR_DEFAULT}"
    local -a changes
    mapfile -t changes < <(ls -1 "$out"/*_source.changes 2>/dev/null || true)
    ((${#changes[@]} > 0)) || die "no *_source.changes in $out — run: $SELF source-packages"

    say "about to upload to $PPA:"
    printf '       %s\n' "${changes[@]##*/}"
    local c
    for c in "${changes[@]}"; do
        if ! gpg --verify "$c" >/dev/null 2>&1; then
            die "$(basename "$c") is not signed — rebuild without --unsigned (needs your GPG key)"
        fi
    done
    ok "all .changes files are signed"

    printf '\033[1;33mThis pushes to Launchpad and CANNOT be undone (a version number is burned forever).\033[0m\n'
    read -r -p "Type the PPA name to confirm [$PPA]: " answer
    [ "$answer" = "$PPA" ] || die "aborted"

    for c in "${changes[@]}"; do
        say "dput $(basename "$c")"
        dput "$PPA" "$c"
    done
    ok "uploaded — watch https://launchpad.net/~kedazo/+archive/ubuntu/libssh-0.7.x/+packages"
}

# ---------------------------------------------------------------- cycle

cmd_cycle() {
    local v="${1:?usage: $SELF cycle <upstream-version>}"
    cmd_check
    cmd_fetch "$v"
    cmd_import "$v"
    cmd_patch
    cmd_build
    cmd_symbols "$v-1up1"
    cmd_changelog "$v"
    say "----------------------------------------------------------------"
    ok  "$v imported, patched, built and changelogged"
    say "review the diff, then:"
    printf '       %s source-packages     # signed .dsc/.changes per series\n' "$SELF"
    printf '       %s upload              # dput to %s\n' "$SELF" "$PPA"
}

cmd_clean() {
    say "removing build dirs and scratch"
    rm -rf "$REPO/build-openssl" "$REPO/build-gcrypt" "$WORK"
    ok "clean"
}

usage() {
    cat <<EOF
$SELF — libssh -> Ubuntu PPA release driver   (repo: $REPO)

  check                        preflight: tools, GPG key, tree state, series drift
  series                       compare Launchpad's supported series with the script's list
  fetch <ver>                  download libssh-<ver>.tar.xz + verify upstream signature
  import <ver>                 extract over the tree, commit "Import from <url>"
  patch [commit]               cherry-pick the deb patch set, auto-resolve the version conflict
  build                        build openssl + gcrypt flavours (debian/rules flags)
  symbols [deb-ver]            regenerate debian/*.symbols, report new/removed symbols
  changelog <ver> [rev]        dch UNRELEASED entry + commit "dch up"
  source-packages [--unsigned] [series...]
                               per-series debchange + dpkg-buildpackage -S -I
  upload                       dput the built .changes to $PPA  (asks for confirmation)
  cycle <ver>                  check->fetch->import->patch->build->symbols->changelog
  clean                        remove build-*/ and tmp/release/

Options:  --no-commit          stage changes instead of committing
Env:      LIBSSH_PPA, LIBSSH_OUTDIR, DEBEMAIL, DEBFULLNAME
EOF
}

# ---------------------------------------------------------------- dispatch

args=()
for a in "$@"; do
    case "$a" in
        --no-commit) NO_COMMIT=1 ;;
        *) args+=("$a") ;;
    esac
done
set -- "${args[@]:-}"

case "${1:-}" in
    check)            shift; cmd_check "$@" ;;
    series)           shift; cmd_series "$@" ;;
    fetch)            shift; cmd_fetch "$@" ;;
    import)           shift; cmd_import "$@" ;;
    patch)            shift; cmd_patch "$@" ;;
    build)            shift; cmd_build "$@" ;;
    symbols)          shift; cmd_symbols "$@" ;;
    changelog)        shift; cmd_changelog "$@" ;;
    source-packages)  shift; cmd_source_packages "$@" ;;
    upload)           shift; cmd_upload "$@" ;;
    cycle)            shift; cmd_cycle "$@" ;;
    clean)            shift; cmd_clean "$@" ;;
    ""|-h|--help)     usage ;;
    *)                usage; die "unknown command: $1" ;;
esac

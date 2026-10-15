#!/bin/bash
# make-qmx-panadapter-nas.sh - build the NAS ("network radio") version of
# QMX-Panadapter from the upstream repository plus this kit's patch series.
#
#   bash make-qmx-panadapter-nas.sh                 newest upstream release -> ~/src/QMX-Panadapter-NAS
#   bash make-qmx-panadapter-nas.sh --ref v1.19.0   a specific upstream tag (or branch/commit)
#   bash make-qmx-panadapter-nas.sh --force         rebuild even if NAS is already on that release
#   bash make-qmx-panadapter-nas.sh --mark-tested   after flashing and testing NAS on the hardware:
#                                                   copy it to ~/src/QMX-Panadapter-Shared
#   bash make-qmx-panadapter-nas.sh --status        what is in NAS and Shared
#
# The kit travels with the build: every new QMX-Panadapter-NAS gets a copy of
# it in tools/nas-kit (scripts, README and the current patch series), so it can
# be run from ~/src/QMX-Panadapter-NAS/tools/nas-kit to build the next version.
# Run from there, it first copies itself to a temporary folder, because a
# rebuild moves that QMX-Panadapter-NAS folder to the archive.
#
# The two folders:
#   ~/src/QMX-Panadapter-NAS     newest upstream release + the patches. Build, flash
#                                and test it from here (bash tools/mac-build-flash.sh).
#   ~/src/QMX-Panadapter-Shared  the last version that was built AND tested on the
#                                hardware. Only --mark-tested (or the very first run,
#                                see below) changes it, so a new upstream release
#                                that does not work never replaces a working one.
#
# Nothing is deleted. A NAS or Shared folder that is replaced is moved to
# ~/src/.qmx-panadapter-archive/<name>-<version>-<date>.
#
# The patches in ./patches are the NAS commits ported to upstream v1.19.0 on
# 2026-10-14, exported with
# `git format-patch --binary v1.19.0..<branch> -- . ':(exclude)tools/nas-kit'`.
# Earlier series are kept for reference in the master copy of the kit
# (~/src/qmx-panadapter-v1.16/tools/nas-kit); the script does not use them.
# On a newer upstream release the patches are applied with git's 3-way merge; if upstream
# changed the same lines, the run stops, says which patch did not apply, and
# leaves NAS and Shared untouched.
#
# First run: if Shared does not exist yet and the release is TESTED_BASE (the
# one this patch series was tested on), the result is the tested code, so it
# is also copied to Shared and marked tested. TESTED_BASE is left empty, so
# initially the kit treats no release as tested and a first build is not copied
# to Shared on its own: test it, then run --mark-tested.
#
# Needs: git, and network access to github.com. Works with macOS's bash 3.2.

set -u
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/SteffenLav/qmx-panadapter}"
SRC="${QMX_SRC_DIR:-$HOME/src}"
NAS="$SRC/QMX-Panadapter-NAS"
SHARED="$SRC/QMX-Panadapter-Shared"
ARCHIVE="$SRC/.qmx-panadapter-archive"
KIT="$(cd "$(dirname "$0")" && pwd)"
PATCHES="$KIT/patches"
TESTED_BASE=""                  # release this patch series was hardware-tested on ("" = not yet)
STAMP=".qmx-nas-build"          # in each tree: what it was built from
TESTED=".qmx-nas-tested"        # in each tree: when it was marked tested
BRANCH="network-radio"

say()  { printf '%s\n' "$*"; }
die()  { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
lc()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }   # macOS paths ignore case

# Running from the copy inside QMX-Panadapter-NAS or -Shared: a rebuild (or
# --mark-tested, for Shared) moves that folder to the archive while this script
# runs, so continue from a temporary copy of the kit instead.
case "$(lc "$KIT")/" in
    "$(lc "$NAS")/"*|"$(lc "$SHARED")/"*)
        if [ -z "${QMX_KIT_HOME:-}" ]; then
            _t="$(mktemp -d "${TMPDIR:-/tmp}/qmx-nas-kit.XXXXXX")" || die "cannot make a temporary folder"
            cp -Rp "$KIT/." "$_t/" || die "cannot copy the kit to $_t"
            QMX_KIT_HOME="$KIT" exec bash "$_t/$(basename "$0")" "$@"
        fi ;;
esac
now()  { date '+%Y-%m-%d %H:%M'; }
stampval() { [ -f "$1/$STAMP" ] && sed -n "s/^$2=//p" "$1/$STAMP" | head -1; }

patch_set_id() {   # one checksum over the whole patch series
    if command -v shasum >/dev/null 2>&1; then cat "$PATCHES"/*.patch | shasum -a 256 | cut -c1-12
    else cat "$PATCHES"/*.patch | sha256sum | cut -c1-12; fi
}

archive_move() {   # archive_move <dir> <label>   - move aside, never delete
    [ -d "$1" ] || return 0
    mkdir -p "$ARCHIVE" || die "cannot create $ARCHIVE"
    local base; base="$(stampval "$1" base)"; [ -n "$base" ] || base="unknown"
    local dest="$ARCHIVE/$2-$base-$(date '+%Y%m%d-%H%M%S')"
    mv "$1" "$dest" || die "cannot move $1 to $dest"
    say "  moved the previous $(basename "$1") to $dest"
}

hide_markers() {   # keep the marker files out of `git status`
    local ex="$1/.git/info/exclude"
    for f in "$STAMP" "$TESTED"; do
        grep -qx "/$f" "$ex" 2>/dev/null || printf '/%s\n' "$f" >> "$ex"
    done
}

latest_release() {   # newest vX.Y.Z tag upstream, compared numerically
    git ls-remote --tags --refs "$UPSTREAM_URL" 2>/dev/null \
      | sed -n 's#.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' \
      | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | sed 's/^/v/'
}

copy_to_shared() {   # copy_to_shared <tree>
    archive_move "$SHARED" "Shared"
    cp -Rp "$1" "$SHARED" || die "cannot copy $1 to $SHARED"
    say "  copied to $SHARED"
}

status() {
    for d in "$NAS" "$SHARED"; do
        say "$(basename "$d"):"
        if [ ! -d "$d" ]; then say "  (not created yet)"; continue; fi
        say "  upstream release : $(stampval "$d" base)  ($(stampval "$d" upstream_commit))"
        say "  patch series     : $(stampval "$d" patches)  (kit now: $(patch_set_id))"
        say "  built            : $(stampval "$d" built)"
        if [ -f "$d/$TESTED" ]; then say "  tested           : $(cat "$d/$TESTED")"
        else say "  tested           : NO - flash it, test it, then run --mark-tested"; fi
    done
}

mark_tested() {
    [ -d "$NAS/.git" ] || die "$NAS does not exist - build it first"
    printf '%s (marked by %s)\n' "$(now)" "$(id -un)" > "$NAS/$TESTED"
    say "Marked $NAS as tested."
    copy_to_shared "$NAS"
    say "Shared now holds $(stampval "$NAS" base) + patch series $(stampval "$NAS" patches)."
}

build() {
    local ref="$1" force="$2"
    command -v git >/dev/null 2>&1 || die "git is not installed"
    ls "$PATCHES"/*.patch >/dev/null 2>&1 || die "no patches in $PATCHES"
    mkdir -p "$SRC" || die "cannot create $SRC"

    if [ -z "$ref" ]; then
        say "Asking $UPSTREAM_URL for its newest release ..."
        ref="$(latest_release)"
        [ -n "$ref" ] || die "could not read the release tags (network? URL?)"
    fi
    local pid; pid="$(patch_set_id)"
    say "Upstream release: $ref    patch series: $pid ($(ls "$PATCHES"/*.patch | wc -l | tr -d ' ') patches)"

    if [ "$force" = 0 ] && [ -d "$NAS" ] && [ "$(stampval "$NAS" base)" = "$ref" ] \
       && [ "$(stampval "$NAS" patches)" = "$pid" ]; then
        say "$NAS is already $ref with this patch series - nothing to do (--force rebuilds)."
        status; return 0
    fi

    local tmp="$SRC/.QMX-Panadapter-NAS.new"
    [ -e "$tmp" ] && archive_move "$tmp" "incomplete"
    say "Cloning upstream ..."
    git clone --quiet "$UPSTREAM_URL" "$tmp" || die "git clone failed"
    ( cd "$tmp" && git checkout --quiet -b "$BRANCH" "$ref" ) || die "upstream has no $ref"
    local commit; commit="$(cd "$tmp" && git rev-parse --short HEAD)"
    printf 'base=%s\n' "$ref" > "$tmp/$STAMP"     # so a failed attempt is archived by name

    say "Applying the NAS patches on $ref ($commit) ..."
    local name email
    name="$(git config --global user.name 2>/dev/null)";  [ -n "$name" ]  || name="QMX NAS kit"
    email="$(git config --global user.email 2>/dev/null)"; [ -n "$email" ] || email="qmx-nas-kit@localhost"
    if ! ( cd "$tmp" && git -c user.name="$name" -c user.email="$email" \
             am --quiet --3way --committer-date-is-author-date "$PATCHES"/*.patch ); then
        local bad; bad="$(cd "$tmp" && git am --show-current-patch 2>/dev/null | sed -n 's/^Subject: //p' | head -1)"
        ( cd "$tmp" && git am --abort >/dev/null 2>&1 )
        say ""
        say "The patch series does not apply cleanly to $ref."
        [ -n "$bad" ] && say "  First patch that failed: $bad"
        say "  Upstream changed the same code the NAS changes touch. $NAS and"
        say "  $SHARED were NOT changed. The failed attempt is kept for inspection."
        archive_move "$tmp" "failed"
        exit 2
    fi

    # The kit travels with the build (see the top of this file): scripts, README
    # and the current patch series, so the new folder can build the next version.
    mkdir -p "$tmp/tools/nas-kit/patches" || die "cannot create $tmp/tools/nas-kit"
    cp -p "$KIT"/*.sh "$KIT"/README.md "$tmp/tools/nas-kit/" || die "cannot copy the kit scripts"
    cp -p "$PATCHES"/*.patch "$tmp/tools/nas-kit/patches/" || die "cannot copy the patch series"
    ( cd "$tmp" && git add tools/nas-kit && git -c user.name="$name" -c user.email="$email" \
          commit --quiet -m "nas-kit: the update kit that built this folder (patch series $pid)" ) \
        || die "cannot commit the kit copy"

    # Sanity: the files the NAS build depends on are there.
    local f
    for f in main/net/radio_relay.c tools/nas-relay/qmx_nas_relay.py tools/mac-build-flash.sh \
             tools/patches/apply_esp_hosted_sdio_split_psram.ps1 M5StackTab5QMX+SharedOverNetwork.pdf \
             tools/mac-serial-bridge/qmx_serial_bridge.py tools/pi-relay/install-pi.sh \
             tools/nas-kit/make-qmx-panadapter-nas.sh tools/nas-kit/push-to-github.sh; do
        [ -f "$tmp/$f" ] || die "applied, but $f is missing - not replacing $NAS"
    done

    {
        printf 'base=%s\n' "$ref"
        printf 'upstream_commit=%s\n' "$commit"
        printf 'upstream_url=%s\n' "$UPSTREAM_URL"
        printf 'patches=%s\n' "$pid"
        printf 'built=%s\n' "$(now)"
    } > "$tmp/$STAMP"
    hide_markers "$tmp"

    archive_move "$NAS" "NAS"
    mv "$tmp" "$NAS" || die "cannot move the new tree to $NAS"
    say "Created $NAS  ($ref + NAS patches, branch $BRANCH)"

    if [ ! -d "$SHARED" ] && [ -n "$TESTED_BASE" ] && [ "$ref" = "$TESTED_BASE" ]; then
        printf '%s (patch series hardware-tested on %s)\n' "$(now)" "$TESTED_BASE" > "$NAS/$TESTED"
        say "First run on the tested release $TESTED_BASE - this is the tested code:"
        copy_to_shared "$NAS"
    fi

    say ""
    say "Next: cd \"$NAS\" && bash tools/mac-build-flash.sh"
    say "      (power the Tab5 off and on after flashing; then test touch, NAS stream, Radio source)"
    if [ ! -f "$NAS/$TESTED" ]; then
        say "      When it works: bash \"$NAS/tools/nas-kit/$(basename "$0")\" --mark-tested"
    fi
}

ref=""; force=0; action="build"
while [ $# -gt 0 ]; do
    case "$1" in
        --ref)          ref="${2:-}"; [ -n "$ref" ] || die "--ref needs a tag"; shift ;;
        --force)        force=1 ;;
        --mark-tested)  action="mark" ;;
        --status)       action="status" ;;
        -h|--help)      sed -n '2,36p' "$0"; exit 0 ;;
        *)              die "unknown option $1 (see --help)" ;;
    esac
    shift
done

case "$action" in
    build)  build "$ref" "$force" ;;
    mark)   mark_tested ;;
    status) status ;;
esac

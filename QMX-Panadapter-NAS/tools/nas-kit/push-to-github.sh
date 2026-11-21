#!/bin/bash
# push-to-github.sh - publish ~/src/QMX-Panadapter-NAS and ~/src/QMX-Panadapter-Shared
# to https://github.com/jpwatters/QMX-PanadapterShared, side by side, with the
# NAS folder's README.md as the repository's front page.
#
#   bash ~/src/QMX-Panadapter-NAS/tools/nas-kit/push-to-github.sh
#
# What it does:
#   1. Clones the GitHub repository into ~/src/QMX-PanadapterShared (or updates
#      that clone if it is already there).
#   2. Replaces QMX-Panadapter-NAS/ and QMX-Panadapter-Shared/ in it with a
#      snapshot of each folder's committed files (`git archive HEAD`): no .git,
#      no build output, nothing uncommitted.
#   3. Copies QMX-Panadapter-NAS/README.md to the top as README.md, with its
#      relative links and images pointed into QMX-Panadapter-NAS/ so they work.
#   4. Commits (only if something changed) and pushes.
# Run it again after each new tested version; it updates the same repository.
#
# Sign-in: an SSH key GitHub knows (`ssh -T git@github.com` greets you by name).
# For HTTPS instead: REPO_URL=https://github.com/jpwatters/QMX-PanadapterShared.git and `gh auth login`.
set -euo pipefail

SRC="${QMX_SRC_DIR:-$HOME/src}"
REPO_URL="${REPO_URL:-git@github.com:jpwatters/QMX-PanadapterShared.git}"   # SSH key sign-in
WORK="${WORK:-$SRC/QMX-PanadapterShared}"
BRANCH="${BRANCH:-main}"
FOLDERS="QMX-Panadapter-NAS QMX-Panadapter-Shared"

say() { printf '%s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

for f in $FOLDERS; do
    [ -d "$SRC/$f/.git" ] || die "$SRC/$f is not there (or is not a git folder)"
    if [ -n "$(git -C "$SRC/$f" status --porcelain --untracked-files=no)" ]; then
        die "$SRC/$f has uncommitted changes - commit them first (only committed files are published)"
    fi
done

# 1. the local clone of the GitHub repository
if [ ! -d "$WORK/.git" ]; then
    say "Cloning $REPO_URL into $WORK ..."
    git clone "$REPO_URL" "$WORK" || die "git clone failed - does the repository exist, and can this Mac sign in to GitHub?"
fi
cd "$WORK"
if git rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1 || git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    git fetch -q origin || die "cannot reach $REPO_URL - check the network and that this Mac can sign in to GitHub"
    git checkout -q -B "$BRANCH" "origin/$BRANCH"
else
    git checkout -q -B "$BRANCH" 2>/dev/null || true    # empty repository: first push
fi

# 2. fresh snapshots of both folders
msg_lines=""
for f in $FOLDERS; do
    rm -rf "$WORK/$f"
    mkdir -p "$WORK/$f"
    git -C "$SRC/$f" archive HEAD | tar -x -C "$WORK/$f"
    base="$(sed -n 's/^base=//p' "$SRC/$f/.qmx-nas-build" 2>/dev/null | head -1)"
    tested="$(head -1 "$SRC/$f/.qmx-nas-tested" 2>/dev/null | cut -c1-16)"
    head="$(git -C "$SRC/$f" log -1 --format='%h %s' | cut -c1-72)"
    msg_lines="$msg_lines
$f: upstream ${base:-?}, commit $head${tested:+, tested $tested}"
    say "  $f: snapshot of ${head%% *} (${base:-?})"
done

# 3. front page = the NAS folder's README, links pointed into its folder
python3 - "$WORK/QMX-Panadapter-NAS/README.md" "$WORK/README.md" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
def fix(m):
    lead, url = m.group(1), m.group(2)
    if re.match(r"^([a-z][a-z0-9+.-]*:|#|/)", url, re.I):
        return m.group(0)                  # web links, anchors, absolute paths stay
    return f"{lead}QMX-Panadapter-NAS/{url}"
text = re.sub(r"(\]\()\s*([^)\s]+)", fix, text)                       # [text](path) and ![img](path)
text = re.sub(r'((?:src|href)=")([^"]+)', fix, text)                  # <img src="..."> / <a href="...">
open(dst, "w", encoding="utf-8").write(text)
PY
[ -f "$WORK/.gitignore" ] || printf '.DS_Store\n' > "$WORK/.gitignore"

# 4. commit if anything changed, then push. --force: upstream tracks a few files
# its own .gitignore excludes (scratchpad/*.ps1, test/*.exe); the snapshot only
# ever holds committed files, so forcing adds exactly those and nothing else.
git add -A --force
if git diff --cached --quiet; then
    say "Nothing changed since the last push."
else
    git commit -q -m "Update QMX-Panadapter-NAS and QMX-Panadapter-Shared$(printf '\n%s' "$msg_lines")"
    say "Committed: $(git log -1 --format='%h')"
fi
# Push, retrying: a push over SSH that dies part way (a dropped connection or an
# idle timeout during the upload) usually goes through on the next try, so the
# script retries by itself instead of needing to be run again. SSH keepalives
# stop a slow upload from being cut off as idle. Every attempt is logged.
LOG="$SRC/.qmx-push.log"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o ConnectTimeout=30}"
ok=0
for attempt in 1 2 3 4; do
    say "Pushing to $(git remote get-url origin) ($BRANCH), attempt $attempt ..."
    printf '\n=== %s push attempt %d\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$attempt" >> "$LOG"
    if git push -u origin "$BRANCH" 2>&1 | tee -a "$LOG"; then ok=1; break; fi   # pipefail: git's status
    [ "$attempt" -lt 4 ] && { say "  push failed - trying again in $((attempt * 10)) s"; sleep $((attempt * 10)); }
done
if [ "$ok" != 1 ]; then
    say ""
    say "The push failed 4 times (details in $LOG). Usual causes:"
    say "  - GitHub does not accept this Mac's key: 'ssh -T git@github.com' should greet you by name;"
    say "  - no network to github.com;"
    say "  - a very large upload on a slow link: push it in smaller pieces -"
    say "    see 'Publishing to GitHub' in $(dirname "$0")/README.md - then use this script again."
    die "git push failed"
fi
say "Done: https://github.com/jpwatters/QMX-PanadapterShared"

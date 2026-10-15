# NAS kit - rebuild QMX-Panadapter-NAS on each new upstream release

`make-qmx-panadapter-nas.sh` clones https://github.com/SteffenLav/qmx-panadapter,
checks out its newest release tag and applies the NAS ("network radio")
commits in `patches/`.

**The kit travels with the build.** Every build copies this kit (the two scripts,
this README and the current `patches/`) into `tools/nas-kit` of the new
`~/src/QMX-Panadapter-NAS`, so the next version can be built from
`~/src/QMX-Panadapter-NAS/tools/nas-kit`. Run from there, the script first copies
itself to a temporary folder, because a rebuild moves that folder to the archive.

* `patches/` - the NAS series for upstream **v1.19.0** (26 patches), built,
  flashed and marked tested on the Tab5 as v1.19.0-NAS. Porting the previous
  series to v1.19.0 needed three changes by hand:
  * the relay's settings bit is DIRTY_RELAY **142** (upstream took 140 for
    DIRTY_JS8_SUBMODE and 141 for DIRTY_RXA_AMBW; check_dirty_bits is clean);
  * the Radio source drawer section is id **51** (upstream took 50 for the JS8
    submode), N_DRAWER_SECTIONS 52;
  * CMakeLists.txt keeps both upstream's configure-on-commit block and the -NAS
    version block.
  Then: **0022** names v1.19.0 in the version fallback, **0023** the front-page
  README (version, features, build steps), **0024-0025** the one project PDF,
  M5StackTab5QMX+SharedOverNetwork.pdf, **0026** the Mac scripts' usage examples.
  Checked in the cloud: the series applies to a clean v1.19.0 with git am --3way,
  the changed firmware files compile with ESP-IDF 5.4.4, and check_dirty_bits,
  check_web, check_webui, check_docs and check_unattended_tx are clean.
* This folder is the only copy of the kit. The older patch series and the original
  work tree are archived in `~/src/.qmx-panadapter-archive/`; the script does not
  use them.

| Folder | What it holds |
|---|---|
| `~/src/QMX-Panadapter-NAS` | newest upstream release + the NAS patches - build, flash and test from here |
| `~/src/QMX-Panadapter-Shared` | the last version that was built **and tested** on the hardware |
| `~/src/.qmx-panadapter-archive` | every NAS/Shared folder that was replaced (nothing is deleted) |

```
bash make-qmx-panadapter-nas.sh                # newest release -> QMX-Panadapter-NAS
bash make-qmx-panadapter-nas.sh --status       # what NAS and Shared contain
cd ~/src/QMX-Panadapter-NAS && bash tools/mac-build-flash.sh
#   power the Tab5 off and on after flashing, then test: touch, NAS stream,
#   Radio source switch, web page live spectrum
bash make-qmx-panadapter-nas.sh --mark-tested  # it works: copy NAS -> Shared
```

Other options: `--ref v1.19.0` (a specific tag, branch or commit),
`--force` (rebuild although NAS is already on that release).

* **Shared only changes on `--mark-tested`.** A new upstream release that does
  not work on the hardware never replaces the one that does. (When the script
  is first run with no Shared folder, a release equal to `TESTED_BASE` in the
  script goes straight into Shared, since that is already tested code.)
* **When upstream changed the same code.** The patches are applied with git's
  3-way merge. If a patch still does not apply, the run stops with exit code 2,
  names the patch, and leaves NAS and Shared as they were; the failed attempt
  is kept in the archive. The patch then has to be redone on the new release.
* **When the NAS code changes.** Commit the change on the branch and export the
  series again, e.g. from `~/src/QMX-Panadapter-NAS`:
  `git format-patch --binary -o <kit>/patches <release-tag>..network-radio -- . ':(exclude)tools/nas-kit'`
  (move the old patch files out first). The exclude keeps the kit itself,
  which is committed on the same branch, out of the patches.
* Each tree holds `.qmx-nas-build` (release, upstream commit, patch-series
  checksum, build time) and, once tested, `.qmx-nas-tested`. Both are excluded
  from `git status`.
* Builds report the upstream release plus `-NAS`, e.g. `v1.19.0-NAS`.

Tested 2026-10-15 (cloud, against a copy of upstream): a fresh run on v1.19.0
produced a tree identical to QMX-Panadapter-NAS (same git tree hash); a rebuild
with `--force`, `--mark-tested` and `--status` run from the copy inside
QMX-Panadapter-NAS (and `--status` from inside Shared) behave as above. On the
Mac, a series that did not apply to a new release stopped at the first patch
that failed, with NAS and Shared unchanged and the attempt kept in the archive.

## Publishing to GitHub

`push-to-github.sh` publishes both folders to
https://github.com/jpwatters/QMX-PanadapterShared:

```
bash push-to-github.sh
```

It clones the repository into `~/src/QMX-PanadapterShared` (or updates that
clone), puts a snapshot of the committed files of `QMX-Panadapter-NAS/` and
`QMX-Panadapter-Shared/` side by side (no `.git`, no build output), makes
`QMX-Panadapter-NAS/README.md` the front page with its links pointed into that
folder, commits only if something changed, and pushes. Run it again after each
new tested version.

Sign in first (`gh auth login`, or an SSH key with
`REPO_URL=git@github.com:jpwatters/QMX-PanadapterShared.git`).

**First upload timing out.** The first push is about 30 MB. If it fails with
HTTP 408, "Operation timed out" or "the remote end hung up", push it in pieces
of about 5 MB from the clone, then use the script as normal:

```
cd ~/src/QMX-PanadapterShared
git update-ref -d HEAD        # only if nothing has been pushed yet
git rm -r -q --cached .
n=0; batch=0
git ls-files -o -z | while IFS= read -r -d '' f; do
  git add -f -- "$f"
  batch=$((batch + $(stat -f%z "$f")))
  if [ $batch -gt 5000000 ]; then
    n=$((n+1)); git commit -q -m "Upload part $n" && git push -q -u origin main || { echo "push failed at part $n"; exit 1; }
    echo "pushed part $n"; batch=0
  fi
done
git add -A -f && git commit -q -m "Upload final part" ; git push -u origin main
```


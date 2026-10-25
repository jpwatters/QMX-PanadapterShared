# Rebuild QMX-Panadapter-NAS on each new upstream release

`make-qmx-panadapter-nas.sh` downloads the newest release tag of
https://github.com/SteffenLav/qmx-panadapter (only that release, ~40 MB, not the
whole history; a dropped connection is retried up to three times) and applies
the NAS ("network radio") commits in `patches/`.

**The kit travels with the build.** Every build copies this kit (the two scripts,
this README and the current `patches/`) into `tools/nas-kit` of the new
`~/src/QMX-Panadapter-NAS`, so the next version can be built from
`~/src/QMX-Panadapter-NAS/tools/nas-kit`. Run from there, the script first copies
itself to a temporary folder, because a rebuild moves that folder to the archive.

* `patches/` - the NAS series (35 patches). It applies to upstream **v1.20.5** as it
  is (ported 2026-10-23; not yet built or tested on the Tab5). v1.20.1-NAS was
  marked tested on 2026-10-18 and v1.20.2-NAS built on 2026-10-21 with the
  series before it, which is in git history and in Shared's kit. `SERIES_BASE`
  in the script names the release the patches were made against. Each build
  writes the release into the README's Version line, the CMake version fallback
  and the relay README, so they name the release they were built on. The ports
  that needed hand work:
  * the relay's settings bit is DIRTY_RELAY **145** (upstream took 140-142 and,
    in v1.20.3-v1.20.5, 143 for DIRTY_TXBAND_OFF and 144 for DIRTY_MY_STATE;
    check_dirty_bits is clean, 14 free) - patch 0001;
  * upstream now sends every CAT command through its own `cat_tx()`; the network
    transport is a branch inside it (patch 0001), and upstream's new raw-CAT
    door `cat_send_external_cmd()` checks for USB **or** network. The former
    patch for the KS keyer-speed commands became empty and was dropped, so the
    later patches moved down by one;
  * the SNTP time is handed to a worker task (patch 0005) with its microseconds,
    which upstream now uses, carried forward by the hand-over delay;
  * the 10-burst test button sits next to upstream's new Skip button (patch 0015);
  * the "TX locked" refusal sits after upstream's new band guard (T48) in the
    FT8 pre-flight, Tune and web Tune (patch 0029);
  * the Radio source drawer section is id **52**, N_DRAWER_SECTIONS **53** -
    patch 0005; CMakeLists.txt keeps both upstream's configure-on-commit block
    and the -NAS version block.
  On v1.20.5 the host harnesses (`tools/run_harnesses.py`) give 57 passed, 2
  failed (js8_submode, js8_wav), 1 skipped - the same as pristine upstream
  v1.20.5; check_tx_guard, check_unattended_tx, check_dirty_bits, check_web,
  check_webui and check_docs are clean.
  Later patches: **0021** the version fallback, **0022** the front-page README
  (version, features, build steps), **0023-0024** the one project PDF,
  **0025** the Mac scripts' usage examples, **0026** the project PDF for v1.20.0-NAS,
  **0027** the Mac TCI bridge for WS / WSJT-X / JTDX and the relay's I/Q copy on TCP 7357,
  **0028** one transmitter at a time (the Tab5 is kept off while a TCI program is connected),
  **0029** the Tab5 shows "TX locked: Another Device has the transmitter" and refuses to key,
  **0030** the front-page README's feature list for v1.20.5-NAS, **0031** the project PDF for v1.20.5-NAS,
  **0032** the README section on how the relay is found, the Mac's Python serial port and how TCI connects,
  **0033** the README title "QMX/QMX+ Panadapter Shared over the network",
  **0034** the setup picture on the README (docs/nas/qmx-nas-setup.png),
  **0035** the grey caption under the README's Version line.
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

Other options: `--ref vX.Y.Z` (a specific tag, branch or commit),
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
* Builds report the upstream release plus `-NAS`, e.g. `v1.20.5-NAS`.

Tested 2026-10-15 (cloud, against a copy of upstream): a fresh run on the current release
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


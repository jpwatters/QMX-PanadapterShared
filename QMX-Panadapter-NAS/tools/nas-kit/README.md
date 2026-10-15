# NAS kit - rebuild QMX-Panadapter-NAS on each new upstream release

`make-qmx-panadapter-nas.sh` clones https://github.com/SteffenLav/qmx-panadapter,
checks out its newest release tag and applies the NAS ("network radio")
commits in `patches/`.

**The kit travels with the build.** Every build copies this kit (the two scripts,
this README and the current `patches/`) into `tools/nas-kit` of the new
`~/src/QMX-Panadapter-NAS`, so the next version can be built from
`~/src/QMX-Panadapter-NAS/tools/nas-kit`. Run from there, the script first copies
itself to a temporary folder, because a rebuild moves that folder to the archive.
The older series (`patches-v1.18.0`, `-v1.16.12`, `-v1.16.11`) stay only in the
master copy, `~/src/qmx-panadapter-v1.16/tools/nas-kit`.

* `patches/` - ported to upstream **v1.19.0** on 2026-10-14 (24 patches). The v1.18.0
  series applied with three conflicts, resolved by hand:
  * the relay's settings bit is DIRTY_RELAY **142** (upstream took 140 for
    DIRTY_JS8_SUBMODE and 141 for DIRTY_RXA_AMBW; check_dirty_bits is clean);
  * the Radio source drawer section is id **51** (upstream took 50 for the JS8
    submode), N_DRAWER_SECTIONS 52;
  * CMakeLists.txt keeps both upstream's configure-on-commit block and the -NAS
    version block.
  * **patch 0022** (new) points the version fallback and examples at v1.19.0.
  * **patch 0023**: the front-page README names v1.19.0-NAS, lists the features and the
    build steps. **patch 0024**: the three project PDFs rebuilt for v1.19.0-NAS.
  Checked in the cloud: the series applies to a clean v1.19.0 with git am --3way,
  the changed firmware files compile with ESP-IDF 5.4.4 (same warnings as
  v1.18.0), and check_dirty_bits, check_web, check_webui, check_docs and
  check_unattended_tx are clean. Built, flashed and marked tested on the Mac/Tab5 on 2026-10-14.
* `patches-v1.18.0/` - the v1.18.0 series (21 patches), tested on the hardware on
  2026-10-14, including 10 relay-timed FT8 bursts.
  Ported from v1.16.12 by hand (DIRTY_RELAY 140, Radio source drawer section 50,
  the relay used only with the QMX receive source, upstream's handler limit 80,
  patch 0014 for KS;). Then: 0015 transmit timing test, 0016 web 10-burst test,
  0017 CAT log and PS0 guard, 0018 I/Q pause in transmit, 0019 relay-timed
  bursts, 0020-0021 README and project PDFs.
* `patches-v1.16.12/` - the v1.16.12 series (13 patches), built and tested on
  the hardware on 2026-10-09 (Find NAS, NAS/USB switching, web live spectrum,
  QMX power cycle).
* `patches-v1.16.11/` - the original six commits on v1.16.11, tested on the
  hardware on 2026-10-04. Kept for reference; the script does not use them.

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

Other options: `--ref v1.18.0` (a specific tag, branch or commit),
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
* Builds report the upstream release plus `-NAS`, e.g. `v1.16.11-NAS`.

Tested 2026-10-04: a fresh run on v1.16.11 produced a tree identical to the
hardware-tested commit (same git tree hash); rerun, `--force`, `--mark-tested`
and `--status` behave as above; upstream `main` (newer than v1.16.11) applied
cleanly; a fake v1.16.12 that changed a patched line stopped at patch 6/6 with
NAS and Shared unchanged.

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


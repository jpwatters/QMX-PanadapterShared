#!/bin/bash
# Build this firmware on a Mac and flash it onto a Tab5 over USB.
#
#   bash ~/src/qmx-panadapter-v1.16/tools/mac-build-flash.sh          build + flash
#   bash ~/src/qmx-panadapter-v1.16/tools/mac-build-flash.sh --build  build only
#
# Uses the ESP-IDF in $IDF_PATH or ~/esp/esp-idf, and an installed PowerShell
# (pwsh, or set PWSH=/path/to/pwsh), because the project's standing patches are
# PowerShell scripts (tools/patches/apply_*.ps1); tools/check_patches.py refuses
# the build if any patch is missing. Flashing is a NORMAL flash: settings,
# WiFi, memories and the QSO log are kept. Everything is logged to
# build/mac-build-flash.log.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO/build"
LOG="$REPO/build/mac-build-flash.log"
exec > >(tee "$LOG") 2>&1
step() { echo; echo "=== $*"; }
fail() { echo; echo "FAILED: $*"; echo "(log: $LOG)"; exit 1; }
fwver() { sed -n 's/.*"project_version": *"\([^"]*\)".*/\1/p' "$REPO/build/project_description.json" | head -1; }
BUILD_ONLY=0; [ "$1" = "--build" ] && BUILD_ONLY=1

step "Mac and project"
date; sw_vers 2>/dev/null | tr '\n' ' '; echo; uname -m
cd "$REPO" || fail "no project folder"
echo "project: $REPO"
echo "branch:  $(git rev-parse --abbrev-ref HEAD)   version: $(git describe --tags --dirty)"

step "PowerShell (for the standing patches)"
# Use the PowerShell that's already installed. Look on PATH, in the usual install
# places, and in your login shell's PATH (Terminal's zsh may set it up there).
PWSH="${PWSH:-}"
for c in pwsh pwsh-preview /usr/local/bin/pwsh /opt/homebrew/bin/pwsh /usr/local/bin/pwsh-preview \
         /opt/homebrew/bin/pwsh-preview /usr/local/microsoft/powershell/7/pwsh \
         /usr/local/microsoft/powershell/7-preview/pwsh "$HOME/.dotnet/tools/pwsh" \
         /Applications/PowerShell.app/Contents/MacOS/pwsh; do
  [ -n "$PWSH" ] && break
  command -v "$c" >/dev/null 2>&1 && PWSH="$(command -v "$c")"
done
[ -n "$PWSH" ] || PWSH="$(zsh -lic 'command -v pwsh || command -v pwsh-preview' 2>/dev/null | tail -1)"
[ -n "$PWSH" ] && [ -x "$PWSH" ] || fail "can't find PowerShell (pwsh). In a PowerShell window run  (Get-Process -Id \$PID).Path  and re-run this as:  PWSH=<that path> bash $0"
echo "PowerShell: $PWSH"
"$PWSH" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' || fail "pwsh does not run"

step "ESP-IDF"
export IDF_PATH="${IDF_PATH:-$HOME/esp/esp-idf}"
[ -f "$IDF_PATH/export.sh" ] || fail "ESP-IDF not found at $IDF_PATH"
echo "IDF tree: $(git -C "$IDF_PATH" describe --tags --dirty 2>/dev/null)"
# PlatformIO puts its own python3 first on PATH; ESP-IDF must not pick that one.
PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/.platformio/penv' | paste -sd: -)"
# Use the ESP-IDF Python environment that already exists for this IDF (made by
# install.sh with whichever Python was current then), and that Python itself.
if [ -z "$IDF_PYTHON_ENV_PATH" ]; then
  IDF_PYTHON_ENV_PATH="$(ls -d "$HOME/.espressif/python_env/idf5.4_py"*_env 2>/dev/null | sort -V | tail -1)"
fi
[ -x "$IDF_PYTHON_ENV_PATH/bin/python" ] || fail "no ESP-IDF Python environment in ~/.espressif/python_env - run $IDF_PATH/install.sh esp32p4"
export IDF_PYTHON_ENV_PATH
ENVPY="$(cd "$IDF_PYTHON_ENV_PATH/bin" && pwd -P)/python"
BASEPY="$(readlink -f "$IDF_PYTHON_ENV_PATH/bin/python" 2>/dev/null)"
[ -x "$BASEPY" ] && "$BASEPY" -V >/dev/null 2>&1 || fail "the Python behind $IDF_PYTHON_ENV_PATH is gone ($BASEPY) - run $IDF_PATH/install.sh esp32p4 once to rebuild it"
mkdir -p build/pyshim && ln -sf "$BASEPY" build/pyshim/python3 && PATH="$REPO/build/pyshim:$PATH"
echo "ESP-IDF Python env: $IDF_PYTHON_ENV_PATH"
echo "python3 for export: $(command -v python3) ($(python3 --version 2>&1))"
. "$IDF_PATH/export.sh" > build/idf-export.log 2>&1
RC=$?
if [ $RC -ne 0 ] || ! command -v idf.py >/dev/null 2>&1; then
  echo "--- ESP-IDF export.sh output (exit code $RC):"; cat build/idf-export.log
  fail "ESP-IDF export.sh did not set up idf.py"
fi
tail -3 build/idf-export.log
idf.py --version
case "$(idf.py --version)" in *v5.4*) ;; *) echo "WARNING: the project and its patches are written for ESP-IDF v5.4.4";; esac

step "Fetch components (idf.py reconfigure)"
idf.py reconfigure > build/reconfigure.log 2>&1 || { tail -40 build/reconfigure.log; fail "idf.py reconfigure"; }
tail -3 build/reconfigure.log
ls managed_components

step "Apply the standing patches"
for s in tools/patches/apply_*.ps1; do
  echo "--- $(basename "$s")"
  "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$s" || fail "$(basename "$s")"
done
step "Check the standing patches"
python tools/check_patches.py || fail "check_patches.py"

step "Build"
idf.py build > build/build.log 2>&1 || { grep -E "error|Error|FAILED" build/build.log | head -40; tail -30 build/build.log; fail "idf.py build"; }
tail -8 build/build.log
echo "Firmware version: $(fwver)"
ls -l build/*.bin
[ "$BUILD_ONLY" = 1 ] && { step "Done (build only)"; exit 0; }

step "Flash the Tab5"
PORTS=( $(ls /dev/cu.usbmodem* 2>/dev/null) )
echo "USB serial ports: ${PORTS[*]:-none}"
[ ${#PORTS[@]} -gt 0 ] || fail "no Tab5 found - plug it in with a USB-C DATA cable and run this again"
PORT="${PORTS[0]}"
if [ ${#PORTS[@]} -gt 1 ]; then
  echo "More than one USB serial device is plugged in:"
  select PORT in "${PORTS[@]}"; do [ -n "$PORT" ] && break; done
fi
echo
echo "About to flash the Tab5 on $PORT (normal flash - settings are kept)."
echo "Nothing should be plugged into the Tab5's own USB port: a flash wedges an attached QMX."
read -r -p "Press Enter to flash, or Ctrl+C to cancel... "
idf.py -p "$PORT" -b 460800 flash || fail "flash (try another USB-C cable, or reboot the Tab5 and run again)"

step "SUCCESS"
echo "Flashed $(fwver). The Tab5 is restarting."

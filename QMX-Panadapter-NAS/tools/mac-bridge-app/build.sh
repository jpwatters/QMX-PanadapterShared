#!/bin/bash
# build.sh - build QMX Bridge.app (with its virtual serial port driver) and/or
# QMX Bridge Lite.app (no driver) from this folder.
#
#   ./build.sh                       # both apps, signed to run locally (ad-hoc)
#   ./build.sh --team ABCDE12345     # both apps, signed with your Apple developer team
#   ./build.sh --lite                # only QMX Bridge Lite.app (no driver, no special signing)
#   ./build.sh --xcode /Applications/Xcode-27.app
#   ./build.sh --install             # also copy the app(s) to /Applications
#
# Needs Xcode (with the DriverKit SDK) and XcodeGen; XcodeGen is downloaded from
# its GitHub release into .tools/ if it isn't installed.
# The full log goes to build/build.log and, if ~/Claude exists, ~/Claude/mac-bridge-build.log.

set -u
cd "$(dirname "$0")"
HERE=$(pwd)

TEAM=""
LITE_ONLY=0
INSTALL=0
XCODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM="$2"; shift ;;
        --lite) LITE_ONLY=1 ;;
        --install) INSTALL=1 ;;
        --xcode) XCODE="$2"; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
    shift
done

mkdir -p build
LOG="$HERE/build/build.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "== QMX Bridge build  $(date)"
echo "   macOS $(sw_vers -productVersion) $(uname -m)"
if [ -n "$XCODE" ]; then export DEVELOPER_DIR="$XCODE/Contents/Developer"; fi
echo "   Xcode: $(xcode-select -p 2>/dev/null) ${DEVELOPER_DIR:+(using $DEVELOPER_DIR)}"
xcodebuild -version || { echo "FAIL: xcodebuild not found"; exit 1; }
xcodebuild -showsdks 2>/dev/null | grep -i driverkit || echo "note: no DriverKit SDK listed"

# ---- XcodeGen
XG=$(command -v xcodegen || true)
if [ -z "$XG" ] && [ -x .tools/xcodegen/bin/xcodegen ]; then XG="$HERE/.tools/xcodegen/bin/xcodegen"; fi
if [ -z "$XG" ]; then
    echo "== downloading XcodeGen"
    mkdir -p .tools
    curl -fsSL -o .tools/xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip \
        && (cd .tools && unzip -oq xcodegen.zip) && XG="$HERE/.tools/xcodegen/bin/xcodegen"
    [ -x "$XG" ] || { echo "FAIL: couldn't get XcodeGen (brew install xcodegen)"; exit 1; }
fi
echo "== $("$XG" --version 2>/dev/null)"
"$XG" generate --spec project.yml || { echo "FAIL: xcodegen"; exit 1; }

# ---- signing
if [ -n "$TEAM" ]; then
    SIGN=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
    echo "== signing with team $TEAM"
else
    # Xcode won't sign DriverKit/system-extension entitlements without a provisioning
    # profile, so build unsigned and sign ad-hoc with the entitlements afterwards.
    SIGN=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=)
    echo "== building unsigned, then signing to run locally (ad-hoc)"
fi

OK=1
build() {   # scheme
    echo "== xcodebuild $1"
    xcodebuild -project QMXBridge.xcodeproj -scheme "$1" -configuration Release \
        -derivedDataPath build/dd "${SIGN[@]}" build
    local rc=$?
    if [ $rc -ne 0 ]; then echo "FAIL: $1 (exit $rc)"; OK=0; else echo "ok  : $1"; fi
}

build QMXBridgeLite
[ $LITE_ONLY -eq 1 ] || build QMXBridge

PROD=build/dd/Build/Products/Release
adhoc() {   # bundle entitlements
    codesign --force --sign - --timestamp=none ${2:+--entitlements "$2"} "$1" && echo "signed (ad-hoc): $1"
}
if [ -z "$TEAM" ]; then
    for d in "$PROD/QMX Bridge.app/Contents/Library/SystemExtensions"/*.dext; do
        [ -d "$d" ] && adhoc "$d" QMXSerialDriver/QMXSerialDriver.entitlements
    done
    [ -d "$PROD/QMX Bridge.app" ] && adhoc "$PROD/QMX Bridge.app" QMXBridge/QMXBridge.entitlements
    [ -d "$PROD/QMX Bridge Lite.app" ] && adhoc "$PROD/QMX Bridge Lite.app"
fi
mkdir -p build/out
rm -rf build/out/*.app
for app in "QMX Bridge Lite.app" "QMX Bridge.app"; do
    if [ -d "$PROD/$app" ] && [ -x "$PROD/$app/Contents/MacOS/${app%.app}" ]; then
        rm -rf "build/out/$app"; cp -R "$PROD/$app" build/out/
        echo "built: build/out/$app"
        codesign -dv --entitlements - "build/out/$app" 2>&1 | sed 's/^/      /' | head -30
        if [ -d "build/out/$app/Contents/Library/SystemExtensions" ]; then
            ls "build/out/$app/Contents/Library/SystemExtensions"
            for d in "build/out/$app/Contents/Library/SystemExtensions"/*.dext; do
                codesign -dv --entitlements - "$d" 2>&1 | sed 's/^/      /' | head -30
            done
        fi
        if [ $INSTALL -eq 1 ]; then
            rm -rf "/Applications/$app" && cp -R "build/out/$app" /Applications/ && echo "installed: /Applications/$app"
        fi
    fi
done

echo
echo "== errors:"
grep -E "error:|\*\* BUILD FAILED" "$LOG" | sort -u | head -60 || true
echo "== RESULT: $([ $OK -eq 1 ] && echo BUILD OK || echo BUILD FAILED)"
if [ -d "$HOME/Claude" ]; then cp "$LOG" "$HOME/Claude/mac-bridge-build.log"; fi
[ $OK -eq 1 ]

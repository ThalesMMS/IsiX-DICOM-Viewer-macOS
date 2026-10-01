#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 0 ]]; then
    echo "Uso: $0"
    echo "Compila, embute as bibliotecas, assina ad hoc e audita build/Release/Horos.app,"
    echo "com BUILD-INFO.txt e SHA256SUMS.txt ao lado. Não assina com Developer ID nem notariza."
    [[ $# -eq 1 && "$1" == --help ]] && exit 0
    exit 2
fi

OUTPUT_DIR="$ROOT_DIR/build/Release"
OUTPUT_APP="$OUTPUT_DIR/Horos.app"
BUILD_LOG="$ROOT_DIR/build/logs/build-release.log"
SIGNING_LOG="$ROOT_DIR/build/logs/release-signing.log"
mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/build/logs"
cd "$ROOT_DIR"

# Resolution is deliberate: a build must not rewrite the reviewed package pins.
PACKAGE_LOCK="$ROOT_DIR/Horos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SOURCE_PACKAGES="$ROOT_DIR/build/SourcePackages"
PUBLIC_SOURCE_REF="${HOROS_PUBLIC_SOURCE_REF:-}"
unset HOROS_PUBLIC_SOURCE_REF
lock_digest() {
    if [[ -f "$PACKAGE_LOCK" ]]; then shasum -a 256 "$PACKAGE_LOCK" | cut -d ' ' -f 1; else echo absent; fi
}
APPROVED_LOCK_DIGEST="$(lock_digest)"
echo "Compilando Horos Release. Log: $BUILD_LOG"
if ! xcodebuild -project Horos.xcodeproj -scheme Horos -configuration Release \
    -derivedDataPath build -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile SYMROOT="$ROOT_DIR/build/Build/Products" CODE_SIGNING_ALLOWED=NO > "$BUILD_LOG" 2>&1; then
    awk '/error:|fatal error:|CMake Error|Traceback \(most recent call last\)/ {
        print NR ":" $0
        count++
        if (count == 20) exit
    }' "$BUILD_LOG" >&2
    tail -n 60 "$BUILD_LOG" >&2
    exit 1
fi

if [[ "$(lock_digest)" != "$APPROVED_LOCK_DIGEST" ]]; then
    echo "A resolução alterou o lockfile aprovado; a versão anterior foi mantida." >&2
    exit 1
fi
# Compare the state Xcode actually used with the pin and public tag before signing.
python3 "$ROOT_DIR/script/release-metadata.py" --verify-packages "$ROOT_DIR" "$SOURCE_PACKAGES"

# Finish and verify the new bundle before replacing the previous output.
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Horos.app"
ENTITLEMENTS="$STAGING_DIR/entitlements.plist"
/usr/bin/ditto "$ROOT_DIR/build/Build/Products/Release/Horos.app" "$STAGED_APP"

# Ad hoc signatures carry no Team ID, so under the hardened runtime's library
# validation the app and its helpers could load neither the frameworks and
# libraries embedded beside them nor a third-party plugin. Keep that exception
# for this local signature only: it is not in Horos.entitlements, and a
# Developer ID signature, which this script does not make, would not need it
# for the embedded code. Debugger access and DYLD variables stay off.
python3 - "$ROOT_DIR/Horos/Horos.entitlements" "$ENTITLEMENTS" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
entitlements['com.apple.security.cs.disable-library-validation'] = True
entitlements.pop('com.apple.security.get-task-allow', None)
entitlements.pop('com.apple.security.cs.allow-dyld-environment-variables', None)
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(entitlements, destination)
PYTHON

python3 "$ROOT_DIR/script/release-metadata.py" --stage-package-notices "$ROOT_DIR" "$SOURCE_PACKAGES" "$STAGED_APP"

# Missing notices must fail before any signing or replacement of the artifact.
python3 "$ROOT_DIR/tools/audit-release-bundle.py" "$STAGED_APP" --notices-only \
    --json "$ROOT_DIR/build/logs/release-notices.json"

echo "Assinando e verificando o aplicativo. Log: $SIGNING_LOG"
: > "$SIGNING_LOG"
sign() { /usr/bin/codesign --force --sign - "$@" >> "$SIGNING_LOG" 2>&1; }
# Inside out, each piece with its own entitlements; --deep would sign the
# extensions without theirs (the sandbox an app extension must have), and does
# not see the bare helpers in Resources at all.
# 1. The libraries of the pinned external inputs, embedded loose in Frameworks
#    by Horos/Scripts/Horos/embed-external-inputs.py.
for library in "$STAGED_APP"/Contents/Frameworks/*.dylib; do
    if [[ -f "$library" && ! -L "$library" ]]; then sign "$library"; fi
done
# 2. The frameworks built by this project.
for framework in "$STAGED_APP"/Contents/Frameworks/*.framework; do
    if [[ -d "$framework" ]]; then sign "$framework"; fi
done
# 3. The Quick Look extensions.
for extension in "$STAGED_APP"/Contents/PlugIns/*.appex; do
    [[ -d "$extension" ]] || continue
    sign --options runtime --entitlements "$ROOT_DIR/FinderPreview/FinderPreview.entitlements" "$extension"
done
# 4. The helpers in Resources, including Decompress: separate processes that
#    load the frameworks beside them, so they need the same exception.
/usr/bin/find "$STAGED_APP/Contents/Resources" -type f -perm -u+x -exec /bin/sh -c '
    entitlements=$1; shift
    for file do
        case "$(/usr/bin/file -b "$file")" in
            *Mach-O*) /usr/bin/codesign --force --sign - --options runtime --entitlements "$entitlements" "$file" || exit 1 ;;
        esac
    done
' _ "$ENTITLEMENTS" {} + >> "$SIGNING_LOG" 2>&1
# 5. The application.
sign --options runtime --entitlements "$ENTITLEMENTS" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP" >> "$SIGNING_LOG" 2>&1

# The package must hold everything it loads: every Mach-O arm64 and signed,
# every library from the macOS or from inside the bundle. A failure here leaves
# the previous output where it was.
AUDIT_LOG="$ROOT_DIR/build/logs/release-audit.json"
echo "Auditando o pacote. Relatório: $AUDIT_LOG"
if ! python3 "$ROOT_DIR/tools/audit-release-bundle.py" "$STAGED_APP" --strict --notices --json "$AUDIT_LOG" > /dev/null; then
    echo "O pacote não passou na auditoria; a versão anterior foi mantida." >&2
    exit 1
fi

# Identify the artifact beside it: public source when mapped, toolchain, dependency
# versions, embedded libraries, signature, audit and checksums.
PUBLIC_SOURCE_ARGS=()
if [[ -n "$PUBLIC_SOURCE_REF" ]]; then
    PUBLIC_SOURCE_ARGS=(--public-source-ref "$PUBLIC_SOURCE_REF")
fi
python3 "$ROOT_DIR/script/release-metadata.py" ${PUBLIC_SOURCE_ARGS[@]+"${PUBLIC_SOURCE_ARGS[@]}"} "$ROOT_DIR" \
    "$ROOT_DIR/build/Intermediates.noindex/Horos.build/Release" "$STAGING_DIR" "$AUDIT_LOG" "$SOURCE_PACKAGES"

# Replace the previous output only now, all three files together, keeping the
# previous ones under the same date. A failure puts back what was moved.
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
ITEMS=(Horos.app BUILD-INFO.txt SHA256SUMS.txt)
previous_name() {
    case "$1" in
        Horos.app) echo "Horos.previous-$STAMP.app" ;;
        *.txt) echo "${1%.txt}.previous-$STAMP.txt" ;;
    esac
}
MOVED=()
restore() {
    local item
    for item in "${ITEMS[@]}"; do
        [[ -e "$OUTPUT_DIR/$item" && ! -e "$STAGING_DIR/$item" ]] && mv "$OUTPUT_DIR/$item" "$STAGING_DIR/$item"
    done
    for item in ${MOVED[@]+"${MOVED[@]}"}; do
        mv "$OUTPUT_DIR/$(previous_name "$item")" "$OUTPUT_DIR/$item"
    done
}
for item in "${ITEMS[@]}"; do
    if [[ -e "$OUTPUT_DIR/$item" || -L "$OUTPUT_DIR/$item" ]]; then
        mv "$OUTPUT_DIR/$item" "$OUTPUT_DIR/$(previous_name "$item")" || { restore; exit 1; }
        MOVED+=("$item")
    fi
done
for item in "${ITEMS[@]}"; do
    mv "$STAGING_DIR/$item" "$OUTPUT_DIR/$item" || { restore; exit 1; }
done
if [[ ${#MOVED[@]} -gt 0 ]]; then
    echo "Versão anterior preservada em: $OUTPUT_DIR/$(previous_name Horos.app)"
fi
echo "Release pronto para copiar para Applications:"
echo "$OUTPUT_APP"
echo "Identificação: $OUTPUT_DIR/BUILD-INFO.txt; somas: (cd \"$OUTPUT_DIR\" && shasum -a 256 -c SHA256SUMS.txt)"

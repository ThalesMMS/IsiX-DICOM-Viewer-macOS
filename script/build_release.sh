#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 0 ]]; then
    echo "Uso: $0"
    echo "Compila, embute as bibliotecas, assina ad hoc e audita build/Release/ARQ/IsiX DICOM Viewer.app,"
    echo "com BUILD-INFO.txt e SHA256SUMS.txt ao lado. Não assina com Developer ID nem notariza."
    echo "HOROS_RELEASE_ARCH escolhe a fatia do pacote: arm64 (padrão, Apple Silicon) ou x86_64 (Macs"
    echo "Intel com macOS 26). Cada pacote leva só a sua; o x86_64 tem dependências e build próprios em build/x86_64."
    echo "O build recebe o número AAAAMMDDNN: data local e HOROS_RELEASE_SEQUENCE (0 a 99, padrão 0);"
    echo "HOROS_RELEASE_BUILD substitui o número inteiro."
    [[ $# -eq 1 && "$1" == --help ]] && exit 0
    exit 2
fi

CHANNEL="${ISIS_BUILD_CHANNEL:-github}"
# One slice per package: arm64 for Apple Silicon by default, x86_64 for the
# Intel Macs that run macOS 26. There is no universal package.
ARCH="${HOROS_RELEASE_ARCH:-arm64}"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "HOROS_RELEASE_ARCH deve ser arm64 ou x86_64." >&2; exit 2 ;;
esac
case "$CHANNEL" in
    github) OUTPUT_DIR="$ROOT_DIR/build/Release/$ARCH"; CHANNEL_CONFIG="GitHub"; HELPER_SOURCE="Decompress/Decompress.entitlements" ;;
    appstore) OUTPUT_DIR="$ROOT_DIR/build/AppStore"; CHANNEL_CONFIG="AppStore"; HELPER_SOURCE="Horos/Configuration/AppStoreHelper.entitlements" ;;
    *) echo "ISIS_BUILD_CHANNEL deve ser github ou appstore." >&2; exit 2 ;;
esac
if [[ "$CHANNEL" == appstore && "$ARCH" != arm64 ]]; then
    echo "O build local do canal App Store usa arm64; para Universal 2, use script/build_appstore.sh --export." >&2
    exit 2
fi
XCCONFIG="$ROOT_DIR/Horos/Configuration/$CHANNEL_CONFIG.xcconfig"
# The arm64 build keeps the derived data it always had. Another slice gets its
# own, dependencies included, so alternating the two builds neither rebuilds
# everything nor mixes slices in one cache.
# With SYMROOT given, Xcode puts the intermediates and the shared precompiled
# headers in build/Intermediates.noindex of the checkout whatever the derived
# data path, so the other slice names its own.
DERIVED_DIR="$ROOT_DIR/build"
ARCH_SETTINGS=()
if [[ "$ARCH" != arm64 ]]; then
    DERIVED_DIR="$ROOT_DIR/build/$ARCH"
    ARCH_SETTINGS=("OBJROOT=$DERIVED_DIR/Intermediates.noindex"
                   "SHARED_PRECOMPS_DIR=$DERIVED_DIR/Intermediates.noindex/PrecompiledHeaders")
fi
PRODUCTS_DIR="$DERIVED_DIR/Build/Products"
INTERMEDIATES_DIR="$DERIVED_DIR/Intermediates.noindex"
if [[ "$CHANNEL" == appstore ]]; then PRODUCTS_DIR="$ROOT_DIR/build/Channels/AppStore/Products"; fi
OUTPUT_APP="$OUTPUT_DIR/IsiX DICOM Viewer.app"
BUILD_LOG="$ROOT_DIR/build/logs/build-$CHANNEL.log"
SIGNING_LOG="$ROOT_DIR/build/logs/$CHANNEL-signing.log"
if [[ "$CHANNEL" == github ]]; then
    BUILD_LOG="$ROOT_DIR/build/logs/build-release-$ARCH.log"
    SIGNING_LOG="$ROOT_DIR/build/logs/release-signing-$ARCH.log"
fi
mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/build/logs"
cd "$ROOT_DIR"
# Both channels use the same dependency cache and Xcode build database.
BUILD_LOCK="$ROOT_DIR/build/.distribution-build-lock"
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    echo "Outro build de distribuição está em execução. Lock: $BUILD_LOCK" >&2
    exit 1
fi
printf '%s\n' "$$" > "$BUILD_LOCK/pid"
STAGING_DIR=""
cleanup() {
    [[ -z "$STAGING_DIR" ]] || rm -rf "$STAGING_DIR"
    # The Unzip Binaries phase staged the validator of this slice in Binaries/.
    # Put back the default one, which the development build and the tests run.
    if [[ "$ARCH" != arm64 ]] && ! python3 "$ROOT_DIR/Horos/Scripts/Horos/stage-dciodvfy.py" --arch arm64 > /dev/null; then
        echo "Aviso: Binaries/dciodvfy não voltou ao arm64; o próximo build arm64 o prepara." >&2
    fi
    rm -rf "$BUILD_LOCK"
}
trap cleanup EXIT

# Resolution is deliberate: a build must not rewrite the reviewed package pins.
PACKAGE_LOCK="$ROOT_DIR/Horos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SOURCE_PACKAGES="$ROOT_DIR/build/SourcePackages"
PUBLIC_SOURCE_REF="${HOROS_PUBLIC_SOURCE_REF:-}"
unset HOROS_PUBLIC_SOURCE_REF
lock_digest() {
    if [[ -f "$PACKAGE_LOCK" ]]; then shasum -a 256 "$PACKAGE_LOCK" | cut -d ' ' -f 1; else echo absent; fi
}
APPROVED_LOCK_DIGEST="$(lock_digest)"
# A copied checkout can retain a submodule gitfile whose local repository was
# not copied. Preserve that worktree before Git initializes the pinned source.
SUBMODULE_LOG="$ROOT_DIR/build/logs/release-submodules.log"
echo "Preparando submódulos. Log: $SUBMODULE_LOG"
if ! python3 - "$ROOT_DIR" > "$SUBMODULE_LOG" 2>&1 <<'PYTHON'
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
entries = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root)
paths = []
for entry in entries.split(b'\0'):
    if not entry:
        continue
    metadata, name = entry.split(b'\t', 1)
    if metadata.split()[0] == b'160000':
        paths.append(name.decode('utf-8'))
backup = None
for name in paths:
    worktree = root / name
    gitfile = worktree / '.git'
    if worktree.is_symlink() or gitfile.is_symlink() or not gitfile.is_file():
        continue
    pointer = gitfile.read_text().strip()
    if not pointer.startswith('gitdir: '):
        continue
    gitdir = worktree / pointer.removeprefix('gitdir: ')
    if gitdir.exists():
        continue
    if backup is None:
        recovery = root / 'build/recovery'
        recovery.mkdir(parents=True, exist_ok=True)
        backup = Path(tempfile.mkdtemp(prefix='submodules-', dir=recovery))
    destination = backup / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(worktree), str(destination))
    print(f'Submódulo {name}: metadados locais ausentes; conteúdo preservado em {destination}', flush=True)
if paths:
    subprocess.run(['git', 'submodule', 'sync', '--', *paths], cwd=root, check=True)
    subprocess.run(['git', 'submodule', 'update', '--init', '--', *paths], cwd=root, check=True)
PYTHON
then
    cat "$SUBMODULE_LOG" >&2
    echo "Falha ao preparar os submódulos; o Xcode não foi iniciado." >&2
    exit 1
fi
cat "$SUBMODULE_LOG"
# The update check compares build numbers, so each release needs its own,
# larger than every earlier one: the local date and a two-digit sequence for a
# further release of the same day.
RELEASE_SEQUENCE="${HOROS_RELEASE_SEQUENCE:-0}"
if ! [[ "$RELEASE_SEQUENCE" =~ ^[0-9]{1,2}$ ]]; then
    echo "HOROS_RELEASE_SEQUENCE deve ser um número de 0 a 99." >&2
    exit 2
fi
RELEASE_BUILD="${HOROS_RELEASE_BUILD:-$(date +%Y%m%d)$(printf '%02d' "$((10#$RELEASE_SEQUENCE))")}"
CHANNEL_SETTINGS=()
if [[ "$CHANNEL" == appstore ]]; then
    RELEASE_BUILD="${ISIS_APPSTORE_BUILD:-$(date +%y%m).$((10#$(date +%d))).$((10#$RELEASE_SEQUENCE))}"
    if ! [[ "$RELEASE_BUILD" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]]; then
        echo "ISIS_APPSTORE_BUILD deve ter até três componentes: 1–9999[.0–99[.0–99]]." >&2
        exit 2
    fi
    CHANNEL_SETTINGS=("PRODUCT_BUNDLE_IDENTIFIER_PREFIX=${ISIS_APPSTORE_BUNDLE_ID:-thalesmms.isis.Isis-DICOM-Viewer}"
                      "MARKETING_VERSION=${ISIS_APPSTORE_VERSION:-1.0}")
elif ! [[ "$RELEASE_BUILD" =~ ^[1-9][0-9]{9}$ ]]; then
    echo "HOROS_RELEASE_BUILD deve ter dez dígitos, AAAAMMDDNN." >&2
    exit 2
fi
# The verified source archives of the dependencies do not depend on the slice.
if [[ "$ARCH" != arm64 ]]; then
    export EXTERNAL_SOURCES_DOWNLOADS="$ROOT_DIR/build/Intermediates.noindex/Horos.build/ExternalSources.downloads"
fi
echo "Compilando IsiX DICOM Viewer Release $ARCH, build $RELEASE_BUILD. Log: $BUILD_LOG"
if ! xcodebuild -project Horos.xcodeproj -scheme Horos -configuration Release -xcconfig "$XCCONFIG" \
    -derivedDataPath "$DERIVED_DIR" -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile SYMROOT="$PRODUCTS_DIR" \
    COMPILATION_CACHE_CAS_PATH="$ROOT_DIR/build/CompilationCache.noindex" CODE_SIGNING_ALLOWED=NO ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    HOROS_RELEASE_BUILD="$RELEASE_BUILD" ${ARCH_SETTINGS[@]+"${ARCH_SETTINGS[@]}"} \
    ${CHANNEL_SETTINGS[@]+"${CHANNEL_SETTINGS[@]}"} > "$BUILD_LOG" 2>&1; then
    awk '/error:|fatal:|fatal error:|CMake Error|Traceback \(most recent call last\)/ {
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
STAGED_APP="$STAGING_DIR/IsiX DICOM Viewer.app"
ENTITLEMENTS="$STAGING_DIR/entitlements.plist"
/usr/bin/ditto "$PRODUCTS_DIR/Release/IsiX DICOM Viewer.app" "$STAGED_APP"

# Under the hardened runtime, library validation refuses code signed by another
# team. Third-party plugins are signed by their own developers and load into the
# app's process, so the GitHub channel's Horos.entitlements carries
# disable-library-validation, and the Developer ID signature made outside this
# script keeps it. An ad hoc signature carries no Team ID, so it additionally
# needs the exception for the frameworks and libraries embedded beside the app
# and its helpers; it is set here on every channel for this local signature.
# The App Store channel loads no third-party plugins and its entitlements do not
# carry it. Debugger access and DYLD variables stay off.
APP_ENTITLEMENTS="$ROOT_DIR/Horos/Horos.entitlements"
if [[ "$CHANNEL" == appstore ]]; then APP_ENTITLEMENTS="$ROOT_DIR/Horos/Configuration/AppStore.entitlements"; fi
HELPER_ENTITLEMENTS="$STAGING_DIR/helper-entitlements.plist"
python3 - "$APP_ENTITLEMENTS" "$ENTITLEMENTS" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
entitlements['com.apple.security.cs.disable-library-validation'] = True
entitlements.pop('com.apple.security.get-task-allow', None)
entitlements.pop('com.apple.security.cs.allow-dyld-environment-variables', None)
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(entitlements, destination)
PYTHON

python3 - "$ROOT_DIR/$HELPER_SOURCE" "$HELPER_ENTITLEMENTS" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
entitlements['com.apple.security.cs.disable-library-validation'] = True
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(entitlements, destination)
PYTHON

python3 "$ROOT_DIR/script/release-metadata.py" --stage-package-notices "$ROOT_DIR" "$SOURCE_PACKAGES" "$STAGED_APP"

# Missing notices must fail before any signing or replacement of the artifact.
NOTICES_LOG="$ROOT_DIR/build/logs/$CHANNEL-notices.json"
if [[ "$CHANNEL" == github ]]; then NOTICES_LOG="$ROOT_DIR/build/logs/release-notices-$ARCH.json"; fi
python3 "$ROOT_DIR/tools/audit-release-bundle.py" "$STAGED_APP" --notices-only --json "$NOTICES_LOG"

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
' _ "$HELPER_ENTITLEMENTS" {} + >> "$SIGNING_LOG" 2>&1
# 5. The application.
sign --options runtime --entitlements "$ENTITLEMENTS" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP" >> "$SIGNING_LOG" 2>&1

# The package must hold everything it loads: every Mach-O of its single slice
# and signed, every library from the macOS or from inside the bundle. A failure
# here leaves the previous output where it was.
AUDIT_LOG="$ROOT_DIR/build/logs/$CHANNEL-audit.json"
if [[ "$CHANNEL" == github ]]; then AUDIT_LOG="$ROOT_DIR/build/logs/release-audit-$ARCH.json"; fi
echo "Auditando o pacote $ARCH. Relatório: $AUDIT_LOG"
if ! python3 "$ROOT_DIR/tools/audit-release-bundle.py" "$STAGED_APP" --strict --notices --channel "$CHANNEL" \
    --expect-arch "$ARCH" --json "$AUDIT_LOG" > /dev/null; then
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
    "$INTERMEDIATES_DIR/Horos.build/Release" "$STAGING_DIR" "$AUDIT_LOG" "$SOURCE_PACKAGES"

# Replace the previous output only now, all three files together, keeping the
# previous ones under the same date. A failure puts back what was moved.
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
APP_NAME="IsiX DICOM Viewer"
ITEMS=("$APP_NAME.app" BUILD-INFO.txt SHA256SUMS.txt)
previous_name() {
    case "$1" in
        "$APP_NAME.app") echo "$APP_NAME.previous-$STAMP.app" ;;
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
    echo "Versão anterior preservada em: $OUTPUT_DIR/$(previous_name "$APP_NAME.app")"
fi
echo "Build local $CHANNEL $ARCH pronto, assinado ad hoc:"
echo "$OUTPUT_APP"
echo "Identificação: $OUTPUT_DIR/BUILD-INFO.txt; somas: (cd \"$OUTPUT_DIR\" && shasum -a 256 -c SHA256SUMS.txt)"

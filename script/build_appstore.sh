#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---local}"
if [[ $# -gt 1 || "$MODE" != --local && "$MODE" != --export ]]; then
    echo "Uso: $0 [--local|--export]"
    echo "Padrão --local: build sandboxed ad hoc em build/AppStore/IsiX DICOM Viewer.app."
    echo "--export: cria um archive Universal 2 assinado e exporta o pacote para App Store Connect."
    echo "Requer ISIS_APPSTORE_TEAM, certificados e perfis de provisionamento disponíveis."
    echo "A exportação não envia o aplicativo nem o submete à revisão."
    [[ $# -eq 1 && "$1" == --help ]] && exit 0
    exit 2
fi
if [[ "$MODE" == --export && -z "${ISIS_APPSTORE_TEAM:-}" ]]; then
    echo "Defina ISIS_APPSTORE_TEAM com seu Team ID para exportar para a App Store." >&2
    exit 2
fi
export ISIS_BUILD_CHANNEL=appstore
if [[ "$MODE" == --local ]]; then
    exec "$ROOT_DIR/script/build_release.sh"
fi
# TIFF's bottle dependency graph differs by architecture; Universal 2 needs both slices of these libraries.
export ISIS_EMBED_EXTRA_LIBRARIES="libwebp.7.dylib libsharpyuv.0.dylib"
RELEASE_SEQUENCE="${HOROS_RELEASE_SEQUENCE:-0}"
if ! [[ "$RELEASE_SEQUENCE" =~ ^[0-9]{1,2}$ ]]; then
    echo "HOROS_RELEASE_SEQUENCE deve ser um número de 0 a 99." >&2
    exit 2
fi
RELEASE_BUILD="${ISIS_APPSTORE_BUILD:-$(date +%y%m).$((10#$(date +%d))).$((10#$RELEASE_SEQUENCE))}"
if ! [[ "$RELEASE_BUILD" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]]; then
    echo "ISIS_APPSTORE_BUILD deve ter até três componentes: 1–9999[.0–99[.0–99]]." >&2
    exit 2
fi

cd "$ROOT_DIR"
OUTPUT="$ROOT_DIR/build/AppStore"
mkdir -p "$OUTPUT" "$ROOT_DIR/build/logs"
ARCHIVE="$OUTPUT/IsiX DICOM Viewer.xcarchive"
EXPORT="$OUTPUT/Export"
BUILD_LOCK="$ROOT_DIR/build/.distribution-build-lock"
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    echo "Outro build de distribuição está em execução. Lock: $BUILD_LOCK" >&2
    exit 1
fi
printf '%s\n' "$$" > "$BUILD_LOCK/pid"
VALIDATION=""
cleanup() {
    python3 "$ROOT_DIR/Horos/Scripts/Horos/stage-dciodvfy.py" --arch arm64 > /dev/null || \
        echo "Aviso: o próximo build arm64 deve preparar dciodvfy novamente." >&2
    [[ -z "$VALIDATION" ]] || rm -rf "$VALIDATION"
    rm -rf "$BUILD_LOCK"
}
trap cleanup EXIT
# Preserve earlier distribution artifacts, including a partially failed export.
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
for item in "$ARCHIVE" "$EXPORT" "$OUTPUT/arm64.xcarchive" "$OUTPUT/x86_64.xcarchive"; do
    [[ ! -e "$item" ]] || mv "$item" "$item.previous-$STAMP"
done
OPTIONS="$OUTPUT/ExportOptions.plist"
python3 - "$OPTIONS" "$ISIS_APPSTORE_TEAM" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], 'wb') as target:
    plistlib.dump({'method': 'app-store-connect', 'destination': 'export',
                  'teamID': sys.argv[2], 'signingStyle': 'automatic',
                  'manageAppVersionAndBuildNumber': False}, target)
PYTHON
LOG="$ROOT_DIR/build/logs/appstore-export.log"
PROVISIONING_ARGS=()
if [[ "${ISIS_APPSTORE_ALLOW_PROVISIONING_UPDATES:-0}" == 1 ]]; then
    PROVISIONING_ARGS=(-allowProvisioningUpdates)
fi
for ARCH in arm64 x86_64; do
    DERIVED_DIR="$ROOT_DIR/build"
    INTERMEDIATES_DIR="$DERIVED_DIR/Build/Intermediates.noindex"
    if [[ "$ARCH" == x86_64 ]]; then
        DERIVED_DIR="$ROOT_DIR/build/x86_64"
        INTERMEDIATES_DIR="$DERIVED_DIR/Intermediates.noindex"
    fi
    ARCH_SETTINGS=("OBJROOT=$INTERMEDIATES_DIR"
                   "SHARED_PRECOMPS_DIR=$INTERMEDIATES_DIR/PrecompiledHeaders")
    echo "Archiving App Store $ARCH, build $RELEASE_BUILD."
    if ! xcodebuild archive -project Horos.xcodeproj -scheme Horos -configuration Release \
    -xcconfig Horos/Configuration/AppStore.xcconfig -archivePath "$OUTPUT/$ARCH.xcarchive" \
    -derivedDataPath "$DERIVED_DIR" -clonedSourcePackagesDirPath build/SourcePackages \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    COMPILATION_CACHE_CAS_PATH="$ROOT_DIR/build/CompilationCache.noindex" \
    HOROS_DEVELOPMENT_TEAM="$ISIS_APPSTORE_TEAM" DEVELOPMENT_TEAM="$ISIS_APPSTORE_TEAM" CODE_SIGNING_ALLOWED=YES \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="Apple Development" \
    PRODUCT_BUNDLE_IDENTIFIER_PREFIX="${ISIS_APPSTORE_BUNDLE_ID:-thalesmms.isis.Isis-DICOM-Viewer}" \
    MARKETING_VERSION="${ISIS_APPSTORE_VERSION:-1.0}" \
    HOROS_RELEASE_BUILD="$RELEASE_BUILD" \
    ${ARCH_SETTINGS[@]+"${ARCH_SETTINGS[@]}"} \
    ${PROVISIONING_ARGS[@]+"${PROVISIONING_ARGS[@]}"} \
    > "$ROOT_DIR/build/logs/appstore-archive-$ARCH.log" 2>&1; then
    LOG="$ROOT_DIR/build/logs/appstore-archive-$ARCH.log"
    tail -n 60 "$LOG" >&2
    echo "Falha no archive assinado. Log: $LOG" >&2
    exit 1
fi
    python3 - "$OUTPUT/$ARCH.xcarchive" "${ISIS_APPSTORE_VERSION:-1.0}" "$RELEASE_BUILD" <<'PYTHON'
from pathlib import Path
import plistlib, sys
archive = Path(sys.argv[1])
props = plistlib.loads((archive / 'Info.plist').read_bytes())['ApplicationProperties']
app = archive / 'Products' / props['ApplicationPath']
expected = {'CFBundleShortVersionString': sys.argv[2], 'CFBundleVersion': sys.argv[3]}
for path in [app / 'Contents/Info.plist', *app.glob('Contents/PlugIns/*.appex/Contents/Info.plist')]:
    info = plistlib.loads(path.read_bytes())
    for key, value in expected.items():
        if info.get(key) != value:
            raise SystemExit(f'{path}: expected {key}={value}, found {info.get(key)}')
PYTHON
done
python3 "$ROOT_DIR/tools/merge-appstore-archives.py" "$OUTPUT/arm64.xcarchive" "$OUTPUT/x86_64.xcarchive" "$ARCHIVE"
APP="$ARCHIVE/Products/Applications/IsiX DICOM Viewer.app"
python3 script/release-metadata.py --verify-packages "$ROOT_DIR" "$ROOT_DIR/build/SourcePackages"
python3 script/release-metadata.py --stage-package-notices "$ROOT_DIR" "$ROOT_DIR/build/SourcePackages" "$APP"
# Resource-only SwiftPM bundles are data. Their development signatures are not
# replaced by Xcode's distribution export; seal their files with the outer app.
python3 - "$APP" <<'PYTHON'
from pathlib import Path
import plistlib, subprocess, sys
for bundle in (Path(sys.argv[1]) / 'Contents/Resources').rglob('*.bundle'):
    info = bundle / 'Contents/Info.plist'
    if not info.is_file() or plistlib.loads(info.read_bytes()).get('CFBundleExecutable'):
        continue
    if any(subprocess.check_output(['file', '-b', str(p)]).startswith(b'Mach-O')
           for p in bundle.rglob('*') if p.is_file()):
        raise SystemExit(f'Resource-only bundle contains executable code: {bundle}')
    if (bundle / 'Contents/_CodeSignature').is_dir():
        subprocess.run(['codesign', '--remove-signature', str(bundle)], check=True)
PYTHON
# Adding package notices changes the seal; Xcode will re-sign it during export.
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "$EXPORT" ${PROVISIONING_ARGS[@]+"${PROVISIONING_ARGS[@]}"} >> "$LOG" 2>&1; then
    tail -n 60 "$LOG" >&2
    echo "Falha na exportação. Confira certificados e perfis de distribuição. Log: $LOG" >&2
    exit 1
fi
# Inspect the app actually inside the signed installer, after Xcode re-signing.
VALIDATION="$(mktemp -d "$OUTPUT/.export-validation.XXXXXX")"
FOUND_PACKAGE=NO
for package in "$EXPORT"/*.pkg; do
    [[ -f "$package" ]] || continue
    FOUND_PACKAGE=YES
    pkgutil --check-signature "$package" >> "$LOG" 2>&1
    pkgutil --expand-full "$package" "$VALIDATION/Expanded" >> "$LOG" 2>&1
    python3 - "$VALIDATION/Expanded" "$ROOT_DIR" <<'PYTHON'
from pathlib import Path
import subprocess, sys
apps = list(Path(sys.argv[1]).rglob('IsiX DICOM Viewer.app'))
if len(apps) != 1:
    raise SystemExit('O pacote exportado deve conter exatamente um aplicativo.')
for arch in ('arm64', 'x86_64'):
    subprocess.run([sys.executable, str(Path(sys.argv[2]) / 'tools/audit-release-bundle.py'),
                    str(apps[0]), '--strict', '--notices', '--channel', 'appstore',
                    '--store-distribution', '--expect-arch', arch], check=True)
PYTHON
    rm -rf "$VALIDATION/Expanded"
done
if [[ "$FOUND_PACKAGE" != YES ]]; then
    echo "A exportação não gerou um instalador .pkg. Confira $EXPORT e $LOG." >&2
    exit 1
fi
echo "Pacote exportado e validado: $EXPORT"

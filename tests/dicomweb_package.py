"""Link existing DICOMweb drivers to the app-approved remote product artifacts.

Copy immutable products from an already built Xcode app or qualified public
consumer, with its effective SourcePackages state. This never builds a second
client implementation or modifies another build's outputs.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build/DICOMwebPackageTests'
LOCK = ROOT / 'Horos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'


def metadata():
    spec = importlib.util.spec_from_file_location('horos_release_metadata', ROOT / 'script/release-metadata.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(products, packages):
    approval = json.loads(LOCK.read_text())
    module = metadata()
    records = module.verified_swift_packages(ROOT, packages)
    resolved = json.loads((packages / 'workspace-state.json').read_text())['object']['dependencies']
    # The internal modules (Modules/) resolve from this tree, without a pin;
    # verified_swift_packages has already refused any other local package.
    effective = {entry['packageRef']['identity']: entry['state']['checkoutState'] for entry in resolved
                 if entry['packageRef'].get('kind') != 'fileSystem'}
    if effective != {pin['identity']: pin['state'] for pin in approval['pins']}:
        raise RuntimeError('product source resolution differs from the app lockfile')
    destination = OUTPUT / 'Products/Debug'
    if destination.exists(): shutil.rmtree(destination)
    destination.mkdir(parents=True)
    names = ['DicomWebClient.o', 'DicomData.o', 'DicomWebOIDC.o',
             'DicomWebClient.swiftmodule', 'DicomData.swiftmodule', 'DicomWebOIDC.swiftmodule']
    names += [bundle.name for bundle in products.glob('*.bundle')]
    for name in names:
        source, target = products / name, destination / name
        if source.is_symlink(): raise RuntimeError('product input must be an independent regular artifact')
        if source.is_dir(): shutil.copytree(source, target)
        elif source.is_file(): shutil.copy2(source, target)
        else: raise RuntimeError('resolved product artifact is missing: ' + name)
    hashes = {str(path.relative_to(destination)): module.sha256(path)
              for path in destination.rglob('*') if path.is_file()}
    (OUTPUT / 'receipt.json').write_text(json.dumps({'lockSHA256': module.sha256(LOCK), 'files': hashes,
        'clientRevision': next(record['revision'] for record in records if record['identity'] == 'dicom-swift')}, indent=2) + '\n')
    print('Copied verified remote DicomWebClient/DicomData/DicomWebOIDC products; %d immutable file hashes recorded' % len(hashes))


# What script/build_and_run.sh leaves: the Debug products and the packages
# they were resolved from.
BUILT_PRODUCTS = ROOT / 'build/Build/Products/Debug'
BUILT_PACKAGES = ROOT / 'build/SourcePackages'


def swift_flags(executable_directory):
    products = OUTPUT / 'Products/Debug'
    receipt = OUTPUT / 'receipt.json'
    current = hashlib.sha256(LOCK.read_bytes()).hexdigest()
    stale = not receipt.is_file() or json.loads(receipt.read_text())['lockSHA256'] != current
    if stale:
        # A lock that moved (a package pinned to a new release) left the cache
        # behind and failed every DICOMweb test until it was prepared again by
        # hand. The Debug build resolved from the current lock is prepared
        # again here; prepare() still refuses products resolved differently.
        if (BUILT_PRODUCTS / 'DicomWebClient.o').is_file() and (BUILT_PACKAGES / 'workspace-state.json').is_file():
            try:
                prepare(BUILT_PRODUCTS, BUILT_PACKAGES)
            except RuntimeError as error:
                print('skipped: the Debug build does not match the package lock (%s); build Debug again '
                      '(script/build_and_run.sh --verify)' % error, file=sys.stderr)
                raise SystemExit(2)
        else:
            print('skipped: build Debug first (script/build_and_run.sh --verify), or run python3 '
                  'tests/dicomweb_package.py --prepare --products DEBUG_PRODUCTS --source-packages SOURCE_PACKAGES',
                  file=sys.stderr)
            raise SystemExit(2)
    expected = json.loads(receipt.read_text())
    if current != expected['lockSHA256']:
        raise RuntimeError('test product cache does not match the app-approved package lock')
    for relative, digest in expected['files'].items():
        if hashlib.sha256((products / relative).read_bytes()).hexdigest() != digest:
            raise RuntimeError('test product cache changed after preparation')
    for bundle in products.glob('*.bundle'):
        shutil.copytree(bundle, Path(executable_directory) / bundle.name, dirs_exist_ok=True)
    # The retrieve modes the node sources take from the app's IsiXDICOMNetwork
    # module, built from source ahead of the products' copy of its interface.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import isix_modules
    network = isix_modules.module_flags('IsiXDICOMNetwork', Path(executable_directory) / 'isix-modules',
                                        ['-target', 'arm64-apple-macos26.0'])
    return ['-target', 'arm64-apple-macos26.0', *network,
            '-I', str(products), str(products / 'DicomWebClient.o'), str(products / 'DicomData.o'),
            str(products / 'DicomWebOIDC.o'), '-lz']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true', required=True)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--source-packages', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.products, args.source_packages)

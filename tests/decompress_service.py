"""The Decompress XPC service, for the tests that ran the Decompress helper.

The helper was an executable in Contents/Resources that took its work on the
command line; the service lives in Contents/XPCServices/Decompress.xpc and
answers only the application it is embedded in. `client()` builds
tests/decompress_client.swift - which takes the helper's command line and
answers as it did, through the code the application calls - into a small
application bundle with a copy of a built service in its XPCServices, and
returns the client's executable: what the tests run where they ran the helper.

    helper = decompress_service.helper(sys.argv[1:])   # None when nothing is built

`--helper PATH` names another service (a Decompress.xpc), or an executable to
run as it is (a client built before, or a helper of an older build). The
client is compiled once per source and kept in build/decompress-client; the
bundle around it is made again for each service.
"""
from pathlib import Path
import hashlib
import plistlib
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CLIENT_SOURCE = ROOT / 'tests/decompress_client.swift'
CACHE = ROOT / 'build/decompress-client'
BUNDLE_ID = 'isix.tests.decompress-client'


def built_service(root=ROOT):
    """The Decompress.xpc of the Debug build or of the development bundle."""
    for app in (root / 'build/Build/Products/Debug/IsiX DICOM Viewer.app',
                root / 'build/Development/HorosDevelopment.app'):
        service = app / 'Contents/XPCServices/Decompress.xpc'
        if (service / 'Contents/Info.plist').is_file():
            return service
    return None


def _source_key():
    digest = hashlib.sha256(CLIENT_SOURCE.read_bytes())
    for name in ('IsiXDatabase', 'IsiXPreferences'):
        for path in isix_modules.module_sources(name):
            digest.update(path.read_bytes())
    return digest.hexdigest()[:16]


def _compiled_client(arch='arm64'):
    folder = CACHE / (_source_key() + ('' if arch == 'arm64' else '-' + arch))
    executable = folder / 'client'
    if not executable.is_file():
        folder.mkdir(parents=True, exist_ok=True)
        target = ['-target', f'{arch}-apple-macos15.0']
        flags = isix_modules.module_flags('IsiXDatabase', folder / 'modules', target)
        flags += isix_modules.module_flags('IsiXPreferences', folder / 'modules', target)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *target, *flags, str(CLIENT_SOURCE),
                        '-o', str(executable)], check=True, capture_output=True, text=True, timeout=600)
    return executable


SANDBOX = {'com.apple.security.app-sandbox': True}


def client(service, folder=None, environment=None, sandbox=False, arch='arm64'):
    """The client's executable in a bundle beside a copy of `service`. With
    `environment`, the copy's Info.plist gives the service those variables and
    the copy is signed again ad hoc without the hardened runtime, so that
    DYLD_INSERT_LIBRARIES reaches it: a fault the tests inject. With `sandbox`,
    the client has the App Sandbox, as the App Store build, and the copy of the
    service the App Store build's entitlements (a sandbox of its own). `arch`
    is the client's slice (x86_64 runs under Rosetta)."""
    service = Path(service)
    stamp = hashlib.sha256(f'{service.resolve()}:{(service / "Contents/Info.plist").stat().st_mtime_ns}'
                           f':{sorted((environment or {}).items())}:{sandbox}:{arch}'.encode()).hexdigest()[:16]
    folder = Path(folder) if folder else CACHE / 'bundles' / stamp
    app = folder / 'DecompressClient.app'
    if app.exists():
        shutil.rmtree(app)
    (app / 'Contents/MacOS').mkdir(parents=True)
    shutil.copy2(_compiled_client(arch), app / 'Contents/MacOS/client')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': 'client', 'CFBundleName': 'DecompressClient',
        'CFBundlePackageType': 'APPL', 'CFBundleInfoDictionaryVersion': '6.0'}))
    copy = app / 'Contents/XPCServices/Decompress.xpc'
    shutil.copytree(service, copy, symlinks=True)
    if environment:
        info = plistlib.loads((copy / 'Contents/Info.plist').read_bytes())
        info.setdefault('XPCService', {})['EnvironmentVariables'] = dict(environment)
        (copy / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', str(copy)], check=True, capture_output=True)
    if sandbox:
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', '--entitlements',
                        str(ROOT / 'Horos/Configuration/AppStoreDecompress.entitlements'), str(copy)],
                       check=True, capture_output=True)
        (folder / 'client.entitlements').write_bytes(plistlib.dumps(SANDBOX))
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(folder / 'client.entitlements'),
                        str(app)], check=True, capture_output=True)
    else:
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return app / 'Contents/MacOS/client'


def helper(args, root=ROOT):
    """What a test runs as the helper: `--helper PATH` from `args`, or the
    client of the built service; None when there is none."""
    if '--helper' in args:
        given = Path(args[args.index('--helper') + 1]).resolve()
        if given.suffix == '.xpc':
            return client(given)
        return given if given.is_file() else None
    service = built_service(root)
    return client(service) if service else None

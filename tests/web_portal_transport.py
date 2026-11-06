"""Build the app's HTTP transport (SwiftNIO) into a test server, outside the app.

The web portal and XML-RPC listen through three app sources:
HTTPServerListener.swift, HTTPConnectionEngine.swift and XMLRPCListener.swift,
over SwiftNIO and the IsiXHTTPServer and IsiXKeychain modules. A test needs them
running, not the app around them: `build_server(main)` writes a SwiftPM package in
build/WebPortalTransportTests that compiles those sources unchanged with `main`
(a test's server program) against the SwiftNIO checkouts the app's Debug build
resolved (build/SourcePackages), so nothing is fetched, and answers the
executable.

Exit 2 (skipped) without those checkouts: build Debug first
(script/build_and_run.sh --verify).
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CHECKOUTS = ROOT / 'build/SourcePackages/checkouts'
PACKAGES = ('swift-nio', 'swift-nio-transport-services', 'swift-atomics', 'swift-collections', 'swift-system')
APP_SOURCES = ('HTTPServerListener.swift', 'HTTPConnectionEngine.swift', 'XMLRPCListener.swift')
MODULES = ('IsiXLogging', 'IsiXHTTPServer', 'IsiXKeychain')
WORK = ROOT / 'build/WebPortalTransportTests'


def build_server(main: str, name: str = 'TransportServer') -> Path:
    missing = [package for package in PACKAGES if not (CHECKOUTS / package / 'Package.swift').is_file()]
    if missing:
        print('skipped: the SwiftNIO checkouts of a Debug build are missing (%s); build Debug first '
              '(script/build_and_run.sh --verify)' % ', '.join(missing), file=sys.stderr)
        raise SystemExit(2)
    package = WORK / name
    sources = package / 'Sources'
    if sources.exists():
        shutil.rmtree(sources)
    for module in MODULES:
        shutil.copytree(ROOT / 'Modules' / module / 'Sources', sources / module)
    server = sources / name
    server.mkdir(parents=True)
    for source in APP_SOURCES:
        shutil.copy2(ROOT / 'Horos/Sources' / source, server / source)
    (server / 'main.swift').write_text(main)
    dependencies = ',\n        '.join('.package(path: %s)' % json.dumps(str(CHECKOUTS / p)) for p in PACKAGES)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "%(name)s",
    platforms: [.macOS(.v15)],
    dependencies: [
        %(dependencies)s
    ],
    targets: [
        .target(name: "IsiXHTTPServer"),
        .target(name: "IsiXLogging"),
        .target(name: "IsiXKeychain", dependencies: ["IsiXLogging"]),
        .executableTarget(name: "%(name)s", dependencies: [
            "IsiXHTTPServer", "IsiXKeychain",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
''' % {'name': name, 'dependencies': dependencies})
    result = subprocess.run(['swift', 'build', '--package-path', str(package), '--disable-automatic-resolution',
                             '--product', name], capture_output=True, text=True, timeout=1500)
    if result.returncode != 0:
        # Resolution is offline: every package is a local checkout.
        result = subprocess.run(['swift', 'build', '--package-path', str(package), '--product', name],
                                capture_output=True, text=True, timeout=1500)
    if result.returncode != 0:
        print(result.stdout[-6000:], result.stderr[-4000:], sep='\n', file=sys.stderr)
        raise RuntimeError('the transport test server did not build')
    binary = subprocess.run(['swift', 'build', '--package-path', str(package), '--product', name, '--show-bin-path'],
                            capture_output=True, text=True, check=True, timeout=300).stdout.strip()
    return Path(binary) / name

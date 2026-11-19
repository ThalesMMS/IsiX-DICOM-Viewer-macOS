"""Build the app's HTTP transport (SwiftNIO) into a test server, outside the app.

The web portal and XML-RPC listen through three app sources:
HTTPServerListener.swift, HTTPConnectionEngine.swift and XMLRPCListener.swift,
over SwiftNIO and the IsiXHTTPServer and IsiXKeychain modules. A test needs them
running, not the app around them: `build_server(main)` writes a SwiftPM package in
build/WebPortalTransportTests that compiles those sources unchanged with `main`
(a test's server program) against the SwiftNIO checkouts the app's Debug build
resolved (build/SourcePackages), so nothing is fetched, and answers the
executable.

The classes of the HTTP server of the Horos and OsiriX plugin SDK, which the
portal's own classes descend from, are compiled with them, unchanged too:
HTTPServer, HTTPConnection, HTTPDataResponse, HTTPFileResponse, AsyncSocket and
DDKeychain, each a Swift implementation (@objc @implementation) of the class
its header declares. The headers reach Swift through a bridging header, and
the two constants AsyncSocket.h declares are defined by AsyncSocket+CAPI.m, an
Objective-C target of the package. `main` supplies FormerSDKFacade, the notice
of a selector that does nothing, which in the app comes with a module this
package does not build.

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
APP_SOURCES = ('HTTPServerListener.swift', 'HTTPConnectionEngine.swift', 'XMLRPCListener.swift',
               'HTTPServer.swift', 'HTTPConnection.swift', 'HTTPDataResponse.swift', 'HTTPFileResponse.swift',
               'AsyncSocket.swift', 'DDKeychain.swift', 'KeychainCertificatePresentation.swift')
SDK_HEADERS = ('HorosWebPathSafety.h', 'HTTPResponse.h', 'AsyncSocket.h', 'HTTPServer.h', 'HTTPConnection.h', 'DDKeychain.h')
SDK_CONSTANTS = 'AsyncSocket+CAPI.m'
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
    bridging = package / 'bridging.h'
    bridging.write_text('#import <Cocoa/Cocoa.h>\n' + ''.join('#import "%s"\n' % header for header in SDK_HEADERS))
    constants = sources / 'FormerSDKConstants'
    (constants / 'include').mkdir(parents=True)
    (constants / 'include' / 'FormerSDKConstants.h').write_text('// The constants are declared by AsyncSocket.h.\n')
    shutil.copy2(ROOT / 'Horos/Sources' / SDK_CONSTANTS, constants / SDK_CONSTANTS)
    headers = json.dumps('-I' + str(ROOT / 'Horos/Sources'))
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
        .target(name: "FormerSDKConstants", cSettings: [.unsafeFlags([%(headers)s, "-fno-objc-arc"])]),
        .executableTarget(name: "%(name)s", dependencies: [
            "IsiXHTTPServer", "IsiXKeychain", "FormerSDKConstants",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
        ], swiftSettings: [.unsafeFlags(["-import-objc-header", %(bridging)s, "-Xcc", %(headers)s])]),
    ],
    swiftLanguageModes: [.v6]
)
''' % {'name': name, 'dependencies': dependencies, 'headers': headers, 'bridging': json.dumps(str(bridging))})
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

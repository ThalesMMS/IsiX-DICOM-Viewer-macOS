#!/usr/bin/env python3
"""The OS version predicates must keep saying yes as macOS version numbers grow.

AppController is Swift since #830: its predicates are compiled with swiftc in a
Swift AppController whose +operatingSystemVersion answers the version under test.
"""
from pathlib import Path
import subprocess, sys, tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
path = str(source_path('AppController').relative_to(root))
source = (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path])
          if len(sys.argv) > 1 else (root / path).read_bytes()).decode('utf-8')

start = source.index('    @objc public class func hasMacOSX1083() -> Bool {')
end = source.index('    @available(*, deprecated) @objc(createNoIndexDirectoryIfNecessary:)')
predicates = source[start:end]

code = r'''
import Foundation

var current = OperatingSystemVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0)

@objc(AppController) final class AppController: NSObject {
    @objc class func operatingSystemVersion() -> OperatingSystemVersion { return current }
PREDICATES
}

func check(_ passed: Bool, _ what: String, line: Int = #line) {
    if !passed {
        print("FAIL: \(what) at line \(line) (at \(current.majorVersion).\(current.minorVersion).\(current.patchVersion))")
        exit(1)
    }
}

func at(_ major: Int, _ minor: Int, _ patch: Int) {
    current = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
}

// Below every gate.
at(10,6,8)
check(AppController.hasMacOSXLeopard() && AppController.hasMacOSXSnowLeopard(), "Leopard && SnowLeopard")
check(!AppController.hasMacOSXLion() && !AppController.hasMacOSXElCapitan(), "!Lion && !ElCapitan")

at(10,10,5)
check(AppController.hasMacOSXYosemite(), "Yosemite")
check(!AppController.hasMacOSXElCapitan() && !AppController.hasMacOSXSierra(), "!ElCapitan && !Sierra")

at(10,11,6)
check(AppController.hasMacOSXElCapitan() && AppController.hasMacOSXYosemite(), "ElCapitan && Yosemite")
check(!AppController.hasMacOSXSierra(), "!Sierra")

at(10,12,0)
check(AppController.hasMacOSXSierra() && AppController.hasMacOSXElCapitan(), "Sierra && ElCapitan")

// Every release from Big Sur on must satisfy every gate, however small the
// minor number is: this is the comparison that used to lock the app out.
let modern = [[11,0],[11,7],[12,6],[13,0],[14,4],[15,0],[26,0],[26,6],[27,0],[100,0]]
for v in modern {
    at(v[0], v[1], 0)
    check(AppController.hasMacOSXLeopard(), "Leopard")
    check(AppController.hasMacOSXSnowLeopard(), "SnowLeopard")
    check(AppController.hasMacOSXLion(), "Lion")
    check(AppController.hasMacOSXMountainLion(), "MountainLion")
    check(AppController.hasMacOSXMaverick(), "Maverick")
    check(AppController.hasMacOSXYosemite(), "Yosemite")
    check(AppController.hasMacOSXElCapitan(), "ElCapitan")
    check(AppController.hasMacOSXSierra(), "Sierra")
    // The exact-version probe stays exact.
    check(!AppController.hasMacOSX1083(), "!1083")
}

// The exact probe matches only its own version.
at(10,8,3); check(AppController.hasMacOSX1083(), "1083")
at(10,8,4); check(!AppController.hasMacOSX1083(), "!1083")
at(10,8,0); check(!AppController.hasMacOSX1083(), "!1083")

print("PASS: 10.6 through 10.12 gate as expected, and 11, 12, 13, 14, 15, 26, 27 and beyond satisfy every gate whatever the minor version")
'''.replace('PREDICATES', predicates)

with tempfile.TemporaryDirectory(prefix='horos-os-version-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(code)
    # Swift traps on arithmetic overflow itself, as -fsanitize=undefined did for the Objective-C.
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'OSVersionGate', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

#!/usr/bin/env python3
"""Verify rejected updates cannot reach deletion of the installed plugin.

PluginManager is Swift: the shipped +installPluginFromPath: is
compiled with the Objective-C messaging helpers of PluginManager.swift and the
preflight of PluginManager+CAPI.m; the atomic installer is a counting stand-in.
"""
from pathlib import Path
import argparse
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=source_path('PluginManager'))
args = parser.parse_args()


def swift_block(text, at):
    """From `at` to the brace closing the first block that opens after it,
    outside comments and string literals."""
    index, depth, opened = at, 0, False
    while index < len(text):
        if text.startswith('//', index):
            index = text.find('\n', index)
            if index < 0:
                break
            continue
        if text.startswith('/*', index):
            index = text.index('*/', index) + 2
            continue
        if text[index] == '"':
            index += 1
            while text[index] != '"':
                index += 2 if text[index] == '\\' else 1
        elif text[index] == '{':
            depth, opened = depth + 1, True
        elif text[index] == '}':
            depth -= 1
            if opened and depth == 0:
                return text[at:index + 1]
        index += 1
    return ''


source = args.source.read_text()
# The atomic installer is replaced by a stand-in that records the destination.
method = swift_block(source, source.index('@objc(installPluginFromPath:)')).replace('PluginManagerCAPIInstallPlugin(', 'FixtureInstall(')
helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
header = (root / 'Horos/Sources/PluginManager.h').read_bytes().decode('latin1')
declarations = header[header.index('@class PluginManager;') + len('@class PluginManager;'):header.index('#elif __has_include("Horos-Swift.h")')]
bridge = '#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n' + declarations
program = r'''
import AppKit

HELPERS

var deletions = 0, moves = 0, alerts = 0
var duplicateInstallations = false, inactiveInstallation = false
var installRoot: NSString = ""
var lastDestination: String? = nil
func FixtureInstall(_ source: String?, _ destination: String?, _ error: NSErrorPointer) -> Bool { moves += 1; lastDestination = destination; return true }
@objc(HorosAlertPanel) final class HorosAlertPanel: NSObject {
    @discardableResult @objc static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
@objc(HorosArchitectureAudit) final class HorosArchitectureAudit: NSObject {
    @objc(pluginDiagnosisAtPath:) static func pluginDiagnosis(at path: String) -> String? {
        if path.contains("QAIntel") {
            return "This plugin is Intel-only (x86_64) and cannot load in this arm64 Horos process. Obtain an arm64 plugin from its author."
        }
        return nil
    }
}
@objc(PluginManager) final class PluginManager: NSObject {
    @objc class func isPluginBundleSignatureValid(_ path: String!) -> Bool { return PluginManagerCAPISignatureAllowsLoading(path, nil) }
    @objc class func pluginsList() -> [Any]! {
        return duplicateInstallations ? [["name": "QAUniversal", "availability": "User", "active": true], ["name": "QAUniversal", "availability": "App", "active": true]]
            : (inactiveInstallation ? [["name": "QAUniversal", "availability": "User", "active": false]] : [])
    }
    @objc class func availabilities() -> [Any]! { return ["User", "System", "App"] }
    @objc class func deletePlugin(withName name: String!) -> String! { deletions += 1; return nil }
    @objc class func movePlugin(fromPath source: String!, toPath destination: String!) { moves += 1 }
DIRECTORY_METHODS
METHOD
}

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

let root = CommandLine.arguments[1] as NSString
installRoot = root
var rejected = ["Missing", "QAInvalidSignature"]
#if arch(arm64)
rejected.append("QAIntel")
#endif
for name in rejected {
    PluginManager.installPlugin(fromPath: root.appendingPathComponent(name + ".horosplugin"))
    check(deletions == 0 && moves == 0, "Rejected update must preserve installed plugin: \(name)")
}
check(alerts == rejected.count, "Each rejection must explain the failure")
PluginManager.installPlugin(fromPath: root.appendingPathComponent("QAUniversal.horosplugin"))
check(deletions == 0 && moves == 1, "Compatible candidate must reach existing install flow")
inactiveInstallation = true
let legacy = (PluginManager.userInactivePluginsDirectoryPath() as NSString).appendingPathComponent("QAUniversal.osirixplugin")
try? FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true, attributes: nil)
PluginManager.installPlugin(fromPath: root.appendingPathComponent("QAUniversal.horosplugin"))
check(moves == 2 && lastDestination == legacy, "Update must preserve inactive location and legacy extension")
duplicateInstallations = true
PluginManager.installPlugin(fromPath: root.appendingPathComponent("QAUniversal.horosplugin"))
check(deletions == 0 && moves == 2 && alerts == rejected.count + 1, "Ambiguous duplicates must be preserved without installing")
check(NSClassFromString("QAUniversal") == nil, "Preflight must not execute candidate code")
print("PASS: missing, invalid-signature and incompatible updates rejected before deletion; compatible preflight does not load code")
'''
names = [f'{scope}{state}PluginsDirectoryPath' for scope in ('user', 'system', 'app') for state in ('Active', 'Inactive')]
program = program.replace('DIRECTORY_METHODS', '\n'.join(f'    @objc class func {n}() -> String! {{ return installRoot.appendingPathComponent("{n}") }}' for n in names)).replace('HELPERS', helpers).replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-install-preflight-') as directory:
    p = Path(directory)
    subprocess.run(['python3', str(root/'tools/generate-plugin-load-fixtures.py'), str(p/'fixtures')], check=True)
    (p/'main.swift').write_text(program)
    (p/'bridge.h').write_text(bridge)
    for name in ('PluginManager+CAPI', 'HorosObjCException'):
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fsanitize=address', '-I', str(root/'Horos/Sources'),
                        str(root/'Horos/Sources'/(name + '.m')), '-o', str(p/(name + '.o'))], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'InstallPreflight', '-sanitize=address', '-import-objc-header', str(p/'bridge.h'),
                    '-Xcc', '-I' + str(root/'Horos/Sources'), str(p/'main.swift'),
                    str(p/'PluginManager+CAPI.o'), str(p/'HorosObjCException.o'),
                    '-framework', 'Security', '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test'), str(p/'fixtures')], check=True, timeout=30)

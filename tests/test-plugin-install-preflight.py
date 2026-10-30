#!/usr/bin/env python3
"""Verify rejected updates cannot reach deletion of the installed plugin.

PluginManager is Swift: the shipped +installPluginFromPath: and the refusal it
asks first (+pluginInstallRefusal: of PluginManager+IsiXPlugins.swift, which is
IsiXPluginLoading's PluginAdmission) are compiled with the Objective-C messaging
helpers of PluginManager.swift, the module's sources and the preflight and
signature check of PluginManager+CAPI.m; the atomic installer is a counting
stand-in.

Only version 1 bundles are installed. A former plugin (.horosplugin,
.osirixplugin), one renamed to .isixplugin, a version 1 bundle for another
architecture or with a broken signature, and a missing one are refused with an
alert, before anything is deleted or moved and without any of their code
running. A former plugin of the same name beside the installed one is neither
counted as a duplicate nor replaced.
"""
from pathlib import Path
import argparse
import os
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
v1 = (root / 'Horos/Sources/PluginManager+IsiXPlugins.swift').read_text()
# The atomic installer is replaced by a stand-in that records the destination.
method = swift_block(source, source.index('@objc(installPluginFromPath:)')).replace('PluginManagerCAPIInstallPlugin(', 'FixtureInstall(')
refusal = swift_block(v1, v1.index('    class func pluginInstallRefusal('))
helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
module = sorted((root / 'Modules/IsiXPluginLoading/Sources').glob('*.swift'))
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
var lastMessage = ""
func FixtureInstall(_ source: String?, _ destination: String?, _ error: NSErrorPointer) -> Bool { moves += 1; lastDestination = destination; return true }
@objc(HorosAlertPanel) final class HorosAlertPanel: NSObject {
    @discardableResult @objc static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; lastMessage = message; return 1 }
}
@objc(HorosArchitectureAudit) final class HorosArchitectureAudit: NSObject {
    @objc(pluginDiagnosisAtPath:) static func pluginDiagnosis(at path: String) -> String? { return nil }
}
@objc(PluginManager) final class PluginManager: NSObject {
    static let legacyPluginKey = "legacy"
    @objc class func isPluginBundleSignatureValid(_ path: String!) -> Bool { return PluginManagerCAPISignatureAllowsLoading(path, nil) }
REFUSAL
    @objc class func pluginsList() -> [Any]! {
        // A former plugin of the same name, as the plugin manager lists it.
        let former: [String: Any] = ["name": "QAVersion1", "availability": "User", "active": true, "legacy": true]
        return duplicateInstallations ? [former, ["name": "QAVersion1", "availability": "User", "active": true], ["name": "QAVersion1", "availability": "App", "active": true]]
            : (inactiveInstallation ? [former, ["name": "QAVersion1", "availability": "User", "active": false]] : [former])
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
let markers = CommandLine.arguments[2]
installRoot = root
var rejected = ["Missing.isixplugin", "QAVersion1InvalidSignature.isixplugin", "QAUniversal.horosplugin",
                "QAOsiriX.osirixplugin", "QARenamed.isixplugin"]
#if arch(arm64)
rejected.append("QAVersion1Intel.isixplugin")
#endif
for name in rejected {
    let before = alerts
    PluginManager.installPlugin(fromPath: root.appendingPathComponent(name))
    check(deletions == 0 && moves == 0, "Rejected update must preserve installed plugin: \(name)")
    check(alerts == before + 1, "The rejection of \(name) must explain the failure")
    if name.hasSuffix("plugin") && !name.hasPrefix("QAVersion1") && name != "QARenamed.isixplugin" && name != "Missing.isixplugin" {
        check(lastMessage.contains("Horos or OsiriX"), "A former plugin is refused as one: \(lastMessage)")
    }
    if name == "QARenamed.isixplugin" {
        check(lastMessage.contains("former plugin API"), "A renamed former plugin is refused by what it declares: \(lastMessage)")
    }
}
// The former plugin of the same name in the list is not a duplicate.
PluginManager.installPlugin(fromPath: root.appendingPathComponent("QAVersion1.isixplugin"))
check(deletions == 0 && moves == 1, "A compatible version 1 candidate must reach the installation")
check(lastDestination == (PluginManager.userActivePluginsDirectoryPath() as NSString).appendingPathComponent("QAVersion1.isixplugin"),
      "A new plugin goes to the user's active folder: \(lastDestination ?? "nil")")
inactiveInstallation = true
let former = (PluginManager.userInactivePluginsDirectoryPath() as NSString).appendingPathComponent("QAVersion1.horosplugin")
try? FileManager.default.createDirectory(atPath: former, withIntermediateDirectories: true, attributes: nil)
PluginManager.installPlugin(fromPath: root.appendingPathComponent("QAVersion1.isixplugin"))
check(moves == 2 && lastDestination == (PluginManager.userInactivePluginsDirectoryPath() as NSString).appendingPathComponent("QAVersion1.isixplugin"),
      "An update keeps the inactive location and never takes a former plugin's place: \(lastDestination ?? "nil")")
check(FileManager.default.fileExists(atPath: former), "The former plugin beside it is left alone")
duplicateInstallations = true
PluginManager.installPlugin(fromPath: root.appendingPathComponent("QAVersion1.isixplugin"))
check(deletions == 0 && moves == 2 && alerts == rejected.count + 1, "Ambiguous duplicates must be preserved without installing")
check(NSClassFromString("QAVersion1") == nil && NSClassFromString("QAUniversal") == nil, "Preflight must not execute candidate code")
check(((try? FileManager.default.contentsOfDirectory(atPath: markers)) ?? []).isEmpty, "No candidate's +load ran")
print("PASS: former, renamed, missing, invalid-signature and incompatible plugins rejected before deletion; a version 1 plugin installs without its code running, beside a former plugin of its name")
'''
names = [f'{scope}{state}PluginsDirectoryPath' for scope in ('user', 'system', 'app') for state in ('Active', 'Inactive')]
program = program.replace('DIRECTORY_METHODS', '\n'.join(f'    @objc class func {n}() -> String! {{ return installRoot.appendingPathComponent("{n}") }}' for n in names)).replace('HELPERS', helpers).replace('REFUSAL', refusal).replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-install-preflight-') as directory:
    p = Path(directory)
    subprocess.run(['python3', str(root/'tools/generate-plugin-load-fixtures.py'), str(p/'fixtures')], check=True, capture_output=True)
    (p/'markers').mkdir()
    (p/'main.swift').write_text(program)
    (p/'bridge.h').write_text(bridge)
    for name in ('PluginManager+CAPI', 'HorosObjCException'):
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fsanitize=address', '-I', str(root/'Horos/Sources'),
                        str(root/'Horos/Sources'/(name + '.m')), '-o', str(p/(name + '.o'))], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'InstallPreflight', '-sanitize=address', '-import-objc-header', str(p/'bridge.h'),
                    '-Xcc', '-I' + str(root/'Horos/Sources'), str(p/'main.swift'), *map(str, module),
                    str(p/'PluginManager+CAPI.o'), str(p/'HorosObjCException.o'),
                    # The stand-in IsiXPluginKit, as the application provides the real one.
                    '-Xlinker', '-rpath', '-Xlinker', str(p/'fixtures/Kit'),
                    '-framework', 'Security', '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test'), str(p/'fixtures'), str(p/'markers')], check=True, timeout=60,
                   env=dict(os.environ, HOROS_PLUGIN_MARKER_DIR=str(p/'markers')))

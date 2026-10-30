#!/usr/bin/env python3
"""Run the production plugin loader entry against disposable plugin bundles.

PluginManager is Swift. The shipped +loadPluginAtPath:, which discovery and
--LoadPlugin call for every bundle, +loadIsiXPluginAtPath: and
+isPluginBundleSignatureValid: are compiled with the registry and Objective-C
messaging helpers of PluginManager.swift, IsiXPluginLoading's sources,
PluginManager+CAPI.m (load outcomes, signature), HorosObjCException and
IsiXPluginExceptionGuard. Only IsiXPluginHost, which runs a version 1 plugin,
is a stand-in that inspects the bundle and reports what the real host would,
without loading it, or lets an Objective-C or C++ exception escape, as a
bundle's initializers can.

- A former plugin (.horosplugin, .osirixplugin) is recorded as Incompatible
  with its reason; no loader is reached, none of its code runs, its name does
  not count as a duplicate, and nothing in its bundle changes.
- Protected mode and a broken signature block a version 1 plugin before the
  host sees it; a duplicate name is blocked with an alert.
- The host's outcome is recorded: Loaded, or Incompatible with the inspector's
  reason, as for a former plugin renamed to .isixplugin.
- An Objective-C or C++ exception that escapes the loading of a version 1
  plugin is recorded as Load failed with its type and reason, and the loader
  goes on.
"""
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402


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


def digest(folder):
    """Every file's path, mode and bytes under `folder`, links as their targets."""
    h = hashlib.sha256()
    for path in sorted(folder.rglob('*')):
        h.update(str(path.relative_to(folder)).encode())
        if path.is_symlink():
            h.update(os.readlink(path).encode())
        elif path.is_file():
            h.update(oct(path.stat().st_mode).encode() + path.read_bytes())
    return h.hexdigest()


source = source_text('PluginManager')
v1 = (root / 'Horos/Sources/PluginManager+IsiXPlugins.swift').read_text()
load = swift_block(source, source.index('@objc(loadPluginAtPath:)'))
load_v1 = swift_block(v1, v1.index('@objc(loadIsiXPluginAtPath:)'))
signature_method = swift_block(source, source.index('@objc(isPluginBundleSignatureValid:)'))
helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
registry = swift_block(source, source.index('fileprivate enum Registry {'))
module = sorted((root / 'Modules/IsiXPluginLoading/Sources').glob('*.swift'))
header = (root / 'Horos/Sources/PluginManager.h').read_bytes().decode('latin1')
# What PluginManager.h declares to the Swift class, from PluginManager+CAPI.m.
declarations = header[header.index('@class PluginManager;') + len('@class PluginManager;'):header.index('#elif __has_include("Horos-Swift.h")')]
bridge = ('#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n#import "IsiXPluginExceptionGuard.h"\n'
          'void TestHostRaise(const char *kind);\n' + declarations)
# What the host stand-in calls to let an exception escape, in each language.
raiser = '''#import <Foundation/Foundation.h>
#include <cstring>
#include <stdexcept>
extern "C" void TestHostRaise(const char *kind)
{
    if (std::strcmp(kind, "cxx") == 0) throw std::runtime_error("the host stand-in threw");
    [NSException raise:@"TestHostException" format:@"the host stand-in raised"];
}
'''

program = r'''
import AppKit

REGISTRY

HELPERS

var protectedDepth = 0
var protectedMode = false
var hostCalls: [String] = []
var alerts = 0
var hostRaises: String?

extension NSString {
    @objc(stringByResolvingAlias) func resolvingAlias() -> String! { return self.resolvingSymlinksInPath }
}
// What the host says of an exception that escaped a plugin; the real one
// (IsiXPluginCommandGuard.swift) needs the plugin kit.
struct IsiXPluginException: CustomStringConvertible {
    let description: String
    init(_ error: NSError) { description = "\(error.localizedFailureReason ?? ""): \(error.localizedDescription)" }
}
func onMainActorSync<Result>(_ body: @MainActor @Sendable () throws -> Result) rethrows -> Result {
    try MainActor.assumeIsolated { try body() }
}
@objc(DCMPix) final class DCMPix: NSObject {
    @objc static func isRunOsiriXInProtectedModeActivated() -> Bool { return protectedMode }
}
@objc(HorosAlertPanel) final class HorosAlertPanel: NSObject {
    @discardableResult @objc static func run(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
enum PluginUpdateRecovery {
    static func discardPrevious(forDestination path: String!) {}
}
// The host that runs version 1 plugins: it answers from the inspector, as the
// real one does before it loads anything, and loads nothing.
@MainActor final class IsiXPluginHost {
    static let shared = IsiXPluginHost()
    struct Outcome {
        enum State { case loaded, incompatible, failed }
        var state: State
        var reason: String
    }
    func loadPlugin(at url: URL) -> Outcome {
        hostCalls.append(url.lastPathComponent)
        if let kind = hostRaises { TestHostRaise(kind) }
        let inspection = PluginInspector().inspect(bundleAt: url)
        return inspection.isLoadable ? Outcome(state: .loaded, reason: "") : Outcome(state: .incompatible, reason: inspection.summary)
    }
}
@objc(PluginManager) final class PluginManager: NSObject {
SIGNATURE_METHOD
    @objc(startProtectForCrashWithPath:) class func startProtectForCrash(withPath path: String!) { protectedDepth += 1 }
    @objc class func endProtectForCrash() { protectedDepth -= 1 }
LOAD
LOAD_V1
}

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}
func state(_ path: String) -> String? { PluginManagerCAPILoadOutcome(path, true)["loadState"] as? String }
func reason(_ path: String) -> String { (PluginManagerCAPILoadOutcome(path, true)["loadReason"] as? String) ?? "" }

Registry.pluginsNames = NSMutableDictionary(); Registry.pluginsBundleDictionnary = NSMutableDictionary()
Registry.fileFormatPlugins = NSMutableDictionary(); Registry.plugins = NSMutableDictionary(); Registry.pluginsDict = NSMutableDictionary()
Registry.reportPlugins = NSMutableDictionary(); Registry.preProcessPlugins = NSMutableArray()
let root = CommandLine.arguments[1] as NSString

// Former plugins: refused by their extension, in and out of protected mode.
for mode in [true, false] {
    protectedMode = mode
    for name in ["QAUniversal.horosplugin", "QAInitializationFailure.horosplugin", "QAOsiriX.osirixplugin"] {
        let path = root.appendingPathComponent(name)
        PluginManager.loadPlugin(atPath: path)
        check(state(path) == "Incompatible", "\(name): expected Incompatible, got \(state(path) ?? "nil")")
        check(reason(path).contains("Horos or OsiriX") && reason(path).contains("did not open, move or change"), "\(name): the reason says why: \(reason(path))")
    }
}
check(hostCalls.isEmpty && protectedDepth == 0, "No loader is reached for a former plugin")
check(NSClassFromString("QAUniversal") == nil && NSClassFromString("QAInitializationFailure") == nil, "No former plugin's code is loaded")
check(Registry.pluginsNames!.count == 0 && Registry.plugins!.count == 0, "A former plugin registers nothing, not even its name")

// Version 1: protected mode and the signature come first.
let version1 = root.appendingPathComponent("QAVersion1.isixplugin")
protectedMode = true
PluginManager.loadPlugin(atPath: version1)
check(state(version1) == "Blocked" && hostCalls.isEmpty, "Protected mode blocks a version 1 plugin before the host")
protectedMode = false
Registry.pluginsNames = NSMutableDictionary()
let broken = root.appendingPathComponent("QAVersion1InvalidSignature.isixplugin")
PluginManager.loadPlugin(atPath: broken)
check(state(broken) == "Blocked" && hostCalls.isEmpty, "A broken signature blocks a version 1 plugin before the host: \(state(broken) ?? "nil")")
PluginManager.loadPlugin(atPath: version1)
check(state(version1) == "Loaded" && hostCalls == ["QAVersion1.isixplugin"] && protectedDepth == 0, "A version 1 plugin reaches the host and is recorded as loaded")
let duplicate = root.appendingPathComponent("Copy/QAVersion1.isixplugin")
PluginManager.loadPlugin(atPath: duplicate)
check(state(duplicate) == "Blocked" && alerts == 1 && hostCalls.count == 1, "A second plugin of the same name is blocked with an alert")
let renamed = root.appendingPathComponent("QARenamed.isixplugin")
PluginManager.loadPlugin(atPath: renamed)
check(state(renamed) == "Incompatible" && reason(renamed).contains("former plugin API"), "A renamed former plugin is refused by what it declares: \(reason(renamed))")
check(NSClassFromString("QAUniversal") == nil, "The renamed former plugin's code is not loaded")
// An exception that escapes the loading: recorded, and the loader goes on.
for (kind, expected) in [("cxx", "std::runtime_error: the host stand-in threw"), ("objc", "TestHostException: the host stand-in raised")] {
    Registry.pluginsNames = NSMutableDictionary()
    hostRaises = kind
    PluginManager.loadPlugin(atPath: version1)
    hostRaises = nil
    check(state(version1) == "Load failed" && reason(version1).contains(expected) && protectedDepth == 0,
          "An exception (\(kind)) that escapes the loading is recorded: \(state(version1) ?? "nil") \(reason(version1))")
}
Registry.pluginsNames = NSMutableDictionary()
PluginManager.loadPlugin(atPath: version1)
check(state(version1) == "Loaded", "The loader goes on after a caught exception")
print("PASS: former plugins refused unopened at the loader entry; protected mode, signature, duplicates, the host's verdict for version 1 plugins and exceptions that escape the loading")
'''.replace('REGISTRY', registry).replace('HELPERS', helpers).replace('SIGNATURE_METHOD', signature_method).replace('LOAD_V1', load_v1).replace('LOAD', load)
with tempfile.TemporaryDirectory(prefix='horos-bundle-load-') as directory:
    p = Path(directory)
    subprocess.run(['python3', str(root/'tools/generate-plugin-load-fixtures.py'), str(p/'fixtures')], check=True, capture_output=True)
    subprocess.run(['ditto', str(p/'fixtures/QAVersion1.isixplugin'), str(p/'fixtures/Copy/QAVersion1.isixplugin')], check=True)
    (p/'main.swift').write_text(program)
    (p/'bridge.h').write_text(bridge)
    (p/'raiser.mm').write_text(raiser)
    for name, path in (('PluginManager+CAPI', root/'Horos/Sources/PluginManager+CAPI.m'),
                       ('HorosObjCException', root/'Horos/Sources/HorosObjCException.m'),
                       ('IsiXPluginExceptionGuard', root/'Horos/Sources/IsiXPluginExceptionGuard.mm'),
                       ('raiser', p/'raiser.mm')):
        subprocess.run(['xcrun', 'clang++' if path.suffix == '.mm' else 'clang', '-c', '-fno-objc-arc',
                        '-I', str(root/'Horos/Sources'), str(path), '-o', str(p/(name + '.o'))], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'BundleLoading', '-import-objc-header', str(p/'bridge.h'),
                    '-Xcc', '-I' + str(root/'Horos/Sources'), str(p/'main.swift'), *map(str, module),
                    str(p/'PluginManager+CAPI.o'), str(p/'HorosObjCException.o'), str(p/'IsiXPluginExceptionGuard.o'),
                    str(p/'raiser.o'), '-lc++', '-framework', 'Security', '-o', str(p/'test')], check=True)
    before = digest(p/'fixtures')
    subprocess.run([str(p/'test'), str(p/'fixtures')], check=True, timeout=60)
    if digest(p/'fixtures') != before:
        raise SystemExit('FAIL: loading changed a bundle')

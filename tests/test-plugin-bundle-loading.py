#!/usr/bin/env python3
"""Run the production loader against disposable compiled plugin bundles.

PluginManager is Swift. The shipped +loadPluginBundle: and
+isPluginBundleSignatureValid: are compiled with the registry and Objective-C
messaging helpers of PluginManager.swift, PluginManager+CAPI.m (load outcomes,
signature, bundle loading) and HorosObjCException, which is what catches a
plugin's exception now that the loader is Swift.
"""
from pathlib import Path
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


source = source_text('PluginManager')
method = swift_block(source, source.index('@objc(loadPluginBundle:)'))
signature_method = swift_block(source, source.index('@objc(isPluginBundleSignatureValid:)'))
helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
registry = swift_block(source, source.index('fileprivate enum Registry {'))
header = (root / 'Horos/Sources/PluginManager.h').read_bytes().decode('latin1')
# What PluginManager.h declares to the Swift class, from PluginManager+CAPI.m.
declarations = header[header.index('@class PluginManager;') + len('@class PluginManager;'):header.index('#elif __has_include("Horos-Swift.h")')]
bridge = '#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n' + declarations

program = r'''
import AppKit

REGISTRY

HELPERS

var protectedDepth = 0
var protectedMode = false

extension NSString {
    @objc(stringByResolvingAlias) func resolvingAlias() -> String! { return self.resolvingSymlinksInPath }
}
@objc(T2FitMapCompatibility) final class T2FitMapCompatibility: NSObject {
    @objc static func diagnostic(forBundleAtPath path: String, loadErrorDomain: String?, loadErrorCode: Int) -> String? { return nil }
}
@objc(ROIEnhancementCompatibility) final class ROIEnhancementCompatibility: NSObject {
    @objc static func diagnostic(forBundleAtPath path: String, loadErrorDomain: String?, loadErrorCode: Int) -> String? { return nil }
}
@objc(HorosArchitectureAudit) final class HorosArchitectureAudit: NSObject {
    @objc(pluginDiagnosisAtPath:) static func pluginDiagnosis(at path: String) -> String? {
        if path.contains("QAIntel") {
            return "This plugin is Intel-only (x86_64) and cannot load in this arm64 Horos process. Obtain an arm64 plugin from its author."
        }
        return nil
    }
}
@objc(DCMPix) final class DCMPix: NSObject {
    @objc static func isRunOsiriXInProtectedModeActivated() -> Bool { return protectedMode }
}
@objc(PluginManager) final class PluginManager: NSObject {
SIGNATURE_METHOD
    @objc(startProtectForCrashWithPath:) class func startProtectForCrash(withPath path: String!) { protectedDepth += 1 }
    @objc class func endProtectForCrash() { protectedDepth -= 1 }
METHOD
}

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

Registry.pluginsNames = NSMutableDictionary(); Registry.pluginsBundleDictionnary = NSMutableDictionary()
Registry.fileFormatPlugins = NSMutableDictionary(); Registry.plugins = NSMutableDictionary(); Registry.pluginsDict = NSMutableDictionary()
Registry.reportPlugins = NSMutableDictionary(); Registry.preProcessPlugins = NSMutableArray()
let root = CommandLine.arguments[1] as NSString
let universalPath = root.appendingPathComponent("QAUniversal.horosplugin")
protectedMode = true
PluginManager.loadPluginBundle(universalPath)
check(PluginManagerCAPILoadOutcome(universalPath, true)["loadState"] as? String == "Blocked", "Protected mode must explain why loading was blocked")
check(NSClassFromString("QAUniversal") == nil, "Protected mode must prevent executable loading, not just hide its menu")
check(Registry.plugins!.count == 0 && Registry.pluginsBundleDictionnary!.count == 0 && protectedDepth == 0, "Protected mode must not register code or leave a crash marker")
protectedMode = false
for name in ["QAUniversal", "QAIntel", "QAMissingClass", "QAInitializationFailure", "QAInvalidSignature"] {
    let path = root.appendingPathComponent(name + ".horosplugin")
    PluginManager.loadPluginBundle(path)
    let state = PluginManagerCAPILoadOutcome(path, true)["loadState"] as? String
    var expected = name == "QAUniversal" ? "Loaded" : (name == "QAInitializationFailure" ? "Load failed" : "Incompatible")
#if arch(x86_64)
    if name == "QAIntel" { expected = "Loaded" }
#endif
    if name == "QAInvalidSignature" { expected = "Blocked" }
    check(state == expected, "\(name): expected \(expected), got \(state ?? "nil")")
    check(protectedDepth == 0, "Crash protection must unwind even after exceptions")
    check((Registry.plugins![name] != nil) == (expected == "Loaded"), "Failed plugins must not enter menu registration")
}
check(NSClassFromString("QAUniversal") != nil, "Compatible code must load after leaving protected mode")
print("PASS: protected-mode blocking and recovery, real universal/Intel/missing-class/initialization-failure/invalid-signature bundles and crash-protection cleanup")
'''.replace('REGISTRY', registry).replace('HELPERS', helpers).replace('SIGNATURE_METHOD', signature_method).replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-bundle-load-') as directory:
    p = Path(directory)
    subprocess.run(['python3', str(root/'tools/generate-plugin-load-fixtures.py'), str(p/'fixtures')], check=True)
    (p/'main.swift').write_text(program)
    (p/'bridge.h').write_text(bridge)
    for name in ('PluginManager+CAPI', 'HorosObjCException'):
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root/'Horos/Sources'),
                        str(root/'Horos/Sources'/(name + '.m')), '-o', str(p/(name + '.o'))], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'BundleLoading', '-import-objc-header', str(p/'bridge.h'),
                    '-Xcc', '-I' + str(root/'Horos/Sources'), str(p/'main.swift'),
                    str(p/'PluginManager+CAPI.o'), str(p/'HorosObjCException.o'),
                    '-framework', 'Security', '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test'), str(p/'fixtures')], check=True, timeout=30)

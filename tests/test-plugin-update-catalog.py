#!/usr/bin/env python3
"""Run the production plugin update scans with controlled catalog transport.

PluginManager is Swift: the two shipped scans are compiled with the
Objective-C messaging helpers of PluginManager.swift, the version and
download-name helpers of PluginManager+CAPI.m and +isVersion1Download: with
IsiXPluginLoading; only the catalog transport is a fixture. Only version 1
plugins are updated, and only to a version 1 package: a former plugin is not
offered an update, and a former plugin package is never proposed.
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
methods = []
for marker in ['@objc(checkForHorosPluginsUpdates:)', '@objc(checkForOsiriXPluginsUpdates:)']:
    methods.append(swift_block(source, source.index(marker)).replace('PluginManagerCAPILoadCatalog(', 'FixtureLoad('))
helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
v1 = (root / 'Horos/Sources/PluginManager+IsiXPlugins.swift').read_text()
version1_download = swift_block(v1, v1.index('    class func isVersion1Download('))
module = sorted((root / 'Modules/IsiXPluginLoading/Sources').glob('*.swift'))
header = (root / 'Horos/Sources/PluginManager.h').read_bytes().decode('latin1')
declarations = header[header.index('@class PluginManager;') + len('@class PluginManager;'):header.index('#elif __has_include("Horos-Swift.h")')]
bridge = '#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n' + declarations
program = r'''
import AppKit

HELPERS

let HOROS_PLUGIN_LIST_URL = "http://127.0.0.1/catalog"
let HOROS_PLUGIN_LIST_ALT_URL = HOROS_PLUGIN_LIST_URL
let OSIRIX_PLUGIN_LIST_URL = HOROS_PLUGIN_LIST_URL
let OSIRIX_PLUGIN_LIST_ALT_URL = HOROS_PLUGIN_LIST_URL
var calls = 0, mode = 0
// The catalog the transport hands over, shared with the scans as it was in Objective-C.
var input = NSMutableArray()
let done = DispatchSemaphore(value: 0)
func FixtureLoad(_ url: URL?, _ timeout: TimeInterval, _ error: NSErrorPointer) -> [Any]? {
    precondition(!Thread.isMainThread, "Update scans must load on worker")
    precondition(timeout == 10, "Bounded timeout required")
    calls += 1
    if mode == 0 {
        error?.pointee = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        return nil
    }
    return input as? [Any]
}

@objc(PluginManager) final class PluginManager: NSObject {
    static let legacyPluginKey = "legacy"
    // A former plugin is listed too, as the plugin manager lists one: it is never updated.
    @objc class func pluginsList() -> [Any]! { return [["name": "Synthetic", "version": "1.0"], ["name": "Former", "version": "1.0", "legacy": true]] }
VERSION1_DOWNLOAD
    @objc(compareVersion:withVersion:) class func compareVersion(_ a: String!, withVersion b: String!) -> Int32 { return Int32(PluginManagerCAPICompareVersions(a, b).rawValue) }
METHODS
    @objc func run() {
        autoreleasepool {
            for m in 0..<5 {
                mode = m
                // Mode 4 offers a newer former plugin package: not an update for anything.
                let package = mode == 4 ? "Synthetic.horosplugin.zip" : "Synthetic.isixplugin.zip"
                var entries: [[String: String]] = [["name": "Synthetic", "version": mode == 3 ? "1.0" : "2.0", "download_url": "https://example.invalid/" + package]]
                if mode == 2 { entries.append(["name": "Former", "version": "2.0", "download_url": "https://example.invalid/Former.isixplugin.zip"]) }
                input = NSMutableArray(array: mode == 1 ? [] : entries)
                calls = 0
                let horos = self.checkForHorosPluginsUpdates(nil)!, osirix = self.checkForOsiriXPluginsUpdates(nil)!
                precondition(calls == 2, "Duplicate fallback URLs should not be retried")
                precondition(horos.count == (mode == 2 ? 1 : 0) && osirix.count == (mode == 2 ? 1 : 0), "Incorrect update result in mode \(mode)")
                precondition(input.count == entries.count * (mode == 1 ? 0 : 1), "Update matching mutated the shared catalog")
            }
            print("PASS: failed/empty/current/newer catalogs, deduplicated endpoints, timeout and immutable input; scans only propose version 1 updates of version 1 plugins")
            done.signal()
        }
    }
}

let manager = PluginManager()
Thread.detachNewThreadSelector(#selector(PluginManager.run), toTarget: manager, with: nil)
done.wait()
'''.replace('HELPERS', helpers).replace('METHODS', '\n'.join(methods)).replace('VERSION1_DOWNLOAD', version1_download)
with tempfile.TemporaryDirectory(prefix='horos-update-catalog-') as directory:
    p = Path(directory)
    (p/'main.swift').write_text(program)
    (p/'bridge.h').write_text(bridge)
    for name in ('PluginManager+CAPI', 'HorosObjCException'):
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root/'Horos/Sources'),
                        str(root/'Horos/Sources'/(name + '.m')), '-o', str(p/(name + '.o'))], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'UpdateCatalog', '-import-objc-header', str(p/'bridge.h'),
                    '-Xcc', '-I' + str(root/'Horos/Sources'), str(p/'main.swift'), *map(str, module),
                    str(p/'PluginManager+CAPI.o'), str(p/'HorosObjCException.o'),
                    '-framework', 'Security', '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test')], check=True, timeout=10)

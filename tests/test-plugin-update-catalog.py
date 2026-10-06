#!/usr/bin/env python3
"""Run the production plugin update scans with controlled catalog transport.

PluginManager is Swift: the two shipped scans are compiled with the
Objective-C messaging helpers of PluginManager.swift and the version and
download-name helpers of PluginManager+CAPI.m; only the catalog transport is a
fixture.
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
    @objc class func pluginsList() -> [Any]! { return [["name": "Synthetic", "version": "1.0"]] }
    @objc(compareVersion:withVersion:) class func compareVersion(_ a: String!, withVersion b: String!) -> Int32 { return Int32(PluginManagerCAPICompareVersions(a, b).rawValue) }
METHODS
    @objc func run() {
        autoreleasepool {
            for m in 0..<4 {
                mode = m
                input = NSMutableArray(array: mode == 1 ? [] : [["name": "Synthetic", "version": mode == 3 ? "1.0" : "2.0", "download_url": "https://example.invalid/Synthetic.horosplugin.zip"]])
                calls = 0
                let horos = self.checkForHorosPluginsUpdates(nil)!, osirix = self.checkForOsiriXPluginsUpdates(nil)!
                precondition(calls == 2, "Duplicate fallback URLs should not be retried")
                precondition(horos.count == (mode == 2 ? 1 : 0) && osirix.count == (mode == 2 ? 1 : 0), "Incorrect update result")
                precondition(input.count == (mode == 1 ? 0 : 1), "Update matching mutated the shared catalog")
            }
            print("PASS: failed/empty/current/newer catalogs, deduplicated endpoints, timeout and immutable input; scans only propose updates")
            done.signal()
        }
    }
}

let manager = PluginManager()
Thread.detachNewThreadSelector(#selector(PluginManager.run), toTarget: manager, with: nil)
done.wait()
'''.replace('HELPERS', helpers).replace('METHODS', '\n'.join(methods))
with tempfile.TemporaryDirectory(prefix='horos-update-catalog-') as directory:
    p = Path(directory)
    (p/'main.swift').write_text(program)
    (p/'bridge.h').write_text(bridge)
    for name in ('PluginManager+CAPI', 'HorosObjCException'):
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root/'Horos/Sources'),
                        str(root/'Horos/Sources'/(name + '.m')), '-o', str(p/(name + '.o'))], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'UpdateCatalog', '-import-objc-header', str(p/'bridge.h'),
                    '-Xcc', '-I' + str(root/'Horos/Sources'), str(p/'main.swift'),
                    str(p/'PluginManager+CAPI.o'), str(p/'HorosObjCException.o'),
                    '-framework', 'Security', '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test')], check=True, timeout=10)

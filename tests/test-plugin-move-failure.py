#!/usr/bin/env python3
"""Exercise the real plugin move helper with controlled authorization outcomes.

A move between folders the user can write needs no authorization (#764): it
must succeed while the authorization would refuse, and without calling it. A
folder the user cannot write still goes through the authorization, and a
refused move there is reported without copying.

PluginManager is Swift since #720: the shipped +movePluginFromPath:toPath: is
compiled with the Objective-C messaging helpers of PluginManager.swift.
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
method = swift_block(source, source.index('@objc(movePluginFromPath:toPath:)'))
# How the method reaches [BLAuthentication sharedInstance].
authentication = swift_block(source, source.index('private class func authentication()'))
helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
program = r'''
import AppKit

HELPERS

var denyMove = false
var alerts = 0, copies = 0, authorizations = 0
@objc(HorosAlertPanel) final class HorosAlertPanel: NSObject {
    @discardableResult @objc static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
@objc(BLAuthentication) final class BLAuthentication: NSObject {
    static let instance = BLAuthentication()
    @objc static func sharedInstance() -> Any! { return instance }
    @objc(executeCommand:withArgs:) func executeCommand(_ command: String!, withArgs args: [Any]!) -> Bool {
        authorizations += 1
        let source = args[args.count - 2] as! String, destination = args.last as! String
        if command == "/bin/mv" {
            if denyMove { return false }
            return (try? FileManager.default.moveItem(atPath: source, toPath: destination)) != nil
        }
        precondition(command == "/bin/cp", "Unexpected command")
        copies += 1
        return (try? FileManager.default.copyItem(atPath: source, toPath: destination)) != nil
    }
}
@objc(PluginManager) final class PluginManager: NSObject {
    AUTHENTICATION
METHOD
}

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

let root = CommandLine.arguments[1] as NSString
let active = root.appendingPathComponent("active/QA.horosplugin")
let inactive = root.appendingPathComponent("inactive/QA.horosplugin")
let fm = FileManager.default
try! fm.createDirectory(atPath: active, withIntermediateDirectories: true, attributes: nil)
let bytes = "synthetic plugin bytes".data(using: .utf8)!
try! bytes.write(to: URL(fileURLWithPath: (active as NSString).appendingPathComponent("payload")), options: .atomic)
let lockedParent = root.appendingPathComponent("locked")
let locked = (lockedParent as NSString).appendingPathComponent("QA.horosplugin")
try! fm.createDirectory(atPath: lockedParent, withIntermediateDirectories: true, attributes: nil)
try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedParent)
denyMove = true
PluginManager.movePlugin(fromPath: active, toPath: locked)
try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedParent)
check(authorizations == 1, "A folder the user cannot write must go through the authorization")
check(copies == 0, "Failed move must not become a copy that leaves the plugin active")
check(alerts == 1, "Failed move must be reported")
check(fm.fileExists(atPath: active) && !fm.fileExists(atPath: locked), "Denied move must preserve source without creating a duplicate")
// The authorization still refuses: writable folders must not need it.
PluginManager.movePlugin(fromPath: active, toPath: inactive)
check(!fm.fileExists(atPath: active) && fm.fileExists(atPath: inactive), "Successful disable must remove active source")
check(fm.contents(atPath: (inactive as NSString).appendingPathComponent("payload")) == bytes, "Move must preserve bytes")
PluginManager.movePlugin(fromPath: inactive, toPath: active)
check(fm.fileExists(atPath: active) && !fm.fileExists(atPath: inactive) && alerts == 1, "Reactivation must move back without errors")
check(authorizations == 1, "Moves between writable folders must not ask for authorization")
print("PASS: writable moves need no authorization; a refused one is reported without copying; bytes preserved")
'''.replace('HELPERS', helpers).replace('AUTHENTICATION', authentication).replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-plugin-move-') as directory:
    p = Path(directory)
    (p/'main.swift').write_text(program)
    (p/'bridge.h').write_text('#import "HorosObjCException.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fsanitize=address', '-I', str(root/'Horos/Sources'),
                    str(root/'Horos/Sources/HorosObjCException.m'), '-o', str(p/'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'MoveFailure', '-sanitize=address', '-import-objc-header', str(p/'bridge.h'),
                    '-Xcc', '-I' + str(root/'Horos/Sources'), str(p/'main.swift'), str(p/'HorosObjCException.o'),
                    '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test'), str(p/'data')], check=True, timeout=30)

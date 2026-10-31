#!/usr/bin/env python3
"""Exercise the real plugin move helper with controlled authorization outcomes.

A move between folders the user can write needs no authorization: it
must succeed while the authorization would refuse, and without calling it. A
folder the user cannot write still goes through the authorization, and a
refused move there is reported without copying. A destination folder
that is missing and that the user cannot make, as the folders of all users
under /Library until a plugin goes there, is made by the same authorization:
one authentication for both commands, then mkdir -p and the move.

PluginManager is Swift: the shipped +movePluginFromPath:toPath: is
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
var authenticated: [[String]] = [], commands: [String] = []
var unlockForMkdir: String? = nil
@objc(HorosAlertPanel) final class HorosAlertPanel: NSObject {
    @discardableResult @objc static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
@objc(BLAuthentication) final class BLAuthentication: NSObject {
    static let instance = BLAuthentication()
    @objc static func sharedInstance() -> Any! { return instance }
    @objc(authenticate:) func authenticate(_ forCommands: [Any]!) -> Bool {
        authenticated.append(forCommands.map { $0 as! String })
        return true
    }
    @objc(executeCommand:withArgs:) func executeCommand(_ command: String!, withArgs args: [Any]!) -> Bool {
        authorizations += 1
        commands.append(command)
        if command == "/bin/mkdir" {
            // As root: the locked folder does not stop it.
            precondition(args.first as? String == "-p", "The folder must be made with its parents")
            let locked = unlockForMkdir!
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            defer { try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked) }
            return (try? FileManager.default.createDirectory(atPath: args.last as! String, withIntermediateDirectories: true, attributes: nil)) != nil
        }
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
check(authenticated.isEmpty, "A destination folder that exists needs no extra authentication")

// All users' folder, missing, under a folder the user cannot write.
let systemRoot = root.appendingPathComponent("system")
let systemPlugins = (systemRoot as NSString).appendingPathComponent("Library/Application Support/IsiX/Plugins")
let systemPlugin = (systemPlugins as NSString).appendingPathComponent("QA.horosplugin")
try! fm.createDirectory(atPath: systemRoot, withIntermediateDirectories: true, attributes: nil)
try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: systemRoot)
unlockForMkdir = systemRoot
denyMove = false
PluginManager.movePlugin(fromPath: active, toPath: systemPlugin)
try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemRoot)
check(authenticated == [["/bin/mkdir", "/bin/mv"]], "One authentication must cover making the folder and the move")
check(commands.suffix(2) == ["/bin/mkdir", "/bin/mv"], "The folder must be made before the move")
check(!fm.fileExists(atPath: active) && fm.fileExists(atPath: systemPlugin) && alerts == 1, "The plugin must arrive in the folder made for it, without an error")
check(fm.contents(atPath: (systemPlugin as NSString).appendingPathComponent("payload")) == bytes, "Move must preserve bytes")
print("PASS: writable moves need no authorization; a refused one is reported without copying; a missing locked folder is made under one authentication; bytes preserved")
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

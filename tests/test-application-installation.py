#!/usr/bin/env python3
"""Exercise host installation with disposable bundles and injected UI/Dock/launch/auth.

No production application, Dock preference, administrator dialog or disk image
is modified. The synchronous Trash case owns and removes exactly one receipt.
"""
from pathlib import Path
import argparse
import os
import plistlib
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--trash-only', action='store_true')
args = parser.parse_args()

DRIVER = r'''
import AppKit

@MainActor final class Operations: HorosInstallOperations {
    var events = [String]()
    var decision = HorosInstallDecision.install
    var running = false
    var runsAfterCopy = false
    var failure = ""
    var cancelled = false
    var dock = true
    var recycle = true
    func event(_ name: String) throws {
        events.append(name)
        if failure == name { throw HorosInstallError.operation("failure " + name) }
        if cancelled && name == "stage" { throw HorosInstallError.cancelled }
    }
    func consent(_ context: HorosInstallContext) -> HorosInstallDecision { events.append("consent"); return decision }
    func isRunning(_ destination: URL) -> Bool { events.append("running"); return running || (runsAfterCopy && events.contains("validate")) }
    func activate(_ destination: URL) throws { try event("activate") }
    func stage(_ context: HorosInstallContext, at staging: URL) throws { try event("stage") }
    func validate(_ context: HorosInstallContext, at staging: URL) throws { try event("validate") }
    func commit(_ context: HorosInstallContext, staging: URL) throws { try event("commit") }
    func discard(_ staging: URL) { events.append("discard") }
    func relaunch(_ destination: URL, diskImage: String?) throws { try event("relaunch") }
    func addToDock(_ destination: URL) -> Bool { events.append("dock"); return dock }
    func trash(_ source: URL) -> Bool { events.append("trash"); return recycle }
}

@main struct Driver {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let native = HorosNativeInstallOperations()
        func check(_ condition: Bool) { precondition(condition) }
        if CommandLine.arguments.contains("--detect-dmg") {
            guard let device = HorosNativeInstallOperations.containingDiskImage(root) else {
                preconditionFailure("mounted disposable DMG was not detected")
            }
            print(device)
            return
        }
        if CommandLine.arguments.contains("--trash-only") {
            let input = root.appendingPathComponent("horos-disposable-trash-" + UUID().uuidString + ".txt")
            let payload = Data("synthetic disposable trash contract".utf8)
            try payload.write(to: input)
            let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                appropriateFor: input, create: false)
            let receipt = trash.appendingPathComponent(input.lastPathComponent)
            precondition(!FileManager.default.fileExists(atPath: receipt.path))
            precondition(native.trash(input))
            precondition(!FileManager.default.fileExists(atPath: input.path))
            check(try Data(contentsOf: receipt) == payload)
            try FileManager.default.removeItem(at: receipt)
            precondition(!native.trash(input))
            print("PASS: native synchronous Trash, byte-identical unique receipt removed, missing input fails")
            return
        }
        let suite = "org.horosproject.installation-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("Source's & \"quoted\".app")
        let destination = root.appendingPathComponent("Applications/Source's & \"quoted\".app")
        func context(dmg: Bool = false, nested: Bool = false, auth: Bool = false) -> HorosInstallContext {
            HorosInstallContext(source: source, destination: destination, userDirectory: false,
                diskImage: dmg ? "/dev/disposable" : nil, nested: nested, authorization: auth)
        }
        func run(_ ops: Operations, _ ctx: HorosInstallContext? = nil) -> HorosInstallResult {
            HorosApplicationInstaller.run(ctx ?? context(), defaults: defaults, operations: ops)
        }
        let decline = Operations(); decline.decision = .decline(suppress: false)
        precondition(run(decline) == .declined && decline.events == ["consent"])
        let suppress = Operations(); suppress.decision = .decline(suppress: true)
        precondition(run(suppress) == .declined)
        precondition(UserDefaults(suiteName: suite)!.bool(forKey: HorosApplicationInstaller.suppressKey))
        let skipped = Operations()
        precondition(run(skipped) == .skipped && skipped.events.isEmpty)
        defaults.set(false, forKey: HorosApplicationInstaller.suppressKey)
        for auth in [false, true] {
            let existing = Operations(); existing.running = true
            precondition(run(existing, context(auth: auth)) == .activatedExisting)
            precondition(existing.events == ["consent", "running", "activate", "discard"])
        }
        let late = Operations(); late.runsAfterCopy = true
        precondition(run(late) == .activatedExisting && !late.events.contains("commit") && !late.events.contains("dock"))
        let cancel = Operations(); cancel.cancelled = true
        precondition(run(cancel, context(auth: true)) == .authorizationCancelled && !cancel.events.contains("commit"))
        for stage in ["stage", "validate", "commit", "relaunch", "activate"] {
            let failing = Operations(); failing.failure = stage; failing.running = stage == "activate"
            if case .failed = run(failing) {} else { preconditionFailure("failure not reported " + stage) }
            precondition(!failing.events.contains("dock") && !failing.events.contains("trash"))
        }
        let success = Operations()
        precondition(run(success) == .installed(dockAdded: true, originalRetained: false))
        precondition(success.events == ["consent", "running", "stage", "validate", "running", "commit", "relaunch", "dock", "trash", "discard"])
        for ctx in [context(dmg: true), context(nested: true)] {
            let preserved = Operations()
            precondition(run(preserved, ctx) == .installed(dockAdded: true, originalRetained: true))
            precondition(!preserved.events.contains("trash"))
        }
        let dockFailure = Operations(); dockFailure.dock = false
        precondition(run(dockFailure) == .installed(dockAdded: false, originalRetained: false))
        let trashFailure = Operations(); trashFailure.recycle = false
        precondition(run(trashFailure) == .installed(dockAdded: true, originalRetained: true))
        print("PASS: consent/opt-out, both auth paths, running/racing destination, cancellation, copy/validation/Trash/relaunch/Dock failures, DMG/nested retention")

        let manager = FileManager.default
        let user = root.appendingPathComponent("User Applications")
        let local = root.appendingPathComponent("Applications")
        try manager.createDirectory(at: user, withIntermediateDirectories: true)
        precondition(HorosApplicationInstaller.preferredDirectory(user: user, local: local) == local)
        try manager.createDirectory(at: user.appendingPathComponent("Existing.app"), withIntermediateDirectories: true)
        precondition(HorosApplicationInstaller.preferredDirectory(user: user, local: local) == user)
        precondition(HorosApplicationInstaller.isInstalled(destination, directories: [local]))
        precondition(!HorosApplicationInstaller.isInstalled(root.appendingPathComponent("ApplicationsFake/Viewer.app"), directories: [local]))
        print("PASS: local/user Applications selection and component-safe installed detection")

        let staging = root.appendingPathComponent("Applications/Staging.app")
        try native.stage(context(), at: staging)
        try native.validate(context(), at: staging)
        check(try HorosNativeInstallOperations.quarantine(source) == HorosNativeInstallOperations.quarantine(staging))
        // Copy failure and invalid signature never reach replacement.
        do { try native.stage(context(), at: staging); preconditionFailure("copy replaced existing staging") } catch {}
        let executable = staging.appendingPathComponent("Contents/MacOS/fixture")
        let original = try Data(contentsOf: executable)
        try Data("tampered".utf8).write(to: executable)
        do { try native.validate(context(), at: staging); preconditionFailure("invalid signature accepted") } catch {}
        try original.write(to: executable)
        try native.validate(context(), at: staging)
        try native.commit(context(), staging: staging)
        precondition(!manager.fileExists(atPath: staging.path))
        check(try Data(contentsOf: destination.appendingPathComponent("Contents/MacOS/fixture")) == original)
        precondition(manager.fileExists(atPath: source.path))
        // Symlink destinations cannot affect the file outside the scenario.
        try manager.removeItem(at: destination)
        try manager.createSymbolicLink(at: destination, withDestinationURL: source)
        do { try native.stage(context(), at: staging); preconditionFailure("destination symlink followed") } catch {}
        precondition(manager.fileExists(atPath: source.path))
        print("PASS: actual signed bundle copy/validation/commit, quarantine and executable bytes, existing-stage failure, tampered signature, symlink rejection")

        let tile = PFApplicationDockTile(source.path) as! [String: Any]
        let bytes = try PropertyListSerialization.data(fromPropertyList: tile, format: .xml, options: 0)
        let decoded = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        precondition(PFApplicationDockContains([decoded], source.path))
        precondition(!PFApplicationDockContains([decoded], source.path + "/Other"))
        precondition(!PFApplicationDockContains([["tile-data": "invalid"]], source.path))
        print("PASS: pure Dock tile serialization for spaces, apostrophe, quotes and ampersand; exact URL match; no Dock write")
        try HorosNativeInstallOperations.authorizedCopyScript(source: source,
            staging: root.appendingPathComponent("Authorized stage's.app"))
            .write(to: root.appendingPathComponent("authorized-copy.txt"), atomically: true, encoding: .utf8)
        try HorosNativeInstallOperations.authorizedCommitScript(
            destination: root.appendingPathComponent("Authorized destination.app"),
            staging: root.appendingPathComponent("Authorized stage's.app"),
            backup: root.appendingPathComponent("Authorized backup.app"))
            .write(to: root.appendingPathComponent("authorized-commit.txt"), atomically: true, encoding: .utf8)
        try HorosNativeInstallOperations.shellQuote(source.path).write(to: root.appendingPathComponent("quoted.txt"), atomically: true, encoding: .utf8)
        try HorosNativeInstallOperations.relaunchScript(source, pid: 2147483646, diskImage: "/dev/synthetic's disk")
            .write(to: root.appendingPathComponent("relaunch.txt"), atomically: true, encoding: .utf8)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-installation-') as folder:
    folder = Path(folder)
    bridge = folder / 'Bridge.h'
    bridge.write_text('''#import "HorosBoundedTask.h"
BOOL PFAddInstalledApplicationToDock(NSString *path);
NSDictionary *PFApplicationDockTile(NSString *path);
BOOL PFApplicationDockContains(NSArray *apps, NSString *path);
''')
    stub = folder / 'stub.m'
    stub.write_text('#import <Foundation/Foundation.h>\nBOOL PFAddInstalledApplicationToDock(NSString *path) { abort(); }\n')
    driver = folder / 'Driver.swift'
    driver.write_text(DRIVER)
    native = ROOT / 'Horos/Sources/HorosApplicationInstaller.swift'
    objects = []
    for index, source in enumerate([stub, ROOT / 'LetsMoveAndDock/NSApplication-Dock.m']):
        obj = folder / f'{index}.o'
        subprocess.run(['xcrun', 'clang', '-c', '-include', 'AppKit/AppKit.h', '-I', str(ROOT / 'Horos/Sources'),
                        str(source), '-o', str(obj)], check=True)
        objects.append(str(obj))
    binary = folder / 'driver'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-import-objc-header', str(bridge),
                    '-I', str(ROOT / 'Horos/Sources'), str(native), str(driver), *objects,
                    '-emit-objc-header-path', str(folder / 'Horos-Swift.h'), '-module-name', 'Horos',
                    '-framework', 'AppKit', '-framework', 'Security', '-o', str(binary)], check=True)
    subprocess.run(['xcrun', 'clang', '-fsyntax-only', '-include', 'AppKit/AppKit.h',
                    '-I', str(folder), '-I', str(ROOT / 'Horos/Sources'),
                    str(ROOT / 'LetsMoveAndDock/PFMoveApplication.m')], check=True)
    if args.trash_only:
        subprocess.run([str(binary), str(folder), '--trash-only'], check=True, timeout=20)
    else:
        app = folder / 'Source\'s & "quoted".app'
        macos = app / 'Contents/MacOS'
        macos.mkdir(parents=True)
        (folder / 'Applications').mkdir()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.horosproject.disposable.installation',
            'CFBundleExecutable': 'fixture', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}))
        c = folder / 'fixture.c'; c.write_text('int main(void) { return 0; }\n')
        subprocess.run(['xcrun', 'clang', str(c), '-o', str(macos / 'fixture')], check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', '0081;00000000;SyntheticTest;', str(app)], check=True)
        subprocess.run([str(binary), str(folder)], check=True, timeout=30)
        # Run the exact privileged copy/commit commands without elevating them,
        # entirely inside this temporary directory; also exercise rollback.
        subprocess.run(['/bin/sh', '-c', (folder / 'authorized-copy.txt').read_text()], check=True)
        authorized_stage = folder / "Authorized stage's.app"
        assert subprocess.check_output(['/usr/bin/xattr', '-px', 'com.apple.quarantine', str(authorized_stage)]) == subprocess.check_output(['/usr/bin/xattr', '-px', 'com.apple.quarantine', str(app)])
        authorized_dst = folder / 'Authorized destination.app'
        authorized_backup = folder / 'Authorized backup.app'
        authorized_dst.mkdir(); (authorized_dst / 'old').write_text('old application')
        commit = (folder / 'authorized-commit.txt').read_text()
        subprocess.run(['/bin/sh', '-c', commit], check=True)
        assert (authorized_backup / 'old').read_text() == 'old application'
        assert not authorized_stage.exists() and (authorized_dst / 'Contents/Info.plist').exists()
        import shutil
        shutil.rmtree(authorized_backup)
        # Missing stage: the previous bundle is restored by the failure branch.
        failed = subprocess.run(['/bin/sh', '-c', commit])
        assert failed.returncode != 0
        assert (authorized_dst / 'Contents/Info.plist').exists() and not authorized_backup.exists()
        print('PASS: exact authorized copy/commit scripts on disposable paths without elevation; quarantine, backup and failure rollback')
        # A real read-only disposable image exercises the production statfs +
        # bounded hdiutil detection. Only this test's device is detached.
        image_input = folder / 'dmg-input'; image_input.mkdir()
        shutil.copytree(app, image_input / app.name)
        image = folder / 'disposable.dmg'
        volume = 'HorosInstallationTest-' + uuid.uuid4().hex
        subprocess.run(['/usr/bin/hdiutil', 'create', '-quiet', '-fs', 'APFS', '-volname', volume,
                        '-srcfolder', str(image_input), str(image)], check=True, timeout=60)
        mount = folder / 'image-mount'; mount.mkdir()
        mounted = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'attach', '-readonly',
            '-nobrowse', '-plist', '-mountpoint', str(mount), str(image)], timeout=30))
        devices = [entry['dev-entry'] for entry in mounted['system-entities'] if 'dev-entry' in entry]
        try:
            detected = subprocess.check_output([str(binary), str(mount / app.name), '--detect-dmg'],
                                               text=True, timeout=15).strip()
            assert detected in devices
        finally:
            subprocess.run(['/usr/bin/hdiutil', 'detach', devices[0]], check=True, timeout=30,
                           stdout=subprocess.DEVNULL)
        print('PASS: actual read-only disposable DMG detected by production statfs/hdiutil; only its device detached')
        quoted = (folder / 'quoted.txt').read_text()
        assert subprocess.check_output(['/bin/sh', '-c', 'printf %s ' + quoted]).decode() == str(app)
        # Execute the generated waiter/open/detach script with tools replaced by
        # disposable recording commands; no real launch or detach occurs.
        record = folder / 'record'
        fake_open = folder / 'open'; fake_detach = folder / 'detach'
        for tool in [fake_open, fake_detach]:
            tool.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$INSTALL_RECORD"\n')
            tool.chmod(0o755)
        script = (folder / 'relaunch.txt').read_text().replace('/usr/bin/open', str(fake_open))
        script = script.replace('/usr/bin/hdiutil', str(fake_detach)).replace('/bin/sleep 5', ':')
        subprocess.run(['/bin/sh', '-c', script], env={**os.environ, 'INSTALL_RECORD': str(record)}, check=True, timeout=5)
        assert record.read_text().splitlines() == [str(app), 'detach', "/dev/synthetic's disk"]
        assert 'xattr' not in script
        print('PASS: generated relaunch/DMG detach argument quoting executed with disposable command substitutes; quarantine untouched')

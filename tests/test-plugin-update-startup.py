#!/usr/bin/env python3
"""Exercise the production startup selector and update action under Swift 6.

Catalog results are synthetic; the worker, delay and main-thread delivery are
the shipped implementation. No network, installed plugins or user defaults
are modified.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import private_tmpdir  # noqa: E402, F401


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(marker)


manager = (root / 'Horos/Sources/PluginManager.swift').read_text()
app = (root / 'Horos/Sources/AppController.swift').read_text()
defaults = (root / 'Horos/Sources/DefaultsOsiriX.m').read_text()
registered = re.search(r'setObject:@"([01])" forKey:@"checkForUpdatesPlugins"', defaults)
assert registered, 'plugin update default registration missing'
action = block(manager, '@IBAction @objc(checkForUpdates:)')
worker_marker = '@objc(checkForUpdatesInBackground:)'
worker = block(manager, worker_marker) if worker_marker in manager else ''
startup = block(app, 'if UserDefaults.standard.bool(forKey: "checkForUpdatesPlugins")')
header = (root / 'Horos/Sources/MainActorCallbacks.swift').read_text().split('import Foundation')[0]

program = r'''
import AppKit

final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0
    private var messages = 0
    func scanned() {
        precondition(!Thread.isMainThread, "catalog must run on a worker")
        lock.lock(); defer { lock.unlock() }
        scans += 1
    }
    func displayed() {
        precondition(Thread.isMainThread, "update message must arrive on main")
        lock.lock(); defer { lock.unlock() }
        messages += 1
    }
    var counts: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (scans, messages)
    }
}
let probe = Probe()
enum ObjC {
    static func arg(_ value: Any?) -> CVarArg { value as? String ?? "" }
    static func format(_ text: String, _ value: Any?) -> String {
        String(format: text, arg(value))
    }
}
@objc final class PluginManager: NSObject {
    func checkForHorosPluginsUpdates(_ sender: Any!) -> [Any]! {
        probe.scanned()
        return [["name": "Synthetic", "version": "2.0"]]
    }
    func checkForOsiriXPluginsUpdates(_ sender: Any!) -> [Any]! {
        probe.scanned()
        return []
    }
    @MainActor @objc func displayUpdateMessage(_ value: NSDictionary!) {
        precondition((value["plugins"] as? [Any])?.count == 1)
        probe.displayed()
    }
ACTION
WORKER
}
@MainActor enum State { static let pluginManager: PluginManager? = PluginManager() }
@MainActor func startup(_ settings: UserDefaults) {
STARTUP
}
@MainActor func waitForMessages(_ count: Int) {
    let deadline = Date().addingTimeInterval(20)
    while probe.counts.1 < count && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    precondition(probe.counts.0 == count * 2 && probe.counts.1 == count,
                 "worker must complete and deliver its result")
}
let suite = "org.horos.test.plugin-update." + UUID().uuidString
let settings = UserDefaults(suiteName: suite)!
defer { settings.removePersistentDomain(forName: suite) }
settings.register(defaults: ["checkForUpdatesPlugins": "DEFAULT"])
settings.set(false, forKey: "checkForUpdatesPlugins")
startup(settings)
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
precondition(probe.counts.0 == 0, "disabled startup must not load catalogs")
settings.set(true, forKey: "checkForUpdatesPlugins")
startup(settings)
waitForMessages(1)
let before = Date()
State.pluginManager!.checkForUpdates(nil)
precondition(Date().timeIntervalSince(before) < 1, "manual action must not block main")
waitForMessages(2)
settings.removeObject(forKey: "checkForUpdatesPlugins")
precondition(!settings.bool(forKey: "checkForUpdatesPlugins"), "new installations default off")
settings.set(true, forKey: "checkForUpdatesPlugins")
precondition(UserDefaults(suiteName: suite)!.bool(forKey: "checkForUpdatesPlugins"),
             "an explicit opt-in remains enabled")
print("PASS: disabled default, persisted opt-in, enabled startup worker, responsive manual action and main-thread results")
'''.replace('ACTION', action).replace('WORKER', worker).replace(
    'STARTUP', startup.replace('UserDefaults.standard', 'settings')).replace('DEFAULT', registered[1])

with tempfile.TemporaryDirectory(prefix='horos-plugin-startup-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(header + program)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                    '-default-isolation', 'nonisolated', '-warnings-as-errors',
                    str(work / 'main.swift'), '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True, timeout=45)

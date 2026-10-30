#!/usr/bin/env python3
"""Run the production plugin download delegate against synthetic HTTP/TLS peers.

The shipped post-download installer is run too: it installs a version 1
package at its full path without touching its neighbours, and refuses a former
plugin package (.horosplugin) with an alert before anything installed is
deleted, moved or loaded.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler
import io
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import zipfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
from local_http import ThreadingLocalHTTPServer

payload = io.BytesIO()
with zipfile.ZipFile(payload, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('Synthetic.isixplugin/Contents/marker.txt', 'complete synthetic plugin\n' * 10000)
package = payload.getvalue()
former_payload = io.BytesIO()
with zipfile.ZipFile(former_payload, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('Former.horosplugin/Contents/marker.txt', 'former plugin\n')
former_package = former_payload.getvalue()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        case = self.path.split('?')[0].strip('/')
        if case == 'slow': time.sleep(1)
        body = package[:len(package)//2] if case == 'badzip' else b'' if case == 'empty' else package
        self.send_response(503 if case == 'http' else 206 if case == 'partial' else 200)
        self.send_header('Content-Length', str(len(body) + 100 if case == 'truncated' else len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass
        self.close_connection = True

source = (root / 'Horos/Sources/PluginManagerController.swift').read_text()
assert 'NSURLDownload' not in source
assert 'thread.supportsCancel = true' in source
close = source.split('public func windowWillClose(', 1)[1].split('@IBAction public override func showWindow', 1)[0]
assert close.index('downloads.removeAll()') < close.index('download.cancel()')
finish = source.split('private func finishDownload(', 1)[1].split('// MARK: install / uinstall', 1)[0]
assert finish.index('$0[path] === download') < finish.index('installDownloadedPlugin(atPath: path)')
assert finish.index('download.terminalError') < finish.index('installDownloadedPlugin(atPath: path)')

def swift_method(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    index = brace + 1
    while depth:
        if source[index] == '{': depth += 1
        elif source[index] == '}': depth -= 1
        index += 1
    return source[start:index]

# The class alone: the file goes on past it, to an #endif.
helper = '\n'.join(swift_method(marker) for marker in (
    'private final class PluginPackageDownload:', 'private final class PluginDownloadActivity:'))
controller_methods = '\n'.join(swift_method(marker) for marker in (
    '@objc(fakeThread:)', 'private func downloadPlugin(', 'private func statusControls(',
    'private func finishDownload(', '@objc(windowWillClose:)'))
controller_methods = controller_methods.replace('private func downloadPlugin(', 'func downloadPlugin(')
controller = r'''@MainActor final class FixtureController: NSObject {
    var window: NSWindow? = nil
    var downloadStatusTextField: NSTextField? = nil
    var downloadStatusProgressIndicator: NSProgressIndicator? = nil
    private nonisolated let downloadingPlugins = Mutex<[String: PluginPackageDownload]>([:])
    var pendingCount: Int { downloadingPlugins.withLock { $0.count } }
    var installations = 0
    var installedData: Data? = nil
    var installedPath: String? = nil
    func refreshPluginList() {}
    static func formatted(_ value: Any?) -> String { String(describing: value) }
    func installDownloadedPlugin(atPath path: String) {
        installations += 1
        installedPath = path
        installedData = try? Data(contentsOf: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }
    METHODS
}
extension FileManager {
    func tmpDirPath() -> String { CommandLine.arguments[2] }
}
extension Thread {
    var progress: CGFloat { get { 0 } set {} }
    var status: String? { get { nil } set {} }
    var supportsCancel: Bool { get { true } set {} }
}
@MainActor final class ThreadsManager {
    static let instance = ThreadsManager()
    static func `default`() -> ThreadsManager { instance }
    var threads: [Thread] = []
    var startImmediately = true
    func addThreadAndStart(_ thread: Thread) {
        threads.append(thread)
        if startImmediately { thread.start() }
    }
}
@MainActor enum HorosAlertPanel {
    @discardableResult static func runCritical(title: String, message: String, defaultButton: String, alternateButton: String?, otherButton: String?) -> Int { 1 }
}
enum HorosObjCException {
    static func perform(_ body: () -> Void) throws { body() }
}
let HorosObjCExceptionKey = "exception"
extension Notification.Name {
    static let AppPluginDownloadInstallDidFinish = Notification.Name("fixture-finished")
}
'''.replace('METHODS', controller_methods)

driver = r'''
import Foundation
import AppKit
import Synchronization
HELPER
CONTROLLER
struct Outcome {
    var completions = 0
    var error: Error?
    var progressCalls = 0
}
let base = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let expected = try Data(contentsOf: root.appendingPathComponent("expected.zip"))
for name in ["valid", "http", "partial", "truncated", "badzip", "empty", "tls", "cancel", "close"] {
    let result = Mutex(Outcome())
    let target = root.appendingPathComponent(name + ".isixplugin.zip")
    let address = name == "tls" ? CommandLine.arguments[3] + "/valid" : base + "/" + (["cancel", "close"].contains(name) ? "slow" : name) + "?token=synthetic"
    let download = PluginPackageDownload(url: URL(string: address)!, destination: target,
        progress: { _, _, _ in result.withLock { $0.progressCalls += 1 } },
        completion: { _, error in result.withLock { $0.completions += 1; $0.error = error } })
    download.start()
    if ["cancel", "close"].contains(name) { download.cancel(); download.cancel() }
    let deadline = Date(timeIntervalSinceNow: 10)
    while result.withLock({ $0.completions }) == 0 && Date() < deadline { _ = download.waitForProgress() }
    let outcome = result.withLock { $0 }
    precondition(outcome.completions == 1, "missing or duplicated terminal callback: \(name)")
    precondition(download.waitForProgress().finished, "activity stuck: \(name)")
    if name == "valid" {
        precondition(outcome.error == nil)
        precondition(try Data(contentsOf: target) == expected, "package bytes changed")
        precondition(outcome.progressCalls > 0, "no progress")
        // Success already delivered but installation still queued when the
        // window closes: revoke the staged package and expose cancellation.
        download.cancel()
        precondition((download.terminalError as NSError?)?.code == NSURLErrorCancelled)
    } else {
        precondition(outcome.error != nil, "accepted invalid transfer: \(name)")
        if ["cancel", "close"].contains(name) {
            precondition((outcome.error as NSError?)?.code == NSURLErrorCancelled)
        }
    }
    precondition(!FileManager.default.fileExists(atPath: target.path), "partial/stale package survives: \(name)")
    Thread.sleep(forTimeInterval: 0.15)
    precondition(result.withLock { $0.completions } == 1, "late duplicated callback")
    print("PASS: \(name)")
}
func drain(until predicate: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !predicate() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    precondition(predicate(), "controller completion stuck")
}
let controller = FixtureController()
controller.downloadPlugin(from: base + "/valid?name=unchanged")
controller.downloadPlugin(from: base + "/valid?name=duplicate")
precondition(controller.pendingCount == 1, "duplicate filename downloaded twice")
drain { controller.pendingCount == 0 }
precondition(controller.installations == 1 && controller.installedData == expected)
for name in ["http", "partial", "badzip", "truncated"] {
    controller.downloadPlugin(from: base + "/" + name)
    drain { controller.pendingCount == 0 }
    precondition(controller.installations == 1, "failed transfer installed")
}
ThreadsManager.instance.startImmediately = false
controller.downloadPlugin(from: base + "/slow")
precondition(!ThreadsManager.instance.threads.last!.isExecuting, "activity started before cancellation case")
ThreadsManager.instance.threads.last!.cancel()
drain { controller.pendingCount == 0 }
precondition(controller.installations == 1, "pre-start activity cancellation installed")
ThreadsManager.instance.startImmediately = true
controller.downloadPlugin(from: base + "/slow")
ThreadsManager.instance.threads.last!.cancel()
drain { controller.pendingCount == 0 }
precondition(controller.installations == 1, "activity cancellation installed")
controller.downloadPlugin(from: base + "/encoded%20plugin.isixplugin.zip?token=synthetic#fragment")
drain { controller.pendingCount == 0 }
precondition(controller.installations == 2)
precondition(controller.installedPath == root.appendingPathComponent("encoded plugin.isixplugin.zip").path, "query/fragment leaked into package filename")
controller.downloadPlugin(from: base + "/slow")
controller.windowWillClose(Notification(name: Notification.Name("close")))
precondition(controller.pendingCount == 0)
let closingDeadline = Date(timeIntervalSinceNow: 1.3)
while Date() < closingDeadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
precondition(controller.installations == 2, "closed window installed a late package")
print("PASS: production controller deduplication, validated install handoff and window close")
'''.replace('HELPER', helper).replace('CONTROLLER', controller).replace('precondition(try Data(contentsOf: target) == expected, "package bytes changed")', 'let actual = try Data(contentsOf: target)\n        precondition(actual == expected, "package bytes changed")')

# Exercise the shipped post-download installer as well as the transfer handoff.
# The manager adapter implements its full-destination filesystem contract: this
# reproduces the destructive parent-directory move if the controller regresses.
installation_method = swift_method('@objc(installDownloadedPluginAtPath:)').replace('NSTextField?', 'FixtureStatusField?').replace('NSProgressIndicator?', 'FixtureProgressIndicator?')
installation_driver = r'''
import Foundation
var alerts = 0
enum HorosAlertPanel {
    @discardableResult static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
// The refusal is IsiXPluginLoading's, tested apart; here only its verdict by extension.
enum PluginManager {
    static func pluginInstallRefusal(atPath path: String?) -> String? {
        (path as NSString?)?.pathExtension == "isixplugin" ? nil : "This plugin was made for Horos or OsiriX."
    }
}
@MainActor final class FixtureStatusField { var stringValue = ""; var isHidden = false }
@MainActor final class FixtureProgressIndicator {
    var isHidden = false
    func startAnimation(_ sender: Any?) {}
    func stopAnimation(_ sender: Any?) {}
}
@MainActor final class FixtureManager {
    var directory = ""
    var previousDirectory: String? = nil
    var failMove = false
    var loaded: [String] = []
    func deletePlugin(withName name: String?) -> String? {
        guard let previousDirectory, let name else { return nil }
        try? FileManager.default.removeItem(atPath: (previousDirectory as NSString).appendingPathComponent(name))
        return previousDirectory
    }
    func userActivePluginsDirectoryPath() -> String? { directory }
    func movePlugin(fromPath source: String?, toPath destination: String?) {
        guard !failMove, let source, let destination else { return }
        if FileManager.default.fileExists(atPath: destination) {
            try? FileManager.default.removeItem(atPath: destination)
        }
        try? FileManager.default.moveItem(atPath: source, toPath: destination)
    }
    func loadPlugin(atPath path: String?) { if let path { loaded.append(path) } }
}
@MainActor final class FixtureInstaller {
    let pluginManager = FixtureManager()
    var downloadStatusTextField: FixtureStatusField? = FixtureStatusField()
    var downloadStatusProgressIndicator: FixtureProgressIndicator? = FixtureProgressIndicator()
    var refreshes = 0
    func refreshPluginList() { refreshes += 1 }
    func isZippedFile(atPath path: String) -> Bool { (path as NSString).pathExtension == "zip" }
    func unZipFile(atPath path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-oq", path, "-d", (path as NSString).deletingLastPathComponent]
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }
METHOD
}
MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let original = root.appendingPathComponent("expected.zip")
    for scenario in ["fresh", "update", "failed-move"] {
        let folder = root.appendingPathComponent("installer-" + scenario)
        let plugins = folder.appendingPathComponent("Plugins")
        let neighbor = plugins.appendingPathComponent("ExistingQA.horosplugin/Contents/keep.txt")
        try! FileManager.default.createDirectory(at: neighbor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("existing unrelated plugin".utf8).write(to: neighbor)
        let zip = folder.appendingPathComponent("Synthetic.isixplugin.zip")
        try! FileManager.default.copyItem(at: original, to: zip)
        let installer = FixtureInstaller()
        installer.pluginManager.directory = plugins.path
        let destination = plugins.appendingPathComponent("Synthetic.isixplugin")
        if scenario == "update" {
            installer.pluginManager.previousDirectory = plugins.path
            try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try! Data("old version".utf8).write(to: destination.appendingPathComponent("old.txt"))
        }
        installer.pluginManager.failMove = scenario == "failed-move"
        installer.installDownloadedPlugin(atPath: zip.path)
        guard let neighborBytes = try? Data(contentsOf: neighbor) else {
            print("FAIL: installer replaced the plugins parent or removed a neighboring bundle")
            exit(1)
        }
        precondition(neighborBytes == Data("existing unrelated plugin".utf8), "installer altered a neighboring bundle")
        if scenario == "failed-move" {
            precondition(installer.pluginManager.loaded.isEmpty, "failed move was loaded")
            precondition(installer.downloadStatusTextField!.stringValue != "Plugin Installed", "failed move reported success")
            precondition(installer.refreshes == 0)
        } else {
            let installedBytes = try! Data(contentsOf: destination.appendingPathComponent("Contents/marker.txt"))
            precondition(installedBytes == Data(String(repeating: "complete synthetic plugin\n", count: 10000).utf8), "installed package is incomplete")
            precondition(installer.pluginManager.loaded == [destination.path], "load path differs from installed bundle")
            precondition(installer.downloadStatusTextField!.stringValue == "Plugin Installed")
            precondition(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Synthetic.isixplugin").path), "move left staged source")
        }
        precondition(installer.downloadStatusProgressIndicator!.isHidden)
    }
    precondition(alerts == 0, "a version 1 package was refused")
    // A former plugin package: refused before the installed one of its name is touched.
    let folder = root.appendingPathComponent("installer-former")
    let plugins = folder.appendingPathComponent("Plugins")
    let installed = plugins.appendingPathComponent("Former.horosplugin/Contents/old.txt")
    try! FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("installed former plugin".utf8).write(to: installed)
    let zip = folder.appendingPathComponent("Former.horosplugin.zip")
    try! FileManager.default.copyItem(at: root.appendingPathComponent("former.zip"), to: zip)
    let installer = FixtureInstaller()
    installer.pluginManager.directory = plugins.path
    installer.pluginManager.previousDirectory = plugins.path
    installer.installDownloadedPlugin(atPath: zip.path)
    precondition(alerts == 1, "a former plugin package was not refused with an alert")
    precondition((try? Data(contentsOf: installed)) == Data("installed former plugin".utf8), "refusing a former plugin package changed the installed one")
    precondition(installer.pluginManager.loaded.isEmpty && installer.refreshes == 0, "a refused package was loaded")
    precondition(installer.downloadStatusProgressIndicator!.isHidden)
    print("PASS: production downloaded installer preserves neighboring plugins, publishes fresh/update bundles at full paths, does not report failed moves as installed, and refuses a former plugin package before touching anything")
}
'''.replace('METHOD', installation_method)

with tempfile.TemporaryDirectory(prefix='horos-plugin-package-') as directory:
    p = Path(directory)
    (p / 'main.swift').write_text(driver)
    (p / 'expected.zip').write_bytes(package)
    (p / 'former.zip').write_bytes(former_package)
    (p / 'installation.swift').write_text(installation_driver)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-default-isolation', 'MainActor', '-warnings-as-errors', str(p/'installation.swift'), '-o', str(p/'installation-test')], check=True)
    subprocess.run([str(p/'installation-test'), str(p)], check=True, timeout=30)
    # Negative control: the former parent-directory destination must fail the
    # neighboring-bundle preservation check, not merely a source spelling check.
    old_method = installation_method.replace('toPath: installedPath)', 'toPath: installDirectoryPath)')
    assert old_method != installation_method
    (p / 'installation-negative.swift').write_text(installation_driver.replace(installation_method, old_method))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-default-isolation', 'MainActor', '-warnings-as-errors', str(p/'installation-negative.swift'), '-o', str(p/'installation-negative')], check=True)
    negative_root = p / 'negative-control'
    negative_root.mkdir()
    (negative_root / 'expected.zip').write_bytes(package)
    (negative_root / 'former.zip').write_bytes(former_package)
    negative = subprocess.run([str(p/'installation-negative'), str(negative_root)], capture_output=True, text=True, timeout=30)
    assert negative.returncode != 0 and 'replaced the plugins parent' in negative.stdout, negative.stdout + negative.stderr
    print('PASS: historical parent-directory destination fails the filesystem preservation control')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', str(p/'main.swift'), '-o', str(p/'test')], check=True)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-keyout', str(p/'key.pem'), '-out', str(p/'cert.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    http = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
    tls = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(p/'cert.pem', p/'key.pem')
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    for server in (http, tls): threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([str(p/'test'), f'http://127.0.0.1:{http.server_port}', str(p), f'https://127.0.0.1:{tls.server_port}'], check=True, timeout=30)
    finally:
        for server in (http, tls): server.shutdown(); server.server_close()
print('PASS: controller close/completion guards and deprecated API inventory')

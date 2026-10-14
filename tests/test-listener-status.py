#!/usr/bin/env python3
"""The Listener preferences say whether the DICOM listener is listening, and why not.

Ticking "Activate DICOM listener" showed nothing either way: a port held by
another application, protected mode, a session that is not the active one or
settings the listener refuses left it stopped with a line in the log or a
notice shown once. And a port whose IPv4 address another application held was
not even a failure: the listener's IPv6 socket bound beside it, and every IPv4
connection went to the other application.

ListenerStatus.swift is compiled as it is and driven as the application drives it:
- the text of each state, with the TLS listener on a second line unless it is
  simply off, and whether a listener that should listen does not;
- a listener that ends after listening is off, one that never started keeps
  its reason;
- a change is announced once on the main thread, a repeated state is not;
- the IPv4 side of a port is taken while a socket of either family holds it,
  listening or only bound, and free before and after.

The wiring is read from the sources: every way out of -[DCMTKQueryRetrieveSCP
run] before its accept loop says why, the IPv4 side is asked before the port
is opened, the loop is entered as "listening" and left as "ended"; the
application marks protected mode, an inactive session, a listener still
stopping, a bind failure (before the notice that is shown once, or hidden) and
an exception; and the pane installs the line.

ListenerStatusLine.swift is compiled too and installed in each of the ten
localized nibs of the pane: the line is there once, inside the listener's box,
over no other control, and follows a change of state.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
failures = []


def source(path):
    return (root / path).read_bytes().decode('latin1')


# -- wiring -------------------------------------------------------------------
listener = source('Horos/Sources/DCMTKQueryRetrieveSCP.mm')
run = listener[listener.index('- (void)run\n'):]
run = run[:run.index('\n-(void)abort')]
loop = run.index('/* loop waiting for associations */')
setup, rest = run[:loop], run[loop:]
lines = setup.split('\n')
for number, line in enumerate(lines):
    if 'return;' not in line:
        continue
    said = '\n'.join(lines[max(0, number - 6):number + 1])
    if 'HorosListenerStatus setNotListening' not in said and 'reportListenBindFailureForService' not in said and 'abandonTLS(' not in said:
        failures.append(f'the listener leaves without saying why: {" ".join(lines[max(0, number - 2):number + 1]).strip()[:90]}')
# The TLS set-up's exits say why through the one clean-up they share.
abandon = setup[setup.find('auto abandonTLS'):]
abandon = abandon[:abandon.find('};')]
if 'setNotListening: [HorosListenerStatus tlsSettingsReason] TLS: YES' not in abandon:
    failures.append('the TLS set-up leaves without saying why: abandonTLS() no longer sets the status')
if setup.count('return;') < 10:
    failures.append('the ways out of the listener were not found')
probe, opened = setup.find('[HorosListenerStatus isIPv4PortTaken: _port]'), setup.find('ASC_initializeNetwork(')
if probe < 0 or opened < 0 or probe > opened:
    failures.append('the IPv4 side of the port must be asked before the port is opened')
if 'errnoCode: EADDRINUSE' not in setup[probe:opened]:
    failures.append('a port whose IPv4 side is taken must be reported as a port in use')
if '[HorosListenerStatus setListeningOnPort: _port TLS: tlsListener]' not in setup[opened:]:
    failures.append('the listener does not say that it listens')
if '[HorosListenerStatus setEndedForTLS: tlsListener]' not in rest:
    failures.append('the listener does not say that it ended')

app = source('Horos/Sources/AppController.swift')


def body(signature, end='\n    }\n'):
    start = app.index(signature)
    return app[start:app.index(end, start)]


restart = body('@objc public func restartSTORESCP() {')
for needle, what in (('markListenersNotStarted(ListenerStatus.protectedModeReason)', 'protected mode'),
                     ('ListenerStatus.setStarting(tls: false)', 'the listener starting'),
                     ('ListenerStatus.setStarting(tls: true)', 'the TLS listener starting'),
                     ('ListenerStatus.setOff(tls: false)', 'the listener switched off'),
                     ('ListenerStatus.setOff(tls: true)', 'the TLS listener switched off'),
                     ('ListenerStatus.setNotListening(reason: ListenerStatus.stillStoppingReason, tls: false)', 'a listener still stopping'),
                     ('markListenersNotStarted(ListenerStatus.internalErrorReason(e?.reason))', 'an exception')):
    if needle not in restart:
        failures.append(f'restartSTORESCP does not say: {what}')
bind = body('nonisolated public func reportListenBindFailure(')
said, hidden = bind.find('ListenerStatus.setNotListening(reason: ListenerStatus.bindFailureReason('), bind.find('if hideDICOM')
if said < 0 or hidden < 0 or said > hidden:
    failures.append('a bind failure must reach the status before the notice that may be hidden or already shown')
if 'controller.markListenersNotStarted(ListenerStatus.inactiveSessionReason)' not in body('private func applyListenerSettings() {'):
    failures.append('settings applied in an inactive session do not say why the listener stays stopped')
resign = body('func switchHandler(')
said, stopped = resign.find('markListenersNotStarted(ListenerStatus.inactiveSessionReason)'), resign.find('self.killDICOMListenerWait(true)')
if said < 0 or stopped < 0 or said > stopped:
    failures.append('a session that resigns must say why before it stops the listener, which ends as off otherwise')
for method, tls in (('startSTORESCP(_', 'false'), ('startSTORESCPTLS(_', 'true')):
    if f'ListenerStatus.setNotListening(reason: ListenerStatus.internalErrorReason(e?.reason), tls: {tls})' not in body(f'nonisolated public func {method}'):
        failures.append(f'{method[:-2]} does not say that it raised')
pane = source('Preference Panes/OSIListenerPreferencePane/OSIListenerPreferencePanePref.swift')
if 'ListenerStatusLine.install(in: view)' not in pane:
    failures.append('the Listener pane does not install the status line')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, ibtool)', file=sys.stderr)
    sys.exit(SKIPPED)

STATUS = r'''
import Foundation
import Darwin

var failed = false
func check(_ condition: Bool, _ what: String) {
    if !condition { FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!); failed = true }
}
func spin() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
typealias Status = ListenerStatus

var announced = 0
let token = NotificationCenter.default.addObserver(forName: Status.didChangeNotification, object: nil, queue: nil) { _ in
    if Thread.isMainThread { announced += 1 } else { announced = -1000 }
}

// Texts.
check(Status.summary == "The listener is off" && Status.hasFailure == false, "at first: \(Status.summary)")
Status.setStarting(tls: false)
check(Status.summary == "Starting the listener...", "starting: \(Status.summary)")
Status.setListening(port: 11112, tls: false)
check(Status.summary == "Listening on port 11112" && Status.hasFailure == false, "listening: \(Status.summary)")
Status.setListening(port: 2762, tls: true)
check(Status.summary == "Listening on port 11112\nTLS: Listening on port 2762", "both: \(Status.summary)")
Status.setNotListening(reason: Status.tlsSettingsReason, tls: true)
check(Status.summary == "Listening on port 11112\nTLS: Not listening: its TLS settings could not be applied" && Status.hasFailure, "TLS failure: \(Status.summary)")
Status.setOff(tls: true)
Status.setNotListening(reason: Status.bindFailureReason(port: 11112, errno: EADDRINUSE), tls: false)
check(Status.summary == "Not listening: port 11112 is in use by another application" && Status.hasFailure, "port in use: \(Status.summary)")
check(Status.bindFailureReason(port: 104, errno: EACCES) == "port 104 could not be opened (Permission denied)", "another errno: \(Status.bindFailureReason(port: 104, errno: EACCES))")
for reason in [Status.protectedModeReason, Status.inactiveSessionReason, Status.missingDictionaryReason, Status.settingsReason, Status.stillStoppingReason, Status.internalErrorReason("x")] {
    Status.setNotListening(reason: reason, tls: false)
    check(Status.summary == "Not listening: " + reason && reason.isEmpty == false && Status.hasFailure, "reason: \(Status.summary)")
}

// A listener that ends.
Status.setListening(port: 11112, tls: false)
Status.setEnded(tls: false)
check(Status.state(tls: false) == .off, "a listener that listened and ended must be off")
Status.setNotListening(reason: Status.protectedModeReason, tls: false)
Status.setEnded(tls: false)
check(Status.state(tls: false) == .notListening(reason: Status.protectedModeReason), "a listener that never started lost its reason")
Status.setStarting(tls: true)
Status.setEnded(tls: true)
check(Status.state(tls: true) == .off, "a TLS listener stopped while starting must be off")

// Announced on the main thread, once per change, from any thread.
Status.setOff(tls: false); spin(); announced = 0
Status.setListening(port: 1, tls: false); spin()
check(announced == 1, "a change announced \(announced) times")
Status.setListening(port: 1, tls: false); spin()
check(announced == 1, "the same state announced again")
let background = Thread { Status.setListening(port: 2, tls: false) }
background.start()
while background.isFinished == false { usleep(1000) }
spin()
check(announced == 2, "a change from a listener thread: \(announced)")
NotificationCenter.default.removeObserver(token)

// The IPv4 side of a port.
func hold(_ family: Int32, _ port: Int, listening: Bool) -> Int32 {
    let descriptor = socket(family, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var result: Int32 = -1
    if family == AF_INET {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(port).bigEndian
        result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    } else {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6); address.sin6_port = in_port_t(port).bigEndian
        result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
    }
    if result != 0 { close(descriptor); return -1 }
    if listening { listen(descriptor, 4) }
    return descriptor
}
// A port nobody holds: one the system has just given and taken back.
var port = 0
do {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
    port = Int(in_port_t(bigEndian: address.sin_port))
    close(descriptor)
}
check(port > 0 && Status.isIPv4PortTaken(port) == false, "a free port (\(port)) read as taken")
for (name, family, listening) in [("an IPv4 listener", AF_INET, true), ("an IPv4 socket only bound", AF_INET, false), ("an IPv6 listener of both families", AF_INET6, true)] {
    let descriptor = hold(family, port, listening: listening)
    check(descriptor >= 0, "\(name) could not be made")
    check(Status.isIPv4PortTaken(port), "\(name) on the port was not seen")
    close(descriptor)
    check(Status.isIPv4PortTaken(port) == false, "the port is still taken after \(name) closed")
}
check(Status.isIPv4PortTaken(0) == false && Status.isIPv4PortTaken(70000) == false, "a number that is no port")

if failed { exit(1) }
print("PASS: the texts of every state, a listener that ends, one announcement per change on the main thread, and the IPv4 side of a port")
'''

LINE = r'''
import AppKit

final class Owner: NSObject {
    @IBOutlet @objc var mainWindow: NSWindow?
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
var failed = false
func check(_ condition: Bool, _ what: String) {
    if !condition { FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!); failed = true }
}
_ = NSApplication.shared
MainActor.assumeIsolated {
    for path in CommandLine.arguments.dropFirst() {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        ListenerStatus.set(.listening(port: 11112), tls: false)
        ListenerStatus.set(.off, tls: true)
        let owner = Owner()
        var objects: NSArray?
        let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
        guard nib.instantiate(withOwner: owner, topLevelObjects: &objects), let view = owner.mainWindow?.contentView else {
            check(false, "\(name): the pane did not load"); continue
        }
        guard let line = ListenerStatusLine.install(in: view), let box = line.superview else {
            check(false, "\(name): the status line was not installed"); continue
        }
        check(ListenerStatusLine.install(in: view) === line && box.subviews.filter { $0.identifier == line.identifier }.count == 1, "\(name): installed twice")
        check(ListenerStatusLine.timeoutField(in: view)?.superview === box, "\(name): not in the listener's box")
        check(box.bounds.contains(line.frame) && line.frame.width >= 150, "\(name): the line leaves its box: \(line.frame) in \(box.bounds)")
        for other in box.subviews where other !== line {
            check(other.frame.intersects(line.frame) == false, "\(name): the line covers a control at \(other.frame)")
        }
        check(line.stringValue == "Listening on port 11112" && line.textColor == NSColor.secondaryLabelColor, "\(name): at first: \(line.stringValue)")
        ListenerStatus.set(.notListening(reason: ListenerStatus.bindFailureReason(port: 11112, errno: EADDRINUSE)), tls: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        check(line.stringValue == "Not listening: port 11112 is in use by another application" && line.textColor == NSColor.systemRed && line.toolTip == line.stringValue,
              "\(name): after a failure: \(line.stringValue)")
        ListenerStatus.set(.off, tls: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        check(line.stringValue == "The listener is off" && line.textColor == NSColor.secondaryLabelColor, "\(name): switched off: \(line.stringValue)")
    }
}
if failed { exit(1) }
print("PASS: the status line is installed once, in its box and over nothing, and follows the listener in \(CommandLine.arguments.count - 1) nibs")
'''

with tempfile.TemporaryDirectory(prefix='horos-listener-status-') as folder:
    folder = Path(folder)
    modules = ['-module-cache-path', str(folder / 'modules')]
    status = str(root / 'Horos/Sources/ListenerStatus.swift')
    (folder / 'status').mkdir()
    (folder / 'status/main.swift').write_text(STATUS)
    subprocess.run(['xcrun', 'swiftc', *modules, status, str(folder / 'status/main.swift'), '-o', str(folder / 'status/check')], check=True)
    ran = subprocess.run([str(folder / 'status/check')], capture_output=True, text=True, timeout=120)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        sys.exit(1)
    print(ran.stdout.strip())

    xibs = {language: root / 'Preference Panes/OSIListenerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')}
    xibs.update({language: root / 'Horos/Resources' / f'{language}.lproj' for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')})
    nibs = []
    for language, location in xibs.items():
        nib = folder / f'{language}.nib'
        built = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(location / 'OSIListenerPreferencePanePref.xib')],
                               capture_output=True, text=True)
        if built.returncode or not nib.exists():
            print(f'FAIL: {language}: the pane does not compile\n{built.stdout[-800:]}{built.stderr[-800:]}')
            sys.exit(1)
        nibs.append(str(nib))
    (folder / 'line').mkdir()
    (folder / 'line/main.swift').write_text(LINE)
    subprocess.run(['xcrun', 'swiftc', *modules, status, str(root / 'Horos/Sources/ListenerStatusLine.swift'),
                    str(folder / 'line/main.swift'), '-o', str(folder / 'line/check')], check=True)
    ran = subprocess.run([str(folder / 'line/check'), *nibs], capture_output=True, text=True, timeout=180)
    wanted = [line for line in ran.stderr.splitlines() if line.startswith('FAIL')]
    if ran.returncode:
        print('\n'.join(wanted) or ran.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
    print(ran.stdout.strip())
print('PASS: every way out of the listener, of its start and of its settings reaches the status')

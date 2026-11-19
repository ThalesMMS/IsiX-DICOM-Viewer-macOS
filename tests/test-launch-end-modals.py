#!/usr/bin/env python3
"""A modal window asked for during the launch waits for its end, on the main run loop.

A link may be what launched the application, and it is handed over as the
launch ends. A modal window opened while the main nib loads keeps that link
waiting for an answer with it. The windows the database window asks for as it
awakes (the warning of a database in a synchronized folder, the assistant that
imports a former database) are given to LaunchEnd, which keeps them until the
launch has ended and then runs them from the main run loop.

Horos/Sources/LaunchEnd.swift is compiled as it is, with the real
MainActorCallbacks.swift, and driven:
- during the launch what is given is kept, not run, once for each name;
- the end of the launch runs nothing before it returns; what was kept runs
  from the main run loop afterwards, in the order it was asked for;
- a window that turns the run loop until it is answered, as a modal does,
  leaves the main queue and the main actor served, and the next one waits for
  its answer;
- after the launch nothing is kept, and the caller goes on by itself.

Over the sources: the two windows go through LaunchEnd before anything modal,
no file keeps an observer of the launch of its own, the launch ends before the
link schemes are looked at, and the former SDK method that adds the dicom:
scheme writes the identifier of the running bundle.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
SOURCES = root / 'Horos/Sources'
failures = []


def swift_block(text, at):
    """From `at` to the brace closing the first block that opens after it."""
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += (text[index] == '{') - (text[index] == '}')
        if depth == 0:
            return text[at:index + 1]
    return ''


# --- the sources ------------------------------------------------------------------
WINDOWS = {
    'ICloudDriveDetector.swift': ('    public class func performStartupICloudDriveTasks(', 'ICloudDriveDetector.performStartupICloudDriveTasks(browser)'),
    'O2HMigrationAssistant.swift': ('    public class func performStartupO2HTasks(', 'O2HMigrationAssistant.showStartupAssistantIfNeeded(browser)'),
}
for name, (declaration, shown) in WINDOWS.items():
    text = (SOURCES / name).read_text(encoding='utf-8')
    at = text.find(declaration)
    body = swift_block(text, at) if at >= 0 else ''
    if not body:
        failures.append('%s: %s is gone' % (name, declaration.strip()))
        continue
    kept = re.search(r'if LaunchEnd\.keeps\("[^"]+", \{ %s \}\) \{\s*return\s*\}' % re.escape(shown), body)
    if not kept:
        failures.append('%s: the window asked for during the launch is not given to LaunchEnd' % name)
        continue
    modal = re.search(r'runModal|HorosAlertPanel|NSAlert\(|presentActiveDatabaseWarning', body)
    if modal and modal.start() < kept.start():
        failures.append('%s: something modal comes before the launch is asked about' % name)
    if 'didFinishLaunchingNotification' in text:
        failures.append('%s: it waits for the launch by itself; LaunchEnd does' % name)

names = re.findall(r'LaunchEnd\.keeps\("([^"]+)"', ''.join(path.read_text(encoding='utf-8') for path in sorted(SOURCES.glob('*.swift'))))
if len(names) != len(set(names)):
    failures.append('two windows wait for the end of the launch under one name: %r' % sorted(names))

lifecycle = (SOURCES / 'ApplicationLifecycle.swift').read_text(encoding='utf-8')
finished = swift_block(lifecycle, lifecycle.find('    func didFinishLaunching() {'))
if finished.count('LaunchEnd.reach()') != 1:
    failures.append('the application does not end the launch once, in didFinishLaunching')
if 'var launchFinished: Bool { LaunchEnd.reached }' not in lifecycle:
    failures.append('the application keeps the end of the launch apart from LaunchEnd')

# The plugins are offered before they load, so that what is copied loads in
# this launch: that offer is not one of the windows that wait.
startup = swift_block(lifecycle, lifecycle.find('    static func initializeProcess() {'))
if not 0 <= startup.find('LegacySupportImportPrompt.offerPluginsIfNeeded()') < startup.find('Once.pluginManager = PluginManager()'):
    failures.append('the plugins of the earlier folders are no longer offered before the plugins load')

mime = swift_block(lifecycle, lifecycle.find('    static func checkForOsirixMimeType() {'))
if not mime:
    failures.append('ApplicationLifecycle.checkForOsirixMimeType is gone')
else:
    if 'Bundle.main.bundleIdentifier' not in mime:
        failures.append('checkForOsirixMimeType does not write the identifier of the running bundle')
    if re.search(r'"LSHandlerRoleAll"\s*:\s*"', mime):
        failures.append('checkForOsirixMimeType writes a fixed bundle identifier')
application = (SOURCES / 'AppController.swift').read_text(encoding='utf-8')
if not re.search(r'@objc func checkForOsirixMimeType\(\) \{\s*ApplicationLifecycle\.checkForOsirixMimeType\(\)\s*\}', application):
    failures.append('-[AppController checkForOsirixMimeType] is gone or no longer asks ApplicationLifecycle')

if shutil.which('xcrun') is None:
    for failure in failures:
        print('FAIL: %s' % failure)
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(1 if failures else SKIPPED)

# --- LaunchEnd, compiled as it is -------------------------------------------------
DRIVER = r"""
import Foundation

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

@MainActor enum Shown {
    static var order: [String] = []
    static var open = 0
}

/// What a modal does on the main thread: it turns the run loop until it is
/// answered, here once the main queue and the main actor have both been served.
@MainActor func modal(_ name: String) {
    Shown.order.append(name)
    emit("\(name).alone", Shown.open == 0 ? "yes" : "no")
    Shown.open += 1
    nonisolated(unsafe) var queueServed = false
    nonisolated(unsafe) var actorServed = false
    DispatchQueue.main.async { queueServed = true }
    Task { @MainActor in actorServed = true }
    let deadline = Date(timeIntervalSinceNow: 2)
    while !(queueServed && actorServed) && Date() < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
    }
    emit("\(name).queue", queueServed ? "served" : "stopped")
    emit("\(name).actor", actorServed ? "served" : "stopped")
    Shown.open -= 1
}

/// Turns the run loop for a while with nothing else to wake it.
@MainActor func turn() {
    nonisolated(unsafe) var over = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { over = true }
    while !over {
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
    }
}

@MainActor func drive() {
    emit("launching", LaunchEnd.reached ? "ended" : "yes")
    emit("first kept", LaunchEnd.keeps("first", { modal("first") }) ? "yes" : "no")
    emit("second kept", LaunchEnd.keeps("second", { modal("second") }) ? "yes" : "no")
    emit("first again kept", LaunchEnd.keeps("first", { modal("first again") }) ? "yes" : "no")
    turn()
    emit("run during the launch", "\(Shown.order.count)")

    LaunchEnd.reach()
    emit("ended", LaunchEnd.reached ? "yes" : "no")
    emit("run before the end returns", "\(Shown.order.count)")
    LaunchEnd.reach()

    let deadline = Date(timeIntervalSinceNow: 10)
    while Shown.order.count < 2 && Date() < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
    }
    turn()
    emit("order", Shown.order.joined(separator: ","))

    emit("kept after the launch", LaunchEnd.keeps("later", { modal("later") }) ? "yes" : "no")
    turn()
    emit("run after the launch", "\(Shown.order.count)")
}

// A turn of the run loop that nothing wakes may outlast its own limit: this does.
let waker = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in }
MainActor.assumeIsolated { drive() }
waker.invalidate()
"""

EXPECTED = {
    'launching': 'yes',
    'first kept': 'yes',
    'second kept': 'yes',
    'first again kept': 'yes',
    'run during the launch': '0',
    'ended': 'yes',
    'run before the end returns': '0',
    'first.alone': 'yes',
    'first.queue': 'served',
    'first.actor': 'served',
    'second.alone': 'yes',
    'second.queue': 'served',
    'second.actor': 'served',
    'order': 'first,second',
    'kept after the launch': 'no',
    'run after the launch': '2',
}

with tempfile.TemporaryDirectory(prefix='launch-end-') as work:
    work = Path(work)
    (work / 'main.swift').write_text(DRIVER, encoding='utf-8')
    binary = work / 'driver'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-o', str(binary),
                            str(SOURCES / 'LaunchEnd.swift'), str(SOURCES / 'MainActorCallbacks.swift'), str(work / 'main.swift')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        print(built.stderr[-4000:], file=sys.stderr)
        failures.append('LaunchEnd.swift does not compile with MainActorCallbacks.swift')
    else:
        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        results = dict(line.split('\t', 1) for line in ran.stdout.splitlines() if '\t' in line)
        if ran.returncode != 0:
            failures.append('the driver ended with %d: %s' % (ran.returncode, ran.stderr[-1000:]))
        for key, value in EXPECTED.items():
            if results.get(key) != value:
                failures.append('%s: %r, expected %r' % (key, results.get(key), value))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: a window asked for during the launch is kept once, runs from the main run loop after the launch has ended, '
      'in order, with the main queue and the main actor served; after the launch the caller shows it; '
      'the dicom: handler written is the running bundle')

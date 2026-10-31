#!/usr/bin/env python3
"""A burst of import notifications reaches the Notification Center once.

Each indexed batch used to post a notification under a new identifier, so one
study made hundreds, which usernoted kept and saved again at every arrival.
-[AppController notificationTitle:description:name:] hands every notification
to UserNotificationDelivery, which groups them with IsiXInstallation's
NotificationBurstPolicy. Compile the production delivery with a short interval
and a recording delivery, then post a burst from the main thread and from a
worker thread. The policy alone is tested in the module's tests.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text, class_text  # noqa: E402
import isix_modules  # noqa: E402
application = class_text('AppController')
delivery_path = root / 'Horos/Sources/UserNotificationDelivery.swift'
delivery = delivery_path.read_text() if delivery_path.is_file() else ''
failures = []


def method(source, signature):
    at = source.find(signature)
    if at < 0:
        failures.append('%s is gone' % signature)
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[at:index + 1]
    return ''


# Any thread posts, through the application controller; the grouping runs on the main actor.
post = method(application, '@objc(notificationTitle:description:name:) nonisolated public func notificationTitle(_ title: String!, description: String!, name: String!)')
if 'userNotifications.post(title: title, description: description, name: name)' not in post:
    failures.append('-notificationTitle:description:name: does not hand the notification to UserNotificationDelivery')
deliver = method(delivery, 'static func deliverToNotificationCenter(')
if 'UUID()' in deliver or 'NSUUID' in deliver:
    failures.append('each notification still gets a new identifier')
if '"org.horosproject.notification." + kind' not in deliver:
    failures.append('the identifier does not come from the kind of notification')
if not re.search(r'if sound \{ notification\.sound = ', deliver):
    failures.append('every notification still makes a sound')
authorization = method(delivery, 'func requestAuthorization()')
launch = method(application, '    func didFinishLaunching() {')  # ApplicationLifecycle.swift
if 'removeAllDeliveredNotifications' not in authorization or 'processGraph.userNotifications.requestAuthorization()' not in launch:
    failures.append('notifications left by earlier versions are not cleared at launch')
# DicomDatabase is Swift: the warning is ImportFeedback.swift.
database = (root / 'Horos/Sources/ImportFeedback.swift').read_text()
at = database.find('NSLocalizedString("Import Paused", comment: "")')
paused = database[at:at + 400] if at >= 0 else ''
if not paused:
    failures.append('the "Import Paused" notification is gone')
if 'name: "newfiles"' in paused:
    failures.append('"Import Paused" shares its identifier with "Incoming Files" and would be replaced')

NATIVE = r"""
import Foundation
import IsiXInstallation
func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}
func check(_ passed: Bool, _ what: String, _ log: [String]) {
    if !passed { FileHandle.standardError.write("\(what): \(log)\n".data(using: .utf8)!); exit(1) }
}
@MainActor final class Log { var lines: [String] = [] }
MainActor.assumeIsolated {
let log = Log()
let app = UserNotificationDelivery(policy: NotificationBurstPolicy(interval: 0.3, quietSound: 1)) { title, body, kind, sound in
    log.lines.append("\(kind)|\(title ?? "(null)")|\(body ?? "(null)")|\(sound ? 1 : 0)|\(Thread.isMainThread ? 1 : 0)")
}
for i in 1...50 {
    app.post(title: "Incoming Files", description: "\(i)", name: "newfiles")
}
app.post(title: "Import Paused", description: "full", name: "importpaused")
DispatchQueue.global().async {
    app.post(title: "Incoming Files", description: "worker", name: "newfiles")
}
spin(0.1)
check(log.lines.count == 2, "a burst delivers once at first, other kinds unaffected", log.lines)
check(log.lines[0] == "newfiles|Incoming Files|1|1|1", "first of a burst, with sound", log.lines)
check(log.lines[1] == "importpaused|Import Paused|full|1|1", "Import Paused is delivered", log.lines)
spin(0.5)
check(log.lines.count == 3, "the rest of the burst is one delivery", log.lines)
check(log.lines[2] == "newfiles|Incoming Files|worker|0|1", "latest text, silent, on the main thread", log.lines)
spin(0.5)
check(log.lines.count == 3, "nothing more is delivered", log.lines)
print("PASS: 51 incoming notifications in a burst became 2 deliveries; Import Paused kept its own")
}
"""

if delivery and not failures:
    with tempfile.TemporaryDirectory(prefix='horos-notifications-') as directory:
        path = Path(directory)
        (path / 'main.swift').write_text(NATIVE)
        flags = isix_modules.module_flags('IsiXInstallation', path / 'modules')
        built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'NotificationCoalescing',
                                str(path / 'main.swift'), str(delivery_path),
                                str(root / 'Horos/Sources/MainActorCallbacks.swift'), *flags,
                                '-o', str(path / 'test')],
                               capture_output=True, text=True)
        if built.returncode:
            failures.append('the notification delivery does not compile: ' + built.stderr[-3000:])
        else:
            run = subprocess.run([str(path / 'test')], capture_output=True, text=True, timeout=30)
            if run.returncode:
                failures.append('coalescing regression: ' + run.stderr[-2000:])
            else:
                print(run.stdout.strip())

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a burst of notifications of one kind is delivered once per interval under one identifier, '
      'with the latest text and a single sound')

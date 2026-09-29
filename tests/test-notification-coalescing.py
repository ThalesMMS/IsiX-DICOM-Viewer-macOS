#!/usr/bin/env python3
"""A burst of import notifications reaches the Notification Center once (#696).

Each indexed batch used to post a notification under a new identifier, so one
study made hundreds, which usernoted kept and saved again at every arrival.
Compile the production -notificationTitle:description:name: with a short
interval and a recording delivery, then post a burst from the main thread and
from a worker thread. AppController is Swift since #830: the method is compiled
with swiftc.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
source = source_text('AppController')
failures = []


def method(signature):
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


post = method('@objc(notificationTitle:description:name:) public func notificationTitle(_ title: String!, description: String!, name: String!)')
deliver = method('@objc(deliverNotificationTitle:description:name:sound:) func deliverNotificationTitle(_ title: String!, description: String!, name: String!, sound: Bool)')
if 'UUID()' in deliver or 'NSUUID' in deliver:
    failures.append('each notification still gets a new identifier')
if '"org.horosproject.notification." + name' not in deliver:
    failures.append('the identifier does not come from the kind of notification')
if not re.search(r'if sound \{ notification\.sound = ', deliver):
    failures.append('every notification still makes a sound')
if 'removeAllDeliveredNotifications' not in source:
    failures.append('notifications left by earlier versions are not cleared at launch')
database = (root / 'Horos/Sources/DicomDatabase.mm').read_bytes().decode('latin1')
paused = database[database.find('NSLocalizedString(@"Import Paused", nil)'):][:400]
if 'name:@"newfiles"' in paused:
    failures.append('"Import Paused" shares its identifier with "Incoming Files" and would be replaced')

NATIVE = r'''
import Foundation
@objc(AppController) final class AppController: NSObject {
    enum State { static var delivered: NSMutableDictionary? = nil, pending: NSMutableDictionary? = nil }
    static let HorosNotificationInterval: TimeInterval = 0.3, HorosNotificationQuietSound: TimeInterval = 1
    var log: [String] = []
POST
    @objc(deliverNotificationTitle:description:name:sound:) func deliverNotificationTitle(_ title: String!, description: String!, name: String!, sound: Bool) {
        log.append("\(name ?? "(null)")|\(title ?? "(null)")|\(description ?? "(null)")|\(sound ? 1 : 0)|\(Thread.isMainThread ? 1 : 0)")
    }
}
func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}
func check(_ passed: Bool, _ what: String, _ log: [String]) {
    if !passed { FileHandle.standardError.write("\(what): \(log)\n".data(using: .utf8)!); exit(1) }
}
let app = AppController()
for i in 1...50 {
    app.notificationTitle("Incoming Files", description: "\(i)", name: "newfiles")
}
app.notificationTitle("Import Paused", description: "full", name: "importpaused")
DispatchQueue.global().async {
    app.notificationTitle("Incoming Files", description: "worker", name: "newfiles")
}
spin(0.1)
check(app.log.count == 2, "a burst delivers once at first, other kinds unaffected", app.log)
check(app.log[0] == "newfiles|Incoming Files|1|1|1", "first of a burst, with sound", app.log)
check(app.log[1] == "importpaused|Import Paused|full|1|1", "Import Paused is delivered", app.log)
spin(0.5)
check(app.log.count == 3, "the rest of the burst is one delivery", app.log)
check(app.log[2] == "newfiles|Incoming Files|worker|0|1", "latest text, silent, on the main thread", app.log)
spin(0.5)
check(app.log.count == 3, "nothing more is delivered", app.log)
print("PASS: 51 incoming notifications in a burst became 2 deliveries; Import Paused kept its own")
'''.replace('POST', post)

if post and deliver:
    with tempfile.TemporaryDirectory(prefix='horos-notifications-') as directory:
        path = Path(directory)
        (path / 'main.swift').write_text(NATIVE)
        built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'NotificationCoalescing',
                                str(path / 'main.swift'), '-o', str(path / 'test')],
                               capture_output=True, text=True)
        if built.returncode:
            failures.append('the notification method does not compile: ' + built.stderr[-3000:])
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

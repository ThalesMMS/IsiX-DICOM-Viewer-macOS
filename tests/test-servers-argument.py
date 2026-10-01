#!/usr/bin/env python3
"""DICOM nodes given as an argument of the launch are not written to the preferences (#855).

`-SERVERS '(…)'` puts a list of nodes in the argument domain, for that launch
only, where it hides the list of the preferences. The list of nodes was
normalised on every read (+serversListSendOnly:queryRetrieveOnly: adds the
`retrieveMode` a node lacks) and written back with -setObject:forKey:, which
writes to the persistent domain: the nodes of the argument replaced those of
the preferences for good, and showed in the next launch without the argument.
The Objective-C of DCMNetServiceDelegate did the same. The migration of the
pilot's DICOMweb nodes and the Send sheet, when its number of threads changes,
wrote the list back the same way.

Now the list is normalised for the launch and not written when it came as an
argument, and the migration and the Send sheet leave it alone; a list of the
preferences is still normalised and written as before.

DICOMNodeService.swift and DICOMwebNode.swift run compiled with xcrun swiftc
in a process of their own, launched with and without `-SERVERS`, against a
defaults domain of this check's own name, removed when it ends; the Send
sheet needs the application around it, so its guard is read from the source.
The real UserDefaults KVO observer reenters the production list during
normalization. Publication stays serialized and the nested read must not
republish. The old nonrecursive lock is a timeout negative control, after
proof that the real observer entered.

`<git revision>` as an optional argument reads the sources of that revision,
the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
UNIQUE = 'org.horos.test.servers-argument'


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


CREDENTIALS = r'''
import Foundation
public typealias DICOMwebCredentialKind = DICOMwebCredentials.Kind
public final class DICOMwebCredentials: NSObject {
    public enum Kind { case basic, apiKey, bearer }
    public static func store(kind: Kind, username: String, secret: String, headerName: String) throws -> String { UUID().uuidString }
    public static func summary(forIdentifier identifier: String) -> String { "Bearer" }
    public static func remove(identifier: String) throws {}
    public static func migrateLegacy(identifier: String) throws {}
}
'''

DRIVER = r'''
import AppKit

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

let domain = ProcessInfo.processInfo.processName
let defaults = UserDefaults.standard
let seed = CommandLine.arguments[1]

func describe(_ list: Any?) -> String {
    guard let list = list as? [Any] else { return "none" }
    return list.map { item -> String in
        let node = item as? [String: Any] ?? [:]
        return "\(node["AETitle"] as? String ?? "?"):\(node["retrieveMode"].map { "\($0)" } ?? "-")"
    }.joined(separator: ",")
}

defaults.removePersistentDomain(forName: domain)
if seed == "stored" {
    // A node of the preferences, as an older version wrote it: no retrieveMode.
    defaults.setPersistentDomain(["SERVERS": [["AETitle": "PREFS855", "Address": "127.0.0.1", "Port": "104",
                                               "Description": "Stored", "QR": true, "Send": true]]], forName: domain)
}

final class ReentrantObserver: NSObject {
    var count = 0
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        count += 1
        precondition(count == 1, "normalization must not recursively republish defaults")
        FileHandle.standardOutput.write(Data("entered-kvo\t1\n".utf8))
        let nested = DICOMNodeService.serversList(sendOnly: false, queryRetrieveOnly: false)
        precondition(describe(nested) == "PREFS855:0")
    }
}
let observer = ReentrantObserver()
if seed == "reentrant" {
    defaults.setPersistentDomain(["SERVERS": [["AETitle": "PREFS855", "Address": "127.0.0.1", "Port": "104",
                                               "Description": "Stored", "QR": true, "Send": true]]], forName: domain)
    defaults.addObserver(observer, forKeyPath: "SERVERS", options: [], context: nil)
}
let listed = DICOMNodeService.serversList(sendOnly: false, queryRetrieveOnly: false)
if seed == "reentrant" {
    defaults.removeObserver(observer, forKeyPath: "SERVERS")
    precondition(observer.count == 1)
    emit("reentered", "1")
}
emit("listed", describe(listed as? [Any]))
emit("migrated", "\(DICOMwebNode.migrateLegacyServers(in: defaults))")
let persistent = defaults.persistentDomain(forName: domain) ?? [:]
emit("stored", describe(persistent["SERVERS"]))
emit("dicomweb", persistent["DICOMWEB_SERVERS"] == nil ? "none" : "written")
defaults.removePersistentDomain(forName: domain)
'''

results = {}
with tempfile.TemporaryDirectory(prefix='horos-servers-argument-') as folder:
    folder = Path(folder)
    (folder / 'DICOMNodeService.swift').write_bytes(read('Horos/Sources/DICOMNodeService.swift'))
    (folder / 'DICOMwebNode.swift').write_bytes(read('Horos/Sources/DICOMwebNode.swift'))
    (folder / 'Credentials.swift').write_text(CREDENTIALS)
    (folder / 'main.swift').write_text(DRIVER)
    executable = folder / UNIQUE
    built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'module-cache'),
                            str(folder / 'DICOMNodeService.swift'), str(folder / 'DICOMwebNode.swift'),
                            str(folder / 'Credentials.swift'), str(folder / 'main.swift'), '-o', str(executable)],
                           capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the node sources do not compile:\n%s' % built.stderr[-3000:])
    else:
        argument = ('({AETitle=ARG855; Address=127.0.0.1; Port=11112; Description=Argument; QR=1; Send=1;},'
                    ' {AETitle=WEB855; Address=127.0.0.1; Port=1; Description=Pilot; retrieveMode=3;'
                    ' DICOMwebURL="https://dicomweb.invalid/dicom-web";})')
        runs = {'argument': ['stored', '-SERVERS', argument], 'preferences': ['stored'],
                'reentrant': ['reentrant']}
        try:
            for name, arguments in runs.items():
                run = subprocess.run([str(executable), *arguments], capture_output=True, text=True, timeout=120)
                if run.returncode != 0:
                    failures.append('%s: the driver failed: %s' % (name, run.stderr[-800:]))
                for line in run.stdout.splitlines():
                    key, _, value = line.partition('\t')
                    results['%s.%s' % (name, key)] = value
            # Only the lock changes in this negative control. A real defaults
            # observer must have entered before the old nonrecursive lock hangs.
            old = (folder / 'DICOMNodeService.swift').read_text().replace('listLock = NSRecursiveLock()', 'listLock = NSLock()')
            (folder / 'DICOMNodeService.swift').write_text(old)
            subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'module-cache'),
                            str(folder / 'DICOMNodeService.swift'), str(folder / 'DICOMwebNode.swift'),
                            str(folder / 'Credentials.swift'), str(folder / 'main.swift'), '-o', str(executable)],
                           check=True, capture_output=True)
            try:
                old_run = subprocess.run([str(executable), 'reentrant'], capture_output=True, text=True, timeout=2)
                failures.append('old nonrecursive lock did not deadlock in the KVO callback: ' + old_run.stderr)
            except subprocess.TimeoutExpired as error:
                output = error.stdout or b''
                if isinstance(output, bytes): output = output.decode()
                if 'entered-kvo' not in output:
                    failures.append('negative timed out without entering the real KVO callback')
                else:
                    print('ok: original nonrecursive lock deadlocks only after real KVO reentry')
        finally:
            # cfprefsd writes a removed domain back as an empty file some
            # seconds later; only this check's domain is named so.
            for _ in range(40):
                time.sleep(0.25)
                (Path.home() / 'Library/Preferences' / (UNIQUE + '.plist')).unlink(missing_ok=True)

if results:
    expected = {
        # Normalised for the launch...
        'argument.listed': 'ARG855:0',
        # ... and the preferences left as they were.
        'argument.stored': 'PREFS855:-',
        'argument.migrated': '0',
        'argument.dicomweb': 'none',
        # A list of the preferences is still normalised and written.
        'preferences.listed': 'PREFS855:0',
        'preferences.stored': 'PREFS855:0',
        'preferences.migrated': '0',
        'reentrant.reentered': '1',
        'reentrant.listed': 'PREFS855:0',
        'reentrant.stored': 'PREFS855:0',
    }
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))

send = read('Horos/Sources/SendController.swift').decode('utf-8')
start = send.find('if keyPath == "values.SendControllerConcurrentThreads"')
if start < 0:
    failures.append('the Send sheet no longer writes the nodes when its threads change; this test needs a new look')
elif 'volatileDomain(forName: UserDefaults.argumentDomain)["SERVERS"] == nil' not in send[start:send.find('{', start)]:
    failures.append('the Send sheet writes a list given as an argument to the preferences when its threads change')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: nodes given as an argument are normalised for the launch and never written to the preferences; '
      'those of the preferences are normalised and written as before')

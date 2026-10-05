#!/usr/bin/env python3
"""The renamed application starts from the preferences of the previous identifier.

macOS keeps preferences per bundle identifier. An installation made as
`org.horosproject.horos` has its database location, nodes and layout there, and
the application now runs as `thalesmms.isis.workstation`: without an import it
starts with nothing, asks where the database goes and creates an empty one beside
the database that is already there.

That previous domain is the one Horos uses, and the Horos database is not this
application's: opening it would upgrade it to a model Horos may then refuse. So
the import leaves out where the database is.

The rule, exercised on the function that decides it and on real preference
domains with disposable names:

  - the released identifier with an empty domain takes the previous domain, without
    the database location keys, the first-use choice, the local sources that are
    not this application's databases and any path inside `Horos Data`; nodes,
    listener and the rest come over as they were;
  - a domain that already has a key is left alone, so nothing set after the
    import is overwritten;
  - a development or test bundle never imports: it must not start from the
    user's settings, which name the user's database;
  - the previous domain is read, never written;
  - an installation whose domain was empty records that it adopts no Horos
    database, and one that had preferences records the one it was using.

And `main` has to ask before `NSApplicationMain`, which is where the first
preference is read.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
source = root / 'Horos/Sources/PreferencesContinuity.swift'
main = (root / 'Horos/Sources/main.m').read_bytes().decode('latin1')
config = (root / 'Horos/Horos.xcconfig').read_text()
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

DRIVER = '''
import Foundation

func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }
func keys(_ domain: [String: Any]?) -> String {
    guard let domain else { return "nil" }
    return domain.keys.sorted().joined(separator: ",")
}

let release = PreferencesContinuity.releaseIdentifier
let previous: [String: Any] = ["DATABASELOCATION": 1, "DATABASELOCATIONURL": "/Volumes/Studies", "AETITLE": "READING1"]

// What a Horos installation keeps, with its database in Documents/Horos Data.
let work = URL(fileURLWithPath: CommandLine.arguments[1])
let documents = work.appendingPathComponent("Documents")
let horosData = documents.appendingPathComponent("Horos Data")
let ownHolder = work.appendingPathComponent("Own")
try! FileManager.default.createDirectory(at: horosData, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: ownHolder.appendingPathComponent("IsiX DICOM Viewer Data"), withIntermediateDirectories: true)
let horos: [String: Any] = [
    "DATABASELOCATION": 1, "DATABASELOCATIONURL": documents.path,
    "DEFAULT_DATABASELOCATION": 1, "DEFAULT_DATABASELOCATIONURL": documents.path,
    "DatabaseLocationChoiceCompleted": true,
    "localDatabasePaths": [["Path": documents.path, "Description": "Documents DB"],
                           ["Path": "/Volumes/Archive", "Description": "Archive DB"],
                           ["Path": ownHolder.path, "Description": "Own DB"]],
    "WebPortalDatabasePath": horosData.appendingPathComponent("WebUsers.sql").path,
    "LASTURL": "file://" + horosData.appendingPathComponent("DATABASE.noindex").path,
    "BurnSupplementaryFolder": "/Users/someone/Burn",
    "AETITLE": "READING1", "AEPORT": 11112,
    "SERVERS": [["AETitle": "PACS", "Address": "10.0.0.1", "Port": 104]],
]
let fromHoros = PreferencesContinuity.preferencesToImport(into: release, current: nil, previous: horos) ?? [:]
emit("horos-keys", keys(fromHoros))
emit("horos-sources", ((fromHoros["localDatabasePaths"] as? [[String: Any]]) ?? []).compactMap { $0["Description"] as? String }.joined(separator: ","))
emit("horos-servers", "\\((fromHoros["SERVERS"] as? [[String: Any]])?.count ?? 0)")

emit("release", release)
emit("previous", PreferencesContinuity.previousIdentifier)
emit("empty", keys(PreferencesContinuity.preferencesToImport(into: release, current: nil, previous: previous)))
emit("empty-dictionary", keys(PreferencesContinuity.preferencesToImport(into: release, current: [:], previous: previous)))
emit("already-set", keys(PreferencesContinuity.preferencesToImport(into: release, current: ["AETITLE": "NEW"], previous: previous)))
emit("development", keys(PreferencesContinuity.preferencesToImport(into: release + ".local-development", current: nil, previous: previous)))
emit("no-identifier", keys(PreferencesContinuity.preferencesToImport(into: nil, current: nil, previous: previous)))
emit("nothing-before", keys(PreferencesContinuity.preferencesToImport(into: release, current: nil, previous: nil)))
emit("nothing-before-dictionary", keys(PreferencesContinuity.preferencesToImport(into: release, current: nil, previous: [:])))

// The same decision against preference domains that exist, under names nothing
// else uses, removed afterwards.
let defaults = UserDefaults.standard
let stamp = UUID().uuidString
let from = "thalesmms.isis.workstation.test-continuity-from-" + stamp
let to = "thalesmms.isis.workstation.test-continuity-to-" + stamp
defaults.setPersistentDomain(previous, forName: from)
let imported = PreferencesContinuity.preferencesToImport(into: release,
                                                         current: defaults.persistentDomain(forName: to),
                                                         previous: defaults.persistentDomain(forName: from))
if let imported { defaults.setPersistentDomain(imported, forName: to) }
emit("domain-copied", keys(defaults.persistentDomain(forName: to)))
emit("domain-source", keys(defaults.persistentDomain(forName: from)))
let again = PreferencesContinuity.preferencesToImport(into: release,
                                                      current: defaults.persistentDomain(forName: to),
                                                      previous: ["AETITLE": "LATER"])
emit("domain-second", keys(again))
defaults.removePersistentDomain(forName: from)
defaults.removePersistentDomain(forName: to)

// The record made at the same time, for a new and for an existing installation.
for (label, existing) in [("record-new", false), ("record-existing", true)] {
    let name = "thalesmms.isis.workstation.test-continuity-record-" + stamp
    let suite = UserDefaults(suiteName: name)!
    suite.set(0, forKey: "DEFAULT_DATABASELOCATION")
    DatabaseLocation.recordHorosDirectoriesInUse(existingInstallation: existing, defaults: suite, documents: documents.path)
    let adopted = DatabaseLocation.adoptedHorosDirectories(suite)
    let resolved = DatabaseLocation.baseDirectory(forPath: documents.path,
                                                  horosDataAdopted: { DatabaseLocation.isAdopted($0, in: adopted) }) ?? "nil"
    emit(label, (resolved as NSString).lastPathComponent)
    suite.removePersistentDomain(forName: name)
}
'''

results = {}
if not source.exists():
    failures.append('nothing carries the preferences of the previous identifier over')
else:
    swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
    if swiftc.returncode != 0:
        failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
    else:
        with tempfile.TemporaryDirectory(prefix='preferences-continuity-') as directory:
            # Top-level statements are only allowed in a file called main.swift.
            (Path(directory) / 'main.swift').write_text(DRIVER)
            binary = Path(directory) / 'continuity'
            built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                    str(source), str(root / 'Horos/Sources/DatabaseLocation.swift'),
                                    str(Path(directory) / 'main.swift')],
                                   capture_output=True, text=True)
            if built.returncode != 0:
                failures.append('the import rule does not compile:\n%s' % built.stderr[-1500:])
            else:
                work = Path(directory) / 'work'
                work.mkdir()
                run = subprocess.run([str(binary), str(work)], capture_output=True, text=True, timeout=120)
                if run.returncode != 0:
                    failures.append('the driver failed: %s' % run.stderr[-800:])
                for line in run.stdout.splitlines():
                    key, _, value = line.partition('\t')
                    results[key] = value

if results:
    whole = 'AETITLE'
    expected = {
        'previous': 'org.horosproject.horos',
        'empty': whole,
        'empty-dictionary': whole,
        'already-set': 'nil',
        'development': 'nil',
        'no-identifier': 'nil',
        'nothing-before': 'nil',
        'nothing-before-dictionary': 'nil',
        'domain-copied': whole,
        'domain-source': 'AETITLE,DATABASELOCATION,DATABASELOCATIONURL',
        'domain-second': 'nil',
        # from Horos: everything but where its database is
        'horos-keys': 'AEPORT,AETITLE,BurnSupplementaryFolder,SERVERS,localDatabasePaths',
        'horos-sources': 'Own DB',
        'horos-servers': '1',
        'record-new': 'IsiX Data',
        'record-existing': 'Horos Data',
    }
    for key, want in expected.items():
        got = results.get(key)
        if got != want:
            failures.append('%s: %r, expected %r' % (key, got, want))

    # The identifier the rule imports into is the one the application is built with.
    prefix = next((line.split('=', 1)[1].strip() for line in config.splitlines()
                   if line.startswith('PRODUCT_BUNDLE_IDENTIFIER_PREFIX')), None)
    if results.get('release') != prefix:
        failures.append('the import is for %r and the application is built as %r'
                        % (results.get('release'), prefix))
    if 'PRODUCT_BUNDLE_IDENTIFIER = "$(PRODUCT_BUNDLE_IDENTIFIER_PREFIX)";' not in project:
        failures.append('the application target no longer takes the prefix as its identifier')

# --- asked before the first preference is read --------------------------------
ask = main.find('HorosImportPreviousPreferences();')
start = main.find('NSApplicationMain(argc, argv)')
if ask < 0 or start < 0 or ask > start:
    failures.append('main does not import the previous preferences before NSApplicationMain')
if 'HorosPreferencesContinuity' not in main or 'importPreviousPreferences' not in main:
    failures.append('main does not reach the import rule')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the released identifier takes the previous preferences once, into an empty domain only, '
      'without where the Horos database is; development bundles never do; the previous domain is left '
      'as it was; an existing installation keeps the Horos database it used, a new one adopts none')

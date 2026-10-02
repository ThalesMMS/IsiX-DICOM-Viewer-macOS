#!/usr/bin/env python3
"""The renamed application starts from the preferences of the previous identifier.

macOS keeps preferences per bundle identifier. An installation made as
`org.horosproject.horos` has its database location, nodes and layout there, and
the application now runs as `thalesmms.isis.workstation`: without an import it
starts with nothing, asks where the database goes and creates an empty one beside
the database that is already there.

The rule, exercised on the function that decides it and on real preference
domains with disposable names:

  - the released identifier with an empty domain takes the previous domain whole;
  - a domain that already has a key is left alone, so nothing set after the
    import is overwritten;
  - a development or test bundle never imports: it must not start from the
    user's settings, which name the user's database;
  - the previous domain is read, never written.

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
                                    str(source), str(Path(directory) / 'main.swift')],
                                   capture_output=True, text=True)
            if built.returncode != 0:
                failures.append('the import rule does not compile:\n%s' % built.stderr[-1500:])
            else:
                run = subprocess.run([str(binary)], capture_output=True, text=True)
                if run.returncode != 0:
                    failures.append('the driver failed: %s' % run.stderr[-800:])
                for line in run.stdout.splitlines():
                    key, _, value = line.partition('\t')
                    results[key] = value

if results:
    whole = 'AETITLE,DATABASELOCATION,DATABASELOCATIONURL'
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
        'domain-source': whole,
        'domain-second': 'nil',
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
print('ok: the released identifier takes the previous preferences once, into an empty domain only; '
      'development bundles never do; the previous domain is left as it was')

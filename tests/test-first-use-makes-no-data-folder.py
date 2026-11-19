#!/usr/bin/env python3
"""First use makes no data folder before it is answered, and a launch given its
database location stores nothing when that location cannot be reached.

At a first launch with no IsiX Data in Documents, the start waited for the
volumes of the database while the class of the application was initialized,
before the question «Choose where to store your database»: it resolved the
location, Documents, through +[DicomDatabase baseDirPathForMode:path:], which
made the folder there. Choosing another folder, or quitting, left an empty
Documents/IsiX Data behind. While first use has still to answer, the location
is now resolved without making anything; the folder chosen is made as its
database opens, once the answer has cleared the pending choice.

When the location to open cannot be reached, +[DicomDatabase
defaultBaseDirPath] and the wait for the volumes fell back to Documents by
writing DATABASELOCATION=0 and DEFAULT_DATABASELOCATION=0 among the user's own
values, also for a launch given its location as an argument: that replaced the
location kept for the launches without arguments. Both now go through one
function of IsiXPreferences (LaunchPreferenceMigrations.
fallBackToDocumentsDatabase, tested in its module with and without arguments),
whose values for a launch given its location are merged into the argument
domain, as the default location given at the launch is.

Checked in the sources, as the launch reaches them only through the
application. Pass --database <DicomDatabase.swift> or --lifecycle
<ApplicationLifecycle.swift> to check an earlier copy as a negative control.
"""
import argparse
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--database', type=Path, default=sources / 'DicomDatabase.swift')
parser.add_argument('--lifecycle', type=Path, default=sources / 'ApplicationLifecycle.swift')
args = parser.parse_args()
failures = []


def body(source, signature):
    if signature not in source:
        return ''
    start = source.index(signature)
    return source[start:source.index('\n    }\n', start)]


def ordered(text, parts):
    at = [text.find(part) for part in parts]
    return -1 not in at and at == sorted(at)


database = args.database.read_text()
lifecycle = args.lifecycle.read_text()

# Nothing is made, or reported, at the location first use offers.
resolve = body(database, 'class func baseDirPath(forMode mode: Int32, path: String!) -> String!')
if resolve.count('confirmDirectory(') != 1 or not ordered(resolve, (
        'if DatabaseFirstUse.hasPendingChoice { return path }',
        'FileManager.default.confirmDirectory(atPath: path)',
        'NSLog("---- database location: %@')):
    failures.append('the location is made, or reported, while a first-use answer is pending')

# The start resolves the location through it, in +initialize, before the question.
initialize = body(lifecycle, 'static func initializeProcess()')
if not ordered(initialize, ('ApplicationPreferencesSetup.register()', 'waitForDatabaseVolumes(preferences:')):
    failures.append('the start no longer waits for the volumes of the database after registering the preferences')
documents = body(lifecycle, 'private static func resolvedDocumentsFolder(')
if 'DicomDatabase.baseDirPath(forMode:' not in documents or 'confirmDirectory' in documents:
    failures.append('the start resolves the documents folder elsewhere than +baseDirPathForMode:path:, or makes it itself')

# The folder chosen is made as its database opens: the answer clears the
# pending choice before the database window opens the default database.
first_use = (sources / 'DatabaseFirstUse.swift').read_text()
choose = body(first_use, 'public static func choosePreparedLocation() -> Bool')
answered = choose[choose.find('chooseLocation(defaults: .standard, documents: documents)'):]
if 'chooseLocation(' not in answered or 'pendingChoice.store(false' not in answered:
    failures.append('first use no longer clears its pending choice once answered')
launch = body(lifecycle, 'func willFinishLaunching()')
if not ordered(launch, ('DatabaseFirstUse.choosePreparedLocation()', 'ApplicationPreferencesSetup.useDefaultDatabaseLocation()',
                        'browser?.completeFirstUseDatabaseSetup()')):
    failures.append('the database chosen at first use is no longer opened right after the answer')
opening = database[database.index('override init?(path p: String!, context c: NSManagedObjectContext!'):]
if 'FileManager.default.confirmDirectory(atPath: basePath)' not in opening[:opening.index('sqlFilePath = DicomDatabase.sqlFilePath(')]:
    failures.append('a database that opens no longer makes its folder')

# The fall back to Documents goes through IsiXPreferences, which stores nothing
# for a launch given its location, and not while first use has still to answer.
fallback = body(database, 'class func defaultBaseDirPath() -> String!')
if not re.search(r'if !DatabaseFirstUse\.hasPendingChoice && \(path == nil \|\| !FileManager\.default\.fileExists\(atPath: path!\)\) \{\s*'
                 r'ApplicationPreferencesSetup\.fallBackToDocumentsDatabase\(\)', fallback):
    failures.append('+defaultBaseDirPath falls back to Documents by itself, or while a first-use answer is pending')
waiting = body(lifecycle, 'private static func waitForDatabaseVolumes(')
if 'ApplicationPreferencesSetup.fallBackToDocumentsDatabase()' not in waiting:
    failures.append('the wait for the volumes falls back to Documents by itself')
for name, text in (('defaultBaseDirPath', fallback), ('waitForDatabaseVolumes', waiting)):
    if re.search(r'\.set\(', text):
        failures.append('%s writes a preference itself' % name)

setup = (sources / 'ApplicationPreferencesSetup.swift').read_text()
if 'giveForThisLaunch(LaunchPreferenceMigrations.fallBackToDocumentsDatabase(in: preferences))' not in body(
        setup, 'nonisolated static func fallBackToDocumentsDatabase()'):
    failures.append('the fall back to Documents does not give a launch given its location the values for that launch only')
migrations = (root / 'Modules/IsiXPreferences/Sources/LaunchPreferenceMigrations.swift').read_text()
rule = body(migrations, 'public static func fallBackToDocumentsDatabase(in store: any PreferenceStore)')
if not re.search(r'guard DatabasePreferences\.location\.isGivenAsLaunchArgument\(in: store\)\s*'
                 r'\|\| DatabasePreferences\.defaultLocation\.isGivenAsLaunchArgument\(in: store\) else \{', rule):
    failures.append('the fall back to Documents no longer leaves a location given at the launch out of the stored values')

# Nobody else writes Documents over the location: the modes are written by
# IsiXPreferences, first use and the panes through the location pairs.
mode = re.compile(r'for:\s*DatabasePreferences\.(?:databaseLocation|defaultDatabaseLocation)\b'
                  r'|forKey:\s*"(?:DEFAULT_)?DATABASELOCATION"')
for path in sorted(sources.rglob('*.swift')):
    text = database if path.name == 'DicomDatabase.swift' else lifecycle if path.name == 'ApplicationLifecycle.swift' else path.read_text(errors='replace')
    for number, line in enumerate(text.split('\n'), 1):
        if '.set(' in line and mode.search(line):
            failures.append('%s:%d writes the kind of database location itself: %s' % (path.name, number, line.strip()))

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    sys.exit(1)
print('PASS: no data folder is made before first use is answered, the one chosen is made as it opens, '
      'and the fall back to Documents stores nothing for a launch given its location')

#!/usr/bin/env python3
"""A database location given at the launch is not stored among the user's own values.

The isolated development application and the drivers of the checks launch with
-DATABASELOCATION/-DATABASELOCATIONURL and their DEFAULT_ pair in the argument
domain. Each copy of the default location into the location opened read the
argument and wrote it into the user's own values, so every such launch replaced
the DATABASELOCATIONURL kept for the launches without arguments.

The copy is one function of IsiXPreferences (LaunchPreferenceMigrations.
copyDefaultDatabaseLocation), tested in its module with the arguments given;
this checks that every place that copies goes through it, and that the location
a launch given the default alone opens is merged into the argument domain,
never stored and never replacing that domain.

Pass --also <file.swift> to check an earlier copy of a source as well, as a
negative control (HEAD's ICloudDriveDetector.swift copied the default location
through a name bound to it).
"""
import argparse
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--also', type=Path, action='append', default=[])
args = parser.parse_args()
failures = []


def text(name):
    return (sources / name).read_text()


def body(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n    }\n', start)]


setup = text('ApplicationPreferencesSetup.swift')
register = body(setup, 'static func register()')
if 'giveForThisLaunch(LaunchPreferenceMigrations.copyDefaultDatabaseLocation(in: preferences))' not in register:
    failures.append('the launch does not copy the default location through LaunchPreferenceMigrations')
use = body(setup, 'static func useDefaultDatabaseLocation()')
if 'giveForThisLaunch(LaunchPreferenceMigrations.copyDefaultDatabaseLocation(in: preferences))' not in use:
    failures.append('the default location chosen at first use is not copied through LaunchPreferenceMigrations')
give = body(setup, 'private static func giveForThisLaunch(')
for needle, what in (('var arguments = preferences.volatileDomain(forName: UserDefaults.argumentDomain)', 'the arguments of the launch are read'),
                     ('arguments.merge(values)', 'and the location opened merged into them'),
                     ('preferences.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)', 'which go back with the arguments of the launch')):
    if needle not in give:
        failures.append('giveForThisLaunch: %s (%r not found)' % (what, needle))
if re.search(r'\bset\((?!.*arguments).*forKey', give) or '.set(' in give.replace('setVolatileDomain', ''):
    failures.append('giveForThisLaunch stores a value')

if 'ApplicationPreferencesSetup.useDefaultDatabaseLocation()' not in text('BrowserController.swift'):
    failures.append('the database window does not copy the default location through ApplicationPreferencesSetup')
if 'LaunchPreferenceMigrations.copyDefaultDatabaseLocation(in: processGraph.preferences)' not in body(text('PreferencesWindowController.swift'), 'func reopenDatabase()'):
    failures.append('reopening the database from the settings does not copy the default location through LaunchPreferenceMigrations')
if 'ApplicationPreferencesSetup.useDefaultDatabaseLocation()' not in text('ApplicationLifecycle.swift'):
    failures.append('first use does not open the default location through ApplicationPreferencesSetup')
if 'LaunchPreferenceMigrations.copyDefaultDatabaseLocation(in: preferences)' not in body(text('ICloudDriveDetector.swift'), 'public func dontSync('):
    failures.append('the database moved out of iCloud Drive is not opened through LaunchPreferenceMigrations')

# No other copy of the default location into the location opened: on one line,
# or through a name bound to the default location and written there after.
DEFAULT = r'(?:DEFAULT_DATABASELOCATION|defaultDatabaseLocation|defaultLocation\b)'
OPENED = r'(?:forKey:\s*"DATABASELOCATION|for:\s*DatabasePreferences\.(?:databaseLocation(?:URL)?|location)\b)'
copy = re.compile(DEFAULT + '.*' + OPENED)
bound = re.compile(r'\b(?:let|var)\s+(\w+)\b[^=\n]*=[^\n]*' + DEFAULT)
write = re.compile(r'\.set\((.*?),\s*' + OPENED)
for path in sorted(sources.rglob('*.swift')) + args.also:
    lines = path.read_text(errors='replace').split('\n')
    names = set()
    for number, line in enumerate(lines, 1):
        names.update(bound.findall(line))
        written = write.search(line)
        if copy.search(line) or (written and names & set(re.findall(r'\b\w+\b', written.group(1)))):
            failures.append('%s:%d copies the default location itself: %s' % (path.name, number, line.strip()))
migrations = (root / 'Modules/IsiXPreferences/Sources/LaunchPreferenceMigrations.swift').read_text()
copying = body(migrations, 'public static func copyDefaultDatabaseLocation(')
for needle in ('guard store.isGivenAsLaunchArgument(source) else {', 'if !store.isGivenAsLaunchArgument(target)'):
    if needle not in copying:
        failures.append('copyDefaultDatabaseLocation no longer leaves a default given at the launch out (%r not found)' % needle)

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    sys.exit(1)
print('PASS: every copy of the default database location goes through LaunchPreferenceMigrations, which stores nothing given at the launch')

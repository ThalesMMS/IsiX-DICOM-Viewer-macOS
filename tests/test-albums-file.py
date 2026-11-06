#!/usr/bin/env python3
"""The albums file is written once, whole and atomically.

Source level, with `<git revision>` as an optional argument for the negative
control (run against 56c91e586, before the fix, it must fail).

-saveAlbumsToPath: of DicomDatabase forwards to CoreDataAlbumStore
(exportAlbumsFile), which writes the file that a database rebuild restores the
albums from and that "Save Albums" exports; the entries are IsiXDatabase's
AlbumsFileEntry, and -loadAlbumsFromPath: reads them back with
importAlbumsFile. It
used to delete and rewrite the file after every album, inside the loop, and an
album with a nil name raised in -[NSMutableDictionary setObject:forKey:]: the
file was left with only the albums before it. Now:

* the list is built first and written once, after the loop, with
  `write(toFile:atomically: true)`, and the file is no longer deleted first;
* a nil name or predicate is left out of the entry instead of raising
  (-loadAlbumsFromPath: reads a missing key as nil), and an album that raises
  anyway is left out alone: each one is built inside its own attempt;
* the entries keep their keys and values, so older versions read the file.

The reader finds an album saved without a name: -loadAlbumsFromPath:
looks each entry up by name among the albums of the database, and a missing
name never matched, so the album was created again on every import. A nil name
now finds an album without one, which the array of names holds as NSNull.

A repeated import is idempotent: with two entries of the same name, or
two without one, the first import created two albums and the next ones put the
studies of both entries in the first. Each album found is now taken out of
those the next entry can find, and several albums of one name are told apart by
kind and studies. The lookup, AlbumCatalog.indexOfAlbum(for:among:), is run
from the IsiXDatabase sources with a replay of the reader's loop, the albums
fetched in either order.

A behavioural probe of the whole reader and writer would need DicomDatabase and
its Core Data stack linked into a test; no existing probe links them, so their
structure is checked here.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_driver

root = Path(__file__).resolve().parents[1]
STORE = 'Horos/Sources/CoreDataAlbumStore.swift'
ENTRY = 'Horos/Sources/DicomDatabase+Albums.swift'
CATALOG = 'Modules/IsiXDatabase/Sources/AlbumCatalog.swift'


def read(path):
    if len(sys.argv) > 1:
        result = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        return result.stdout.decode('utf-8') if result.returncode == 0 else ''
    return (root / path).read_text(encoding='utf-8')


def block(source, start):
    """From `start` to the brace that closes the first brace after it."""
    opening = source.find('{', start)
    if start < 0 or opening < 0:
        return ''
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return ''


store = read(STORE)
catalog = read(CATALOG)
failures = []

save = block(store, store.find('func exportAlbumsFile('))
if not save:
    failures.append('no exportAlbumsFile in %s' % STORE)
else:
    loop_start = save.find('for album in albums {')
    loop = block(save, loop_start)
    if not loop:
        failures.append('exportAlbumsFile has no loop over the albums')
    else:
        after_loop = save[loop_start + len(loop):]
        writes = re.findall(r'Self\.write\(entries, toFile: path\)', save)
        if len(writes) != 1:
            failures.append('exportAlbumsFile writes the file %d times, not once' % len(writes))
        if 'write(' in loop:
            failures.append('exportAlbumsFile still writes the file inside the loop, after every album')
        elif 'Self.write(entries, toFile: path)' not in after_loop:
            failures.append('exportAlbumsFile does not write the file after the loop')
        if 'removeItem(atPath: path)' in save:
            failures.append('exportAlbumsFile still deletes the file before writing it')
        if not re.search(r'HorosObjCException\.caught\(\{[^\n]*entries\.append\(', loop):
            failures.append('an album that raises still stops the others from being saved')
    writer = block(store, store.find('static func write('))
    if 'options: .atomic' not in writer:
        failures.append('the albums file is not written atomically')

# The entry: nil values are left out, and the keys are those older versions read.
entry = block(catalog, catalog.find('public var propertyList: [String: Any]'))
if not entry:
    failures.append('no AlbumsFileEntry.propertyList in %s' % CATALOG)
for key in ('name', 'predicateString'):
    if not re.search(r'if let %s \{ entry\["%s"\] = %s \}' % (key, key, key), entry):
        failures.append('the album %s is not left out when nil' % key)
for needle in ('entry["smartAlbum"] = true', 'entry["studies"] = studies.map'):
    if needle not in entry:
        failures.append('the albums file entry changed: %s' % needle)
for needle in ('("studyInstanceUID", \\.studyInstanceUID), ("patientName", \\.patientName), ("patientID", \\.patientID),',
               '("patientUID", \\.patientUID), ("name", \\.name), ("modality", \\.modality), ("accessionNumber", \\.accessionNumber)',
               '("dateOfBirth", \\.dateOfBirth), ("date", \\.date)'):
    if needle not in catalog:
        failures.append('the keys of a study in the albums file changed: %s' % needle)
reader = read(ENTRY)
for needle in ('studyInstanceUID: read("studyInstanceUID"), patientName: read("name")', 'name: read("studyName")'):
    if needle not in reader:
        failures.append('the entry no longer reads the study as the file names it: %s' % needle)

# The reader takes an entry without a name or predicate ...
load = block(store, store.find('func importAlbumsFile('))
if 'DatabaseAlbumCatalog.indexOfAlbum(for: entry, among: remaining.map(Self.candidate))' not in load:
    failures.append('importAlbumsFile no longer looks each entry up with indexOfAlbum')
# ... takes each album it finds out of the albums still to be found ...
if 'album = remaining.remove(at: index)' not in load:
    failures.append('importAlbumsFile leaves an album it found among those the next entry of the same name can find')
if 'album?.predicateString = entry.predicateString' not in load or \
        'predicateString = entry["predicateString"] as? String' not in catalog:
    failures.append('importAlbumsFile no longer reads a missing predicate as nil')

# ... and finds the album it created for it on an earlier import, one album
# per entry when several have the same name or none. The probe replays the
# reader's loop (look up, create or take out of the candidates, add the
# studies of a non-smart album) with the module's lookup.
PROBE = r"""
import Foundation

final class Album {
    var name: String?
    var smart: Bool
    var uids: Set<String>
    init(_ name: String?, smart: Bool = false, _ uids: [String] = []) { self.name = name; self.smart = smart; self.uids = Set(uids) }
    var candidate: AlbumsFileCandidate { AlbumsFileCandidate(name: name, isSmart: smart, studyInstanceUIDs: uids) }
}
func entry(_ name: String?, smart: Bool = false, _ uids: [String] = []) -> AlbumsFileEntry {
    var plist: [String: Any] = [:]
    if let name { plist["name"] = name }
    if smart { plist["smartAlbum"] = true; plist["predicateString"] = "modality = 'CT'" }
    else { plist["studies"] = uids.map { ["studyInstanceUID": $0] } }
    return AlbumsFileEntry(propertyList: plist)!
}
/// The loop of importAlbumsFile, over the albums of the database in the order given.
func load(_ file: [AlbumsFileEntry], into database: inout [Album], reversed: Bool) {
    var remaining = reversed ? database.reversed() : database
    for entry in file {
        let a: Album
        if let index = AlbumCatalog<Int>.indexOfAlbum(for: entry, among: remaining.map(\.candidate)) {
            a = remaining.remove(at: index)
        } else {
            a = Album(entry.name, smart: entry.isSmart)
            database.append(a)
        }
        if !a.smart {
            for study in entry.studies { if let uid = study.studyInstanceUID { a.uids.insert(uid) } }
        }
    }
}
func state(_ database: [Album]) -> String {
    return database.map { "\($0.name ?? "<none>")\($0.smart ? "*" : "")\($0.uids.sorted())" }.sorted().joined(separator: " ")
}
let cases: [(String, [Album], [AlbumsFileEntry], String)] = [
    ("sameName", [], [entry("X", ["a"]), entry("X", ["b"])], "X[\"a\"] X[\"b\"]"),
    ("noNames", [], [entry(nil, ["a"]), entry(nil, ["b"])], "<none>[\"a\"] <none>[\"b\"]"),
    ("nested", [], [entry("X", ["a"]), entry("X", ["a", "b"])], "X[\"a\", \"b\"] X[\"a\"]"),
    ("smartAndNot", [], [entry("X", smart: true), entry("X", ["a"])], "X*[] X[\"a\"]"),
    ("onePresent", [Album("X", ["c"])], [entry("X", ["a"]), entry("X", ["b"])], "X[\"a\", \"c\"] X[\"b\"]"),
    ("distinct", [Album("Y", ["c"])], [entry("X", ["a"]), entry(nil, ["b"])], "<none>[\"b\"] X[\"a\"] Y[\"c\"]"),
]
for (label, start, file, expected) in cases {
    for reversed in [false, true] {
        var database = start.map { Album($0.name, smart: $0.smart, $0.uids.sorted()) }
        var seen: [String] = []
        for _ in 0..<3 {
            load(file, into: &database, reversed: reversed)
            seen.append(state(database))
            load(file, into: &database, reversed: !reversed)
            seen.append(state(database))
        }
        let ok = Set(seen) == [expected]
        print("\(label)\(reversed ? "-reversed" : "")=\(ok ? "idempotent" : seen.joined(separator: " | "))")
    }
}
let names = [Album("Interesting Cases"), Album(nil), Album("Cases with comments")].map(\.candidate)
print("named=\(AlbumCatalog<Int>.indexOfAlbum(for: entry("Cases with comments"), among: names) ?? -1)")
print("nameless=\(AlbumCatalog<Int>.indexOfAlbum(for: entry(nil), among: names) ?? -1)")
print("absent=\(AlbumCatalog<Int>.indexOfAlbum(for: entry("Absent"), among: names) == nil)")
print("noneWithoutName=\(AlbumCatalog<Int>.indexOfAlbum(for: entry(nil), among: [Album("Interesting Cases").candidate]) == nil)")
print("noCandidates=\(AlbumCatalog<Int>.indexOfAlbum(for: entry(nil), among: []) == nil)")
"""
if len(sys.argv) > 1:
    failures.append('the lookup is run from the working tree only')
else:
    with tempfile.TemporaryDirectory() as tmp:
        try:
            probe = module_driver('IsiXDatabase', PROBE, Path(tmp) / 'probe')
        except subprocess.CalledProcessError as error:
            failures.append('the lookup does not compile with IsiXDatabase:\n' + (error.stderr or '')[-1500:])
        else:
            ran = subprocess.run([str(probe)], capture_output=True, text=True)
            found = dict(line.split('=', 1) for line in ran.stdout.splitlines() if '=' in line)
            expected = {'named': '2', 'nameless': '1', 'absent': 'true', 'noneWithoutName': 'true', 'noCandidates': 'true'}
            for label in ('sameName', 'noNames', 'nested', 'smartAndNot', 'onePresent', 'distinct'):
                expected[label] = expected[label + '-reversed'] = 'idempotent'
            wrong = {k: (found.get(k), v) for k, v in expected.items() if found.get(k) != v}
            if wrong or ran.returncode:
                failures.append('indexOfAlbum and the reader loop give %r (found, expected): an album is not found again,'
                                ' or a repeated import changes the albums' % wrong)

if failures:
    print('FAIL:\n  ' + '\n  '.join(failures))
    sys.exit(1)
print('PASS: the albums file is written once, whole and atomically; a nameless album does not cut it short,'
      ' and is found again, not created again, when the file is read; a repeated import is idempotent')

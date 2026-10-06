#!/usr/bin/env python3
"""The albums file is written once, whole and atomically.

Source level, with `<git revision>` as an optional argument for the negative
control (run against 56c91e586, before the fix, it must fail).

-saveAlbumsToPath: of DicomDatabase (Swift) writes the file that a
database rebuild restores the albums from and that "Save Albums" exports. It
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
kind and studies. The lookup, indexOfAlbum, is compiled on its own and run with
a replay of the reader's loop, the albums fetched in either order.

A behavioural probe of the whole reader and writer would need DicomDatabase and
its Core Data stack linked into a test; no existing probe links them, so their
structure is checked here.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/DicomDatabase+Albums.swift'


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


def method(source, selector):
    return block(source, source.find('@objc(%s)' % selector))


albums = read(PATH)
failures = []

save = method(albums, 'saveAlbumsToPath:')
if not save:
    failures.append('no -saveAlbumsToPath: in %s' % PATH)
else:
    loop_start = save.find('for case let album as NSManagedObject in albumArray')
    loop = block(save, loop_start)
    if not loop:
        failures.append('-saveAlbumsToPath: has no loop over the albums')
    else:
        after_loop = save[loop_start + len(loop):]
        writes = re.findall(r'\.write\(toFile: *path, *atomically: *(\w+)\)', save)
        if len(writes) != 1:
            failures.append('-saveAlbumsToPath: writes the file %d times, not once' % len(writes))
        elif writes != ['true']:
            failures.append('-saveAlbumsToPath: does not write the file atomically')
        if '.write(toFile:' in loop:
            failures.append('-saveAlbumsToPath: still writes the file inside the loop, after every album')
        elif '.write(toFile:' not in after_loop:
            failures.append('-saveAlbumsToPath: does not write the file after the loop')
        if 'removeItem(atPath: path)' in save:
            failures.append('-saveAlbumsToPath: still deletes the file before writing it')
        if not re.search(r'DicomDatabaseObjC\.attempt\(\{[^\n]*albums\.add\(', loop):
            failures.append('an album that raises still stops the others from being saved')

    # The entry: the raising helper is gone, and nil values are left out.
    entry = block(albums, albums.find('private func albumsFileEntry('))
    built = entry or save
    if 'DicomDatabaseObjC.setObject(' in built:
        failures.append('a nil album name or predicate still raises in setObject:forKey:')
    for key in ('name', 'predicateString'):
        if not re.search(r'if let \w+ = album\.value\(forKey: "%s"\) \{\s*entry\.setObject\(\w+, forKey: "%s" as NSString\)'
                         % (key, key), built):
            failures.append('the album %s is not left out when nil' % key)
    # The keys and values of the file are those older versions read.
    for needle in ('entry.setObject(NSNumber(value: true), forKey: "smartAlbum" as NSString)',
                   'entry.setObject(studies, forKey: "studies" as NSString)',
                   '[("studyInstanceUID", "studyInstanceUID"), ("patientName", "name"), ("patientID", "patientID"),',
                   '("patientUID", "patientUID"), ("dateOfBirth", "dateOfBirth"), ("name", "studyName"),',
                   '("date", "date"), ("modality", "modality"), ("accessionNumber", "accessionNumber")]'):
        if needle not in built:
            failures.append('the albums file entry changed: %s' % needle)

# The reader takes an entry without a name or predicate.
load = method(albums, 'loadAlbumsFromPath:')
if 'indexOfAlbum(forEntry: dict, in: albumArray)' not in load:
    failures.append('-loadAlbumsFromPath: no longer looks each entry up with indexOfAlbum')

# ... takes each album it finds out of the albums still to be found ...
if not re.search(r'a = albumArray\.object\(at: index\) as\? NSManagedObject\s*\n\s*albumArray\.removeObject\(at: index\)', load):
    failures.append('-loadAlbumsFromPath: leaves an album it found among those the next entry of the same name can find')

# ... and finds the album it created for it on an earlier import, one
# album per entry when several have the same name or none. The lookup is
# compiled on its own; the probe replays the reader's loop (look up, create or
# take out of the array, add the studies of a non-smart album) against doubles
# of the albums, fetched in either order.
lookup = block(albums, albums.find('private func indexOfAlbum('))
if not lookup:
    failures.append('no indexOfAlbum in %s' % PATH)
else:
    PROBE = r'''
import Foundation

%s

final class Study: NSObject {
    @objc let studyInstanceUID: String?
    init(_ uid: String?) { studyInstanceUID = uid }
}
final class Album: NSObject {
    @objc var name: String?
    @objc var smartAlbum: NSNumber = false
    @objc var studies = NSMutableSet()
    init(_ name: String?, smart: Bool = false, _ uids: [String] = []) {
        self.name = name; smartAlbum = NSNumber(value: smart)
        for uid in uids { studies.add(Study(uid)) }
    }
    var uids: [String] { return (studies.allObjects as! [Study]).compactMap { $0.studyInstanceUID }.sorted() }
}
func entry(_ name: String?, smart: Bool = false, _ uids: [String] = []) -> NSDictionary {
    let d = NSMutableDictionary()
    if let name { d["name"] = name }
    if smart { d["smartAlbum"] = NSNumber(value: true); d["predicateString"] = "modality = 'CT'" }
    else { d["studies"] = uids.map { ["studyInstanceUID": $0] } }
    return d
}
/// The loop of -loadAlbumsFromPath:, over the albums of the database in the order given.
func load(_ file: [NSDictionary], into database: inout [Album], reversed: Bool) {
    let albumArray = NSMutableArray(array: reversed ? database.reversed() : database)
    for dict in file {
        var a: Album
        let index = indexOfAlbum(forEntry: dict, in: albumArray)
        if index == NSNotFound {
            a = Album(dict["name"] as? String, smart: (dict["smartAlbum"] as? NSNumber)?.boolValue ?? false)
            database.append(a)
        } else {
            a = albumArray.object(at: index) as! Album
            albumArray.removeObject(at: index)
        }
        if !a.smartAlbum.boolValue {
            for study in (dict["studies"] as? [NSDictionary]) ?? [] {
                if let uid = study["studyInstanceUID"] as? String, !a.uids.contains(uid) { a.studies.add(Study(uid)) }
            }
        }
    }
}
func state(_ database: [Album]) -> String {
    return database.map { "\($0.name ?? "<none>")\($0.smartAlbum.boolValue ? "*" : "")\($0.uids)" }.sorted().joined(separator: " ")
}
let cases: [(String, [Album], [NSDictionary], String)] = [
    ("sameName", [], [entry("X", ["a"]), entry("X", ["b"])], "X[\"a\"] X[\"b\"]"),
    ("noNames", [], [entry(nil, ["a"]), entry(nil, ["b"])], "<none>[\"a\"] <none>[\"b\"]"),
    ("nested", [], [entry("X", ["a"]), entry("X", ["a", "b"])], "X[\"a\", \"b\"] X[\"a\"]"),
    ("smartAndNot", [], [entry("X", smart: true), entry("X", ["a"])], "X*[] X[\"a\"]"),
    ("onePresent", [Album("X", ["c"])], [entry("X", ["a"]), entry("X", ["b"])], "X[\"a\", \"c\"] X[\"b\"]"),
    ("distinct", [Album("Y", ["c"])], [entry("X", ["a"]), entry(nil, ["b"])], "<none>[\"b\"] X[\"a\"] Y[\"c\"]"),
]
for (label, start, file, expected) in cases {
    for reversed in [false, true] {
        var database = start.map { Album($0.name, smart: $0.smartAlbum.boolValue, $0.uids) }
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
let names = NSArray(array: [Album("Interesting Cases"), Album(nil), Album("Cases with comments")])
print("named=\(indexOfAlbum(forEntry: entry("Cases with comments"), in: names))")
print("nameless=\(indexOfAlbum(forEntry: entry(nil), in: names))")
print("absent=\(indexOfAlbum(forEntry: entry("Absent"), in: names) == NSNotFound)")
print("noneWithoutName=\(indexOfAlbum(forEntry: entry(nil), in: NSArray(array: [Album("Interesting Cases")])) == NSNotFound)")
print("noArray=\(indexOfAlbum(forEntry: entry(nil), in: nil) == NSNotFound)")
''' % lookup.replace('private func', 'func', 1)
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / 'main.swift').write_text(PROBE)
        built = subprocess.run(['xcrun', 'swiftc', '-O', '-o', str(Path(tmp) / 'probe'), str(Path(tmp) / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode:
            failures.append('indexOfAlbum does not compile on its own:\n' + built.stderr)
        else:
            ran = subprocess.run([str(Path(tmp) / 'probe')], capture_output=True, text=True)
            found = dict(line.split('=', 1) for line in ran.stdout.splitlines() if '=' in line)
            expected = {'named': '2', 'nameless': '1', 'absent': 'true', 'noneWithoutName': 'true', 'noArray': 'true'}
            for label in ('sameName', 'noNames', 'nested', 'smartAndNot', 'onePresent', 'distinct'):
                expected[label] = expected[label + '-reversed'] = 'idempotent'
            wrong = {k: (found.get(k), v) for k, v in expected.items() if found.get(k) != v}
            if wrong or ran.returncode:
                failures.append('indexOfAlbum and the reader loop give %r (found, expected): an album is not found again,'
                                ' or a repeated import changes the albums' % wrong)
if 'a?.setValue((dict as AnyObject).value(forKey: "predicateString"), forKey: "predicateString")' not in load:
    failures.append('-loadAlbumsFromPath: no longer reads a missing predicate as nil')

if failures:
    print('FAIL:\n  ' + '\n  '.join(failures))
    sys.exit(1)
print('PASS: the albums file is written once, whole and atomically; a nameless album does not cut it short,'
      ' and is found again, not created again, when the file is read; a repeated import is idempotent')

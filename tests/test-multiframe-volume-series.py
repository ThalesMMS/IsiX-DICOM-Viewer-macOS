#!/usr/bin/env python3
"""The multiframe files of one volume make one series, and reading them again adds nothing.

An acquisition in time (a functional or a diffusion series, a dynamic one) may
come as one Enhanced MR, CT or PET file per volume (or one of their legacy
converted classes), all of one Series Instance UID and the same slices. Every multiframe file used to be a series of its own,
keyed by its SOP Instance UID, and such an acquisition filled the list with one
series per point in time. The rule is IsiXDICOMFile's DICOMImportRules
(volumeSeriesKey; its cases are the module's tests): a volume shares a key with
the files of its geometry, anything else keeps the key it had.

This checks the two places that apply the rule:

- the reading (DicomFile+DICOMReading.swift) hands the rule the planes its
  frames state, as it reads them for the slice locations, takes the key from the
  rule and, for a volume, puts the key the file had before beside it
  (formerSeriesID); it builds neither key itself and leaves seriesDICOMUID alone;
- the import (DicomFileIndexer.swift, compiled here with the stand-ins of
  test-indexer-equivalence.py over an in-memory store, IsiXDatabase and
  IsiXDICOMFile the real ones) files the described files of a volume in one
  series, one row per frame; and in a database indexed when each file was a
  series of its own, finds the rows of a file in the series of its former key,
  so that reading the files again, in any order, read again in place or after
  later files of the acquisition made the shared series, adds no row and no
  series and renames none.

Exit 2 when the stand-ins cannot be read from test-indexer-equivalence.py.
"""
from pathlib import Path
import ast
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import indexer_paste  # noqa: E402
import isix_modules  # noqa: E402
import sources  # noqa: E402

failures = []

# --- the rule's classes --------------------------------------------------------
rules = (root / 'Modules/IsiXDICOMFile/Sources/DICOMImportRules.swift').read_text()
listed = re.search(r'volumeMultiframeSOPClasses: Set<String> = \[(.*?)\n    \]', rules, re.S)
classes = set(re.findall(r'"([0-9.]+)"', listed.group(1))) if listed else set()
if classes != {'1.2.840.10008.5.1.4.1.1.4.1', '1.2.840.10008.5.1.4.1.1.2.1', '1.2.840.10008.5.1.4.1.1.130',
               '1.2.840.10008.5.1.4.1.1.4.4', '1.2.840.10008.5.1.4.1.1.2.2', '1.2.840.10008.5.1.4.1.1.128.1'}:
    failures.append('the classes whose files share a series are %s, not Enhanced MR, CT and PET and their legacy converted '
                    'classes alone' % (', '.join(sorted(classes)) or 'not listed'))

# --- the reading applies the rule ---------------------------------------------
reader = sources.class_text('DicomFile')


def block(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        if depth == 0:
            return source[at:index + 1]
    return ''


frames = block(reader, 'private final func readFrames(of dataset: IsiXDCMTKItem) -> [DICOMImportRules.FramePlane]')
if not frames:
    failures.append('the reading of the frames no longer hands back their planes')
else:
    located = block(frames, 'if succeed {')
    if 'sliceLocations.add(' not in located or 'planes.append(DICOMImportRules.FramePlane(position: originMultiFrame, ' \
            'orientation: orientationMultiFrame))' not in located:
        failures.append('a frame\'s plane is not kept where its slice location is, from the same position and orientation')
    if frames.count('planes.append(') != 1 or 'return planes' not in frames:
        failures.append('the planes handed back are not one per frame that states its position')

branch = block(reader, 'if horos_numberOfFrames > 1 {')
if not branch:
    failures.append('the series of a multiframe file is no longer decided')
else:
    for needed, why in (
            ('DICOMImportRules.formerMultiframeSeriesKey(', 'the key of a file alone is not the rule\'s'),
            ('DICOMImportRules.volumeSeriesKey(grouping: serieID, layout: layout)', 'the key of a volume is not the rule\'s'),
            ('frames: horos_numberOfFrames, planes: framePlanes)', 'the rule is not given the frames and their planes'),
            ('sopClassUID: sopClassUID, columns: horos_width, rows: horos_height', 'the rule is not given the class and the size'),
            ('formerSeriesID = ownSeriesID', 'a volume does not keep the key it had as a series of its own')):
        if needed not in branch:
            failures.append('in the reading, %s' % why)
if 'let framePlanes = readFrames(of: dataset)' not in reader:
    failures.append('the planes the frames state do not reach the decision of the series')
if '%@-%@-%@' in reader or '-volume-' in reader:
    failures.append('the reading builds a series key itself; the keys are the rule\'s')

grouping = block(reader, 'private final func groupSeries(')
if 'forKey: "formerSeriesID" as NSString' not in grouping or 'if let formerSeriesID' not in grouping:
    failures.append('the former key of a volume is not filed beside its key')
if reader.count('"formerSeriesID"') != 1:
    failures.append('formerSeriesID is written in %d places, expected one' % reader.count('"formerSeriesID"'))
if len(re.findall(r'set\([^\n]*?, "seriesDICOMUID"\)', branch + grouping)) != 0:
    failures.append('the series of a multiframe file rewrites seriesDICOMUID, the Series Instance UID of the file')

# --- the import ------------------------------------------------------------------
indexer = indexer_paste.current()
for needed, why in (
        ('let formerSeriesID = curDict.object(forKey: "formerSeriesID" + seriesNum) as? String', 'does not read the former key'),
        ('if formerSeriesID != nil || !isEqualString(curDictSeriesID, cursor.seriesID) {',
         'takes the series of the file before for a file that has a former key'),
        ('ImportMatching.staysInFormerSeries(formerKey: formerSeriesID)', 'does not ask the rule where the file stays'),
        ('seriesTable?.setValue(seriesKey, forKey: "seriesInstanceUID")', 'does not keep the key of the series it files in'),
        ('cursor.seriesID = inFormerSeries ? formerSeriesID : curDictSeriesID', 'does not remember the key of the series it files in')):
    if needed not in indexer:
        failures.append('the import %s' % why)

# --- the image of a file, found by its path --------------------------------------
# A study can hold the shared series and series of the former key: the image is
# looked for in every series either key names, not in the first one alone.
lookup = (root / 'Horos/Sources/ViewerOpener+Navigation.swift').read_text()
if ('.filter { matches($0.seriesInstanceUID, "seriesID") || matches($0.seriesInstanceUID, "formerSeriesID") }' not in lookup
        or '.first(where: { matches($0.seriesInstanceUID, "seriesID")' in lookup):
    failures.append('the image of a file is looked for in one series of its study, where the shared and the former key can each name one')

DRIVER = r'''
import CoreData
import Foundation
import IsiXDICOMFile

let folder = CommandLine.arguments[1]
UserDefaults.standard.register(defaults: ["AETITLE": "HOROSTEST"])
let database = DicomDatabase(folder: folder)
let context = database.managedObjectContext!
for name in ["REPORTS", "NOT READABLE"] { try! FileManager.default.createDirectory(atPath: folder + "/" + name, withIntermediateDirectories: true) }
func file(_ name: String) -> String {
    let path = folder + "/" + name
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: Data(name.utf8)) }
    return path
}
let enhancedMR = "1.2.840.10008.5.1.4.1.1.4.1", ultrasound = "1.2.840.10008.5.1.4.1.1.3.1"

/// One file of an acquisition: its keys by the rule, and its description.
struct Volume {
    let study: String, series: String, name: String, number: Int, slices: Int
    var grouping: String { String(format: "%8.8d %@", 1, series) }
    var sop: String { series + "." + name }
    var layout: DICOMImportRules.MultiframeLayout {
        .init(sopClassUID: enhancedMR, columns: 64, rows: 64, frames: slices,
              planes: (0..<slices).map { .init(position: [-100, -100, 3 * Double($0)], orientation: [1, 0, 0, 0, 1, 0]) })
    }
    var key: String { DICOMImportRules.volumeSeriesKey(grouping: grouping, layout: layout)! }
    var formerKey: String {
        DICOMImportRules.formerMultiframeSeriesKey(grouping: grouping, imageID: DICOMImportRules.imageIdentifier(instanceNumber: Int32(number)),
                                                   sopInstanceUID: sop)
    }
    var described: NSMutableDictionary {
        NSMutableDictionary(dictionary: [
            "fileType": "DICOM", "numberOfSeries": NSNumber(value: 1), "SOPClassUID": enhancedMR, "modality": "MR",
            "hasDICOM": NSNumber(value: true), "height": NSNumber(value: 64), "width": NSNumber(value: 64),
            "filePath": file(name + ".dcm"), "studyID": study, "patientUID": "P" + study, "patientName": "SYNTHETIC^" + study,
            "seriesID": key, "formerSeriesID": formerKey, "seriesDICOMUID": series, "SOPUID": sop,
            "seriesDescription": "one volume per file", "imageID": NSNumber(value: number), "numberOfFrames": NSNumber(value: slices),
            "instanceNumberArray": (1...slices).map { NSNumber(value: $0) },
            "sliceLocationArray": (0..<slices).map { NSNumber(value: 3 * Float($0)) },
            "studyDate": Date(timeIntervalSinceReferenceDate: 800_000_000 + 2 * Double(number))])
    }
}
func loop(_ study: String, _ name: String, _ number: Int, frames: Int) -> NSMutableDictionary {
    let series = study + ".1", sop = study + ".1." + name
    let key = DICOMImportRules.multiframeSeriesKey(
        grouping: String(format: "%8.8d %@", 1, series), imageID: DICOMImportRules.imageIdentifier(instanceNumber: Int32(number)),
        sopInstanceUID: sop, layout: .init(sopClassUID: ultrasound, columns: 64, rows: 48, frames: frames, planes: []))
    return NSMutableDictionary(dictionary: [
        "fileType": "DICOM", "numberOfSeries": NSNumber(value: 1), "SOPClassUID": ultrasound, "modality": "US",
        "hasDICOM": NSNumber(value: true), "height": NSNumber(value: 48), "width": NSNumber(value: 64),
        "filePath": file(name + ".dcm"), "studyID": study, "patientUID": "P" + study, "patientName": "SYNTHETIC^" + study,
        "seriesID": key, "seriesDICOMUID": series, "SOPUID": sop, "imageID": NSNumber(value: number),
        "numberOfFrames": NSNumber(value: frames)])
}

let split = (1...6).map { Volume(study: "1.1", series: "1.1.1", name: "a\($0)", number: $0, slices: 12) }
let single = Volume(study: "2.2", series: "2.2.1", name: "b1", number: 1, slices: 12)
let fresh = (1...4).map { Volume(study: "3.3", series: "3.3.1", name: "f\($0)", number: $0, slices: 12) }
let shorter = Volume(study: "3.3", series: "3.3.1", name: "g1", number: 5, slices: 10)

// --- a database indexed when each multiframe file was a series of its own -----
context.performAndWait {
    func study(_ uid: String) -> DicomStudy {
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as! DicomStudy
        study.studyInstanceUID = uid; study.patientUID = "P" + uid; study.modality = "MR"; study.name = "SYNTHETIC^" + uid
        return study
    }
    func index(_ volume: Volume, in study: DicomStudy) {
        let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
        series.setValue(volume.formerKey, forKey: "seriesInstanceUID"); series.setValue(volume.series, forKey: "seriesDICOMUID")
        series.setValue("MR", forKey: "modality"); series.setValue(study, forKey: "study")
        for frame in 0..<volume.slices {
            let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context) as! DicomImage
            image.setSopInstanceUID(volume.sop); image.setPath(volume.name + ".dcm"); image.frameID = NSNumber(value: frame)
            image.setValue(NSNumber(value: true), forKey: "inDatabaseFolder"); image.setValue(series, forKey: "series")
        }
        _ = file(volume.name + ".dcm")
    }
    let acquisition = study("1.1")
    for volume in split.prefix(4) { index(volume, in: acquisition) }
    index(single, in: study("2.2"))
    try! context.save()
}

func state(_ label: String) {
    context.performAndWait {
        let all = try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Series"))
        let lines = all.map { series -> String in
            let images = ((series.value(forKey: "images") as? NSSet)?.allObjects as? [DicomImage]) ?? []
            let files = Set(images.compactMap { $0.sopInstanceUID() })
            let rows = Set(images.map { "\($0.sopInstanceUID() ?? "")#\($0.frameID?.intValue ?? 0)" })
            let paths = Set(images.compactMap { ($0.path() as NSString?)?.lastPathComponent })
            return "\(label) | \((series.value(forKey: "study") as? DicomStudy)?.studyInstanceUID ?? "-") | "
                + "\(series.value(forKey: "seriesInstanceUID") as? String ?? "-") | \(images.count) rows | \(rows.count) frames | "
                + "\(files.count) files | \(paths.count) paths | uid \(series.value(forKey: "seriesDICOMUID") as? String ?? "-")"
        }
        for line in lines.sorted() { emit(line) }
        emit("\(label) total \(all.count) series \((try! context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Image")))) rows")
    }
}
func run(_ label: String, _ files: [NSMutableDictionary], reread: Bool = false) {
    context.performAndWait {
        _ = database.addFilesDescribed(inDictionaries: files, postNotifications: false, rereadExistingItems: reread,
                                       generatedByOsiriX: false, importedFiles: false, returnArray: true)
    }
    state(label)
}

emit("key split " + split[0].key)
emit("key shorter " + shorter.key)
for volume in split + [single] { emit("former \(volume.name) " + volume.formerKey) }
state("seeded")
run("again", split.prefix(4).map(\.described) + [single.described])
run("reread", split.prefix(4).map(\.described) + [single.described], reread: true)
run("later", split.suffix(2).map(\.described))
run("mixed", [4, 0, 5, 2, 1, 3].map { split[$0].described } + [single.described])
run("mixed reread", [1, 5, 0, 4, 3, 2].map { split[$0].described }, reread: true)
run("fresh", fresh.map(\.described) + [shorter.described, loop("4.4", "c1", 1, frames: 5), loop("4.4", "c2", 2, frames: 8)])
run("fresh again", [loop("4.4", "c2", 2, frames: 8), shorter.described] + fresh.reversed().map(\.described) + [loop("4.4", "c1", 1, frames: 5)])
context.performAndWait {
    for image in ((try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Image"))) as! [DicomImage])
    where image.sopInstanceUID() == fresh[2].sop {
        emit("row \(image.frameID?.intValue ?? -1) instance \((image.value(forKey: "instanceNumber") as? NSNumber)?.intValue ?? -1) "
            + "location \((image.value(forKey: "sliceLocation") as? NSNumber)?.intValue ?? -1) frames "
            + "\((image.value(forKey: "numberOfFrames") as? NSNumber)?.intValue ?? -1) path \((image.path() as NSString?)?.lastPathComponent ?? "-")")
    }
}
'''


def equivalence_parts():
    """The stand-ins the indexer is compiled with, and how, from the test that
    compares it with the import before: its definitions, not its run."""
    path = root / 'tests/test-indexer-equivalence.py'
    wanted = {'member', 'without', 'body', 'indexer_paste_of', 'STANDINS', 'INDEXER_STANDINS', 'build_and_run'}
    nodes = [node for node in ast.parse(path.read_text()).body
             if isinstance(node, ast.FunctionDef) and node.name in wanted
             or isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id in wanted for target in node.targets)]
    names = {'re': re, 'subprocess': subprocess, 'isix_modules': isix_modules, 'failures': failures, 'DRIVER': DRIVER}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), names)
    return names if wanted <= set(names) else None


parts = equivalence_parts()
if parts is None:
    print('skipped: the stand-ins of test-indexer-equivalence.py are not where this reads them')
    sys.exit(2)

directory = Path(tempfile.mkdtemp(prefix='horos-multiframe-volume-series-'))
try:
    lines = parts['build_and_run']('the indexer of the checkout', parts['indexer_paste_of'](indexer), parts['INDEXER_STANDINS'],
                                   directory / 'indexer')
finally:
    shutil.rmtree(directory, ignore_errors=True)

if lines is not None:
    if '--verbose' in sys.argv:
        print('\n'.join(lines))
    keys = dict(line.split(' ', 2)[1:] for line in lines if line.startswith(('key ', 'former ')))
    shared, former = keys.get('split'), [keys.get('a%d' % number) for number in range(1, 7)]
    if not shared or not re.fullmatch(r'00000001 1\.1\.1-volume-64x64x12-[0-9a-f]{16}', shared):
        failures.append('the key of the volumes is %r' % shared)
    if keys.get('a1') != '00000001 1.1.1-    1-1.1.1.a1':
        failures.append('the former key of the first volume is %r' % keys.get('a1'))

    def series(label):
        """{(study, key): (rows, frames, files, paths)} and the totals after a batch."""
        found, total = {}, None
        for line in lines:
            if line.startswith(label + ' | '):
                _, study, key, rows, distinct, files, paths, _ = line.split(' | ')
                found[(study, key)] = tuple(int(part.split()[0]) for part in (rows, distinct, files, paths))
            elif line.startswith(label + ' total '):
                total = tuple(int(number) for number in re.findall(r'\d+', line[len(label):]))
        return found, total

    seeded = dict([(('1.1', key), (12, 12, 1, 1)) for key in former[:4]] + [(('2.2', keys.get('b1')), (12, 12, 1, 1))])
    later = dict(seeded)
    later[('1.1', shared)] = (24, 24, 2, 2)
    expected = {
        'seeded': (seeded, (5, 60)),
        # The files of a database indexed with the former keys, read again: nothing new, nothing renamed.
        'again': (seeded, (5, 60)),
        'reread': (seeded, (5, 60)),
        # Two later files of the acquisition: one series for both, beside the four.
        'later': (later, (6, 84)),
        # And every file again, in other orders: each one where it was.
        'mixed': (later, (6, 84)),
        'mixed reread': (later, (6, 84)),
    }
    for label, (want, total) in expected.items():
        got = series(label)
        if got != (want, total):
            failures.append('after "%s" the database has %s (%s series, rows), expected %s (%s)'
                            % (label, sorted(got[0].items()), got[1], sorted(want.items()), total))

    # A database that never had the former keys: one series for the four files,
    # another for the file of another geometry, one per loop.
    for label in ('fresh', 'fresh again'):
        found, total = series(label)
        study = {key: value for (uid, key), value in found.items() if uid == '3.3'}
        loops = sorted(value for (uid, key), value in found.items() if uid == '4.4')
        merged = [key for key, value in study.items() if value == (48, 48, 4, 4)]
        if len(study) != 2 or len(merged) != 1 or study.get(keys.get('shorter')) != (10, 10, 1, 1) or merged == [keys.get('shorter')]:
            failures.append('after "%s" the four volumes and the shorter one make %s, expected one series of 48 rows of 4 files '
                            'and one of 10 rows' % (label, sorted(study.items())))
        if loops != [(5, 5, 1, 1), (8, 8, 1, 1)]:
            failures.append('after "%s" the two loops make %s, expected a series each' % (label, loops))
        if total != (10, 155):
            failures.append('after "%s" the database has %s series and rows, expected 10 and 155' % (label, total))
    for line in lines:
        if ' | ' in line and not re.search(r' \| uid (1\.1\.1|2\.2\.1|3\.3\.1|4\.4\.1)$', line):
            failures.append('a series lost the Series Instance UID of its files: %s' % line)

    # The rows of a file in a shared series are what they were in its own:
    # one per frame, numbered and placed by the frame, of the file's path.
    rows = sorted(line for line in lines if line.startswith('row '))
    wanted = sorted('row %d instance %d location %d frames 12 path f3.dcm' % (frame, frame + 1, 3 * frame) for frame in range(12))
    if rows != wanted:
        failures.append('the rows of a file in a shared series are\n  %s\nexpected\n  %s' % ('\n  '.join(rows), '\n  '.join(wanted)))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the reading takes the series of a multiframe file from the rule, the files of one volume make one series, and '
      'a file indexed as a series of its own stays in it when read again')

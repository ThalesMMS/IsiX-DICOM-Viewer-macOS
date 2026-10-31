#!/usr/bin/env python3
"""Each preset of the single entry is what its path passed in the revision before.

Modules/IsiXContracts/Sources/DICOMIngesting.swift names the six options of each
way into the index, written out in full. They decide what is stored and who is
told, so a preset that differs from its path changes the database of whoever
uses that path, with no failure anywhere. The reference is the source itself in
the last revision before the port existed, found with
isix_modules.revision_before and never by a fixed hash, so the check survives
what later moves the callers.

Every call of addFiles(atPaths:) and addFilesDescribed(inDictionaries:) of that
revision is read here, with what each overload of the indexer passed for the
arguments it leaves out, and must be the preset CALLS names for it: a call that
is not listed fails, and so does a preset no call asks for. An option that the
caller computes counts for both of its values, and each must be one of the
presets of the call. The transports that leave files for the scan take the
scan's options, since it is the scan that indexes them. The calls left out are in
UNLISTED, with why.

And what the options do, not only their values: the code of the indexer that
stores `importedFile` and `generatedByOsiriX`, that fills the comments, the state
and the key frames, and that posts the notifications and starts the autorouting
is pasted from that revision and from the checkout into one stand-in each, and
driven with a file that brings all of them. For each preset, the options read
from the old call on the old code and the preset on the code of the checkout
must store, tell and route the same. `dicomOnly` chooses which files are read,
before any of that, so its value is what is compared.
"""
from pathlib import Path
import importlib.util
import itertools
import json
import re
import shutil
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
PORT = 'Modules/IsiXContracts/Sources/DICOMIngesting.swift'
SOURCES = 'Horos/Sources/'
failures = []

spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


def fail(message):
    failures.append(message)
    print('FAIL:', message)


# file: the preset of each call, in reading order; a list for a call whose
# options depend on what its caller computes.
CALLS = {
    'BonjourPublisher.swift': [['sharedDatabaseReceived', 'sharedDatabaseGenerated']],
    'BrowserController+Anonymization.swift': ['anonymization'],
    'BrowserController+DICOMExport.swift': ['generated'],
    'BrowserController+DatabaseDragExport+Selection.swift': ['generated'],
    'BrowserController+DatabaseMaintenance.swift': ['surgicalRecords'],
    'BrowserController+Reports.swift': ['generated'],
    'BrowserController+Sources+Copy.swift': ['sourceCopyBatch', 'sourceCopy', 'sourceCopy'],
    'CPRController.swift': ['generated'],
    'DCMPix+RTStruct.swift': ['generated'],
    'DatabaseRebuildService.swift': ['rebuild'],
    'DicomDatabase+Compression.swift': ['decompress'],
    'DicomDatabase+DicomDir.swift': ['mediaDicomdir'],
    'DicomDatabase+IncomingImport.swift': ['incoming'],
    'DicomDatabase+MediaCopy.swift': [['mediaCopyDICOM', 'mediaCopyAnything', 'dragAndDropDICOM', 'dragAndDropAnything']],
    'DicomDatabase+Scan.swift': ['mediaScan'],
    'DicomStudy.swift': [['generated', 'generatedQuiet'], 'generated', 'generated', 'generatedQuiet', 'generated'],
    'EndoscopyMPRView.swift': ['generated'],
    'EndoscopyViewer.swift': ['generated'],
    'FlyThruController.swift': ['generated'],
    'IsiXDatabaseAdapter.swift': ['plugin'],
    'MPRController.swift': ['generated'],
    'OrthogonalMPRPETCTViewer.swift': ['generated'],
    'OrthogonalMPRViewer.swift': ['generated'],
    'ROISaveJob.swift': [['generated', 'generatedQuiet']],
    'SceneView.swift': ['generated'],
    'URLImportOperation.swift': ['url'],
    'ViewerController+Export.swift': ['generated', 'generated'],
    'ViewerController+KeyImageCapture.swift': ['generated'],
    'ViewerController+ROI.swift': ['generated'],
    'WebPortalConnection.swift': ['upload', 'upload'],
    'XMLController.swift': ['modify'],
}
# The presets of what the scan indexes for them.
TRANSPORTS = ('listener', 'retrieve', 'dicomweb', 'wado')
# Where the files of the revision before the port went since, each with what it
# must still say to reach its preset through the single entry.
MOVED = {
    'Horos/Sources/BonjourPublisher.swift': ('generatedByViewer ? .sharedDatabaseGenerated : .sharedDatabaseReceived, in: idatabase)',),
    'Horos/Sources/AnonymizedImport.swift': ('index(chunk, preset: .anonymization, in: target)',),
    'Horos/Sources/BrowserController+DICOMExport.swift': ('GeneratedSeriesImport.process.images(indexing:',),
    # Paste, from the browser or a viewer.
    'Horos/Sources/ClipboardImagePaste.swift': ('GeneratedSeriesImport.process.add(into: database',),
    'Horos/Sources/BrowserController+DatabaseMaintenance.swift': ('index(paths, preset: .surgicalRecords, in: database)',),
    # The copies between sources, each through SourceCopyJob's one call of the entry.
    'Horos/Sources/SourceCopyJob.swift': ('indexCopies(copied, preset: .sourceCopyBatch, in: destination)',
                                          'indexCopies(copied, preset: .sourceCopy, in: destination)',
                                          'indexCopies(copied, preset: .sourceCopy, in: local)',
                                          'ingest.index(paths, preset: preset, in: database)'),
    'Horos/Sources/CPRController.swift': ('GeneratedSeriesImport.process.add(',),
    'Horos/Sources/DCMPix+RTStruct.swift': ('index(newFiles as? [Any], preset: .generated, in: database)',),
    'Horos/Sources/DatabaseFileConversion.swift': ('ingest.index(paths, preset: .decompress, in: database)',),
    'Horos/Sources/DatabaseRebuildService.swift': ('index(files, preset: .rebuild, in: database)',),
    'Horos/Sources/DicomStudy.swift': ('preset: postNotifications ? .generated : .generatedQuiet, in: database)',
                                       'GeneratedSeriesImport.process.images(indexing:',
                                       # The annotations SR (quiet, through AnnotationsSRPruning) and the report SR, into the
                                       # study's own database where a scratch database in the temporary folder had them.
                                       'GeneratedSeriesImport.process.add(into: database, writing:',
                                       'GeneratedSeriesImport.process.add(into: database, at: dstPath, writing:',
                                       # The windows state SR, into the study's own database.
                                       'GeneratedSeriesImport.process.add(into: database)'),
    # The validated report's DICOM PDF, into the study's own database where a scratch database in the
    # temporary folder had it for a study the browser did not show.
    'Horos/Sources/DicomStudy+Report.swift': ('index([path], preset: .generated, in: database)',
                                              'GeneratedSeriesImport.process.add(into: database, writing:'),
    'Horos/Sources/EndoscopyMPRView.swift': ('GeneratedSeriesImport.process.add(',),
    'Horos/Sources/EndoscopyViewer.swift': ('GeneratedSeriesImport.process.add(',),
    'Horos/Sources/FlyThruController.swift': ('GeneratedSeriesImport.process.add(',),
    # The exports into the database shown, and an image for a given database
    # (the key image capture and Paste).
    'Horos/Sources/GeneratedSeriesImport.swift': ('index(paths, preset: .generated, in: database)', 'index([path], preset: .generated, in: database)'),
    'Horos/Sources/IncomingAdmission.swift': ('ingest.indexReturningIDs(Array(filesArray), preset: .incoming, in: database)',),
    'Horos/Sources/IsiXDatabaseAdapter.swift': ('index(copies, preset: .plugin, in: database)',),
    'Horos/Sources/MPRController.swift': ('GeneratedSeriesImport.process.add(',),
    'Horos/Sources/OrthogonalMPRPETCTViewer.swift': ('GeneratedSeriesImport.process.add(',),
    'Horos/Sources/OrthogonalMPRViewer.swift': ('GeneratedSeriesImport.process.add(',),
    'Horos/Sources/ROISaveJob.swift': ('preset: end == self.written.count ? .generated : .generatedQuiet, in: database)',),
    'Horos/Sources/ROIVolumeView.swift': ('GeneratedSeriesImport.process.add(',),
    'Horos/Sources/SRView+Export.swift': ('GeneratedSeriesImport.process.add(',),
    'Horos/Sources/StudyReports.swift': ('index(written, preset: .generated, in: database)',),
    'Horos/Sources/URLImportOperation.swift': ('ingest.publishAndImport(draft, preset: .url, in: database)', 'ingest.publish(draft, preset: .url)'),
    'Horos/Sources/VRView+Export.swift': ('GeneratedSeriesImport.process.add(',),
    # The 2D viewer's two DICOM exports and its key image capture.
    'Horos/Sources/ViewerImageExporter.swift': ('GeneratedSeriesImport.process.add(',) * 2 + ('imports.add(into: database)',),
    # The 2D viewer's ROI reports, written through its ROI archive store.
    'Horos/Sources/ViewerROIArchiveStore.swift': ('ingest.index(paths, preset: .generated, in: database)',),
    'Horos/Sources/WebPortalConnection.swift': ('index(filesAccumulator as? [Any], preset: .upload, in: idatabase)',) * 2,
    'Horos/Sources/XMLController.swift': ('preset: .modify, in: $0)',),
    'Horos/Sources/DicomdirReader.swift': (),
    'Horos/Sources/MediaVolumeScan.swift': ('ingest.index(described: entries, preset: .mediaDicomdir, in: database)',
                                            'ingest.indexReturningIDs(files, preset: .mediaScan, in: database)'),
    'Horos/Sources/MediaImportJob.swift': ('ingest.indexOnOwnContext(acceptedFiles, preset: request.preset, of: database)',),
}
UNLISTED = {
    'DicomDatabase+Import.swift': 'the overloads of the indexer, each passing to the next',
    'BrowserController+DatabaseImport.swift': 'deprecated entry points that passed on what their caller gave them, since removed',
    'RemoteDicomDatabase.swift': 'an override that passes on what it is given to the local indexer',
}

# What each overload of the indexer passed for what it leaves out.
ADD_FILES = {'postNotifications': 'true', 'dicomOnly': 'preference', 'rereadExistingItems': 'false',
             'generatedByOsiriX': 'false', 'importedFiles': 'false', 'returnArray': 'true'}
DESCRIBED = dict(ADD_FILES, dicomOnly='false')
CALL = re.compile(r'\b(addFiles)\(atPaths:|\b(addFilesDescribed)\(inDictionaries:')


def git(*arguments):
    return subprocess.run(['git', '-C', str(root), *arguments], capture_output=True)


def shown(revision, path):
    result = git('show', f'{revision}:{path}')
    return result.stdout.decode('utf-8', 'replace') if result.returncode == 0 else None


def arguments(text, code, opening):
    """The labelled arguments of the call whose parenthesis is at `opening`."""
    depth, start, found = 0, opening + 1, {}
    at = opening
    while True:
        character = code[at]
        if character in '([{':
            depth += 1
        elif character in ')]}':
            depth -= 1
        if (character == ',' and depth == 1) or depth == 0:
            label, _, value = text[start:at].partition(':')
            found[label.strip()] = value.strip()
            start = at + 1
            if depth == 0:
                return found
        at += 1


def calls(text):
    """The options of each call of `text`, in reading order."""
    code = indicator.swift_code(text)
    found = []
    for call in CALL.finditer(code):
        given = arguments(text, code, code.index('(', call.start()))
        options = dict(DESCRIBED if call.group(2) else ADD_FILES)
        for label in options:
            if label in given:
                options[label] = given[label]
        found.append(options)
    return found


def values(option, value):
    """What an argument may be: its literal, the preference, or both of a computed one."""
    if value in ('true', 'false'):
        literal = value == 'true'
        return [('always' if literal else 'never') if option == 'dicomOnly' else literal]
    if value == 'preference' or 'forKey: "onlyDICOM"' in value:
        return ['preference']
    return ['always', 'never'] if option == 'dicomOnly' else [True, False]


def expansions(options):
    names = list(options)
    return [dict(zip(names, chosen)) for chosen in itertools.product(*(values(name, options[name]) for name in names))]


def method(text, signature):
    """A Swift member from `signature` through its closing brace."""
    at = text.index(signature)
    code = indicator.swift_code(text)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return text[at:index]


def stored_flags(text):
    """The lines of the indexer that store the two flags in an image."""
    start = text.index('                if importedFiles {')
    last = text.index('image?.setValue(nil, forKey: "generatedByOsiriX")', start)
    return text[start:text.index('}', last) + 1]


def probe_source(importer, maintenance):
    autorouting = method(maintenance, 'dynamic func allowAutorouting(').replace('dynamic func', 'func')
    if 'struct DicomFileIndexer' in importer:
        # The indexer is a type of its own that reaches the database as
        # `database`; the stand-in database forwards to it.
        publish = method(importer, 'private func publish(').replace('private func', 'func')
        comments = method(importer, 'private func fillComments(').replace('private func', 'func')
        members = INDEXER_FORWARDERS
        tail = INDEXER_STANDIN.replace('@PUBLISH@', publish).replace('@COMMENTS@', comments)
    else:
        publish = method(importer, 'private final func publish(').replace('private final func', 'func')
        comments = method(importer, 'private final func fillComments(').replace('private final func', 'func')
        members, tail = publish + '\n\n    ' + comments, ''
    return STANDINS.replace('@PUBLISH@\n\n    @COMMENTS@', members).replace('@AUTOROUTING@', autorouting) \
        .replace('@FLAGS@', stored_flags(importer)) + tail


# The members the stand-in database forwards to the indexer, and the indexer.
INDEXER_FORWARDERS = r'''func publish(_ added: DicomDatabaseImportBatch, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) {
        DicomFileIndexer(database: self).publish(added, postNotifications: postNotifications, rereadExistingItems: rereadExistingItems,
                                                 generatedByOsiriX: generatedByOsiriX, returnArray: returnArray)
    }

    func fillComments(_ curDict: NSMutableDictionary, image: DicomImage?, seriesTable: NSManagedObject?, study: DicomStudy?, frame f: Int32,
                      settings: DicomDatabaseImportSettings, generatedByOsiriX: Bool) {
        DicomFileIndexer(database: self).fillComments(curDict, image: image, seriesTable: seriesTable, study: study, frame: f,
                                                      settings: settings, generatedByOsiriX: generatedByOsiriX)
    }'''
INDEXER_STANDIN = r'''
struct IndexerFeedback {
    let database: DicomDatabase
    func notifyImport(imagesAdded: String?, newStudy: String?) { database.notifyImport(imagesAdded: imagesAdded, newStudy: newStudy) }
}

struct DicomFileIndexer {
    let database: DicomDatabase
    let preferences = UserDefaults.standard
    var feedback: IndexerFeedback { IndexerFeedback(database: database) }
    func objcLength(_ object: Any?) -> Int { database.objcLength(object) }
    func objcIntValue(_ object: Any?) -> Int32 { database.objcIntValue(object) }

    @PUBLISH@

    @COMMENTS@
}
'''


STANDINS = r'''
import Foundation

let OsirixAddToDBNotificationImagesArray = "images", OsirixAddToDBNotificationImagesPerAETDictionary = "byCreator"

// A row of the model, with what the pasted code asks of a managed object.
final class Row: NSObject {
    var values: [String: Any] = [:]
    override func value(forKey key: String) -> Any? { values[key] }
    override func setValue(_ value: Any?, forKey key: String) { values[key] = value }
    func setPrimitiveValue(_ value: Any?, forKey key: String) { values[key] = value }
    var importedFile: NSNumber? {
        get { values["importedFile"] as? NSNumber }
        set { values["importedFile"] = newValue }
    }
}
typealias NSManagedObject = Row
typealias DicomImage = Row
typealias DicomStudy = Row

struct DicomDatabaseImportSettings {
    let commentsAutoFill: Bool
    let commentField: String?
    let commentsAutoFillSeriesLevel: Bool
    let commentsAutoFillStudyLevel: Bool
}

final class DicomDatabaseImportBatch {
    let newStudies = NSMutableArray()
    var newStudy = false
    let addedImageObjects: NSMutableArray?
    let completeAddedImageObjects: NSMutableArray?
    let addedImagesPerCreatorUID: NSMutableDictionary?
    let completeAddedImagesPerCreatorUID: NSMutableDictionary?
    init(returnArray: Bool) {
        addedImageObjects = returnArray ? NSMutableArray() : nil
        completeAddedImageObjects = returnArray ? NSMutableArray() : nil
        addedImagesPerCreatorUID = returnArray ? NSMutableDictionary() : nil
        completeAddedImagesPerCreatorUID = returnArray ? NSMutableDictionary() : nil
    }
}

enum ProtectedMode { static var isActive: Bool { false } }

// The guards of HorosObjCException+Guards.swift, running each body.
enum HorosObjCException {
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
    static func caught(_ body: () -> Void, catch handler: (NSException) -> Void) { body() }
    static func caughtWithoutAllocation(_ body: () -> Void) -> NSException? { body(); return nil }
    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool { body(); return false }
    @discardableResult
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T { body() }
    @discardableResult
    static func raisingToCaller<T>(_ body: () -> T) -> T { body() }
    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T { try body() }
}

enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? { body(); return nil }
    static func log(_ exception: NSException, stack: Bool, _ function: String) {}
    static func arg(_ value: Any?) -> CVarArg { String(describing: value ?? "(null)") as NSString }
    static func localizedCount(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
    static func dictionary(_ pairs: [(Any?, String)]) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        for (value, key) in pairs { if let value { dictionary[key] = value } }
        return dictionary
    }
}

extension Thread { var progress: CGFloat { get { 0 } set {} } }

extension Notification.Name {
    static let _O2AddToDBAnyway = Notification.Name("_O2AddToDBAnyway")
    static let _O2AddToDBAnywayComplete = Notification.Name("_O2AddToDBAnywayComplete")
    static let OsirixAddNewStudiesDB = Notification.Name("OsirixAddNewStudiesDB")
    static let OsirixAddToDB = Notification.Name("OsirixAddToDB")
    static let OsirixAddToDBComplete = Notification.Name("OsirixAddToDBComplete")
}

extension NotificationCenter {
    func postNotificationOnMainThread(name: NSString, object: Any?, userInfo: NSDictionary?) {
        heard.append(name as String)
    }
}

nonisolated(unsafe) var heard: [String] = []

final class DicomDatabase: NSObject {
    var timeOfLastModification = 0.0
    var routed = false
    var notice: [String?] = []
    func isLocal() -> Bool { true }
    func alertToApplyRoutingRules(_ routingRules: [Any]?, toImages images: [Any]?) { routed = true }
    func notifyImport(imagesAdded: String?, newStudy: String?) { notice = [imagesAdded, newStudy] }
    func objcLength(_ object: Any?) -> Int { (object as? NSString)?.length ?? 0 }
    func objcIntValue(_ object: Any?) -> Int32 { (object as? NSNumber)?.int32Value ?? 0 }

    @AUTOROUTING@

    @PUBLISH@

    @COMMENTS@

    func storeFlags(_ image: Row?, importedFiles: Bool, generatedByOsiriX: Bool) {
        @FLAGS@
    }
}

/// One file with all that the options decide about, added once.
func scenario(post: Bool, reread: Bool, generated: Bool, imported: Bool, returned: Bool) -> [String: Any] {
    heard = []
    let database = DicomDatabase()
    let study = Row(), series = Row(), image = Row()
    study.values = ["name": "SYNTHETIC^PRESET", "studyName": "preset", "stateText": NSNumber(value: 0)]
    series.values = ["study": study]
    image.values = ["series": series]
    let file = NSMutableDictionary(dictionary: ["commentsAutoFill": "auto", "seriesComments": "of the series", "studyComments": "of the study",
                                                "stateText": NSNumber(value: 2), "keyFrames": [NSNumber(value: 0)]])
    let settings = DicomDatabaseImportSettings(commentsAutoFill: false, commentField: "comment2",
                                               commentsAutoFillSeriesLevel: true, commentsAutoFillStudyLevel: true)
    database.storeFlags(image, importedFiles: imported, generatedByOsiriX: generated)
    database.fillComments(file, image: image, seriesTable: series, study: study, frame: 0, settings: settings, generatedByOsiriX: generated)
    let added = DicomDatabaseImportBatch(returnArray: returned)
    added.addedImageObjects?.add(image)
    added.completeAddedImageObjects?.add(image)
    added.newStudy = true
    added.newStudies.add(study)
    database.publish(added, postNotifications: post, rereadExistingItems: reread, generatedByOsiriX: generated, returnArray: returned)
    func text(_ value: Any?) -> Any { value.map { String(describing: $0) } ?? NSNull() }
    return ["importedFile": text(image.values["importedFile"]), "generatedByOsiriX": text(image.values["generatedByOsiriX"]),
            "seriesComment": text(series.values["comment"]), "studyComment": text(study.values["comment"]),
            "stateText": text(study.values["stateText"]), "keyImage": text(image.values["storedIsKeyImage"]),
            "notifications": heard, "notice": database.notice.map(text), "routed": database.routed]
}
'''

DRIVER = r'''
UserDefaults.standard.set(true, forKey: "AUTOROUTINGACTIVATED")
for name in [Notification.Name._O2AddToDBAnyway, ._O2AddToDBAnywayComplete] {
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { heard.append($0.name.rawValue) }
}
var results: [String: Any] = [:]
let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: [String: Bool]]
for (name, options) in cases {
    results[name] = scenario(post: options["postNotifications"]!, reread: options["rereadExistingItems"]!, generated: options["generatedByOsiriX"]!,
                             imported: options["importedFiles"]!, returned: options["returnArray"]!)
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
'''

PRESETS = r'''
import Foundation
import IsiXContracts

func dicomOnly(_ value: IngestDicomOnly) -> String {
    switch value {
    case .always: return "always"
    case .never: return "never"
    case .preference: return "preference"
    }
}
let table = IngestPreset.all.map { preset -> [String: Any] in
    ["name": preset.name, "source": preset.source.rawValue, "postNotifications": preset.options.postNotifications,
     "dicomOnly": dicomOnly(preset.options.dicomOnly), "rereadExistingItems": preset.options.rereadExistingItems,
     "generatedByOsiriX": preset.options.generatedByOsiriX, "importedFiles": preset.options.importedFiles,
     "returnArray": preset.options.returnArray]
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: table))
'''

revision = isix_modules.revision_before(root, PORT)
if revision is None:
    print('skipped: this history does not reach the revision before the port', file=sys.stderr)
    sys.exit(SKIPPED)
if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

listed = git('ls-tree', '-r', '--name-only', revision, '--', SOURCES).stdout.decode().split()
found = {}
for path in listed:
    if path.endswith('.swift'):
        text = shown(revision, path)
        if CALL.search(text):
            options = calls(text)
            if options:
                found[Path(path).name] = options

with tempfile.TemporaryDirectory(prefix='horos-ingest-presets-') as directory:
    folder = Path(directory)

    def swiftc(name, sources, *flags):
        built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'cache'), *flags, *map(str, sources),
                                '-o', str(folder / name)], capture_output=True, text=True)
        if built.returncode != 0:
            print('FAIL:', name, 'does not compile\n' + built.stderr[-3000:])
            sys.exit(1)
        return folder / name

    (folder / 'presets').mkdir()
    (folder / 'presets/main.swift').write_text(PRESETS)
    table = swiftc('presets-tool', [folder / 'presets/main.swift'], *isix_modules.module_flags('IsiXContracts', folder / 'internal'))
    presets = {entry['name']: entry for entry in json.loads(subprocess.run([str(table)], capture_output=True, check=True).stdout)}

    def option_values(name):
        return {key: value for key, value in presets[name].items() if key not in ('name', 'source')}

    # --- the options of each path ------------------------------------------------
    for name in sorted(set(CALLS) - set(found)):
        fail(f'{name}: no call in {revision}, so this test no longer reads that revision')
    asked = {}
    for name, options in sorted(found.items()):
        if name in UNLISTED:
            continue
        expected = CALLS.get(name)
        if expected is None:
            fail(f'{name}: a call of the revision before the port that names no preset')
            continue
        if len(expected) != len(options):
            fail(f'{name}: {len(options)} calls in the revision before the port, {len(expected)} presets named')
            continue
        for number, (call, chosen) in enumerate(zip(options, expected)):
            names = chosen if isinstance(chosen, list) else [chosen]
            cases = expansions(call)
            for each in names:
                if each not in presets:
                    fail(f'{name} call {number}: no preset {each}')
                elif option_values(each) not in cases:
                    fail(f'{name} call {number}: preset {each} is {option_values(each)}, the call passed {cases}')
                else:
                    asked.setdefault(each, cases[cases.index(option_values(each))])
            for case in cases:
                if not any(option_values(each) == case for each in names if each in presets):
                    fail(f'{name} call {number}: it could pass {case}, which none of {names} carries')
    for name in TRANSPORTS + ('url',):
        if option_values(name) != option_values('incoming'):
            fail(f'{name}: what it publishes is indexed by the scan, and the preset says otherwise')
        asked.setdefault(name, option_values('incoming'))
    for name in sorted(set(presets) - set(asked)):
        fail(f'preset {name}: no call of the revision before the port passed it')
    for name, reaches in MOVED.items():
        text = (root / name).read_text(encoding='utf-8')
        if CALL.search(indicator.swift_code(text)):
            fail(f'{name} reaches the index without the single entry')
        for each in sorted(set(reaches)):
            if text.count(each) < reaches.count(each):
                fail(f'{name} says {each} {text.count(each)} times, and {reaches.count(each)} calls went through it')

    sources = json.loads((root / 'tests/module-map.json').read_text())['ports']['DICOMIngesting']['sources']
    if sorted({entry['source'] for entry in presets.values()}) != sorted(sources):
        fail('the sources of the presets are not those of the module map')

    # --- what the options do -----------------------------------------------------
    def behaviour(label, read, importer):
        (folder / label).mkdir()
        source = probe_source(read(importer), read('Horos/Sources/DicomDatabase+Maintenance.swift'))
        # The indexer reads the preferences through the catalog of IsiXPreferences.
        (folder / label / 'probe.swift').write_text('import IsiXPreferences\n' + source)
        (folder / label / 'main.swift').write_text(harness_defaults.SWIFT + DRIVER)
        return swiftc(f'{label}-tool', [folder / label / 'probe.swift', folder / label / 'main.swift'], '-swift-version', '5',
                      *isix_modules.module_flags('IsiXPreferences', folder / 'internal'))

    def run(tool, cases):
        path = folder / 'cases.json'
        path.write_text(json.dumps({name: {key: value for key, value in options.items() if key != 'dicomOnly'}
                                    for name, options in cases.items()}))
        ran = subprocess.run([str(tool), str(path)], capture_output=True, timeout=60)
        if ran.returncode != 0:
            print('FAIL: the probe did not run\n' + ran.stderr.decode()[-2000:])
            sys.exit(1)
        return json.loads(ran.stdout)

    before = run(behaviour('before', lambda path: shown(revision, path), 'Horos/Sources/DicomDatabase+Import.swift'), asked)
    after = run(behaviour('after', lambda path: (root / path).read_text(encoding='utf-8'), 'Horos/Sources/DicomFileIndexer.swift'),
                {name: option_values(name) for name in presets})
    for name in sorted(presets):
        if before.get(name) != after.get(name):
            fail(f'preset {name}: the revision before stored or told {before.get(name)}, the checkout {after.get(name)}')

    # The probe tells the options apart, or the comparison above says nothing.
    distinct = {json.dumps(result, sort_keys=True) for result in after.values()}
    if len(distinct) < 6:
        fail(f'the probe gives {len(distinct)} different results over {len(after)} presets: it does not see the options')
    if not any(result['routed'] for result in after.values()) or all(result['routed'] for result in after.values()):
        fail('the autorouting does not depend on the options in the probe')
    if not any(result['importedFile'] != 'nil' and result['importedFile'] is not None for result in after.values()):
        fail('no preset stores importedFile in the probe')

if failures:
    sys.exit(1)
print(f'PASS: {len(presets)} presets; every call of addFiles and addFilesDescribed of {revision} names its preset, and each '
      f'stores importedFile, generatedByOsiriX, comments, state and key frames, tells the same notifications and routes as that '
      f'call did ({len(distinct)} different outcomes); {len(UNLISTED)} files of forwarders left out with their reason')

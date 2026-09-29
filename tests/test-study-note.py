#!/usr/bin/env python3
"""The note of a study: model 2.6, the upgrade from 2.5, the editor and its toolbar item (#897).

The note is the optional `note` attribute of the Study entity, new in model
2.6. The model source became the XML one Xcode writes today; the 2.5 source is
kept, unchanged, as OsiriXDB_Previous_DataModel2.5.xcdatamodel, which the
build compiles into the OsiriXDB_Previous_DataModel2.5.mom that
-upgradeSqlFileFromModelVersion: opens an index of 2.5 with.

Checked here:

1. the current model is the 2.5 one with only Study.note added (optional
   String), and the 2.5 source compiles to the model a 2.5 index is of;
2. a real SQLite index of model 2.5 - studies with their comments, status,
   report and lock, series, images and albums, among them two of the same name
   - is upgraded by -upgradeSqlFileFromModelVersion: itself, compiled from the
   source with xcrun swiftc around a stand-in of the database: the new index
   opens with the 2.6 model, keeps every study attribute, series, image and
   album membership, and has no note; no Database.sql-wal or -shm of the
   former index is left beside the new one;
3. a note written through HorosStudyNote is saved, is there once the index is
   closed and opened again, is removed when only white space is left, and is
   found by the All Fields search of the browser;
4. the «Note» item of the 2D viewer's toolbar, its menu item, the shared
   database key and the version the database writes.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs (#803)
from sources import source_text  # noqa: E402

root = Path(__file__).resolve().parents[1]
failures = []
MODEL = root / 'Horos/Models/OsiriXDB_DataModel.xcdatamodeld'
FORMER = root / 'Horos/Models/OsiriXDB_Previous_DataModel2.5.xcdatamodel'


def require(condition, message):
    if not condition:
        failures.append(message)


# --- 4. what the application declares -----------------------------------------
database = (root / 'Horos/Sources/DicomDatabase.mm').read_bytes().decode('latin1')
version = re.search(r'NSString\* const CurrentDatabaseVersion = @"([^"]+)"', database)
require(version and version.group(1) == '2.6', 'CurrentDatabaseVersion is not 2.6')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
for name, kind in (('OsiriXDB_Previous_DataModel2.5.xcdatamodel', 'wrapper.xcdatamodel'), ('StudyNoteEditor.swift', 'sourcecode.swift')):
    reference = re.search(r'(\w{24}) /\* %s \*/ = \{isa = PBXFileReference; lastKnownFileType = %s;' % (re.escape(name), re.escape(kind)), project)
    require(reference, '%s has no file reference' % name)
    if reference:
        build = re.search(r'(\w{24}) /\* %s in Sources \*/ = \{isa = PBXBuildFile; fileRef = %s ' % (re.escape(name), reference.group(1)), project)
        require(build and project.count(build.group(1)) >= 2, '%s is not compiled by the Sources phase' % name)
require((FORMER / 'elements').is_file(), 'the 2.5 model source is not kept')
require((MODEL / 'OsiriXDB_DataModel.xcdatamodel/contents').is_file(), 'the current model is not the XML source')

toolbar = source_text('ViewerController+Toolbar')
identifier = re.search(r'fileprivate let (\w+) = "StudyNote"', toolbar)
require(identifier, 'the toolbar has no StudyNote identifier')
if identifier:
    name = identifier.group(1)
    allowed = toolbar[toolbar.find('func toolbarAllowedItemIdentifiers'):]
    allowed = allowed[:allowed.find('])')]
    default = toolbar[toolbar.find('func toolbarDefaultItemIdentifiers'):]
    default = default[:default.find('].map')]
    require(name in allowed, 'the Note item is not among the allowed items of the 2D viewer')
    require(name not in default, 'the Note item is among the default items of the 2D viewer')
    branch = toolbar[toolbar.find('itemIdent == %s {' % name):]
    branch = branch[:branch.find('} else if')]
    require('systemSymbolName: "note.text"' in branch, 'the Note item has no image of its own')
    require('#selector(ViewerController.showStudyNoteEditor(_:))' in branch, 'the Note item does not open the note editor')
    require('"Display the Note Editor"' in branch, 'the Note item has not the tooltip of the issue')
for language in ('en', 'es', 'it-IT', 'ja-JP'):
    menu = (root / f'Horos/Resources/{language}.lproj/MainMenu.xib').read_text()
    require('<action selector="showStudyNoteEditor:" target="-1"' in menu, f'the {language} 2D Viewer menu has no Note item')
    require(re.search(r'<tableColumn identifier="note" [^>]*hidden="YES"', menu), f'the {language} browser has no hidden Note column')
editor = source_text('StudyNoteEditor')
require('@objc(showStudyNoteEditor:)' in editor, 'the viewer has no -showStudyNoteEditor:')
shared = source_text('SharedDatabaseRequests')
require('"note": .text' in shared, 'a client of a shared database cannot set the note')
require('- (NSString*) note' in source_text('DCMTKStudyQueryNode'), 'a study of a DICOM node answers no note to the search and the sort')

# --- 1-3. the models and the upgrade, against real stores ---------------------
other = source_text('DicomDatabase+Other')
helpers_start = other.find('/// The attributes that the former upgrade copied')
helpers_end = other.find('public extension DicomDatabase {')
method_start = other.find('    @objc(upgradeSqlFileFromModelVersion:)')
method_end = other.find('    @objc(', method_start + 1)
note_start = editor.find('@objc(HorosStudyNote)\n')
note_end = editor.find('@objc(HorosStudyNoteEditor)')
plugins = source_text('BrowserController+Plugins')
filter_start = plugins.find('    @objc(createFilterPredicate)')
filter_end = plugins.find('    @objc(databaseSelection)', filter_start)
require(min(helpers_start, helpers_end, method_start, method_end, note_start, note_end, filter_start, filter_end) >= 0,
        'the upgrade, HorosStudyNote or -createFilterPredicate are not where this test reads them')

DOUBLES = r'''
import AppKit
import CoreData

let NSAlertDefaultReturn = 1
let NSAlertAlternateReturn = 0
var alerts: [String] = []
var logged: [String] = []

enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? { body(); return nil }
    static func log(_ exception: NSException, stack: Bool, _ function: String) { logged.append("\(exception)") }
    static func logError(_ message: String?, _ function: String) { logged.append(message ?? "") }
    static func arg(_ object: Any?) -> CVarArg { return (object as? NSObject) ?? ("(null)" as NSString) }
    static func isEqual(_ string: String?, _ other: String?) -> Bool {
        guard let string, let other else { return false }
        return (string as NSString).isEqual(to: other)
    }
    static func appending(_ path: String?, _ component: String) -> String? { return (path as NSString?)?.appendingPathComponent(component) }
    static func fileExists(_ path: String?) -> Bool { return path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    static func set(_ object: AnyObject?, _ key: String) -> NSSet? { return object?.value(forKey: key) as? NSSet }
}

enum HorosAlertPanel {
    @discardableResult
    static func run(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alerts.append(message)
        return NSAlertDefaultReturn
    }
}

extension Thread {
    func enterOperation() {}
    func exitOperation() {}
    var status: String? { get { nil } set {} }
    var progress: CGFloat { get { 0 } set {} }
}

extension NSException {
    @discardableResult func printStackTrace() -> String { return "" }
}

let CurrentDatabaseVersion = "VERSION"

/// The database around -upgradeSqlFileFromModelVersion:.
final class DicomDatabase: NSObject {
    var baseDirPath: String!
    var sqlFilePath: String!
    var managedObjectModel: NSManagedObjectModel!
    var rebuilt = false
    init(base: String, model: NSManagedObjectModel) {
        baseDirPath = base
        sqlFilePath = (base as NSString).appendingPathComponent("Database.sql")
        managedObjectModel = model
    }
    func loadingFilePath() -> String? { return nil }
    func rebuild(_ complete: Bool) { rebuilt = true }
}

final class BrowserFixture: NSObject {
    var horos_searchString: String?
    var horos_searchType = 0
    func patientsnamePredicate(_ s: String!) -> NSPredicate! { return NSPredicate(format: "name CONTAINS[cd] %@", s) }
FILTER
}
'''

DRIVER = r'''
import AppKit
import CoreData

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

let arguments = CommandLine.arguments
let current = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[1]))!
let former = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[2]))!
let folder = arguments[3]

// --- 1. the models ----------------------------------------------------------
func describe(_ p: NSPropertyDescription) -> String {
    var s = "\(p.name) optional=\(p.isOptional) transient=\(p.isTransient) indexed=\(p.isIndexed)"
    if let a = p as? NSAttributeDescription { s += " type=\(a.attributeType.rawValue) default=\(String(describing: a.defaultValue))" }
    if let r = p as? NSRelationshipDescription {
        s += " to=\(r.destinationEntity?.name ?? "") inverse=\(r.inverseRelationship?.name ?? "") min=\(r.minCount) max=\(r.maxCount) delete=\(r.deleteRule.rawValue)"
    }
    return s
}
var added: [String] = [], lost: [String] = [], changed: [String] = []
for entity in current.entities {
    guard let before = former.entitiesByName[entity.name!] else { added.append(entity.name!); continue }
    if entity.managedObjectClassName != before.managedObjectClassName { changed.append("\(entity.name!) class") }
    for p in entity.properties {
        if let q = before.propertiesByName[p.name] {
            if describe(p) != describe(q) { changed.append("\(entity.name!).\(describe(p)) was \(describe(q))") }
        } else { added.append("\(entity.name!).\(describe(p))") }
    }
    for p in before.properties where entity.propertiesByName[p.name] == nil { lost.append("\(entity.name!).\(p.name)") }
    if entity.name != "Study" && entity.versionHash != before.versionHash { changed.append("\(entity.name!) version hash") }
}
for entity in former.entities where current.entitiesByName[entity.name!] == nil { lost.append(entity.name!) }
emit("model.added", added.sorted().joined(separator: ";"))
emit("model.lost", lost.sorted().joined(separator: ";"))
emit("model.changed", changed.sorted().joined(separator: ";"))

// --- 2. an index of 2.5, upgraded --------------------------------------------
func value(_ attribute: NSAttributeDescription, _ n: Int) -> Any? {
    switch attribute.attributeType {
    case .stringAttributeType: return "\(attribute.entity.name!).\(attribute.name).\(n) é"
    case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: return NSNumber(value: n + 2)
    case .booleanAttributeType: return NSNumber(value: n % 2 == 0)
    case .floatAttributeType, .doubleAttributeType: return NSNumber(value: Double(n) + 0.5)
    case .dateAttributeType: return Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(n))
    case .binaryDataAttributeType: return Data([UInt8(n), 1, 2, 3])
    default: return nil
    }
}
func fill(_ object: NSManagedObject, _ n: Int) {
    for (name, attribute) in object.entity.attributesByName where !attribute.isTransient {
        object.setValue(value(attribute, n), forKey: name)
    }
}

let base = (folder as NSString).appendingPathComponent("Horos Data")
try! FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
let indexURL = URL(fileURLWithPath: (base as NSString).appendingPathComponent("Database.sql"))
var originals: [String: [String: Any]] = [:] // study UID -> attributes, series and images
do {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: former)
    let store = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: indexURL,
                                                    options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        var studies: [NSManagedObject] = []
        for n in 0..<3 {
            let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
            fill(study, n)
            study.setValue("1.2.826.0.1.\(n)", forKey: "studyInstanceUID")
            study.setValue(NSNumber(value: n + 1), forKey: "stateText")
            for s in 0..<2 {
                let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
                fill(series, 10 * n + s)
                series.setValue(study, forKey: "study")
                for i in 0..<2 {
                    let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
                    fill(image, 100 * n + 10 * s + i)
                    image.setValue(series, forKey: "series")
                }
            }
            studies.append(study)
        }
        func album(_ name: String, _ members: [NSManagedObject], smart: String? = nil) {
            let a = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
            a.setValue(name, forKey: "name")
            a.setValue(smart != nil, forKey: "smartAlbum")
            a.setValue(smart, forKey: "predicateString")
            a.mutableSetValue(forKey: "studies").addObjects(from: members)
        }
        album("Teaching", [studies[0], studies[1]])
        album("Same", [studies[0]])
        album("Same", [studies[2]])
        album("Today CT", [], smart: "(modality CONTAINS[cd] 'CT')")
        try! context.save()
        for study in studies {
            var entry: [String: Any] = [:]
            for name in study.entity.attributesByName.keys { entry[name] = study.value(forKey: name) ?? NSNull() }
            entry["~series"] = ((study.value(forKey: "series") as! NSSet).allObjects as! [NSManagedObject]).map { s -> String in
                let images = ((s.value(forKey: "images") as! NSSet).allObjects as! [NSManagedObject]).map { i in
                    i.entity.attributesByName.keys.filter { !upgradeImageSkippedKeys.contains($0) && !i.entity.attributesByName[$0]!.isTransient }
                        .sorted().map { "\($0)=\(i.value(forKey: $0) ?? "nil")" }.joined(separator: ",")
                }.sorted()
                return s.entity.attributesByName.keys.filter { !upgradeSeriesSkippedKeys.contains($0) }.sorted()
                    .map { "\($0)=\(s.value(forKey: $0) ?? "nil")" }.joined(separator: ",") + images.joined(separator: "|")
            }.sorted()
            entry["~albums"] = ((study.value(forKey: "albums") as! NSSet).allObjects as! [NSManagedObject])
                .map { $0.value(forKey: "name") as! String }.sorted()
            originals[study.value(forKey: "studyInstanceUID") as! String] = entry
        }
    }
    try! coordinator.remove(store)
}

let database = DicomDatabase(base: base, model: current)
let upgraded = database.upgradeSqlFile(fromModelVersion: "2.5")
emit("upgrade.result", "\(upgraded)")
emit("upgrade.rebuilt", "\(database.rebuilt)")
emit("upgrade.alerts", alerts.joined(separator: ";"))
emit("upgrade.logged", logged.joined(separator: ";"))
emit("upgrade.files", ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted().joined(separator: ","))

/// The index opened as the database opens it once upgraded: with the current
/// model, without any migration.
func open(_ model: NSManagedObjectModel) -> (NSPersistentStoreCoordinator, NSPersistentStore, NSManagedObjectContext)? {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    guard let store = try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: indexURL,
                                                          options: [NSSQLitePragmasOption: ["journal_mode": "delete"]]) else { return nil }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return (coordinator, store, context)
}
emit("open.former", open(former) == nil ? "refused" : "opened")
func studies(_ context: NSManagedObjectContext) -> [NSManagedObject] {
    let request = NSFetchRequest<NSManagedObject>(entityName: "Study")
    request.sortDescriptors = [NSSortDescriptor(key: "studyInstanceUID", ascending: true)]
    return try! context.fetch(request)
}
if let (coordinator, store, context) = open(current) {
    context.performAndWait {
        let found = studies(context)
        emit("upgraded.studies", "\(found.count)")
        var differences: [String] = []
        for study in found {
            guard let uid = study.value(forKey: "studyInstanceUID") as? String, let entry = originals[uid] else { differences.append("unknown study"); continue }
            for (name, before) in entry where !name.hasPrefix("~") {
                let after = study.value(forKey: name) ?? NSNull()
                if !(after as AnyObject).isEqual(before) { differences.append("\(uid).\(name): \(after) was \(before)") }
            }
            let series = ((study.value(forKey: "series") as! NSSet).allObjects as! [NSManagedObject]).map { s -> String in
                let images = ((s.value(forKey: "images") as! NSSet).allObjects as! [NSManagedObject]).map { i in
                    i.entity.attributesByName.keys.filter { !upgradeImageSkippedKeys.contains($0) && !i.entity.attributesByName[$0]!.isTransient }
                        .sorted().map { "\($0)=\(i.value(forKey: $0) ?? "nil")" }.joined(separator: ",")
                }.sorted()
                return s.entity.attributesByName.keys.filter { !upgradeSeriesSkippedKeys.contains($0) }.sorted()
                    .map { "\($0)=\(s.value(forKey: $0) ?? "nil")" }.joined(separator: ",") + images.joined(separator: "|")
            }.sorted()
            if series != entry["~series"] as! [String] { differences.append("\(uid) series or images") }
            let albums = ((study.value(forKey: "albums") as! NSSet).allObjects as! [NSManagedObject]).map { $0.value(forKey: "name") as! String }.sorted()
            if albums != entry["~albums"] as! [String] { differences.append("\(uid) albums \(albums)") }
            if study.value(forKey: "note") != nil { differences.append("\(uid) has a note") }
        }
        emit("upgraded.differences", differences.joined(separator: ";"))
        let albums = try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Album"))
        emit("upgraded.albums", albums.map { a -> String in
            let smart = (a.value(forKey: "smartAlbum") as! NSNumber).boolValue ? "*" + (a.value(forKey: "predicateString") as! String) : ""
            return "\(a.value(forKey: "name")!)\(smart)[\((a.value(forKey: "studies") as! NSSet).count)]"
        }.sorted().joined(separator: ","))

        // --- 3. the note, written and read back ---------------------------------
        let first = found[0], second = found[1]
        emit("note.empty", StudyNote.text(of: first).isEmpty ? "empty" : "not empty")
        emit("note.set", "\(StudyNote.setText("Follow-up in 6 months.\nCompare with the prior CT.", of: first))")
        emit("note.again", "\(StudyNote.setText("Follow-up in 6 months.\nCompare with the prior CT.", of: first))")
        StudyNote.setText("temporary", of: second)
        emit("note.blank", "\(StudyNote.setText("  \n\t ", of: second)) \(String(describing: second.value(forKey: "note")))")
        emit("note.line", StudyNote.singleLineText(of: first.value(forKey: "note") as? String) ?? "nil")
        try! context.save()
    }
    try! coordinator.remove(store)
} else {
    emit("upgraded.studies", "the upgraded index does not open with the current model")
}

if let (coordinator, store, context) = open(current) {
    context.performAndWait {
        let found = studies(context)
        emit("reopened.notes", found.map { StudyNote.text(of: $0).replacingOccurrences(of: "\n", with: "\\n") }.joined(separator: "|"))
        let browser = BrowserFixture()
        browser.horos_searchType = 7 // All Fields
        for term in ["prior ct", "Follow-up in"] {
            browser.horos_searchString = term
            let request = NSFetchRequest<NSManagedObject>(entityName: "Study")
            request.predicate = browser.createFilterPredicate()
            let hits = (try? context.fetch(request)) ?? []
            emit("search.\(term)", hits.map { $0.value(forKey: "studyInstanceUID") as! String }.joined(separator: ","))
        }
    }
    try! coordinator.remove(store)
}

// --- 4. the image of the toolbar item ------------------------------------------
emit("symbol", NSImage(systemSymbolName: "note.text", accessibilityDescription: nil) == nil ? "missing" : "present")
'''

results = {}
if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-study-note-') as directory:
        directory = Path(directory)
        sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
        compiled = [subprocess.run(['xcrun', 'momc', f'--sdkroot={sdk}', '--macosx-deployment-target=26.0', str(source), str(directory)],
                                   capture_output=True, text=True) for source in (MODEL, FORMER)]
        momd = directory / 'OsiriXDB_DataModel.momd'
        mom = directory / 'OsiriXDB_Previous_DataModel2.5.mom'
        if any(c.returncode != 0 for c in compiled) or not momd.exists() or not mom.exists():
            failures.append('the models do not compile with momc:\n%s' % ''.join(c.stderr for c in compiled)[-1500:])
        else:
            helpers = other[helpers_start:helpers_end].replace('private let ', 'let ').replace('private func ', 'func ')
            (directory / 'doubles.swift').write_text(DOUBLES.replace('VERSION', version.group(1))
                                                     .replace('FILTER', plugins[filter_start:filter_end]))
            (directory / 'upgrade.swift').write_text('import AppKit\nimport CoreData\n\n' + helpers + '\nextension DicomDatabase {\n'
                                                     + other[method_start:method_end] + '\n}\n')
            (directory / 'note.swift').write_text('import Foundation\nimport CoreData\n\n' + editor[note_start:note_end])
            (directory / 'main.swift').write_text(DRIVER)
            # Bundle.main of a tool is its folder: the former model is looked for there.
            binary = directory / 'study-note'
            built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-suppress-warnings', '-o', str(binary),
                                    *(str(directory / f) for f in ('doubles.swift', 'upgrade.swift', 'note.swift', 'main.swift'))],
                                   capture_output=True, text=True)
            if built.returncode != 0:
                failures.append('the upgrade and the note do not compile:\n%s' % built.stderr[-2500:])
            else:
                run = subprocess.run([str(binary), str(momd), str(mom), str(directory)], capture_output=True, text=True, cwd=directory)
                if run.returncode != 0:
                    failures.append('the driver failed: %s' % (run.stderr or run.stdout)[-1500:])
                for line in run.stdout.splitlines():
                    key, _, value = line.partition('\t')
                    results[key] = value

if results:
    expected = {
        'model.added': 'Study.note optional=true transient=false indexed=false type=700 default=nil',
        'model.lost': '',
        'model.changed': '',
        'upgrade.result': 'true',
        'upgrade.rebuilt': 'false',
        'upgrade.alerts': '',
        'upgrade.logged': '',
        'upgrade.files': 'Database-Old-PreviousVersion.sql,Database.sql',
        'open.former': 'refused',
        'upgraded.studies': '3',
        'upgraded.differences': '',
        'upgraded.albums': 'Same[1],Same[1],Teaching[2],Today CT*(modality CONTAINS[cd] \'CT\')[0]',
        'note.empty': 'empty',
        'note.set': 'true',
        'note.again': 'false',
        'note.blank': 'true nil',
        'note.line': 'Follow-up in 6 months. Compare with the prior CT.',
        'reopened.notes': 'Follow-up in 6 months.\\nCompare with the prior CT.||',
        'search.prior ct': '1.2.826.0.1.0',
        'search.Follow-up in': '1.2.826.0.1.0',
        'symbol': 'present',
    }
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))

if failures:
    print('FAIL: ' + '\n'.join(failures))
    sys.exit(1)
print('PASS: model 2.6 is 2.5 plus Study.note; a real 2.5 index is upgraded with its studies, series, images and albums and '
      'no note; the note is saved, read back after reopening, cleared when blank and found by All Fields; toolbar, menu, '
      'column, shared key and version in place')

#!/usr/bin/env python3
"""A rebuild that stops says why, even when the save gave no error.

-rebuild: stops with a DatabaseRebuildFailure exception whose userInfo named
the underlying error as @{NSUnderlyingErrorKey: error}. A save can fail
without returning an error, and then the literal itself raised, for inserting
nil: the exception that reached the person was about a dictionary, not about
the database. The key is now left out when there is no error, and the reason
is never nil. The count of files it summed and never read is gone too.

The helper runs compiled from the source with xcrun swiftc; where the rebuild
uses it is read from the source. `<git revision>` as an optional argument reads
the sources of that revision, the negative control.

The rebuild itself (DatabaseRebuildService), with its database a stand-in over a
real SQLite store and with the real recovery snapshot and the real sqlite3, is
compiled from the checkout and from the revision before it left DicomDatabase,
and both run the same scenarios: they leave the same studies, series and images,
keep or set aside the same files, and say the same. While a rebuild runs the
import of the INCOMING folder waits, in the two ways it asks for the lock; a
rebuild that stops leaves the index as it was, and the lock free.

A rebuild that keeps the index changed on purpose after that revision, so what it
leaves is not compared with it (kept.Study, kept.Series, kept.studies): the study
whose files are gone used to stay, empty, for noFiles answers the count it stored,
and a study with no files that an album kept used to go. The stand-in's noFiles
answers the stored count as the real one does, and leaves documents out as it does.
The scenario kept-cleanup, on an index with albums, runs on the two and has to
differ: it is what shows the test still bites. A study that goes takes its files,
as the real classes do after the save: the file of an image inside the database
and the report. So the stand-ins do that too, and the files that have to stay are
looked for afterwards. A series that lost an image makes its thumbnail again, and
one whose files only went out of reach keeps it (kept-cleanup.thumbnails).

kept-cleanup-model runs on an index opened as the application opens it with the copy
of the model the database folder keeps: its coordinator has a merged model, another
instance than the database's. A fetch that takes its entity from the database's model
makes Core Data log, on stderr, that the entity is from another model; the rebuilds
must not, and the one fetch the driver does that way shows the log still reaches it.

The stand-in's addFiles asks ImportArrival what the real indexing asks, which is read
from the source, so kept-cleanup-dates compares dateAdded before and after a rebuild,
with a new image and a study sent again beside it. kept-cleanup-reports runs the real
DatabaseReportConsistency on a stand-in whose reportURL answers nil for a report
inside the database, as the real one does with no browser database, and whose archive
drops the link it cannot read. kept-cleanup-shared is an index in which records of
other images name the files of others, as an import that was given the number of a
file that was gone left them: each such record gets a number of its own before it
leaves, so that the file it named stays; the frames of a multiframe file and the
series of a file that is not DICOM stay, and so do the records of a file that does
not read, that raises, or that none of them is of. The study that had only that
record leaves or stays as any study left without images.

The rebuild of the SQL file changed on purpose after that revision, so the files
it leaves are not compared with it (sql.base, sql.recovery): the former index
goes to Index Backups and no longer to the Trash. A complete rebuild changed too:
it writes the current version where it deleted the file, once the former index
is retired, so the folders of those scenarios and the versions are not compared
either, and the versions are expected here. Everything about a refused
index runs in the checkout only, on stores that are damaged for real, page by
page, with the real sqlite3: a mid-file leaf, the last leaf, the interior page of
a table, the pages of the tables of albums, a truncated file, text with
dot-commands, and crafted schemas that come out of .dump as commands. The same
crafted file with no options runs its command here, so that a test that stopped
biting would say so. The complete rebuild the refusal points to then runs on
those same stores, and gets past them.

sqlite3 runs in a process group of its own and outlives the rebuild that started
it: the crafted index that would fill the disk wrote without end once the helper
was killed (a run stopped kills the test's group). The rebuild starts it under
the kernel's limits of its run (IndexRepairRules.boundedLaunch, checked here),
and the test's folders have a reaper in a session of its own: once the test has
ended, however it ended, it kills what still names them and removes them.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from isix_modules import module_flags, revision_before  # noqa: E402
import sources  # noqa: E402

# Started by the test in a session of its own, so that what stops the test's
# process group does not reach it: once the test has ended, the processes that
# still name its folders (an orphaned sqlite3 of the rebuild, in a group of its
# own) are killed and the folders removed. It gives up after two hours.
REAPER = r"""
import os, shutil, signal, subprocess, sys, time
test, folders = int(sys.argv[1]), sys.argv[2:]
deadline = time.monotonic() + 7200


def alive():
    try:
        os.kill(test, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


while alive() and time.monotonic() < deadline:
    time.sleep(0.5)
for attempt in range(3):
    listed = subprocess.run(['ps', '-axww', '-o', 'pid=,command='], capture_output=True, text=True).stdout
    pids = [int(line.split(None, 1)[0]) for line in listed.splitlines()
            if any(folder in line for folder in folders) and int(line.split(None, 1)[0]) != os.getpid()]
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    if not pids:
        break
    time.sleep(0.2)
for folder in folders:
    shutil.rmtree(folder, ignore_errors=True)
"""


def reaped(directory):
    """`directory`, removed with what still names it once this test has ended."""
    subprocess.Popen([sys.executable, '-I', '-c', REAPER, str(os.getpid()), str(directory)], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return directory

revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
SKIPPED = 2
SOURCE = 'Horos/Sources/DatabaseRebuildService.swift'
# Where the rebuild was until it left DicomDatabase.
FORMER_SOURCE = 'Horos/Sources/DicomDatabase+Other.swift'
FORWARDERS = 'Horos/Sources/DicomDatabase+Maintenance.swift'
# The Objective-C half of DicomDatabase: +SwiftIvars.m before the class moved
# to Swift, +CAPI.m after.
BRIDGES = ('Horos/Sources/DicomDatabase+CAPI.m', 'Horos/Sources/DicomDatabase+SwiftIvars.m')


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'], stderr=subprocess.DEVNULL).decode('utf-8')
    return (root / path).read_text()


def read_source():
    for path in (SOURCE, FORMER_SOURCE):
        try:
            return read(path)
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
    raise SystemExit('FAIL: neither %s nor %s exists' % (SOURCE, FORMER_SOURCE))


text = read_source()


def read_bridge():
    for path in BRIDGES:
        try:
            return read(path)
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
    raise SystemExit('FAIL: neither %s exists' % ' nor '.join(BRIDGES))


bridge = read_bridge()
if 'func rebuild(complete: Bool)' in text:
    start = text.find('func rebuild(complete: Bool)')
    end = text.find('    // MARK: The SQL file', start)
else:
    start = text.find('@objc(rebuild:)')
    end = text.find('@objc(', start + 1)
rebuild = text[start:end] if start >= 0 and end > start else ''
if not rebuild:
    failures.append('-rebuild: is not in %s' % SOURCE)

match = re.search(r'^private func rebuildFailure\(.*?^}\n', text, re.S | re.M)
helper = match.group(0) if match else None
if helper is None:
    failures.append('there is no rebuild failure that tolerates a missing error')
if 'NSUnderlyingErrorKey: error}' in bridge:
    failures.append('the Objective-C literal that raises for a nil error is still there')
if 'DicomDatabaseRebuildFailure(' in rebuild:
    failures.append('-rebuild: still builds its exception with the literal that raises for a nil error')
raised = re.findall(r'NSException\(name: NSExceptionName\("DatabaseRebuildFailure"\)[^\n]*', rebuild)
for line in raised:
    if 'NSUnderlyingErrorKey' in line:
        failures.append('-rebuild: builds its own underlying error key: %s' % line.strip())
if rebuild.count('rebuildFailure(') < 5:
    failures.append('not every stop of -rebuild: with an error goes through the tolerant exception '
                    '(%d of 5)' % rebuild.count('rebuildFailure('))
if 'totalFiles' in rebuild:
    failures.append('-rebuild: still sums a count of files that nothing reads')

if not revision:
    # A modal loop inside a block of the main queue stops that queue until it is
    # answered, and a main-queue context waits on it.
    if 'DispatchQueue.main' in text or 'Task {' in text:
        failures.append('an alert of the rebuild comes from the main queue or a task, not from the main run loop')
    # sqlite3 outlives the app in a group of its own: the kernel holds it to the run's limits.
    if 'IndexRepairRules.boundedLaunch(of: arguments, limit: limit)' not in text or '"/usr/bin/sqlite3"' in text:
        failures.append('sqlite3 is not started under the kernel limits of IndexRepairRules.boundedLaunch')
    maintenance = (root / 'Horos/Sources/BrowserController+DatabaseMaintenance.swift').read_text()
    if 'Thread(target:' in maintenance:
        failures.append('the browser still starts its maintenance threads by selector')
    for direct in ('.rebuild(complete)', '.rebuildSqlFile()', '.rebuildAllowed()'):
        if direct in maintenance:
            failures.append('the browser still reaches %s of the database and not the port' % direct)
    for consumer in ('Horos/Sources/AppController.swift', 'Horos/Sources/QTExportHTMLSummary.swift'):
        if '.checkForHtmlTemplates()' in (root / consumer).read_text():
            failures.append('%s still asks the database for the templates and not the installer' % consumer)
    if '.checkReportsConsistencyWithDICOMSR()' in (root / 'Horos/Sources/StudyReports.swift').read_text():
        failures.append('the browser still reaches the consistency of the reports of the database and not the port')

DRIVER = '''
import Foundation

func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }

let silent = rebuildFailure(nil)
emit("silent.name", silent.name.rawValue)
emit("silent.reason", silent.reason ?? "<nil>")
emit("silent.key", silent.userInfo?[NSUnderlyingErrorKey] == nil ? "absent" : "present")

let cause = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
let named = rebuildFailure(cause)
emit("named.reason", named.reason == cause.localizedDescription ? "same" : named.reason ?? "<nil>")
emit("named.key", (named.userInfo?[NSUnderlyingErrorKey] as? NSError) === cause ? "cause" : "other")
'''

results = {}
if helper is not None:
    with tempfile.TemporaryDirectory(prefix='horos-rebuild-failure-') as directory:
        directory = reaped(Path(directory))
        # File-private in the app; the driver is another file.
        (directory / 'helper.swift').write_text('import Foundation\n\n' + helper.replace('private func ', 'func '))
        (directory / 'main.swift').write_text(DRIVER)
        binary = directory / 'rebuild-failure'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(directory / 'helper.swift'), str(directory / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the rebuild failure does not compile:\n%s' % built.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    expected = {'silent.name': 'DatabaseRebuildFailure', 'silent.key': 'absent',
                'named.reason': 'same', 'named.key': 'cause'}
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))
    if results.get('silent.reason') in (None, '', '<nil>'):
        failures.append('a save that failed without an error stops the rebuild with no reason')


# --- the rebuild itself, the same as before it left DicomDatabase --------------
TRY_HEADER = """#import <Foundation/Foundation.h>
NSException * _Nullable HarnessAttempt(void (NS_NOESCAPE ^ _Nonnull body)(void));
"""
TRY_SOURCE = """#import "try.h"
NSException *HarnessAttempt(void (NS_NOESCAPE ^body)(void)) {
    @try { body(); } @catch (NSException *exception) { return exception; }
    return nil;
}
"""

REBUILD_DOUBLES = r"""
import CoreData
import Foundation
import IsiXContracts
import IsiXDatabase

// The guards of HorosObjCException+Guards.swift, catching through HarnessAttempt.
enum HorosObjCException {
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? { HarnessAttempt(body) }
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
    static func attempt(_ body: () -> Void) -> NSException? { HarnessAttempt(body) }
    static func log(_ exception: NSException, stack: Bool, _ function: String) {}
    static func arg(_ object: Any?) -> CVarArg { return (object as? NSObject) ?? ("(null)" as NSString) }
    static func appending(_ path: String?, _ component: String) -> String? { return (path as NSString?)?.appendingPathComponent(component) }
    static func fileExists(_ path: String?) -> Bool { return path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    static func array(_ items: Any?...) -> NSArray { return items.compactMap { $0 } as NSArray }
}

/// The report of a study has its name.
enum Reports {
    static func getUniqueFilename(_ study: Any!) -> String! { return (study as? DicomStudy)?.studyInstanceUID }
    static func getOldUniqueFilename(_ study: NSManagedObject!) -> String! { return nil }
}

// Nitrogen's: an exception raised on the queue goes on outside it.
func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext?, _ block: () -> Void) {
    guard let context else { block(); return }
    var raised: NSException? = nil
    context.performAndWait { raised = HarnessAttempt(block) }
    raised?.raise()
}

extension Thread {
    var status: String? { get { nil } set {} }
}

let CurrentDatabaseVersion = "current"

extension Notification.Name {
    static let OsirixDatabaseObjectsMayBecomeUnavailable = Notification.Name("OsirixDatabaseObjectsMayBecomeUnavailable")
}

/// What the person is told: the application's alert, written down.
final class HarnessApplication {
    @discardableResult func presentError(_ error: Error) -> Bool {
        presented.append((error as NSError).localizedDescription)
        return true
    }
}
nonisolated(unsafe) let NSApp = HarnessApplication()
nonisolated(unsafe) var presented: [String] = []

/// Every index here is of the model the application expects.
struct DatabaseModelUpgrade {
    let database: DicomDatabase
    let processGraph: ProcessGraph
    var indexAwaitsUpgrade: Bool { return false }
}

final class ProcessGraph {
    static let process = ProcessGraph()
    var preferences: UserDefaults { .standard }
    var databaseIngest: DatabaseIngest { DatabaseIngest() }
}

/// As the real one: the files go to the database with the options of the preset.
struct DatabaseIngest {
    func index(_ paths: [Any]?, preset: IngestPreset, in database: DicomDatabase) {
        let options = preset.options
        _ = database.addFiles(atPaths: paths, postNotifications: options.postNotifications, dicomOnly: options.dicomOnly.resolved(preference: false),
                              rereadExistingItems: options.rereadExistingItems, generatedByOsiriX: options.generatedByOsiriX, returnArray: options.returnArray)
    }
    func admissionFolder(of database: DicomDatabase?) -> IngestFolder { return IngestFolder(path: database?.incomingDirPath() ?? "") }
}

func storedCount(_ object: NSManagedObject) -> Int { return Int(object.value(forKey: "numberOfImages") as? String ?? "") ?? 0 }
func withoutTheDeleted(_ objects: Any?) -> NSSet? {
    return (objects as? NSSet)?.filtered(using: NSPredicate { object, _ in !(object as! NSManagedObject).isDeleted }) as NSSet?
}

/// What the placeholders of the studies that left were told.
enum ExcludedSeries {
    static func forget(study: String, database: String) { forgotten.append(study) }
}
nonisolated(unsafe) var forgotten: [String] = []
/// What the real classes remove once the save went well.
nonisolated(unsafe) var removedAfterTheSave: [String] = []
/// The date an arrival writes.
nonisolated(unsafe) var harnessToday = "the day it came"

@objc(DicomImage) final class DicomImage: NSManagedObject {
    func completePath() -> String? { return value(forKey: "path") as? String }
    var series: DicomSeries? { return value(forKey: "series") as? DicomSeries }
    func inDatabaseFolder() -> NSNumber? { return NSNumber(value: completePath()?.contains(".noindex/") == true) }
    /// Of the index whose images are numbered files, harnessModel(numbered:).
    var pathNumber: NSNumber? { return value(forKey: "pathNumber") as? NSNumber }
    var compressedSopInstanceUID: Data? { return value(forKey: "compressedSopInstanceUID") as? Data }
    static func sopInstanceUIDEncode(_ uid: String!) -> Data! { return Data(uid.utf8) }
    /// As the real one: a numbered name is the file of that number, in the folder the image is in.
    func setPath(_ name: String!) {
        setValue(NSNumber(value: Int64((name as NSString).deletingPathExtension) ?? 0), forKey: "pathNumber")
        setValue(((completePath()! as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name), forKey: "path")
    }
    /// As the real one: the cascade of a study reaches this too.
    override func validateForDelete() throws {
        try super.validateForDelete()
        if inDatabaseFolder()?.boolValue == true, let path = completePath() { removedAfterTheSave.append(path) }
    }
}
/// A data file as the import reads it. One that starts with `uids:` holds a series
/// for each identifier after it, one that says `raises` makes the reader raise, as
/// the readers behind the import's guard may, and any other does not read.
final class DicomFile {
    private let identifiers: [String]
    init!(_ path: String!) {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if text == "raises" { NSException(name: .genericException, reason: "the reader raised", userInfo: nil).raise() }
        guard text.hasPrefix("uids:") else { return nil }
        identifiers = String(text.dropFirst(5)).components(separatedBy: ",")
    }
    func noOfSeries() -> Int { return identifiers.count }
    func dicomElements() -> NSMutableDictionary! {
        let elements = NSMutableDictionary()
        for (series, identifier) in identifiers.enumerated() { elements[series == 0 ? "SOPUID" : "SOPUID\(series)"] = identifier }
        return elements
    }
}
/// A series named -SR is a structured report the person can open, and one named
/// -OWN one of the application's own, which nothing shows: noFiles counts neither.
/// One named -KO is as a key object: nothing shows it, and noFiles counts it.
@objc(DicomSeries) final class DicomSeries: NSManagedObject {
    var study: DicomStudy? { return value(forKey: "study") as? DicomStudy }
    var name: String? { return value(forKey: "name") as? String }
    var id: NSNumber? { return (value(forKey: "id") as? String).flatMap { Int32($0) }.map { NSNumber(value: $0) } }
    var modality: String? { return value(forKey: "modality") as? String }
    var numberOfImages: NSNumber? {
        get { return NSNumber(value: storedCount(self)) }
        set { setValue(newValue?.stringValue, forKey: "numberOfImages") }
    }
    var thumbnail: Data? {
        get { return (value(forKey: "thumbnail") as? String)?.data(using: .utf8) }
        set { setValue(newValue.map { String(decoding: $0, as: UTF8.self) }, forKey: "thumbnail") }
    }
    /// As the real one: without the images deleted in the context.
    var images: NSSet? { return withoutTheDeleted(value(forKey: "images")) }
    var isDocument: Bool { return name?.hasSuffix("-SR") == true || name?.hasSuffix("-OWN") == true }
    var isShown: Bool { return name != "OsiriX No Autodeletion" && name?.hasSuffix("-OWN") != true && name?.hasSuffix("-KO") != true }
    /// As the real one: the count it stored while it has one, and otherwise what
    /// it has, which it stores.
    func noFiles() -> NSNumber? {
        let stored = storedCount(self)
        if stored != 0 { return NSNumber(value: abs(stored)) }
        if isDocument { return NSNumber(value: 0) }
        let images = self.images?.count ?? 0
        setValue(String(images), forKey: "numberOfImages")
        return NSNumber(value: images)
    }
}
@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    /// As the real one: without the series deleted in the context.
    var series: NSSet? { return withoutTheDeleted(value(forKey: "series")) }
    var studyInstanceUID: String? { return value(forKey: "name") as? String }
    var lockedStudy: NSNumber? { return NSNumber(value: value(forKey: "lockedStudy") != nil) }
    /// As the real one during a rebuild, when the browser has no database: the
    /// path of a report inside the database reads as nil.
    var reportURL: String? { return (value(forKey: "reportURL") as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } }
    /// As the real one: a report it cannot read is one that was deleted.
    func archiveReportAsDICOMSR() {
        if reportURL.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true { setValue(nil, forKey: "reportURL") }
    }
    /// As the real one: the report goes with its study.
    override func validateForDelete() throws {
        try super.validateForDelete()
        if let path = reportURL { removedAfterTheSave.append(path) }
    }
    var numberOfImages: NSNumber? {
        get { return NSNumber(value: storedCount(self)) }
        set { setValue(newValue?.stringValue, forKey: "numberOfImages") }
    }
    var modality: String? {
        get { return value(forKey: "modality") as? String }
        set { setValue(newValue, forKey: "modality") }
    }
    private var allSeries: [DicomSeries] { return (series?.allObjects ?? []).compactMap { $0 as? DicomSeries } }
    func modalities() -> String? { return allSeries.filter(\.isShown).compactMap(\.modality).sorted().joined(separator: "\\") }
    func numberOfImageSeries() -> UInt { return UInt(allSeries.filter(\.isShown).count) }
    /// As the real one: the count it stored while it has one, and otherwise the
    /// sum of its series, without the documents, which it stores.
    func noFiles() -> NSNumber? {
        let stored = storedCount(self)
        if stored != 0 { return NSNumber(value: abs(stored)) }
        let images = allSeries.filter { !$0.isDocument }.reduce(0) { $0 + ($1.noFiles()?.intValue ?? 0) }
        setValue(String(images), forKey: "numberOfImages")
        return NSNumber(value: images)
    }
}

/// `albums`: with the entity of albums. The other scenarios have no such tables:
/// the repair ones make them by hand, in the store, to damage them.
func harnessModel(albums: Bool = false, numbered: Bool = false) -> NSManagedObjectModel {
    func attribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = true
        return attribute
    }
    func relationship(_ name: String, to destination: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
        let relationship = NSRelationshipDescription()
        relationship.name = name
        relationship.destinationEntity = destination
        relationship.minCount = 0
        relationship.maxCount = many ? 0 : 1
        relationship.isOptional = true
        relationship.deleteRule = many ? .cascadeDeleteRule : .nullifyDeleteRule
        return relationship
    }
    func entity(_ name: String, _ objectClass: String) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = objectClass
        return entity
    }
    let study = entity("Study", "DicomStudy"), series = entity("Series", "DicomSeries"), image = entity("Image", "DicomImage")
    let studySeries = relationship("series", to: series, many: true), seriesStudy = relationship("study", to: study, many: false)
    let seriesImages = relationship("images", to: image, many: true), imageSeries = relationship("series", to: series, many: false)
    studySeries.inverseRelationship = seriesStudy
    seriesStudy.inverseRelationship = studySeries
    seriesImages.inverseRelationship = imageSeries
    imageSeries.inverseRelationship = seriesImages
    study.properties = [attribute("name"), attribute("reportURL"), attribute("lockedStudy"), attribute("numberOfImages"), attribute("modality"), attribute("dateAdded"), studySeries]
    series.properties = [attribute("name"), attribute("id"), attribute("numberOfImages"), attribute("modality"), attribute("dateAdded"), attribute("thumbnail"), seriesStudy, seriesImages]
    image.properties = [attribute("path"), imageSeries]
    if numbered {
        // As the index names the files of the data folder, and the images in them.
        let number = attribute("pathNumber"), identifier = attribute("compressedSopInstanceUID")
        number.attributeType = .integer64AttributeType
        identifier.attributeType = .binaryDataAttributeType
        image.properties += [number, identifier]
    }
    var entities = [study, series, image]
    if albums {
        let album = entity("Album", "NSManagedObject")
        let albumStudies = relationship("studies", to: study, many: true), studyAlbums = relationship("albums", to: album, many: true)
        albumStudies.deleteRule = .nullifyDeleteRule
        studyAlbums.deleteRule = .nullifyDeleteRule
        albumStudies.inverseRelationship = studyAlbums
        studyAlbums.inverseRelationship = albumStudies
        album.properties = [attribute("name"), albumStudies]
        study.properties.append(studyAlbums)
        entities.insert(album, at: 0)
    }
    let model = NSManagedObjectModel()
    model.entities = entities
    return model
}

let sharedModel = harnessModel()
let modelWithAlbums = harnessModel(albums: true)
let numberedModel = harnessModel(numbered: true)

func albumsFileEntries(ofIndexAtPath path: String, models: [NSManagedObjectModel]) -> NSArray? {
    harnessAlbumsReadFrom = path
    return harnessAlbumsInCopy
}
nonisolated(unsafe) var harnessAlbumsReadFrom = ""
nonisolated(unsafe) var harnessAlbumsInCopy: NSArray? = ["read from the copy"]

class DicomDatabase: NSObject {
    var baseDirPath: String
    var sqlFilePath: String!
    var managedObjectContext: NSManagedObjectContext!
    var model = sharedModel
    var managedObjectModel: NSManagedObjectModel! { model }
    /// As an index with the copy of the model beside it opens: the coordinator has
    /// a model of its own, merged from the database's and the copy.
    var opensWithMergedModel = false
    var dataBaseDirPath: String! { baseDirPath }
    var importFilesFromIncomingDirLock: NSRecursiveLock? = NSRecursiveLock()
    /// What adds files directly waits here while the SQL file is replaced.
    let databaseWriterGate = DatabaseWriterGate()
    func isMainDatabase() -> Bool { true }
    func privateQueueIndependentContext() -> NSManagedObjectContext! { nil }

    var saveFails = false
    var albumsUnreadable = false
    var openFails = false
    var openRaises = false
    var onAddFiles: (() -> Void)? = nil
    var onSaveAlbums: (() -> Void)? = nil
    var onLastStep: (() -> Void)? = nil
    var restoredAlbums = "none"
    var defaultAlbumsCreated = false

    init(base: String) {
        baseDirPath = base
        sqlFilePath = (base as NSString).appendingPathComponent("Database.sql")
        super.init()
    }

    func dataDirPath() -> String! { return (baseDirPath as NSString).appendingPathComponent("DATABASE.noindex") }
    func incomingDirPath() -> String! { return (baseDirPath as NSString).appendingPathComponent("INCOMING.noindex") }
    func roisDirPath() -> String! { return (baseDirPath as NSString).appendingPathComponent("ROIs") }
    func reportsDirPath() -> String! { return (baseDirPath as NSString).appendingPathComponent("REPORTS") }
    func modelVersionFilePath() -> String! { return (baseDirPath as NSString).appendingPathComponent("DB_VERSION") }
    func rebuildAllowed() -> Bool { return true }
    /// As the real one: a number no file has, never given twice.
    var lastDataFileNumber = 9000
    func uniquePathForNewDataFile(withExtension fileExtension: String!) -> String! {
        lastDataFileNumber += 1
        return ((dataDirPath() as NSString).appendingPathComponent("1000") as NSString).appendingPathComponent("\(lastDataFileNumber).\(fileExtension!)")
    }
    func privateQueueIndependentDatabase() -> Any! { return self }

    func context(atPath path: String!) -> NSManagedObjectContext! {
        if openRaises { NSException(name: .genericException, reason: "the store does not open", userInfo: nil).raise() }
        if openFails { return nil }
        let opened = opensWithMergedModel ? NSManagedObjectModel(byMerging: [model, harnessModel(albums: model === modelWithAlbums)])! : model
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: opened)
        try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: path),
                                            options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    func performBlockAndWait(_ block: () -> Void) {
        N2ManagedObjectContextPerformAndWait(managedObjectContext, block)
    }

    func save(_ error: NSErrorPointer) -> Bool {
        if saveFails { return false }
        var saved = true
        managedObjectContext?.performAndWait { saved = (try? managedObjectContext.save()) != nil }
        if saved { removedAfterTheSave.forEach { try? FileManager.default.removeItem(atPath: $0) } }
        removedAfterTheSave = []
        return saved
    }

    func saveAlbums(toPath path: String!) {
        onSaveAlbums?()
        if managedObjectContext != nil && !albumsUnreadable { (["saved before"] as NSArray).write(toFile: path, atomically: true) }
    }
    func loadAlbums(fromPath path: String!) {
        restoredAlbums = (NSArray(contentsOfFile: path) as? [String] ?? ["unreadable"]).joined(separator: ",")
    }
    func addDefaultAlbums() { defaultAlbumsCreated = true }
    func checkForExistingReport(forStudy study: NSManagedObject!) { DatabaseReportConsistency(database: self).attachExistingReport(to: study) }
    func checkReportsConsistencyWithDICOMSR() {
        DatabaseReportConsistency(database: self).archiveReportsAsDICOMSR()
        onLastStep?()
    }

    func objects(forEntity entity: NSEntityDescription!) -> [Any]! {
        let request = NSFetchRequest<NSManagedObject>()
        request.entity = entity
        return try! managedObjectContext.fetch(request)
    }
    /// As the real ones: of the model of the context.
    private func entity(_ name: String) -> NSEntityDescription! { return managedObjectContext.persistentStoreCoordinator!.managedObjectModel.entitiesByName[name] }
    func imageEntity() -> NSEntityDescription! { return entity("Image") }
    func seriesEntity() -> NSEntityDescription! { return entity("Series") }
    func studyEntity() -> NSEntityDescription! { return entity("Study") }

    /// A file is `<study>-<series>-<image>.dcm`; any other name is not DICOM. With
    /// `~<anything>` before the extension it is a copy of that image under another
    /// name, as an import leaves a file it receives, which goes once it is read. The
    /// ROIs folder holds structured reports, which write no date.
    func addFiles(atPaths paths: [Any]!, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) -> [Any]! {
        onAddFiles?()
        let context = managedObjectContext!
        func one(_ entity: String, _ key: String, _ value: String, _ owner: (String, NSManagedObject)?) -> NSManagedObject {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "%K == %@", key, value)
            if let found = try! context.fetch(request).first { return found }
            let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
            object.setValue(value, forKey: key)
            if let owner { object.setValue(owner.1, forKey: owner.0) }
            return object
        }
        for case let path as String in paths {
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.components(separatedBy: "~")
            let parts = stem[0].components(separatedBy: "-")
            guard parts.count == 3 else { continue }
            let indexed = stem.count == 1 ? path : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(stem[0] + ".dcm")
            let study = one("Study", "name", parts[0], nil)
            let series = one("Series", "name", parts[0] + "-" + parts[1], ("study", study))
            let image = one("Image", "path", indexed, ("series", series))
            if !path.hasPrefix(roisDirPath()),
               ImportArrival.isArrival(storedPath: image.isInserted ? nil : (indexed as NSString).lastPathComponent, file: path,
                                       insideDataFolder: path.hasPrefix(dataDirPath()), rereading: rereadExistingItems) {
                series.setValue(harnessToday, forKey: "dateAdded")
                study.setValue(harnessToday, forKey: "dateAdded")
            }
            if indexed != path { try? FileManager.default.removeItem(atPath: path) }
            // As the real -setSeries: of an image: a new one resets the two counts.
            if image.isInserted {
                series.setValue(nil, forKey: "numberOfImages")
                study.setValue(nil, forKey: "numberOfImages")
            }
        }
        try! context.save()
        return []
    }
}
"""

REBUILD_DRIVER = r"""
import CoreData
import Foundation
import ObjectiveC

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

let folder = CommandLine.arguments[1]
let fileManager = FileManager.default

// Files go to a folder of the test, not to the Trash of whoever runs it.
let trash = (folder as NSString).appendingPathComponent("Trash")
try! fileManager.createDirectory(atPath: trash, withIntermediateDirectories: true)
extension FileManager {
    @objc func harnessTrash(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try moveItem(atPath: url.path, toPath: (trash as NSString).appendingPathComponent(UUID().uuidString))
    }
}
method_exchangeImplementations(class_getInstanceMethod(FileManager.self, #selector(FileManager.trashItem(at:resultingItemURL:)))!,
                               class_getInstanceMethod(FileManager.self, #selector(FileManager.harnessTrash(at:resultingItemURL:)))!)

func write(_ path: String, _ text: String = "synthetic") {
    try! fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: false, encoding: .utf8)
}

func listing(_ path: String) -> String {
    return ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).sorted().joined(separator: ",")
}

func bytes(_ path: String) -> Data? { return fileManager.contents(atPath: path) }

/// Three studies of files, a hidden file and a file that is not DICOM in their
/// folders, a stray file in the data folder and one file of ROIs; the index
/// knows another study, whose files are gone, and the first two.
func makeDatabase(_ name: String) -> DicomDatabase { return makeDatabase(name, model: sharedModel) }

func makeDatabase(_ name: String, model: NSManagedObjectModel, mergedModel: Bool = false) -> DicomDatabase {
    let base = (folder as NSString).appendingPathComponent(name)
    let database = DicomDatabase(base: base)
    database.model = model
    database.opensWithMergedModel = mergedModel
    let data = database.dataDirPath()!
    for (subfolder, names) in [("1000", ["A-1-1.dcm", "A-1-2.dcm", "A-2-1.dcm", ".hidden-1-1.dcm", "notes.txt"]), ("2000", ["B-1-1.dcm", "B-1-2.dcm"]),
                               ("3000", ["C-1-1.dcm"]), ("4000", [String]())] {
        try! fileManager.createDirectory(atPath: (data as NSString).appendingPathComponent(subfolder), withIntermediateDirectories: true)
        for file in names { write(((data as NSString).appendingPathComponent(subfolder) as NSString).appendingPathComponent(file)) }
    }
    write((data as NSString).appendingPathComponent("stray-1-1.dcm"))
    write((database.roisDirPath() as NSString).appendingPathComponent("R-1-1.dcm"))
    write((database.roisDirPath() as NSString).appendingPathComponent(".R-1-2.dcm"))
    try! fileManager.createDirectory(atPath: database.incomingDirPath(), withIntermediateDirectories: true)
    write(database.modelVersionFilePath(), "2.6")
    database.managedObjectContext = database.context(atPath: database.sqlFilePath)
    let known = [(data as NSString).appendingPathComponent("1000/A-1-1.dcm"), (data as NSString).appendingPathComponent("2000/B-1-1.dcm"),
                 (data as NSString).appendingPathComponent("9000/GONE-1-1.dcm")]
    database.managedObjectContext.performAndWait {
        _ = database.addFiles(atPaths: known, postNotifications: false, dicomOnly: false, rereadExistingItems: false, generatedByOsiriX: false, returnArray: false)
        // As the browser leaves them once it has shown them.
        for case let study as DicomStudy in try! database.managedObjectContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study")) { _ = study.noFiles() }
        try! database.managedObjectContext.save()
    }
    return database
}

func runLoopTurns() {
    for _ in 0..<5 { _ = CFRunLoopRunInMode(.defaultMode, 0.02, false) }
}

func counts(_ label: String, _ database: DicomDatabase) {
    // Read from the file, as the application will find it when it opens.
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: sharedModel)
    let store = try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: database.sqlFilePath),
                                                    options: [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true])
    guard store != nil else { emit("\(label).index", "does not open"); return }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        for entity in ["Study", "Series", "Image"] {
            emit("\(label).\(entity)", "\((try? context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))) ?? -1)")
        }
        let names = ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))) ?? []).compactMap { $0.value(forKey: "name") as? String }.sorted()
        emit("\(label).studies", names.joined(separator: ","))
    }
}

func recoveryFolder(_ database: DicomDatabase) -> String? {
    let backups = (database.baseDirPath as NSString).appendingPathComponent("Index Backups")
    return (try? fileManager.contentsOfDirectory(atPath: backups))?.first.map { (backups as NSString).appendingPathComponent($0) }
}

/// The lock is recursive: only another thread learns whether it is free.
func isFree(_ lock: NSRecursiveLock) -> Bool {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var free = false
    Thread { free = lock.try(); if free { lock.unlock() }; done.signal() }.start()
    done.wait()
    return free
}

func report(_ label: String, _ database: DicomDatabase) {
    runLoopTurns()
    counts(label, database)
    emit("\(label).presented", presented.joined(separator: ";").replacingOccurrences(of: "\n", with: " | ").replacingOccurrences(of: database.baseDirPath, with: "<base>")
        .replacingOccurrences(of: recoveryFolder(database).map { ($0 as NSString).lastPathComponent } ?? "<none>", with: "<uuid>"))
    presented = []
    emit("\(label).recovery", recoveryFolder(database).map(listing) ?? "none")
    emit("\(label).base", listing(database.baseDirPath))
    emit("\(label).version", (try? String(contentsOfFile: database.modelVersionFilePath(), encoding: .utf8)) ?? "none")
    emit("\(label).incoming", listing(database.incomingDirPath()))
    emit("\(label).albums", "\(database.restoredAlbums) defaults=\(database.defaultAlbumsCreated)")
    if let lock = database.importFilesFromIncomingDirLock {
        emit("\(label).lock", isFree(lock) ? "free" : "held")
    }
}

/// While the rebuild adds its files: the import that asks without waiting, and
/// the one that waits for the lock, on threads of their own.
func probeImport(_ database: DicomDatabase, _ label: String) {
    let lock = database.importFilesFromIncomingDirLock!
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var refused = false
    Thread {
        refused = !lock.try()
        if !refused { lock.unlock() }
        done.signal()
    }.start()
    done.wait()
    emit("\(label).import.asking", refused ? "refused" : "let in")

    nonisolated(unsafe) var order: [String] = []
    let orderLock = NSLock()
    Thread {
        lock.lock()
        orderLock.withLock { order.append("import") }
        lock.unlock()
    }.start()
    Thread.sleep(forTimeInterval: 0.3) // long enough for the import to go first, if nothing holds it
    database.onLastStep = {
        orderLock.withLock { order.append("end of the rebuild") }
    }
    database.onAfterRebuild = {
        Thread.sleep(forTimeInterval: 0.3)
        emit("\(label).import.waiting", orderLock.withLock { order.joined(separator: " then ") })
    }
}

// A complete rebuild.
do {
    let database = makeDatabase("complete")
    database.onAddFiles = { probeImport(database, "complete") }
    database.rebuild(true)
    database.onAfterRebuild?()
    report("complete", database)
}

// A rebuild that keeps the index: the image whose file is gone leaves it.
do {
    let database = makeDatabase("kept")
    database.onAddFiles = { probeImport(database, "kept") }
    database.rebuild(false)
    database.onAfterRebuild?()
    report("kept", database)
}

/// What the file of the index holds, as the application will find it.
func rows(_ label: String, _ database: DicomDatabase) {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: database.model)
    _ = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: database.sqlFilePath),
                                            options: [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true])
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        func all(_ entity: String) -> [NSManagedObject] { return try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity)) }
        func name(_ object: NSManagedObject) -> String { return object.value(forKey: "name") as? String ?? "?" }
        let studies = all("Study").sorted { name($0) < name($1) }
        emit("\(label).studies", studies.map(name).joined(separator: ","))
        emit("\(label).series", all("Series").map { name($0.value(forKey: "study") as! NSManagedObject) + "/" + name($0) }.sorted().joined(separator: ","))
        emit("\(label).stored", studies.map { "\(name($0))=\($0.value(forKey: "numberOfImages") as? String ?? "none")" }.joined(separator: ","))
        emit("\(label).modality", studies.map { "\(name($0))=\($0.value(forKey: "modality") as? String ?? "none")" }.joined(separator: ","))
        emit("\(label).thumbnails", all("Series").filter { $0.value(forKey: "thumbnail") != nil }.map(name).sorted().joined(separator: ","))
        emit("\(label).albums", all("Album").map { album in
            name(album) + "[" + (album.value(forKey: "studies") as! NSSet).map { name($0 as! NSManagedObject) }.sorted().joined(separator: ",") + "]"
        }.sorted().joined(separator: " "))
    }
}

// A rebuild that keeps the index, on what an index holds. PART keeps one of its
// two images, MOVED one of its two series; LOST has nothing left, and GONE, of
// makeDatabase, neither; EMPTIED is what a former rebuild left, series with no
// images and the count it stored, and EMPTIEDPART the same beside a series that has
// images. MARK is the study an album keeps with no files, as -loadAlbumsFromPath:
// makes it, MARKED one that lost the images it had. DOC is left with a structured
// report and DOCONLY never had anything else, both with their files, which noFiles
// does not count; OWNED is left with an SR of the application's, which nothing
// shows, and KOONLY has only a key object, which noFiles counts and nothing shows.
// REPORTED lost its images and has a file in the reports folder with its name, and
// ELSEWHERE one with another name, attached; STALE is attached to a report that is
// not there. LOCKED is locked. OFFLINE is a link into a volume that is out, and
// LINKED one to a file that is gone; UNREADABLE has a file it may not open. Of the
// series with a thumbnail, only PART-1 loses an image: the others lost none, or
// have theirs out of reach.
do {
    let database = makeDatabase("kept-cleanup", model: modelWithAlbums)
    let data = database.dataDirPath() as NSString
    let reports = ((database.baseDirPath as NSString).appendingPathComponent("REPORTS") as NSString)
    let here = ["PART-1-1", "MOVED-2-1", "DOC-SR-1", "DOCONLY-SR-1", "OWNED-OWN-1", "KOONLY-KO-1", "EMPTIEDPART-1-1", "UNREADABLE-1-1"].map { data.appendingPathComponent("1000/\($0).dcm") }
    let gone = ["PART-1-2", "MOVED-1-1", "LOST-1-1", "LOST-2-1", "MARKED-1-1", "DOC-1-1", "OWNED-1-1", "REPORTED-1-1", "ELSEWHERE-1-1", "STALE-1-1", "LOCKED-1-1"].map { data.appendingPathComponent("9000/\($0).dcm") }
    let links = ["/Volumes/isix-test-volume-that-is-out-\(getpid())/OFFLINE-1-1.dcm", (folder as NSString).appendingPathComponent("elsewhere/LINKED-1-1.dcm")]
    let reportFiles = ["REPORTED.pages", "notes-of-the-study.pages"].map { reports.appendingPathComponent($0) }
    (here + reportFiles).forEach { write($0) }
    let unreadable = data.appendingPathComponent("1000/UNREADABLE-1-1.dcm")
    chmod(unreadable, 0o000)
    let context = database.managedObjectContext!
    context.performAndWait {
        _ = database.addFiles(atPaths: here + gone + links, postNotifications: false, dicomOnly: false, rereadExistingItems: false, generatedByOsiriX: false, returnArray: false)
        func insert(_ entity: String, _ name: String) -> NSManagedObject {
            let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
            object.setValue(name, forKey: "name")
            return object
        }
        func marker(_ study: NSManagedObject) {
            let series = insert("Series", "OsiriX No Autodeletion")
            series.setValue("5005", forKey: "id")
            series.setValue(study, forKey: "study")
        }
        func found(_ entity: String, _ name: String) -> NSManagedObject {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "name == %@", name)
            return try! context.fetch(request).first!
        }
        let mark = insert("Study", "MARK")
        mark.setValue("US", forKey: "modality")
        marker(mark)
        let marked = found("Study", "MARKED")
        marker(marked)
        let emptied = insert("Study", "EMPTIED")
        emptied.setValue("3", forKey: "numberOfImages")
        insert("Series", "EMPTIED-1").setValue(emptied, forKey: "study")
        let emptiedPart = found("Study", "EMPTIEDPART")
        emptiedPart.setValue("3", forKey: "numberOfImages")
        emptiedPart.setValue("CT\\MR", forKey: "modality")
        found("Series", "EMPTIEDPART-1").setValue("MR", forKey: "modality")
        let emptySeries = insert("Series", "EMPTIEDPART-2")
        emptySeries.setValue("CT", forKey: "modality")
        emptySeries.setValue(emptiedPart, forKey: "study")
        found("Study", "MOVED").setValue("CT\\MR", forKey: "modality")
        found("Series", "MOVED-1").setValue("CT", forKey: "modality")
        found("Series", "MOVED-2").setValue("MR", forKey: "modality")
        found("Series", "DOC-SR").setValue("SR", forKey: "modality")
        found("Study", "ELSEWHERE").setValue("REPORTS/notes-of-the-study.pages", forKey: "reportURL")
        found("Study", "STALE").setValue("REPORTS/not-there.pages", forKey: "reportURL")
        found("Study", "LOCKED").setValue("1", forKey: "lockedStudy")
        for name in ["A-1", "PART-1", "MOVED-2", "OFFLINE-1", "UNREADABLE-1"] { found("Series", name).setValue("of an image", forKey: "thumbnail") }
        let teaching = insert("Album", "Teaching")
        teaching.mutableSetValue(forKey: "studies").addObjects(from: [mark, marked, found("Study", "LOST"), found("Study", "A"), found("Study", "OFFLINE")])
        for case let study as DicomStudy in try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study")) { _ = study.noFiles() }
        try! context.save()
    }
    func files() -> String {
        let missing = (here + reportFiles).filter { !fileManager.fileExists(atPath: $0) }.map { ($0 as NSString).lastPathComponent }
        return missing.isEmpty ? "all here" : "gone: " + missing.sorted().joined(separator: ",")
    }
    forgotten = []
    database.rebuild(false)
    rows("kept-cleanup", database)
    emit("kept-cleanup.forgotten", forgotten.sorted().joined(separator: ","))
    emit("kept-cleanup.files", files())
    // The second time finds nothing to take out.
    forgotten = []
    database.rebuild(false)
    rows("kept-cleanup-again", database)
    emit("kept-cleanup-again.forgotten", forgotten.sorted().joined(separator: ","))
    emit("kept-cleanup-again.files", files())
    chmod(unreadable, 0o644)
}

// A save that fails leaves the study that was leaving in the index, with its
// placeholders.
do {
    let database = makeDatabase("kept-cleanup-no-save")
    forgotten = []
    database.saveFails = true
    database.rebuild(false)
    database.saveFails = false
    emit("kept-cleanup-no-save.forgotten", forgotten.joined(separator: ","))
    report("kept-cleanup-no-save", database)
}

// With no data folder its files are out of reach: nothing leaves on their account.
do {
    let database = makeDatabase("kept-cleanup-no-data", model: modelWithAlbums)
    let context = database.managedObjectContext!
    context.performAndWait {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Series")
        for series in try! context.fetch(request) { series.setValue("of an image", forKey: "thumbnail") }
        try! context.save()
    }
    let data = database.dataDirPath()!
    try! fileManager.moveItem(atPath: data, toPath: data + "-out")
    forgotten = []
    database.rebuild(false)
    rows("kept-cleanup-no-data", database)
    emit("kept-cleanup-no-data.forgotten", forgotten.joined(separator: ","))
}

// An index opened with the copy of the model beside it. The rebuilds fetch nothing
// with an entity of the database's model; the one fetch here does, for the control.
do {
    let database = makeDatabase("kept-cleanup-model", model: sharedModel, mergedModel: true)
    database.rebuild(false)
    database.rebuild(true)
    let context = database.managedObjectContext!
    context.performAndWait {
        let request = NSFetchRequest<NSManagedObject>()
        request.entity = sharedModel.entitiesByName["Study"]
        emit("kept-cleanup-model.studies", "\((try? context.fetch(request))?.count ?? -1)")
    }
}

// The column of a rebuild that keeps the index. The first rebuild indexes all that
// is there; in the second nothing is new but one image of B, whose study and series
// alone take the day. A copy under a new name, as a study sent again arrives, and a
// reread asked for, go on writing it.
do {
    let database = makeDatabase("kept-cleanup-dates")
    func dates(_ label: String) {
        let context = database.managedObjectContext!
        context.performAndWait {
            context.reset()
            func all(_ entity: String) -> [NSManagedObject] { return try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity)) }
            func line(_ object: NSManagedObject) -> String { return "\(object.value(forKey: "name") as? String ?? "?")=\(object.value(forKey: "dateAdded") as? String ?? "none")" }
            emit("\(label).studies", all("Study").map(line).sorted().joined(separator: ","))
            emit("\(label).series", all("Series").map(line).sorted().joined(separator: ","))
            emit("\(label).images", "\(all("Image").count)")
        }
    }
    database.rebuild(false)
    dates("kept-cleanup-dates.before")
    let data = database.dataDirPath() as NSString
    write(data.appendingPathComponent("2000/B-1-3.dcm"))
    harnessToday = "the day of the rebuild"
    database.rebuild(false)
    dates("kept-cleanup-dates.after")
    harnessToday = "the day it came again"
    let copy = data.appendingPathComponent("1000/A-1-1~sent-again.dcm")
    write(copy)
    let context = database.managedObjectContext!
    context.performAndWait {
        _ = database.addFiles(atPaths: [copy], postNotifications: false, dicomOnly: false, rereadExistingItems: false, generatedByOsiriX: false, returnArray: false)
        _ = database.addFiles(atPaths: [data.appendingPathComponent("3000/C-1-1.dcm")], postNotifications: false, dicomOnly: false, rereadExistingItems: true,
                              generatedByOsiriX: false, returnArray: false)
    }
    dates("kept-cleanup-dates.sent")
    harnessToday = "the day it came"
}

// The column of the reports. ATTACHED has a file with its name in the reports folder,
// OTHER a link to a file with another name; OUT and OUTALONE one into a volume that
// is out, OUT with a file of its name that must not replace it; TAKEN lost its file.
// None of them has images, so what keeps a study here is its report.
do {
    let database = makeDatabase("kept-cleanup-reports")
    let reports = database.reportsDirPath() as NSString
    let volume = "/Volumes/isix-test-volume-that-is-out-\(getpid())"
    ["ATTACHED.pages", "notes-of-other.pages", "OUT.pages"].forEach { write(reports.appendingPathComponent($0)) }
    let context = database.managedObjectContext!
    context.performAndWait {
        for (name, link) in [("ATTACHED", nil), ("OTHER", "REPORTS/notes-of-other.pages"), ("OUT", volume + "/OUT.pages"), ("OUTALONE", volume + "/alone.pages"), ("TAKEN", "REPORTS/not-there.pages")] {
            let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
            study.setValue(name, forKey: "name")
            study.setValue(link, forKey: "reportURL")
        }
        try! context.save()
    }
    func links(_ label: String) {
        context.performAndWait {
            context.reset()
            let studies = try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))
            emit(label, studies.compactMap { study in
                (study.value(forKey: "reportURL") as? String).map { "\(study.value(forKey: "name") as! String)=\($0.replacingOccurrences(of: volume, with: "<out>"))" }
            }.sorted().joined(separator: ","))
        }
    }
    database.rebuild(false)
    links("kept-cleanup-reports.links")
    database.rebuild(false)
    links("kept-cleanup-reports-again.links")
}

// Records that name the file of another image. OLD lost the files of two images,
// and an import was given their numbers: its records name the file of NEW and the
// multiframe file of MFB. ALONE, WITHREPORT and LOCKEDONE have nothing but such a
// record. The frames of MF name one file, and so do the two series of TWO, a file
// that is not DICOM. The file NOREAD and NOREADB name does not read, the one of
// RAISES and RAISESB raises, and the one of REWRITTEN and REWRITTENB is of neither.
do {
    let database = makeDatabase("kept-cleanup-shared", model: numberedModel)
    let data = database.dataDirPath() as NSString
    let reports = database.reportsDirPath() as NSString
    let contents = [10: "uids:OLD.1", 11: "uids:NEW.1", 12: "uids:MF.1", 13: "uids:scan,scan1", 14: "not an image", 15: "uids:WRITTEN.ANEW", 16: "raises",
                    17: "uids:HOLDER.1", 18: "uids:HOLDERB.1", 19: "uids:HOLDERC.1", 20: "uids:MFB.1"]
    func file(_ number: Int) -> String { return data.appendingPathComponent("1000/\(number).dcm") }
    for (number, text) in contents { write(file(number), text) }
    write(reports.appendingPathComponent("notes-of-with-report.pages"))
    let context = database.managedObjectContext!
    context.performAndWait {
        func one(_ entity: String, _ name: String, _ owner: (String, NSManagedObject)?) -> NSManagedObject {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "name == %@", name)
            if let found = try! context.fetch(request).first { return found }
            let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
            object.setValue(name, forKey: "name")
            if let owner { object.setValue(owner.1, forKey: owner.0) }
            return object
        }
        // <series> is <study>-<n>; each record is an image, or a frame, of the file of its number.
        for (series, identifier, number) in [("OLD-1", "OLD.1", 10), ("OLD-1", "OLD.2", 11), ("NEW-1", "NEW.1", 11), ("OLD-2", "OLD.3", 20),
                                             ("MF-1", "MF.1", 12), ("MF-1", "MF.1", 12), ("MF-1", "MF.1", 12), ("TWO-1", "scan", 13), ("TWO-2", "scan1", 13),
                                             ("NOREAD-1", "NOREAD.1", 14), ("NOREADB-1", "NOREADB.1", 14), ("REWRITTEN-1", "REWRITTEN.1", 15),
                                             ("REWRITTENB-1", "REWRITTENB.1", 15), ("RAISES-1", "RAISES.1", 16), ("RAISESB-1", "RAISESB.1", 16),
                                             ("HOLDER-1", "HOLDER.1", 17), ("ALONE-1", "ALONE.1", 17), ("HOLDERB-1", "HOLDERB.1", 18),
                                             ("WITHREPORT-1", "WITHREPORT.1", 18), ("HOLDERC-1", "HOLDERC.1", 19), ("LOCKEDONE-1", "LOCKEDONE.1", 19),
                                             ("MFB-1", "MFB.1", 20), ("MFB-1", "MFB.1", 20)] {
            let study = one("Study", series.components(separatedBy: "-")[0], nil)
            let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
            image.setValue(file(number), forKey: "path")
            image.setValue(NSNumber(value: number), forKey: "pathNumber")
            image.setValue(Data(identifier.utf8), forKey: "compressedSopInstanceUID")
            image.setValue(one("Series", series, ("study", study)), forKey: "series")
        }
        one("Study", "WITHREPORT", nil).setValue("REPORTS/notes-of-with-report.pages", forKey: "reportURL")
        one("Study", "LOCKEDONE", nil).setValue("1", forKey: "lockedStudy")
        for name in ["OLD-1", "NEW-1", "MF-1", "MFB-1"] { one("Series", name, nil).setValue("of an image", forKey: "thumbnail") }
        for case let study as DicomStudy in try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study")) { _ = study.noFiles() }
        try! context.save()
    }
    /// The images of the numbered files, as the index on the disk has them: each study with those of each file.
    func images(_ label: String) {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: numberedModel)
        _ = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: database.sqlFilePath),
                                                options: [NSSQLitePragmasOption: ["journal_mode": "delete"], NSReadOnlyPersistentStoreOption: true])
        let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        reader.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Image")
            request.predicate = NSPredicate(format: "pathNumber != nil")
            var held: [String: Int] = [:]
            for image in try! reader.fetch(request) {
                let series = image.value(forKey: "series") as! NSManagedObject
                held["\((series.value(forKey: "study") as! NSManagedObject).value(forKey: "name") as! String)@\(image.value(forKey: "pathNumber") as! NSNumber)", default: 0] += 1
            }
            emit(label, held.keys.sorted().map { held[$0] == 1 ? $0 : "\($0)x\(held[$0]!)" }.joined(separator: ","))
            func names(_ entity: String, having key: String? = nil) -> String {
                return (try! reader.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))).filter { object in key.map { object.value(forKey: $0) != nil } ?? true }
                    .map { $0.value(forKey: "name") as! String }.sorted().joined(separator: ",")
            }
            emit(label + ".studies", names("Study"))
            emit(label + ".thumbnails", names("Series", having: "thumbnail"))
        }
    }
    func files() -> String {
        let changed = contents.keys.sorted().filter { (try? String(contentsOfFile: file($0), encoding: .utf8)) != contents[$0] }
        let others = ((try? fileManager.contentsOfDirectory(atPath: data.appendingPathComponent("1000"))) ?? []).filter { Int(($0 as NSString).deletingPathExtension) ?? 0 > 9000 }
        return changed.isEmpty && others.isEmpty ? "all here" : "gone or changed: \(changed), new: \(others.sorted())"
    }
    images("kept-cleanup-shared.before")
    forgotten = []
    database.rebuild(false)
    images("kept-cleanup-shared.images")
    emit("kept-cleanup-shared.forgotten", forgotten.sorted().joined(separator: ","))
    emit("kept-cleanup-shared.files", files())
    // The second time finds nothing to take out.
    forgotten = []
    database.rebuild(false)
    images("kept-cleanup-shared-again.images")
    emit("kept-cleanup-shared-again.forgotten", forgotten.sorted().joined(separator: ","))
    emit("kept-cleanup-shared-again.files", files())
}

// The recovery copy cannot be made: nothing was touched.
do {
    let database = makeDatabase("no-copy")
    write((database.baseDirPath as NSString).appendingPathComponent("Index Backups"), "a file where the folder goes")
    let before = bytes(database.sqlFilePath)
    let context = database.managedObjectContext
    database.rebuild(true)
    emit("no-copy.index", bytes(database.sqlFilePath) == before ? "as it was" : "changed")
    emit("no-copy.context", database.managedObjectContext === context ? "the same" : "another")
    report("no-copy", database)
}

// A save that fails without an error, before anything happened.
do {
    let database = makeDatabase("no-save")
    let before = bytes(database.sqlFilePath)
    database.saveFails = true
    database.rebuild(true)
    database.saveFails = false
    emit("no-save.index", bytes(database.sqlFilePath) == before ? "as it was" : "changed")
    report("no-save", database)
}

// The index cannot be retired once the copy exists: it stays, with its context.
do {
    let database = makeDatabase("no-move")
    let before = bytes(database.sqlFilePath)
    let context = database.managedObjectContext
    database.onSaveAlbums = { chmod(database.baseDirPath, 0o555) }
    database.rebuild(true)
    chmod(database.baseDirPath, 0o755)
    emit("no-move.index", bytes(database.sqlFilePath) == before ? "as it was" : "changed")
    emit("no-move.context", database.managedObjectContext === context ? "the same" : "another")
    report("no-move", database)
}

// The new index does not open: the former one is in the recovery folder.
do {
    let database = makeDatabase("no-open")
    let before = bytes(database.sqlFilePath)
    database.openFails = true
    database.rebuild(true)
    database.openFails = false
    emit("no-open.kept", bytes((recoveryFolder(database)! as NSString).appendingPathComponent("RetiredDatabase.sql")) == before ? "as it was" : "changed")
    report("no-open", database)
}

// A rebuild while the database opens, as an upgrade that failed starts one:
// no context, no lock, and the albums come from the verified copy.
do {
    let database = makeDatabase("opening")
    let context = database.managedObjectContext!
    context.performAndWait { try! context.save() }
    let coordinator = context.persistentStoreCoordinator!
    for store in coordinator.persistentStores { try! coordinator.remove(store) }
    database.managedObjectContext = nil
    database.importFilesFromIncomingDirLock = nil
    database.rebuild(true)
    report("opening", database)
}

// The same, when the albums of the copy cannot be read.
do {
    let database = makeDatabase("opening-no-albums")
    let context = database.managedObjectContext!
    let coordinator = context.persistentStoreCoordinator!
    for store in coordinator.persistentStores { try! coordinator.remove(store) }
    database.managedObjectContext = nil
    database.importFilesFromIncomingDirLock = nil
    harnessAlbumsInCopy = nil
    database.rebuild(true)
    harnessAlbumsInCopy = ["read from the copy"]
    report("opening-no-albums", database)
}

// The SQL file rebuilt by the real sqlite3.
do {
    let database = makeDatabase("sql")
    database.onAddFiles = nil
    database.managedObjectContext.performAndWait {
        _ = database.addFiles(atPaths: [(database.dataDirPath()! as NSString).appendingPathComponent("3000/C-1-1.dcm")], postNotifications: false, dicomOnly: false,
                              rereadExistingItems: false, generatedByOsiriX: false, returnArray: false)
    }
    let lock = database.importFilesFromIncomingDirLock!
    database.onLastStep = {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var refused = false
        Thread { refused = !lock.try(); if !refused { lock.unlock() }; done.signal() }.start()
        done.wait()
        emit("sql.import.asking", refused ? "refused" : "let in")
    }
    let before = bytes(database.sqlFilePath)
    database.rebuildSqlFile()
    emit("sql.index", bytes(database.sqlFilePath) == before ? "as it was" : "rewritten")
    emit("sql.context", database.managedObjectContext != nil ? "open" : "none")
    report("sql", database)
}
"""

# What damages a store: a page of a table or of an index, the end of the file, its
# schema, or the files beside it. A script of its own, as the driver runs it on a
# file nothing has open.
STORE_TOOL = r"""
import os, shutil, sqlite3, sys


def tree(path, table):
    data = open(path, 'rb').read()
    size = int.from_bytes(data[16:18], 'big') or 65536
    connection = sqlite3.connect(path)
    root = connection.execute('select rootpage from sqlite_master where name = ?', (table,)).fetchone()[0]
    connection.close()
    leaves, interiors = [], []

    def walk(page):
        base = (page - 1) * size
        start = base + (100 if page == 1 else 0)
        if data[start] == 13:
            leaves.append(page)
            return
        assert data[start] == 5, 'page %d is not of a table' % page
        interiors.append(page)
        for cell in range(int.from_bytes(data[start + 3:start + 5], 'big')):
            pointer = int.from_bytes(data[start + 12 + cell * 2:start + 14 + cell * 2], 'big')
            walk(int.from_bytes(data[base + pointer:base + pointer + 4], 'big'))
        walk(int.from_bytes(data[start + 8:start + 12], 'big'))

    walk(root)
    return size, leaves, interiors


def smash(path, page, size):
    with open(path, 'r+b') as store:
        store.seek((page - 1) * size)
        store.write(b'\xff' * size)


def page_size(path):
    return int.from_bytes(open(path, 'rb').read()[16:18], 'big') or 65536


mode, path = sys.argv[1:3]
if mode == 'leaf':
    size, leaves, _ = tree(path, 'ZSTUDY')
    assert len(leaves) > 50, 'too few pages to damage the middle'
    smash(path, leaves[len(leaves) // 2], size)
elif mode == 'last-leaf':
    size, leaves, _ = tree(path, 'ZSTUDY')
    smash(path, leaves[-1], size)
elif mode == 'interior':
    size, _, interiors = tree(path, 'ZSTUDY')
    assert interiors, 'the table has no interior page'
    smash(path, interiors[0], size)
elif mode == 'index-page':
    connection = sqlite3.connect(path)
    root = connection.execute("select rootpage from sqlite_master where type = 'index' and tbl_name = 'ZSERIES' and sql is not null").fetchone()[0]
    connection.close()
    smash(path, root, page_size(path))
elif mode in ('album-page', 'join-page', 'album-tables'):
    connection = sqlite3.connect(path)
    connection.execute('create table ZALBUM (Z_PK integer primary key, Z_ENT integer, Z_OPT integer, ZNAME varchar)')
    connection.execute('create table Z_1STUDIES (Z_1ALBUMS integer, Z_5STUDIES integer, primary key (Z_1ALBUMS, Z_5STUDIES))')
    connection.executemany('insert into ZALBUM values (?, 1, 1, ?)', ((key, 'album %d' % key) for key in range(1, 20)))
    connection.executemany('insert into Z_1STUDIES values (?, ?)', ((key % 19 + 1, key) for key in range(1, 8001)))
    connection.commit()
    connection.close()
    if mode == 'album-page':
        size, leaves, _ = tree(path, 'ZALBUM')
        smash(path, leaves[0], size)
    elif mode == 'join-page':
        size, leaves, _ = tree(path, 'Z_1STUDIES')
        smash(path, leaves[len(leaves) // 2], size)
elif mode == 'truncate':
    os.truncate(path, os.path.getsize(path) // 2)
elif mode == 'foreign':
    os.remove(path)
    connection = sqlite3.connect(path)
    connection.execute('create table notes (text)')
    connection.commit()
    connection.close()
elif mode == 'craft':
    connection = sqlite3.connect(path)
    sql = connection.execute("select sql from sqlite_master where name = 'ZIMAGE'").fetchone()[0]
    connection.execute('pragma writable_schema = on')
    connection.execute("update sqlite_master set sql = ? where name = 'ZIMAGE'", (sql + ';\n' + sys.argv[3] + '\nCREATE TABLE ZQ (a TEXT)',))
    connection.commit()
    connection.close()
elif mode == 'wal' or mode == 'wal-no-log':
    connection = sqlite3.connect(path)
    connection.execute('pragma journal_mode = wal')
    connection.commit()
    if mode == 'wal-no-log':
        connection.close()
        sys.exit(0)
    # One more study, in the log only, and the files as a crash leaves them.
    connection.execute("update Z_PRIMARYKEY set Z_MAX = Z_MAX + 1 where Z_NAME = 'Study'")
    connection.execute("insert into ZSTUDY (Z_PK, Z_ENT, Z_OPT, ZNAME) select max(Z_PK) + 1, min(Z_ENT), 1, 'in the log' from ZSTUDY")
    connection.commit()
    for suffix in ('', '-wal', '-shm'):
        shutil.copy(path + suffix, path + suffix + '.kept')
    connection.close()
    for suffix in ('', '-wal', '-shm'):
        os.replace(path + suffix + '.kept', path + suffix)
else:
    sys.exit('unknown mode ' + mode)
"""

# What only the type does: the port, the lock free after an exception, and the
# repair of the SQL file on real damage.
REBUILD_DRIVER_NOW = r"""
import CoreData
import Foundation
import IsiXContracts
import IsiXDatabase
import ObjectiveC

/// As RemoteDicomDatabase, whose index is on its server: -rebuild: does nothing.
final class Refusing: DicomDatabase {
    var rebuilt = 0
    var dumped = 0
    override func rebuildAllowed() -> Bool { return false }
    override func rebuild(_ complete: Bool) { rebuilt += 1 }
    override func dumpSqlFile() { dumped += 1 }
}

func portScenarios(_ makeDatabase: (String) -> DicomDatabase) {
    // Through the port, what a refusing database does is its override, or nothing.
    let remote = Refusing(base: "/nonexistent")
    let port = remote.rebuilding
    print("port.remote.allowed\t\(port.rebuildAllowed)")
    port.rebuildIndex(complete: true)
    port.rebuildIndex(complete: false)
    port.rebuildSQLFile()
    print("port.remote.rebuilds\t\(remote.rebuilt)")
    print("port.remote.dumps\t\(remote.dumped)")

    let database = makeDatabase("port")
    let service = database.rebuilding
    print("port.allowed\t\(service.rebuildAllowed)")
    var posted = 0
    let observer = NotificationCenter.default.addObserver(forName: .OsirixDatabaseObjectsMayBecomeUnavailable, object: database, queue: nil) { _ in posted += 1 }
    service.rebuildIndex(complete: false)
    NotificationCenter.default.removeObserver(observer)
    print("port.posted\t\(posted)")
    print("port.images\t\(database.managedObjectContext.performAndWaitCount("Image"))")
    service.rebuildSQLFile()
    print("port.sql.images\t\(database.managedObjectContext.performAndWaitCount("Image"))")
    var reports = 0
    database.onLastStep = { reports += 1 }
    service.checkReportsConsistency()
    print("port.reports\t\(reports)")

    // An exception inside the SQL rebuild goes on, and leaves the lock free.
    let raising = makeDatabase("raising")
    raising.openRaises = true
    let lock = raising.importFilesFromIncomingDirLock!
    let raised = HarnessAttempt { raising.rebuildSqlFile() }
    print("raising.exception\t\(raised?.reason ?? "none")")
    print("raising.lock\t\(isFree(lock) ? "free" : "held")")
}

/// How many moves to a path still fail, each one that does taking one off.
nonisolated(unsafe) var failingMoves: [String: Int] = [:]
/// A file that does not leave its place.
nonisolated(unsafe) var failingFirstStepOf: String? = nil
/// Once the folder of the former index exists, with its path.
nonisolated(unsafe) var afterFolderIsMade: ((String) -> Void)? = nil
extension FileManager {
    @objc func harnessMakeFolder(atPath path: String, withIntermediateDirectories intermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try harnessMakeFolder(atPath: path, withIntermediateDirectories: intermediates, attributes: attributes)
        if path.contains("/Index Backups/") { afterFolderIsMade?(path) }
    }

    @objc func harnessMove(atPath source: String, toPath destination: String) throws {
        if source == failingFirstStepOf { throw CocoaError(.fileWriteNoPermission) }
        if let left = failingMoves[destination], left > 0 {
            failingMoves[destination] = left - 1
            throw CocoaError(.fileWriteNoPermission)
        }
        try harnessMove(atPath: source, toPath: destination)
    }
}

func repairScenarios(_ makeDatabase: (String) -> DicomDatabase) {
    method_exchangeImplementations(class_getInstanceMethod(FileManager.self, #selector(FileManager.moveItem(atPath:toPath:)))!,
                                   class_getInstanceMethod(FileManager.self, #selector(FileManager.harnessMove(atPath:toPath:)))!)
    method_exchangeImplementations(class_getInstanceMethod(FileManager.self, #selector(FileManager.createDirectory(atPath:withIntermediateDirectories:attributes:)))!,
                                   class_getInstanceMethod(FileManager.self, #selector(FileManager.harnessMakeFolder(atPath:withIntermediateDirectories:attributes:)))!)
    let tool = CommandLine.arguments[2]

    /// Long enough for the table to have an interior page and hundreds of leaves.
    func addStudies(_ count: Int, _ database: DicomDatabase) {
        let context = database.managedObjectContext!
        context.performAndWait {
            for index in 0..<count {
                let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
                study.setValue("study \(index) " + String(repeating: "x", count: 200), forKey: "name")
            }
            try! context.save()
        }
    }

    func damage(_ mode: String, _ database: DicomDatabase, _ argument: String? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", tool, mode, database.sqlFilePath] + (argument.map { [$0] } ?? [])
        try! process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { fatalError("the store tool failed: \(mode)") }
    }

    func temporaryFiles(_ database: DicomDatabase) -> String {
        let left = (try? fileManager.contentsOfDirectory(atPath: database.baseDirPath))?.filter { $0.contains(".dump") } ?? []
        return left.isEmpty ? "none" : left.sorted().joined(separator: ",")
    }

    /// A rebuild of the SQL file that has to leave everything as it was.
    func refused(_ label: String, _ database: DicomDatabase, marker: String? = nil, through rebuild: ((DicomDatabase) -> Void)? = nil) {
        let path: String = database.sqlFilePath
        let before = bytes(path)
        let context = database.managedObjectContext
        (rebuild ?? { $0.rebuildSqlFile() })(database)
        emit("\(label).file", bytes(path) == before ? "as it was" : "changed")
        emit("\(label).context", database.managedObjectContext === context ? "the same" : "another")
        emit("\(label).temporary", temporaryFiles(database))
        if let marker { emit("\(label).marker", fileManager.fileExists(atPath: marker) ? "made" : "nothing") }
        report(label, database)
    }

    func rebuilt(_ label: String, _ database: DicomDatabase) {
        let path: String = database.sqlFilePath
        let before = bytes(path)
        database.rebuildSqlFile()
        emit("\(label).temporary", temporaryFiles(database))
        if let folder = recoveryFolder(database) {
            let retired = (folder as NSString).appendingPathComponent(IndexRepairRules.retiredName)
            emit("\(label).retired", bytes(retired) == before ? "byte for byte" : "changed")
            emit("\(label).retired.rows", "\(IndexFileProbe.state(ofRepairedIndexAtPath: retired)?.rows["ZSTUDY"] ?? -1)")
        }
        report(label, database)
    }

    // An intact index: the same rows, with text that looks like a command in
    // them, and the former one in Index Backups.
    do {
        let database = makeDatabase("repair-intact")
        addStudies(5000, database)
        let context = database.managedObjectContext!
        let marker = (folder as NSString).appendingPathComponent("marker-in-a-row")
        let tricky = "first line;\n.shell touch \(marker)\nlast line\u{1}"
        context.performAndWait {
            let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
            study.setValue(tricky, forKey: "name")
            try! context.save()
        }
        rebuilt("repair-intact", database)
        emit("repair-intact.marker", fileManager.fileExists(atPath: marker) ? "made" : "nothing")
        database.managedObjectContext.performAndWait {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
            request.predicate = NSPredicate(format: "name == %@", tricky)
            emit("repair-intact.tricky", "\(try! database.managedObjectContext.count(for: request))")
        }
    }

    // What is not a database never reaches sqlite3, through the selector too.
    for (label, rebuild) in [("repair-text", nil), ("repair-selector", { $0.dumpSqlFile() } as ((DicomDatabase) -> Void)?)] {
        let database = makeDatabase(label)
        let marker = (folder as NSString).appendingPathComponent("marker-\(label)")
        write(database.sqlFilePath, ".shell touch \(marker)\nSELECT 1;\n")
        refused(label, database, marker: marker, through: rebuild)
    }

    // Damage for real, and in a file that sqlite3 reads to the end, saying 0.
    for (label, mode) in [("repair-leaf", "leaf"), ("repair-last-leaf", "last-leaf"), ("repair-interior", "interior"), ("repair-album", "album-page"), ("repair-join", "join-page"),
                          ("repair-truncated", "truncate"), ("repair-foreign", "foreign")] {
        let database = makeDatabase(label)
        addStudies(5000, database)
        damage(mode, database)
        refused(label, database)
    }

    // A journal that would have to roll back: read-only, it cannot.
    do {
        let database = makeDatabase("repair-hot-journal")
        try! Data(repeating: 7, count: 4096).write(to: URL(fileURLWithPath: database.sqlFilePath + "-journal"))
        refused("repair-hot-journal", database)
    }

    // A schema that comes out of .dump as commands to the second sqlite3.
    for (label, payload) in [("repair-crafted", ".shell touch %@"), ("repair-crafted-system", ".system touch %@"), ("repair-crafted-output", ".output %@"),
                             ("repair-crafted-attach", "COMMIT;\nATTACH '%@' AS outside;\nCREATE TABLE outside.t (a);\nBEGIN;"),
                             ("repair-crafted-vacuum", "COMMIT;\nVACUUM INTO '%@';\nBEGIN;"), ("repair-crafted-writefile", "SELECT writefile('%@', 'x');")] {
        let database = makeDatabase(label)
        let marker = (folder as NSString).appendingPathComponent("marker-\(label)")
        damage("craft", database, payload.replacingOccurrences(of: "%@", with: marker))
        refused(label, database, marker: marker)
    }

    // A command that sqlite3 lets through ends the load with nothing committed.
    do {
        let database = makeDatabase("repair-crafted-quit")
        damage("craft", database, ".quit")
        refused("repair-crafted-quit", database)
    }

    // Plain SQL goes through safe mode: this one would fill the disk, with the
    // import lock held, and is stopped at the size the index allows.
    do {
        let database = makeDatabase("repair-crafted-endless")
        damage("craft", database, "COMMIT;\nCREATE TABLE fill (a);\nWITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) INSERT INTO fill SELECT zeroblob(1048576) FROM n;\nBEGIN;")
        refused("repair-crafted-endless", database)
    }

    // A folder that takes no new file: the index reads well, and sqlite3 has
    // nothing to do with it.
    do {
        let database = makeDatabase("repair-read-only-folder")
        let base: String = database.baseDirPath
        try! fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: base)
        refused("repair-read-only-folder", database)
        try! fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: base)
    }

    // A page of an index of the table: the rows are all there, and that is
    // what this function is for.
    do {
        let database = makeDatabase("repair-index-page")
        damage("index-page", database)
        rebuilt("repair-index-page", database)
    }

    // The tables of albums, which the model of this test does not have, come out
    // with their rows.
    do {
        let database = makeDatabase("repair-album-tables")
        damage("album-tables", database)
        rebuilt("repair-album-tables", database)
        let rows = IndexFileProbe.state(ofRepairedIndexAtPath: database.sqlFilePath)?.rows
        emit("repair-album-tables.rows", "\(rows?["ZALBUM"] ?? -1) \(rows?["Z_1STUDIES"] ?? -1)")
    }

    // The log leaves with the index. Left beside the new file, SQLite would
    // apply it to it, even though the file is not in log mode.
    do {
        let database = makeDatabase("repair-wal")
        damage("wal", database)
        rebuilt("repair-wal", database)
    }

    // In log mode and without a log, which read-only cannot open as it is.
    do {
        let database = makeDatabase("repair-wal-no-log")
        damage("wal-no-log", database)
        rebuilt("repair-wal-no-log", database)
    }

    // A journal left empty goes with the index, and does nothing to the new file.
    do {
        let database = makeDatabase("repair-empty-journal")
        fileManager.createFile(atPath: database.sqlFilePath + "-journal", contents: Data())
        rebuilt("repair-empty-journal", database)
    }

    // The folder for the former index cannot be made.
    do {
        let database = makeDatabase("repair-no-folder")
        write((database.baseDirPath as NSString).appendingPathComponent("Index Backups"), "a file where the folder goes")
        refused("repair-no-folder", database)
    }

    // The new file does not take the name: the index never left its place, and
    // its second name goes.
    do {
        let database = makeDatabase("repair-second-step")
        let new = IndexRepairRules.temporaryFiles(forIndexAtPath: database.sqlFilePath)[1]
        afterFolderIsMade = { _ in try? fileManager.removeItem(atPath: new) }
        refused("repair-second-step", database)
        afterFolderIsMade = nil
        emit("repair-second-step.backups", listing((database.baseDirPath as NSString).appendingPathComponent("Index Backups")))
    }

    // The index cannot be kept in the folder, by link or by copy.
    do {
        let database = makeDatabase("repair-no-keep")
        afterFolderIsMade = { chmod($0, 0o555) }
        refused("repair-no-keep", database)
        afterFolderIsMade = nil
    }

    // What is beside the index does not leave: nothing changed.
    do {
        let database = makeDatabase("repair-first-step")
        let journal = database.sqlFilePath + "-journal"
        fileManager.createFile(atPath: journal, contents: Data())
        failingFirstStepOf = journal
        refused("repair-first-step", database)
        failingFirstStepOf = nil
        emit("repair-first-step.journal", fileManager.fileExists(atPath: journal) ? "there" : "gone")
    }

    // Neither the new file nor the way back of what was beside the index: the
    // index is in its place, and the person is told where the rest is.
    do {
        let database = makeDatabase("repair-no-way-back")
        let before = bytes(database.sqlFilePath)
        let context = database.managedObjectContext
        let new = IndexRepairRules.temporaryFiles(forIndexAtPath: database.sqlFilePath)[1]
        fileManager.createFile(atPath: database.sqlFilePath + "-journal", contents: Data())
        afterFolderIsMade = { _ in try? fileManager.removeItem(atPath: new) }
        failingMoves[database.sqlFilePath + "-journal"] = 1
        database.rebuildSqlFile()
        afterFolderIsMade = nil
        emit("repair-no-way-back.context", database.managedObjectContext === context ? "the same" : "another")
        emit("repair-no-way-back.file", bytes(database.sqlFilePath) == before ? "as it was" : "changed")
        report("repair-no-way-back", database)
    }

    /// A store the repair refused, as the person has it after reading the alert.
    func refusedStore(_ label: String, _ mode: String) -> DicomDatabase {
        let database = makeDatabase(label)
        addStudies(5000, database)
        damage(mode, database)
        database.rebuildSqlFile()
        runLoopTurns()
        emit("\(label).refused", presented.first?.contains("(Rebuild Entire Database...)") == true ? "points to the rebuild" : "\(presented)")
        presented = []
        return database
    }

    func retired(_ database: DicomDatabase) -> Data? {
        return recoveryFolder(database).flatMap { bytes(($0 as NSString).appendingPathComponent(IndexRepairRules.retiredName)) }
    }

    // The way out the alert points to: a complete rebuild, with the damaged index
    // in its recovery folder as it was.
    for (label, mode) in [("complete-leaf", "leaf"), ("complete-last-leaf", "last-leaf"), ("complete-interior", "interior"), ("complete-album", "album-page"), ("complete-truncated", "truncate")] {
        let database = refusedStore(label, mode)
        let before = bytes(database.sqlFilePath)
        database.rebuild(true)
        emit("\(label).retired", retired(database) == before ? "byte for byte" : "changed")
        report(label, database)
    }

    // What is not a database at all, while the database has it open.
    do {
        let database = makeDatabase("complete-text")
        write(database.sqlFilePath, "not a database")
        database.rebuild(true)
        emit("complete-text.retired", retired(database) == Data("not a database".utf8) ? "byte for byte" : "changed")
        report("complete-text", database)
    }

    // The log of a damaged index is not lost with it.
    do {
        let database = refusedStore("complete-log", "leaf")
        write(database.sqlFilePath + "-wal", "log")
        database.rebuild(true)
        report("complete-log", database)
    }

    // No album comes out of a damaged index: the default ones come back.
    do {
        let database = refusedStore("complete-no-albums", "leaf")
        database.albumsUnreadable = true
        database.rebuild(true)
        report("complete-no-albums", database)
    }

    // The same while the database opens: the index is read where it is.
    do {
        let database = refusedStore("complete-opening", "leaf")
        let context = database.managedObjectContext!
        let coordinator = context.persistentStoreCoordinator!
        for store in coordinator.persistentStores { try! coordinator.remove(store) }
        database.managedObjectContext = nil
        database.importFilesFromIncomingDirLock = nil
        database.rebuild(true)
        emit("complete-opening.read", (harnessAlbumsReadFrom as NSString).lastPathComponent)
        report("complete-opening", database)
    }

    // The damage is no reason to go on when the folder cannot be made.
    do {
        let database = refusedStore("complete-no-folder", "leaf")
        write((database.baseDirPath as NSString).appendingPathComponent("Index Backups"), "a file where the folder goes")
        let before = bytes(database.sqlFilePath)
        let context = database.managedObjectContext
        database.rebuild(true)
        emit("complete-no-folder.index", bytes(database.sqlFilePath) == before ? "as it was" : "changed")
        emit("complete-no-folder.context", database.managedObjectContext === context ? "the same" : "another")
        report("complete-no-folder", database)
    }

    emit("repair.trash", listing(trash))
}

extension NSManagedObjectContext {
    func performAndWaitCount(_ entity: String) -> Int {
        var count = -1
        performAndWait { count = (try? self.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))) ?? -1 }
        return count
    }
}
"""


def rebuild_forwarders():
    """What of the database's forwarders the rebuild goes through, as they are."""
    source = (root / FORWARDERS).read_text()
    blocks = ''.join(re.search(r'    @objc\(%s\)\n.*?^    }\n' % selector, source, re.S | re.M).group(0)
                     for selector in ('rebuild:', 'dumpSqlFile', 'rebuildSqlFile'))
    return 'extension DicomDatabase {\n' + blocks + '}\n\n' + source[source.rindex('extension DicomDatabase {'):]


def rebuild_sources(source):
    """The rebuild of `source`, wherever it is, as a Swift file."""
    if 'final class DatabaseRebuildService' in source:
        return source[source.index('import AppKit'):] + '\n' + rebuild_forwarders()
    helpers = ''
    for name in ('rebuildFailure', 'add', 'contentsOfDirectory', 'isNotHidden', 'singularPluralCount'):
        found = re.search(r'^private func %s\(.*?^}\n' % name, source, re.S | re.M)
        helpers += found.group(0) + '\n'
    models = source[source.index('    /// The models an index of this database can be of'):source.index('    @objc(rebuild)\n')]
    method = source[source.index('    @objc(rebuild:)\n'):source.index('    @objc(checkReportsConsistencyWithDICOMSR)')]
    sql = source[source.index('    @objc(dumpSqlFile)'):source.index('    @objc(checkForHtmlTemplates)')]
    body = re.sub(r'    @objc\([^)]*\)\n    dynamic func', '    func', models + method + sql)
    return 'import AppKit\nimport CoreData\n\n' + helpers + '\nextension DicomDatabase {\n' + body + '\n}\n'


def run_rebuild(source, label, directory):
    """What the rebuild of `source` does in the scenarios, as {key: value}."""
    folder = directory / label
    folder.mkdir()
    now = 'final class DatabaseRebuildService' in source
    driver = REBUILD_DRIVER + ('\nportScenarios(makeDatabase)\nrepairScenarios(makeDatabase)\n' if now else '')
    # The waiters of a scenario run after the rebuild, in order.
    doubles = REBUILD_DOUBLES.replace('    var restoredAlbums = "none"', '    var onAfterRebuild: (() -> Void)? = nil\n    var restoredAlbums = "none"')
    (folder / 'doubles.swift').write_text(doubles)
    (folder / 'rebuild.swift').write_text(rebuild_sources(source))
    (folder / 'try.h').write_text(TRY_HEADER)
    (folder / 'try.m').write_text(TRY_SOURCE)
    (folder / 'main.swift').write_text(driver)
    files = ['doubles.swift', 'rebuild.swift', 'main.swift']
    if now:
        (folder / 'port.swift').write_text(REBUILD_DRIVER_NOW)
        files.append('port.swift')
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-o', str(folder / 'try.o'), str(folder / 'try.m')], check=True, capture_output=True)
    binary = folder / 'rebuild'
    built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-suppress-warnings', '-o', str(binary), '-import-objc-header', str(folder / 'try.h'),
                            *module_flags('IsiXDatabase', directory / 'modules'), *(str(folder / name) for name in files), str(folder / 'try.o'),
                            str(root / 'Horos/Sources/MainActorCallbacks.swift'), str(root / 'Horos/Sources/DatabaseIndexBackup.swift'),
                            str(root / 'Horos/Sources/MissingFileReason.swift'), str(root / 'Horos/Sources/DatabaseReportConsistency.swift')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the rebuild of %s does not compile:\n%s' % (label, built.stderr[-2500:]))
        return {}
    stores = folder / 'stores'
    stores.mkdir()
    tool = folder / 'store-tool.py'
    tool.write_text(STORE_TOOL)
    run = subprocess.run([str(binary), str(stores), str(tool)], capture_output=True, text=True, timeout=300)
    if run.returncode != 0:
        failures.append('the rebuild of %s failed (%d): %s' % (label, run.returncode, (run.stderr or run.stdout)[-1500:]))
    results = dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)
    results['kept-cleanup-model.warnings'] = str(run.stderr.count('appears to be from a different NSManagedObjectModel'))
    return results


REFUSED = 'The database index was not rebuilt and has not changed: %s | A complete rebuild (Rebuild Entire Database...) can index the image files again.'
DAMAGED = 'the table %s has a page that cannot be read, and its rows after that page would be lost.'
NOT_AN_INDEX = 'the file cannot be read as a database index.'
NOT_LOADED = 'sqlite3 could not load the contents of the index into a new file.'


def check_repair(now):
    """What a repair of the SQL file did, in each scenario."""
    def expect(key, want):
        if now.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, now.get(key), want))

    reasons = {
        'repair-text': 'the file is not a SQLite database.',
        'repair-selector': 'the file is not a SQLite database.',
        'repair-leaf': DAMAGED % 'ZSTUDY', 'repair-last-leaf': DAMAGED % 'ZSTUDY', 'repair-interior': DAMAGED % 'ZSTUDY',
        'repair-album': DAMAGED % 'ZALBUM', 'repair-join': DAMAGED % 'Z_1STUDIES',
        'repair-truncated': NOT_AN_INDEX, 'repair-foreign': NOT_AN_INDEX, 'repair-hot-journal': NOT_AN_INDEX,
        'repair-crafted': NOT_LOADED, 'repair-crafted-system': NOT_LOADED, 'repair-crafted-output': NOT_LOADED,
        'repair-crafted-attach': NOT_LOADED, 'repair-crafted-vacuum': NOT_LOADED, 'repair-crafted-writefile': NOT_LOADED,
        'repair-crafted-quit': 'the new index does not have the table ZIMAGE.',
        'repair-crafted-endless': NOT_LOADED,
    }
    left_alone = list(reasons) + ['repair-no-folder', 'repair-read-only-folder', 'repair-second-step', 'repair-no-keep', 'repair-first-step']
    for label in left_alone:
        expect(label + '.file', 'as it was')
        expect(label + '.context', 'the same')
        expect(label + '.temporary', 'none')
        expect(label + '.recovery', 'none')
        expect(label + '.lock', 'free')
    for label, reason in reasons.items():
        expect(label + '.presented', REFUSED % reason)
    for label in ('repair-text', 'repair-selector', 'repair-crafted', 'repair-crafted-system', 'repair-crafted-output',
                  'repair-crafted-attach', 'repair-crafted-vacuum', 'repair-crafted-writefile'):
        expect(label + '.marker', 'nothing')

    expect('repair-intact.Study', '5004')  # the three of the scenario, the 5000 and the one with a line break
    expect('repair-intact.Image', '3')
    expect('repair-intact.tricky', '1')
    expect('repair-intact.marker', 'nothing')
    expect('repair-intact.retired', 'byte for byte')
    expect('repair-intact.recovery', 'RetiredDatabase.sql')
    expect('repair-intact.temporary', 'none')
    expect('repair-intact.presented', '')
    expect('repair-intact.lock', 'free')

    expect('repair-album-tables.rows', '19 8000')
    expect('repair-album-tables.retired', 'byte for byte')
    expect('repair-album-tables.presented', '')

    expect('repair-index-page.Study', '3')
    expect('repair-index-page.retired', 'byte for byte')
    expect('repair-index-page.presented', '')

    expect('repair-wal.Study', '4')
    expect('repair-wal.recovery', 'RetiredDatabase.sql,RetiredDatabase.sql-shm,RetiredDatabase.sql-wal')
    expect('repair-wal.retired.rows', '4')
    expect('repair-wal.presented', '')
    expect('repair-wal.base', 'DATABASE.noindex,DB_VERSION,Database.sql,INCOMING.noindex,Index Backups,ROIs')
    expect('repair-wal-no-log.Study', '3')
    expect('repair-wal-no-log.presented', '')
    expect('repair-empty-journal.Study', '3')
    expect('repair-empty-journal.recovery', 'RetiredDatabase.sql,RetiredDatabase.sql-journal')
    expect('repair-empty-journal.base', 'DATABASE.noindex,DB_VERSION,Database.sql,INCOMING.noindex,Index Backups,ROIs')

    for label in ('repair-no-folder', 'repair-read-only-folder', 'repair-second-step', 'repair-no-keep', 'repair-first-step'):
        if 'the new index could not be put in place (' not in now.get(label + '.presented', ''):
            failures.append('%s says %r' % (label, now.get(label + '.presented')))
    expect('repair-second-step.backups', '')
    expect('repair-first-step.journal', 'there')
    expect('repair-no-way-back.file', 'as it was')
    expect('repair-no-way-back.context', 'the same')
    expect('repair-no-way-back.recovery', 'RetiredDatabase.sql-journal')
    expect('repair-no-way-back.lock', 'free')
    if 'The index is in its place, and they are in: <base>/Index Backups/<uuid>' not in now.get('repair-no-way-back.presented', ''):
        failures.append('what could not come back says %r' % now.get('repair-no-way-back.presented'))

    # The complete rebuild the alert points to gets past the same damage.
    kept = 'The former database index was damaged, and the image files were indexed again. What only the index held, such as comments, stays in the former index, kept in: <base>/Index Backups/<uuid>'
    for label in ('complete-leaf', 'complete-last-leaf', 'complete-interior', 'complete-album', 'complete-truncated', 'complete-text', 'complete-log', 'complete-no-albums', 'complete-opening'):
        expect(label + '.Study', '4')
        expect(label + '.Image', '7')
        expect(label + '.lock', 'free' if label != 'complete-opening' else None)
        if label != 'complete-text':
            expect(label + '.refused', 'points to the rebuild')
    for label in ('complete-leaf', 'complete-last-leaf', 'complete-interior', 'complete-album', 'complete-truncated', 'complete-text'):
        expect(label + '.retired', 'byte for byte')
        expect(label + '.presented', kept)
        expect(label + '.recovery', 'DB_VERSION,RetiredDatabase.sql')
        expect(label + '.albums', 'saved before defaults=false')
    if 'RetiredDatabase.sql-wal' not in now.get('complete-log.recovery', ''):
        failures.append('the log of a damaged index is not with it: %r' % now.get('complete-log.recovery'))
    expect('complete-no-albums.albums', 'none defaults=true')
    if 'albums of the former database index' not in now.get('complete-no-albums.presented', ''):
        failures.append('albums lost with a damaged index say %r' % now.get('complete-no-albums.presented'))
    expect('complete-opening.read', 'Database.sql')
    expect('complete-opening.albums', 'read from the copy defaults=false')
    expect('complete-no-folder.index', 'as it was')
    expect('complete-no-folder.context', 'the same')
    expect('complete-no-folder.lock', 'free')
    if 'stopped before the index could be backed up' not in now.get('complete-no-folder.presented', ''):
        failures.append('a damaged index with no folder says %r' % now.get('complete-no-folder.presented'))
    expect('repair.trash', '')


def check_crafted_control(directory):
    """The crafted file, with the two runs of sqlite3 of before: its command runs."""
    control = directory / 'crafted-control'
    control.mkdir()
    (control / 'store-tool.py').write_text(STORE_TOOL)
    store, new, marker = control / 'store.sql', control / 'new.sql', control / 'marker'
    subprocess.run(['/usr/bin/sqlite3', str(store), 'CREATE TABLE ZIMAGE (Z_PK INTEGER PRIMARY KEY)'], check=True)
    subprocess.run([sys.executable, '-I', str(control / 'store-tool.py'), 'craft', str(store), '.shell touch %s' % marker], check=True)
    dump = subprocess.run(['/usr/bin/sqlite3', str(store), '.dump'], capture_output=True, text=True, check=True, timeout=30)
    subprocess.run(['/usr/bin/sqlite3', str(new)], input=dump.stdout, capture_output=True, text=True, timeout=30)
    if not marker.exists():
        failures.append('the crafted file does not run its command with no options: it no longer tests what it should')


if not revision:
    with tempfile.TemporaryDirectory(prefix='horos-rebuild-equivalence-') as directory:
        directory = reaped(Path(directory))
        before_the_type = revision_before(root, SOURCE)
        shown = subprocess.run(['git', '-C', str(root), 'show', f'{before_the_type}:{FORMER_SOURCE}'], capture_output=True) if before_the_type else None
        now = run_rebuild(text, 'now', directory)
        compared = shown is not None and shown.returncode == 0
        if compared:
            then = run_rebuild(shown.stdout.decode('utf-8'), 'before', directory)
            only_now = ('port.', 'raising.', 'repair', 'complete-', 'kept-cleanup')
            # The former index of the SQL rebuild left the Trash for Index Backups,
            # and a complete rebuild writes the version file instead of deleting
            # it, which the files it leaves show; the versions are expected below.
            # The rebuild that keeps the index takes out the study with no files,
            # which it left, and keeps the one of an album, which it deleted.
            changed_on_purpose = {'sql.base', 'sql.recovery', 'complete.base', 'no-open.base', 'opening.base', 'opening-no-albums.base',
                                  'kept.Study', 'kept.Series', 'kept.studies'}
            for key in sorted((set(now) | set(then)) - changed_on_purpose):
                if not key.startswith(only_now) and not key.endswith('.version') and now.get(key) != then.get(key):
                    failures.append('the rebuild changed, %s: %r, was %r' % (key, now.get(key), then.get(key)))
            # A stand-in that gave the former rebuild the new result would test nothing.
            for key, want in {'kept-cleanup.studies': 'A,B,C,GONE,DOC,ELSEWHERE,EMPTIED,EMPTIEDPART,KOONLY,LINKED,LOCKED,LOST,MARKED,MOVED,OFFLINE,OWNED,PART,R,REPORTED,STALE,UNREADABLE',
                              'kept-cleanup.albums': 'Teaching[A,LOST,MARKED,OFFLINE]',
                              'kept-cleanup.files': 'gone: DOCONLY-SR-1.dcm,UNREADABLE-1-1.dcm'}.items():
                if ','.join(sorted(then.get(key, '').split(','))) != ','.join(sorted(want.split(','))):
                    failures.append('the former rebuild left, %s: %r, expected %r' % (key, then.get(key), want))
        SHARED_LEFT = ('HOLDER@17,HOLDERB@18,HOLDERC@19,MF@12x3,MFB@20x2,NEW@11,NOREAD@14,NOREADB@14,OLD@10,'
                       'RAISES@16,RAISESB@16,REWRITTEN@15,REWRITTENB@15,TWO@13x2')
        expected = {
            # The three studies of the files and the one of the ROIs; the hidden
            # ones and the file that is not DICOM stay out, the stray one is moved.
            'complete.Study': '4', 'complete.Series': '5', 'complete.Image': '7', 'complete.studies': 'A,B,C,R',
            'complete.recovery': 'DB_VERSION,Database.sql,RetiredDatabase.sql',
            'complete.incoming': 'stray-1-1.dcm',
            'complete.albums': 'saved before defaults=false',
            'complete.lock': 'free', 'complete.presented': '',
            'complete.import.asking': 'refused', 'complete.import.waiting': 'end of the rebuild then import',
            # The index stays and the image whose file is gone leaves it, with its
            # series and its study, which used to stay, empty, on the count it stored.
            'kept.Study': '4', 'kept.Series': '5', 'kept.Image': '7', 'kept.studies': 'A,B,C,R', 'kept.recovery': 'none',
            'kept.lock': 'free', 'kept.import.asking': 'refused', 'kept.import.waiting': 'end of the rebuild then import',
            # What leaves leaves with its series. A study stays while it has anything
            # it would take with it: images of any kind, shown or not, or a report it
            # can reach, and the files are looked for afterwards. The marker keeps its
            # study and the album its reference, a lock keeps its study, and a file out
            # of reach is not a file gone. The counts are what is left, and MARK keeps
            # the modality its album gave it. A study that stays on a report or a lock
            # may have no series at all.
            'kept-cleanup.studies': 'A,B,C,DOC,DOCONLY,ELSEWHERE,EMPTIEDPART,KOONLY,LOCKED,MARK,MARKED,MOVED,OFFLINE,OWNED,PART,R,REPORTED,UNREADABLE',
            'kept-cleanup.series': 'A/A-1,A/A-2,B/B-1,C/C-1,DOC/DOC-SR,DOCONLY/DOCONLY-SR,EMPTIEDPART/EMPTIEDPART-1,KOONLY/KOONLY-KO,'
                                   'MARK/OsiriX No Autodeletion,MARKED/OsiriX No Autodeletion,MOVED/MOVED-2,OFFLINE/OFFLINE-1,OWNED/OWNED-OWN,'
                                   'PART/PART-1,R/R-1,UNREADABLE/UNREADABLE-1',
            'kept-cleanup.stored': 'A=3,B=2,C=1,DOC=0,DOCONLY=0,ELSEWHERE=0,EMPTIEDPART=1,KOONLY=1,LOCKED=0,MARK=0,MARKED=0,MOVED=1,OFFLINE=1,OWNED=0,PART=1,R=1,'
                                   'REPORTED=0,UNREADABLE=1',
            'kept-cleanup.modality': 'A=none,B=none,C=none,DOC=SR,DOCONLY=none,ELSEWHERE=none,EMPTIEDPART=MR,KOONLY=none,LOCKED=none,MARK=US,MARKED=none,MOVED=MR,'
                                     'OFFLINE=none,OWNED=none,PART=none,R=none,REPORTED=none,UNREADABLE=none',
            'kept-cleanup.albums': 'Teaching[A,MARK,MARKED,OFFLINE]',
            'kept-cleanup.forgotten': 'EMPTIED,GONE,LINKED,LOST,STALE',
            'kept-cleanup.files': 'all here',
            'kept-cleanup-again.studies': 'A,B,C,DOC,DOCONLY,ELSEWHERE,EMPTIEDPART,KOONLY,LOCKED,MARK,MARKED,MOVED,OFFLINE,OWNED,PART,R,REPORTED,UNREADABLE',
            'kept-cleanup-again.albums': 'Teaching[A,MARK,MARKED,OFFLINE]',
            'kept-cleanup-again.forgotten': '',
            'kept-cleanup.thumbnails': 'A-1,MOVED-2,OFFLINE-1,UNREADABLE-1',
            'kept-cleanup-again.thumbnails': 'A-1,MOVED-2,OFFLINE-1,UNREADABLE-1',
            # The fetch of the driver, and no other.
            'kept-cleanup-model.warnings': '1',
            'kept-cleanup-again.files': 'all here',
            # dateAdded: a rebuild writes it only for what is new, and the entries that
            # bring a study again go on writing it.
            'kept-cleanup-dates.before.studies': 'A=the day it came,B=the day it came,C=the day it came,R=none',
            'kept-cleanup-dates.before.series': 'A-1=the day it came,A-2=the day it came,B-1=the day it came,C-1=the day it came,R-1=none',
            'kept-cleanup-dates.after.studies': 'A=the day it came,B=the day of the rebuild,C=the day it came,R=none',
            'kept-cleanup-dates.after.series': 'A-1=the day it came,A-2=the day it came,B-1=the day of the rebuild,C-1=the day it came,R-1=none',
            'kept-cleanup-dates.sent.studies': 'A=the day it came again,B=the day of the rebuild,C=the day it came again,R=none',
            'kept-cleanup-dates.sent.series': 'A-1=the day it came again,A-2=the day it came,B-1=the day of the rebuild,C-1=the day it came again,R-1=none',
            'kept-cleanup-dates.after.images': '8', 'kept-cleanup-dates.sent.images': '8',
            # A report inside the database stays relative, an archive that cannot read
            # it leaves it, and one on a volume that is out keeps its link and its study.
            'kept-cleanup-reports.links': 'ATTACHED=REPORTS/ATTACHED.pages,OTHER=REPORTS/notes-of-other.pages,OUT=<out>/OUT.pages,OUTALONE=<out>/alone.pages',
            'kept-cleanup-reports-again.links': 'ATTACHED=REPORTS/ATTACHED.pages,OTHER=REPORTS/notes-of-other.pages,OUT=<out>/OUT.pages,OUTALONE=<out>/alone.pages',
            'kept-cleanup-no-save.forgotten': '', 'kept-cleanup-no-save.lock': 'free',
            # The records that named the file of another image left as images whose
            # files are gone, and every file is as it was: OLD keeps the image it has
            # a file of, ALONE left with its only record, and a report and a lock
            # kept WITHREPORT and LOCKEDONE with no image. The frames of MF and of
            # MFB and the two series of TWO stay. The files that do not read, raise
            # or are of none of their records tell nothing, and their records stay.
            'kept-cleanup-shared.before': 'ALONE@17,HOLDER@17,HOLDERB@18,HOLDERC@19,LOCKEDONE@19,MF@12x3,MFB@20x2,NEW@11,NOREAD@14,NOREADB@14,OLD@10,OLD@11,OLD@20,'
                                          'RAISES@16,RAISESB@16,REWRITTEN@15,REWRITTENB@15,TWO@13x2,WITHREPORT@18',
            'kept-cleanup-shared.images': SHARED_LEFT, 'kept-cleanup-shared-again.images': SHARED_LEFT,
            'kept-cleanup-shared.images.studies': 'A,B,C,HOLDER,HOLDERB,HOLDERC,LOCKEDONE,MF,MFB,NEW,NOREAD,NOREADB,OLD,R,RAISES,RAISESB,REWRITTEN,REWRITTENB,TWO,WITHREPORT',
            'kept-cleanup-shared.forgotten': 'ALONE,GONE', 'kept-cleanup-shared-again.forgotten': '',
            'kept-cleanup-shared.files': 'all here', 'kept-cleanup-shared-again.files': 'all here',
            # OLD-1 lost an image, and makes its thumbnail again; the series that
            # kept theirs lost none.
            'kept-cleanup-shared.images.thumbnails': 'MF-1,MFB-1,NEW-1',
            'kept-cleanup-no-data.studies': 'A,B,GONE,R', 'kept-cleanup-no-data.forgotten': '',
            'kept-cleanup-no-data.thumbnails': 'A-1,B-1,GONE-1',
            'no-copy.index': 'as it was', 'no-copy.context': 'the same', 'no-copy.lock': 'free', 'no-copy.recovery': 'none',
            'no-save.index': 'as it was', 'no-save.lock': 'free', 'no-save.presented': 'Database reconstruction stopped before the index could be backed up: unknown error',
            'no-move.index': 'as it was', 'no-move.context': 'the same', 'no-move.lock': 'free',
            'no-open.kept': 'as it was', 'no-open.lock': 'free',
            'no-open.presented': 'Database reconstruction stopped: The reconstructed database index could not be opened. | Recovery files: <base>/Index Backups/<uuid>',
            'opening.Study': '4', 'opening.Image': '7', 'opening.albums': 'read from the copy defaults=false', 'opening.presented': '',
            'opening-no-albums.Study': '4', 'opening-no-albums.albums': 'none defaults=true',
            'sql.Study': '4', 'sql.Image': '4', 'sql.studies': 'A,B,C,GONE',
            'sql.index': 'rewritten', 'sql.context': 'open', 'sql.lock': 'free', 'sql.import.asking': 'refused',
            'sql.recovery': 'RetiredDatabase.sql', 'sql.presented': '',
            'sql.base': 'DATABASE.noindex,DB_VERSION,Database.sql,INCOMING.noindex,Index Backups,ROIs',
            # Once the former index is retired the new one is of the current model,
            # and a rebuild that stops before that leaves the file as it was.
            'complete.version': 'current', 'no-open.version': 'current', 'opening.version': 'current', 'opening-no-albums.version': 'current',
            # Not no-move: its folder is read-only by then and takes no write of any
            # kind. test-database-opening-upgrade.py stops at the same place.
            'kept.version': '2.6', 'no-copy.version': '2.6', 'no-save.version': '2.6', 'sql.version': '2.6',
            'port.remote.allowed': 'false', 'port.remote.rebuilds': '2', 'port.remote.dumps': '0',
            'port.allowed': 'true', 'port.posted': '1', 'port.reports': '1',
            'raising.exception': 'the store does not open', 'raising.lock': 'free',
        }
        for key, want in expected.items():
            if now.get(key) != want:
                failures.append('%s: %r, expected %r' % (key, now.get(key), want))
        if 'stopped before the index could be backed up' not in now.get('no-copy.presented', ''):
            failures.append('a copy that cannot be made says %r' % now.get('no-copy.presented'))
        if 'Recovery files: <base>/Index Backups/<uuid>' not in now.get('no-move.presented', ''):
            failures.append('an index that cannot be retired says %r' % now.get('no-move.presented'))
        if 'albums of the former database index' not in now.get('opening-no-albums.presented', ''):
            failures.append('albums that are lost say %r' % now.get('opening-no-albums.presented'))

        check_repair(now)
        check_crafted_control(directory)

        # The stand-in asks the rule; this is what says the real indexing does.
        indexing = sources.source_text('DicomFileIndexer')
        indexing = indexing[indexing.index('private func indexImages('):indexing.index('/// The comments, the state and the key frames')]
        guarded = r'(?:if arrived|\} else if arrived) \{\n\s*seriesTable\?\.setValue\(today, forKey: "dateAdded"\)\n\s*study\?\.dateAdded = today\n'
        if ('let arrived = DICOMSR == false && ImportArrival.isArrival(storedPath: image?.path(), file: newFile, insideDataFolder: local, rereading: inParseExistingObject)' not in indexing
                or len(re.findall(guarded, indexing)) != 2 or indexing.count('dateAdded') != 4):
            failures.append('the indexing of an image no longer writes dateAdded through ImportArrival, and only so')

remote_source = (root / 'Horos/Sources/RemoteDicomDatabase.swift').read_text()
for override in ('override func rebuild(_ complete: Bool)', 'override func rebuildAllowed() -> Bool'):
    if override not in remote_source:
        failures.append('RemoteDicomDatabase no longer has %s' % override)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
if not revision and not compared:
    print('skipped: git does not have the revision before %s, so the rebuild was not compared with it' % SOURCE, file=sys.stderr)
    sys.exit(SKIPPED)
print('ok: a rebuild that stops names the underlying error when there is one, and still has a reason when there is not, '
      'leaves the index as it was and the lock free, makes the import wait, and, compiled from the checkout and from '
      'the revision before the type, leaves the same studies, series, images and files, but for the former index of the '
      'SQL rebuild and for what a rebuild that keeps the index takes out, which is now the study with no files and not the '
      'study of an album; a repair refuses what it would lose, runs nothing a file says, and leaves the index whole, and a '
      'complete rebuild gets past the damage it refuses')

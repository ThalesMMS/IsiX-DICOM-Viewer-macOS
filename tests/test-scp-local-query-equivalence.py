#!/usr/bin/env python3
"""The listener's local C-FIND, C-MOVE and C-GET answer what they answered
before they read the database through LocalMetadataQuerying.

SCPDatabaseSession fetched the matching objects of the index itself, in
batches, kept them between responses and read their values with key-value
coding; its C-MOVE and C-GET read their files the same way. They now ask the
metadata port (IsiXContracts) with a query that IsiXDICOMNetwork's
SCPLocalQuery makes, and the app answers it in LocalDatabaseStudyReader, which
returns values. The same driver is compiled twice:

- with SCPDatabaseSession.swift, +Find and +Retrieve, IsiXDICOMNetwork and
  IsiXContracts of the revision before that change;
- with those of this tree, the adapter, HorosLocalQueryReader.swift and the
  process graph.

Both link the real N2ManagedDatabase, the DCMTK adapter's dataset (against the
Debug build's DCMTK), the database name search (PatientNameMatching.swift) and
the DICOM string conversion, and read a synthetic SQLite index whose entities
answer the attributes and methods the listener reads, with the attribute names
of the application's model. Over the same index, for every case below:

- each C-FIND's start (match, no match, failure), and every response, as
  DCMTK prints it: the same responses, in the same order (the images of the
  series an IMAGE request names come from a set, whose order is not fixed: they
  compare as a set);
- each C-GET's start, the files it sends in order, and the network log entry,
  with the network log on and off.

The cases hold wildcards, ranges and exact dates and times (an exact time
names an attribute the model does not have, which fails the fetch), lists of
UIDs, a request in ISO_IR 192 and values the response cannot write in its
character set, ties of the order and records without a value, multi-frame
files, a maximum count, levels the database does not read, a study whose log
entry misses a value, and no database at all.

Exits 2 without the Debug build's DCMTK, or when the history does not reach
the revision before the change.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, dcmtk_flags  # noqa: E402
import history_reference  # noqa: E402
import isix_modules  # noqa: E402
import n2_database_harness  # noqa: E402

SESSION = 'Horos/Sources/SCPDatabaseSession.swift'
MARK = 'var findObjects: [NSManagedObject]?'
reference = ('HEAD' if MARK in history_reference.show('HEAD', SESSION).decode('utf-8')
             else history_reference.before_text_removed(SESSION, MARK))
if reference is None:
    print('skipped: the history does not reach the revision before the metadata port')
    sys.exit(2)
if MARK in (ROOT / SESSION).read_text(encoding='utf-8'):
    print('skipped: this tree still fetches the listener\'s objects itself')
    sys.exit(2)
flags = dcmtk_flags('dcmnet', 'dcmtls')
ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
SESSION_FILES = ('Horos/Sources/SCPDatabaseSession.swift', 'Horos/Sources/SCPDatabaseSession+Find.swift',
                 'Horos/Sources/SCPDatabaseSession+Retrieve.swift')
SHARED_SOURCES = ('Horos/Sources/PatientNameMatching.swift', 'Horos/Sources/DICOMToNSString.swift',
                  'Horos/Sources/MutableArrayCategory.swift')
NEW_SOURCES = ('Horos/Sources/ProcessGraph.swift', 'Horos/Sources/HorosLocalQueryReader.swift',
               'Horos/Sources/LocalDatabaseStudyReader.swift', 'Horos/Sources/LocalDatabaseStudyReader+Metadata.swift')
# What the session and the graph of this tree use of the single entry, which
# the queries do not reach.
NEW_STAND_INS = r'''
// The graph of the database window and the Recent Studies outlet the graph reads.
extension AppController {
    var browserWindow: BrowserWindowGraph? { nil }
    var recentStudiesMenu: NSMenu! { nil }
}

// The members the process graph makes for the application; never reached here.
@MainActor final class BrowserWindowGraph {}
@MainActor final class DICOMListenerController {
    nonisolated init(processGraph: ProcessGraph) {}
    nonisolated var isSessionInactive: Bool { false }
}
@MainActor final class UserNotificationDelivery { nonisolated init() {} }
@MainActor final class ViewerWindowArranger { nonisolated init(processGraph: ProcessGraph) {} }
@MainActor final class ApplicationMenus {
    init(recentStudiesMenu: @escaping @MainActor () -> NSMenu?, processGraph: ProcessGraph) {}
}

import IsiXContracts
import IsiXDatabase
import IsiXPreferences

// The PACS On-Demand nodes over QueryController, a member of the process graph that a query never asks.
struct QueryControllerDistantStudies: DistantStudyQuerying {
    let preferences: any PreferenceStore
    func studies(matching filters: [String: PropertyListValue], activity: String) async -> [DistantStudySummary] { [] }
    func patientStudies(of patient: String, activity: String) async -> [DistantStudySummary] { [] }
}

@MainActor final class ViewerController: NSObject {
    static func areLoadingViewers() -> Bool { false }
}
// The register of the viewers, a member of the process graph.
nonisolated final class ViewerRegistry: Sendable {}
// The presets menus and the last colour table of the viewers, members of the process graph.
@MainActor final class PresetMenuCache { nonisolated init() {} }
@MainActor final class ColourTableCache { nonisolated init() {} }
@MainActor final class ViewerSyncState { nonisolated init() {} }
// The ROI archives of a viewer's images, which the process graph makes and a query never asks for.
@MainActor final class ViewerROIArchiveStore {
    init(images: [DicomImage], database: DicomDatabase, ingest: DatabaseIngest) {}
}

struct DatabaseIngest {
    init(processGraph: ProcessGraph) {}
    var receivingFolder: String { "" }
    func listenerFolder() -> IngestFolder { IngestFolder(path: "") }
    func publish(fileAt path: String, named name: String, into folder: IngestFolder, preset: IngestPreset) -> IngestPublication {
        IngestPublication(errorNumber: EINVAL, folder: folder)
    }
}
'''
# The modules the change touched, built from each revision; the others are this tree's.
CHANGED_MODULES = ('IsiXContracts', 'IsiXDICOMNetwork')

# The entities, with the attribute names of the application's model; what the
# application computes (files, counts, the SOP Instance UID of an image) is
# computed here from stored attributes, as plainly.
ENTITIES_H = r'''
#import <CoreData/CoreData.h>
NS_ASSUME_NONNULL_BEGIN
@interface DicomImage : NSManagedObject
+ (NSData *)sopInstanceUIDEncode:(NSString *)uid NS_SWIFT_NAME(sopInstanceUIDEncode(_:));
- (nullable NSString *)type;
- (nullable NSString *)sopInstanceUID;
- (nullable NSNumber *)numberOfFrames;
- (nullable NSString *)completePath;
- (nullable NSString *)completePathResolved;
- (NSSet *)pathsForForkedProcess;
@end
@interface DicomSeries : NSManagedObject
@property (nonatomic, retain, nullable) NSSet *images;
- (nullable NSString *)type;
- (nullable NSNumber *)rawNoFiles;
- (nullable NSNumber *)noFiles;
- (NSSet *)pathsForForkedProcess;
@end
@interface DicomStudy : NSManagedObject
@property (nonatomic, retain, nullable) NSSet *series;
@property (nonatomic, retain, nullable) NSString *studyInstanceUID;
@property (nonatomic, retain, nullable) NSNumber *stateText;
@property (nonatomic, retain, nullable) NSString *comment;
- (nullable NSString *)type;
- (nullable NSString *)name;
- (nullable NSNumber *)rawNoFiles;
- (nullable NSNumber *)noFiles;
- (NSSet *)pathsForForkedProcess;
@end
@interface NSData (HorosTestSOPInstanceUID)
- (BOOL)isEqualToSopInstanceUID:(nullable NSData *)other;
@end
#ifdef __cplusplus
extern "C" {
#endif
/// The identifier of `pairs` ([tag, value or NSNull]) as the adapter holds it;
/// a value "hex:..." is put as those bytes.
IsiXDCMTKDataset *HorosTestIdentifier(NSArray *pairs);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
'''

ENTITIES_M = r'''
#import "Bridge.h"
@implementation DicomImage
+ (NSData *)sopInstanceUIDEncode:(NSString *)uid { return [uid dataUsingEncoding:NSUTF8StringEncoding]; }
- (NSString *)type { return @"Image"; }
- (NSString *)sopInstanceUID
{
    NSData *data = [self valueForKey:@"compressedSopInstanceUID"];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
- (NSNumber *)numberOfFrames { return [self valueForKey:@"storedNumberOfFrames"]; }
- (NSString *)completePath { return [self valueForKey:@"pathString"]; }
- (NSString *)completePathResolved { return [self valueForKey:@"pathString"]; }
- (NSSet *)pathsForForkedProcess { NSString *p = self.completePath; return p ? [NSSet setWithObject:p] : [NSSet set]; }
@end
@implementation DicomSeries
@dynamic images;
- (NSString *)type { return @"Series"; }
- (NSNumber *)rawNoFiles { return @(self.images.count); }
- (NSNumber *)noFiles { return self.rawNoFiles; }
- (NSSet *)pathsForForkedProcess
{
    NSMutableSet *paths = [NSMutableSet set];
    for (DicomImage *image in self.images) if (image.completePath) [paths addObject:image.completePath];
    return paths;
}
@end
@implementation DicomStudy
@dynamic series, studyInstanceUID, stateText, comment;
- (NSString *)type { return @"Study"; }
// The accessor is not the stored value: a response reads the stored one, the log the accessor.
- (NSString *)name
{
    [self willAccessValueForKey:@"name"];
    NSString *stored = [self primitiveValueForKey:@"name"];
    [self didAccessValueForKey:@"name"];
    return stored ? [@"~" stringByAppendingString:stored] : nil;
}
- (NSNumber *)rawNoFiles { NSInteger n = 0; for (DicomSeries *s in self.series) n += s.rawNoFiles.integerValue; return @(n); }
- (NSNumber *)noFiles { return self.rawNoFiles; }
- (NSSet *)pathsForForkedProcess
{
    NSMutableSet *paths = [NSMutableSet set];
    for (DicomSeries *series in self.series) [paths unionSet:series.pathsForForkedProcess];
    return paths;
}
@end
@implementation NSData (HorosTestSOPInstanceUID)
- (BOOL)isEqualToSopInstanceUID:(NSData *)other { return other && [self isEqualToData:other]; }
@end
'''

IDENTIFIER_MM = r'''
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#import "Bridge.h"
#include "IsiXDCMTKInternal.hpp"
IsiXDCMTKDataset *HorosTestIdentifier(NSArray *pairs)
{
    DcmDataset *dataset = new DcmDataset();
    for (NSArray *pair in pairs) {
        unsigned tag = [pair[0] unsignedIntValue];
        DcmTagKey key(tag >> 16, tag & 0xffff);
        if ([pair[1] isKindOfClass:[NSNull class]]) { dataset->insertEmptyElement(key, OFTrue); continue; }
        NSString *value = pair[1];
        if ([value hasPrefix:@"hex:"]) {
            NSString *hex = [value substringFromIndex:4];
            std::string bytes;
            for (NSUInteger i = 0; i + 1 < hex.length; i += 2)
                bytes.push_back((char)strtol([[hex substringWithRange:NSMakeRange(i, 2)] UTF8String], NULL, 16));
            dataset->putAndInsertString(key, bytes.c_str(), OFTrue);
        } else {
            dataset->putAndInsertString(key, [value UTF8String], OFTrue);
        }
    }
    return IsiXDCMTKDatasetTakingOwnership(dataset);
}
'''

BRIDGE = ('#import "Library.h"\n#import "IsiXDCMTKDataset.h"\n#import "IsiXDCMTKQueryRetrieveSCP.h"\n'
          '#import "Entities.h"\n')

# What the listener reaches of the application besides the database: the
# browser (its network log switch and, before, its name search, which is the
# database's), the log, the activity count, the threads' progress and the files.
STAND_INS = r'''
import AppKit
import CoreData

@MainActor final class BrowserController: NSObject {
    nonisolated(unsafe) static var current: BrowserController?
    nonisolated(unsafe) static var logs = false
    nonisolated static func currentBrowser() -> BrowserController! { current }
    nonisolated func isNetworkLogsActive() -> Bool { Self.logs }
    // The database it shows, which the process graph hands out to any thread.
    nonisolated(unsafe) var database: DicomDatabase?
    nonisolated func addFile(toDeleteQueue file: String!) {}
    nonisolated func patientsnamePredicate(_ s: String!, soundex: Bool) -> NSPredicate! {
        PatientNameMatching.namePredicate(s, soundex: nil)
    }
}

@MainActor final class AppController: NSObject {
    nonisolated static func shared() -> AppController! { nil }
    // The Dock's receiving indicator, which any thread reaches through the graph.
    nonisolated let receivingIndicator = ReceivingIndicator()
    final class ReceivingIndicator: Sendable { nonisolated func showReceiving(_ receiving: Bool) {} }
    nonisolated var bonjourPublisher: BonjourPublisher! { nil }
    nonisolated var isSessionInactive: Bool { false }
}

@MainActor final class BonjourPublisher: NSObject {}

final class DicomDatabase: N2ManagedDatabase, @unchecked Sendable {
    nonisolated(unsafe) static var instance: DicomDatabase?
    class func `default`() -> DicomDatabase? { instance }
    class func activeLocal() -> DicomDatabase? { instance }
    func tempDirPathC() -> UnsafePointer<CChar>? { nil }
    func incomingDirPathC() -> UnsafePointer<CChar>? { nil }
    override var managedObjectModel: NSManagedObjectModel! { HorosTestModel.shared }
    override func saveModel() -> Bool { false }
}

final class LogManager: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = LogManager()
    nonisolated(unsafe) var lines: [[String: String]] = []
    static func currentLogManager() -> Any? { shared }
    func addLogLine(_ line: NSMutableDictionary) {
        var copy: [String: String] = [:]
        for (key, value) in line {
            let name = "\(key)"
            // When and the random identifier differ from run to run.
            if ["logStartTime", "logEndTime", "logUID"].contains(name) { continue }
            let kind = value is NSNumber ? "number" : value is Date ? "date" : value is String ? "text" : "\(type(of: value))"
            copy[name] = "\(kind):\(value)"
        }
        lines.append(copy)
    }
}

enum ActivityProgressCount { static func countOne(on thread: Thread) {} }

final class DicomFile: NSObject {
    nonisolated(unsafe) static var asked: [String] = []
    class func getEncodingArray(forFile file: String!) -> [Any]! {
        asked.append(file ?? "(nil)")
        return ["ISO_IR 192"]
    }
    class func string(withBytes bytes: UnsafeMutablePointer<CChar>?, encodings: UnsafeMutablePointer<UInt>?) -> String? { nil }
}

extension Thread {
    @objc var progress: CGFloat { get { 0 } set {} }
}

enum HorosTestModel {
    nonisolated(unsafe) static let shared: NSManagedObjectModel = {
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true; return a
        }
        func relation(_ name: String, _ to: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
            let r = NSRelationshipDescription(); r.name = name; r.destinationEntity = to; r.isOptional = true
            r.minCount = 0; r.maxCount = many ? 0 : 1; r.deleteRule = many ? .cascadeDeleteRule : .nullifyDeleteRule; return r
        }
        let study = NSEntityDescription(); study.name = "Study"; study.managedObjectClassName = "DicomStudy"
        let series = NSEntityDescription(); series.name = "Series"; series.managedObjectClassName = "DicomSeries"
        let image = NSEntityDescription(); image.name = "Image"; image.managedObjectClassName = "DicomImage"
        let studySeries = relation("series", series, many: true), seriesStudy = relation("study", study, many: false)
        studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries
        let seriesImages = relation("images", image, many: true), imageSeries = relation("series", series, many: false)
        seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages
        study.properties = ["accessionNumber", "comment", "id", "institutionName", "modality", "name", "patientID", "patientSex",
                            "performingPhysician", "referringPhysician", "studyInstanceUID", "studyName"]
            .map { attribute($0, .stringAttributeType) }
            + [attribute("date", .dateAttributeType), attribute("dateOfBirth", .dateAttributeType),
               attribute("hasDICOM", .booleanAttributeType), attribute("stateText", .integer16AttributeType), studySeries]
        series.properties = ["comment", "modality", "name", "seriesDICOMUID", "seriesSOPClassUID"].map { attribute($0, .stringAttributeType) }
            + [attribute("date", .dateAttributeType), attribute("id", .integer32AttributeType), seriesStudy, seriesImages]
        image.properties = [attribute("compressedSopInstanceUID", .binaryDataAttributeType), attribute("date", .dateAttributeType),
                            attribute("instanceNumber", .integer32AttributeType), attribute("pathString", .stringAttributeType),
                            attribute("sliceLocation", .floatAttributeType), attribute("storedNumberOfFrames", .integer32AttributeType),
                            imageSeries]
        let model = NSManagedObjectModel(); model.entities = [study, series, image]; return model
    }()
}
'''

DRIVER = r'''
import CoreData
import Foundation

// The index: studies of every kind the cases need, the same on both sides.
func populate(_ database: DicomDatabase) {
    let context = database.managedObjectContext!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    func insert(_ entity: String, _ values: [String: Any?]) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        for (key, value) in values { if let value { object.setValue(value, forKey: key) } }
        return object
    }
    var file = 0
    func images(_ series: NSManagedObject, _ list: [(number: Int?, frames: Int, sharesFile: Bool)], uid: String) {
        for (index, image) in list.enumerated() {
            if !image.sharesFile { file += 1 }
            let made = insert("Image", ["compressedSopInstanceUID": "\(uid).\(image.sharesFile ? index - 1 : index)".data(using: .utf8),
                                        "instanceNumber": image.number.map { NSNumber(value: $0) }, "pathString": "/data/\(file).dcm",
                                        "storedNumberOfFrames": NSNumber(value: image.frames), "sliceLocation": NSNumber(value: Float(index) * 2.5),
                                        "date": day(2026, 1, 2, 10, index)])
            made.setValue(series, forKey: "series")
        }
    }
    let studies: [[String: Any?]] = [
        ["name": "DOE^JANE", "patientID": "P100", "accessionNumber": "A1", "studyInstanceUID": "1.2.1", "id": "7",
         "studyName": "CT HEAD", "date": day(2026, 1, 2, 10, 15), "dateOfBirth": day(1980, 1, 2), "modality": "CT",
         "institutionName": "ISIX HOSPITAL", "referringPhysician": "SMITH^J", "performingPhysician": "JONES^K", "patientSex": "F",
         "comment": "NOTE A", "stateText": NSNumber(value: 2), "hasDICOM": true],
        ["name": "M\u{DC}LLER^HANS", "patientID": "P200", "accessionNumber": "A2", "studyInstanceUID": "1.2.2", "studyName": "MR KNEE",
         "date": day(2026, 1, 5, 8, 0), "dateOfBirth": day(1975, 6, 1), "modality": "MR", "patientSex": "M", "hasDICOM": true],
        ["name": "\u{17B}\u{D3}\u{141}W^ADAM", "patientID": "Q100", "studyInstanceUID": "1.2.3", "studyName": "CT CHEST",
         "date": day(2026, 1, 3, 14, 30), "modality": "CT", "comment": "\u{17B}\u{F3}\u{142}w note", "hasDICOM": true],
        ["name": "NOT^DICOM", "patientID": "P300", "studyInstanceUID": "1.2.4", "studyName": "CT", "date": day(2026, 1, 2), "hasDICOM": false],
        ["name": "NONAME^X", "patientID": "P400", "studyInstanceUID": "1.2.5", "date": day(2026, 1, 4, 9, 0), "modality": "CT",
         "hasDICOM": true],
    ]
    let ct = "1.2.840.10008.5.1.4.1.1.2", mr = "1.2.840.10008.5.1.4.1.1.4", sr = "1.2.840.10008.5.1.4.1.1.88.11"
    let sc = "1.2.840.10008.5.1.4.1.1.7"
    let layout: [[(uid: String, modality: String, sop: String, name: String?, id: Int, date: Date?, comment: String?,
                   images: [(number: Int?, frames: Int, sharesFile: Bool)])]] = [
        [("1.2.1.1", "CT", ct, "AXIAL", 2, day(2026, 1, 2, 10, 15), nil,
          [(3, 1, false), (1, 1, false), (2, 1, false), (2, 1, false), (nil, 1, false), (5, 3, false), (6, 3, true)]),
         ("1.2.1.2", "CT", ct, "CORONAL", 1, day(2026, 1, 2, 10, 15), "SERIES NOTE", [(1, 1, false), (2, 1, false)]),
         ("1.2.1.3", "SR", sr, "REPORT", 3, day(2026, 1, 2, 9, 0), "SR NOTE", [(1, 1, false)])],
        [("1.2.2.1", "MR", mr, "SAG T1", 1, day(2026, 1, 5, 8, 0), nil, [(1, 1, false), (2, 1, false), (3, 1, false)]),
         ("1.2.2.2", "SC", sc, nil, 2, nil, nil, [(1, 1, false)])],
        [("1.2.3.1", "CT", ct, "AXIAL CHEST", 1, day(2026, 1, 3, 14, 30), nil, [(1, 1, false), (2, 1, false)])],
        [("1.2.4.1", "CT", ct, "AX", 1, day(2026, 1, 2), nil, [(1, 1, false)])],
        [("1.2.5.1", "CT", ct, "AX", 1, day(2026, 1, 4, 9, 0), nil, [(1, 1, false)])],
    ]
    for (values, seriesList) in zip(studies, layout) {
        let study = insert("Study", values)
        for one in seriesList {
            let series = insert("Series", ["seriesDICOMUID": one.uid, "modality": one.modality, "seriesSOPClassUID": one.sop,
                                           "name": one.name, "id": NSNumber(value: one.id), "date": one.date, "comment": one.comment])
            series.setValue(study, forKey: "study")
            images(series, one.images, uid: one.uid)
        }
    }
    try! context.save()
}

func dump(_ dataset: IsiXDCMTKDataset) -> String {
    dataset.dump.split(separator: "\n").filter { $0.hasPrefix("(") }.joined(separator: "\n")
}

let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
let folder = URL(fileURLWithPath: CommandLine.arguments[2])
let find = "1.2.840.10008.5.1.4.1.2.2.1", get = "1.2.840.10008.5.1.4.1.2.2.3"
BrowserController.current = BrowserController()
var results: [[String: Any]] = []
for item in cases {
    if item["database"] as? Bool == false {
        DicomDatabase.instance = nil
    } else if DicomDatabase.instance == nil {
        // One index for both sides: the first run makes it, as the order of the
        // records a fetch returns is that of the store.
        let database = DicomDatabase(path: CommandLine.arguments[3])!
        if (try? database.managedObjectContext.count(for: NSFetchRequest<NSManagedObject>(entityName: "Study"))) == 0 {
            populate(database)
        }
        DicomDatabase.instance = database
    }
    UserDefaults.standard.register(defaults: ["maximumNumberOfCFindObjects": item["maximum"] as? Int ?? 0])
    BrowserController.logs = item["logs"] as? Bool ?? false
    LogManager.shared.lines = []
    DicomFile.asked = []
    var pairs: [[Any]] = []
    if let level = item["level"] as? String { pairs.append([NSNumber(value: 0x00080052), level]) }
    pairs += (item["keys"] as! [[Any]]).map { [$0[0], $0[1] is NSNull ? NSNull() : $0[1]] }
    let identifier = HorosTestIdentifier(pairs)
    let session = SCPDatabaseSession(callingAETitle: "PEER AE")
    var result: [String: Any] = ["name": item["name"] as! String]
    if item["service"] as! String == "find" {
        result["start"] = session.startFind(withSOPClass: find, identifier: identifier).rawValue
        var responses: [String] = []
        while true {
            let response = IsiXDCMTKDataset()
            guard session.nextFindResponse(response) else { break }
            responses.append(dump(response))
            if responses.count > 200 { break }
        }
        result["responses"] = responses
    } else {
        result["start"] = session.startRetrieve(withSOPClass: get, identifier: identifier, moveDestination: nil).rawValue
        result["count"] = session.retrieveCount
        var paths: [String] = []
        while let path = session.nextRetrievePath() { paths.append(path); if paths.count > 200 { break } }
        result["paths"] = paths
    }
    session.close()
    result["log"] = LogManager.shared.lines.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } }
    result["characterSetFiles"] = DicomFile.asked
    results.append(result)
}
try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
    .write(to: folder.appendingPathComponent("results.json"))
'''

T = {
    'SpecificCharacterSet': 0x00080005, 'PatientName': 0x00100010, 'PatientID': 0x00100020, 'AccessionNumber': 0x00080050,
    'StudyInstanceUID': 0x0020000D, 'StudyID': 0x00200010, 'StudyDescription': 0x00081030,
    'InterpretationStatusID': 0x4008010C, 'ImageComments': 0x00204000, 'StudyComments': 0x00324000,
    'InstitutionName': 0x00080080, 'ReferringPhysicianName': 0x00080090, 'PerformingPhysicianName': 0x00081050,
    'ModalitiesInStudy': 0x00080061, 'Modality': 0x00080060, 'PatientBirthDate': 0x00100030, 'StudyDate': 0x00080020,
    'StudyTime': 0x00080030, 'NumberOfStudyRelatedInstances': 0x00201208, 'NumberOfStudyRelatedSeries': 0x00201206,
    'NumberOfSeriesRelatedInstances': 0x00201209, 'SeriesInstanceUID': 0x0020000E, 'SeriesDescription': 0x0008103E,
    'SeriesNumber': 0x00200011, 'SeriesDate': 0x00080021, 'SeriesTime': 0x00080031, 'SOPInstanceUID': 0x00080018,
    'SOPClassUID': 0x00080016, 'InstanceNumber': 0x00200013, 'NumberOfFrames': 0x00280008, 'PatientSex': 0x00100040,
    'SliceLocation': 0x00201041, 'ContentDate': 0x00080023, 'AcquisitionTime': 0x00080032,
}
STUDY_RETURN = ['PatientName', 'PatientID', 'AccessionNumber', 'StudyInstanceUID', 'StudyID', 'StudyDescription',
                'InterpretationStatusID', 'StudyComments', 'InstitutionName', 'ReferringPhysicianName', 'PerformingPhysicianName',
                'ModalitiesInStudy', 'PatientBirthDate', 'StudyDate', 'StudyTime', 'NumberOfStudyRelatedInstances',
                'NumberOfStudyRelatedSeries', 'PatientSex', 'SOPClassUID', 'SeriesDate', 'AcquisitionTime', 'ImageComments']
SERIES_RETURN = ['StudyInstanceUID', 'SeriesInstanceUID', 'SeriesDescription', 'SeriesNumber', 'Modality', 'SeriesDate',
                 'SeriesTime', 'NumberOfSeriesRelatedInstances', 'PatientName', 'StudyComments', 'ModalitiesInStudy',
                 'NumberOfStudyRelatedSeries', 'SOPClassUID', 'ImageComments', 'InterpretationStatusID', 'PatientID']
IMAGE_RETURN = ['StudyInstanceUID', 'SeriesInstanceUID', 'SOPInstanceUID', 'InstanceNumber', 'NumberOfFrames', 'SliceLocation',
                'ImageComments', 'StudyComments', 'PatientName', 'ContentDate', 'AcquisitionTime', 'SeriesDescription',
                'NumberOfStudyRelatedSeries', 'ModalitiesInStudy', 'SOPClassUID', 'NumberOfSeriesRelatedInstances']
RETURN = {'STUDY': STUDY_RETURN, 'SERIES': SERIES_RETURN, 'IMAGE': IMAGE_RETURN}


def latin1(text):
    return 'hex:' + text.encode('latin-1').hex()


CASES = []


def case(name, service, level, keys, unordered=False, **extra):
    returned = [] if service == 'retrieve' or level not in RETURN else \
        [[T[key], None] for key in RETURN[level] if key not in {k for k, _ in keys}]
    CASES.append(dict(name=name, service=service, level=level, keys=[[T[k], v] for k, v in keys] + returned,
                      unordered=unordered, **extra))


# No database: a find fails, a retrieve matches nothing.
case('find without a database', 'find', 'STUDY', [], database=False)
case('retrieve without a database', 'retrieve', 'STUDY', [('StudyInstanceUID', '1.2.1')], database=False)

finds = [
    ('STUDY', []),
    ('STUDY', [('PatientName', '*')]), ('STUDY', [('PatientName', 'DOE*')]), ('STUDY', [('PatientName', 'doe^jane')]),
    ('STUDY', [('PatientName', latin1('MÜLLER'))]),
    ('STUDY', [('SpecificCharacterSet', 'ISO_IR 192'), ('PatientName', 'Żółw')]),
    ('STUDY', [('SpecificCharacterSet', 'ISO_IR 192'), ('PatientName', 'zolw*')]),
    ('STUDY', [('PatientID', 'P*')]), ('STUDY', [('PatientID', '*100')]), ('STUDY', [('PatientID', 'P1*0')]),
    ('STUDY', [('AccessionNumber', 'A1')]), ('STUDY', [('StudyInstanceUID', '1.2.1')]), ('STUDY', [('StudyID', '7')]),
    ('STUDY', [('StudyDescription', 'ct*')]), ('STUDY', [('StudyDescription', '*KNEE')]),
    ('STUDY', [('StudyDate', '20260102')]), ('STUDY', [('StudyDate', '20260102-20260103')]),
    ('STUDY', [('StudyDate', '-20260103')]), ('STUDY', [('StudyDate', '20260104-')]),
    ('STUDY', [('StudyDate', '20260102-20260105'), ('StudyTime', '080000-120000')]),
    ('STUDY', [('StudyTime', '101500')]),
    ('STUDY', [('PatientBirthDate', '19800102')]), ('STUDY', [('PatientBirthDate', '19700101-19790101')]),
    ('STUDY', [('ModalitiesInStudy', 'CT\\MR')]), ('STUDY', [('ModalitiesInStudy', 'SR')]), ('STUDY', [('Modality', 'MR')]),
    ('STUDY', [('ReferringPhysicianName', 'SMITH*')]), ('STUDY', [('InstitutionName', 'ISIX*')]),
    ('STUDY', [('InterpretationStatusID', '2')]), ('STUDY', [('ImageComments', '*NOTE*')]), ('STUDY', [('StudyComments', 'NOTE A')]),
    ('STUDY', [('SpecificCharacterSet', 'ISO_IR 100'), ('PatientID', 'Q100')]),
    ('SERIES', []), ('SERIES', [('StudyInstanceUID', '1.2.1')]), ('SERIES', [('SeriesInstanceUID', '1.2.1.1\\1.2.2.2')]),
    ('SERIES', [('Modality', 'CT')]), ('SERIES', [('SeriesDescription', 'AX*')]), ('SERIES', [('SeriesNumber', '2')]),
    ('SERIES', [('SeriesDate', '20260102')]), ('SERIES', [('SeriesDate', '20260102-20260103'), ('SeriesTime', '090000-110000')]),
    ('SERIES', [('SpecificCharacterSet', 'ISO_IR 100'), ('StudyInstanceUID', '1.2.3')]),
    ('IMAGE', []), ('IMAGE', [('SOPInstanceUID', '1.2.1.1.0\\1.2.1.1.3\\1.2.2.1.1')]), ('IMAGE', [('InstanceNumber', '2')]),
    ('IMAGE', [('NumberOfFrames', '3')]),
    ('PATIENT', [('PatientID', 'P100')]), ('study', [('PatientID', 'P100')]),
]
for level, keys in finds:
    case(f'find {level} {keys}', 'find', level, keys)
# The images of the series a request names come from a set.
for keys in ([('StudyInstanceUID', '1.2.1')], [('StudyInstanceUID', '1.2.1'), ('SeriesInstanceUID', '1.2.1.1')],
             [('SeriesInstanceUID', '1.2.2.1'), ('InstanceNumber', '2')]):
    case(f'find IMAGE of series {keys}', 'find', 'IMAGE', keys, unordered=True)
for level in ('STUDY', 'SERIES', 'IMAGE'):
    case(f'find {level} at most 2', 'find', level, [], maximum=2)

retrieves = [
    ('STUDY', [('StudyInstanceUID', '1.2.1')]), ('STUDY', []), ('STUDY', [('PatientID', 'P*')]),
    ('STUDY', [('StudyInstanceUID', '1.2.5')]), ('STUDY', [('StudyInstanceUID', '9.9')]), ('STUDY', [('StudyTime', '101500')]),
    ('SERIES', [('SeriesInstanceUID', '1.2.1.1')]), ('SERIES', [('StudyInstanceUID', '1.2.2')]),
    ('IMAGE', [('SOPInstanceUID', '1.2.1.1.5\\1.2.1.1.0')]), ('IMAGE', [('StudyInstanceUID', '1.2.1'), ('SeriesInstanceUID', '1.2.1.1')]),
    ('PATIENT', [('PatientID', 'P100')]),
]
for logs in (False, True):
    for level, keys in retrieves:
        case(f'retrieve {level} {keys} logs={logs}', 'retrieve', level, keys, logs=logs)


def build(side, work, n2_folder, archives, objects, modules):
    """The driver of `side` ('old' or 'new') in `work`; its path, or None."""
    sources = []
    for path in SESSION_FILES:
        target = work / Path(path).name
        target.write_bytes(history_reference.show(reference, path) if side == 'old' else (ROOT / path).read_bytes())
        sources.append(str(target))
    sources += [str(ROOT / path) for path in SHARED_SOURCES]
    if side == 'new':
        sources += [str(ROOT / path) for path in NEW_SOURCES]
    (work / 'standins.swift').write_text(STAND_INS + (NEW_STAND_INS if side == 'new' else ''))
    (work / 'main.swift').write_text(DRIVER)
    executable = work / 'driver'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'HorosTest', '-module-cache-path',
                            str(work / 'cache'), '-import-objc-header', str(n2_folder / 'Bridge.h'),
                            '-Xcc', '-I' + str(n2_folder), '-Xcc', '-I' + str(ADAPTERS), *modules, *sources,
                            str(work / 'standins.swift'), str(work / 'main.swift'), *objects,
                            # The database's categories are in its libraries: load them whole.
                            *(flag for archive in archives[:2] for flag in ('-Xlinker', '-force_load', '-Xlinker', archive)),
                            *archives[2:],
                            *[flag for flag in flags if not flag.startswith('-I')], '-lc++', '-framework', 'CoreData',
                            '-framework', 'AppKit', '-o', str(executable)], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[:4000])
        print(f'FAIL: the {side} driver does not compile')
        return None
    return executable


def old_modules(folder):
    """IsiXContracts and IsiXDICOMNetwork of the reference revision, in `folder`,
    over this tree's modules below them."""
    tree = folder / 'tree'
    for name in CHANGED_MODULES:
        listed = subprocess.run(['git', '-C', str(ROOT), 'ls-tree', '-r', '--name-only', reference, f'Modules/{name}/Sources'],
                                capture_output=True, text=True, check=True).stdout.split()
        for path in listed:
            (tree / path).parent.mkdir(parents=True, exist_ok=True)
            (tree / path).write_bytes(history_reference.show(reference, path))
    (tree / 'Modules/Package.swift').write_bytes(history_reference.show(reference, 'Modules/Package.swift'))
    saved = isix_modules.ROOT
    try:
        isix_modules.ROOT = tree
        for name in CHANGED_MODULES:
            isix_modules.build_module(name, folder / 'modules', ['-target', 'arm64-apple-macos15.0'])
    finally:
        isix_modules.ROOT = saved


def main():
    failures = []
    with tempfile.TemporaryDirectory(prefix='horos-scp-local-query-') as temporary:
        base = Path(temporary)
        n2_folder, archives = n2_database_harness.library(base / 'n2')
        (n2_folder / 'Entities.h').write_text(ENTITIES_H)
        (n2_folder / 'Entities.m').write_text(ENTITIES_M)
        (n2_folder / 'identifier.mm').write_text(IDENTIFIER_MM)
        (n2_folder / 'Bridge.h').write_text(BRIDGE)
        includes = ['-I' + str(n2_folder), '-I' + str(ADAPTERS), *[flag for flag in flags if flag.startswith('-I')]]
        objects = []
        for source, compiler, arc in ((n2_folder / 'Entities.m', 'clang', '-fobjc-arc'),
                                      (n2_folder / 'identifier.mm', 'clang++', '-fobjc-arc'),
                                      (ADAPTERS / 'IsiXDCMTKDataset.mm', 'clang++', '-fobjc-arc'),
                                      (ADAPTERS / 'IsiXDCMTKError.mm', 'clang++', '-fobjc-arc')):
            obj = base / (source.stem + '.o')
            language = ['-std=gnu++17'] if compiler == 'clang++' else []
            built = subprocess.run(['xcrun', compiler, *language, '-w', arc, '-fobjc-exceptions', *includes, '-c', str(source),
                                    '-o', str(obj)], capture_output=True, text=True)
            if built.returncode:
                print(built.stderr[-4000:])
                print(f'FAIL: {source.name} does not compile')
                return 1
            objects.append(str(obj))
        # The modules the change left alone once; those it touched for each side,
        # each in a folder of its own (one module map per folder).
        target = ['-target', 'arm64-apple-macos15.0']
        shared = isix_modules.module_flags('IsiXDICOMFile', base / 'shared', target)
        old_modules(base / 'old')

        def changed(folder):
            return ['-I', str(folder), '-L', str(folder), *(f'-l{name}' for name in CHANGED_MODULES)]
        # This tree's changed modules may depend on modules the shared folder
        # also holds (IsiXLogging), and two module maps may not declare the
        # same module: the new side builds everything it imports in one folder.
        modules = []
        for name in ('IsiXDICOMFile', *CHANGED_MODULES, 'IsiXDatabase'):
            modules += isix_modules.module_flags(name, base / 'new/modules', target)
        old_flags = changed(base / 'old/modules') + shared
        (base / 'cases.json').write_text(json.dumps(CASES))
        results = {}
        for side, flags_of_side in (('old', old_flags), ('new', modules)):
            work = base / side
            work.mkdir(exist_ok=True)
            executable = build(side, work, n2_folder, archives, objects, flags_of_side)
            if executable is None:
                return 1
            (base / 'index').mkdir(exist_ok=True)
            run = subprocess.run([str(executable), str(base / 'cases.json'), str(work), str(base / 'index/index.sql'),
                                  '-com.apple.CoreData.ConcurrencyDebug', '1'],
                                 capture_output=True, text=True, errors='replace', timeout=120, env=dict(os.environ, TZ='UTC'))
            if run.returncode:
                print(run.stderr[-3000:])
                print(f'FAIL: the {side} driver exits {run.returncode}')
                return 1
            results[side] = json.loads((work / 'results.json').read_text())
        old, new = results['old'], results['new']

        # The SOP classes and modalities a response lists come from a set of
        # the study's series, whose order is not fixed from one run to the next.
        def settled(response):
            lines = []
            for line in response.splitlines():
                if line.startswith(('(0008,0016)', '(0008,0061)')) and '[' in line:
                    head, rest = line.split('[', 1)
                    values, tail = rest.split(']', 1)
                    line = head + '[' + '\\'.join(sorted(values.split('\\'))) + ']' + tail
                lines.append(line)
            return '\n'.join(lines)

        for side in (old, new):
            for result in side:
                if 'responses' in result:
                    result['responses'] = [settled(response) for response in result['responses']]
        responses = paths = 0
        for spec, before, after in zip(CASES, old, new):
            if spec['unordered']:
                before = dict(before, responses=sorted(before.get('responses', [])))
                after = dict(after, responses=sorted(after.get('responses', [])))
            if before != after:
                failures.append(spec['name'])
                print(f'DIFFERENT {spec["name"]}:')
                for key in sorted(set(before) | set(after)):
                    if before.get(key) == after.get(key):
                        continue
                    one, two = before.get(key), after.get(key)
                    if isinstance(one, list) and isinstance(two, list) and len(one) == len(two):
                        at = next(index for index, (x, y) in enumerate(zip(one, two)) if x != y)
                        one, two = f'[{at}] {one[at]}', f'[{at}] {two[at]}'
                    print(f'  {key}: old {str(one)[:1200]}\n  {key}: new {str(two)[:1200]}')
            if '--verbose' in sys.argv:
                print(f'{spec["name"]}: start {after["start"]}, {len(after.get("responses", []))} responses, '
                      f'{len(after.get("paths", []))} files, {len(after["log"])} log lines')
            responses += len(after.get('responses', []))
            paths += len(after.get('paths', []))
        matched = sum(1 for result in new if result.get('responses') or result.get('paths'))
        print(f'compared {len(CASES)} requests ({matched} with matches): {responses} responses and {paths} files, '
              f'{len(failures)} different')
        if matched < len(CASES) // 2:
            failures.append('fewer than half of the requests match anything: the index is not what the cases expect')
    for failure in failures:
        print('FAIL:', failure)
    if not failures:
        print(f'PASS: the local C-FIND and the files and log of C-GET answer as at {reference[:12]}: same matches, '
              'attributes, order, files and log entries')
    return 1 if failures else 0


sys.exit(main())

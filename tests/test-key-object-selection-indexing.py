#!/usr/bin/env python3
"""A Key Object Selection Document "Of Interest" marks its images as key images when indexed.

When the index (DicomFileIndexer) has written the images of an import, and
before it saves them, it hands them to KeyObjectSelectionIndexing: a document
of SOP class 1.2.840.10008.5.1.4.1.1.88.59 whose title is (113000, DCM, "Of
Interest") marks the images of its study that it references, and an image that
arrives after such a document is marked when it arrives. Which images is
IsiXDatabase's KeyObjectSelectionMarking, which its Swift tests check.

This compiles the real KeyObjectSelectionIndexing.swift, the real
markAsKeyImageInDatabase of DicomImage.swift and the real report adapter
(IsiXDCMTKStructuredReportReader.mm with HorosStructuredReportBridge.cpp)
against the DCMTK of the Debug build and the module IsiXDatabase, with
stand-ins for the Core Data classes over a throwaway SQLite store, one per
case. The documents are written by the adapter as Create Key Object Selection
Document writes them: one "Of Interest" that lists CT1 and CT2, one "For
Teaching" that lists CT3. Each import inserts its rows, hands them over as the
indexer does and saves; the cases are the images before the documents, the
documents before the images, both in one import, images in two imports after
the document, and an image the user took out of the key images, which stays out
when another image arrives. CT4, which no document lists, is never marked.

The indexer's wiring (the rows it hands over, the call before the save) and
the Xcode target are checked in the sources. Exits 2 when the Debug build's
DCMTK is missing. Synthetic data only, written in a temporary folder.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, dcmtk_flags  # noqa: E402
import isix_modules  # noqa: E402

failures = []


def fail(message):
    failures.append(message)
    print('FAIL:', message)


flags = dcmtk_flags('dcmnet', 'dcmsr', 'dcmimage', 'dcmimgle')

# ------------------------------------------------------------- the wiring
indexer = (ROOT / 'Horos/Sources/DicomFileIndexer.swift').read_text(encoding='utf-8')
index_body = indexer[indexer.index('private func indexDescribedFiles('):indexer.index('private func markKeyObjectSelections(')]
reapply, mark, save = (index_body.find(text) for text in (
    'study.reapplyAnnotationsFromDICOMSR()', 'markKeyObjectSelections(of: added)', 'try context?.save()'))
if not (0 <= reapply < mark < save):
    fail('indexDescribedFiles does not mark the key object selections after the annotations SRs and before the save')
if 'KeyObjectSelectionIndexing.markKeyImages(among: added.indexedImages)' not in indexer:
    fail('the indexer does not hand the images it wrote to KeyObjectSelectionIndexing')
if not re.search(r'DicomDatabaseObjC\.add\(image, to: added\.addedImageObjects\)\n\s*if let image \{ added\.indexedImages\.append\(image\) \}',
                 indexer):
    fail('indexImages does not keep every image it writes for the key object selections, beside addedImageObjects')
if not re.search(r'var indexedImages: \[DicomImage\] = \[\]', indexer):
    fail('the import batch does not keep the images it wrote whatever the caller wants returned')
project = (ROOT / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
if project.count('KeyObjectSelectionIndexing.swift in Sources */,') != 1:
    fail('KeyObjectSelectionIndexing.swift is not in the Sources phase of the app target')

image_source = (ROOT / 'Horos/Sources/DicomImage.swift').read_text(encoding='utf-8')
marking = re.search(r'\n    func markAsKeyImageInDatabase\(\) \{\n.*?\n    \}\n', image_source, re.S)
if marking is None:
    fail('DicomImage has no markAsKeyImageInDatabase()')
    raise SystemExit(1)
if 'setIsKey' in marking.group(0) or 'archiveAnnotationsAsDICOMSR' in marking.group(0):
    fail('markAsKeyImageInDatabase writes the file or the annotations SR, inside the write of the import')

STUDY, OTHER = '1.2.826.0.1.3680043.8.498.72000', '1.2.826.0.1.3680043.8.498.72001'
CT = '1.2.840.10008.5.1.4.1.1.2'

STANDINS = r'''
import CoreData
import Foundation

// The Core Data classes the indexing reaches, over the attributes it reads.
@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    @NSManaged var studyInstanceUID: String?
    @NSManaged var series: Set<DicomSeries>?

    func keyObjects() -> NSArray! {
        let documents = (series ?? []).filter { $0.seriesSOPClassUID == "1.2.840.10008.5.1.4.1.1.88.59" }
        return NSArray(array: documents.reduce(into: [DicomImage]()) { $0 += Array($1.images ?? []) })
    }

    func images() -> NSSet! {
        NSSet(array: (series ?? []).reduce(into: [DicomImage]()) { $0 += Array($1.images ?? []) })
    }
}

@objc(DicomSeries) final class DicomSeries: NSManagedObject {
    @NSManaged var seriesSOPClassUID: String!
    @NSManaged var study: DicomStudy!
    @NSManaged var images: Set<DicomImage>?
}

@objc(DicomImage) final class DicomImage: NSManagedObject {
    @NSManaged var sopUID: String?
    @NSManaged var path: String?
    @NSManaged var storedIsKeyImage: NSNumber!
    @NSManaged var series: DicomSeries!
    var _isKeyImage: NSNumber?

    func sopInstanceUID() -> String! { sopUID }
    func completePath() -> String! { path }

    // As DicomImage.isKeyImage(): the stored value, cached.
    func isKeyImage() -> NSNumber! {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        if let cached = _isKeyImage { return cached }
        _isKeyImage = storedIsKeyImage ?? NSNumber(value: false)
        return _isKeyImage
    }
}

// The real method, from DicomImage.swift.
extension DicomImage {
@@MARK@@
}

func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true; return a
}
func relation(_ name: String, _ to: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
    let r = NSRelationshipDescription(); r.name = name; r.destinationEntity = to; r.isOptional = true
    r.minCount = 0; r.maxCount = many ? 0 : 1; r.deleteRule = .nullifyDeleteRule; return r
}
func model() -> NSManagedObjectModel {
    let study = NSEntityDescription(); study.name = "Study"; study.managedObjectClassName = NSStringFromClass(DicomStudy.self)
    let series = NSEntityDescription(); series.name = "Series"; series.managedObjectClassName = NSStringFromClass(DicomSeries.self)
    let image = NSEntityDescription(); image.name = "Image"; image.managedObjectClassName = NSStringFromClass(DicomImage.self)
    let studySeries = relation("series", series, many: true), seriesStudy = relation("study", study, many: false)
    studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries
    let seriesImages = relation("images", image, many: true), imageSeries = relation("series", series, many: false)
    seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages
    study.properties = [attribute("studyInstanceUID", .stringAttributeType), studySeries]
    series.properties = [attribute("seriesSOPClassUID", .stringAttributeType), seriesStudy, seriesImages]
    image.properties = [attribute("sopUID", .stringAttributeType), attribute("path", .stringAttributeType),
                        attribute("storedIsKeyImage", .booleanAttributeType), imageSeries]
    let m = NSManagedObjectModel(); m.entities = [study, series, image]; return m
}
'''

DRIVER = r'''
import CoreData
import Foundation

let folder = CommandLine.arguments[1]
let study = "@@STUDY@@", other = "@@OTHER@@", ct = "@@CT@@"
let kosClass = "1.2.840.10008.5.1.4.1.1.88.59"
nonisolated(unsafe) var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { print("FAIL: \(what)"); failures += 1 }
}

// The documents, as ViewerKeyObjectDocument writes them.
func writeDocument(_ name: String, code: String, meaning: String, images: [String]) -> String {
    let path = (folder as NSString).appendingPathComponent(name)
    let document = IsiXDCMTKStructuredReport()
    document.createNewDocument(.keyObjectSelection)
    do {
        try document.createNewSeries(inStudy: study)
        document.setValue("Key Object Selection", of: .seriesDescription)
        document.setValue("1", of: .instanceNumber)
        document.addRootContainer(withCode: code, scheme: "DCM", meaning: meaning)
        check(document.setRootTemplate(identifier: "2010", mappingResource: "DCMR"), "the template of \(name)")
        for image in images {
            check(document.addSelectedImage(sopClass: ct, instance: image, frames: nil), "\(image) listed in \(name)")
            try document.addEvidence(study: study, series: study + ".1", sopClass: ct, instance: image)
        }
        try document.prepareFile(withEncapsulatedDocument: nil, seriesInstanceUID: nil)
    } catch {
        check(false, "\(name) is built: \(error)")
    }
    check(document.writePreparedFileAtomically(toPath: path), "\(name) is written")
    return path
}
let ofInterest = writeDocument("of-interest.dcm", code: "113000", meaning: "Of Interest", images: [study + ".1.1", study + ".1.2"])
let forTeaching = writeDocument("for-teaching.dcm", code: "113004", meaning: "For Teaching", images: [study + ".1.3"])
check((try? IsiXDCMTKStructuredReportReader.titleCode(ofReportAtPath: ofInterest)) == ["113000", "DCM", "Of Interest"],
      "the reader gives the whole title code")
check((try? IsiXDCMTKStructuredReportReader.titleCode(ofReportAtPath: forTeaching)) == ["113004", "DCM", "For Teaching"],
      "the reader gives the other title code")
check((try? IsiXDCMTKStructuredReportReader.titleCode(ofReportAtPath: folder + "/missing.dcm")) == nil,
      "a missing file has no title code")

// A throwaway database, one per case.
final class Database {
    let context: NSManagedObjectContext
    init(_ name: String) {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model())
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".sqlite")
        _ = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
        context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }

    func fetch<T: NSManagedObject>(_ entity: String) -> [T] {
        (try? context.fetch(NSFetchRequest<T>(entityName: entity))) ?? []
    }

    func studyRow(_ uid: String) -> DicomStudy {
        if let found = (fetch("Study") as [DicomStudy]).first(where: { $0.studyInstanceUID == uid }) { return found }
        let made = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as! DicomStudy
        made.studyInstanceUID = uid
        return made
    }

    func seriesRow(_ sopClass: String, in study: DicomStudy) -> DicomSeries {
        if let found = (study.series ?? []).first(where: { $0.seriesSOPClassUID == sopClass }) { return found }
        let made = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context) as! DicomSeries
        made.seriesSOPClassUID = sopClass
        made.study = study
        return made
    }

    enum File { case image(String, study: String), document(String) }

    /// One import, as the indexer makes it: the rows, the marking, the save.
    func importFiles(_ files: [File]) {
        context.performAndWait {
            var written: [DicomImage] = []
            for file in files {
                let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context) as! DicomImage
                switch file {
                case .image(let uid, let studyUID):
                    image.sopUID = uid
                    image.series = seriesRow(ct, in: studyRow(studyUID))
                case .document(let path):
                    image.sopUID = (path as NSString).lastPathComponent
                    image.path = path
                    image.series = seriesRow(kosClass, in: studyRow(study))
                }
                written.append(image)
            }
            KeyObjectSelectionIndexing.markKeyImages(among: written)
            do { try context.save() } catch { check(false, "the import is saved: \(error)") }
        }
    }

    /// The SOP Instance UIDs of the key images, read from the store again.
    func keyImages() -> [String] {
        var keys: [String] = []
        context.performAndWait {
            context.reset()
            keys = (fetch("Image") as [DicomImage]).filter { $0.isKeyImage()?.boolValue == true }.compactMap { $0.sopUID }.sorted()
        }
        return keys
    }

    func image(_ uid: String) -> DicomImage? { (fetch("Image") as [DicomImage]).first { $0.sopUID == uid } }
}

let ct1 = study + ".1.1", ct2 = study + ".1.2", ct3 = study + ".1.3", ct4 = study + ".1.4", ct5 = study + ".1.5"
let images: [Database.File] = [ct1, ct2, ct3, ct4].map { .image($0, study: study) }
let documents: [Database.File] = [.document(ofInterest), .document(forTeaching)]
let expected = [ct1, ct2]

let imagesFirst = Database("images-first")
imagesFirst.importFiles(images)
check(imagesFirst.keyImages().isEmpty, "images without a document are no key images")
imagesFirst.context.performAndWait {
    // A browser that showed CT1 cached it as no key image.
    check(imagesFirst.image(ct1)?.isKeyImage()?.boolValue == false, "CT1 is no key image yet")
}
imagesFirst.importFiles(documents)
imagesFirst.context.performAndWait {
    check(imagesFirst.image(ct1)?.isKeyImage()?.boolValue == true, "the value CT1 cached is dropped when it is marked")
}
check(imagesFirst.keyImages() == expected, "images first, then the documents: key images \(imagesFirst.keyImages())")

let documentsFirst = Database("documents-first")
documentsFirst.importFiles(documents)
check(documentsFirst.keyImages().isEmpty, "documents alone mark nothing")
documentsFirst.importFiles(images)
check(documentsFirst.keyImages() == expected, "documents first, then the images: key images \(documentsFirst.keyImages())")

let together = Database("together")
together.importFiles(documents + images)
check(together.keyImages() == expected, "documents and images in one import: key images \(together.keyImages())")

let later = Database("one-by-one")
later.importFiles(documents)
later.importFiles([.image(ct2, study: study), .image(ct4, study: study)])
check(later.keyImages() == [ct2], "the first image listed is marked when it comes: \(later.keyImages())")
later.importFiles([.image(ct1, study: study), .image(ct3, study: study)])
check(later.keyImages() == expected, "the second image listed is marked when it comes: \(later.keyImages())")

let elsewhere = Database("other-study")
elsewhere.importFiles(documents)
elsewhere.importFiles([.image(ct1, study: other), .image(ct2, study: study)])
check(elsewhere.keyImages() == [ct2], "an image of another study is not marked: \(elsewhere.keyImages())")

// The user takes CT1 out of the key images; another image arrives.
together.context.performAndWait {
    together.image(ct1)?.storedIsKeyImage = nil
    try? together.context.save()
}
together.importFiles([.image(ct5, study: study)])
check(together.keyImages() == [ct2], "an image taken out stays out when another arrives: \(together.keyImages())")

exit(failures == 0 ? 0 : 1)
'''
for name, value in (('STUDY', STUDY), ('OTHER', OTHER), ('CT', CT)):
    DRIVER = DRIVER.replace('@@' + name + '@@', value)
STANDINS = STANDINS.replace('@@MARK@@', marking.group(0).strip('\n'))

with tempfile.TemporaryDirectory(prefix='isix-key-object-indexing-') as directory:
    work = Path(directory)
    adapters = ROOT / 'Horos/Sources/Adapters/DCMTK'
    target = ['-target', 'arm64-apple-macos15.0']
    objects = []
    for source, language, strict in ((adapters / 'HorosStructuredReportBridge.cpp', 'c++', False),
                                     (adapters / 'IsiXDCMTKError.mm', 'objective-c++', True),
                                     (adapters / 'IsiXDCMTKStructuredReportReader.mm', 'objective-c++', True)):
        output = work / (source.stem + '.o')
        warnings = ['-Wall', '-Werror', '-Wno-unused-parameter'] if strict else ['-w']
        built = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', *target, *warnings, '-fobjc-arc', '-I' + str(adapters),
                                '-x', language, '-c', str(source), *flags[:2], '-o', str(output)],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            print(built.stderr[-4000:])
            fail(f'{source.name} does not compile against the build\'s DCMTK')
        objects.append(str(output))
    if not failures:
        (work / 'bridge.h').write_text('#import "IsiXDCMTKStructuredReportReader.h"\n')
        (work / 'standins.swift').write_text(STANDINS)
        (work / 'main.swift').write_text(DRIVER)
        modules = isix_modules.module_flags('IsiXDatabase', work / 'modules', target)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *target, '-import-objc-header', str(work / 'bridge.h'),
                                '-Xcc', '-I' + str(adapters), *modules,
                                str(work / 'standins.swift'), str(ROOT / 'Horos/Sources/KeyObjectSelectionIndexing.swift'),
                                str(work / 'main.swift'), *objects, *flags[2:], '-lc++', '-lxml2', '-o', str(work / 'probe')],
                               capture_output=True, text=True, timeout=600)
        if built.returncode:
            print(built.stderr[-4000:])
            fail('KeyObjectSelectionIndexing.swift does not compile with the stand-ins and the adapter')
        else:
            (work / 'files').mkdir()
            run = subprocess.run([str(work / 'probe'), str(work / 'files')], capture_output=True, text=True, timeout=120)
            print(run.stdout, end='')
            for line in run.stdout.splitlines():
                if line.startswith('FAIL: '):
                    failures.append(line[len('FAIL: '):])
            if run.returncode and not failures:
                fail('the driver exited with %d\n%s' % (run.returncode, run.stderr[-2000:]))

if failures:
    sys.exit(1)
print('PASS: a Key Object Selection Document "Of Interest" written by the adapter marks the images of its study it '
      'lists, whether it is indexed before, after or with them, and not the others, those of another study, nor those '
      'of a document of another title; an image taken out stays out; the indexer hands its images over before the save')

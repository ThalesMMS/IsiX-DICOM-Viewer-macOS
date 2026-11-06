#!/usr/bin/env python3
"""Run the actual patient name presentation branches on Core Data image/series/study objects.

A custom annotation field holding the patient's name carries the prefix DCMPix
declares; like the PatientName item, it shows at the Full level, never at
Basic (No Name), and at the Custom level only while the Custom Annotations
sheet keeps the patient's name checked (HorosAnnotationLevel, compiled here)."""
from pathlib import Path
import subprocess,tempfile,re,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from sources import source_text
import process_graph_stand_in  # the 2D viewer's sources read the catalog's keys through PreferencesSource
import isix_modules
root=Path(__file__).resolve().parents[1]
# -drawTextualData:... is Swift (DCMView+WindowLevel+Coordinates.swift): the
# lines of a position are built by AnnotationOverlayLayout (IsiXImaging) from
# what the view reads. The view's reading of the level and of the patient's
# name (ViewAnnotationValues) is compiled as written into a stand-in for
# DCMView's instance variables, and the layout of the module builds the line.
s=source_text('DCMView+WindowLevel+Coordinates')
values=s[s.index('private struct ViewAnnotationValues'):]
def method(signature):
 start=values.index(signature)
 return values[start:values.index('\n    }\n',start)+7]
branch=''.join(method(m) for m in ('    func shows(_ token: String) -> Bool {','    func showsPatientName() -> Bool {','    func patientName() -> String? {'))
header=(root/'Horos/Sources/DCMView.h').read_bytes().decode('latin1')
pix=(root/'Horos/Sources/DCMPix.h').read_bytes().decode('latin1')
prefix_declaration=re.search(r'FOUNDATION_EXPORT NSString \* const DCMPixAnnotationPatientNamePrefix;',pix).group(0)
# The Swift class keeps its exported names in Objective-C.
pix_source=(root/'Horos/Sources/DCMPix+CAPI.m').read_bytes().decode('latin1')
prefix_definition=re.search(r'NSString \* const DCMPixAnnotationPatientNamePrefix = @"[^"]*";',pix_source).group(0)
# Both ways a custom annotation reads the name, DICOM (0010,0010) and the
# study's name in the database, are tagged with the prefix.
annotations_source=(root/'Horos/Sources/DCMPix+Annotations.swift').read_text()
assert 'return DCMPixAnnotationPatientNamePrefix + shown.text' in annotations_source
assert 'if level == "study" && name == "name" { return DCMPixAnnotationPatientNamePrefix + text }' in annotations_source
annotation_enum=re.search(r'enum \{ annotNone = 0, annotGraphics, annotBase, annotFull \};',header).group(0)
code=r'''
import Foundation
import CoreData
import IsiXImaging
func check(_ condition: Bool, _ text: String) { if !condition { print("failed: \(text)"); exit(1) } }
final class View {
 var horos_curImage = 0
 var horos_dcmFilesList: NSArray! = nil
 var horos_annotationType: Int32 = 0
}
struct Values: AnnotationValueSource {
 let view: View
 let level: Int
BRANCH
 func imageSize() -> (width: Int, height: Int) { (0, 0) }
 func pixelProbe() -> AnnotationPixelProbe? { nil }
 func zoom() -> Float { 1 }
 func rotation() -> Float { 0 }
 func imagePosition() -> AnnotationImagePosition { AnnotationImagePosition(current: 0, count: 0, stack: 1, flipped: false, step: nil) }
 func millimetrePosition() -> AnnotationMillimetrePosition? { nil }
 func windowLevel() -> AnnotationWindowLevel { AnnotationWindowLevel(level: 0, width: 0, windowsAsPET: false, maximumOfSeries: 0) }
 func slice() -> AnnotationSlice { AnnotationSlice(thickness: 0, location: 0, stack: 1, viewPosition: nil, patientPosition: nil) }
 func thickSlab() -> (thickness: Float, location: Float) { (0, 0) }
}
func render(_ dcmFilesList: NSArray?, _ curImage: Int, _ annotationType: Int, _ item: String = "PatientName") -> String {
 let view = View()
 view.horos_dcmFilesList = dcmFilesList
 view.horos_curImage = curImage
 view.horos_annotationType = Int32(annotationType)
 let layout = AnnotationOverlayLayout(originX: 0, originY: 0, width: 400, height: 300, scale: 1, characterWidth: 8, lineHeight: 14)
 let drawn = layout.commands(for: "TopLeft", lines: [[item]], fullText: true, patientNamePrefix: DCMPixAnnotationPatientNamePrefix,
                             phrases: .english, values: Values(view: view, level: annotationType))
 return drawn.commands.compactMap { command -> String? in
  if case let .text(text, _, _, _) = command { return text }
  return nil
 }.joined(separator: "|")
}
autoreleasepool {
 let study = NSEntityDescription(); study.name = "Study"; study.managedObjectClassName = "NSManagedObject"
 let name = NSAttributeDescription(); name.name = "name"; name.attributeType = .stringAttributeType; name.isOptional = true; study.properties = [name]
 let series = NSEntityDescription(); series.name = "Series"; series.managedObjectClassName = "NSManagedObject"
 let sr = NSRelationshipDescription(); sr.name = "study"; sr.destinationEntity = study; sr.maxCount = 1; sr.isOptional = true; series.properties = [sr]
 let image = NSEntityDescription(); image.name = "Image"; image.managedObjectClassName = "NSManagedObject"
 let ir = NSRelationshipDescription(); ir.name = "series"; ir.destinationEntity = series; ir.maxCount = 1; ir.isOptional = true; image.properties = [ir]
 let model = NSManagedObjectModel(); model.entities = [study, series, image]
 let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
 check((try? coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)) != nil, "addPersistentStore")
 let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
 let files = NSMutableArray()
 for value in ["QA Alice", "QA Béatrice", nil, ""] as [String?] {
  let s = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
  if let value = value { s.setValue(value, forKey: "name") }
  let se = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context); se.setValue(s, forKey: "study")
  let im = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context); im.setValue(se, forKey: "series"); files.add(im)
 }
 check(render(files, 1, annotFull) == "QA Béatrice", "render(files,1,annotFull) == QA Béatrice")
 check(render(files, 0, annotFull) == "QA Alice", "render(files,0,annotFull) == QA Alice")
 check(render(files, 2, annotFull) == "", "render(files,2,annotFull) == \"\"")
 check(render(files, 3, annotFull) == "", "render(files,3,annotFull) == \"\"")
 check(render(files, 1, annotGraphics) == "", "render(files,1,annotGraphics) == \"\"")
 check(render(files, 1, annotBase) == "", "render(files,1,annotBase) == \"\"")
 check(render(files, 1, annotNone) == "", "render(files,1,annotNone) == \"\"")
 check(render(NSArray(), 0, annotFull) == "", "render(@[],0,annotFull) == \"\"")
 check(render(files, -1, annotFull) == "", "render(files,-1,annotFull) == \"\"")
 check(render(files, files.count, annotFull) == "", "render(files,files.count,annotFull) == \"\"")
 check(render(NSArray(array: [files[1], files[0]]), 1, annotFull) == "QA Alice", "render(@[files[1],files[0]],1,annotFull) == QA Alice")
 let tagged = DCMPixAnnotationPatientNamePrefix + "DOE^JANE"
 check(render(files, 1, annotFull, tagged) == "DOE^JANE", "tagged name at annotFull")
 check(render(files, 1, annotBase, tagged) == "", "tagged name at annotBase")
 check(render(files, 1, annotGraphics, tagged) == "", "tagged name at annotGraphics")
 check(render(files, 1, annotNone, tagged) == "", "tagged name at annotNone")
 let annotCustom = 5
 check(render(files, 1, annotCustom) == "QA Béatrice", "PatientName at Custom, checked")
 check(render(files, 1, annotCustom, tagged) == "DOE^JANE", "tagged name at Custom, checked")
 UserDefaults.standard.setVolatileDomain(["AnnotationsCustomHidePatientName": true], forName: UserDefaults.argumentDomain)
 check(render(files, 1, annotCustom) == "", "PatientName at Custom, unchecked")
 check(render(files, 1, annotCustom, tagged) == "", "tagged name at Custom, unchecked")
 check(render(files, 1, annotFull) == "QA Béatrice", "the Custom check leaves Full alone")
 NSLog("PASS: PatientName follows current image, including reordered lists; missing/empty names, reduced modes, absent list and invalid selection never borrow the first patient's name")
}
'''.replace('BRANCH',branch)
with tempfile.TemporaryDirectory(prefix='horos-patient-annotation-') as t:
 p=Path(t);(p/'main.swift').write_text(code);(p/'annotations.h').write_text('#import <Foundation/Foundation.h>\n'+annotation_enum+'\n'+prefix_declaration+'\n')
 (p/'prefix.m').write_text('#import "annotations.h"\n'+prefix_definition+'\n')
 subprocess.run(['xcrun','clang','-c','-fobjc-arc',str(p/'prefix.m'),'-o',str(p/'prefix.o')],check=True)
 subprocess.run(['xcrun','swiftc','-import-objc-header',str(p/'annotations.h'),str(root/'Horos/Sources/AnnotationLevel.swift'),
                 str(p/'main.swift'),str(p/'prefix.o'),*process_graph_stand_in.swift_flags(p/'isix'),
                 *isix_modules.module_flags('IsiXImaging',p/'isix'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

#!/usr/bin/env python3
"""Run the actual PatientName presentation branch on Core Data image/series/study objects."""
from pathlib import Path
import subprocess,tempfile,re,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from sources import source_text
root=Path(__file__).resolve().parents[1]
# -drawTextualData:... is Swift (DCMView+WindowLevel+Coordinates.swift):
# its PatientName branch, and the helpers it calls, are compiled as written into
# a Swift stand-in for DCMView's instance variables.
s=source_text('DCMView+WindowLevel+Coordinates')
a=s.index('} else if item.isEqual(to: "PatientName") {')
b=s.index('} else if fullText {',a)
branch=s[a:b]
h=s.index('@inline(__always)\nprivate func objcObject<T: AnyObject>')
helpers=s[h:s.index('/// An object property read by message',h)]
header=(root/'Horos/Sources/DCMView.h').read_bytes().decode('latin1')
annotation_enum=re.search(r'enum \{ annotNone = 0, annotGraphics, annotBase, annotFull \};',header).group(0)
code=r'''
import Foundation
import CoreData
func check(_ condition: Bool, _ text: String) { if !condition { print("failed: \(text)"); exit(1) } }
HELPERS
final class View {
 var horos_curImage: Int16 = 0
 var horos_dcmFilesList: NSArray! = nil
 var horos_annotationType: Int32 = 0
 func render(_ item: NSString) -> String {
  let tempString = NSMutableString(string: "")
  let fullText = true
  if !fullText {
BRANCH }
  return tempString as String
 }
}
func render(_ dcmFilesList: NSArray?, _ curImage: Int, _ annotationType: Int) -> String {
 let view = View()
 view.horos_dcmFilesList = dcmFilesList
 view.horos_curImage = Int16(curImage)
 view.horos_annotationType = Int32(annotationType)
 return view.render("PatientName")
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
 NSLog("PASS: PatientName follows current image, including reordered lists; missing/empty names, reduced modes, absent list and invalid selection never borrow the first patient's name")
}
'''.replace('BRANCH',branch).replace('HELPERS',helpers)
with tempfile.TemporaryDirectory(prefix='horos-patient-annotation-') as t:
 p=Path(t);(p/'test.swift').write_text(code);(p/'annotations.h').write_text(annotation_enum+'\n')
 subprocess.run(['xcrun','swiftc','-import-objc-header',str(p/'annotations.h'),str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

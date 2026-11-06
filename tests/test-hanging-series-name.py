#!/usr/bin/env python3
"""Execute the production hanging-protocol ordering on real Core Data objects.

The ordering is the browser's ViewerOpener's (ViewerOpener.swift): its
SeriesOrder sort of the study's series and of each comparative study's
(ordered(_:by:)), the series kept of each comparative study
(comparativeSeries(of:by:)) and a study standing for its first series
(seriesLevel(_:)). They are copied out of that file, with the file's own
plistBool/plistInteger helpers, into a Swift program around stub
DicomSeries/DicomStudy classes.

The sort calls -[NSString contains:], Swift (n2Contains in
NSString+N2.swift): the program is compiled together with that source, so the
method it runs is the application's, not a copy.
"""
from pathlib import Path
import re, subprocess, sys, tempfile
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools'))
import object_probe  # noqa: E402
s=(root/'Horos/Sources/ViewerOpener.swift').read_text()
def static(name):
    a=s.index('    nonisolated static func %s(' % name)
    return s[a:s.index('\n    }\n',a)+7]
statics=''.join(static(name) for name in ('ordered','comparativeSeries','seriesLevel'))
# The functions read the protocol through the file's own helpers.
helpers=''.join(re.search(r'\nnonisolated private func %s\(.*?\n}\n'%name,s,re.S).group(0) for name in ('plistBool','plistInteger'))
code=r'''
import Foundation
import CoreData
HELPERS
func check(_ c: @autoclosure () -> Bool, line: Int = #line) {
    if !c() { fputs("failed: check at line \(line)\n", stderr); exit(1) }
}
@objc(DicomSeries) class DicomSeries: NSManagedObject {
    @NSManaged var name: String!
    @NSManaged var comment: String!
}
@objc(DicomStudy) class DicomStudy: NSObject {
    var imageSeriesArray: NSArray = []
    var pixelSeries: NSArray = []
    @objc func imageSeriesContainingPixels(_ pixels: Bool) -> NSArray! { return pixelSeries }
    @objc func imageSeries() -> NSArray! { return imageSeriesArray }
}
enum ViewerOpener {
STATICS}
func expanded(_ studies: [Any], _ currentHangingProtocol: [AnyHashable: Any]!) -> NSArray {
    ViewerOpener.seriesLevel(ViewerOpener.comparativeSeries(of: studies, by: currentHangingProtocol)) as NSArray
}
// The study's series and each comparative study's go through the same sort.
func current(_ input: [Any], _ currentHangingProtocol: [AnyHashable: Any]!) -> NSArray {
    ViewerOpener.ordered(input, by: currentHangingProtocol) as NSArray
}
func comparative(_ input: [Any], _ currentHangingProtocol: [AnyHashable: Any]!) -> NSArray {
    ViewerOpener.ordered(input, by: currentHangingProtocol) as NSArray
}
@_cdecl("hanging_main") public func hangingMain() -> Int32 { autoreleasepool {
    let entity = NSEntityDescription(); entity.name = "Series"; entity.managedObjectClassName = "DicomSeries"
    var properties: [NSPropertyDescription] = []
    for name in ["name", "comment"] {
        let a = NSAttributeDescription(); a.name = name; a.attributeType = .stringAttributeType; a.isOptional = true; properties.append(a)
    }
    entity.properties = properties
    let model = NSManagedObjectModel(); model.entities = [entity]
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    check((try? coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)) != nil)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
    var input: [DicomSeries] = []
    for name in ["T2 Axial", "Scout", "T1 Sagittal"] {
        let series = DicomSeries(entity: entity, insertInto: context); series.name = name; input.append(series)
    }
    input[1].comment = "T2 Axial -- unrelated note"
    let yes = NSNumber(value: true), no = NSNumber(value: false)
    for path in 0..<2 {
        let sort: ([AnyHashable: Any]) -> NSArray = { p in path != 0 ? comparative(input, p) : current(input, p) }
        check(sort(["SeriesOrder": "T2" as NSString]).isEqual(to: input))
        check(sort(["SeriesOrder": "t2" as NSString, "SeriesOrderIgnoreCase": yes]).isEqual(to: input))
        check(sort(["SeriesOrder": "t2" as NSString, "SeriesOrderIgnoreCase": no]).isEqual(to: input))
        let expected = [input[2], input[0], input[1]]
        check(sort(["SeriesOrder": "T1, T2" as NSString]).isEqual(to: expected))
        check(sort(["SeriesOrder": " , \n" as NSString]).isEqual(to: input))
        check(sort([:]).isEqual(to: input))
        input[0].name = "T2 Coração"
        let unicodeExpected = [input[0], input[2], input[1]]
        check(sort(["SeriesOrder": "Coração,T1" as NSString]).isEqual(to: unicodeExpected))
        input[0].name = "T2 Axial"
        input[1].name = nil
        check(sort(["SeriesOrder": "T2" as NSString]).isEqual(to: input))
        input[1].name = "Scout"
    }
    let study = DicomStudy(); study.imageSeriesArray = [input[1], input[2], input[0]]; study.pixelSeries = study.imageSeriesArray
    let one = [input[0]], two = [input[0], input[1]]
    check(expanded([study], ["SeriesOrder": "T2" as NSString, "NumberOfSeriesPerComparative": NSNumber(value: 1)]).isEqual(to: one))
    check(expanded([study], ["SeriesOrder": "T2" as NSString, "NumberOfSeriesPerComparative": NSNumber(value: 2)]).isEqual(to: two))
    check(expanded([study], ["SeriesOrder": "T2" as NSString]).isEqual(to: one))
    check(expanded([study], ["SeriesOrder": "T2" as NSString, "NumberOfSeriesPerComparative": NSNumber(value: 0)]).isEqual(to: one))
    check(expanded([study], [:]).isEqual(to: [input[1]]))
    study.pixelSeries = []
    check(expanded([study], ["SeriesOrder": "T2" as NSString, "NumberOfSeriesPerComparative": NSNumber(value: 1)]).isEqual(to: one))
    check(expanded([], ["SeriesOrder": "T2" as NSString]).count == 0)
    NSLog("PASS: single/multiple comparative selection and fallback; current/comparative series names; unrelated comments, case modes, fallback and missing names")
    return 0
} }
'''.replace('HELPERS',helpers).replace('STATICS',statics)
with tempfile.TemporaryDirectory(prefix='horos-hanging-name-') as directory:
 p=Path(directory);(p/'hanging.swift').write_text(code)
 (p/'main.c').write_text('int hanging_main(void);\nint main(void) { return hanging_main(); }\n')
 (p/'bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n#import "NSString+N2.h"\n')
 # NSString (N2) calls NSMutableString (N2), Swift too; the blocks and the
 # string methods are compiled as one module, as they are in the application.
 library=object_probe.swift_dylib([p/'hanging.swift',root/'Nitrogen/Sources/NSString+N2.swift',root/'Nitrogen/Sources/NSMutableString+N2.swift'],[],p/'libHanging.dylib',
                                  bridging_header=p/'bridging.h',include_dirs=(root/'Nitrogen/Sources',),frameworks=('Cocoa','CoreData'))
 subprocess.run(['xcrun','clang',str(p/'main.c'),str(library),'-Wl,-rpath,'+str(p),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

#!/usr/bin/env python3
"""Thumbnails of MONOCHROME1 images have the polarity the viewer shows.

MONOCHROME1 polarity is applied for display (-[DCMPix displayInverted]), not
to fImage, so that measurements keep calibrated values. The viewer's 8-bit
image follows it; -generateThumbnailImageWithWW:WL: did not, and every series
icon of a MONOCHROME1 radiograph came out in reverse video. The production
CreateIconFrom16 and -generateThumbnailImageWithWW:WL: run here against a
stand-in DCMPix: the icon of a MONOCHROME1 image is the MONOCHROME2 icon
reversed, and an RGB image is left as it is.

The thumbnails already stored are dropped once per database for the
projection modalities that carry MONOCHROME1, and made again when shown:
HorosMonochrome1Thumbnails runs here against a stand-in DicomDatabase with a
real in-memory Core Data store. The browser calls it when it opens a
database.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
pix = (root / 'Horos/Sources/DCMPix.m').read_bytes().decode('utf-8')

icon_function = pix[pix.index('unsigned char* CreateIconFrom16 (float* image'):]
icon_function = icon_function[:icon_function.index('\n}\n') + 3]
method = pix[pix.index('- (NSImage*) generateThumbnailImageWithWW: (float)newWW WL: (float)newWL'):]
method = method[:method.index('\n}\n') + 3]

code = r'''
#import <Cocoa/Cocoa.h>
#define PREVIEWSIZE 68
FUNCTION
@interface DCMPix : NSObject { @public long width, height; float *fImage; BOOL isRGB, inverseVal; float ww, wl, fullww, fullwl; }
@property(retain) NSString *srcFile;
@end
@implementation DCMPix
- (void)CheckLoad {}
- (void)computePixMinPixMax { fullww = 4096; fullwl = 2048; }
- (BOOL)displayInverted { return inverseVal && !isRGB; }
METHOD
@end
#define check(...) do { if (!(__VA_ARGS__)) { NSLog(@"FAIL: %s", #__VA_ARGS__); return 1; } } while (0)
static unsigned char *bytes(NSImage *image) { return [(NSBitmapImageRep*)image.representations[0] bitmapData]; }
int main() { @autoreleasepool {
    // A horizontal ramp from 0 to 4095.
    DCMPix *p = [DCMPix new];
    p->width = 340; p->height = 136;
    p->fImage = malloc(sizeof(float) * p->width * p->height);
    for (long y = 0; y < p->height; y++) for (long x = 0; x < p->width; x++) p->fImage[y * p->width + x] = x * 4095.f / (p->width - 1);

    NSImage *plain = [p generateThumbnailImageWithWW:4096 WL:2048];
    NSSize size = plain.size;
    check(size.width == 68 && size.height == 27);
    NSMutableData *before = [NSMutableData dataWithBytes:bytes(plain) length:(NSUInteger)(size.width * size.height)];
    const unsigned char *b = before.bytes;
    check(b[0] < 10 && b[(int)size.width - 1] > 245);

    p->inverseVal = YES;
    NSImage *inverted = [p generateThumbnailImageWithWW:4096 WL:2048];
    const unsigned char *i = bytes(inverted);
    for (NSUInteger k = 0; k < before.length; k++) check(i[k] == 255 - b[k]);

    // Window values of 0 use the image's own window, inverted all the same.
    NSImage *automatic = [p generateThumbnailImageWithWW:0 WL:0];
    check(bytes(automatic)[0] > 245);

    // An RGB image never takes the MONOCHROME1 polarity.
    DCMPix *rgb = [DCMPix new];
    rgb->width = 68; rgb->height = 68; rgb->isRGB = YES; rgb->inverseVal = YES;
    rgb->fImage = calloc(68 * 68, 4);
    for (int k = 0; k < 68 * 68; k++) ((unsigned char*)rgb->fImage)[k * 4 + 1] = 200;
    NSImage *colour = [rgb generateThumbnailImageWithWW:256 WL:127];
    check(bytes(colour)[0] > 190);
    NSLog(@"PASS: MONOCHROME1 icons reversed, MONOCHROME2 and RGB icons unchanged");
}}
'''.replace('FUNCTION', icon_function).replace('METHOD', method)

stub = r'''
import CoreData
import Foundation

public final class DicomDatabase: NSObject {
    public var isReadOnly = false
    var local = true
    public var baseDirPath: String?
    public var managedObjectContext: NSManagedObjectContext!
    var saves = 0
    public func isLocal() -> Bool { local }
    public func objects(forEntity name: Any!, predicate: NSPredicate!) -> [Any]! {
        let request = NSFetchRequest<NSManagedObject>(entityName: name as! String)
        request.predicate = predicate
        return try! managedObjectContext.fetch(request)
    }
    public func save(_ err: NSErrorPointer) -> Bool { saves += 1; try! managedObjectContext.save(); return true }
}
'''

main = r'''
import CoreData
import Foundation

func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL: \(message)"); exit(1) } }

UserDefaults.standard.removeObject(forKey: Monochrome1Thumbnails.doneKey)
let entity = NSEntityDescription()
entity.name = "Series"
entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
let modality = NSAttributeDescription(); modality.name = "modality"; modality.attributeType = .stringAttributeType; modality.isOptional = true
let thumbnail = NSAttributeDescription(); thumbnail.name = "thumbnail"; thumbnail.attributeType = .binaryDataAttributeType; thumbnail.isOptional = true
entity.properties = [modality, thumbnail]
let model = NSManagedObjectModel(); model.entities = [entity]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
_ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator

var series: [String: NSManagedObject] = [:]
for m in ["CR", "DX", "MG", "CT", "MR", "OT"] {
    let s = NSManagedObject(entity: entity, insertInto: context)
    s.setValue(m, forKey: "modality"); s.setValue(Data([1, 2, 3]), forKey: "thumbnail")
    series[m] = s
}
try! context.save()

let database = DicomDatabase()
database.managedObjectContext = context
database.baseDirPath = "/tmp/Horos Data"
Monochrome1Thumbnails.rebuildOnce(in: database)
for m in ["CR", "DX", "MG", "OT"] { check(series[m]!.value(forKey: "thumbnail") == nil, "\(m) kept its thumbnail") }
for m in ["CT", "MR"] { check(series[m]!.value(forKey: "thumbnail") != nil, "\(m) lost its thumbnail") }
check(database.saves == 1, "not saved once")

// Once per database: a thumbnail made again afterwards stays.
series["CR"]!.setValue(Data([4]), forKey: "thumbnail")
Monochrome1Thumbnails.rebuildOnce(in: database)
check(series["CR"]!.value(forKey: "thumbnail") != nil && database.saves == 1, "done twice")

// Another database is done on its own; read-only and remote ones are not.
let other = DicomDatabase(); other.managedObjectContext = context; other.baseDirPath = "/tmp/Other Data"
let readOnly = DicomDatabase(); readOnly.managedObjectContext = context; readOnly.baseDirPath = "/tmp/Read Only"; readOnly.isReadOnly = true
let remote = DicomDatabase(); remote.managedObjectContext = context; remote.baseDirPath = "/tmp/Remote"; remote.local = false
Monochrome1Thumbnails.rebuildOnce(in: readOnly)
Monochrome1Thumbnails.rebuildOnce(in: remote)
check(series["CR"]!.value(forKey: "thumbnail") != nil, "a read-only or remote database was changed")
Monochrome1Thumbnails.rebuildOnce(in: other)
check(series["CR"]!.value(forKey: "thumbnail") == nil, "another database was not done")
UserDefaults.standard.removeObject(forKey: Monochrome1Thumbnails.doneKey)
print("PASS: radiography thumbnails dropped once per local, writable database; CT and MR kept")
'''

with tempfile.TemporaryDirectory(prefix='horos-monochrome1-thumbnail-') as folder:
    p = Path(folder)
    (p / 'test.m').write_text(code)
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-framework', 'Cocoa', str(p / 'test.m'), '-o', str(p / 'icon')], check=True)
    subprocess.run([str(p / 'icon')], check=True)

    (p / 'stub.swift').write_text(stub)
    (p / 'main.swift').write_text(main)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(p / 'modules'), '-module-name', 'Thumbs',
                    str(root / 'Horos/Sources/Monochrome1Thumbnails.swift'), str(p / 'stub.swift'), str(p / 'main.swift'),
                    '-o', str(p / 'rebuild')], check=True)
    subprocess.run([str(p / 'rebuild')], check=True)

browser = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('latin1')
opening = browser[browser.index('-(void)setDatabase:(DicomDatabase*)db'):]
opening = opening[:opening.index('[self selectCurrentDatabaseSource];')]
assert '[HorosMonochrome1Thumbnails rebuildOnceInDatabase:db];' in opening, 'the browser does not drop the stored thumbnails'
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
assert project.count('Monochrome1Thumbnails.swift in Sources') == 2, 'Monochrome1Thumbnails.swift is not built'
print('PASS: MONOCHROME1 thumbnails follow the display polarity')

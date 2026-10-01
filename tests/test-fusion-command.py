#!/usr/bin/env python3
"""Run the production fusion command with controlled viewer identities and geometry.

-blendWindows: is Swift since #832 (ViewerController+Blending.swift): the method
is copied out of that file, with the file's own objcIsEqualToString and
normalsAngle helpers, into a Swift extension of a stand-in viewer and compiled
with xcrun swiftc, as the Objective-C version was with clang, with the same
cases. With a git revision as argument, the source is taken from that revision;
a revision older than #832 has the method in ViewerController.m and is compiled
with clang, as before.
"""
from pathlib import Path
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
import re,subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
SWIFT='Horos/Sources/ViewerController+Blending.swift'
def read(path):
 if len(sys.argv)>1:
  r=subprocess.run(['git','-C',str(root),'show',sys.argv[1]+':'+path],capture_output=True)
  return r.stdout.decode('utf-8' if path.endswith('.swift') else 'latin1') if r.returncode==0 else None
 p=root/path
 return p.read_bytes().decode('utf-8' if path.endswith('.swift') else 'latin1') if p.is_file() else None
swift=read(SWIFT)

if swift is not None:
 a=swift.index('    @objc(blendWindows:)');b=swift.index('    @objc(ActivateBlending:)',a);command=swift[a:b]
 # The file's own Objective-C idioms the command uses, as they are written there.
 # (Without the main actor (#961): the stand-ins below are not isolated.)
 helpers=''.join(re.search(r'\n(?:@MainActor )?fileprivate func %s\(.*?\n}\n'%name,swift,re.S).group(0).replace('@MainActor ','') for name in ('objcIsEqualToString','normalsAngle'))
 code=r'''
import Foundation
var viewers = NSMutableArray()
var alerts = 0
func check(_ c: @autoclosure () -> Bool, line: Int = #line) {
    if !c() { fputs("failed: check at line \(line)\n", stderr); exit(1) }
}
enum HorosAlertPanel {
    @discardableResult static func runCritical(title: String, message: String, defaultButton: String, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
// Stands in for the preference, as the Objective-C harness did.
final class UserDefaults {
    static let standard = UserDefaults()
    func float(forKey key: String) -> Float { return 0.01 }
}
final class Geometry: NSObject {
    var tilted = false
    func orientation(_ out: UnsafeMutablePointer<Float>) { for i in 0..<9 { out[i] = 0 }; out[tilted ? 6 : 8] = 1 }
}
final class Image: NSObject {
    var geometry = Geometry()
    var curDCM: Geometry? { return geometry }
    func sendSyncMessage(_ value: Int) {}
}
final class DCMView: NSObject {
    static func angleBetweenVector(_ a: UnsafeMutablePointer<Float>, andVector b: UnsafeMutablePointer<Float>) -> Float { return a[2] == b[2] ? 0 : 90 }
}
final class ViewerController: NSObject {
    var horos_blending: ViewerController?
    var kind: String = "", study: String = "", image = Image(), gantry = false
    class func getDisplayed2DViewers() -> NSMutableArray! { return viewers }
    func blending() -> ViewerController? { return horos_blending }
    func activateBlending(_ other: ViewerController!) { horos_blending = other }
    func modality() -> String! { return kind }
    func studyInstanceUID() -> String! { return study }
    func imageView() -> Image? { return image }
    func isGantryTitled() -> Bool { return gantry }
}
HELPERS
extension ViewerController {
COMMAND
}
func make(_ kind: String, _ study: String) -> ViewerController {
    let v = ViewerController(); v.kind = kind; v.study = study; viewers.add(v); return v
}
let ct = make("CT", "A"), pt = make("PT", "A"), ct2 = make("CT", "B"), pt2 = make("NM", "B")
ct.horos_blending = pt; ct2.horos_blending = pt2
pt.blendWindows(true)
if ct.horos_blending != nil || ct2.horos_blending !== pt2 || alerts != 0 {
    fputs("FAIL: secondary command did not detach its owner without affecting unrelated pair/alerting\n", stderr); exit(1)
}
pt.blendWindows(true); check(ct.horos_blending === pt && ct2.horos_blending === pt2 && alerts == 0)
ct.blendWindows(true); check(ct.horos_blending == nil && ct2.horos_blending === pt2)
ct2.horos_blending = nil
ct.blendWindows(true); check(ct.horos_blending === pt && ct2.horos_blending == nil)
ct.blendWindows(true); check(ct.horos_blending == nil)
ct.blendWindows(nil); check(ct.horos_blending === pt && ct2.horos_blending === pt2)
let mr = make("MR", "C"); mr.blendWindows(true); check(alerts == 1 && ct.horos_blending === pt && ct2.horos_blending === pt2)
ct.horos_blending = nil; pt.image.geometry.tilted = true; ct.blendWindows(true); check(alerts == 2 && ct.horos_blending == nil && ct2.horos_blending === pt2)
pt.image.geometry.tilted = false; pt.gantry = true; ct.blendWindows(true); check(alerts == 3 && ct.horos_blending == nil)
print("PASS: CT/PT symmetric toggle, selected-pair isolation, automatic pairing and incompatible geometry diagnostics")
'''.replace('HELPERS',helpers).replace('COMMAND',command)
 with tempfile.TemporaryDirectory(prefix='horos-fusion-command-') as d:
  p=Path(d);(p/'main.swift').write_text(code)
  subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
  subprocess.run([str(p/'test')],check=True)
 sys.exit(0)

s=read('Horos/Sources/ViewerController.m')
a=s.index('-(IBAction) blendWindows:');b=s.index('-(void) ActivateBlending:',a)
code=r'''
#import <Cocoa/Cocoa.h>
#include <assert.h>
static NSMutableArray *viewers;
static int alerts;
#define NSRunCriticalAlertPanel(...) (++alerts)
@interface Geometry:NSObject { @public BOOL tilted; }
- (void)orientation:(float *)out;
@end
@implementation Geometry
- (void)orientation:(float *)out { memset(out,0,9*sizeof(float));out[tilted?6:8]=1; }
@end
@interface Image:NSObject { @public Geometry *geometry; }
- (id)curDCM; - (void)sendSyncMessage:(int)value;
@end
@implementation Image
- (id)curDCM {return geometry;} - (void)sendSyncMessage:(int)value {}
@end
@interface DCMView:NSObject
+ (float)angleBetweenVector:(float *)a andVector:(float *)b;
@end
@implementation DCMView
+ (float)angleBetweenVector:(float *)a andVector:(float *)b { return a[2]==b[2]?0:90; }
@end
@interface Preferences:NSObject
+ (id)standardUserDefaults; - (float)floatForKey:(NSString *)key;
@end
@implementation Preferences
+ (id)standardUserDefaults {return [[[self alloc] init] autorelease];}
- (float)floatForKey:(NSString *)key {return .01;}
@end
#define NSUserDefaults Preferences
@interface ViewerController:NSObject {
@public ViewerController *blendingController; NSString *kind,*study; Image *image; BOOL gantry;
}
+ (NSMutableArray *)getDisplayed2DViewers;
- (id)blendingController; - (void)ActivateBlending:(ViewerController *)other;
- (NSString *)modality; - (NSString *)studyInstanceUID; - (id)imageView; - (BOOL)isGantryTitled;
- (void)blendWindows:(id)sender;
@end
@implementation ViewerController
+ (NSMutableArray *)getDisplayed2DViewers {return viewers;}
- (id)blendingController {return blendingController;}
- (void)ActivateBlending:(ViewerController *)other {blendingController=other;}
- (NSString *)modality {return kind;} - (NSString *)studyInstanceUID {return study;}
- (id)imageView {return image;} - (BOOL)isGantryTitled {return gantry;}
COMMAND
@end
ViewerController *make(NSString *kind,NSString *study) {
 ViewerController *v=[[[ViewerController alloc] init] autorelease];v->kind=kind;v->study=study;
 v->image=[[[Image alloc] init] autorelease];v->image->geometry=[[[Geometry alloc] init] autorelease];[viewers addObject:v];return v;
}
int main(){@autoreleasepool {
 viewers=[NSMutableArray array];
 ViewerController *ct=make(@"CT",@"A"),*pt=make(@"PT",@"A"),*ct2=make(@"CT",@"B"),*pt2=make(@"NM",@"B");
 ct->blendingController=pt;ct2->blendingController=pt2;
 [pt blendWindows:@YES];
 if(ct->blendingController || ct2->blendingController!=pt2 || alerts){fprintf(stderr,"FAIL: secondary command did not detach its owner without affecting unrelated pair/alerting\n");return 1;}
 [pt blendWindows:@YES];assert(ct->blendingController==pt && ct2->blendingController==pt2 && alerts==0);
 [ct blendWindows:@YES];assert(!ct->blendingController && ct2->blendingController==pt2);
 ct2->blendingController=nil;
 [ct blendWindows:@YES];assert(ct->blendingController==pt && !ct2->blendingController);
 [ct blendWindows:@YES];assert(!ct->blendingController);
 [ct blendWindows:nil];assert(ct->blendingController==pt && ct2->blendingController==pt2);
 ViewerController *mr=make(@"MR",@"C");[mr blendWindows:@YES];assert(alerts==1 && ct->blendingController==pt && ct2->blendingController==pt2);
 ct->blendingController=nil;pt->image->geometry->tilted=YES;[ct blendWindows:@YES];assert(alerts==2 && !ct->blendingController && ct2->blendingController==pt2);
 pt->image->geometry->tilted=NO;pt->gantry=YES;[ct blendWindows:@YES];assert(alerts==3 && !ct->blendingController);
 puts("PASS: CT/PT symmetric toggle, selected-pair isolation, automatic pairing and incompatible geometry diagnostics");
}}
'''.replace('COMMAND',s[a:b])
with tempfile.TemporaryDirectory(prefix='horos-fusion-command-') as d:
 p=Path(d);(p/'test.m').write_text(code)
 subprocess.run(['xcrun','clang',str(p/'test.m'),'-framework','Cocoa','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

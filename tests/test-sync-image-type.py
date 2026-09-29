#!/usr/bin/env python3
"""Test production nearest-plane selection with equal-position image types.

The plane selection is Swift since #834 (DCMView+WindowLevel+Coordinates.swift):
its methods are compiled as written into a Swift stand-in for DCMView. A git
revision as argument (the baseline without the type preference) reads the
sources of that revision: the Objective-C of DCMView.m when the Swift file does
not exist there, the Swift otherwise.
"""
from pathlib import Path
import subprocess,tempfile,sys,re
import harness_defaults  # the harness's preferences stay in its own process (#923)
root=Path(__file__).resolve().parents[1]
SWIFT='Horos/Sources/DCMView+WindowLevel+Coordinates.swift'
revision=sys.argv[1] if len(sys.argv)>1 else None
def show(path): return subprocess.check_output(['git','-C',str(root),'show',revision+':'+path]).decode('latin1' if path.endswith('.m') else 'utf-8')
swift=revision is None or subprocess.run(['git','-C',str(root),'cat-file','-e',revision+':'+SWIFT],capture_output=True).returncode==0

objc_code=r'''
#import <Foundation/Foundation.h>
#include <math.h>
#define N2LogExceptionWithStackTrace(e) ((void)0)
@interface DCMPix:NSObject
@property(copy) NSString *imageType;
@property float z,sliceThickness;
-(void)orientation:(float*)v;-(void)origin:(float*)v;
@end
@implementation DCMPix
-(void)orientation:(float*)v{for(int i=0;i<9;i++)v[i]=0;v[0]=v[4]=v[8]=1;}
-(void)origin:(float*)v{v[0]=v[1]=0;v[2]=self.z;}
@end
@interface DCMView:NSObject { @public NSArray *dcmPixList,*cleanedOutDcmPixArray;int volumicData; }
@property(retain) DCMPix *curDCM;
+(float)angleBetweenVector:(float*)a andVector:(float*)b;
+(float)pbase_Plane:(float*)p :(float*)o :(float*)v :(float*)l;
-(int)findPlaneForPoint:(float*)p preferParallelTo:(float*)o localPoint:(float*)l distanceWithPlane:(float*)d preferImageType:(NSString*)t;
@end
@implementation DCMView
+(float)angleBetweenVector:(float*)a andVector:(float*)b{return 0;}
+(float)pbase_Plane:(float*)p :(float*)o :(float*)v :(float*)l{l[0]=p[0];l[1]=p[1];l[2]=o[2];return fabsf(p[2]-o[2]);}
METHODS
@end
static DCMPix *pix(NSString*t,float z){DCMPix*p=[DCMPix new];p.imageType=t;p.z=z;p.sliceThickness=1;return p;}
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
 [[NSUserDefaults standardUserDefaults] setFloat:1 forKey:@"PARALLELPLANETOLERANCE"];
 DCMView*v=[DCMView new];v->volumicData=1;
 // Interleave types to exercise original array mapping and deterministic fallback.
 v->dcmPixList=@[pix(@"F",0),pix(@"W",0),pix(@"IP",0),pix(@"IP",1),pix(@"F",1),pix(@"W",1)];v.curDCM=v->dcmPixList[0];
 float p[3]={0,0,0},o[9]={1,0,0,0,1,0,0,0,1},distance;
 check([[DCMView cleanedOutDcmPixArray:v->dcmPixList] isEqual:v->dcmPixList]);
 for(NSString*t in @[@"F",@"W",@"IP"]){
  int i=[v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:&distance preferImageType:t];
  check([[(DCMPix*)v->dcmPixList[i] imageType] isEqual:t] && distance==0);
 }
 check([v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL preferImageType:@"missing"]==0);
 check([v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL]==0);
 p[2]=1;check([v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL preferImageType:@"W"]==5);
 // Matching type on a farther plane must not override geometry.
 v->dcmPixList=@[pix(@"F",0),pix(@"W",1)];v->cleanedOutDcmPixArray=nil;p[2]=0;
 check([v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL preferImageType:@"W"]==0);
 p[2]=100;check([v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL preferImageType:@"W"]==-1);
 NSLog(@"PASS: equal-plane type preference, original indices, stable fallback and geometric priority");
}}
'''

# The same stand-ins and checks in Swift. The helpers the methods call
# (objcObject, objcProperty, objcArray and the imageType getter) are the
# production ones; the exception log is a no-op, as N2LogExceptionWithStackTrace
# was in the Objective-C harness.
swift_code=r'''
import Foundation
enum HorosObjCException { static func perform(_ block: () -> Void) throws { block() } }
func logException(_ error: Error, _ function: StaticString) {}
HELPERS
class DCMPix: NSObject {
 @objc var imageType: String?
 var z: Float = 0, sliceThickness: Double = 0
 func orientation(_ v: UnsafeMutablePointer<Float>!) { for i in 0..<9 { v[i] = 0 }; v[0] = 1; v[4] = 1; v[8] = 1 }
 func origin(_ v: UnsafeMutablePointer<Float>!) { v[0] = 0; v[1] = 0; v[2] = self.z }
}
IMAGE_TYPE_GETTER
class DCMView: NSObject {
 var horos_dcmPixList: NSMutableArray! = nil
 var horos_cleanedOutDcmPixArray: NSArray! = nil
 var horos_volumicData: Int32 = 0
 var curDCM: DCMPix? = nil
 @objc(angleBetweenVector:andVector:) class func angleBetweenVector(_ a: UnsafeMutablePointer<Float>!, andVector b: UnsafeMutablePointer<Float>!) -> Float { return 0 }
 @objc(pbase_Plane::::) class func pbase_Plane(_ p: UnsafeMutablePointer<Float>!, _ o: UnsafeMutablePointer<Float>!, _ v: UnsafeMutablePointer<Float>!, _ l: UnsafeMutablePointer<Float>!) -> Float { l[0] = p[0]; l[1] = p[1]; l[2] = o[2]; return fabsf(p[2] - o[2]) }
METHODS
}
func pix(_ t: String, _ z: Float) -> DCMPix { let p = DCMPix(); p.imageType = t; p.z = z; p.sliceThickness = 1; return p }
func check(_ condition: Bool, _ text: String) { if !condition { NSLog("FAIL: %@", text); exit(1) } }
autoreleasepool {
 UserDefaults.standard.set(Float(1), forKey: "PARALLELPLANETOLERANCE")
 let v = DCMView(); v.horos_volumicData = 1
 // Interleave types to exercise original array mapping and deterministic fallback.
 v.horos_dcmPixList = NSMutableArray(array: [pix("F", 0), pix("W", 0), pix("IP", 0), pix("IP", 1), pix("F", 1), pix("W", 1)]); v.curDCM = (v.horos_dcmPixList[0] as! DCMPix)
 var p: [Float] = [0, 0, 0], o: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1], distance: Float = 0
 check(DCMView.cleanedOutDcmPixArray(v.horos_dcmPixList).isEqual(v.horos_dcmPixList), "[[DCMView cleanedOutDcmPixArray:v->dcmPixList] isEqual:v->dcmPixList]")
 for t in ["F", "W", "IP"] {
  let i = v.findPlane(forPoint: &p, preferParallelTo: &o, localPoint: nil, distanceWithPlane: &distance, preferImageType: t as NSString)
  check((v.horos_dcmPixList[Int(i)] as! DCMPix).imageType == t && distance == 0, "[[(DCMPix*)v->dcmPixList[i] imageType] isEqual:t] && distance==0")
 }
 check(v.findPlane(forPoint: &p, preferParallelTo: &o, localPoint: nil, distanceWithPlane: nil, preferImageType: "missing") == 0, "[v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL preferImageType:@\"missing\"]==0")
 check(v.findPlane(forPoint: &p, preferParallelTo: &o, localPoint: nil, distanceWithPlane: nil) == 0, "[v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL]==0")
 p[2] = 1; check(v.findPlane(forPoint: &p, preferParallelTo: &o, localPoint: nil, distanceWithPlane: nil, preferImageType: "W") == 5, "[v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL preferImageType:@\"W\"]==5")
 // Matching type on a farther plane must not override geometry.
 v.horos_dcmPixList = NSMutableArray(array: [pix("F", 0), pix("W", 1)]); v.horos_cleanedOutDcmPixArray = nil; p[2] = 0
 check(v.findPlane(forPoint: &p, preferParallelTo: &o, localPoint: nil, distanceWithPlane: nil, preferImageType: "W") == 0, "[v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL preferImageType:@\"W\"]==0")
 p[2] = 100; check(v.findPlane(forPoint: &p, preferParallelTo: &o, localPoint: nil, distanceWithPlane: nil, preferImageType: "W") == -1, "[v findPlaneForPoint:p preferParallelTo:o localPoint:NULL distanceWithPlane:NULL preferImageType:@\"W\"]==-1")
 NSLog("PASS: equal-plane type preference, original indices, stable fallback and geometric priority")
}
'''

if swift:
    s=show(SWIFT) if revision else (root/SWIFT).read_text(encoding='utf-8')
    a=s.index('    @objc(cleanedOutDcmPixArray:)\n');b=s.index('    @objc(drawOrientation:)\n',a)
    h=s.index('@inline(__always)\nprivate func objcObject<T: AnyObject>')
    helpers=s[h:s.index('/// `[[dictionary objectForKey:',h)]
    getter=re.search(r'private let kImageTypeGetter = .*',s).group(0)
    code=swift_code.replace('METHODS',s[a:b]).replace('HELPERS',helpers).replace('IMAGE_TYPE_GETTER',getter)
    if revision:
        # Baseline has only the original spatial selector, which has no type input.
        code=re.sub(r', preferImageType: (?:t as NSString|"[^"]*")', '', code)
        code=code.replace('check(DCMView.cleanedOutDcmPixArray(v.horos_dcmPixList).isEqual(v.horos_dcmPixList), "[[DCMView cleanedOutDcmPixArray:v->dcmPixList] isEqual:v->dcmPixList]")', '_ = 0')
else:
    s=show('Horos/Sources/DCMView.m')
    a=s.index('+ (NSArray*)cleanedOutDcmPixArray:');b=s.index('\n- (void) drawOrientation:',a)
    code=objc_code.replace('METHODS',s[a:b])
    # Baseline has only the original spatial selector, which has no type input.
    code=re.sub(r' preferImageType:(?:t|@"[^"]*")', '', code)
    code=code.replace('check([[DCMView cleanedOutDcmPixArray:v->dcmPixList] isEqual:v->dcmPixList]);', '(void)0;')
with tempfile.TemporaryDirectory(prefix='horos-sync-type-') as d:
 p=Path(d)
 if swift:
  (p/'test.swift').write_text(harness_defaults.SWIFT + code)
  subprocess.run(['xcrun','swiftc','-Onone','-sanitize=undefined',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 else:
  (p/'test.m').write_text(code + harness_defaults.OBJC)
  subprocess.run(['xcrun','clang','-fno-objc-arc','-fsanitize=undefined','-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

#!/usr/bin/env python3
"""Verify each accepted single-frame export owns a fresh exporter session.

The export of VRView is Swift (VRView+Export.swift): its branch for the
current image is compiled into a Swift harness whose exporter counts its
instances. A revision given as argument whose export is still Objective-C
(VRView.m or VRView.mm) is checked the former way, which is how the bug the
test guards against is shown to fail."""
from pathlib import Path
import subprocess, tempfile, sys
root=Path(__file__).resolve().parents[1]
def revision_file(rev, name):
    shown = subprocess.run(['git', 'show', rev + ':' + name], capture_output=True)
    return shown.stdout if shown.returncode == 0 else None
def revision_source(rev):
    # VRView.mm became VRView.m when its VTK code moved to the adapter.
    for name in ('Horos/Sources/VRView.m', 'Horos/Sources/VRView.mm'):
        shown = revision_file(rev, name)
        if shown is not None:
            return shown
    sys.exit('no VRView source at ' + rev)
rev = sys.argv[1] if len(sys.argv) > 1 else None
export = root/'Horos/Sources/VRView+Export.swift'
swift = revision_file(rev, 'Horos/Sources/VRView+Export.swift') if rev else (export.read_bytes() if export.exists() else None)
if swift is not None:
    s = swift.decode('utf-8')
    a = s.index('\n', s.index('// CURRENT image only')) + 1
    # The outlet is `dcmExportMode` since the class is Swift, `horos_dcmExportMode` before.
    b = next(s.index(marker, a) for marker in ('} else if selectedTag(dcmExportMode) == 2 {',
                                               '} else if selectedTag(horos_dcmExportMode) == 2 {') if marker in s[a:])
    body = s[a:b]
    harness = r'''
import Foundation
var created = 0, destroyed = 0
final class DICOMExport {
    let serial: Int
    var instance = 1
    var number = 0
    init() { created += 1; serial = created }
    deinit { destroyed += 1 }
    func setSeriesNumber(_ value: Int) { number = value }
}
func seriesNumberMinuteAndSecond() -> Int { 3 + 4 }
final class Peer {
    var exportDCM: DICOMExport!
    func exportDCMCurrentImage(in16bit depth: Bool) -> [AnyHashable: Any] {
        defer { exportDCM.instance += 1 }
        return ["session": exportDCM.serial, "instance": exportDCM.instance, "number": exportDCM.number, "depth": depth]
    }
    func request(_ fullDepthCapture: Bool) -> [AnyHashable: Any] {
        var producedFiles: [[AnyHashable: Any]] = []
BODY
        return producedFiles.last!
    }
}
var view: Peer? = Peer()
for i in 1...100 {
    let r = view!.request(i % 2 == 1)
    if r["session"] as! Int != i || r["instance"] as! Int != 1 {
        FileHandle.standardError.write("FAIL: independent request reused its prior exporter session\n".data(using: .utf8)!)
        exit(1)
    }
    precondition(r["number"] as! Int == 5227 && r["depth"] as! Bool == (i % 2 == 1))
    precondition(created == i && destroyed == i - 1)
}
view = nil
precondition(created == destroyed)
print("PASS: 100 requests within the same clock second create fresh sessions, reset instance state and release prior ownership")
'''.replace('BODY', body)
    with tempfile.TemporaryDirectory(prefix='horos-export-session-') as d:
        p = Path(d); (p/'test.swift').write_text(harness)
        subprocess.run(['xcrun', 'swiftc', str(p/'test.swift'), '-o', str(p/'test')], check=True)
        sys.exit(subprocess.run([str(p/'test')]).returncode)
s=(revision_source(rev) if rev else (root/'Horos/Sources/VRView.m').read_bytes()).decode('latin1')
a=s.index('\n        {',s.index('// CURRENT image only'))+len('\n        {')
b=s.index('// 4th dimension',a)
body=s[a:b].rsplit('        }',1)[0].replace('[NSCalendarDate date]','[FixedDate date]').replace('[DCMCalendarDate date]','[FixedDate date]').replace('[IsiXDICOMCalendarDate date]','[FixedDate date]')
code=r'''
#import <Foundation/Foundation.h>
#include <cassert>
static int created, destroyed;
@interface FixedDate:NSObject
+ (FixedDate*)date;
- (int)minuteOfHour;
- (int)secondOfMinute;
@end
@implementation FixedDate
+ (FixedDate*)date{return [[[self alloc] init] autorelease];}
- (int)minuteOfHour{return 3;}
- (int)secondOfMinute{return 4;}
@end
@interface DICOMExport:NSObject { @public int serial,instance; long number; }
- (void)setSeriesNumber:(long)value;
@end
@implementation DICOMExport
- (id)init {if((self=[super init])){serial=++created;instance=1;}return self;}
- (void)setSeriesNumber:(long)value {number=value;}
- (void)dealloc {destroyed++;[super dealloc];}
@end
@interface Peer:NSObject { @public DICOMExport *exportDCM; }
- (NSDictionary*)exportDCMCurrentImageIn16bit:(BOOL)depth;
- (NSDictionary*)request:(BOOL)depth;
@end
@implementation Peer
- (NSDictionary*)exportDCMCurrentImageIn16bit:(BOOL)depth {
 return @{ @"session":@(exportDCM->serial), @"instance":@(exportDCM->instance++), @"number":@(exportDCM->number), @"depth":@(depth) };
}
- (NSDictionary*)request:(BOOL)fullDepthCapture {
 NSMutableArray *producedFiles=[NSMutableArray array];
BODY
 return [producedFiles lastObject];
}
- (void)dealloc {[exportDCM release];[super dealloc];}
@end
int main(){@autoreleasepool{
 Peer *view=[Peer new];
 for(int i=1;i<=100;i++){
  NSDictionary *r=[view request:i%2];
  if([r[@"session"] intValue]!=i || [r[@"instance"] intValue]!=1){fprintf(stderr,"FAIL: independent request reused its prior exporter session\n");return 1;}
  assert([r[@"number"] intValue]==5227);assert([r[@"depth"] boolValue]==(i%2));
  assert(created==i && destroyed==i-1);
 }
 [view release];assert(created==destroyed);
 puts("PASS: 100 requests within the same clock second create fresh sessions, reset instance state and release prior ownership");
}}
'''.replace('BODY',body)
with tempfile.TemporaryDirectory(prefix='horos-export-session-') as d:
 p=Path(d);(p/'test.mm').write_text(code)
 subprocess.run(['xcrun','clang++','-std=c++11','-fsanitize=address',str(p/'test.mm'),'-framework','Foundation','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

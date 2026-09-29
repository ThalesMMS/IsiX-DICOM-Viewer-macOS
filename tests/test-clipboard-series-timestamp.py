#!/usr/bin/env python3
"""Execute the real clipboard description setup with macOS date formatting.

-pasteImageForSourceFile: is Swift since #831, in
BrowserController+DatabaseDragExport+Selection.swift: the block that names the
DICOMExport series is taken from there and compiled with swiftc (address
sanitizer on) around a DICOMExport double. With a git revision as argument, the
block is taken from that revision: its Swift file, or, for a revision older
than #831, BrowserController.m, compiled with clang as before.
"""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
SWIFT='Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift'
def revision(path):
 r=subprocess.run(['git','-C',str(root),'show',sys.argv[1]+':'+path],capture_output=True)
 return r.stdout if r.returncode==0 else None
if len(sys.argv)>1:
 swift=revision(SWIFT)
 swift=swift.decode('utf-8') if swift is not None else None
else:
 swift=(root/SWIFT).read_text(encoding='utf-8')
if swift is not None:
 a=swift.index('            let e = DICOMExport()',swift.index('func pasteImage(forSourceFile '));b=swift.index('            e.setSeriesNumber(',a)
 block=swift[a:b]
 program=r'''
import Foundation
final class DICOMExport {
 var seriesDescription: String?
 func setSeriesDescription(_ description: String!) { seriesDescription = description }
}
BLOCK
guard let description = e.seriesDescription, let text = description.cString(using: .isoLatin1), text.count > 1 else {
 print("FAIL: generated description cannot be encoded in source Latin1"); exit(1)
}
let re = try! NSRegularExpression(pattern: "^Clipboard - [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$")
if re.numberOfMatches(in: description, range: NSRange(location: 0, length: (description as NSString).length)) != 1 { exit(2) }
print("PASS: generated clipboard timestamp remains Latin1/ASCII representable on current macOS")
'''.replace('BLOCK',block)
 with tempfile.TemporaryDirectory(prefix='horos-clipboard-date-') as folder:
  p=Path(folder);(p/'main.swift').write_text(program)
  subprocess.run(['xcrun','swiftc','-sanitize=address',str(p/'main.swift'),'-o',str(p/'test')],check=True)
  subprocess.run([str(p/'test')],check=True)
 sys.exit(0)
s=revision('Horos/Sources/BrowserController.m')
if s is None: sys.exit('FAIL: %s has neither %s nor BrowserController.m'%(sys.argv[1],SWIFT))
s=s.decode('latin1')
a=s.index('        DICOMExport *e =',s.index('- (IBAction) pasteImageForSourceFile:'));b=s.index('        [e setSeriesNumber:',a)
block=s[a:b]
program=r'''
#import <Foundation/Foundation.h>
@interface DICOMExport:NSObject
@property(retain) NSString *seriesDescription;
@end
@implementation DICOMExport
@synthesize seriesDescription;
- (void)dealloc {[seriesDescription release];[super dealloc];}
@end
@interface BrowserController:NSObject @end
@implementation BrowserController
+ (NSString*)DateTimeWithSecondsFormat:(NSDate*)date {
 NSDateFormatter *f=[[[NSDateFormatter alloc] init] autorelease];
 f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US"];f.dateStyle=NSDateFormatterShortStyle;f.timeStyle=NSDateFormatterMediumStyle;
 return [f stringFromDate:date];
}
@end
int main(){@autoreleasepool {
 BLOCK
 const char *text=[e.seriesDescription cStringUsingEncoding:NSISOLatin1StringEncoding];
 if(!text || !strlen(text)) {puts("FAIL: generated description cannot be encoded in source Latin1");return 1;}
 NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^Clipboard - [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$" options:0 error:NULL];
 if([re numberOfMatchesInString:e.seriesDescription options:0 range:NSMakeRange(0,e.seriesDescription.length)]!=1)return 2;
 puts("PASS: generated clipboard timestamp remains Latin1/ASCII representable on current macOS");
}}
'''.replace('BLOCK',block)
with tempfile.TemporaryDirectory(prefix='horos-clipboard-date-') as folder:
 p=Path(folder);(p/'test.m').write_text(program)
 subprocess.run(['xcrun','clang','-fsanitize=address',str(p/'test.m'),'-framework','Foundation','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

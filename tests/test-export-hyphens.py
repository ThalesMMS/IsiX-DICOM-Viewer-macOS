#!/usr/bin/env python3
"""Exercise the real sanitizer's normal-folder and legacy/DICOMDIR policies.

The sanitizer is Swift (BrowserController+DICOMExport.swift, with the rules of
IsiXDatabase's ExportNaming): compiled here as it is and called from this
Objective-C driver through the generated interface, as the app's Objective-C
callers call it.
"""
from pathlib import Path
import subprocess,tempfile,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from isix_modules import module_flags,link_flags
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
a=s.index('    @objc(replaceNotAdmitted:)\n');b=s.index('    /// The patient folder the export',a)
swift=r'''
import Foundation
import IsiXDatabase
@objc(BrowserController) public class BrowserController: NSObject {}
extension BrowserController {
BODY
}
'''.replace('BODY',s[a:b])
code=r'''
#import <Foundation/Foundation.h>
#import "Harness-Swift.h"
int main(){@autoreleasepool{
 NSArray *names=@[@"Chr-P03R",@"ChrP03R",@"Chr_P03R",@"A--B",@"A-B_C",@"João-Silva"];
 NSMutableSet *outputs=[NSMutableSet set];
 for(NSString *name in names){
  NSString *result=[BrowserController replaceNotAdmitted:[NSMutableString stringWithString:name] preserveHyphens:YES];
  NSCAssert([result isEqual:name],@"valid hyphen/underscore changed");[outputs addObject:result];
  NSString *legacy=[BrowserController replaceNotAdmitted:[NSMutableString stringWithString:name]];
  NSCAssert([legacy isEqual:[name stringByReplacingOccurrencesOfString:@"-" withString:@""]],@"legacy naming changed");
  NSCAssert([legacy isEqual:[BrowserController replaceNotAdmitted:[NSMutableString stringWithString:name] preserveHyphens:NO]],@"DICOMDIR compatibility changed");
 }
 for(NSString *immutable in @[@"Chr-P03R", [NSString stringWithFormat:@"%@",@"A-B"], [NSString stringWithFormat:@"%@ %@",@"A-long-hyphenated-name",@"with-a-second-component"]]) {
  NSString *before=[[immutable copy] autorelease];
  NSString *filtered=[BrowserController replaceNotAdmitted:immutable preserveHyphens:YES];
  NSCAssert([immutable isEqual:before],@"immutable source changed");
  NSCAssert([filtered isEqual:[before stringByReplacingOccurrencesOfString:@" " withString:@"_"]],@"immutable result incorrect");
  NSCAssert([filtered isKindOfClass:[NSMutableString class]],@"result is not mutable");
  [(NSMutableString*)filtered appendString:@"_proof"];
 }
 NSCAssert(outputs.count==names.count,@"valid names collided");
 NSMutableString *mutable=[NSMutableString stringWithString:@"A-B / C:*?\\D"];
 id result=[BrowserController replaceNotAdmitted:mutable preserveHyphens:YES];
 NSCAssert(result==mutable && [mutable isEqual:@"A-B__CD"],@"mutation/unsafe-character policy changed");
 NSCAssert([BrowserController replaceNotAdmitted:nil preserveHyphens:YES]==nil,@"nil changed");
 puts("PASS: hyphen/underscore distinctions preserved for ordinary folders; legacy policy, unsafe-character filtering and mutable callers preserved; immutable constant/tagged/heap strings copied safely");
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-export-hyphen-') as folder:
 p=Path(folder);(p/'test.m').write_text(code);(p/'Harness.swift').write_text(swift)
 modules=p/'modules';flags=module_flags('IsiXDatabase',modules)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-module-name','Harness',*flags[:2],'-emit-objc-header-path',str(p/'Harness-Swift.h'),
                 '-c',str(p/'Harness.swift'),'-o',str(p/'harness.o')],check=True)
 subprocess.run(['xcrun','clang','-c','-fmodules','-fno-objc-arc','-I',str(p),str(p/'test.m'),'-o',str(p/'test.o')],check=True)
 subprocess.run(['xcrun','swiftc',str(p/'test.o'),str(p/'harness.o'),*link_flags('IsiXDatabase',modules),'-framework','Foundation','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

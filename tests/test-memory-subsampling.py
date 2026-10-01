#!/usr/bin/env python3
"""Exercise the production allocation-failure retry branch without allocating images."""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
s = (subprocess.check_output(['git', 'show', sys.argv[1]+':Horos/Sources/BrowserController.m']).decode('latin1')
     if len(sys.argv)>1 else (root/'Horos/Sources/BrowserController.m').read_bytes().decode('latin1'))
a = s.index('NSLog(@"Test memory failed -> sub-sampling");')
b = s.index('\n            }\n            else enoughMemory = YES;', a)
# Historical controls keep the retry body; only their old alert entry point
# is routed through the current production bridge, whose modal UI is recorded.
branch = s[a:b].replace('NSRunInformationalAlertPanel(', 'HorosRunInformationalAlertPanel(')
code = r'''
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "HorosAlertPanel.h"
#include <limits.h>
#define NSManagedObject NSObject
static int alerts;
static NSModalResponse TestAlertRun(NSAlert *alert, SEL selector){alerts++;return NSAlertFirstButtonReturn;}
static NSArray *retry(NSArray *toOpenArray,long *sampling){
 long subSampling=*sampling;
 BRANCH
 *sampling=subSampling;
 return toOpenArray;
}
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
 method_setImplementation(class_getInstanceMethod(NSAlert.class,@selector(runModal)),(IMP)TestAlertRun);
 long sampling=1;
 NSArray *files=@[@[@0,@1,@2,@3,@4],@[@5],@[]];
 files=retry(files,&sampling);check([files isEqual:@[@[@0,@2,@4],@[@5]]] && sampling==2);
 files=retry(files,&sampling);check([files isEqual:@[@[@0,@4],@[@5]]] && sampling==4);
 files=retry(files,&sampling);check([files isEqual:@[@[@0],@[@5]]] && sampling==8);
 check(retry(files,&sampling)==nil && alerts==1);
 sampling=1;check(retry(@[@[@{@"numberOfFrames":@4096}]],&sampling)==nil && sampling==1);
 sampling=LONG_MAX;check(retry(@[@[@0,@1]],&sampling)==nil && sampling==LONG_MAX);
 sampling=1;check(retry(@[@[]],&sampling)==nil);
 NSLog(@"PASS: retries strictly shrink selections and terminate for singleton, multiframe, empty and overflow cases");
}}
'''.replace('BRANCH',branch)
with tempfile.TemporaryDirectory(prefix='horos-subsampling-') as d:
 p=Path(d);(p/'test.m').write_text(code)
 subprocess.run(['xcrun','clang','-fno-objc-arc','-fblocks','-Werror=deprecated-declarations','-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(root/'Horos/Sources'),'-framework','AppKit',str(p/'test.m'),str(root/'Horos/Sources/HorosAlertPanel.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

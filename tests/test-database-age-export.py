#!/usr/bin/env python3
"""Run actual database-list export with the actual age-display preference branch.

-exportDBListOnlySelected: is Swift, in
BrowserController+DatabaseDragExport+Selection.swift; the age display
(-outlineView:objectValueForTableColumn:byItem:) is still in BrowserController.m.
Both are taken as they stand: the display branch is compiled with clang into an
Objective-C double of the browser, and the export, with the helpers it calls,
into a Swift extension of that double (address sanitizer on both sides). With a
git revision as argument, both are taken from that revision; a revision older
than the Swift translation has the export in BrowserController.m and is compiled with clang only,
as before.
"""
from pathlib import Path
import re,subprocess,tempfile,sys
import harness_defaults  # the harness's preferences stay in its own process
root=Path(__file__).resolve().parents[1]
SWIFT='Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift'
def read(path):
 if len(sys.argv)>1:
  r=subprocess.run(['git','-C',str(root),'show',sys.argv[1]+':'+path],capture_output=True)
  return r.stdout.decode('utf-8' if path.endswith('.swift') else 'latin1') if r.returncode==0 else None
 return (root/path).read_bytes().decode('utf-8' if path.endswith('.swift') else 'latin1')
s=read('Horos/Sources/BrowserController.m')
swift=read(SWIFT)
a=s.index('        switch ( [[NSUserDefaults standardUserDefaults] integerForKey: @"yearOldDatabaseDisplay"])');b=s.index('\n    if( [[tableColumn identifier] isEqualToString:@"noSeries"])',a);display=s[a:b].rsplit('    }',1)[0]

if swift is not None:
 a=swift.index('    @objc(exportDBListOnlySelected:)');b=swift.index('\n    }\n',a)+len('\n    }\n');export=swift[a:b]
 # The file's own Objective-C idioms the export uses, as they are written there.
 helpers=''
 for name in ('objcTry','objcIsType','objcAppend'):
  m=re.search(r'(?:@inline\(__always\)\n)?fileprivate func '+name+r'\b.*?\n}\n',swift,re.S)
  helpers+=m.group(0)+'\n'
 header=r'''
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf);
@interface Outline:NSOutlineView
@property(retain) NSDictionary *study;
@end
@interface Browser:NSObject
@property(retain) Outline *horos_databaseOutline;
- (id)outlineView:(NSOutlineView*)outlineView objectValueForTableColumn:(NSTableColumn*)tableColumn byItem:(id)item;
@end
'''
 code=r'''
#import "Harness.h"
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { abort(); }
@implementation Outline
- (NSIndexSet*)selectedRowIndexes{return [NSIndexSet indexSetWithIndex:0];}
- (NSInteger)numberOfRows{return 1;}
- (id)itemAtRow:(NSInteger)row{return self.study;}
- (void)dealloc{[_study release];[super dealloc];}
@end
@implementation Browser
- (id)outlineView:(NSOutlineView*)outlineView objectValueForTableColumn:(NSTableColumn*)tableColumn byItem:(id)item {
DISPLAY
 return nil;
}
- (void)dealloc{[_horos_databaseOutline release];[super dealloc];}
@end
'''.replace('DISPLAY',display)
 extension='import Cocoa\n\n'+helpers+'extension Browser {\n'+export+'}\n'
 main=r'''
import Cocoa
_ = NSApplication.shared
let outline = Outline()
let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("yearOld"))
col.headerCell.stringValue = "Age"
outline.addTableColumn(col)
let browser = Browser()
browser.horos_databaseOutline = outline
let cases = [["36 y","30 y","36/30 y"],["6 d","2 d","6 d/2 d"],["5 m","2 m","5 m/2 m"],["1 y 3 m","7 m","1 y 3 m/7 m"],["","",""],["20 y","20 y","20 y"]]
for values in cases {
 for mode in 0..<3 {
  UserDefaults.standard.set(mode, forKey: "yearOldDatabaseDisplay")
  outline.study = ["type": "Study", "yearOld": values[0], "yearOldAcquisition": values[1]]
  let visible = browser.outlineView(outline, objectValueFor: col, byItem: outline.study) as? String
  if visible != values[mode] { abort() }
  for selected in [false, true] {
   let result = browser.exportDBListOnlySelected(selected)
   if result != "Age\r" + visible! {
    FileHandle.standardError.write("FAIL: export differs from displayed age in mode \(mode)\n".data(using: .utf8)!)
    exit(1)
   }
  }
 }
}
print("PASS: actual export matches actual age display for all three preferences, years/days/months/mixed units/missing birth date/equal ages and selected/all rows")
'''
 with tempfile.TemporaryDirectory(prefix='horos-age-export-') as folder:
  p=Path(folder)
  (p/'Harness.h').write_text(header);(p/'Harness.m').write_text(code + harness_defaults.OBJC)
  (p/'Export.swift').write_text(extension);(p/'main.swift').write_text(main)
  include=['-I',str(p),'-I',str(root/'Horos/Sources')]
  subprocess.run(['xcrun','clang','-c','-fsanitize=address',*include,str(p/'Harness.m'),'-o',str(p/'Harness.o')],check=True)
  subprocess.run(['xcrun','clang','-c','-fobjc-arc','-fsanitize=address',*include,str(root/'Horos/Sources/HorosObjCException.m'),'-o',str(p/'HorosObjCException.o')],check=True)
  subprocess.run(['xcrun','swiftc','-sanitize=address',*include,'-import-objc-header',str(p/'Harness.h'),str(p/'Export.swift'),str(p/'main.swift'),str(p/'Harness.o'),str(p/'HorosObjCException.o'),'-o',str(p/'test')],check=True)
  subprocess.run([str(p/'test')],check=True)
 sys.exit(0)

a=s.index('- (NSString*) exportDBListOnlySelected:');b=s.index('\n#ifndef OSIRIX_LIGHT',a);export=s[a:b]
code=r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#define N2LogException(e) abort()
@interface Outline:NSObject
@property(retain) NSArray *tableColumns;
@property(retain) NSDictionary *study;
- (NSIndexSet*)selectedRowIndexes;
- (NSInteger)numberOfRows;
- (id)itemAtRow:(NSInteger)row;
@end
@implementation Outline
- (NSIndexSet*)selectedRowIndexes{return [NSIndexSet indexSetWithIndex:0];}
- (NSInteger)numberOfRows{return 1;}
- (id)itemAtRow:(NSInteger)row{return self.study;}
- (void)dealloc{[_tableColumns release];[_study release];[super dealloc];}
@end
@interface Browser:NSObject { @public Outline *databaseOutline; }
- (id)outlineView:(id)view objectValueForTableColumn:(id)column byItem:(id)item;
- (NSString*)exportDBListOnlySelected:(BOOL)selected;
@end
@implementation Browser
- (id)outlineView:(id)view objectValueForTableColumn:(id)column byItem:(id)item {
DISPLAY
}
EXPORT
@end
int main(){@autoreleasepool{
 [NSApplication sharedApplication];
 Outline *outline=[Outline new];NSTableColumn *col=[[[NSTableColumn alloc] initWithIdentifier:@"yearOld"] autorelease];col.headerCell.stringValue=@"Age";outline.tableColumns=@[col];
 Browser *browser=[Browser new];browser->databaseOutline=outline;
 NSArray *cases=@[@[@"36 y",@"30 y",@"36/30 y"],@[@"6 d",@"2 d",@"6 d/2 d"],@[@"5 m",@"2 m",@"5 m/2 m"],@[@"1 y 3 m",@"7 m",@"1 y 3 m/7 m"],@[@"",@"",@""],@[@"20 y",@"20 y",@"20 y"]];
 for(NSArray *values in cases)for(int mode=0;mode<3;mode++){
  [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:@"yearOldDatabaseDisplay"];
  outline.study=@{@"type":@"Study",@"yearOld":values[0],@"yearOldAcquisition":values[1]};
  NSString *visible=[browser outlineView:outline objectValueForTableColumn:col byItem:outline.study];
  if(![visible isEqual:values[mode]])abort();
  for(int selected=0;selected<2;selected++){
   NSString *result=[browser exportDBListOnlySelected:selected];
   if(![result isEqual:[@"Age\r" stringByAppendingString:visible]]){fprintf(stderr,"FAIL: export differs from displayed age in mode %d\n",mode);return 1;}
  }
 }
 [browser release];[outline release];
 puts("PASS: actual export matches actual age display for all three preferences, years/days/months/mixed units/missing birth date/equal ages and selected/all rows");
}}
'''.replace('DISPLAY',display).replace('EXPORT',export)
with tempfile.TemporaryDirectory(prefix='horos-age-export-') as folder:
 p=Path(folder);(p/'test.m').write_text(code + harness_defaults.OBJC)
 subprocess.run(['xcrun','clang','-fsanitize=address',str(p/'test.m'),'-framework','Cocoa','-framework','CoreData','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

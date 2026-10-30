#!/usr/bin/env python3
"""Execute the actual ZIP method against /usr/bin/zip and inspect resulting archives.

The ZIP archives are Swift (BrowserController+ZIPExport.swift, with the
arguments of IsiXDatabase's ZipCommand): compiled here as they are, with the
real ExportArchive and HorosAlertPanel, and called from this Objective-C
driver through the generated interface.
"""
from pathlib import Path
import subprocess,tempfile,zipfile,sys
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
# The export packs all its patient folders into one archive, not one per folder.
call='BrowserController.encryptFilesOrFolders(folders, inZIPFile: folderClaims.archivePath(forFolders: folders)'
assert call in s, 'the export no longer packs its patient folders into one archive'
packing=s[s.rindex('if encryptExport && !exportAborted',0,s.index(call)):s.index(call)]
assert 'for ' not in packing, 'the export still packs each patient folder on its own'
bridge=r'''
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
#import "HorosAlertPanel.h"
NS_ASSUME_NONNULL_BEGIN
@interface AppController:NSObject
+ (BOOL)hasMacOSXSnowLeopard;
@end
@interface NSThread(Status)
@property(copy, nullable) NSString *status;
@end
@interface WaitRendering:NSObject
- (id)init:(NSString*)message;
- (void)showWindow:(nullable id)sender;
- (void)close;
@end
NS_SWIFT_UI_ACTOR
@interface BrowserController:NSObject
@end
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
void DicomDatabaseLogError(const char* function, const char* file, int line, NSString* message);
NS_ASSUME_NONNULL_END
'''
stubs=r'''
#import "Bridge.h"
@implementation AppController
+ (BOOL)hasMacOSXSnowLeopard{return YES;}
@end
@implementation NSThread(Status)
- (void)setStatus:(NSString*)value{}
- (NSString*)status{return @"";}
@end
@implementation WaitRendering
- (id)init:(NSString*)message{return [super init];}
- (void)showWindow:(id)sender{}
- (void)close{}
@end
@implementation BrowserController
@end
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%s: %@", pf, e); }
void DicomDatabaseLogError(const char* function, const char* file, int line, NSString* message) { NSLog(@"%s: %@", function, message); }
'''
code=r'''
#import "Bridge.h"
#import "Harness-Swift.h"
int main(int argc,char **argv){@autoreleasepool{
 NSString *root=[NSString stringWithUTF8String:argv[1]];
 for(int scenario=0;scenario<9;scenario++) {
  NSString *folder=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"source %d",scenario]];
  [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *file=[folder stringByAppendingPathComponent:@"image.txt"];
  [@"synthetic archive bytes" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  NSString *dest=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"result-%d.zip",scenario]];
  if(scenario==2)dest=[file stringByAppendingPathComponent:@"invalid.zip"];
  NSString *source=(scenario==3 || scenario==6)?[root stringByAppendingPathComponent:@"missing"]:folder;
  if(scenario==4)dest=nil;
  if(scenario==0 || scenario==6 || scenario==8)[@"old archive bytes" writeToFile:dest atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  if(scenario==7) {
   [[NSFileManager defaultManager] createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:NULL];
   [@"destination folder sentinel" writeToFile:[dest stringByAppendingPathComponent:@"keep.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  if(scenario==8)[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0} ofItemAtPath:file error:NULL];
  NSError *error=nil;BOOL removeSource=scenario==1 || scenario==2 || scenario==5 || scenario==6 || scenario==7 || scenario==8;
  BOOL ok=[BrowserController encryptFileOrFolder:source inZIPFile:dest password:scenario==5?@"synthetic-password":@"" deleteSource:removeSource showGUI:NO error:&error];
  if(scenario==8)[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0644} ofItemAtPath:file error:NULL];
  BOOL expected=scenario==0 || scenario==1 || scenario==5;
  if(ok!=expected || (!!error)==expected || (!expected && !error.localizedDescription.length)) {fprintf(stderr,"FAIL scenario %d: success %d error %s\n",scenario,ok,[[error description] UTF8String]);return 1;}
  if((scenario==6 || scenario==8) && ![[NSString stringWithContentsOfFile:dest encoding:NSUTF8StringEncoding error:NULL] isEqual:@"old archive bytes"]) {fputs("FAIL previous archive lost after failed export\n",stderr);return 1;}
  if(scenario==7 && ![[NSString stringWithContentsOfFile:[dest stringByAppendingPathComponent:@"keep.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqual:@"destination folder sentinel"])return 1;
  BOOL sourceRemains=[[NSFileManager defaultManager] fileExistsAtPath:file];
  if(sourceRemains!=(scenario!=1 && scenario!=5)) {fputs("FAIL source preservation\n",stderr);return 1;}
 }
 // Several patient folders of one export go into one archive.
 NSMutableArray *patients=[NSMutableArray array];
 for(NSString *name in @[@"SMITH", @"SMITH_2"]) {
  NSString *folder=[root stringByAppendingPathComponent:name];
  [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
  [@"synthetic archive bytes" writeToFile:[folder stringByAppendingPathComponent:@"image.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  [patients addObject:folder];
 }
 NSError *patientsError=nil;
 if(![BrowserController encryptFilesOrFolders:patients inZIPFile:[root stringByAppendingPathComponent:@"SMITH.zip"] password:@"synthetic-password" deleteSource:YES showGUI:NO error:&patientsError] || patientsError)return 8;
 for(NSString *folder in patients) if([[NSFileManager defaultManager] fileExistsAtPath:folder])return 9;
 // Items from different directories are refused, and kept.
 NSString *elsewhere=[[root stringByAppendingPathComponent:@"elsewhere"] stringByAppendingPathComponent:@"DOE"];
 [[NSFileManager defaultManager] createDirectoryAtPath:elsewhere withIntermediateDirectories:YES attributes:nil error:NULL];
 NSString *here=[root stringByAppendingPathComponent:@"source 0"];
 if([BrowserController encryptFilesOrFolders:@[here, elsewhere] inZIPFile:[root stringByAppendingPathComponent:@"split.zip"] password:@"" deleteSource:YES showGUI:NO error:&patientsError] || !patientsError)return 10;
 if(![[NSFileManager defaultManager] fileExistsAtPath:here] || ![[NSFileManager defaultManager] fileExistsAtPath:elsewhere])return 11;
 NSError *emailError=nil;
 NSString *original=[root stringByAppendingPathComponent:@"result-5.zip"];
 NSString *email=[root stringByAppendingPathComponent:@"Images.zip"];
 if(![BrowserController prepareProtectedEmailAttachment:original destination:email password:@"synthetic-password" error:&emailError])return 2;
 NSData *saved=[NSData dataWithContentsOfFile:email];
 if([BrowserController prepareProtectedEmailAttachment:original destination:email password:@"" error:&emailError] || !emailError)return 3;
 if(![saved isEqual:[NSData dataWithContentsOfFile:email]])return 4;
 if([BrowserController prepareProtectedEmailAttachment:@"/missing-source" destination:email password:@"synthetic-password" error:&emailError] || !emailError)return 5;
 if(![saved isEqual:[NSData dataWithContentsOfFile:email]])return 6;
 if(![[NSFileManager defaultManager] fileExistsAtPath:original])return 7;
 puts("PASS: ZIP result and NSError; failed sources preserved; successful deleteSource honored");
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-zip-result-') as folder:
 p=Path(folder);(p/'test.m').write_text(code);(p/'Bridge.h').write_text(bridge);(p/'stubs.m').write_text(stubs)
 sources=root/'Horos/Sources'
 # One module with the rules: the extension's "import IsiXDatabase" goes.
 (p/'ZIPExport.swift').write_text((sources/'BrowserController+ZIPExport.swift').read_text().replace('import IsiXDatabase\n',''))
 subprocess.run(['xcrun','swiftc','-parse-as-library','-wmo','-swift-version','6','-module-name','Harness','-import-objc-header',str(p/'Bridge.h'),
                 '-Xcc','-I','-Xcc',str(sources),'-emit-objc-header-path',str(p/'Harness-Swift.h'),'-c',
                 str(sources/'ExportArchive.swift'),str(sources/'BrowserController+DatabaseSupport.swift'),str(p/'ZIPExport.swift'),
                 str(root/'Modules/IsiXDatabase/Sources/ExportRules.swift'),'-o',str(p/'swift.o')],check=True)
 for source,arc in ((p/'stubs.m',False),(sources/'HorosObjCException.m',True),(sources/'HorosAlertPanel.m',False)):
  subprocess.run(['xcrun','clang','-c','-fblocks','-fobjc-arc' if arc else '-fno-objc-arc','-I',str(p),'-I',str(sources),str(source),'-o',str(p/(source.name+'.o'))],check=True)
 subprocess.run(['xcrun','clang','-c','-fmodules','-fblocks','-fno-objc-arc','-Werror=deprecated-declarations','-I',str(p),'-I',str(sources),str(p/'test.m'),'-o',str(p/'test.o')],check=True)
 subprocess.run(['xcrun','swiftc',str(p/'test.o'),str(p/'swift.o'),str(p/'stubs.m.o'),str(p/'HorosObjCException.m.o'),str(p/'HorosAlertPanel.m.o'),'-framework','Cocoa','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'files')],check=True)
 for case in [0,1,5]:
  with zipfile.ZipFile(p/'files'/f'result-{case}.zip') as z:
   assert z.read(f'source {case}/image.txt',pwd=b'synthetic-password' if case==5 else None)==b'synthetic archive bytes'
   if case==5:assert z.getinfo(f'source {case}/image.txt').flag_bits & 1
 with zipfile.ZipFile(p/'files'/'SMITH.zip') as z:
  for name in ('SMITH/image.txt','SMITH_2/image.txt'):
   assert z.read(name,pwd=b'synthetic-password')==b'synthetic archive bytes', name
   assert z.getinfo(name).flag_bits & 1
 assert not (p/'files'/'split.zip').exists()
 print('PASS: the patient folders of one export share one encrypted archive; items from different directories are refused')
 import io
 with zipfile.ZipFile(p/'files'/'Images.zip') as outer:
  assert outer.namelist()==['Images.zip'], outer.namelist()
  assert outer.getinfo('Images.zip').flag_bits & 1
  try: outer.read('Images.zip')
  except RuntimeError: pass
  else: raise AssertionError('Payload readable without password')
  with zipfile.ZipFile(io.BytesIO(outer.read('Images.zip',pwd=b'synthetic-password'))) as inner:
   assert inner.read('source 5/image.txt',pwd=b'synthetic-password')==b'synthetic archive bytes'
 print('PASS: email exposes only generic entry; two-stage extraction preserves original names/bytes; failed retry preserves destination')
 assert not list((p/'files').glob('.horos-zip-*')), 'Staging directory leaked'
 print('PASS: atomic replacement preserves old destinations on failure and cleans staging')
 print('PASS: plain and password-protected archive entries match source bytes')

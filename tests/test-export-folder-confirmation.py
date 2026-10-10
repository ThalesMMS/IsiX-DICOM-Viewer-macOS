#!/usr/bin/env python3
"""Run actual patient-folder handling with real temporary folders and controlled answers.

The block is the exporter's own, over the real folder claims: a folder that was
there before the export is asked about once; a second patient that comes to the
same name gets a numbered sibling and no question about a folder the export
itself just made.
"""
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/BrowserController.m').read_bytes().decode('latin1')
a=s.index('                // Two patients of this export')
b=s.index('                NSString *studyPath = nil;',a)
helper = s[s.index('- (BOOL) confirmDICOMExportFolder:'):s.index('- (void) showDICOMExportCompletion:')]
code=r"""
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosAlertPanel.h"
#import "ExportFolderClaims-Swift.h"
@interface Peer:NSObject { @public NSInteger prompts,answer,completed; BOOL exportAborted; NSError *exportError; NSMutableArray *used; }
- (void)runInformationAlertPanel:(NSMutableDictionary*)options;
- (void)run:(NSArray*)requests;
@end
@implementation Peer
HELPER
- (void)runInformationAlertPanel:(NSMutableDictionary*)options {prompts++;options[@"result"]=@(answer);}
- (void)run:(NSArray*)requests {
 NSMutableSet *reviewedPatientFolders=[NSMutableSet set];
 NSMutableArray *patientFolders=[NSMutableArray array];
 NSMutableArray *result=[NSMutableArray array];
 NSMutableDictionary *parameters=[NSMutableDictionary dictionary];
 HorosExportFolderClaims *folderClaims=[[[HorosExportFolderClaims alloc] init] autorelease];
 BOOL addDICOMDIR=NO;
 for(NSUInteger i=0;i<requests.count;i++) {
  NSDictionary *request=requests[i];NSString *tempPath=request[@"path"];
  NSDictionary *curImage=@{@"series":@{@"study":@{@"patientUID":request[@"patient"]}}};
BODY
  [@"image" writeToFile:[tempPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.dcm",(unsigned long)i]] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  completed++;
 }
 used=[patientFolders retain];
 if(!exportAborted && ![[result valueForKey:@"self"] isEqual:[[requests valueForKey:@"expected"] valueForKey:@"lastPathComponent"]]) { fprintf(stderr,"FAIL folders %s\n",[[result description] UTF8String]); exit(1); }
}
@end
int main(int argc,char **argv){@autoreleasepool{
 NSString *root=[NSString stringWithUTF8String:argv[1]];
 NSFileManager *fm=[NSFileManager defaultManager];
 // 0: new folder; 1: there before, Merge; 2: there before, Cancel; 3: there before, Replace.
 for(int scenario=0;scenario<4;scenario++) {
  NSString *path=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"%d",scenario]];
  NSString *sibling=[path stringByAppendingString:@"_2"];
  Peer *peer=[Peer new];peer->answer=scenario==2?NSAlertAlternateReturn:(scenario==3?NSAlertDefaultReturn:NSAlertOtherReturn);
  NSDictionary *a=@{@"path":path,@"patient":@"A",@"expected":path};NSDictionary *b=@{@"path":path,@"patient":@"B",@"expected":sibling};
  NSString *sentinel=[path stringByAppendingPathComponent:@"existing.txt"];
  if(scenario) {
   [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
   [@"preserve" writeToFile:sentinel atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  if(scenario==2) {
   // Cancel stops at the first image and leaves what was there.
   [peer run:@[a,a,b]];
   if(peer->prompts!=1 || !peer->exportAborted || peer->completed!=0 || ![fm fileExistsAtPath:sentinel]) { fprintf(stderr,"FAIL cancel\n");return 1; }
   [peer release];continue;
  }
  NSArray *requests=@[a,a,b,a,b];
  [peer run:requests];
  NSInteger expectedPrompts=scenario?1:0;
  if(peer->prompts!=expectedPrompts || peer->completed!=5 || peer->exportAborted) {
   fprintf(stderr,"FAIL scenario %d: prompts %ld expected %ld, completed %ld aborted %d\n",scenario,(long)peer->prompts,(long)expectedPrompts,(long)peer->completed,peer->exportAborted);return 1;
  }
  if(![peer->used isEqual:@[path,sibling]]) { fprintf(stderr,"FAIL scenario %d folders handed on\n",scenario);return 1; }
  // Both patients keep every file: three of A, two of B.
  NSUInteger extra=scenario==1?1:0;
  if([[fm contentsOfDirectoryAtPath:path error:NULL] count]!=3+extra || [[fm contentsOfDirectoryAtPath:sibling error:NULL] count]!=2) { fprintf(stderr,"FAIL scenario %d files\n",scenario);return 1; }
  if([fm fileExistsAtPath:sentinel]!=(scenario==1)) { fprintf(stderr,"FAIL existing contents after merge/replace\n");return 1; }
  [peer release];
 }
 puts("PASS: a folder there before the export is asked about once; a second patient under the same name gets a sibling, unasked; cancellation stops the batch");
}}
""".replace('BODY',s[a:b]).replace('HELPER',helper)
with tempfile.TemporaryDirectory(prefix='horos-folder-confirm-') as folder:
 p=Path(folder);(p/'test.m').write_text(code)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','ExportFolderClaims','-c',
                 str(root/'Horos/Sources/ExportFolderNaming.swift'),'-o',str(p/'claims.o'),
                 '-emit-objc-header-path',str(p/'ExportFolderClaims-Swift.h')],check=True)
 subprocess.run(['xcrun','clang','-c','-fmodules','-Wno-deprecated-declarations','-iquote',str(root/'Horos/Sources'),'-I',str(p),
                 str(p/'test.m'),'-o',str(p/'test.o')],check=True)
 subprocess.run(['xcrun','swiftc',str(p/'claims.o'),str(p/'test.o'),'-framework','Cocoa','-framework','CoreData','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'exports')],check=True)

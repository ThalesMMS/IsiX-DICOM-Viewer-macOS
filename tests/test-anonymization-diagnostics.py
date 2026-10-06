#!/usr/bin/env python3
"""Compile production Swift/DCMTK selected-field anonymization and generate DICOM.

App model, panels and progress UI are doubles; the helper, charset table,
transaction, parser and writer are real. Requires pydicom/numpy and a built
DCMTK. --compare retains the former Objective-C++ baseline (also needs GDCM),
comparing reports and semantic datasets rather than reserialized file bytes.
--large and --large-mixed opt into the historical 29329-file cases.
--empty-sequences runs only the sequence batch cases plus the per-file gates.
--charsets runs the lightweight encoding matrix and established defaults/date
batches, without parser failure injections or allocation probes.
The SQ insertion-failure executable substitutes a bad insertion result in its
own copy of the helper; the app and DCMTK have no test hook.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import hashlib
import json
import copy
import struct
import os
import re
import subprocess
import sys
import tempfile
# Re-run under an interpreter that has pydicom when this one does not, so the
# test measures the product rather than the machine it was started on.
# The fixture generator needs numpy as well.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import python_with
python_with.require('import pydicom', 'import numpy')
import pydicom
from sources import is_swift, source_path
root = Path(__file__).resolve().parents[1]
FORMER = '440c1c1b7'
configuration = os.environ.get('HOROS_TEST_CONFIGURATION', 'Debug')
from dcmtk_build import BUILD
install = BUILD/'DCMTK.build/Install'
gdcm_install = BUILD/'GDCM.build/Install'
if not (install/'lib/libdcmdata.a').exists():
    # Not built here: a skip, not a failure. SystemExit with a string exits 1,
    # which tools/run-tests.py reads as failed; the skip code is 2.
    print('skipped: needs a built DCMTK; run script/build_and_run.sh --verify first',
          file=sys.stderr)
    raise SystemExit(2)
assert is_swift('Anonymization'), 'Anonymization is expected in Swift'
anonymization = source_path('Anonymization')
gdcm_helper = source_path('HorosGDCMAnonymizer')
compare = '--compare' in sys.argv
sequence_modes = ['sq-present', 'sq-absent', 'sq-empty', 'sq-private',
                  'sq-nonempty', 'sq-private-nonempty', 'sq-private-absent',
                  'sq-insert-failure']
sequence_success = {'sq-present', 'sq-absent', 'sq-empty', 'sq-private'}


def _method(text, signature):
    at = text.index(signature)
    opening = text.index('{', at)
    depth, index = 0, opening
    while index < len(text):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[at:index + 1]
        index += 1
    raise SystemExit('cannot find %s' % signature)


# The category delegates to the one table, which lives in the framework, so the
# harness carries that table and a stand-in class to hang it on.
encoding_source = (root/'DCM Framework/DCMCharacterSet.m').read_bytes().decode('latin1')
encoding_methods = '\n'.join([
    '@interface DCMCharacterSet : NSObject',
    '+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)characterSet;',
    '+ (NSString*) characterSetWhenAbsent;',
    '@end',
    '@implementation DCMCharacterSet',
    _method(encoding_source, '+ (NSString*) characterSetWhenAbsent'),
    _method(encoding_source, '+ (NSStringEncoding)encodingForDICOMCharacterSet:'),
    '@end',
    '@implementation NSString (DICOMToNSString)',
    '+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)characterSet',
    '{ return [DCMCharacterSet encodingForDICOMCharacterSet: characterSet]; }',
    '@end',
])

# What Swift, the GDCM helper and the former Anonymization.mm see of the app.
# Plain Objective-C: it is the bridging header of the Swift build.
stubs_header = r'''
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
#import "HorosAlertPanel.h"
#import "HorosAnonymizationSafety.h"
#import "HorosGDCMAnonymizer.h"
#import "DCMCalendarDate.h"
#ifdef __cplusplus
extern "C" {
#endif
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf);
#ifdef __cplusplus
}
#endif
#define N2LogExceptionWithStackTrace(e, ...) _N2LogExceptionImpl(e, YES, __PRETTY_FUNCTION__)
@interface DCMAttributeTag : NSObject
+ (id)tagWithGroup:(int)group element:(int)element vr:(NSString *)vr name:(NSString *)name;
+ (id)tagWithName:(NSString *)name;
+ (id)tagWithTagString:(NSString *)tagString;
@property(readonly) int group;
@property(readonly) int element;
@property(retain) NSString *vr;
@property(readonly) NSString *name;
@property(readonly) NSString *stringValue;
@end
@interface DicomStudy : NSObject
@end
@interface DicomSeries : NSObject
@property(nonatomic, retain) DicomStudy *study;
@end
@interface DicomImage : NSObject
@property(nonatomic, retain) DicomSeries *series;
@property(nonatomic, retain) NSNumber *instanceNumber;
@end
@interface DicomFile : NSObject
+ (NSArray *)getEncodingArrayForFile:(NSString *)p;
@end
@interface NSString (DICOMToNSString)
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)characterSet;
@end
@interface NSFileManager (N2)
- (NSString *)confirmDirectoryAtPath:(NSString *)dirPath;
@end
@interface NSUserDefaultsController (N2)
- (NSArray *)arrayForKey:(NSString *)defaultName;
- (NSDictionary *)dictionaryForKey:(NSString *)defaultName;
@end
@interface Wait : NSWindowController
- (id)initWithString:(NSString *)s;
- (NSProgressIndicator *)progress;
- (void)incrementBy:(double)delta;
- (BOOL)pollCancellation;
- (void)setCancel:(BOOL)val;
@end
@class AnonymizationViewController;
@interface AnonymizationPanelController : NSWindowController
@property(retain, readonly) AnonymizationViewController *anonymizationViewController;
@property(readonly) int end;
@property(retain) id representedObject;
- (id)initWithTags:(NSArray *)shownDcmTags values:(NSArray *)values;
@end
@interface AnonymizationSavePanelController : AnonymizationPanelController
@end
@interface AnonymizationViewController : NSViewController
@property(readonly, retain) NSMutableArray *tags;
- (NSArray *)tagsValues;
@end
'''
# The headers the former Anonymization.mm and the GDCM helper import.
redirected = ['DCMAttributeTag.h', 'AnonymizationViewController.h', 'AnonymizationSavePanelController.h',
              'NSFileManager+N2.h', 'NSDictionary+N2.h', 'DCMObject.h', 'DicomImage.h', 'DicomStudy.h',
              'DicomSeries.h', 'BrowserController.h', 'AppController.h', 'Wait.h', 'DicomFile.h',
              'DICOMToNSString.h', 'XMLController.h', 'DicomFileDCMTKCategory.h', 'XMLControllerDCMTKCategory.h',
              'N2Debug.h', 'NSUserDefaultsController+N2.h']
stubs = r'''
#import "fixture-stubs.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
static NSDictionary *fixtureTags() {
 static NSDictionary *t; if(!t) t=[@{@"PatientsName":@[@0x10,@0x10,@"PN"],@"PatientID":@[@0x10,@0x20,@"LO"],@"PatientsBirthDate":@[@0x10,@0x30,@"DA"],
  @"PatientsWeight":@[@0x10,@0x1030,@"DS"],@"PatientsAge":@[@0x10,@0x1010,@"AS"],@"StudyTime":@[@0x8,@0x30,@"TM"],@"AcquisitionDatetime":@[@0x8,@0x2a,@"DT"],
  @"InstitutionName":@[@0x8,@0x80,@"LO"],@"SeriesNumber":@[@0x20,@0x11,@"IS"]} retain];
 return t;
}
@implementation DCMAttributeTag { int _group, _element; NSString *_name; }
@synthesize vr;
+ (id)tagWithGroup:(int)g element:(int)e vr:(NSString *)v name:(NSString *)n { DCMAttributeTag *t=[[self new] autorelease];t->_group=g;t->_element=e;t.vr=v;t->_name=[n retain];return t; }
+ (id)tagWithName:(NSString *)n { NSArray *d=fixtureTags()[n]; return d?[self tagWithGroup:[d[0] intValue] element:[d[1] intValue] vr:d[2] name:n]:nil; }
+ (id)tagWithTagString:(NSString *)s {
 unsigned g,e; if(![s isKindOfClass:NSString.class]||sscanf(s.UTF8String,"%x,%x",&g,&e)!=2) return nil;
 for(NSString *n in fixtureTags()) if([fixtureTags()[n][0] intValue]==(int)g&&[fixtureTags()[n][1] intValue]==(int)e) return [self tagWithName:n];
 return [self tagWithGroup:g element:e vr:nil name:nil];
}
- (int)group { return _group; } - (int)element { return _element; } - (NSString *)name { return _name; }
- (NSString *)stringValue { return [NSString stringWithFormat:@"%04X,%04X",_group,_element]; }
- (BOOL)isEqual:(id)o { return [o isKindOfClass:DCMAttributeTag.class]&&[[o stringValue] isEqualToString:self.stringValue]; }
- (NSUInteger)hash { return self.stringValue.hash; }
@end
@implementation DicomStudy
@end
@implementation DicomSeries
@synthesize study;
@end
@implementation DicomImage
@synthesize series, instanceNumber;
@end
@implementation DicomFile
+ (NSArray *)getEncodingArrayForFile:(NSString *)p {
 DcmFileFormat file;
 if(file.loadFile(p.fileSystemRepresentation).bad()) return @[];
 const char *value=nullptr;
 if(file.getDataset()->findAndGetString(DCM_SpecificCharacterSet,value,OFFalse).bad() || !value) return @[@""];
 return @[[NSString stringWithCString:value encoding:NSISOLatin1StringEncoding]?:@""];

}
@end
ENCODING_METHODS
@implementation NSFileManager (N2)
- (NSString *)confirmDirectoryAtPath:(NSString *)p { if(![self createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL]) [NSException raise:@"FixtureDirectory" format:@"cannot create export folder"]; return p; }
@end
@implementation NSUserDefaultsController (N2)
- (NSArray *)arrayForKey:(NSString *)k { return [NSUserDefaults.standardUserDefaults arrayForKey:k]; }
- (NSDictionary *)dictionaryForKey:(NSString *)k { return [NSUserDefaults.standardUserDefaults dictionaryForKey:k]; }
@end
@implementation AnonymizationPanelController
@synthesize anonymizationViewController, end, representedObject;
- (id)initWithTags:(NSArray *)t values:(NSArray *)v { return [super initWithWindow:nil]; }
@end
@implementation AnonymizationSavePanelController
@end
@implementation AnonymizationViewController
@synthesize tags;
- (NSArray *)tagsValues { return @[]; }
@end
extern "C" void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"exception %@ in %s", e, pf); }
'''.replace('ENCODING_METHODS', encoding_methods)
harness = r'''
#import "fixture-stubs.h"
#import "Anonymization.h"
#import <objc/runtime.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>
static NSString *mode, *output;
static BOOL outputStream(FILE *stream) {
 char path[PATH_MAX];
 return mode && fcntl(fileno(stream),F_GETPATH,path)==0 && strstr(path,".horos-anonymized-")!=NULL;
}
// These libc failure injections leave the production source and DCMTK
// archives unchanged; the separate SQ fault executable controls insertion.
int fclose(FILE *stream) {
 int (*realClose)(FILE *)=dlsym(RTLD_NEXT,"fclose");
 BOOL fail=[mode isEqual:@"file-close"] && outputStream(stream);
 int result=realClose(stream);
 if(fail) { errno=ENOSPC; return EOF; }
 return result;
}
size_t fwrite(const void *bytes, size_t size, size_t count, FILE *stream) {
 size_t (*realWrite)(const void *,size_t,size_t,FILE *)=dlsym(RTLD_NEXT,"fwrite");
 if([mode isEqual:@"file-save"] && outputStream(stream)) { errno=ENOSPC; return 0; }
 return realWrite(bytes,size,count,stream);
}
static NSInteger polls, publications, sequenceFailures;
static void check(BOOL ok, NSString *why) { if(!ok) { NSLog(@"FAIL %@: %@",mode,why);exit(1); } }
#if HOROS_FIXTURE_CURRENT_HELPER
@interface HorosGDCMAnonymizer (FixtureFailure)
+ (NSString *)fixtureAnonymizeStagedFile:(NSString *)path withTags:(NSArray *)tags failure:(HorosGDCMAnonymizerFailure)failure;
@end
@implementation HorosGDCMAnonymizer (FixtureFailure)
+ (NSString *)fixtureAnonymizeStagedFile:(NSString *)path withTags:(NSArray *)tags failure:(HorosGDCMAnonymizerFailure)failure {
 return [self fixtureAnonymizeStagedFile:path withTags:tags failure:^(NSString *reason, NSString *tag) {
  sequenceFailures++;
  check([tag isEqual:([mode hasPrefix:@"sq-private"]?@"(0011,1010)":@"(0008,1110)")],@"callback identifies the rejected sequence");
  failure(reason,tag);
 }];
}
@end
#endif
// One line per fact, on stdout, for --compare.
static void report(NSString *format, ...) {
 va_list args;va_start(args,format);NSString *line=[[[NSString alloc] initWithFormat:format arguments:args] autorelease];va_end(args);
 printf("%s\n",[[line stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String]);
}
static NSString *kind(id v) { return v==nil?@"nil":[v isKindOfClass:NSString.class]?@"string":[v isKindOfClass:NSNumber.class]?@"number":[v isKindOfClass:NSDate.class]?@"date":[v isKindOfClass:NSArray.class]?@"array":NSStringFromClass([v class]); }
@interface NSFileManager (FixtureMove)
- (BOOL)fixtureMove:(NSString *)a toPath:(NSString *)b error:(NSError **)e;
@end
@implementation NSFileManager (FixtureMove)
- (BOOL)fixtureMove:(NSString *)a toPath:(NSString *)b error:(NSError **)e {
 if([b containsString:@"/Anonymized-"] && ++publications==2 && [mode isEqual:@"publish-failure"]) {
  if(e)*e=[NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];return NO;
 }
 return [self fixtureMove:a toPath:b error:e];
}
@end
@implementation Wait
- (id)initWithString:(NSString *)s { return [super initWithWindow:nil]; }
- (NSProgressIndicator *)progress { static NSProgressIndicator *p; if(!p) p=[[NSProgressIndicator alloc] initWithFrame:NSZeroRect]; return p; }
- (void)showWindow:(id)s {} - (void)setCancel:(BOOL)b {} - (void)incrementBy:(double)n {}
- (BOOL)pollCancellation {
 polls++;
 if([mode isEqual:@"write-failure"] && (polls==3||polls==4))
  for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:output error:NULL])
   if([name hasPrefix:@".horos-anonymization-"]) chmod([[output stringByAppendingPathComponent:name] fileSystemRepresentation],polls==3?0500:0700);
 return ([mode isEqual:@"cancel-copy"]&&polls==2)||([mode isEqual:@"cancel-publish"]&&polls==6)||([mode isEqual:@"cancel-final"]&&polls==7);
}
- (void)close {}
@end
static void reportTagsValues(NSString *what, NSArray *a) {
 NSMutableArray *rows=[NSMutableArray array];
 for(NSArray *i in a) [rows addObject:[NSString stringWithFormat:@"%@=%@:%@",[i[0] stringValue],i.count>1?kind(i[1]):@"none",i.count>1?[i[1] description]:@""]];
 report(@"%@ %ld %@",what,(long)a.count,[[rows sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "]);
}
static void reportDictionary(NSString *what, NSDictionary *d) {
 NSMutableArray *rows=[NSMutableArray array];
 for(id k in d) [rows addObject:[NSString stringWithFormat:@"%@(%@)=%@:%@",k,kind(k),kind(d[k]),d[k]]];
 report(@"%@ %ld %@",what,(long)d.count,[[rows sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "]);
}
// The template methods, whose dictionaries are what NSUserDefaults stores.
static void helpers(void) {
 NSDate *date=[NSDate dateWithTimeIntervalSince1970:981203696];
 NSDictionary *stored=@{@"PatientsName":@"QA^Template",@"Patient's ID":@"LOCAL-1",@"PatientsBirthDate":date,@"PatientsWeight":@72.5,
  @"InstitutionName":[NSNull null],@"0010,1010":@"042Y",@"Not A Tag":@"x"};
 NSArray *values=[Anonymization tagsValuesArrayFromDictionary:stored];
 reportTagsValues(@"tagsValuesArrayFromDictionary",values);
 check(values.count==6,@"unrecognized key skipped, NSNull kept as a tag without value");
 NSDictionary *saved=[Anonymization tagsValuesDictionaryFromArray:values];
 reportDictionary(@"tagsValuesDictionaryFromArray",saved);
 check([saved[@"InstitutionName"] isEqual:@""],@"a tag without value is saved as an empty string");
 reportTagsValues(@"roundtrip",[Anonymization tagsValuesArrayFromDictionary:saved]);
 report(@"tagsValuesDictionaryFromArray(empty) %@",[Anonymization tagsValuesDictionaryFromArray:@[]]);
 NSArray *tags=[Anonymization tagsArrayFromStringsArray:@[@"PatientsName",@"0008,0030",@"Nope",@"Patient's Sex",@"0012,0034"]];
 report(@"tagsArrayFromStringsArray %@",[[tags valueForKey:@"stringValue"] componentsJoinedByString:@" "]);
 NSArray *strings=[Anonymization performSelector:@selector(stringArrayFromTagsArray:) withObject:tags];
 report(@"stringArrayFromTagsArray %@ %@",NSStringFromClass([strings class]).length?@"array":@"",[strings componentsJoinedByString:@" "]);
 check([[[Anonymization tagsArrayFromStringsArray:strings] valueForKey:@"stringValue"] isEqual:strings],@"saved tag list reads back");
 DCMAttributeTag *pn=[DCMAttributeTag tagWithName:@"PatientsName"],*id_=[DCMAttributeTag tagWithName:@"PatientID"];
 NSArray *cases=@[@[@[@[pn,@"A"],@[id_]],@[@[id_],@[pn,@"A"]]],@[@[@[pn,@"A"]],@[@[pn,@"B"]]],@[@[@[pn]],@[@[pn,@""]]],
  @[@[@[pn,@"A"]],@[@[pn,@"A"],@[id_]]],@[@[@[pn,@"A"]],@[@[id_,@"A"]]],@[@[],@[]],@[@[@[pn,@1]],@[@[pn,@1.0]]],@[@[@[pn,date]],@[@[pn,[date copy]]]]];
 for(NSArray *c in cases) report(@"tagsValues:isEqualTo: %d",(int)[Anonymization tagsValues:c[0] isEqualTo:c[1]]);
 report(@"cleanStringForFile %@",[Anonymization performSelector:@selector(cleanStringForFile:) withObject:@"CT/Head: 1"]);
 report(@"templateDicomFile %@",[Anonymization templateDicomFile]);
 NSLog(@"PASS helpers");
}
int main(int argc,char **argv) { @autoreleasepool {
 mode=[NSString stringWithUTF8String:argv[1]];
 if([mode isEqual:@"helpers"]) { helpers(); return 0; }
#ifndef HOROS_FORMER
 if([mode hasPrefix:@"file"]) {
  NSString *input=[NSString stringWithUTF8String:argv[2]];
  NSData *json=[[NSString stringWithUTF8String:argv[3]] dataUsingEncoding:NSUTF8StringEncoding];
  NSArray *selections=[NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
  NSMutableArray *tags=[NSMutableArray array];
  for(NSArray *row in selections) {
   DCMAttributeTag *tag=[DCMAttributeTag tagWithGroup:[row[0] intValue] element:[row[1] intValue] vr:nil name:nil];
   [tags addObject:row.count>2?@[tag,row[2]]:@[tag]];
  }
  if([mode isEqual:@"file-rename"])
   [NSFileManager.defaultManager createDirectoryAtPath:[[input stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"anon_input.dcm"] withIntermediateDirectories:NO attributes:nil error:NULL];
  if([mode isEqual:@"file-default"])
   [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"DefaultCharacterSetWhenAbsent":@"ISO_IR 192"} forName:NSArgumentDomain];
  __block NSInteger failures=0;
  NSString *written=[HorosGDCMAnonymizer anonymizeStagedFile:input withTags:tags failure:^(NSString *reason, NSString *tag) {
   failures++; report(@"failure %@ %@",tag?:@"file",reason);
   if([mode isEqual:@"file-remove"]) unlink(input.fileSystemRepresentation);
   if([mode isEqual:@"file-truncate"]) truncate(input.fileSystemRepresentation,132);
   if([mode isEqual:@"file-inaccessible"]) chmod(input.fileSystemRepresentation,0000);
  }];
  report(@"written %d failures %ld",written!=nil,(long)failures);
  return 0;
 }
#endif
 NSString *input=[NSString stringWithUTF8String:argv[2]];output=[NSString stringWithUTF8String:argv[3]];
#if HOROS_FIXTURE_CURRENT_HELPER
 if([mode hasPrefix:@"sq-"])
  method_exchangeImplementations(class_getClassMethod(HorosGDCMAnonymizer.class,@selector(anonymizeStagedFile:withTags:failure:)),class_getClassMethod(HorosGDCMAnonymizer.class,@selector(fixtureAnonymizeStagedFile:withTags:failure:)));
#endif
 method_exchangeImplementations(class_getInstanceMethod(NSFileManager.class,@selector(moveItemAtPath:toPath:error:)),class_getInstanceMethod(NSFileManager.class,@selector(fixtureMove:toPath:error:)));
 NSInteger count=argc>4?atoi(argv[4]):2;
 NSMutableArray *files=[NSMutableArray array];
 for(NSInteger i=0;i<count;i++) [files addObject:[input stringByAppendingPathComponent:[mode isEqual:@"order"]?[NSString stringWithFormat:@"reverse-%02ld.dcm",(long)(99-i)]:count==2?(i==0?@"one.dcm":@"two.dcm"):[NSString stringWithFormat:@"image-%05ld.dcm",(long)i]]];
 if([mode isEqual:@"duplicate-path"]) files[1]=files[0];
 DicomSeries *series=[DicomSeries new];series.study=[DicomStudy new];NSMutableArray *images=[NSMutableArray array];
 for(int i=0;i<count;i++){ DicomImage *im=[DicomImage new];im.series=series;im.instanceNumber=@(i+1);[images addObject:im]; }
 DCMAttributeTag *tag=[DCMAttributeTag tagWithGroup:0x10 element:0x10 vr:@"PN" name:@"PatientsName"];
 if([mode isEqual:@"unsupported-tag"]) tag=[DCMAttributeTag tagWithGroup:0x28 element:0x10 vr:@"US" name:@"Rows"];
 NSString *value=[mode isEqual:@"encoding"]?@"QA^漢":([mode isEqual:@"mixed-encoding"]?@"QA^Élodie":@"QA^Anonymous");
 NSArray *tags=[mode isEqual:@"no-tags"]?@[]:@[@[tag,value]];
 if([mode hasPrefix:@"charset-"]) {
  NSData *json=[[NSString stringWithUTF8String:argv[5]] dataUsingEncoding:NSUTF8StringEncoding];
  NSArray *selections=[NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
  NSMutableArray *encodedTags=[NSMutableArray array];
  for(NSArray *row in selections) {
   DCMAttributeTag *selected=[DCMAttributeTag tagWithGroup:[row[0] intValue] element:[row[1] intValue] vr:nil name:nil];
   [encodedTags addObject:row.count>2?@[selected,row[2]]:@[selected]];
  }
  tags=encodedTags;
  if(argc>6 && strcmp(argv[6],"none"))
   [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"DefaultCharacterSetWhenAbsent":[NSString stringWithUTF8String:argv[6]]} forName:NSArgumentDomain];
 }
 if([mode hasPrefix:@"sq-"]) {
  BOOL privateTag=[mode hasPrefix:@"sq-private"];
  tag=[DCMAttributeTag tagWithGroup:privateTag?0x11:0x8 element:privateTag?0x1010:0x1110 vr:@"SQ" name:nil];
  tags=[mode containsString:@"nonempty"]?@[@[tag,@"replacement"]]:([mode isEqual:@"sq-present"]?@[@[tag]]:@[@[tag,@""]]);
 }
 if([mode isEqual:@"multi"]) {
  // Every conversion the method makes before GDCM: dates by VR, numbers by VR, a number left as it is, no value.
  NSDate *date=[NSDate dateWithTimeIntervalSince1970:981203696];
  tags=@[@[tag,value],@[[DCMAttributeTag tagWithName:@"PatientID"]],@[[DCMAttributeTag tagWithName:@"PatientsBirthDate"],date],
   @[[DCMAttributeTag tagWithName:@"StudyTime"],date],@[[DCMAttributeTag tagWithName:@"AcquisitionDatetime"],date],
   @[[DCMAttributeTag tagWithName:@"PatientsWeight"],@72.5],@[[DCMAttributeTag tagWithName:@"SeriesNumber"],@9],
   @[[DCMAttributeTag tagWithName:@"InstitutionName"],@7],@[[DCMAttributeTag tagWithName:@"PatientsAge"],@"042Y"]];
 }
 if([mode isEqual:@"order"]) tags=@[@[tag,@"QA^AnonymousOrder"],@[[DCMAttributeTag tagWithName:@"PatientID"],@"ANON-ORDER-140"]];
 NSError *error=nil;
 NSDictionary *result=[Anonymization anonymizeFiles:files dicomImages:images toPath:output withTags:tags error:&error];
 BOOL success=[mode isEqual:@"order"]||[mode isEqual:@"success"]||[mode isEqual:@"mixed-encoding"]||[mode isEqual:@"duplicate-uid"]||[mode isEqual:@"large"]||[mode isEqual:@"large-mixed"]||[mode isEqual:@"multi"]||[mode isEqual:@"sq-present"]||[mode isEqual:@"sq-absent"]||[mode isEqual:@"sq-empty"]||[mode isEqual:@"sq-private"];
 if([mode hasPrefix:@"charset-"]) success=[mode isEqual:@"charset-success"];
 report(@"polls %ld publications %ld",(long)polls,(long)publications);
 report(@"result %@ %ld",result?@"dictionary":@"nil",(long)result.count);
 for(NSString *k in [result.allKeys sortedArrayUsingSelector:@selector(compare:)]) report(@"map %@ -> %@",k,result[k]);
 if(error) {
  report(@"error %@ %ld keys %@",error.domain,(long)error.code,[[error.userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]);
  report(@"description %@",error.localizedDescription);
  for(NSDictionary *row in error.userInfo[@"HorosAnonymizationFileResults"]) report(@"file %@ %@ %@",row[@"source"],row[@"outcome"],row[@"detail"]);
 }
 check((result!=nil)==success,@"result");check(success?!error:error!=nil,@"error contract");
 if([mode hasPrefix:@"sq-"]) check(sequenceFailures==(success?0:count),@"failure callback only for rejected operations, once per input");
 if(success) check(result.count==count,@"complete output mapping");
 else {
  NSArray *rows=error.userInfo[@"HorosAnonymizationFileResults"];
  check(rows.count==files.count,@"every requested input has a result");
  for(NSUInteger i=0;i<files.count;i++) check([rows[i][@"source"] isEqual:files[i]],@"result source and order");
  if([mode isEqual:@"invalid"]||[mode isEqual:@"missing"]||[mode isEqual:@"publish-failure"])
   check([rows[1][@"outcome"] isEqual:@"failed"]&&[rows[0][@"outcome"] isEqual:@"not-exported"],@"specific failed file distinguished from batch rollback");
  if([mode isEqual:@"large-invalid"])
   check([rows.lastObject[@"outcome"] isEqual:@"failed"]&&[[rows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"outcome == 'failed'"]] count]==1,@"only the final invalid input is marked failed in a large batch");
  if([mode hasPrefix:@"cancel-"]) check([error.domain isEqual:NSCocoaErrorDomain]&&error.code==NSUserCancelledError,@"cancellation distinguished");
  else check(error.localizedDescription.length>0,@"explicit failure");
  if([mode isEqual:@"unsupported-tag"])check([error.localizedDescription containsString:@"(0028,0010)"],@"failed tag identified");
  if([mode isEqual:@"encoding"])check([error.localizedDescription containsString:@"character set"],@"encoding failure identified");
  if([mode hasPrefix:@"charset-"])check([error.localizedDescription containsString:@"character set"],@"encoding refusal identified");
  if([mode hasPrefix:@"sq-"]) {
   check([error.localizedDescription containsString:([mode hasPrefix:@"sq-private"]?@"(0011,1010)":@"(0008,1110)")],@"failed sequence tag identified");
   for(NSDictionary *row in rows) check([row[@"outcome"] isEqual:@"failed"],@"each rejected sequence input is failed");
  }
  for(NSString *p in [NSFileManager.defaultManager subpathsAtPath:output])
   check(![p.pathExtension isEqual:@"dcm"],@"no partial export or staged DICOM left");
 }
 NSLog(@"PASS %@: %@",mode,error.localizedDescription?:[NSString stringWithFormat:@"%ld complete outputs",(long)count]);
} }
'''


def run(*command, **options):
    return subprocess.run([str(c) for c in command], check=True, **options)


def build(path, former, fail_empty_sequence=False):
    """The production Swift/DCMTK harness, optional insertion fault, or former implementation."""
    path.mkdir()
    common = path/'common'
    common.mkdir()
    (common/'fixture-stubs.h').write_text(stubs_header)
    for name in redirected:
        (common/name).write_text('#import "fixture-stubs.h"\n')
    (common/'stubs.mm').write_text(stubs)
    # DCMCalendarDate.m is compiled as it is, without the framework umbrella.
    (common/'DCM.h').write_text('#import <Foundation/Foundation.h>\n#define DCMDEBUG 0\n')
    (common/'DCMCalendarDate.m').write_bytes((root/'DCM Framework/DCMCalendarDate.m').read_bytes())
    includes = ['-I' + str(common), '-I' + str(root/'Horos/Sources'), '-I' + str(root/'DCM Framework'),
                '-I' + str(install/'include'), '-I' + str(gdcm_install/'include'), '-I' + str(gdcm_install/'include/GDCM')]
    flags = ['-fno-objc-arc', '-fblocks', '-Wno-deprecated-declarations', '-Wno-objc-method-access', '-Wno-incomplete-implementation']
    objects = []

    def objc(source, language, *extra):
        obj = path/(source.name + '.o')
        std = ['-std=c++17'] if language == 'objective-c++' else []
        run('xcrun', 'clang', '-c', '-x', language, *std, *flags, *extra, *includes, source, '-o', obj)
        objects.append(obj)

    swift = [root/'Horos/Sources/ExportFolderNaming.swift'] + ([] if former else [anonymization])
    run('xcrun', 'swiftc', '-parse-as-library', '-wmo', '-module-name', 'Horos', '-import-objc-header', common/'fixture-stubs.h',
        *[a for i in includes for a in ('-Xcc', i)], '-emit-objc-header-path', path/'Horos-Swift.h', '-c', *swift, '-o', path/'swift.o')
    objects.append(path/'swift.o')
    objc(common/'stubs.mm', 'objective-c++')
    objc(common/'DCMCalendarDate.m', 'objective-c')
    objc(root/'Horos/Sources/HorosObjCException.m', 'objective-c')
    objc(root/'Horos/Sources/HorosAlertPanel.m', 'objective-c')
    if former:
        # The former implementation, verbatim, next to its own header.
        for name in ['Anonymization.h', 'Anonymization.mm']:
            (path/name).write_bytes(run('git', '-C', root, 'show', f'{FORMER}:Horos/Sources/{name}', capture_output=True).stdout)
        objc(path/'Anonymization.mm', 'objective-c++', '-I' + str(path))
        (path/'main.m').write_text(harness)
        objc(path/'main.m', 'objective-c', '-DHOROS_FORMER')
    else:
        # The regular helper is verbatim. Its #imports reach the doubles; main
        # reaches the compatibility header and the interface generated here.
        helper_source = gdcm_helper.read_text()
        if fail_empty_sequence:
            # The fault executable changes only the insertion result. It
            # exercises the production callback and batch rollback without
            # installing a fault hook in the app or changing the DCMTK library.
            insertion = 'dataset.insertEmptyElement(DcmTag(key, EVR_SQ), OFTrue)'
            assert helper_source.count(insertion) == 1, 'Cannot locate public SQ insertion for fault injection'
            helper_source = helper_source.replace(insertion, 'OFCondition(EC_MemoryExhausted)')
        (path/gdcm_helper.name).write_text(helper_source)
        (path/'HorosSelectedAnonymizationCatalog.h').write_bytes((root/'Horos/Sources/HorosSelectedAnonymizationCatalog.h').read_bytes())
        (path/'HorosDCMTKSeekableInput.h').write_bytes((root/'Horos/Sources/HorosDCMTKSeekableInput.h').read_bytes())
        (common/'main.m').write_text(harness)
        objc(path/gdcm_helper.name, 'objective-c++')
        objc(common/'main.m', 'objective-c', '-I' + str(path), '-DHOROS_FIXTURE_CURRENT_HELPER=1')
    libraries = [install/'lib'/f'lib{name}.a' for name in ['dcmdata', 'oflog', 'ofstd', 'oficonv']]
    if former:
        libraries.append(gdcm_install/'wlib/libGDCM.a')
    run('xcrun', 'swiftc', *objects, *libraries, '-lc++', '-lz', '-lexpat', '-framework', 'Cocoa', '-o', path/'test')
    return path/'test'


def normalised(text, output):
    text = text.replace(str(output), '<output>')
    text = re.sub(r'Anonymized-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}', 'Anonymized-<batch>', text)
    return re.sub(r'\.horos-anonymization-[A-Za-z0-9]{6}', '.horos-anonymization-<random>', text)


def tree(output):
    """{normalised relative path: file bytes, or None for a folder}."""
    found = {}
    for p in sorted(output.rglob('*')):
        found[normalised(str(p), output)] = None if p.is_dir() else semantic_dataset(pydicom.dcmread(p))
    return found


def semantic_dataset(dataset, ignored=()):
    """A recursive semantic manifest; PixelData bytes include BOT and fragments."""
    result = []
    for element in dataset:
        if element.tag in ignored or element.tag.element == 0 or element.tag == (0xfffc, 0xfffc):
            continue
        value = (tuple(semantic_dataset(item) for item in element.value) if element.VR == 'SQ'
                 else bytes(element.value) if isinstance(element.value, bytes) else str(element.value))
        result.append((int(element.tag), element.VR, value))
    return tuple(result)


def charset_matrix(path, current, original, execute):
    """Use the existing batch harness, then decode raw replacement bytes strictly."""
    pn, lo, cs, declaration = (0x10, 0x10), (0x8, 0x80), (0x8, 0x60), (0x8, 0x5)
    multi = ['ISO 2022 IR 6', 'ISO 2022 IR 87']
    # A failed second file must roll back a first file with a compatible UTF-8
    # declaration. Other failures intentionally reject both inputs.
    cases = [
        ('multi-components-groups-vm', multi, pn, 'QA^Family^Given=Ideographic^Group=Phonetic^Group\\QA^Second', True),
        ('multi-empty-first-term', ['', 'ISO 2022 IR 87'], pn, 'QA^Plain=Group', True),
        ('multi-latin-first-ascii', ['ISO 2022 IR 100', 'ISO 2022 IR 6'], pn, 'QA^Plain', True),
        ('multi-latin-discriminant', multi, pn, 'QA^Élodie', False, 'utf-8', None, True),
        ('multi-ideographic-group', multi, pn, 'QA^Plain=山田^太郎=やまだ^たろう', False, 'utf-8', None, True),
        ('multi-lo', multi, lo, '保留', False, 'utf-8', None, True),
        ('single-code-extension', 'ISO 2022 IR 100', pn, 'QA^Élodie', False, 'utf-8', None, True),
        ('multi-empty', multi, pn, '', True),
        ('utf8-components-groups-vm', 'ISO_IR 192', pn, 'QA^Élodie=山田^太郎\\QA^漢', True, 'utf-8'),
        ('latin1', 'ISO_IR 100', pn, 'QA^Élodie', True, 'latin1'),
        ('latin1-impossible', 'ISO_IR 100', pn, 'QA^漢', False, 'utf-8', None, True),
        ('declared-ascii', 'ISO_IR 6', pn, 'QA^Plain', True),
        ('declared-ascii-impossible', 'ISO_IR 6', pn, 'QA^Élodie', False, 'utf-8', None, True),
        ('cs-outside-repertoire', 'ISO_IR 192', cs, 'É', False),
        ('cs-ascii-under-multi', multi, cs, 'MR', True),
        ('absent-host-default', None, pn, 'QA^Élodie', True, 'latin1'),
        ('empty-host-default', '', pn, 'QA^Élodie', True, 'latin1'),
        ('absent-chosen-utf8', None, pn, 'QA^漢', True, 'utf-8', 'ISO_IR 192'),
        ('absent-chosen-latin1-impossible', None, pn, 'QA^漢', False, 'utf-8', 'ISO_IR 100', True),
        ('unknown-declaration', 'UNSUPPORTED_QA', pn, 'QA^Plain', False, 'utf-8', None, True),
        ('unknown-empty', 'UNSUPPORTED_QA', pn, '', True),
        ('nul', 'ISO_IR 192', pn, 'QA\0Hidden', False),
        ('escape', 'ISO_IR 192', pn, 'QA\x1b$B', False),
        ('c1-control', 'ISO_IR 100', pn, 'QA\u0085Hidden', False),
        ('same-declaration', 'ISO_IR 100', declaration, 'ISO_IR 100', True),
        ('change-declaration', 'ISO_IR 100', declaration, 'ISO_IR 192', False),
        ('clear-declaration', 'ISO_IR 100', declaration, '', False),
    ]
    for entry in cases:
        label, charset, selected, replacement, success, *options = entry
        codec = options[0] if options else 'ascii'
        default = options[1] if len(options) > 1 else None
        first_safe = options[2] if len(options) > 2 else False
        case = path/('charset-' + label)
        input_dir, output = case/'input', case/'output'
        input_dir.mkdir(parents=True)
        output.mkdir()
        for index, name in enumerate(['one.dcm', 'two.dcm']):
            ds = copy.deepcopy(original)
            ds.SOPInstanceUID = ds.file_meta.MediaStorageSOPInstanceUID = pydicom.uid.generate_uid()
            ds.InstanceNumber = index + 1
            ds.SpecificCharacterSet = 'ISO_IR 192' if first_safe and index == 0 else charset or ''
            if charset is None and not (first_safe and index == 0):
                del ds.SpecificCharacterSet
            ds.PatientName = 'QA^Original'
            ds.InstitutionName = 'Unselected institution'
            # Nonselected escaped text must remain byte-identical, even when
            # replacing another field or refusing a multirepertoire request.
            codes = ds.get('SpecificCharacterSet')
            if isinstance(codes, pydicom.multival.MultiValue) and list(codes) == multi:
                ds.PatientName = 'QA^Original=山田^太郎'
                ds.InstitutionName = '保留'
            nested = pydicom.Dataset()
            nested.PatientName = 'QA^Nested'
            ds.ReferencedImageSequence = [nested]
            ds.save_as(input_dir/name, enforce_file_format=True)
        before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in input_dir.iterdir()}
        mode = 'charset-success' if success else 'charset-refusal'
        done = execute(current, mode, input_dir, output, 2,
                       json.dumps([[*selected, replacement]]), default or 'none')
        assert done.returncode == 0, (label, done.stdout)
        assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in before.items()), label
        files = list(output.rglob('*.dcm'))
        if not success:
            assert not files and 'publications 0' in done.stdout, (label, done.stdout)
            tag = f'({selected[0]:04X},{selected[1]:04X})'
            assert tag in done.stdout and 'character set' in done.stdout, (label, done.stdout)
            assert f'file {input_dir/"one.dcm"} {"not-exported" if first_safe else "failed"} ' in done.stdout, (label, done.stdout)
            assert f'file {input_dir/"two.dcm"} failed ' in done.stdout, (label, done.stdout)
            print('PASS charset ' + label + ': explicit tag diagnostic, complete rollback, originals preserved', flush=True)
            continue
        assert len(files) == 2, label
        for file in files:
            actual = pydicom.dcmread(file)
            raw = (str(actual.SpecificCharacterSet).encode('ascii') if selected == declaration
                   else actual.get_item(selected, keep_deferred=True).value or b'')
            assert isinstance(raw, bytes), (label, type(raw))
            assert raw.rstrip(b' \0').decode(codec, errors='strict') == replacement, (label, raw)
            source = input_dir/('one.dcm' if actual.InstanceNumber == 1 else 'two.dcm')
            expected = pydicom.dcmread(source)
            for unselected in [pn, lo]:
                if unselected != selected:
                    assert actual.get_item(unselected, keep_deferred=True).value == expected.get_item(unselected, keep_deferred=True).value, label + ': raw text changed'
            assert semantic_dataset(actual, (selected,)) == semantic_dataset(expected, (selected,)), label + ': unselected attributes/pixels changed'
            assert actual.file_meta.TransferSyntaxUID == expected.file_meta.TransferSyntaxUID, label
            assert actual.file_meta.MediaStorageSOPInstanceUID == expected.file_meta.MediaStorageSOPInstanceUID, label
            assert actual.get('SpecificCharacterSet') == expected.get('SpecificCharacterSet'), label
        print('PASS charset ' + label + ': strict replacement decoding, declaration/raw text/payload preserved', flush=True)
    print(f'PASS charset matrix: {len(cases)} two-input batches', flush=True)


with tempfile.TemporaryDirectory(prefix='horos-anonymization-dcmtk-') as tmp:
    path = Path(tmp)
    environment = dict(os.environ, TZ='UTC')
    current = build(path/'current', former=False)
    former = build(path/'former', former=True) if compare else None
    run(sys.executable, root/'tools/generate-anonymization-order-fixture.py', path/'generated')
    original = pydicom.dcmread(path/'generated/reverse-99.dcm')
    compared = []

    def execute(test, *arguments, timing=()):
        done = subprocess.run([str(a) for a in (*timing, test, *arguments)], env=environment, capture_output=True, text=True)
        sys.stderr.write(done.stderr)
        return done

    def same(mode, a, b, output_a, output_b):
        assert a.returncode == b.returncode, f'{mode}: exit status {a.returncode} != former {b.returncode}'
        report_a, report_b = normalised(a.stdout, output_a), normalised(b.stdout, output_b)
        assert report_a == report_b, f'{mode}: reported result differs from the former implementation:\n{report_a}\n---\n{report_b}'
        if output_a:
            files_a, files_b = tree(output_a), tree(output_b)
            assert files_a.keys() == files_b.keys(), f'{mode}: output trees differ: {sorted(files_a.keys() ^ files_b.keys())}'
            for name in files_a:
                assert files_a[name] == files_b[name], f'{mode}: {name} differs from the former output'
            written = [v for v in files_a.values() if v is not None]
            compared.append((mode, len(written)))
        else:
            compared.append((mode, 0))
        files = compared[-1][1]
        print(f'PASS compare {mode}: same status and report' + ('' if not output_a else f', {files} output datasets semantically equivalent' if files else ', no output file left by either'), flush=True)

    helpers = execute(current, 'helpers')
    assert helpers.returncode == 0, helpers.stdout
    if compare:
        same('helpers', helpers, execute(former, 'helpers'), None, None)
    modes = ['success', 'mixed-encoding', 'multi'] if '--charsets' in sys.argv else sequence_modes if '--empty-sequences' in sys.argv else ['success','duplicate-uid','duplicate-path','invalid','missing','no-tags','unsupported-tag','encoding','mixed-encoding','multi','write-failure','publish-failure','cancel-copy','cancel-publish','cancel-final'] + sequence_modes + (['large'] if '--large' in sys.argv else []) + (['large-mixed','large-invalid'] if '--large-mixed' in sys.argv else [])
    for mode in modes:
        # multi runs in folders whose names defaultCStringEncoding cannot hold:
        # GDCM got a NULL file name from them.
        case=path/(mode+'-漢字' if mode=='multi' else mode);input_dir=case/'input';output=case/'output';input_dir.mkdir(parents=True);output.mkdir()
        count=29329 if mode.startswith('large') else 2
        expected={}
        sequence_inputs={}
        for index,name in enumerate(['one.dcm','two.dcm'] if count==2 else [f'image-{i:05d}.dcm' for i in range(count)]):
            ds=copy.deepcopy(original);ds.InstanceNumber=index+1
            ds.SOPInstanceUID=ds.file_meta.MediaStorageSOPInstanceUID='1.2.826.0.1.3680043.10.543.5.1' if mode=='duplicate-uid' or (mode=='large-mixed' and index>=count-2) else pydicom.uid.generate_uid()
            ds.SpecificCharacterSet=('ISO_IR 100' if index==0 else 'ISO_IR 192') if mode=='mixed-encoding' else ''
            ds.PixelData=((index+1)%4096).to_bytes(2,'little')*(ds.Rows*ds.Columns)
            if mode in sequence_modes:
                item=pydicom.dataset.Dataset()
                item.ReferencedSOPClassUID=ds.SOPClassUID
                item.ReferencedSOPInstanceUID=ds.SOPInstanceUID
                if mode not in {'sq-absent', 'sq-empty'}:
                    ds.ReferencedStudySequence=pydicom.sequence.Sequence([copy.deepcopy(item)])
                elif mode=='sq-empty':
                    ds.ReferencedStudySequence=pydicom.sequence.Sequence([])
                # The same selected tag nested in a different, unselected SQ
                # must remain populated; the operation visits only the root.
                series=pydicom.dataset.Dataset()
                series.SeriesInstanceUID=ds.SeriesInstanceUID
                series.ReferencedStudySequence=pydicom.sequence.Sequence([copy.deepcopy(item)])
                ds.ReferencedSeriesSequence=pydicom.sequence.Sequence([series])
                ds.add_new((0x11,0x10),'LO','LOCAL_QA')
                if mode!='sq-private-absent':
                    ds.add_new((0x11,0x1010),'SQ',pydicom.sequence.Sequence([copy.deepcopy(item)]))
                sequence_inputs[str(ds.SOPInstanceUID)]=copy.deepcopy(ds)
            expected[(str(ds.SOPInstanceUID),int(ds.InstanceNumber))]=hashlib.sha256(ds.PixelData).hexdigest()
            ds.save_as(input_dir/name,enforce_file_format=True)
        if mode in ['invalid','large-invalid']: (input_dir/('two.dcm' if count==2 else f'image-{count-1:05d}.dcm')).write_bytes(b'synthetic invalid DICOM\n')
        if mode=='missing': (input_dir/'two.dcm').unlink()
        before={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in input_dir.iterdir()}
        timing=['/usr/bin/time','-l'] if mode.startswith('large') else []
        test=build(path/'insert-failure', former=False, fail_empty_sequence=True) if mode=='sq-insert-failure' else current
        done=execute(test,mode,input_dir,output,count,timing=timing)
        assert done.returncode==0, f'{mode}: harness failed\n{done.stdout}'
        assert all(hashlib.sha256(p.read_bytes()).hexdigest()==h for p,h in before.items())
        # multi's dates are DICOM strings; the former wrote DT as
        # the NSDate's description, so the two cannot match there.
        if compare and mode!='multi' and mode not in sequence_modes:
            output_former=case/'output-former';output_former.mkdir()
            done_former=execute(former,mode,input_dir,output_former,count,timing=timing)
            assert all(hashlib.sha256(p.read_bytes()).hexdigest()==h for p,h in before.items())
            same(mode,done,done_former,output,output_former)
        if mode in ['success','mixed-encoding','duplicate-uid','multi','large','large-mixed'] or mode in sequence_success:
            files=list(output.rglob('*.dcm'));assert len(files)==count
            actual={}
            for p in files:
                ds=pydicom.dcmread(p)
                if mode in sequence_success:
                    selected=(0x11,0x1010) if mode=='sq-private' else (0x8,0x1110)
                    assert selected in ds, 'Empty sequence must remain present'
                    assert ds[selected].VR=='SQ' and len(ds[selected].value)==0, 'Empty sequence must have no items'
                    before_ds=sequence_inputs[str(ds.SOPInstanceUID)]
                    unchanged=copy.deepcopy(ds)
                    del unchanged[selected]
                    before_ds=copy.deepcopy(before_ds)
                    if selected in before_ds:
                        del before_ds[selected]
                    assert unchanged==before_ds, 'An unselected dataset attribute changed'
                    for tag in before_ds.file_meta:
                        if int(tag.tag) not in {0x00020000, 0x00020012, 0x00020013}:
                            assert tag==ds.file_meta[tag.tag], 'An unselected metainfo attribute changed'
                else:
                    assert str(ds.PatientName)==('QA^Élodie' if mode=='mixed-encoding' else 'QA^Anonymous')
                if mode=='multi':
                    # Numbers by VR and no value.
                    assert (ds.PatientID,str(ds.PatientWeight),str(ds.SeriesNumber),ds.InstitutionName,ds.PatientAge)==('','72.5','9','7','042Y'), 'converted replacement values'
                    # 2001-02-03 12:34:56 UTC, the harness's zone: DA, TM and DT
                    # in DICOM's formats, DT with its offset.
                    assert (ds.PatientBirthDate,ds.StudyTime,ds.AcquisitionDateTime)==('20010203','123456','20010203123456+0000'), f'DICOM dates: {(ds.PatientBirthDate,ds.StudyTime,ds.AcquisitionDateTime)}'
                    dates=(ds.PatientBirthDate,ds.StudyTime,ds.AcquisitionDateTime)
                key=(str(ds.SOPInstanceUID),int(ds.InstanceNumber))
                assert key not in actual, 'Duplicate output instance key'
                actual[key]=hashlib.sha256(ds.PixelData).hexdigest()
            assert actual==expected, 'Input/output UID, instance and pixel manifests differ'
            print(f'PASS manifest {mode}: {len(files)} files, {len({k[0] for k in actual})} unique SOP UIDs'+(f', dates {dates}' if mode=='multi' else ''),flush=True)

    charset_matrix(path, current, original, execute)
    if '--charsets' in sys.argv:
        print('PASS lightweight charset/default/date batches; parser probes not run')
        raise SystemExit(0)

    order_output = path/'order-output'
    order_output.mkdir()
    order_hashes = path/'order-hashes.json'
    order_hashes.write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (path/'generated').glob('*.dcm')}))
    done = execute(current, 'order', path/'generated', order_output, 12)
    assert done.returncode == 0, done.stdout
    # The harness has no Core Data/viewer: reimport is a pending app gate.
    # Running the existing verifier over the exported set twice checks its
    # order/pixel oracle without claiming an app reimport execution.
    run(sys.executable, root/'tools/verify-anonymization-order.py', path/'generated', order_output, order_output, order_hashes)
    def fixture():
        ds = copy.deepcopy(original)
        ds.SpecificCharacterSet = 'ISO_IR 192'
        ds.PatientName = 'QA^Original'
        ds.add_new((0x0011, 0x0010), 'LO', 'QA_CREATOR')
        ds.add_new((0x0011, 0x1010), 'LO', 'private retained')
        ds.add_new((0x0011, 0x1011), 'UN', b'\x01\x02\x03\x04')
        nested = pydicom.Dataset()
        nested.PatientName = 'QA^Nested'
        nested.ReferencedSOPClassUID = ds.SOPClassUID
        nested.ReferencedSOPInstanceUID = ds.SOPInstanceUID
        ds.ReferencedImageSequence = [nested]
        ds.add_new((0x0011, 0x1012), 'SQ', [copy.deepcopy(nested)])
        ds.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
        ds.RescaleSlope = '1.5'
        ds.RescaleIntercept = '-1024'
        ds.FrameOfReferenceUID = pydicom.uid.generate_uid()
        ds.file_meta.SourceApplicationEntityTitle = 'QA_META'
        return ds

    def single(label, ds, selections, *, failures=0, written=True, ignored=(), fault='file', mutate=None):
        case = path/('file-' + label)
        case.mkdir()
        source = case/'input.dcm'
        # Explicit BE cannot be produced by save_as from a LE source.
        pydicom.dcmwrite(source, ds, enforce_file_format=True)
        if mutate:
            mutate(source)
        before = source.read_bytes()
        done = execute(current, fault, source, json.dumps(selections))
        assert done.returncode == 0, (label, done.stdout)
        assert f'written {int(written)} failures {failures}' in done.stdout, (label, done.stdout)
        output = case/'anon_input.dcm'
        assert output.is_file() == written, (label, done.stdout)
        if fault in ['file', 'file-save', 'file-close', 'file-rename', 'file-default']:
            assert source.read_bytes() == before, label + ': original changed'
        assert not list(case.glob('.horos-anonymized-*')), label + ': temporary left'
        assert not list(case.glob('.horos-inflate-*')), label + ': backing left'
        if not written:
            print('PASS file ' + label + ': refused, no output', flush=True)
            return
        actual = pydicom.dcmread(output)
        expected = pydicom.dcmread(source)
        assert str(actual.file_meta.TransferSyntaxUID) == str(expected.file_meta.TransferSyntaxUID), label
        assert semantic_dataset(actual, ignored) == semantic_dataset(expected, ignored), label + ': unselected attributes changed'
        assert actual.file_meta.SourceApplicationEntityTitle == expected.file_meta.SourceApplicationEntityTitle, label
        assert actual.file_meta.MediaStorageSOPClassUID == getattr(actual, 'SOPClassUID', expected.file_meta.MediaStorageSOPClassUID), label
        assert actual.file_meta.MediaStorageSOPInstanceUID == getattr(actual, 'SOPInstanceUID', expected.file_meta.MediaStorageSOPInstanceUID), label
        print('PASS file ' + label + ': syntax, unselected semantics, payload and original preserved', flush=True)
        return actual

    for uid in [pydicom.uid.ImplicitVRLittleEndian, pydicom.uid.ExplicitVRLittleEndian,
                pydicom.uid.ExplicitVRBigEndian, pydicom.uid.DeflatedExplicitVRLittleEndian]:
        ds = fixture()
        ds.file_meta.TransferSyntaxUID = uid
        ds.Rows = ds.Columns = 256
        ds.NumberOfFrames = 2
        endian = '>' if uid == pydicom.uid.ExplicitVRBigEndian else '<'
        ds.PixelData = b''.join(struct.pack(endian + 'H', i % 65536) for i in range(256*256*2))
        actual = single(str(uid), ds, [[0x10, 0x10, 'QA^Élodie']], ignored=((0x10, 0x10),))
        assert actual.PatientName == 'QA^Élodie'
    # A real multiframe RLE codestream with BOT is generated by pydicom's encoder.
    ds = fixture()
    ds.Rows = ds.Columns = 32
    ds.NumberOfFrames = 2
    ds.PixelData = bytes(range(256)) * 16
    ds.compress(pydicom.uid.RLELossless)
    single('rle-multiframe', ds, [[0x10, 0x10, 'QA^Anonymous']], ignored=((0x10, 0x10),))
    actual = single('rle-selected-empty-pixel', ds, [[0x7fe0, 0x10]], ignored=((0x7fe0, 0x10),))
    assert list(pydicom.encaps.generate_fragments(actual.PixelData)) == [b''], repr(actual.PixelData[:80])
    # Other syntax envelopes are deliberately opaque: no codec is invoked by
    # selected-field anonymization. Only fragment/BOT preservation is asserted.
    for uid in [pydicom.uid.JPEGBaseline8Bit, pydicom.uid.JPEGLSLossless,
                pydicom.uid.JPEG2000Lossless, '1.2.840.10008.1.2.4.201', '1.2.840.10008.1.2.4.102']:
        ds = fixture()
        ds.file_meta.TransferSyntaxUID = uid
        ds.NumberOfFrames = 2
        ds.PixelData = pydicom.encaps.encapsulate([b'opaque-first-frame'*1000, b'opaque-second-frame'*1000], fragments_per_frame=2)
        ds['PixelData'].is_undefined_length = True
        ds['PixelData'].VR = 'OB'
        single('opaque-' + str(uid), ds, [[0x10, 0x10, 'QA^Anonymous']], ignored=((0x10, 0x10),))
    ds = fixture()
    actual = single('root-only-and-order', ds, [[0x10, 0x10, 'QA^First'], [0x10, 0x10, 'QA^Last']], ignored=((0x10, 0x10),))
    assert actual.PatientName == 'QA^Last' and actual.ReferencedImageSequence[0].PatientName == 'QA^Nested'
    ds = fixture()
    del ds.PatientID
    actual = single('create-public', ds, [[0x10, 0x20, 'QA_ID']], ignored=((0x10, 0x20),))
    assert actual.PatientID == 'QA_ID'
    for label, selections, ignored, check in [
        ('empty-text', [[0x10, 0x20]], ((0x10, 0x20),), lambda d: d.PatientID == ''),
        ('empty-pixels', [[0x7fe0, 0x10]], ((0x7fe0, 0x10),), lambda d: d.PixelData in (b'', None)),
        ('empty-binary', [[0x28, 0x10]], ((0x28, 0x10),), lambda d: (0x28, 0x10) in d and d.Rows is None),
        ('empty-absent-binary', [[0x28, 0x100]], ((0x28, 0x100),), lambda d: (0x28, 0x100) in d and d.BitsAllocated is None),
        ('empty-private', [[0x11, 0x1010]], ((0x11, 0x1010),), lambda d: d[0x11, 0x1010].value == ''),
        ('empty-private-un', [[0x11, 0x1011]], ((0x11, 0x1011),), lambda d: d[0x11, 0x1011].value in (b'', None)),
        ('empty-private-sq', [[0x11, 0x1012]], ((0x11, 0x1012),), lambda d: len(d[0x11, 0x1012].value) == 0),
        ('private-creator', [[0x11, 0x10, 'QA_CHANGED']], ((0x11, 0x10),), lambda d: d[0x11, 0x10].value == 'QA_CHANGED'),
        ('public-sq-empty', [[0x8, 0x1140]], ((0x8, 0x1140),), lambda d: (0x8, 0x1140) in d and d[0x8, 0x1140].VR == 'SQ' and len(d.ReferencedImageSequence) == 0),
        ('public-sq-absent', [[0x8, 0x1110]], ((0x8, 0x1110),), lambda d: (0x8, 0x1110) in d and d[0x8, 0x1110].VR == 'SQ' and len(d.ReferencedStudySequence) == 0),
        ('sop-instance', [[0x8, 0x18, '1.2.826.0.1.3680043.10.543.999']], ((0x8, 0x18),), lambda d: str(d.SOPInstanceUID).endswith('.999')),
        ('sop-class', [[0x8, 0x16, str(pydicom.uid.MRImageStorage)]], ((0x8, 0x16),), lambda d: d.SOPClassUID == pydicom.uid.MRImageStorage),
    ]:
        ds = fixture()
        if label == 'empty-absent-binary':
            del ds.BitsAllocated
        actual = single(label, ds, selections, ignored=ignored)
        assert check(actual), label
    for label, selections in [
        ('binary-nonempty', [[0x28, 0x10, '12']]),
        ('sq-nonempty', [[0x8, 0x1140, '[]']]),
        ('private-nonempty', [[0x11, 0x1010, 'QA']]),
        ('private-absent', [[0x11, 0x1020]]),
        ('meta-selected', [[0x2, 0x3, '1.2.3']]),
        ('directory-group', [[0x4, 0x1130, 'QA']]),
        ('unknown-public', [[0x8, 0x9999, 'QA']]),
    ]:
        ds = fixture()
        ds.add_new((0x8, 0x9999), 'LO', 'unknown retained')
        single(label, ds, selections, failures=1)
    ds = fixture()
    ds[0x10, 0x10].VR = 'US'
    ds[0x10, 0x10].value = 42
    single('malformed-text-vr', ds, [[0x10, 0x10, 'QA']], failures=1)
    # Small boundary controls; no large allocation or malformed-VL probe.
    uid64 = '1.' + '2' * 62
    uid65 = uid64 + '2'
    ds = fixture()
    ds.SOPInstanceUID = ds.file_meta.MediaStorageSOPInstanceUID = uid64
    actual = single('sop-instance-64-bytes', ds, [[0x10, 0x10, 'QA']], ignored=((0x10, 0x10),))
    assert actual.SOPInstanceUID == uid64
    ds = fixture()
    ds.SOPInstanceUID = ds.file_meta.MediaStorageSOPInstanceUID = uid65
    single('sop-instance-over-limit', ds, [[0x10, 0x10, 'QA']], failures=1, written=False)
    single('selected-sop-instance-over-limit', fixture(), [[0x8, 0x18, uid65]], failures=1, written=False)
    for label in ['unsupported-storage', 'missing-sop-class', 'empty-sop-instance', 'empty-selected-sop-instance']:
        ds = fixture()
        if label == 'unsupported-storage':
            ds.SOPClassUID = ds.file_meta.MediaStorageSOPClassUID = '1.2.840.10008.1.1'
        if label == 'missing-sop-class':
            del ds.SOPClassUID
        if label == 'empty-sop-instance':
            ds.SOPInstanceUID = ''
        selections = [[0x8, 0x18]] if label == 'empty-selected-sop-instance' else [[0x10, 0x10, 'QA']]
        single(label, ds, selections, failures=1, written=False)
    ds = fixture()
    del ds.SOPClassUID
    del ds.SOPInstanceUID
    ds.file_meta.MediaStorageSOPClassUID = pydicom.uid.MediaStorageDirectoryStorage
    ds.DirectoryRecordSequence = []
    single('dicomdir', ds, [[0x10, 0x10, 'QA']], ignored=((0x10, 0x10),))
    for fault in ['file-remove', 'file-truncate', 'file-inaccessible']:
        ds = fixture()
        ds.Rows = ds.Columns = 256
        ds.PixelData = b'\x12\x34' * (256*256)
        single(fault, ds, [[0x28, 0x10, '12']], failures=2, written=False, fault=fault)
    for fault in ['file-save', 'file-close', 'file-rename']:
        single(fault, fixture(), [[0x10, 0x10, 'QA']], failures=1, written=False, fault=fault)
    ds = fixture()
    del ds.SpecificCharacterSet
    actual = single('absent-charset-default', ds, [[0x10, 0x10, 'QA^Plain']], ignored=((0x10, 0x10),))
    assert actual.PatientName == 'QA^Plain' and 'SpecificCharacterSet' not in actual
    ds = fixture()
    ds.SpecificCharacterSet = ['ISO 2022 IR 100', 'ISO 2022 IR 6']
    single('first-charset-term-refused', ds, [[0x10, 0x10, 'QA^Élodie']], failures=1)
    for uid in ['1.2.392.200036.9125.1.1.2', '1.2.392.200036.9125.1.1.4', '1.3.12.2.1107.5.9.1']:
        ds = fixture()
        ds.SOPClassUID = ds.file_meta.MediaStorageSOPClassUID = uid
        single('private-storage-' + uid, ds, [[0x10, 0x10, 'QA']], ignored=((0x10, 0x10),))
    ds = fixture()
    nested = ds
    for level in range(18):
        child = pydicom.Dataset()
        nested.ContentSequence = [child]
        nested = child
    single('depth-limit', ds, [[0x10, 0x10, 'QA']], failures=1, written=False)
    def truncated(p):
        p.write_bytes(p.read_bytes()[:-100])
    ds = fixture()
    ds.Rows = ds.Columns = 256
    ds.PixelData = b'\x12\x34' * (256*256)
    single('truncated-payload', ds, [[0x10, 0x10, 'QA']], failures=1, written=False, mutate=truncated)
    if compare:
        print(f'PASS compare with {FORMER}: {len(compared)} scenarios; generated values normalised: batch UUID, working-folder suffix, output folder')
        for mode, count in compared:
            print(f'  {mode}: {count} semantically equivalent output files')
print('PASS all scenarios: original bytes preserved; successful tags and pixels verified independently')

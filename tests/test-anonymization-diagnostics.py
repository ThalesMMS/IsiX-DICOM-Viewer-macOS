#!/usr/bin/env python3
"""Run the production anonymization code with the built GDCM and generated DICOM.

Anonymization is Swift since #712 (Horos/Sources/Anonymization.swift); its
per-file GDCM work is in Horos/Sources/HorosGDCMAnonymizer.mm. Both are
compiled as they are, with the real HorosObjCException, HorosAlertPanel,
ExportFolderNaming, DCMCalendarDate and HorosAnonymizationSafety. Requires
pydicom/numpy and a successful Debug dependency build. App model, tag table,
panels and progress UI are doubles; GDCM reads, tag replacement, writes and
files are real.

--compare also builds the former Objective-C++ implementation
(Anonymization.mm at FORMER, the last revision before #712) verbatim, with the
same doubles, anonymizes the same inputs with both, and requires the same
exit status, the same reported result and error, and output files equal byte
for byte. The values generated on each run are named and normalised: the
batch UUID of the "Anonymized-<UUID>" folder, the random suffix of the
".horos-anonymization-XXXXXX" working folder and the output folder itself.
--large and --large-mixed add the 29329-file scenarios.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import hashlib
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
install = root/'build/Build/Intermediates.noindex/Horos.build/Debug/GDCM.build/Install'
if not (install/'wlib/libGDCM.a').exists():
    # Not built here: a skip, not a failure. SystemExit with a string exits 1,
    # which tools/run-tests.py reads as failed; the skip code is 2.
    print('skipped: needs a built GDCM; run script/build_and_run.sh --verify first',
          file=sys.stderr)
    raise SystemExit(2)
assert is_swift('Anonymization'), 'Anonymization is expected in Swift since #712'
anonymization = source_path('Anonymization')
gdcm_helper = source_path('HorosGDCMAnonymizer')
compare = '--compare' in sys.argv


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
#include <GDCM/gdcmReader.h>
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
 gdcm::Reader reader;reader.SetFileName(p.fileSystemRepresentation);
 if(!reader.Read()) return @[];
 const gdcm::DataSet &ds=reader.GetFile().GetDataSet();gdcm::Tag tag(8,5);
 if(!ds.FindDataElement(tag)) return @[@""];
 const gdcm::ByteValue *value=ds.GetDataElement(tag).GetByteValue();
 NSString *str=value?[[[NSString alloc] initWithBytes:value->GetPointer() length:value->GetLength() encoding:NSASCIIStringEncoding] autorelease]:@"";
 return @[str?:@""];
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
static NSString *mode, *output;
static NSInteger polls, publications;
static void check(BOOL ok, NSString *why) { if(!ok) { NSLog(@"FAIL %@: %@",mode,why);exit(1); } }
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
 NSString *input=[NSString stringWithUTF8String:argv[2]];output=[NSString stringWithUTF8String:argv[3]];
 method_exchangeImplementations(class_getInstanceMethod(NSFileManager.class,@selector(moveItemAtPath:toPath:error:)),class_getInstanceMethod(NSFileManager.class,@selector(fixtureMove:toPath:error:)));
 NSInteger count=argc>4?atoi(argv[4]):2;
 NSMutableArray *files=[NSMutableArray array];
 for(NSInteger i=0;i<count;i++) [files addObject:[input stringByAppendingPathComponent:count==2?(i==0?@"one.dcm":@"two.dcm"):[NSString stringWithFormat:@"image-%05ld.dcm",(long)i]]];
 if([mode isEqual:@"duplicate-path"]) files[1]=files[0];
 DicomSeries *series=[DicomSeries new];series.study=[DicomStudy new];NSMutableArray *images=[NSMutableArray array];
 for(int i=0;i<count;i++){ DicomImage *im=[DicomImage new];im.series=series;im.instanceNumber=@(i+1);[images addObject:im]; }
 DCMAttributeTag *tag=[DCMAttributeTag tagWithGroup:0x10 element:0x10 vr:@"PN" name:@"PatientsName"];
 if([mode isEqual:@"unsupported-tag"]) tag=[DCMAttributeTag tagWithGroup:0x28 element:0x10 vr:@"US" name:@"Rows"];
 NSString *value=[mode isEqual:@"encoding"]?@"QA^漢":([mode isEqual:@"mixed-encoding"]?@"QA^Élodie":@"QA^Anonymous");
 NSArray *tags=[mode isEqual:@"no-tags"]?@[]:@[@[tag,value]];
 if([mode isEqual:@"multi"]) {
  // Every conversion the method makes before GDCM: dates by VR, numbers by VR, a number left as it is, no value.
  NSDate *date=[NSDate dateWithTimeIntervalSince1970:981203696];
  tags=@[@[tag,value],@[[DCMAttributeTag tagWithName:@"PatientID"]],@[[DCMAttributeTag tagWithName:@"PatientsBirthDate"],date],
   @[[DCMAttributeTag tagWithName:@"StudyTime"],date],@[[DCMAttributeTag tagWithName:@"AcquisitionDatetime"],date],
   @[[DCMAttributeTag tagWithName:@"PatientsWeight"],@72.5],@[[DCMAttributeTag tagWithName:@"SeriesNumber"],@9],
   @[[DCMAttributeTag tagWithName:@"InstitutionName"],@7],@[[DCMAttributeTag tagWithName:@"PatientsAge"],@"042Y"]];
 }
 NSError *error=nil;
 NSDictionary *result=[Anonymization anonymizeFiles:files dicomImages:images toPath:output withTags:tags error:&error];
 BOOL success=[mode isEqual:@"success"]||[mode isEqual:@"mixed-encoding"]||[mode isEqual:@"duplicate-uid"]||[mode isEqual:@"large"]||[mode isEqual:@"large-mixed"]||[mode isEqual:@"multi"];
 report(@"polls %ld publications %ld",(long)polls,(long)publications);
 report(@"result %@ %ld",result?@"dictionary":@"nil",(long)result.count);
 for(NSString *k in [result.allKeys sortedArrayUsingSelector:@selector(compare:)]) report(@"map %@ -> %@",k,result[k]);
 if(error) {
  report(@"error %@ %ld keys %@",error.domain,(long)error.code,[[error.userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]);
  report(@"description %@",error.localizedDescription);
  for(NSDictionary *row in error.userInfo[@"HorosAnonymizationFileResults"]) report(@"file %@ %@ %@",row[@"source"],row[@"outcome"],row[@"detail"]);
 }
 check((result!=nil)==success,@"result");check(success?!error:error!=nil,@"error contract");
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
  for(NSString *p in [NSFileManager.defaultManager subpathsAtPath:output])
   check(![p.pathExtension isEqual:@"dcm"],@"no partial export or staged DICOM left");
 }
 NSLog(@"PASS %@: %@",mode,error.localizedDescription?:[NSString stringWithFormat:@"%ld complete outputs",(long)count]);
} }
'''


def run(*command, **options):
    return subprocess.run([str(c) for c in command], check=True, **options)


def build(path, former):
    """The harness around the current Swift and GDCM helper, or around the former Anonymization.mm."""
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
                '-I' + str(install/'include'), '-I' + str(install/'include/GDCM')]
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
        objc(path/'main.m', 'objective-c')
    else:
        # The helper, verbatim, where its #imports reach the doubles; main reaches the
        # compatibility header in Horos/Sources and the interface generated here.
        (path/gdcm_helper.name).write_bytes(gdcm_helper.read_bytes())
        (common/'main.m').write_text(harness)
        objc(path/gdcm_helper.name, 'objective-c++')
        objc(common/'main.m', 'objective-c', '-I' + str(path))
    run('xcrun', 'swiftc', *objects, install/'wlib/libGDCM.a', '-lc++', '-lz', '-framework', 'Cocoa', '-o', path/'test')
    return path/'test'


def normalised(text, output):
    text = text.replace(str(output), '<output>')
    text = re.sub(r'Anonymized-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}', 'Anonymized-<batch>', text)
    return re.sub(r'\.horos-anonymization-[A-Za-z0-9]{6}', '.horos-anonymization-<random>', text)


def tree(output):
    """{normalised relative path: file bytes, or None for a folder}."""
    found = {}
    for p in sorted(output.rglob('*')):
        found[normalised(str(p), output)] = None if p.is_dir() else p.read_bytes()
    return found


with tempfile.TemporaryDirectory(prefix='horos-anonymization-gdcm-') as tmp:
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
            compared.append((mode, len(written), sum(map(len, written)), hashlib.sha256(b''.join(written)).hexdigest()[:16]))
        else:
            compared.append((mode, 0, 0, ''))
        files = compared[-1][1]
        print(f'PASS compare {mode}: same status and report' + ('' if not output_a else f', {files} output files identical byte for byte' if files else ', no output file left by either'), flush=True)

    helpers = execute(current, 'helpers')
    assert helpers.returncode == 0, helpers.stdout
    if compare:
        same('helpers', helpers, execute(former, 'helpers'), None, None)
    for mode in ['success','duplicate-uid','duplicate-path','invalid','missing','no-tags','unsupported-tag','encoding','mixed-encoding','multi','write-failure','publish-failure','cancel-copy','cancel-publish','cancel-final'] + (['large'] if '--large' in sys.argv else []) + (['large-mixed','large-invalid'] if '--large-mixed' in sys.argv else []):
        # multi runs in folders whose names defaultCStringEncoding cannot hold:
        # GDCM got a NULL file name from them (#749).
        case=path/(mode+'-漢字' if mode=='multi' else mode);input_dir=case/'input';output=case/'output';input_dir.mkdir(parents=True);output.mkdir()
        count=29329 if mode.startswith('large') else 2
        expected={}
        for index,name in enumerate(['one.dcm','two.dcm'] if count==2 else [f'image-{i:05d}.dcm' for i in range(count)]):
            ds=original.copy();ds.InstanceNumber=index+1
            ds.SOPInstanceUID=ds.file_meta.MediaStorageSOPInstanceUID='1.2.826.0.1.3680043.10.543.5.1' if mode=='duplicate-uid' or (mode=='large-mixed' and index>=count-2) else pydicom.uid.generate_uid()
            ds.SpecificCharacterSet=('ISO_IR 100' if index==0 else 'ISO_IR 192') if mode=='mixed-encoding' else ''
            ds.PixelData=((index+1)%4096).to_bytes(2,'little')*(ds.Rows*ds.Columns)
            expected[(str(ds.SOPInstanceUID),int(ds.InstanceNumber))]=hashlib.sha256(ds.PixelData).hexdigest()
            ds.save_as(input_dir/name,enforce_file_format=True)
        if mode in ['invalid','large-invalid']: (input_dir/('two.dcm' if count==2 else f'image-{count-1:05d}.dcm')).write_bytes(b'synthetic invalid DICOM\n')
        if mode=='missing': (input_dir/'two.dcm').unlink()
        before={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in input_dir.iterdir()}
        timing=['/usr/bin/time','-l'] if mode.startswith('large') else []
        done=execute(current,mode,input_dir,output,count,timing=timing)
        assert done.returncode==0, f'{mode}: harness failed'
        assert all(hashlib.sha256(p.read_bytes()).hexdigest()==h for p,h in before.items())
        # multi's dates are DICOM strings since #749; the former wrote DT as
        # the NSDate's description, so the two cannot match there.
        if compare and mode!='multi':
            output_former=case/'output-former';output_former.mkdir()
            done_former=execute(former,mode,input_dir,output_former,count,timing=timing)
            assert all(hashlib.sha256(p.read_bytes()).hexdigest()==h for p,h in before.items())
            same(mode,done,done_former,output,output_former)
        if mode in ['success','mixed-encoding','duplicate-uid','multi','large','large-mixed']:
            files=list(output.rglob('*.dcm'));assert len(files)==count
            actual={}
            for p in files:
                ds=pydicom.dcmread(p)
                assert str(ds.PatientName)==('QA^Élodie' if mode=='mixed-encoding' else 'QA^Anonymous')
                if mode=='multi':
                    # Numbers by VR and no value.
                    assert (ds.PatientID,str(ds.PatientWeight),str(ds.SeriesNumber),ds.InstitutionName,ds.PatientAge)==('','72.5','9','7','042Y'), 'converted replacement values'
                    # 2001-02-03 12:34:56 UTC, the harness's zone: DA, TM and DT
                    # in DICOM's formats, DT with its offset (#749).
                    assert (ds.PatientBirthDate,ds.StudyTime,ds.AcquisitionDateTime)==('20010203','123456','20010203123456+0000'), f'DICOM dates: {(ds.PatientBirthDate,ds.StudyTime,ds.AcquisitionDateTime)}'
                    dates=(ds.PatientBirthDate,ds.StudyTime,ds.AcquisitionDateTime)
                key=(str(ds.SOPInstanceUID),int(ds.InstanceNumber))
                assert key not in actual, 'Duplicate output instance key'
                actual[key]=hashlib.sha256(ds.PixelData).hexdigest()
            assert actual==expected, 'Input/output UID, instance and pixel manifests differ'
            print(f'PASS manifest {mode}: {len(files)} files, {len({k[0] for k in actual})} unique SOP UIDs'+(f', dates {dates}' if mode=='multi' else ''),flush=True)
    if compare:
        print(f'PASS compare with {FORMER}: {len(compared)} scenarios; generated values normalised: batch UUID, working-folder suffix, output folder')
        for mode, count, size, digest in compared:
            print(f'  {mode}: {count} files, {size} bytes' + (f', sha256 {digest}' if count else ''))
print('PASS all scenarios: original bytes preserved; successful tags and pixels verified independently')

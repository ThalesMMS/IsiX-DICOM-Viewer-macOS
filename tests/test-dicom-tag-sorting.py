#!/usr/bin/env python3
"""Exercise production tag sorting, including duplicate values and pixel identity.

-sortSeriesByDICOMGroup:element: and -sortSeriesByValue:ascending: are Swift
since #832, in ViewerController+Export+PrintMovie.swift. Both are taken from
there as they stand, with the file's own fileprivate helpers (objcTry,
objcCompare, objcVolumeData, objcChangeImageData, objcAddMovieSerie...), and
compiled with swiftc as an extension of an Objective-C double of
ViewerController, beside the real AcquisitionTimeOrdering.swift and
HorosObjCException. The doubles keep the declarations of the application's
headers (DCMPix, DCMAttributeTag, DCMAttribute, DCMObject, HorosDCMTKObject,
DicomFile, DCMView and the ViewerController+SwiftIvars accessors), so the Swift
code is checked against the names it sees in the app. The cases and their
checks are the Objective-C driver the test always had.
"""
from pathlib import Path
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from sources import source_text

root = Path(__file__).resolve().parents[1]
s = source_text('ViewerController+Export+PrintMovie')
helpers = s[s.index('/// Runs `body` as an @try block'):s.index('public extension ViewerController {')]
a = s.index('    @objc(sortSeriesByValue:ascending:)')
method = s[a:s.index('    @objc(setPagesToPrint:)', a)]
header = r'''
// Only the declarations the sorts use, as the application's headers write them.
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
extern void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
@interface DCMAttributeTag:NSObject
+ (id)tagWithGroup:(int)group element:(int)element;
@end
@interface DCMAttribute:NSObject
@property(retain) NSMutableArray *values;
@end
@interface DCMObject:NSObject
@property(retain) DCMAttribute *attribute;
- (DCMAttribute *)attributeForTag:(DCMAttributeTag *)tag;
@end
// The reader the method uses since #738.
@interface HorosDCMTKObject:DCMObject
+ (nullable instancetype)objectWithContentsOfFile:(NSString *)path;
@end
@interface DicomFile:NSObject
+ (NSDictionary*) acquisitionTimingForFile: (NSString*) path;
@end
@interface DCMPix:NSObject <NSCopying>
@property(strong) NSString *srcFile;
@property(setter=setfImage:) float* fImage;
@property (nonatomic) long pwidth, pheight;
@end
@interface DCMView:NSObject
- (void) setIndex:(short) index;
- (void) sendSyncMessage:(short) inc;
@end
@interface ViewerController:NSObject {
@public
 short maxMovieIndex;
 NSMutableArray *pixList[2], *fileList[2];
 NSData *volumeData[2];
 DCMView *imageView;
 BOOL postprocessed;
}
@property(retain) NSMutableArray *results;
@property(retain, nullable) DCMView* horos_imageView;
@property(assign) short horos_maxMovieIndex;
@property(assign) BOOL horos_postprocessed;
- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index;
- (nullable NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index;
- (nullable NSObject*)horos_volumeDataAt:(NSInteger)index;
- (void) checkEverythingLoaded;
- (void) changeImageData:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v :(BOOL) applyTransition;
- (void) addMovieSerie:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v;
- (float) computeInterval;
- (void) setWindowTitle:(id) sender;
- (void) adjustSlider;
@end
'''
code = r'''
#import "Harness.h"
#define check(c) NSCAssert((c), @"failed: %s", #c)
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%s %@", pf, e); }
static NSDictionary *attributes;
@implementation DCMAttributeTag
+ (id)tagWithGroup:(int)group element:(int)element { return [[self new] autorelease]; }
@end
@implementation DCMAttribute
@end
@implementation DCMObject
- (DCMAttribute*)attributeForTag:(DCMAttributeTag *)tag {return self.attribute;}
@end
@implementation HorosDCMTKObject
+ (instancetype)objectWithContentsOfFile:(NSString*)path {
 HorosDCMTKObject *o=[self new];o.attribute=attributes[path];return [o autorelease];
}
@end
@implementation DicomFile
+ (NSDictionary*)acquisitionTimingForFile:(NSString*)path {
 NSArray *values=[(DCMAttribute*)attributes[path] values];
 return values.count ? @{@"AcquisitionDateTime":values[0]} : @{};
}
@end
@implementation DCMPix
- (id)init {if((self=[super init])){self.pwidth=1;self.pheight=1;}return self;}
- (id)copyWithZone:(NSZone*)zone {DCMPix *p=[DCMPix new];p.srcFile=self.srcFile;p.fImage=self.fImage;return p;}
@end
@implementation DCMView
- (void)setIndex:(short)index {}
- (void)sendSyncMessage:(short)value {}
@end
@implementation ViewerController
- (DCMView*)horos_imageView {return imageView;}
- (void)setHoros_imageView:(DCMView*)value {imageView=value;}
- (short)horos_maxMovieIndex {return maxMovieIndex;}
- (void)setHoros_maxMovieIndex:(short)value {maxMovieIndex=value;}
- (BOOL)horos_postprocessed {return postprocessed;}
- (void)setHoros_postprocessed:(BOOL)value {postprocessed=value;}
- (NSMutableArray*)horos_fileListAt:(NSInteger)index {return fileList[index];}
- (NSMutableArray*)horos_pixListAt:(NSInteger)index {return pixList[index];}
- (NSObject*)horos_volumeDataAt:(NSInteger)index {return volumeData[index];}
- (void)checkEverythingLoaded {}
- (void)changeImageData:(id)p :(id)f :(id)d :(BOOL)value {[self.results addObject:@[p,f,d]];}
- (void)addMovieSerie:(id)p :(id)f :(id)d {[self.results addObject:@[p,f,d]];}
- (float)computeInterval {return 0;}
- (void)setWindowTitle:(id)sender {}
- (void)adjustSlider {}
@end
// The Swift extension (ViewerController+Export+PrintMovie.swift).
@interface ViewerController (Export)
- (BOOL) sortSeriesByValue: (NSString*) key ascending: (BOOL) ascending;
- (BOOL) sortSeriesByDICOMGroup: (int) gr element: (int) el;
@end
static BOOL acquisition, descriptor;
static void runCase(NSArray *values, NSArray *expected) {
 ViewerController *v=[ViewerController new];v->maxMovieIndex=2;
 v->imageView=[DCMView new];v.results=[NSMutableArray array];
 NSMutableDictionary *map=[NSMutableDictionary dictionary];
 for(int phase=0;phase<2;phase++) {
  NSMutableData *data=[NSMutableData dataWithLength:values.count*sizeof(float)];
  v->volumeData[phase]=data;
  v->pixList[phase]=[NSMutableArray array];v->fileList[phase]=[NSMutableArray array];
  for(NSUInteger i=0;i<values.count;i++) {
   NSString *path=[NSString stringWithFormat:@"%d-%lu",phase,(unsigned long)i];
   DCMAttribute *attr=[DCMAttribute new];attr.values=values[i];map[path]=attr;
   DCMPix *p=[DCMPix new];p.srcFile=path;p.fImage=(float*)data.mutableBytes+i;
   *p.fImage=phase*100+i;
   [v->pixList[phase] addObject:p];[v->fileList[phase] addObject:path];
  }
 }
 attributes=map;
 check(descriptor ? [v sortSeriesByValue:@"self" ascending:NO] : acquisition ? [v sortSeriesByValue:nil ascending:YES] : [v sortSeriesByDICOMGroup:8 element:0x32]);
 check(v.results.count==2);check(v->postprocessed);
 for(int phase=0;phase<2;phase++) {
  NSArray *r=v.results[phase];NSArray *pixels=r[0],*files=r[1];NSData *data=r[2];
  check(files.count==expected.count);
  check([NSSet setWithArray:files].count==files.count);
  for(NSUInteger i=0;i<expected.count;i++) {
   NSInteger old=[expected[i] integerValue];
   check(([files[i] isEqual:[NSString stringWithFormat:@"%d-%ld",phase,(long)old]]));
   check(((const float*)data.bytes)[i]==phase*100+old);
   check(*[(DCMPix*)pixels[i] fImage]==phase*100+old);
  }
 }
}
int main(void) {@autoreleasepool {
 // Equal numeric values may share the same NSNumber object (tagged pointers).
 runCase(@[@[@"3"],@[@"1"],@[@"1"],@[@"2"]],@[@1,@2,@3,@0]);
 runCase(@[@[@"B"],@[@"A"],@[@"A"],@[@"C"]],@[@1,@2,@0,@3]);
 // Empty value arrays must follow the existing missing-value policy (numeric zero).
 runCase(@[@[@"2"],@[],@[@"0"],@[]],@[@1,@2,@3,@0]);
 acquisition=YES;
 runCase(@[@[@"20260907120000.000002"],@[@"20260907120000.000001"],@[@"20260907120000.000001"],@[]],@[@1,@2,@0,@3]);
 descriptor=YES;
 runCase(@[@[@"3"],@[@"1"],@[@"1"],@[@"2"]],@[@3,@2,@1,@0]);
 NSLog(@"PASS: descriptor and acquisition pipeline; duplicate numeric/string keys, stable ties, empty values, two phases, unique files and pixel buffers");
}}
'''
# On the main actor, as the real extension of the window controller (#961).
# The helpers before the extension include the print grid restoration, an AppKit function.
extension = 'import AppKit\n\n' + helpers + '@MainActor extension ViewerController {\n' + method + '}\n'
with tempfile.TemporaryDirectory(prefix='horos-tag-sort-') as directory:
    p = Path(directory)
    (p/'Harness.h').write_text(header)
    (p/'test.m').write_text(code)
    (p/'Sort.swift').write_text(extension, encoding='utf-8')
    include = ['-I', str(p), '-I', str(root/'Horos/Sources')]
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fblocks', *include, str(p/'test.m'), '-o', str(p/'test.o')], check=True, timeout=60)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', *include, str(root/'Horos/Sources/HorosObjCException.m'), '-o', str(p/'HorosObjCException.o')], check=True, timeout=60)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *include, '-import-objc-header', str(p/'Harness.h'),
                    str(root/'Horos/Sources/AcquisitionTimeOrdering.swift'), str(p/'Sort.swift'),
                    str(p/'test.o'), str(p/'HorosObjCException.o'), '-o', str(p/'test')], check=True, timeout=120)
    subprocess.run([str(p/'test')], check=True, timeout=30)

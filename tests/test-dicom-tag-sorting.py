#!/usr/bin/env python3
"""Exercise production tag sorting, including duplicate values and pixel identity.

-sortSeriesByDICOMGroup:element: and -sortSeriesByValue:ascending: are Swift,
in ViewerController+Export+PrintMovie.swift. Both are taken from there as they
stand, with the file's own fileprivate helpers (viewerSortCompare,
viewerSortValue, viewerSortedPositions, ViewerSortedFrame, ViewerSortFusions) and the bridge that
hands the sorted volume to -changeImageData:::: and -addMovieSerie::: as the
NSData object itself (ViewerController+ImagePipelineSupport.swift), and
compiled with swiftc as an extension of an Objective-C double of
ViewerController, beside the real AcquisitionTimeOrdering.swift. The doubles
keep the declarations of the application's headers (DCMPix, DCMAttributeTag,
DCMAttribute, DCMObject, HorosDCMTKObject, DicomFile, DCMView and the
ViewerController+SwiftIvars accessors), so the Swift code is checked against
the names it sees in the app. The cases and their checks are the Objective-C
driver the test always had.

After the new order is in, the series opens on the first image of the order
displayed (-setImageIndex: 0, after -computeInterval, which may flip the
display), and the fusions the change of data ended are made again: the
viewer's own, and that of a viewer which shows it over its images, each with
its overlay and its mode.
"""
from pathlib import Path
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from sources import source_text

root = Path(__file__).resolve().parents[1]
s = source_text('ViewerController+Export+PrintMovie')
helpers = s[s.index('/// `[a compare: b]` of two values'):s.index('public extension ViewerController {')]
a = s.index('    /// Sorts every movie frame of the series by a key')
method = s[a:s.index('    // MARK: Printing', a)]
pipeline = source_text('ViewerController+ImagePipelineSupport')
b = pipeline.index('/// `[viewer changeImageData: f :d :v :b]`')
bridge = pipeline[b:pipeline.index('\nextension ViewerController {', b)] + '\n'
header = r'''
// Only the declarations the sorts use, as the application's headers write them.
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Foundation/Foundation.h>
extern void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
// IsiXDICOMFile's tag, which the sort names as DICOMAttributeTag.
@interface DCMAttributeTag:NSObject
+ (instancetype)tagWithGroup:(int)group element:(int)element NS_SWIFT_NAME(tag(withGroup:element:));
@property(readonly) NSString *stringValue;
@end
@interface DCMAttribute:NSObject
@property(retain) NSMutableArray *values;
@end
@interface DCMObject:NSObject
@property(retain) DCMAttribute *attribute;
@property(readonly) NSMutableDictionary *attributes;
- (DCMAttribute *)attributeForTag:(DCMAttributeTag *)tag;
@end
// The reader the method uses, which +[DCMObject objectWithContentsOfFile:] forwards to.
@interface HorosDCMTKObject:DCMObject
+ (nullable instancetype)objectWithContentsOfFile:(NSString *)path;
@end
// The IsiXDICOMDataset model's factory, under the Swift name it has there.
@interface DCMObject (Reading)
+ (nullable instancetype)objectWithContentsOfFile:(NSString *)path NS_SWIFT_NAME(object(contentsOfFile:));
@end
@interface DicomFile:NSObject
+ (NSDictionary*) acquisitionTimingForFile: (NSString*) path;
@end
@interface DCMPix:NSObject <NSCopying>
@property(strong) NSString *srcFile;
@property(setter=setfImage:) float* fImage;
@property (nonatomic) long pwidth, pheight;
@end
@class ViewerController;
@interface DCMView:NSObject
- (void) setIndex:(NSInteger) index;
- (void) sendSyncMessage:(NSInteger) inc;
@property NSInteger blendingMode;
@end
@interface SeriesView:NSObject
@property int mode;
- (void) setBlendingMode:(int) value;
@end
@interface PopUpButton:NSObject
@property NSInteger tag;
- (void) selectItemWithTag:(NSInteger) tag;
@end
@interface ViewerRegistry:NSObject
@property(retain, nullable) NSArray<ViewerController*> *viewers;
@end
@interface ViewerSessionGraph:NSObject
@property(retain) ViewerRegistry *registry;
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
@property(retain) NSMutableArray *calls;
@property(assign, nullable) ViewerController *horos_blending;
@property(retain, nullable) SeriesView *horos_seriesView;
@property(retain, nullable) PopUpButton *horos_blendingPopupMenu;
@property(retain) ViewerSessionGraph *sessionGraph;
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
- (void) setImageIndex:(NSInteger) i;
- (void) ActivateBlending:(nullable ViewerController*) viewer NS_SWIFT_NAME(activateBlending(_:));
@end
'''
code = r'''
#import "Harness.h"
#define check(c) NSCAssert((c), @"failed: %s", #c)
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%s %@", pf, e); }
static NSDictionary *attributes;
@implementation DCMAttributeTag
+ (instancetype)tagWithGroup:(int)group element:(int)element { return [[self new] autorelease]; }
- (NSString *)stringValue { return @"TAG"; }
@end
@implementation DCMAttribute
@end
@implementation DCMObject
- (DCMAttribute*)attributeForTag:(DCMAttributeTag *)tag {return self.attribute;}
// Every tag of the case reads the one attribute, by its key.
- (NSMutableDictionary *)attributes {
 return self.attribute ? [NSMutableDictionary dictionaryWithObject:self.attribute forKey:@"TAG"] : [NSMutableDictionary dictionary];
}
@end
@implementation DCMObject (Reading)
+ (instancetype)objectWithContentsOfFile:(NSString*)path { return [HorosDCMTKObject objectWithContentsOfFile:path]; }
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
static NSMutableArray *calls;
@implementation DCMView
- (void)setIndex:(NSInteger)index {[calls addObject:@"setIndex"];}
- (void)sendSyncMessage:(NSInteger) value {}
@end
@implementation SeriesView
- (void)setBlendingMode:(int)value {self.mode=value;}
@end
@implementation PopUpButton
- (void)selectItemWithTag:(NSInteger)tag {self.tag=tag;}
@end
@implementation ViewerRegistry
@end
@implementation ViewerSessionGraph
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
// As the viewer: the change of data ends this viewer's fusion, and its close
// notification the fusion of every viewer that shows this one.
- (void)changeImageData:(id)p :(id)f :(id)d :(BOOL)value {
 [self.results addObject:@[p,f,d]];
 [self ActivateBlending:nil];
 for(ViewerController *other in self.sessionGraph.registry.viewers) if(other.horos_blending==self) [other ActivateBlending:nil];
}
- (void)addMovieSerie:(id)p :(id)f :(id)d {[self.results addObject:@[p,f,d]];}
- (float)computeInterval {[calls addObject:@"computeInterval"];return 0;}
- (void)setImageIndex:(NSInteger)i {[calls addObject:[NSString stringWithFormat:@"setImageIndex:%ld",(long)i]];}
// The activation takes its mode from the preferences (0 here).
- (void)ActivateBlending:(ViewerController*)viewer {
 self.horos_blending=viewer;
 if(viewer){self.horos_imageView.blendingMode=0;[calls addObject:@"ActivateBlending"];}
}
- (void)setWindowTitle:(id)sender {}
- (void)adjustSlider {}
@end
// The Swift extension (ViewerController+Export+PrintMovie.swift).
@interface ViewerController (Export)
- (BOOL) sortSeriesByValue: (NSString*) key ascending: (BOOL) ascending;
- (BOOL) sortSeriesByDICOMGroup: (int) gr element: (int) el;
@end
static BOOL acquisition, descriptor, fused;
static ViewerController *viewerDouble(ViewerRegistry *registry, NSInteger mode) {
 ViewerController *v=[ViewerController new];v->imageView=[DCMView new];v->imageView.blendingMode=mode;
 v.horos_seriesView=[SeriesView new];v.horos_blendingPopupMenu=[PopUpButton new];
 v.sessionGraph=[ViewerSessionGraph new];v.sessionGraph.registry=registry;
 return v;
}
static void runCase(NSArray *values, NSArray *expected) {
 // When fused, the sorted viewer shows `overlay` in mode 3, and `owner` shows the sorted viewer in mode 2.
 ViewerRegistry *registry=[ViewerRegistry new];
 ViewerController *v=viewerDouble(registry,3),*overlay=viewerDouble(registry,0),*owner=viewerDouble(registry,2);
 registry.viewers=@[owner,v,overlay];
 if(fused){v.horos_blending=overlay;owner.horos_blending=v;}
 calls=[NSMutableArray array];
 v->maxMovieIndex=2;v.results=[NSMutableArray array];
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
 // The first image of the displayed order, once -computeInterval has run; the fusions made again before it.
 check([calls.lastObject isEqual:@"setImageIndex:0"]);
 check(![calls containsObject:@"setIndex"]);
 check([calls indexOfObject:@"computeInterval"]<[calls indexOfObject:@"setImageIndex:0"]);
 if(fused) {
  check([calls filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'ActivateBlending'"]].count==2);
  check(v.horos_blending==overlay);check(v->imageView.blendingMode==3);check(v.horos_seriesView.mode==3);check(v.horos_blendingPopupMenu.tag==3);
  check(owner.horos_blending==v);check(owner->imageView.blendingMode==2);check(owner.horos_seriesView.mode==2);check(owner.horos_blendingPopupMenu.tag==2);
  check(overlay.horos_blending==nil);
 } else {
  check(![calls containsObject:@"ActivateBlending"]);
  check(v.horos_blending==nil);check(owner.horos_blending==nil);
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
 fused=YES;
 runCase(@[@[@"3"],@[@"1"],@[@"1"],@[@"2"]],@[@3,@2,@1,@0]);
 descriptor=NO;acquisition=NO;
 runCase(@[@[@"3"],@[@"1"],@[@"1"],@[@"2"]],@[@1,@2,@3,@0]);
 NSLog(@"PASS: descriptor and acquisition pipeline; duplicate numeric/string keys, stable ties, empty values, two phases, unique files and pixel buffers; first displayed image; fusions kept");
}}
'''
# On the main actor, as the real extension of the window controller.
extension = 'import AppKit\n\ntypealias DICOMAttributeTag = DCMAttributeTag\n\n' + helpers + bridge + '@MainActor extension ViewerController {\n' + method + '}\n'
with tempfile.TemporaryDirectory(prefix='horos-tag-sort-') as directory:
    p = Path(directory)
    (p/'Harness.h').write_text(header)
    (p/'test.m').write_text(code)
    (p/'Sort.swift').write_text(extension, encoding='utf-8')
    include = ['-I', str(p), '-I', str(root/'Horos/Sources')]
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fblocks', *include, str(p/'test.m'), '-o', str(p/'test.o')], check=True, timeout=60)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *include, '-import-objc-header', str(p/'Harness.h'),
                    str(root/'Horos/Sources/AcquisitionTimeOrdering.swift'), str(p/'Sort.swift'),
                    str(p/'test.o'), '-o', str(p/'test')], check=True, timeout=120)
    subprocess.run([str(p/'test')], check=True, timeout=30)

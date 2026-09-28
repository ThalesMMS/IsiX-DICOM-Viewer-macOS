#!/usr/bin/env python3
"""Run the actual viewer facade and Swift registry with lightweight host stubs.

No window, app build, pixels or database are needed. An optional source path
lets the regression run against the previous ViewerVolumeSession.m revision.
The facade is Swift since #722 (ViewerVolumeSession.swift, an extension of
the Objective-C ViewerController): it is compiled into the same library as the
registry, against host stubs declared the way the app headers declare them.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root/'tests'))
from sources import source_path  # noqa: E402
source = Path(sys.argv[1]) if len(sys.argv) > 1 else source_path('ViewerVolumeSession')
headers = r'''
#import <Foundation/Foundation.h>
@interface DicomStudy : NSObject
@property(copy) NSString *studyInstanceUID;
@end
@interface DicomSeries : NSObject
@property(strong) DicomStudy *study;
@property(copy) NSString *seriesInstanceUID;
@property(copy) NSString *seriesDICOMUID;
@end
@interface DicomImage : NSObject
@property(strong) DicomSeries *series;
@end
@interface DCMPix : NSObject
@property(copy) NSString *frameofReferenceUID;
@end
@interface DCMView : NSObject
@property(strong) DCMPix *curDCM;
@end
@interface ViewerController : NSObject
@property(strong) DicomImage *currentImage;
@property(strong) DCMView *imageView;
@property(strong) NSMutableArray *pixList;
@property NSInteger curMovieIndex;
@property BOOL windowWillClose;
@end
extern NSString * const OsirixCloseViewerNotification;
extern NSString * const OsirixViewerWillChangeNotification;
extern NSString * const OsirixViewerDidChangeNotification;
extern NSString * const OsirixUpdateVolumeDataNotification;
'''
# The facade in Swift reads the host through the app's declarations: methods on
# ViewerController and a read-only curDCM. The driver sets them through setters.
swift_headers = r'''
#import <Foundation/Foundation.h>
@interface DicomStudy : NSObject
@property(nonatomic, retain) NSString* studyInstanceUID;
@end
@interface DicomSeries : NSObject
@property(nonatomic, retain) DicomStudy* study;
@property(nonatomic, retain) NSString* seriesInstanceUID;
@property(nonatomic, retain) NSString* seriesDICOMUID;
@end
@interface DicomImage : NSObject
@property(nonatomic, retain) DicomSeries* series;
@end
@interface DCMPix : NSObject
@property(retain) NSString *frameofReferenceUID;
@end
@interface DCMView : NSObject
@property(readonly, strong) DCMPix *curDCM;
- (void)setCurDCM:(DCMPix *)pix;
@end
@interface ViewerController : NSObject
- (DicomImage *)currentImage;
- (DCMView*) imageView;
- (NSMutableArray*) pixList;
- (short) curMovieIndex;
- (BOOL) windowWillClose;
- (void)setCurrentImage:(DicomImage *)image;
- (void)setImageView:(DCMView *)view;
- (void)setPixList:(NSMutableArray *)pixList;
- (void)setCurMovieIndex:(NSInteger)index;
- (void)setWindowWillClose:(BOOL)flag;
@end
extern NSString * const OsirixCloseViewerNotification;
extern NSString * const OsirixViewerWillChangeNotification;
extern NSString * const OsirixViewerDidChangeNotification;
extern NSString * const OsirixUpdateVolumeDataNotification;
'''
swift_stubs = r'''
#import "Host.h"
@implementation DicomStudy @end
@implementation DicomSeries @end
@implementation DicomImage @end
@implementation DCMPix @end
@implementation DCMView { DCMPix *_pix; }
- (DCMPix *)curDCM { return _pix; }
- (void)setCurDCM:(DCMPix *)pix { _pix = pix; }
@end
@implementation ViewerController { DicomImage *_image; DCMView *_view; NSMutableArray *_pixList; NSInteger _movie; BOOL _closing; }
- (DicomImage *)currentImage { return _image; }
- (DCMView*) imageView { return _view; }
- (NSMutableArray*) pixList { return _pixList; }
- (short) curMovieIndex { return (short)_movie; }
- (BOOL) windowWillClose { return _closing; }
- (void)setCurrentImage:(DicomImage *)image { _image = image; }
- (void)setImageView:(DCMView *)view { _view = view; }
- (void)setPixList:(NSMutableArray *)pixList { _pixList = pixList; }
- (void)setCurMovieIndex:(NSInteger)index { _movie = index; }
- (void)setWindowWillClose:(BOOL)flag { _closing = flag; }
@end
NSString * const OsirixCloseViewerNotification = @"CloseViewerNotification";
NSString * const OsirixViewerWillChangeNotification = @"ViewerWillChangeNotification";
NSString * const OsirixViewerDidChangeNotification = @"ViewerDidChangeNotification";
NSString * const OsirixUpdateVolumeDataNotification = @"UpdateVolumeDataNotification";
'''
driver = r'''
#import "ViewerVolumeSession.h"
#import "Horos-Swift.h"
#include <assert.h>
STUBS
int main(void) { @autoreleasepool {
    ViewerController *viewer = [ViewerController new];
    viewer.currentImage = [DicomImage new];
    viewer.currentImage.series = [DicomSeries new];
    viewer.currentImage.series.seriesInstanceUID = @"00000001 1.2.3";
    viewer.currentImage.series.seriesDICOMUID = @"1.2.3";
    viewer.currentImage.series.study = [DicomStudy new];
    viewer.currentImage.series.study.studyInstanceUID = @"1.2";
    viewer.imageView = [DCMView new]; viewer.imageView.curDCM = [DCMPix new];
    viewer.imageView.curDCM.frameofReferenceUID = @"1.4";
    viewer.pixList = [NSMutableArray arrayWithObject:viewer.imageView.curDCM];
    HorosVolumeSessionRegistry *registry = HorosVolumeSessionRegistry.shared;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    HorosVolumeSession *first = viewer.horosVolumeSession;
    assert(first && first.isOpen && !first.isStale && first.identity.generation == 0);
    assert([first.identity.seriesInstanceUID isEqual:@"1.2.3"]);
    assert(viewer.horosVolumeSession == first);
    HorosPatientCrosshairController *crosshair = HorosPatientCrosshairController.shared;
    assert([crosshair publishX:1 y:2 z:3 session:first owner:viewer]);
    HorosVolumeLoadToken *old = [registry makeLoadTokenFor:first];
    [nc postNotificationName:OsirixUpdateVolumeDataNotification object:[NSMutableArray array]];
    assert(!first.isStale && !old.isCancelled && crosshair.currentPoint != nil);
    [nc postNotificationName:OsirixUpdateVolumeDataNotification object:viewer.pixList];
    assert(first.isStale && first.identity.generation == 1 && old.isCancelled && ![old deliver]);
    assert(crosshair.currentPoint == nil && crosshair.sourceOwner == nil);
    HorosVolumeSession *second = viewer.horosVolumeSession;
    assert(second != first && !first.isOpen && second.isOpen && !second.isStale);
    assert(second.identity.generation == 1 && [second.owner isEqual:first.owner]);
    assert([registry makeLoadTokenFor:first] == nil);
    assert(viewer.horosVolumeSession == second && registry.openSessionCount == 1);
    HorosVolumeLoadToken *current = [registry makeLoadTokenFor:second];
    assert(current.identity.generation == 1 && [current deliver]);
    HorosVolumeLoadToken *pending = [registry makeLoadTokenFor:second];
    [nc postNotificationName:OsirixUpdateVolumeDataNotification object:viewer.pixList];
    [nc postNotificationName:OsirixUpdateVolumeDataNotification object:viewer.pixList];
    HorosVolumeSession *third = viewer.horosVolumeSession;
    assert(third != second && !second.isOpen && !third.isStale && third.identity.generation == 3);
    assert(![pending deliver] && ![old deliver]);
    // Time-point switches still retire the previous volume instead of carrying its generation.
    viewer.curMovieIndex = 1;
    HorosVolumeSession *fourth = viewer.horosVolumeSession;
    assert(!third.isOpen && fourth.identity.timeIndex == 1 && fourth.identity.generation == 0);
    assert([crosshair publishX:4 y:5 z:6 session:fourth owner:viewer]);
    HorosVolumeLoadToken *closing = [registry makeLoadTokenFor:fourth];
    [nc postNotificationName:OsirixCloseViewerNotification object:viewer];
    assert(!fourth.isOpen && ![closing deliver] && registry.openSessionCount == 0);
    assert(crosshair.currentPoint == nil && crosshair.sourceOwner == nil);
    viewer.windowWillClose = YES;
    assert(viewer.horosVolumeSession == nil && registry.openSessionCount == 0);
    // A retained plugin may query during replacement, before the old catalog
    // objects are removed. It must not recreate a session for those old pixels.
    viewer.windowWillClose = NO;
    HorosVolumeSession *beforeChange = viewer.horosVolumeSession;
    HorosVolumeLoadToken *changing = [registry makeLoadTokenFor:beforeChange];
    [nc postNotificationName:OsirixViewerWillChangeNotification object:viewer];
    assert(!beforeChange.isOpen && changing.isCancelled);
    assert(viewer.horosVolumeSession == nil && registry.openSessionCount == 0);
    [nc postNotificationName:OsirixCloseViewerNotification object:viewer userInfo:@{@"newStudyID":@"next"}];
    assert(viewer.horosVolumeSession == nil && registry.openSessionCount == 0);
    viewer.currentImage.series.seriesInstanceUID = @"00000002 1.2.4";
    viewer.currentImage.series.seriesDICOMUID = @"1.2.4";
    [nc postNotificationName:OsirixViewerDidChangeNotification object:viewer];
    HorosVolumeSession *afterChange = viewer.horosVolumeSession;
    assert(afterChange.isOpen && [afterChange.owner isEqual:beforeChange.owner]);
    assert([afterChange.identity.seriesInstanceUID isEqual:@"1.2.4"]);
    viewer.windowWillClose = YES;
    [nc postNotificationName:OsirixCloseViewerNotification object:viewer];
    assert(viewer.horosVolumeSession == nil && registry.openSessionCount == 0);
    puts("PASS: real viewer facade renews stale generations, rejects old loads and preserves owner/close semantics");
} return 0; }
'''
stubs = """@implementation DicomStudy @end
@implementation DicomSeries @end
@implementation DicomImage @end
@implementation DCMPix @end
@implementation DCMView @end
@implementation ViewerController @end
NSString * const OsirixCloseViewerNotification = @"CloseViewerNotification";
NSString * const OsirixViewerWillChangeNotification = @"ViewerWillChangeNotification";
NSString * const OsirixViewerDidChangeNotification = @"ViewerDidChangeNotification";
NSString * const OsirixUpdateVolumeDataNotification = @"UpdateVolumeDataNotification";"""
registry = [str(root/'Horos/Sources/VolumeSession.swift'),
            str(root/'Horos/Sources/ViewerReferenceLines.swift'),
            str(root/'Horos/Sources/PatientCrosshairController.swift')]
with tempfile.TemporaryDirectory(prefix='horos-viewer-volume-session-') as temporary:
    work = Path(temporary)
    for name in ['ViewerController.h', 'DicomImage.h', 'DicomSeries.h', 'DicomStudy.h', 'DCMPix.h', 'Notifications.h']:
        (work/name).write_text('#import "Host.h"\n')
    if source.suffix == '.swift':
        (work/'ViewerVolumeSession.h').write_bytes((root/'Horos/Sources/ViewerVolumeSession.h').read_bytes())
        # The Swift facade extends the stub ViewerController: the stubs are
        # Objective-C in the library, which Swift sees through Host.h.
        (work/'Host.h').write_text('#pragma once\n'+swift_headers)
        (work/'Stubs.m').write_text(swift_stubs)
        (work/'Check.m').write_text(driver.replace('STUBS', ''))
        subprocess.run(['xcrun','clang','-fobjc-arc','-c',str(work/'Stubs.m'),'-o',str(work/'stubs.o')],check=True)
        subprocess.run(['xcrun','swiftc','-emit-library','-module-name','Horos',
                        '-import-objc-header',str(work/'Host.h'),
                        '-emit-objc-header-path',str(work/'Horos-Swift.h'),
                        *registry,str(source),str(work/'stubs.o'),'-o',str(work/'libHoros.dylib')],check=True,cwd=work)
        subprocess.run(['xcrun','clang','-fobjc-arc',str(work/'Check.m'),
                        '-framework','Foundation','-L'+str(work),'-lHoros','-o',str(work/'check')],check=True)
    else:
        # A former Objective-C revision of the facade, as before #722, with its
        # own header: the one beside it, or the last one that declared the category.
        header = source.with_suffix('.h')
        (work/'ViewerVolumeSession.h').write_bytes(header.read_bytes() if header.is_file() else subprocess.run(
            ['git','-C',str(root),'show','2c2a1c16d:Horos/Sources/ViewerVolumeSession.h'],
            check=True,capture_output=True).stdout)
        (work/'Host.h').write_text('#pragma once\n'+headers)
        (work/'ViewerVolumeSession.m').write_bytes(source.read_bytes())
        (work/'Check.m').write_text(driver.replace('STUBS', stubs))
        subprocess.run(['xcrun','swiftc','-emit-library','-module-name','Horos',
                        '-emit-objc-header-path',str(work/'Horos-Swift.h'),
                        *registry,'-o',str(work/'libHoros.dylib')],check=True)
        subprocess.run(['xcrun','clang','-fno-objc-arc','-c',str(work/'ViewerVolumeSession.m'),
                        '-o',str(work/'facade.o')],check=True)
        subprocess.run(['xcrun','clang','-fobjc-arc',str(work/'Check.m'),str(work/'facade.o'),
                        '-framework','Foundation','-L'+str(work),'-lHoros','-o',str(work/'check')],check=True)
    subprocess.run([str(work/'check')],check=True,cwd=work)

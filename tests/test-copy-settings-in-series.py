#!/usr/bin/env python3
"""Turning propagation off must not flatten the series it is meant to un-flatten.

-writeCopySettingsInSeriesForPixels: is Swift (DCMView+SeriesSettings.swift),
with what it writes to each image decided by IsiXImaging's
SeriesSettingsPropagation and written by ImagePresentationStore. Both are
compiled as they are, with xcrun swiftc, the method as an extension of an
Objective-C double of DCMView that has the same horos_* properties (the
view's ViewportState is made from them), beside the real HorosObjCException;
the images and pixels are doubles too, the images with the typed attributes of
DicomImage, the pixels with DCMPix's own -storedWindowLevelForCalibratedLevel:.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text, class_text  # noqa: E402
import harness_defaults  # noqa: E402  the harness's preferences stay in its own process
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
settings = source_text('DCMView+SeriesSettings')
start = settings.index('    @objc(writeCopySettingsInSeriesForPixels:)')
method = settings[start:settings.index('    /// The toolbar\'s switch', start)]
# The view's viewport, as DCMView.swift keeps it, from the double's horos_* properties.
VIEWPORT = """
    var viewport: ViewportState {
        ViewportState(scale: horos_scaleValue, origin: horos_origin, rotation: horos_rotation, xFlipped: horos_xFlipped,
                      yFlipped: horos_yFlipped)
    }
"""
extension = 'import Cocoa\nimport IsiXImaging\n\n@MainActor extension DCMView {\n' + VIEWPORT + method + '}\n'
store = root / 'Horos/Sources/ImagePresentationStore.swift'

pix_source = class_text('DCMPix')
if '- (float) storedWindowLevelForCalibratedLevel:' in pix_source:
    a = pix_source.index('- (float) storedWindowLevelForCalibratedLevel:')
    storage_methods = pix_source[a:pix_source.index('- (void) compute8bitRepresentation', a)]
else:
    # The adapters are in DCMPix+Display.swift: both load the image and turn the
    # sign of the level for a MONOCHROME1 image. The program has them in
    # Objective-C, as long as the Swift says that.
    swift = (root / 'Horos/Sources/DCMPix+Display.swift').read_text()
    for selector, name in (('storedWindowLevelForCalibratedLevel:', 'storedWindowLevel(forCalibratedLevel level: Float)'),
                           ('calibratedWindowLevelForStoredLevel:', 'calibratedWindowLevel(forStoredLevel level: Float)')):
        body = swift[swift.index(f'@objc({selector})'):]
        body = body[:body.index('\n    }\n')]
        if name not in body or 'checkLoad()\n        return displayInverted ? -level : level' not in body:
            print(f'FAIL: -[DCMPix {selector}] no longer turns the level for an inverted image')
            sys.exit(1)
    storage_methods = '''- (float) storedWindowLevelForCalibratedLevel:(float) level { [self CheckLoad]; return self.displayInverted ? -level : level; }
- (float) calibratedWindowLevelForStoredLevel:(float) level { [self CheckLoad]; return self.displayInverted ? -level : level; }
'''

bridge = r'''
#import <AppKit/AppKit.h>
#import "HorosObjCException.h"

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf);

// The presentation state of one image, as DicomImage's attributes. A nil value
// means the image has none of its own and falls back to what the file says.
@interface DicomImage : NSObject
@property(retain) NSNumber *windowWidth, *windowLevel, *scale, *rotationAngle, *yFlipped, *xFlipped, *xOffset, *yOffset;
@end

// The series' attributes ImagePresentationStore reads and writes.
@interface DicomSeries : NSObject
@property(retain) NSNumber *windowWidth, *windowLevel, *scale, *displayStyle, *rotationAngle, *yFlipped, *xFlipped, *xOffset, *yOffset;
@end

@interface DCMPix : NSObject
- (DicomImage *) imageObj;
- (BOOL) isLoaded;
- (void) changeWLWW:(float)wl :(float)ww;
- (float) storedWindowLevelForCalibratedLevel:(float) level;
- (float) calibratedWindowLevelForStoredLevel:(float) level;
@property BOOL displayInverted;
@property float appliedWL, appliedWW;
@property BOOL windowChanged;
@property BOOL loaded;
@property(retain) DicomImage *image;
@end

// The state DCMView+SeriesSettings.swift reads, under the view's names.
@interface DCMView : NSObject
// The window the view answers through curWL and curWW, which it keeps in a Swift value.
@property float curWL, curWW, horos_scaleValue, horos_rotation;
@property BOOL horos_yFlipped, horos_xFlipped, horos_COPYSETTINGSINSERIES;
@property NSPoint horos_origin;
@property BOOL scaledFit;
@property(retain) DicomImage *shownImage;
- (DicomImage *) imageObj;
- (BOOL) isScaledFit;
@end
'''

program = r'''
#import "bridge.h"
#import "Horos-Swift.h"

@implementation DicomImage
@end

@implementation DicomSeries
@end

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"Exception: %@", e); }

// Whether the image keeps nothing of its own.
static BOOL keepsNothing(DicomImage *im) {
    for (NSString *key in @[@"windowWidth", @"windowLevel", @"scale", @"rotationAngle", @"yFlipped", @"xFlipped", @"xOffset", @"yOffset"])
        if ([im valueForKey:key]) return NO;
    return YES;
}

@implementation DCMPix
- (DicomImage *) imageObj { return self.image; }
- (BOOL) isLoaded { return self.loaded; }
- (void) CheckLoad {}
STORAGE_METHODS
- (void) changeWLWW:(float)wl :(float)ww {
    self.appliedWL = wl; self.appliedWW = ww; self.windowChanged = YES;
}
@end

@implementation DCMView
- (DicomImage *) imageObj { return self.shownImage; }
- (BOOL) isScaledFit { return self.scaledFit; }
@end

#define check(...) do{ if(!(__VA_ARGS__)){ NSLog(@"FAIL: %s", #__VA_ARGS__); return 1; } }while(0)

static DCMPix *pixel(void) {
    DCMPix *pix = [DCMPix new];
    pix.image = [DicomImage new];
    pix.loaded = YES;
    return pix;
}

int main(void) { @autoreleasepool {
    DCMView *view = [DCMView new];
    view.curWL = 1234; view.curWW = 88;
    view.horos_scaleValue = 2.5; view.horos_rotation = 90;
    view.horos_yFlipped = YES; view.horos_xFlipped = NO;
    view.horos_origin = NSMakePoint(3, 4);
    view.scaledFit = NO;

    NSArray *pixels = @[ pixel(), pixel(), pixel() ];
    view.shownImage = [(DCMPix*)pixels[1] imageObj];   // the image on screen

    // Off: only the image on screen records the window on screen. Every other
    // image keeps the window it had, which for an untouched image is nothing,
    // so it falls back to its own window from the file. This is the whole
    // point of the option, and it used to write the current window onto all
    // of them. Zoom, pan, rotation and flips have nothing of their own in the
    // file: an untouched image takes the ones on screen, or every image the
    // user had not zoomed jumped back to the fitted view.
    view.horos_COPYSETTINGSINSERIES = NO;
    [view writeCopySettingsInSeriesForPixels: pixels];

    DicomImage *shown = [(DCMPix*)pixels[1] imageObj];
    check([[shown valueForKey:@"windowWidth"] floatValue] == 88);
    check([[shown valueForKey:@"windowLevel"] floatValue] == 1234);
    check([[shown valueForKey:@"scale"] floatValue] == 2.5);
    check([[shown valueForKey:@"rotationAngle"] floatValue] == 90);
    check([[shown valueForKey:@"yFlipped"] boolValue] == YES);
    // This took its value from yFlipped, so turning propagation off flipped a
    // vertically flipped series horizontally.
    check([[shown valueForKey:@"xFlipped"] boolValue] == NO);
    check([[shown valueForKey:@"xOffset"] floatValue] == 3);
    check([[shown valueForKey:@"yOffset"] floatValue] == 4);

    for (DCMPix *pix in @[ pixels[0], pixels[2] ]) {
        DicomImage *im = [pix imageObj];
        check([im valueForKey:@"windowWidth"] == nil);
        check([im valueForKey:@"windowLevel"] == nil);
        check(pix.windowChanged == NO);
        check([[im valueForKey:@"scale"] floatValue] == 2.5);
        check([[im valueForKey:@"rotationAngle"] floatValue] == 90);
        check([[im valueForKey:@"yFlipped"] boolValue] == YES);
        check([[im valueForKey:@"xFlipped"] boolValue] == NO);
        check([[im valueForKey:@"xOffset"] floatValue] == 3);
        check([[im valueForKey:@"yOffset"] floatValue] == 4);
    }

    // A window or a zoom the user set on another image is not touched either.
    DicomImage *other = [(DCMPix*)pixels[0] imageObj];
    [other setValue:[NSNumber numberWithFloat:200] forKey:@"windowWidth"];
    [other setValue:[NSNumber numberWithFloat:300] forKey:@"windowLevel"];
    [other setValue:[NSNumber numberWithFloat:7] forKey:@"scale"];
    [other setValue:[NSNumber numberWithFloat:-5] forKey:@"xOffset"];
    [other setValue:[NSNumber numberWithFloat:6] forKey:@"yOffset"];
    view.horos_scaleValue = 3; view.horos_origin = NSMakePoint(8, 9);
    [view writeCopySettingsInSeriesForPixels: pixels];
    check([[other valueForKey:@"windowWidth"] floatValue] == 200);
    check([[other valueForKey:@"windowLevel"] floatValue] == 300);
    check([[other valueForKey:@"scale"] floatValue] == 7);
    check([[other valueForKey:@"xOffset"] floatValue] == -5);
    check([[other valueForKey:@"yOffset"] floatValue] == 6);
    check([[shown valueForKey:@"scale"] floatValue] == 3);
    check([[shown valueForKey:@"xOffset"] floatValue] == 8);
    view.horos_scaleValue = 2.5; view.horos_origin = NSMakePoint(3, 4);

    // Scale-to-fit is stored as "no scale of its own" rather than as a number.
    view.scaledFit = YES;
    [view writeCopySettingsInSeriesForPixels: pixels];
    check([shown valueForKey:@"scale"] == nil);

    // A MONOCHROME1 image retains the old cache sign while the live window
    // and its samples use calibrated values.
    DCMPix *mono = pixels[1]; mono.displayInverted = YES;
    view.curWL = -1888;
    [view writeCopySettingsInSeriesForPixels:pixels];
    check([[shown valueForKey:@"windowLevel"] floatValue] == 1888);
    mono.displayInverted = NO; view.curWL = 1234;

    // On: the flattening the option promises. Every image loses its own
    // settings and every loaded one takes the window on screen.
    view.horos_COPYSETTINGSINSERIES = YES;
    [view writeCopySettingsInSeriesForPixels: pixels];
    for (DCMPix *pix in pixels) {
        check(keepsNothing([pix imageObj]));
        check(pix.appliedWL == 1234 && pix.appliedWW == 88);
    }

    // An image that is not loaded is not windowed, but is still cleared.
    DCMPix *unloaded = pixel();
    unloaded.loaded = NO;
    [[unloaded imageObj] setValue:[NSNumber numberWithFloat:1] forKey:@"windowWidth"];
    [view writeCopySettingsInSeriesForPixels: @[ unloaded ]];
    check(unloaded.windowChanged == NO);
    check(keepsNothing([unloaded imageObj]));

    NSLog(@"PASS: propagation off records the window only on the image on screen and the view on every image without its own, on flattens the series, xFlipped is xFlipped");
    return 0;
}}
'''.replace('STORAGE_METHODS', storage_methods)

# The database path that carries one series' presentation onto images gathered
# from several series asked whether the destination already had the setting.
# BrowserController's viewerKeyImagesAndROIsImages: hands the opening to
# SelectionMarkedImages (SelectionMarkedImages.swift), which reads each
# series' presentation before the viewer opens and copies what it found.
facade = source_text('BrowserController+Toolbar')
facade_start = facade.index('func viewerKeyImagesAndROIsImages(')
assert 'markedImages.openInViewer(sender)' in facade[facade_start:facade.index('\n    }\n', facade_start)], (
    'viewerKeyImagesAndROIsImages: no longer hands the opening to SelectionMarkedImages; this test needs a new look')
browser = source_text('SelectionMarkedImages')
block_start = browser.index('func openInViewer(')
block = browser[block_start:browser.index('autoTiling', block_start)]
copies = re.findall(r'if let value = (\w+)\.(\w+) \{ (\w+)\.(\w+) = value \}', block)
assert len(copies) >= 7, 'the presentation copy loop was not found'
for guarded, key, destination, written in copies:
    assert guarded == 'presentation' and destination == 'image' and key == written, (
        f'the {written} copy asks whether the destination image already has one, '
        'so an image with no presentation of its own is skipped')
assert re.search(r'\} else if let value = presentation\.scale \{\s*image\.scale = value', block), (
    'the scale copy asks whether the destination image already has one')

with tempfile.TemporaryDirectory(prefix='horos-copy-settings-') as tmp:
    p = Path(tmp)
    (p / 'bridge.h').write_text(bridge)
    (p / 'settings.swift').write_text(extension)
    (p / 'test.m').write_text(program + harness_defaults.OBJC)
    module = isix_modules.module_flags('IsiXImaging', p / 'module')
    sources = root / 'Horos/Sources'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'Horos', '-wmo',
                    '-import-objc-header', str(p / 'bridge.h'), '-I', str(sources), *module,
                    '-emit-objc-header', '-emit-objc-header-path', str(p / 'Horos-Swift.h'),
                    '-c', str(p / 'settings.swift'), str(store), '-o', str(p / 'settings.o')], check=True)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c', str(p / 'test.m'), '-o', str(p / 'test.o'), '-I', str(p), '-I', str(sources)],
                   check=True)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c', str(sources / 'HorosObjCException.m'), '-o', str(p / 'exception.o'),
                    '-I', str(sources)], check=True)
    subprocess.run(['xcrun', 'swiftc', str(p / 'settings.o'), str(p / 'test.o'), str(p / 'exception.o'), *module, '-o', str(p / 'test'),
                    '-framework', 'AppKit'], check=True)
    subprocess.run([str(p / 'test')], check=True)

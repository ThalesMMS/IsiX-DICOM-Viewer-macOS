#!/usr/bin/env python3
"""Turning propagation off must not flatten the series it is meant to un-flatten.

-writeCopySettingsInSeriesForPixels: is Swift (DCMView+SeriesSettings.swift),
with what it writes to each image decided by IsiXImaging's
SeriesSettingsPropagation. It is compiled as it is, with xcrun swiftc, as an
extension of an Objective-C double of DCMView that has the same horos_*
properties; the images and pixels are doubles too, with DCMPix's own
-storedWindowLevelForCalibratedLevel:.
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
extension = 'import Cocoa\nimport IsiXImaging\n\nextension DCMView {\n' + method + '}\n'

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

// The presentation state of one image, as key-value pairs. A nil value means
// the image has none of its own and falls back to what the file says.
@interface DicomImage : NSObject
@property(retain) NSMutableDictionary *values;
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
@property float horos_curWL, horos_curWW, horos_scaleValue, horos_rotation;
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
- (id) init { if ((self = [super init])) self.values = [NSMutableDictionary dictionary]; return self; }
- (void) setValue:(id)value forKey:(NSString*)key {
    if (value) [self.values setObject:value forKey:key];
    else [self.values removeObjectForKey:key];
}
- (id) valueForKey:(NSString*)key { return [self.values objectForKey:key]; }
@end

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
    view.horos_curWL = 1234; view.horos_curWW = 88;
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
    view.horos_curWL = -1888;
    [view writeCopySettingsInSeriesForPixels:pixels];
    check([[shown valueForKey:@"windowLevel"] floatValue] == 1888);
    mono.displayInverted = NO; view.horos_curWL = 1234;

    // On: the flattening the option promises. Every image loses its own
    // settings and every loaded one takes the window on screen.
    view.horos_COPYSETTINGSINSERIES = YES;
    [view writeCopySettingsInSeriesForPixels: pixels];
    for (DCMPix *pix in pixels) {
        check([[pix imageObj].values count] == 0);
        check(pix.appliedWL == 1234 && pix.appliedWW == 88);
    }

    // An image that is not loaded is not windowed, but is still cleared.
    DCMPix *unloaded = pixel();
    unloaded.loaded = NO;
    [[unloaded imageObj] setValue:[NSNumber numberWithFloat:1] forKey:@"windowWidth"];
    [view writeCopySettingsInSeriesForPixels: @[ unloaded ]];
    check(unloaded.windowChanged == NO);
    check([[unloaded imageObj].values count] == 0);

    NSLog(@"PASS: propagation off records the window only on the image on screen and the view on every image without its own, on flattens the series, xFlipped is xFlipped");
    return 0;
}}
'''.replace('STORAGE_METHODS', storage_methods)

# The database path that carries one series' presentation onto images gathered
# from several series asked whether the destination already had the setting.
# BrowserController's viewerKeyImagesAndROIsImages: is Swift
# (BrowserController+Toolbar.swift).
browser = source_text('BrowserController+Toolbar')
block_start = browser.index('func viewerKeyImagesAndROIsImages(')
block = browser[block_start:browser.index('AUTOTILING', block_start)]
copies = re.findall(r'if (\w+)\??\.value\(forKey: "(\w+)"\) != nil \{\s*\n\s*'
                    r'im\?\.setValue\(d\.value\(forKey: "\2"\)',
                    block)
assert copies, 'the presentation copy loop was not found'
for guarded, key in copies:
    assert guarded == 'd', (
        f'the {key} copy asks whether the destination image already has one, '
        'so an image with no presentation of its own is skipped')

with tempfile.TemporaryDirectory(prefix='horos-copy-settings-') as tmp:
    p = Path(tmp)
    (p / 'bridge.h').write_text(bridge)
    (p / 'settings.swift').write_text(extension)
    (p / 'test.m').write_text(program + harness_defaults.OBJC)
    module = isix_modules.module_flags('IsiXImaging', p / 'module')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'Horos', '-wmo',
                    '-import-objc-header', str(p / 'bridge.h'), *module,
                    '-emit-objc-header', '-emit-objc-header-path', str(p / 'Horos-Swift.h'),
                    '-c', str(p / 'settings.swift'), '-o', str(p / 'settings.o')], check=True)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c', str(p / 'test.m'), '-o', str(p / 'test.o'), '-I', str(p)],
                   check=True)
    subprocess.run(['xcrun', 'swiftc', str(p / 'settings.o'), str(p / 'test.o'), *module, '-o', str(p / 'test'),
                    '-framework', 'AppKit'], check=True)
    subprocess.run([str(p / 'test')], check=True)

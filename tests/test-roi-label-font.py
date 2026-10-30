#!/usr/bin/env python3
"""Exercise production ROI font selection/cache with real AppKit fonts.

The labels are pictures of the view's text layer (`HorosAnnotationText`). The
ROI is this checkout's, linked as the application's build compiled it with the
real rasterizer (tests/roi_harness.py); the viewer's font choice is that of
-changeLabelGLFontNotification: in DCMView+Drawing.swift, whose two statements
the probe runs in Objective-C. Without a build the test is skipped.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import roi_harness  # noqa: E402

drawing = (root / 'Horos/Sources/DCMView+Drawing.swift').read_text()
notification = drawing[drawing.index('@objc(changeLabelGLFontNotification:)'):]
notification = notification[:notification.index('\n    }\n')]
SWIFT_FONT = (
    '            var font = NSFont(name: defaults.string(forKey: "LabelFONTNAME") ?? "", '
    'size: CGFloat(defaults.float(forKey: "LabelFONTSIZE")))\n'
    '            if font == nil { font = NSFont.userFixedPitchFont(ofSize: CGFloat(defaults.float(forKey: "LabelFONTSIZE"))) }\n'
    '            self.horos_labelFont = font\n')
if SWIFT_FONT not in notification:
    sys.exit('FAIL: the viewer no longer chooses its label font as this probe does')
# The same choice in Objective-C (a missing name gives nil, as an empty one).
VIEW_FONT = '''
        labelFont = [[NSFont fontWithName: [[NSUserDefaults standardUserDefaults] stringForKey:@"LabelFONTNAME"] ?: @"" size: [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"]] retain];
        if( labelFont == nil) labelFont = [[NSFont userFixedPitchFontOfSize: [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"]] retain];
'''

PROBE = r'''
@interface ROI (LabelFont)
- (HorosAnnotationText*) stringTextureForString:(NSString*) str;
@end

// The picture's size in points for a string in a font: its size and margins.
static NSSize frameFor( NSString *s, NSFont *f) { NSSize z = [s sizeWithAttributes: @{NSFontAttributeName: f}]; return NSMakeSize( ceil( z.width + 8), ceil( z.height + 4)); }
static NSFont *viewerFont( void) { NSFont *labelFont = nil;
VIEW_FONT
return [labelFont autorelease];
}
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{});
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for( NSString *name in @[@"Helvetica", @"Horos-Definitely-Uninstalled-QA-Font"])
    {
        ROI *r = [newROI( tMesure) retain]; NSSize initial = NSZeroSize;
        for( NSNumber *size in @[@12, @13, @12])
        {
            [d setVolatileDomain: @{@"LabelFONTNAME": name, @"LabelFONTSIZE": size, @"FONTNAME": @"Courier", @"FONTSIZE": @30} forName: NSArgumentDomain];
            [r updateLabelFont];
            HorosAnnotationText *t = [r stringTextureForString: @"Length: 5.501 cm"];
            NSFont *expected = viewerFont();
            check( expected.pointSize == size.doubleValue);
            check( NSEqualSizes( t.frameSize, frameFor( @"Length: 5.501 cm", expected)));
            check( t == [r stringTextureForString: @"Length: 5.501 cm"]);
            NSSize measured = t.frameSize;
            if( initial.width == 0) initial = measured;
            else if( size.intValue == 13) check( measured.width > initial.width);
            else check( NSEqualSizes( initial, measured));
            check( [d integerForKey: @"FONTSIZE"] == 30);
        }
        // A later series open reads the same defaults; it must not keep the size-13 texture.
        ROI *reopened = newROI( tMesure);
        HorosAnnotationText *reopenedTexture = [reopened stringTextureForString: @"Length: 5.501 cm"];
        check( NSEqualSizes( initial, reopenedTexture.frameSize));
        [d setVolatileDomain: @{@"LabelFONTNAME": name, @"LabelFONTSIZE": @13, @"FONTNAME": @"Courier", @"FONTSIZE": @30} forName: NSArgumentDomain];
        ROI *kept = newROI( tMesure);
        check( [kept stringTextureForString: @"Length: 5.501 cm"].frameSize.width > initial.width);
        [r release];
    }
    ROI *r = newROI( tMesure);
    [r setCurView: (DCMView*) view];
    for( NSNumber *scale in @[@1, @2, @1, @2])
    {
        gBacking = scale.floatValue;
        HorosAnnotationText *t = [r stringTextureForString: @"Length: 5.501 cm"];
        // Layout reads the pixel size before any draw call, including on a cached ROI.
        check( t.pixelWidth == (NSInteger)( t.frameSize.width * scale.floatValue) && t.pixelHeight == (NSInteger)( t.frameSize.height * scale.floatValue));
        check( t == [r stringTextureForString: @"Length: 5.501 cm"]);
    }
    [window release];
    printf( "PASS: installed/missing ROI fonts, cache refresh, 12/13/12 sizes, reopen defaults, viewer agreement, annotation independence, pre-draw 1x/2x layout sizes\n");
    return 0;
}}
'''.replace('VIEW_FONT', VIEW_FONT)

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)

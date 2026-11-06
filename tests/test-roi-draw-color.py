#!/usr/bin/env python3
"""Check production ROI overlay colors against calibrated RGBY/alpha and the blend they are drawn with.

The OSI ROIs draw with OpenGL: their colour calls run here as they are in their
sources, against OpenGL itself. A 2D ROI draws on the view's canvas: this
checkout's ROI, linked as the application's build compiled it
(tests/roi_harness.py), draws a point on a canvas whose blend is the
premultiplied one the overlay leaves, and the pixels must be its colour at its
opacity, blended over what is behind; without a build that part is skipped.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

# These render with OpenGL and read the pixels back, so a machine with no
# window server session has nothing to draw into. That is a missing
# prerequisite, not a defect: skip, the way the rest of the suite does.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import accelerated_opengl
import roi_harness  # noqa: E402
accelerated_opengl.require()

root = Path(__file__).resolve().parents[1]


def source(name):
    path = 'Horos/Sources/' + name
    text = (subprocess.check_output(['git', 'show', sys.argv[1] + ':' + path])
            if len(sys.argv) > 1 else (root / path).read_bytes()).decode('latin1')
    # The ROIs call the canvas's OpenGL-shaped functions; the colours
    # and blend they set are checked against OpenGL itself here.
    return re.sub(r'(?<![A-Za-z0-9_])roi(?=[A-Z][A-Za-z0-9]*\s*\()', 'gl', text)


def slice_between(text, start, end):
    if start not in text:
        start = start.replace('colorUsingColorSpaceName:NSCalibratedRGBColorSpace',
                              'colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]')
    a = text.index(start)
    return text[a:text.index(end, a)]


def slice_first(text, pairs):
    last = None
    for start, end in pairs:
        try:
            return slice_between(text, start, end)
        except ValueError as error:
            last = error
    raise last


def objc_osi_check():
    """The colour calls of the Objective-C OSI ROIs, compiled against OpenGL."""
    extrusion = source('OSIPathExtrusionROI.m')
    extrusion_color = slice_first(extrusion, [
        ('    NSColor *deviceStrokeColor = [self.strokeColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];',
         '\n    \n    if (self.strokeThickness != 0 && self.strokeColor != nil) {'),
        ('    NSColor *deviceStrokeColor = [self.strokeColor colorUsingColorSpaceName:NSDeviceRGBColorSpace];',
         '\n    \n    if (self.strokeThickness != 0 && self.strokeColor != nil) {'),
    ])
    extrusion_gl = slice_between(
        extrusion,
        '        glColor4f((float)[deviceStrokeColor redComponent], (float)[deviceStrokeColor greenComponent], (float)[deviceStrokeColor blueComponent], (float)[deviceStrokeColor alphaComponent]);',
        '\n\n        N3AffineTransformGetOpenGLMatrixd')
    mask = source('OSIMaskROI.m')
    mask_color = slice_first(mask, [
        ('    NSColor *deviceColor = [self.fillColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];',
         '\n    \n    double dicomToPixGLTransform[16];'),
        ('    NSColor *deviceColor = [self.fillColor colorUsingColorSpaceName:NSDeviceRGBColorSpace];',
         '\n    \n    double dicomToPixGLTransform[16];'),
    ])
    mask_gl = slice_between(
        mask,
        '    glColor4f((float)[deviceColor redComponent], (float)[deviceColor greenComponent], (float)[deviceColor blueComponent], (float)[deviceColor alphaComponent]);',
        '\n//    glColor4f(1, 0, 1, .5);')
    path = source('OSIPlanarPathROI.m')
    path_color = slice_first(path, [
        ('    glLineWidth(3.0);\n    NSColor *drawColor = [self.strokeColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];',
         '\n    glBegin(GL_LINE_STRIP);'),
        ('    glLineWidth(3.0);\n    glColor3f(1, 0, 0);', '\n    glBegin(GL_LINE_STRIP);'),
    ])
    path_mask = slice_first(path, [
        ('    NSColor *maskColor = [self.fillColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];',
         '\n    glBegin(GL_LINES);'),
        ('    glColor3f(1, 0, 1);', '\n    glBegin(GL_LINES);'),
    ])
    brush = source('OSIPlanarBrushROI.m')
    try:
        brush_setup = slice_between(
            brush,
            '    glLineWidth(3.0);\n    NSColor *drawColor = [self.fillColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];',
            '\n    \n    // let\'s try drawing some the mask')
    except ValueError:
        brush_setup = '    glLineWidth(3.0);\n'
    brush_gl = slice_first(brush, [
        ('    glColor4f((float)[drawColor redComponent], (float)[drawColor greenComponent], (float)[drawColor blueComponent], (float)[drawColor alphaComponent]);',
         '\n    glBegin(GL_LINES);'),
        ('    glColor3f(1, 0, 1);', '\n    glBegin(GL_LINES);'),
    ])
    coalesced = source('OSICoalescedPlanarROI.m')
    coalesced_color = slice_first(coalesced, [
        ('    glLineWidth(3.0);\n    NSColor *drawColor = [self.fillColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];',
         '\n    glBegin(GL_QUADS);'),
        ('    glLineWidth(3.0);    \n\n    glColor4f(1, 0, 0, .4);', '\n    glBegin(GL_QUADS);'),
    ])

    code = r'''
    #import <Cocoa/Cocoa.h>
    #import <OpenGL/gl.h>
    #import <OpenGL/glext.h>
    static GLfloat captured[4], firstCaptured[4];
    static int captures;
    static void Cap4(GLfloat r, GLfloat g, GLfloat b, GLfloat a) {
     if(captures==0){firstCaptured[0]=r; firstCaptured[1]=g; firstCaptured[2]=b; firstCaptured[3]=a;}
     captured[0]=r; captured[1]=g; captured[2]=b; captured[3]=a; captures++;
     glColor4f(r,g,b,a);
    }
    static void Cap3(GLfloat r, GLfloat g, GLfloat b) { Cap4(r,g,b,1); }
    #define glColor4f Cap4
    #define glColor3f Cap3
    @interface Peer:NSObject {@public RGBColor color; float opacity;}
    @property(retain) NSColor *strokeColor;
    @property(retain) NSColor *fillColor;
    @property CGFloat strokeThickness;
    -(void)applyExtrusion;
    -(void)applyMask;
    -(void)applyPath;
    -(void)applyBrush;
    -(void)applyCoalesced;
    @end
    @implementation Peer
    -(void)applyExtrusion { EXTRUSION_COLOR EXTRUSION_GL }
    -(void)applyMask { MASK_COLOR MASK_GL }
    -(void)applyPath { PATH_COLOR PATH_MASK }
    -(void)applyBrush { BRUSH_SETUP BRUSH_GL }
    -(void)applyCoalesced { COALESCED_COLOR }
    @end
    #undef glColor4f
    #undef glColor3f
    #define check(...) do {if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
    static BOOL near4(const GLfloat *got, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
     return fabs(got[0]-r)<1.1/65535 && fabs(got[1]-g)<1.1/65535 && fabs(got[2]-b)<1.1/65535 && fabs(got[3]-a)<1e-5;
    }
    static int expect(Peer *p, SEL sel, CGFloat r, CGFloat g, CGFloat b, CGFloat a, const char *name) {
     captures=0; captured[0]=captured[1]=captured[2]=captured[3]=-1;
     [p performSelector:sel];
     if(captures<1 || !near4(firstCaptured,r,g,b,a) || !near4(captured,r,g,b,a)) {
      NSLog(@"FAIL %s: expected %.5f,%.5f,%.5f,%.5f first %.5f,%.5f,%.5f,%.5f last %.5f,%.5f,%.5f,%.5f captures=%d",
            name,r,g,b,a,firstCaptured[0],firstCaptured[1],firstCaptured[2],firstCaptured[3],captured[0],captured[1],captured[2],captured[3],captures);
      return 1;
     }
     return 0;
    }
    int main() {@autoreleasepool{
     [NSApplication sharedApplication];
     NSOpenGLPixelFormatAttribute attrs[]={NSOpenGLPFAAccelerated,NSOpenGLPFAColorSize,32,NSOpenGLPFAAlphaSize,8,0};
     NSOpenGLContext *context=[[NSOpenGLContext alloc] initWithFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] shareContext:nil];
     check(context!=nil); [context makeCurrentContext];
     RGBColor cases[]={{32768,32768,32768},{65535,0,0},{0,65535,0},{0,0,65535},{65535,65535,0},{12345,45678,23456}};
     float opacities[]={1.0f,0.5f};
     for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) for(int o=0;o<2;o++) {
      RGBColor rgb=cases[i]; float opacity=opacities[o];
      CGFloat r=rgb.red/65535.0, g=rgb.green/65535.0, b=rgb.blue/65535.0;
      NSColor *selected=[NSColor colorWithCalibratedRed:r green:g blue:b alpha:opacity];
      Peer *p=[Peer new]; p->color=rgb; p->opacity=opacity;
      p.strokeColor=selected; p.fillColor=selected; p.strokeThickness=1;
      if(expect(p,@selector(applyExtrusion),r,g,b,opacity,"OSI extrusion")) return 1;
      if(expect(p,@selector(applyMask),r,g,b,opacity,"OSI mask")) return 1;
      if(expect(p,@selector(applyPath),r,g,b,opacity,"OSI path")) return 1;
      if(expect(p,@selector(applyBrush),r,g,b,opacity,"OSI brush")) return 1;
      if(expect(p,@selector(applyCoalesced),r,g,b,opacity,"OSI coalesced")) return 1;
      [p release];
     }
     NSLog(@"PASS: OSI overlay draw colors match calibrated RGBY/midgray/mixed at opacity 1 and 0.5");
    }}
    '''
    for key, value in {
        'EXTRUSION_COLOR': extrusion_color,
        'EXTRUSION_GL': extrusion_gl,
        'MASK_COLOR': mask_color,
        'MASK_GL': mask_gl,
        'PATH_COLOR': path_color,
        'PATH_MASK': path_mask,
        'BRUSH_SETUP': brush_setup,
        'BRUSH_GL': brush_gl,
        'COALESCED_COLOR': coalesced_color,
    }.items():
        code = code.replace(key, value)

    with tempfile.TemporaryDirectory(prefix='horos-roi-draw-color-') as d:
        p = Path(d)
        (p / 'test.m').write_text(code)
        subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-Wno-deprecated-declarations',
                        '-fsanitize=undefined', '-framework', 'Cocoa', '-framework', 'OpenGL',
                        str(p / 'test.m'), '-o', str(p / 'test')], check=True)
        subprocess.run([str(p / 'test')], check=True)


def swift_source(name):
    return (root / 'Horos/Sources' / name).read_text(encoding='utf-8')


def swift_osi_check():
    """The colour calls of the Swift OSI ROIs, as their -drawSlab: makes them,
    run with the canvas's OpenGL-shaped functions recording the colour."""
    extrusion = swift_source('OSIPathExtrusionROI.swift')
    extrusion_color = slice_between(extrusion, '        let deviceStrokeColor = ', '\n')
    extrusion_gl = slice_between(extrusion, '            ROIGL.color4f(Float(deviceStrokeColor', '\n')
    mask = swift_source('OSIMaskROI.swift')
    mask_color = slice_between(mask, '        let deviceColor = ', '\n')
    mask_gl = slice_between(mask, '        ROIGL.color4f(Float(deviceColor', '\n')
    path = swift_source('OSIPlanarPathROI.swift')
    path_color = slice_between(path, '        ROIGL.lineWidth(3.0)\n', '        OSIROI.drawLineStrip(')
    path_mask = slice_between(path, '        let maskColor = ', '        OSIROI.drawMaskRunLines(')
    brush = swift_source('OSIPlanarBrushROI.swift')
    brush_setup = slice_between(brush, '        ROIGL.lineWidth(3.0)\n', '\n        // let\'s try drawing some the mask')
    brush_gl = slice_between(brush, '        ROIGL.color4f(Float(drawColor', '\n')
    coalesced = swift_source('OSICoalescedPlanarROI.swift')
    coalesced_color = slice_between(coalesced, '        ROIGL.lineWidth(3.0)\n', '        ROIGL.begin(ROIGL.quads)')

    code = r'''
import Cocoa

var captured: [Float] = [-1, -1, -1, -1], firstCaptured: [Float] = [-1, -1, -1, -1], captures = 0
// The canvas calls the ROIs make (ROIGL of ROI+Drawing.swift), the colour recorded.
enum ROIGL {
    static let pointSmooth: UInt32 = 0x0B10, lineSmooth: UInt32 = 0x0B20, polygonSmooth: UInt32 = 0x0B41
    static let blend: UInt32 = 0x0BE2, srcAlpha: UInt32 = 0x0302, oneMinusSrcAlpha: UInt32 = 0x0303
    static func color4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        if captures == 0 { firstCaptured = [r, g, b, a] }
        captured = [r, g, b, a]
        captures += 1
    }
    static func lineWidth(_ w: Float) {}
    static func enable(_ cap: UInt32) {}
    static func disable(_ cap: UInt32) {}
    static func blendFunc(_ source: UInt32, _ destination: UInt32) {}
    static func popMatrix() {}
}

final class Peer: NSObject {
    var stroke: NSColor?
    var fill: NSColor?
    func strokeColor() -> NSColor! { stroke }
    func fillColor() -> NSColor! { fill }
    func strokeThickness() -> CGFloat { 1 }
    func applyExtrusion() {
EXTRUSION_COLOR
EXTRUSION_GL
    }
    func applyMask() {
MASK_COLOR
MASK_GL
    }
    func applyPath() {
PATH_COLOR
PATH_MASK
    }
    func applyBrush() {
BRUSH_SETUP
BRUSH_GL
    }
    func applyCoalesced() {
COALESCED_COLOR
    }
}

func near4(_ got: [Float], _ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Bool {
    return abs(Double(got[0]) - r) < 1.1 / 65535 && abs(Double(got[1]) - g) < 1.1 / 65535 && abs(Double(got[2]) - b) < 1.1 / 65535
        && abs(Double(got[3]) - a) < 1e-5
}

var failed = false
let cases: [(UInt16, UInt16, UInt16)] = [(32768, 32768, 32768), (65535, 0, 0), (0, 65535, 0), (0, 0, 65535), (65535, 65535, 0), (12345, 45678, 23456)]
for rgb in cases {
    for opacity: Float in [1.0, 0.5] {
        let r = Double(rgb.0) / 65535.0, g = Double(rgb.1) / 65535.0, b = Double(rgb.2) / 65535.0
        let selected = NSColor(calibratedRed: r, green: g, blue: b, alpha: CGFloat(opacity))
        let peer = Peer()
        peer.stroke = selected
        peer.fill = selected
        for (name, apply) in [("OSI extrusion", peer.applyExtrusion), ("OSI mask", peer.applyMask), ("OSI path", peer.applyPath),
                              ("OSI brush", peer.applyBrush), ("OSI coalesced", peer.applyCoalesced)] {
            captures = 0
            captured = [-1, -1, -1, -1]
            apply()
            if captures < 1 || !near4(firstCaptured, r, g, b, Double(opacity)) || !near4(captured, r, g, b, Double(opacity)) {
                print("FAIL \(name): expected \(r),\(g),\(b),\(opacity) first \(firstCaptured) last \(captured) captures=\(captures)")
                failed = true
            }
        }
    }
}
if failed { exit(1) }
print("PASS: OSI overlay draw colors match calibrated RGBY/midgray/mixed at opacity 1 and 0.5")
'''
    for key, value in {
        'EXTRUSION_COLOR': extrusion_color,
        'EXTRUSION_GL': extrusion_gl,
        'MASK_COLOR': mask_color,
        'MASK_GL': mask_gl,
        'PATH_COLOR': path_color,
        'PATH_MASK': path_mask,
        'BRUSH_SETUP': brush_setup,
        'BRUSH_GL': brush_gl,
        'COALESCED_COLOR': coalesced_color,
    }.items():
        code = code.replace(key, value)

    with tempfile.TemporaryDirectory(prefix='horos-roi-draw-color-') as d:
        p = Path(d)
        (p / 'main.swift').write_text(code)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-module-name', 'DrawColor',
                        str(p / 'main.swift'), '-o', str(p / 'test')], check=True, timeout=300)
        subprocess.run([str(p / 'test')], check=True, timeout=60)


def has_objc_osi():
    """Whether the sources read (this checkout's, or the revision's) are the
    Objective-C OSI ROIs."""
    path = 'Horos/Sources/OSIPathExtrusionROI.m'
    if len(sys.argv) > 1:
        return subprocess.run(['git', 'cat-file', '-e', sys.argv[1] + ':' + path], capture_output=True).returncode == 0
    return (root / path).is_file()


if has_objc_osi():
    objc_osi_check()
else:
    swift_osi_check()


PROBE = r"""
int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{});
    ROI *r = newROI( t2DPoint);
    showAlone( r);
    r.rect = NSMakeRect( 32, 32, 0, 0);
    RGBColor cases[] = {{32768,32768,32768},{65535,0,0},{0,65535,0},{0,0,65535},{65535,65535,0},{12345,45678,23456}};
    float opacities[] = {1.0f, 0.5f};
    HorosAnnotationOverlay *overlay = [HorosAnnotationOverlay overlayForView: view];
    for( unsigned i = 0; i < sizeof( cases) / sizeof( cases[ 0]); i++) for( int o = 0; o < 2; o++)
    {
        [r setColor: cases[ i] globally: NO];
        [r setOpacity: opacities[ o] globally: NO];
        [overlay beginFrameWidth: kFrame height: kFrame];
        HorosROICanvas *canvas = [HorosROICanvas current];
        [canvas setModelview: CGAffineTransformIdentity viewport: NSMakeRect( 0, 0, kFrame, kFrame)];
        [canvas resetFrameState];
        [view applyImageTransformation];
        // What the frame leaves before a ROI draws: the labels' premultiplied
        // blend, and a line wide enough to have pixels the line covers whole.
        [canvas enable: 0x0BE2];
        [canvas blendSource: 1 destination: 0x0303];
        [canvas lineWidth: 8];
        [canvas colorR: 0 g: 1 b: 0 a: 1];
        [r setCurView: (DCMView*) view];
        [r drawROIWithScaleValue: gScale offsetX: kSide / 2. offsetY: kSide / 2. pixelSpacingX: 1 pixelSpacingY: 1
             highlightIfSelected: NO thickness: r.thickness prepareTextualData: NO];
        const unsigned char *px = canvas.pixels;
        // The pixels one segment covers whole are the most frequent drawn
        // ones: the segments of the loop blend twice where they join.
        long count = canvas.pixelWidth * canvas.pixelHeight;
        NSCountedSet *drawn = [NSCountedSet set];
        for( long k = 0; k < count; k++) if( px[ 4*k+3]) [drawn addObject: @(((unsigned) px[ 4*k] << 24) | (px[ 4*k+1] << 16) | (px[ 4*k+2] << 8) | px[ 4*k+3])];
        unsigned top = 0; NSUInteger most = 0;
        for( NSNumber *n in drawn) if( [drawn countForObject: n] > most) { most = [drawn countForObject: n]; top = n.unsignedIntValue; }
        const unsigned char b[ 4] = { top >> 24, (top >> 16) & 255, (top >> 8) & 255, top & 255};
        float a = opacities[ o];
        int wanted[ 4] = { (int) lrint( cases[ i].red / 65535. * a * 255), (int) lrint( cases[ i].green / 65535. * a * 255),
                           (int) lrint( cases[ i].blue / 65535. * a * 255), (int) lrint( a * 255)};
        for( int c = 0; c < 4; c++) if( abs( b[ c] - wanted[ c]) > 1)
        {
            fprintf( stderr, "FAIL colour %u opacity %.1f: channel %d is %d, expected %d (premultiplied, source-alpha blend)\n", i, a, c, b[ c], wanted[ c]);
            return 1;
        }
    }
    [window release];
    printf( "PASS: a 2D ROI draws its colour at its opacity, blended by its alpha whatever blend the frame left\n");
    return 0;
}}
"""

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)

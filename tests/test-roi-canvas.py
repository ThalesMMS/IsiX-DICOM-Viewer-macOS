#!/usr/bin/env python3
"""ROIs are drawn by a Core Graphics canvas, not OpenGL (#727).

`ROI.m` and the OSIROI family describe their graphics in OpenGL's immediate
mode. Those calls now go to `HorosROICanvas` (`ROICanvasGL.h`), which draws
them into a bitmap beneath the view's text with OpenGL's rules; labels and
text ROIs go to the text layer.

Checked here:
- in the sources, `ROI.m` and the OSIROI classes' drawing call no OpenGL
  function, labels are overlay text, and the view syncs the canvas before its
  ROIs and posts the Core Graphics notification for plugins;
- the same command lists run through OpenGL, into a framebuffer, and through
  the canvas: aliased and smooth lines of several widths, strips and loops,
  square and round points, colours per vertex, filled polygons with alpha, blending off, the
  additive blend, the stipple, a 3-D matrix with z, push and pop, a Bezier
  evaluator, an intensity mask, an ARGB picture on a parallelogram and a
  plugin's Core Graphics drawing in model coordinates. The
  pixels each lights agree (intersection over union) and their colours are
  close where both light.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import accelerated_opengl

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path], stderr=subprocess.DEVNULL).decode('utf-8', 'replace')
        except subprocess.CalledProcessError:
            return ''
    return (root / path).read_bytes().decode('utf-8', 'replace')


failures = []
GL_CALL = re.compile(r'(?<![A-Za-z0-9_/])gl[A-Z]\w*\s*\(')
roi = read('Horos/Sources/ROI.m')
code = '\n'.join(l for l in roi.split('\n') if not l.strip().startswith('//'))
if GL_CALL.search(code) or 'StringTexture' in code:
    failures.append('ROI.m still draws with OpenGL or StringTexture')
if '[[HorosAnnotationOverlay overlayForView: view] addText:' not in roi:
    failures.append('ROI labels are not overlay text')
for name in ('OSIMaskROI', 'OSIPathExtrusionROI', 'OSIPlanarBrushROI', 'OSIPlanarPathROI', 'OSICoalescedPlanarROI'):
    text = read('Horos/Sources/%s.m' % name)
    if 'drawSlab:(OSISlab)slab dicomToPixTransform:' not in text:
        failures.append(name + ' has no drawSlab')
        continue
    body = text[text.index('- (void)drawSlab:(OSISlab)slab dicomToPixTransform:'):]
    body = '\n'.join(l for l in body[:body.index('\n}\n')].split('\n') if not l.strip().startswith('//'))
    if GL_CALL.search(body):
        failures.append(name + ' still draws with OpenGL')
view = read('Horos/Sources/DCMView.m')
if '[[HorosROICanvas current] resetFrameState]' not in view or 'HorosDrawObjectsCanvasNotification' not in view:
    failures.append('the view does not reset the canvas before its ROIs or post the canvas notification')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

accelerated_opengl.require()

W, H = 240, 160
# Each case is a list of commands both sides run from the same state: a pixel
# transform from the top left, blending on with (SRC_ALPHA, ONE_MINUS_SRC_ALPHA),
# no smoothing, width and point size 1, white.
CASES = {
    'aliased lines 1 2 6': [['width', 1], ['begin', 'LINES'], ['v', 10, 10], ['v', 200, 40], ['v', 20, 60], ['v', 60, 150], ['end'],
                            ['width', 2], ['begin', 'LINES'], ['v', 30, 20], ['v', 220, 120], ['end'],
                            ['width', 6], ['color', 1, 0.5, 0, 1], ['begin', 'LINES'], ['v', 100, 10], ['v', 130, 150], ['end']],
    'smooth strip and loop': [['enable', 'LINE_SMOOTH'], ['width', 2], ['color', 0.2, 0.9, 0.3, 1], ['begin', 'LINE_STRIP'],
                              ['v', 20, 20], ['v', 120, 30], ['v', 200, 120], ['v', 60, 140], ['end'],
                              ['width', 3], ['color', 0.9, 0.2, 0.8, 0.8], ['begin', 'LINE_LOOP'], ['v', 40, 50], ['v', 180, 60], ['v', 110, 100], ['end']],
    'points square and round': [['psize', 8], ['begin', 'POINTS'], ['v', 30, 30], ['v', 60.5, 30.5], ['end'],
                                ['enable', 'POINT_SMOOTH'], ['psize', 12], ['color', 0.5, 0.5, 1, 1], ['begin', 'POINTS'], ['v', 120, 80], ['v', 200, 120], ['end']],
    'polygon with alpha': [['enable', 'POLYGON_SMOOTH'], ['color', 1, 0, 0, 0.5], ['begin', 'POLYGON'], ['v', 30, 20], ['v', 200, 30], ['v', 180, 140], ['v', 40, 120], ['end'],
                           ['color', 0, 0, 1, 0.5], ['begin', 'TRIANGLES'], ['v', 100, 10], ['v', 220, 150], ['v', 20, 150], ['end']],
    'blending off and additive': [['disable', 'BLEND'], ['width', 4], ['color', 0.2, 0.4, 0.6, 0.1], ['begin', 'LINES'], ['v', 10, 20], ['v', 230, 20], ['end'],
                                  ['enable', 'BLEND'], ['blend', 'ONE'], ['color', 0.3, 0.1, 0.0, 0.5], ['begin', 'QUADS'],
                                  ['v', 40, 40], ['v', 200, 40], ['v', 200, 120], ['v', 40, 120], ['end']],
    'stipple': [['width', 2], ['enable', 'LINE_STIPPLE'], ['stipple', 1, 0x0F0F], ['begin', 'LINES'], ['v', 10, 80], ['v', 230, 80], ['end'], ['disable', 'LINE_STIPPLE']],
    'matrix with z, push and pop': [['push'], ['mult', [0.5, 0.2, 0, 0, -0.2, 0.5, 0, 0, 10, 20, 1, 0, 100, 40, 0, 1]], ['width', 3],
                                    ['begin', 'LINE_LOOP'], ['v3', 0, 0, 0], ['v3', 100, 0, 2], ['v3', 100, 100, 4], ['v3', 0, 100, 0], ['end'], ['pop'],
                                    ['translate', 20, 10], ['rotate', 20], ['scale', 1.5, 0.8], ['begin', 'LINES'], ['v', 0, 0], ['v', 80, 60], ['end']],
    'bezier evaluator': [['width', 2], ['map', [20, 140, 0, 120, 10, 0, 220, 140, 0]], ['enable', 'MAP1_VERTEX_3'], ['begin', 'LINE_STRIP'], ['eval', 30], ['end']],
    'colour per vertex': [['width', 3], ['begin', 'LINE_STRIP'], ['color', 1, 0.5, 0, 1], ['v', 20, 30], ['color', 1, 0.5, 0, 0.1], ['v', 120, 40],
                          ['v', 200, 120], ['color', 1, 0.5, 0, 1], ['v', 60, 140], ['end'],
                          ['psize', 10], ['begin', 'POINTS'], ['color', 1, 0, 0, 1], ['v', 30, 100], ['color', 0, 1, 0, 1], ['v', 60, 100], ['color', 0, 0, 1, 1], ['v', 90, 100], ['end']],
    'plugin Core Graphics context': [['cgrect', 30, 40, 120, 70, 0.2, 0.8, 0.4, 0.6], ['translate', 100, 20], ['cgrect', 50, 50, 60, 60, 1, 0, 0, 1]],
    'intensity mask': [['color', 0.9, 0.6, 0.1, 0.7], ['mask', 12, 8, 30.0, 20.0, 210.0, 140.0]],
    'argb picture': [['argb', 10, 6, 20.0, 20.0, 200.0, 40.0, 40.0, 140.0]],
}

REFERENCE = r'''
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
static GLenum mode(NSString *m) {
    NSDictionary *d = @{@"POINTS": @(GL_POINTS), @"LINES": @(GL_LINES), @"LINE_STRIP": @(GL_LINE_STRIP), @"LINE_LOOP": @(GL_LINE_LOOP),
        @"POLYGON": @(GL_POLYGON), @"TRIANGLES": @(GL_TRIANGLES), @"QUADS": @(GL_QUADS), @"LINE_SMOOTH": @(GL_LINE_SMOOTH),
        @"POINT_SMOOTH": @(GL_POINT_SMOOTH), @"POLYGON_SMOOTH": @(GL_POLYGON_SMOOTH), @"BLEND": @(GL_BLEND), @"LINE_STIPPLE": @(GL_LINE_STIPPLE),
        @"MAP1_VERTEX_3": @(GL_MAP1_VERTEX_3), @"ONE": @(GL_ONE)};
    return [d[m] unsignedIntValue];
}
int main(int argc, char **argv) { @autoreleasepool {
    NSDictionary *cases = [NSJSONSerialization JSONObjectWithData: [NSData dataWithContentsOfFile: @(argv[1])] options: 0 error: nil];
    NSOpenGLPixelFormatAttribute attributes[] = {NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0};
    NSOpenGLContext *context = [[NSOpenGLContext alloc] initWithFormat: [[NSOpenGLPixelFormat alloc] initWithAttributes: attributes] shareContext: nil];
    [context makeCurrentContext];
    GLuint fbo, colour; glGenFramebuffersEXT(1, &fbo); glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    glGenRenderbuffersEXT(1, &colour); glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, colour);
    glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, W, H);
    glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_RENDERBUFFER_EXT, colour);
    for (NSString *name in cases) {
        glViewport(0, 0, W, H); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
        glMatrixMode(GL_PROJECTION); glLoadIdentity(); glMatrixMode(GL_MODELVIEW); glLoadIdentity();
        glScalef(2.0f / W, -2.0f / H, 1); glTranslatef(-W / 2.0f, -H / 2.0f, 0);
        glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_LINE_SMOOTH); glDisable(GL_POINT_SMOOTH); glDisable(GL_POLYGON_SMOOTH);
        glLineWidth(1); glPointSize(1); glColor4f(1, 1, 1, 1);
        for (NSArray *c in cases[name]) {
            NSString *op = c[0];
            if ([op isEqual: @"width"]) glLineWidth([c[1] floatValue]);
            else if ([op isEqual: @"psize"]) glPointSize([c[1] floatValue]);
            else if ([op isEqual: @"color"]) glColor4f([c[1] floatValue], [c[2] floatValue], [c[3] floatValue], [c[4] floatValue]);
            else if ([op isEqual: @"enable"]) glEnable(mode(c[1]));
            else if ([op isEqual: @"disable"]) glDisable(mode(c[1]));
            else if ([op isEqual: @"blend"]) glBlendFunc(mode(c[1]), GL_ONE_MINUS_SRC_ALPHA);
            else if ([op isEqual: @"stipple"]) glLineStipple([c[1] intValue], [c[2] intValue]);
            else if ([op isEqual: @"begin"]) glBegin(mode(c[1]));
            else if ([op isEqual: @"end"]) glEnd();
            else if ([op isEqual: @"v"]) glVertex2f([c[1] floatValue], [c[2] floatValue]);
            else if ([op isEqual: @"v3"]) glVertex3d([c[1] doubleValue], [c[2] doubleValue], [c[3] doubleValue]);
            else if ([op isEqual: @"push"]) glPushMatrix();
            else if ([op isEqual: @"pop"]) glPopMatrix();
            else if ([op isEqual: @"mult"]) { GLdouble m[16]; for (int i = 0; i < 16; i++) m[i] = [c[1][i] doubleValue]; glMultMatrixd(m); }
            else if ([op isEqual: @"translate"]) glTranslatef([c[1] floatValue], [c[2] floatValue], 0);
            else if ([op isEqual: @"cgrect"]) {
                float x = [c[1] floatValue], y = [c[2] floatValue], w = [c[3] floatValue], h = [c[4] floatValue];
                glColor4f([c[5] floatValue], [c[6] floatValue], [c[7] floatValue], [c[8] floatValue]);
                glBegin(GL_QUADS); glVertex2f(x, y); glVertex2f(x + w, y); glVertex2f(x + w, y + h); glVertex2f(x, y + h); glEnd();
            }
            else if ([op isEqual: @"rotate"]) glRotatef([c[1] floatValue], 0, 0, 1);
            else if ([op isEqual: @"scale"]) glScalef([c[1] floatValue], [c[2] floatValue], 1);
            else if ([op isEqual: @"map"]) { GLfloat p[9]; for (int i = 0; i < 9; i++) p[i] = [c[1][i] floatValue]; glMap1f(GL_MAP1_VERTEX_3, 0, 1, 3, 3, p); }
            else if ([op isEqual: @"eval"]) { int n = [c[1] intValue]; for (int i = 0; i <= n; i++) glEvalCoord1f((GLfloat) i / n); }
            else if ([op isEqual: @"mask"] || [op isEqual: @"argb"]) {
                int w = [c[1] intValue], h = [c[2] intValue];
                BOOL mask = [op isEqual: @"mask"];
                unsigned char *data = malloc(w * h * 4);
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                    if (mask) data[y * w + x] = ((x / 2 + y) % 3) ? 255 : 0;
                    else { unsigned char *p = data + 4 * (y * w + x); p[0] = (x + y) % 2 ? 255 : 128; p[1] = x * 20; p[2] = y * 40; p[3] = 200; }
                }
                GLuint t; glGenTextures(1, &t); glEnable(GL_TEXTURE_RECTANGLE_EXT); glBindTexture(GL_TEXTURE_RECTANGLE_EXT, t);
                glPixelStorei(GL_UNPACK_ROW_LENGTH, w); glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
                glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
                glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                if (mask) glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_INTENSITY8, w, h, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, data);
                else { glColor4f(1, 1, 1, 1); glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA, w, h, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8, data); }
                float x0 = [c[3] floatValue], y0 = [c[4] floatValue], x1 = [c[5] floatValue], y1 = [c[6] floatValue];
                float x2 = mask ? x0 : [c[7] floatValue], y2 = mask ? y1 : [c[8] floatValue];
                if (mask) y1 = y0;
                glBegin(GL_QUAD_STRIP);
                glTexCoord2f(0, 0); glVertex2f(x0, y0);
                glTexCoord2f(w, 0); glVertex2f(x1, y1);
                glTexCoord2f(0, h); glVertex2f(x2, y2);
                glTexCoord2f(w, h); glVertex2f(x1 + x2 - x0, y1 + y2 - y0);
                glEnd();
                glDisable(GL_TEXTURE_RECTANGLE_EXT); glDeleteTextures(1, &t); free(data);
                glPixelStorei(GL_UNPACK_ROW_LENGTH, 0); glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            }
        }
        glFinish();
        NSMutableData *out = [NSMutableData dataWithLength: W * H * 4];
        glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, out.mutableBytes);
        NSMutableData *rgb = [NSMutableData dataWithLength: W * H * 3];
        unsigned char *s = out.mutableBytes, *d = rgb.mutableBytes;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (int k = 0; k < 3; k++) d[(y * W + x) * 3 + k] = s[((H - 1 - y) * W + x) * 4 + k];
        [rgb writeToFile: [NSString stringWithFormat: @"%s/%@.gl", argv[2], name] atomically: NO];
    }
    return 0;
}}
'''.replace('#import <Cocoa/Cocoa.h>\n', '#import <Cocoa/Cocoa.h>\n#define W %d\n#define H %d\n' % (W, H), 1)

DRIVER = r'''
import AppKit
import simd

@main struct Check {
    static func main() throws {
        let args = CommandLine.arguments
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: [[Any]]]
        let w = WIDTH, h = HEIGHT
        let enums: [String: UInt32] = ["POINTS": 0, "LINES": 1, "LINE_LOOP": 2, "LINE_STRIP": 3, "TRIANGLES": 4, "QUADS": 7, "POLYGON": 9,
            "LINE_SMOOTH": 0x0B20, "POINT_SMOOTH": 0x0B10, "POLYGON_SMOOTH": 0x0B41, "BLEND": 0x0BE2, "LINE_STIPPLE": 0x0B24, "MAP1_VERTEX_3": 0x0D97, "ONE": 1]
        func f(_ a: Any) -> Double { (a as! NSNumber).doubleValue }
        for (name, commands) in cases {
            let canvas = ROICanvas()
            canvas.beginFrame(width: w, height: h, colorSpace: CGColorSpaceCreateDeviceRGB())
            canvas.set(modelview: CGAffineTransform(a: 2.0 / CGFloat(w), b: 0, c: 0, d: -2.0 / CGFloat(h), tx: -1, ty: 1),
                       viewport: CGRect(x: 0, y: 0, width: w, height: h))
            canvas.enable(0x0BE2); canvas.blend(source: 0x0302, destination: 0x0303)
            canvas.lineWidth(1); canvas.pointSize(1); canvas.color(r: 1, g: 1, b: 1, a: 1)
            for c in commands {
                switch c[0] as! String {
                case "width": canvas.lineWidth(CGFloat(f(c[1])))
                case "psize": canvas.pointSize(CGFloat(f(c[1])))
                case "color": canvas.color(r: CGFloat(f(c[1])), g: CGFloat(f(c[2])), b: CGFloat(f(c[3])), a: CGFloat(f(c[4])))
                case "enable": canvas.enable(enums[c[1] as! String]!)
                case "disable": canvas.disable(enums[c[1] as! String]!)
                case "blend": canvas.blend(source: enums[c[1] as! String]!, destination: 0x0303)
                case "stipple": canvas.lineStipple(factor: Int(f(c[1])), pattern: UInt16(f(c[2])))
                case "begin": canvas.begin(enums[c[1] as! String]!)
                case "end": canvas.end()
                case "v": canvas.vertex(x: CGFloat(f(c[1])), y: CGFloat(f(c[2])))
                case "v3": canvas.vertex(x: f(c[1]), y: f(c[2]), z: f(c[3]))
                case "push": canvas.pushMatrix()
                case "pop": canvas.popMatrix()
                case "mult": var m = (c[1] as! [NSNumber]).map { $0.doubleValue }; canvas.mult(&m)
                case "translate": canvas.translate(x: f(c[1]), y: f(c[2]), z: 0)
                case "rotate": canvas.rotate(f(c[1]))
                case "cgrect":
                    // What a plugin draws through the notification's context, in model coordinates.
                    let context = canvas.modelContext()!
                    context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [CGFloat(f(c[5])), CGFloat(f(c[6])), CGFloat(f(c[7])), CGFloat(f(c[8]))])!)
                    context.fill(CGRect(x: f(c[1]), y: f(c[2]), width: f(c[3]), height: f(c[4])))
                case "scale": canvas.scale(x: f(c[1]), y: f(c[2]), z: 1)
                case "map": let p = (c[1] as! [NSNumber]).map { Float($0.doubleValue) }; p.withUnsafeBufferPointer { canvas.map1(points: $0.baseAddress!, count: 3) }
                case "eval": let n = Int(f(c[1])); for i in 0...n { canvas.evalCoord(CGFloat(i) / CGFloat(n)) }
                case "mask", "argb":
                    let mw = Int(f(c[1])), mh = Int(f(c[2]))
                    var data = [UInt8](repeating: 0, count: mw * mh * 4)
                    for y in 0..<mh { for x in 0..<mw {
                        if c[0] as! String == "mask" { data[y * mw + x] = ((x / 2 + y) % 3) != 0 ? 255 : 0 }
                        else { let i = 4 * (y * mw + x); data[i] = (x + y) % 2 == 1 ? 255 : 128; data[i + 1] = UInt8(x * 20); data[i + 2] = UInt8(y * 40); data[i + 3] = 200 }
                    } }
                    if c[0] as! String == "mask" {
                        canvas.drawIntensity(data, width: mw, height: mh, rowBytes: mw, x0: CGFloat(f(c[3])), y0: CGFloat(f(c[4])), x1: CGFloat(f(c[5])), y1: CGFloat(f(c[6])), interpolate: false)
                    } else {
                        canvas.color(r: 1, g: 1, b: 1, a: 1)
                        canvas.drawARGB(data, width: mw, height: mh, rowBytes: mw * 4, x0: CGFloat(f(c[3])), y0: CGFloat(f(c[4])), x1: CGFloat(f(c[5])), y1: CGFloat(f(c[6])),
                                        x2: CGFloat(f(c[7])), y2: CGFloat(f(c[8])), interpolate: false)
                    }
                default: break
                }
            }
            // Over black, a premultiplied pixel is its colour.
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            if let picture = canvas.finishFrame() {
                rgb.withUnsafeMutableBufferPointer {
                    AnnotationOverlay.composite([(picture.picture, picture.rect)], onto: $0.baseAddress!, width: w, height: h, originX: 0, originY: 0)
                }
            }
            try Data(rgb).write(to: URL(fileURLWithPath: "\(args[2])/\(name).canvas"))
        }
        // Each bitmap is cleared where it drew two frames before: a frame
        // shows nothing of an earlier one, which drew elsewhere.
        let frames = ROICanvas()
        var leftovers = 0
        for frame in 0..<6 {
            frames.beginFrame(width: w, height: h, colorSpace: CGColorSpaceCreateDeviceRGB())
            frames.set(modelview: CGAffineTransform(a: 2.0 / CGFloat(w), b: 0, c: 0, d: -2.0 / CGFloat(h), tx: -1, ty: 1),
                       viewport: CGRect(x: 0, y: 0, width: w, height: h))
            frames.enable(0x0BE2); frames.blend(source: 0x0302, destination: 0x0303)
            frames.color(r: 1, g: 0.4, b: 0, a: 1)
            let left = CGFloat(frame * 30)
            frames.enable(0x0B20); frames.lineWidth(3)
            frames.begin(2)
            for i in 0..<24 { let a = CGFloat(i) * .pi / 12; frames.vertex(x: left + 40 + 25 * cos(a), y: 80 + 25 * sin(a)) }
            frames.end()
            frames.enable(0x0B10); frames.pointSize(3)
            frames.begin(0)
            for i in 0..<24 { let a = CGFloat(i) * .pi / 12; frames.vertex(x: left + 40 + 25 * cos(a), y: 80 + 25 * sin(a)) }
            frames.end()
            frames.disable(0x0B20); frames.lineWidth(2)
            frames.begin(1); frames.vertex(x: left + 10, y: 140); frames.vertex(x: left + 70, y: 150); frames.end()
            _ = frames.finishFrame()
            let bytes = frames.bytes!
            for y in 0..<h { for x in 0..<w where bytes[(y * w + x) * 4 + 3] != 0 {
                if CGFloat(x) < left + 5 || CGFloat(x) > left + 75 || y < 45 || y > 160 { leftovers += 1 }
            } }
        }
        print("LEFTOVERS \(leftovers)")
        print("DONE")
    }
}
'''.replace('WIDTH', str(W)).replace('HEIGHT', str(H))

with tempfile.TemporaryDirectory(prefix='horos-roi-canvas-') as name:
    work = Path(name)
    (work / 'cases.json').write_text(json.dumps(CASES))
    (work / 'reference.m').write_text(REFERENCE)
    if subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wno-deprecated-declarations', '-w', '-framework', 'Cocoa', '-framework', 'OpenGL',
                       str(work / 'reference.m'), '-o', str(work / 'reference')]).returncode:
        print('FAIL: the OpenGL reference does not build')
        raise SystemExit(1)
    (work / 'Check.swift').write_text(DRIVER)
    if subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-suppress-warnings', str(root / 'Horos/Sources/ROICanvas.swift'),
                       str(root / 'Horos/Sources/AnnotationOverlay.swift'), str(work / 'Check.swift'), '-o', str(work / 'check')]).returncode:
        print('FAIL: the canvas does not build with the driver')
        raise SystemExit(1)
    if subprocess.run([str(work / 'reference'), str(work / 'cases.json'), str(work)], timeout=120).returncode:
        print('FAIL: the OpenGL reference did not draw')
        raise SystemExit(1)
    run = subprocess.run([str(work / 'check'), str(work / 'cases.json'), str(work)], timeout=120, capture_output=True, text=True)
    if run.returncode or 'DONE' not in run.stdout:
        print(run.stdout.strip() or run.stderr.strip() or 'FAIL: the canvas driver failed')
        raise SystemExit(1)
    leftovers = re.search(r'LEFTOVERS (\d+)', run.stdout)
    if not leftovers or int(leftovers.group(1)):
        failures.append('a frame shows pixels an earlier frame drew: %s' % (leftovers.group(1) if leftovers else 'no count'))
    results = []
    for case in CASES:
        gl = (work / (case + '.gl')).read_bytes()
        cv = (work / (case + '.canvas')).read_bytes()
        lit_gl = [max(gl[i:i + 3]) > 24 for i in range(0, len(gl), 3)]
        lit_cv = [max(cv[i:i + 3]) > 24 for i in range(0, len(cv), 3)]
        both = sum(1 for a, b in zip(lit_gl, lit_cv) if a and b)
        either = sum(1 for a, b in zip(lit_gl, lit_cv) if a or b)
        iou = both / either if either else 1.0
        diffs = [abs(gl[i + k] - cv[i + k]) for j, i in enumerate(range(0, len(gl), 3)) if lit_gl[j] and lit_cv[j] for k in range(3)]
        mean = sum(diffs) / len(diffs) if diffs else 0
        results.append('%s %.3f/%.1f' % (case, iou, mean))
        if either < 20:
            failures.append('%s: OpenGL drew %d pixels' % (case, either))
        elif iou < 0.9 or mean > 12:
            failures.append('%s: the canvas lights %.3f of the pixels OpenGL and it light together, colours %.1f levels apart' % (case, iou, mean))
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        print('   ', '; '.join(results))
        raise SystemExit(1)
    print('PASS: ROI.m and the OSIROI drawing call no OpenGL; canvas against OpenGL, intersection over union / mean colour difference: ' + '; '.join(results))

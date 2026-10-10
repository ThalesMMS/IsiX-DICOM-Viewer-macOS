#!/usr/bin/env python3
"""The viewer's text is drawn above its OpenGL content, not in it.

Every string of a `DCMView` - the annotations, the orientation letters, the
colour bar values, the renderer notice, the study number box and the large
description - used to be an OpenGL texture (`StringTexture`, `GLString`) or
glyph display lists drawn into the frame. They are now recorded by
`DrawNSStringGL` and the two boxes where the current OpenGL transform would
have put them, and shown by `HorosAnnotationOverlay`, a Core Animation layer
above the view. Captures read the OpenGL pixels and composite the same frame
onto them.

Checked here:
- in the sources, `DCMView.m` no longer uses `StringTexture`, `GLString` or
  glyph display lists; `DrawNSStringGL` records into the overlay; the frame is
  begun and committed around the drawing, inverted with it; captures
  composite the overlay after the rows are flipped;
- the overlay's glyphs are `StringTexture`'s texture byte for byte, and its
  boxes `GLString`'s, at 1x and 2x;
- composited onto a background, the overlay gives what OpenGL drew with the
  old calls - shadow, text, white background, inverted frame, a box stretched
  to 2x and one between pixels - within one level (a quad edge exactly on
  a pixel centre is left to OpenGL's arithmetic, so no case sits on one);
- the overlay view keeps one layer per item, at the item's place in points,
  hides the rest, leaves out items placed at NaN (a panel collapsed to no
  size), and lets the mouse through.

`<git revision>` as an optional argument reads `DCMView.m` from that revision,
the negative control. The study number box is built and drawn by
`-drawTextualData:...` in DCMView+WindowLevel+Coordinates.swift, and blocks of
DCMView.m live in Swift extensions (DCMView+*.swift), which are read too when
the revision has them.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import accelerated_opengl
import history_reference

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


# The blocks of DCMView.m moved to Swift extensions of DCMView.
EXTENSIONS = ('MouseDragging', 'WindowLevel', 'WindowLevel+Coordinates', 'DragAndDrop', 'HotKeys', 'Loupe')


def read_swift(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(root), 'show', revision + ':' + path], capture_output=True)
        return shown.stdout.decode('utf-8') if shown.returncode == 0 else None
    return (root / path).read_text(encoding='utf-8') if (root / path).is_file() else None


failures = []
view = read('Horos/Sources/DCMView.m')
extensions = {name: read_swift('Horos/Sources/DCMView+' + name + '.swift') for name in EXTENSIONS}
extensions = {name: text for name, text in extensions.items() if text is not None}
for old in ('StringTexture', 'GLString', 'glCallList', 'drawWithBounds'):
    if re.search(r'\b' + old + r'\b', view):
        failures.append('DCMView.m still draws text with ' + old)
    for name, text in extensions.items():
        if re.search(r'\b' + old + r'\b', text):
            failures.append('DCMView+' + name + '.swift still draws text with ' + old)
draw = view[view.index('- (void)DrawNSStringGL:(NSString*)str :(DCMViewFontKind)fontL :(long)x :(long)y align:'):]
draw = draw[:draw.index('\n}\n')]
if 'HorosAnnotationText textForString:' not in draw or 'addText:' not in draw:
    failures.append('DrawNSStringGL does not record its string into the overlay')
frame = view[view.index('- (void) drawFrame:(NSRect)aRect'):]
frame = frame[:frame.index('\n}\n')]
# The picture is presented with the Core Animation transaction the overlay's
# frame is committed in.
# The frame's cycle (PlanarFramePresenter.swift) begins and commits it.
presenter = (root / 'Horos/Sources/PlanarFramePresenter.swift').read_text() if (root / 'Horos/Sources/PlanarFramePresenter.swift').exists() else ''
if '[HorosPlanarFrameCycle beginInView: self size: aRect.size scale: sf\n' not in frame or \
        'inverted: gInvertColors && [stringID isEqualToString: @"export"] == NO]' not in frame or \
        '[frame commitIndex: curImage];' not in frame or \
        'overlay.beginFrame(width: Int(size.width), height: Int(size.height))' not in presenter or \
        'overlay.commit(inverted: inverted, scale: scale)' not in presenter:
    failures.append('the frame is not begun and committed, with its inversion')
capture = view[view.index('-(unsigned char*) getRawPixelsViewWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing offset:'):]
capture = capture[:capture.index('else // Screen Capture in 16 bit BW')]
if 'compositeOntoRGB:' not in capture or capture.find('compositeOntoRGB:') < capture.find('horosPlanarPixelsWidth:'):
    failures.append('captures do not composite the overlay onto the picture read back')
textual = extensions.get('WindowLevel+Coordinates')
if textual is None:
    boxes = '[[HorosAnnotationBox alloc]' in view and 'horosDrawAnnotationBox: studyDateBox' in view
else:
    # The large description stays in DCMView.m; the study number box is Swift.
    boxes = ('[[HorosAnnotationBox alloc]' in view and 'box = AnnotationBox(attributedString:' in textual
             and 'self.horosDraw(studyDateBox, bounds:' in textual)
if not boxes:
    failures.append('the study number box and the large description are not overlay boxes')
if 'AnnotationOverlay.swift in Sources' not in (root / 'Horos.xcodeproj/project.pbxproj').read_text():
    failures.append('AnnotationOverlay.swift is not in the app target')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

accelerated_opengl.require()

W, H = 360, 120
CASES = [
    # text: string, font, size, scale, x, y (top left of the glyphs), white background, inverted
    ['text', 'WL: 40 WW: 400', 'Geneva', 14, 1, 12, 20, False, False],
    ['text', 'Image size: 512 x 512', 'Helvetica', 12, 1, 30, 50, False, False],
    ['text', 'Ågçy 0123 mm', 'Menlo', 11, 1, 7, 70, True, False],
    ['text', 'WL: 40 WW: 400', 'Geneva', 14, 2, 12, 20, False, False],
    ['text', 'Zoom: 250% Angle: 0', 'Helvetica', 12, 2, 3, 30, True, False],
    ['text', 'L', 'Geneva', 14, 2, 150, 40, False, True],
    ['text', 'Original renderer (Metal paused)', 'Helvetica', 12, 1, 40, 80, False, True],
    # box: string, font, size, scale, x, y, box colour, border colour, inverted
    ['box', ' 2 ', 'Helvetica', 20, 1, 5, 4, [0.8, 0.3, 0.1, 1], [0.8, 0.3, 0.1, 1], False],
    ['box', ' 2 ', 'Helvetica', 20, 2, 10, 8, [0.1, 0.5, 0.9, 1], [0.1, 0.5, 0.9, 1], False],
    ['box', 'Study\rSeries', 'Helvetica-Bold', 30, 1, 60.25, 10.75, [0.2, 0.7, 0.3, 0.7], [0.2, 0.7, 0.3, 1], False],
    ['box', 'Series', 'Helvetica-Bold', 30, 2, 40, 6, [0.9, 0.9, 0.2, 0.7], [0.9, 0.9, 0.2, 1], True],
]

REFERENCE = r'''
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import "StringTexture.h"
#import "GLString.h"
static unsigned char background(int x, int y, int c) { return c == 0 ? (x * 7 + y * 3) % 256 : c == 1 ? (x * 2 + y * 5) % 256 : 60 + (x + y) % 120; }
static void texture(GLuint name, const char *path) {
    CGLContextObj cgl_ctx = CGLGetCurrentContext();
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, name); GLint w = 0, h = 0;
    glGetTexLevelParameteriv(GL_TEXTURE_RECTANGLE_EXT, 0, GL_TEXTURE_WIDTH, &w);
    glGetTexLevelParameteriv(GL_TEXTURE_RECTANGLE_EXT, 0, GL_TEXTURE_HEIGHT, &h);
    NSMutableData *d = [NSMutableData dataWithLength: w * h * 4];
    glGetTexImage(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA, GL_UNSIGNED_BYTE, d.mutableBytes);
    [[NSString stringWithFormat: @"%d %d\n", w, h] writeToFile: [NSString stringWithFormat: @"%s.size", path] atomically: NO encoding: NSUTF8StringEncoding error: nil];
    [d writeToFile: [NSString stringWithUTF8String: path] atomically: NO];
}
int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSData *json = [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: argv[1]]];
    NSArray *cases = [NSJSONSerialization JSONObjectWithData: json options: 0 error: nil];
    NSOpenGLPixelFormatAttribute attributes[] = {NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0};
    NSOpenGLContext *context = [[NSOpenGLContext alloc] initWithFormat: [[NSOpenGLPixelFormat alloc] initWithAttributes: attributes] shareContext: nil];
    [context makeCurrentContext];
    CGLContextObj cgl_ctx = context.CGLContextObj;
    GLuint fbo, colour; glGenFramebuffersEXT(1, &fbo); glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    glGenRenderbuffersEXT(1, &colour); glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, colour);
    glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, W, H);
    glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_RENDERBUFFER_EXT, colour);
    if (glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) != GL_FRAMEBUFFER_COMPLETE_EXT) return 3;
    unsigned char *bg = malloc(W * H * 4), *out = malloc(W * H * 4);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (int c = 0; c < 4; c++)
        bg[((H - 1 - y) * W + x) * 4 + c] = c == 3 ? 255 : background(x, y, c);
    int index = 0;
    for (NSArray *k in cases) {
        glViewport(0, 0, W, H);
        glMatrixMode(GL_PROJECTION); glLoadIdentity(); glMatrixMode(GL_MODELVIEW); glLoadIdentity();
        // GLString leaves its row length behind.
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0); glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_FALSE);
        glDisable(GL_BLEND); glWindowPos2i(0, 0); glDrawPixels(W, H, GL_RGBA, GL_UNSIGNED_BYTE, bg);
        glScalef(2.0f / W, -2.0f / H, 1.0f); glTranslatef(-W / 2.0f, -H / 2.0f, 0.0f);
        NSFont *font = [NSFont fontWithName: k[2] size: [k[3] doubleValue]];
        float scale = [k[4] floatValue], x = [k[5] floatValue], y = [k[6] floatValue];
        char path[1024]; snprintf(path, sizeof path, "%s/raster-%d", argv[2], index);
        BOOL inverted;
        if ([k[0] isEqual: @"text"]) {
            StringTexture *tex = [[StringTexture alloc] initWithString: k[1] withAttributes: @{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.whiteColor}];
            [tex setAntiAliasing: YES];
            GLuint name = [tex genTextureWithBackingScaleFactor: scale];
            texture(name, path);
            // drawWithBounds: regenerates the texture at the scale of the
            // context's window, which has none here; its quad, at this scale:
            void (^quad)(float, float) = ^(float left, float top) {
                glBindTexture(GL_TEXTURE_RECTANGLE_EXT, name);
                glBegin(GL_QUADS);
                glTexCoord2f(0, 0); glVertex2f(left, top);
                glTexCoord2f(0, tex.texSize.height); glVertex2f(left, top + tex.texSize.height);
                glTexCoord2f(tex.texSize.width, tex.texSize.height); glVertex2f(left + tex.texSize.width, top + tex.texSize.height);
                glTexCoord2f(tex.texSize.width, 0); glVertex2f(left + tex.texSize.width, top);
                glEnd();
            };
            BOOL white = [k[7] boolValue]; inverted = [k[8] boolValue];
            glEnable(GL_TEXTURE_RECTANGLE_EXT); glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            if (white) glColor4f(1, 1, 1, 1); else glColor4f(0, 0, 0, 1);
            quad(x + 1, y + 1);
            if (white) glColor4f(0, 0, 0, 1); else glColor4f(1, 1, 1, 1);
            quad(x, y);
            glDisable(GL_BLEND); glDisable(GL_TEXTURE_RECTANGLE_EXT);
        } else {
            NSArray *b = k[7], *e = k[8]; inverted = [k[9] boolValue];
            NSAttributedString *text = [[NSAttributedString alloc] initWithString: k[1] attributes: @{NSFontAttributeName: font}];
            GLString *box = [[GLString alloc] initWithAttributedString: text
                withBoxColor: [NSColor colorWithCalibratedRed: [b[0] doubleValue] green: [b[1] doubleValue] blue: [b[2] doubleValue] alpha: [b[3] doubleValue]]
                withBorderColor: [NSColor colorWithDeviceRed: [e[0] doubleValue] green: [e[1] doubleValue] blue: [e[2] doubleValue] alpha: [e[3] doubleValue]]];
            glColor4f(1, 1, 1, 1);
            [box drawWithBounds: NSMakeRect(x, y, box.frameSize.width * scale, box.frameSize.height * scale)];
            texture(box.texName, path);
        }
        if (inverted) {
            glLoadIdentity(); glBlendFunc(GL_ONE_MINUS_DST_COLOR, GL_ZERO); glColor4f(1, 1, 1, 1);
            glEnable(GL_BLEND); glRectf(-1, -1, 1, 1); glDisable(GL_BLEND);
        }
        glFinish();
        glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, out);
        NSMutableData *rgb = [NSMutableData dataWithLength: W * H * 3];
        unsigned char *p = rgb.mutableBytes;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (int c = 0; c < 3; c++)
            p[(y * W + x) * 3 + c] = out[((H - 1 - y) * W + x) * 4 + c];
        snprintf(path, sizeof path, "%s/gl-%d", argv[2], index++);
        [rgb writeToFile: [NSString stringWithUTF8String: path] atomically: NO];
    }
    return 0;
}}
'''.replace('#import <Cocoa/Cocoa.h>\n', '#import <Cocoa/Cocoa.h>\n#define W %d\n#define H %d\n' % (W, H), 1)

DRIVER = r'''
import AppKit

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }
func background(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { UInt8(c == 0 ? (x * 7 + y * 3) % 256 : c == 1 ? (x * 2 + y * 5) % 256 : 60 + (x + y) % 120) }

@main struct Check {
    static func main() throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[Any]]
        let w = WIDTH, h = HEIGHT
        for (index, k) in cases.enumerated() {
            let font = NSFont(name: k[2] as! String, size: CGFloat((k[3] as! NSNumber).doubleValue))!
            let scale = CGFloat((k[4] as! NSNumber).doubleValue), x = CGFloat((k[5] as! NSNumber).doubleValue), y = CGFloat((k[6] as! NSNumber).doubleValue)
            let picture: AnnotationPicture, raster: AnnotationPicture, rect: CGRect, inverted: Bool
            if k[0] as! String == "text" {
                let text = AnnotationText.text(for: k[1] as! String, font: font, scale: scale, cacheToken: "test")
                let white = k[7] as! Bool
                inverted = k[8] as! Bool
                picture = text.picture(text: white ? .black : .white, shadow: white ? .white : .black)
                raster = text.glyphs
                rect = CGRect(x: x, y: y, width: CGFloat(picture.width), height: CGFloat(picture.height))
            } else {
                let b = (k[7] as! [NSNumber]).map { CGFloat($0.doubleValue) }, e = (k[8] as! [NSNumber]).map { CGFloat($0.doubleValue) }
                inverted = k[9] as! Bool
                let box = AnnotationBox(attributedString: NSAttributedString(string: k[1] as! String, attributes: [.font: font]),
                                        boxColor: NSColor(calibratedRed: b[0], green: b[1], blue: b[2], alpha: b[3]),
                                        borderColor: NSColor(deviceRed: e[0], green: e[1], blue: e[2], alpha: e[3]))
                picture = box.picture
                raster = picture
                rect = CGRect(x: x, y: y, width: box.frameSize.width * scale, height: box.frameSize.height * scale)
            }
            try Data(raster.bytes).write(to: URL(fileURLWithPath: "\(args[2])/raster-\(index)"))
            try "\(raster.width) \(raster.height)\n".write(toFile: "\(args[2])/raster-\(index).size", atomically: false, encoding: .utf8)
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for yy in 0..<h { for xx in 0..<w { for c in 0..<3 {
                let v = background(xx, yy, c)
                rgb[(yy * w + xx) * 3 + c] = inverted ? 255 - v : v
            } } }
            rgb.withUnsafeMutableBufferPointer {
                AnnotationOverlay.composite([(inverted ? picture.inverted() : picture, rect)], onto: $0.baseAddress!, width: w, height: h, originX: 0, originY: 0)
            }
            try Data(rgb).write(to: URL(fileURLWithPath: "\(args[2])/overlay-\(index)"))
        }

        // The view: one layer per item, placed in points, the rest hidden.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let overlay = AnnotationOverlay.overlay(for: host)
        expect(AnnotationOverlay.overlay(for: host) === overlay && host.subviews.count == 1, "a second overlay was added")
        expect(overlay.hitTest(NSPoint(x: 10, y: 10)) == nil, "the overlay takes the mouse")
        let text = AnnotationText.text(for: "WL: 40", font: NSFont(name: "Geneva", size: 14)!, scale: 2, cacheToken: "test")
        let box = AnnotationBox(attributedString: NSAttributedString(string: " 1 "), boxColor: .red, borderColor: .red)
        overlay.beginFrame()
        overlay.add(text: text, x: 10, y: 20, textColor: .white, shadowColor: .black)
        overlay.add(box: box, rect: CGRect(x: 4, y: 6, width: box.frameSize.width * 2, height: box.frameSize.height * 2))
        overlay.commit(inverted: false, scale: 2)
        var shown = overlay.layer!.sublayers!.filter { !$0.isHidden }
        expect(shown.count == 2 && overlay.itemCount == 2, "two items gave \(shown.count) layers")
        expect(shown[0].frame == CGRect(x: 5, y: 10, width: CGFloat(text.pixelWidth + 1) / 2, height: CGFloat(text.pixelHeight + 1) / 2) && shown[0].contentsScale == 2,
               "the text layer is at \(shown[0].frame), scale \(shown[0].contentsScale)")
        expect(shown[1].frame == CGRect(x: 2, y: 3, width: box.frameSize.width, height: box.frameSize.height) && shown[1].contentsScale == 1,
               "the box layer is at \(shown[1].frame), scale \(shown[1].contentsScale)")
        overlay.beginFrame()
        overlay.add(text: text, x: 10, y: 20, textColor: .white, shadowColor: .black)
        overlay.commit(inverted: false, scale: 2)
        shown = overlay.layer!.sublayers!.filter { !$0.isHidden }
        expect(shown.count == 1 && overlay.layer!.sublayers!.count == 2, "a shorter frame left \(shown.count) layers shown")
        // A panel collapsed to no size maps its text to NaN; Core Animation
        // throws on such a frame, so the overlay leaves it out.
        overlay.beginFrame()
        overlay.add(text: text, x: .nan, y: .nan, textColor: .white, shadowColor: .black)
        overlay.add(box: box, rect: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))
        overlay.add(text: text, x: 10, y: 20, textColor: .white, shadowColor: .black)
        overlay.commit(inverted: false, scale: 2)
        shown = overlay.layer!.sublayers!.filter { !$0.isHidden }
        expect(shown.count == 1 && overlay.itemCount == 1, "items placed at NaN gave \(shown.count) layers")
        print("DONE")
    }
}
'''.replace('WIDTH', str(W)).replace('HEIGHT', str(H))

with tempfile.TemporaryDirectory(prefix='horos-annotation-overlay-') as name:
    work = Path(name)
    (work / 'cases.json').write_text(json.dumps(CASES))
    # StringTexture left the tree with the CPR labels and GLString with the
    # rest of the app's OpenGL: each reference source is read from the last
    # revision that has it.
    for name in ('StringTexture.h', 'StringTexture.m', 'GLString.h', 'GLString.m'):
        path = 'Horos/Sources/' + name
        reference = history_reference.before_removal(path)
        if reference is None:
            print(f'skipped: needs the history back to {path}; a shallow clone does not carry it', file=sys.stderr)
            sys.exit(2)
        (work / name).write_bytes(history_reference.show(reference, path))
    for source in ('StringTexture.m', 'GLString.m'):
        text = (work / source).read_bytes().decode('latin1')
        text = text.replace('#import "N2Debug.h"', 'static void N2LogStackTrace(NSString *message) { NSLog(@"%@", message); }')
        (work / source).write_text('#import <Cocoa/Cocoa.h>\n' + text)
    (work / 'reference.m').write_text(REFERENCE)
    build = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-Wno-deprecated-declarations', '-w', '-I', str(work), '-I', str(root / 'Horos/Sources'),
                            '-framework', 'Cocoa', '-framework', 'OpenGL', str(work / 'StringTexture.m'), str(work / 'GLString.m'),
                            str(work / 'reference.m'), '-o', str(work / 'reference')])
    if build.returncode:
        print('FAIL: the OpenGL reference does not build')
        raise SystemExit(1)
    (work / 'Check.swift').write_text(DRIVER)
    # Built as Release builds the app, with -Xcc -ffast-math: under it LLVM
    # folds isFinite and isNaN, and the NaN case below would pass here while
    # the app still crashed.
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-Xcc', '-ffast-math', '-parse-as-library', '-suppress-warnings',
                            str(root / 'Horos/Sources/AnnotationOverlay.swift'), str(root / 'Horos/Sources/ROICanvas.swift'),
                            str(work / 'Check.swift'), '-o', str(work / 'check')])
    if build.returncode:
        print('FAIL: the overlay does not build with the driver')
        raise SystemExit(1)
    (work / 'gl').mkdir()
    (work / 'overlay').mkdir()
    if subprocess.run([str(work / 'reference'), str(work / 'cases.json'), str(work / 'gl')], timeout=120).returncode:
        print('FAIL: the OpenGL reference did not draw')
        raise SystemExit(1)
    run = subprocess.run([str(work / 'check'), str(work / 'cases.json'), str(work / 'overlay')], timeout=120, capture_output=True, text=True)
    if run.returncode or 'DONE' not in run.stdout:
        print(run.stdout.strip() or run.stderr.strip() or 'FAIL: the overlay driver failed')
        raise SystemExit(1)
    worst_all, inked_all = 0, 0
    for index, case in enumerate(CASES):
        label = '%s %r %s %s at %sx' % (case[0], case[1], case[2], case[3], case[4])
        size_gl = (work / 'gl' / ('raster-%d.size' % index)).read_text().split()
        size_ov = (work / 'overlay' / ('raster-%d.size' % index)).read_text().split()
        if size_gl != size_ov or (work / 'gl' / ('raster-%d' % index)).read_bytes() != (work / 'overlay' / ('raster-%d' % index)).read_bytes():
            failures.append('%s: the raster is not the OpenGL texture (%s against %s)' % (label, 'x'.join(size_ov), 'x'.join(size_gl)))
            continue
        gl = (work / 'gl' / ('gl-%d' % index)).read_bytes()
        ov = (work / 'overlay' / ('overlay-%d' % index)).read_bytes()
        background = bytearray(W * H * 3)
        inverted = case[8] if case[0] == 'text' else case[9]
        for y in range(H):
            for x in range(W):
                for c, v in enumerate(((x * 7 + y * 3) % 256, (x * 2 + y * 5) % 256, 60 + (x + y) % 120)):
                    background[(y * W + x) * 3 + c] = 255 - v if inverted else v
        inked = sum(1 for i in range(0, len(gl), 3) if gl[i:i + 3] != background[i:i + 3])
        worst = max(abs(a - b) for a, b in zip(gl, ov))
        if inked < 50:
            failures.append('%s: OpenGL drew only %d pixels' % (label, inked))
        if worst > 1:
            differing = sum(1 for a, b in zip(gl, ov) if abs(a - b) > 1)
            failures.append('%s: the overlay differs from OpenGL by %d levels (%d samples above 1)' % (label, worst, differing))
        worst_all, inked_all = max(worst_all, worst), inked_all + inked
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        raise SystemExit(1)
    print('PASS: DCMView draws no text in OpenGL; %d cases: the rasters are the OpenGL textures byte for byte and the '
          'composite is within %d level of OpenGL over %d drawn pixels; the view keeps one layer per item' % (len(CASES), worst_all, inked_all))

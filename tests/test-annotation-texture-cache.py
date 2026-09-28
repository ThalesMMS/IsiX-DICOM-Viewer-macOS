#!/usr/bin/env python3
"""Compile the production annotation text cache with AppKit fonts.

The viewer's strings are rasterized once per string, font, backing scale and
display colour space (`HorosAnnotationText`), and `DrawNSStringGL` picks the
label font for the label list and the annotation font otherwise. Checked: the
choice and the key in `DCMView.m`, and, compiled, that the same key returns the
same picture at the size a texture of that string had, and any other font, size,
scale or colour space a new one.

`<git revision>` as an optional argument reads `DCMView.m` from that revision.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
path = 'Horos/Sources/DCMView.m'
s = (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]) if len(sys.argv) > 1
     else (root / path).read_bytes()).decode('latin1')
draw = s[s.index('- (void)DrawNSStringGL:(NSString*)str :(DCMViewFontKind)fontL :(long)x :(long)y align:'):]
draw = draw[:draw.index('\n}\n')]
if 'NSFont *textureFont = fontL == DCMViewLabelFont ? labelFont : fontGL;' not in draw or \
        'HorosAnnotationText textForString: str font: textureFont scale: sf' not in draw or \
        'cacheToken: [HorosAnnotationPresentation textureCacheTokenForWindow: self.window]' not in draw:
    print('FAIL: DrawNSStringGL does not key its text by font, backing scale and colour space')
    raise SystemExit(1)

DRIVER = r'''
import AppKit

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }

@main struct Check {
    static func main() {
        _ = NSApplication.shared
        let text = "Point 1 / Zoom: 100%"
        let label = NSFont(name: "Helvetica", size: 12)!
        for scale in [1.0, 2.0, 1.0, 2.0] as [CGFloat] {
            for size in [12.0, 20.0, 12.0] as [CGFloat] {
                let annotation = NSFont(name: "Courier", size: size)!
                for font in [label, annotation] {
                    let t = AnnotationText.text(for: text, font: font, scale: scale, cacheToken: "sRGB")
                    let measured = (text as NSString).size(withAttributes: [.font: font])
                    expect(t.pixelWidth == Int(ceil(ceil(measured.width + 8) * scale)), "width \(t.pixelWidth) for \(font) at \(scale)x")
                    expect(t.pixelHeight == Int(ceil(ceil(measured.height + 4) * scale)), "height \(t.pixelHeight) for \(font) at \(scale)x")
                    expect(t === AnnotationText.text(for: text, font: font, scale: scale, cacheToken: "sRGB"), "the same key built a new picture")
                    expect(t !== AnnotationText.text(for: text, font: font, scale: scale, cacheToken: "linear"), "another colour space reused the picture")
                    expect(t !== AnnotationText.text(for: text, font: font, scale: 3 - scale, cacheToken: "sRGB"), "another scale reused the picture")
                }
                expect(AnnotationText.text(for: text, font: label, scale: scale, cacheToken: "sRGB") !==
                       AnnotationText.text(for: text, font: annotation, scale: scale, cacheToken: "sRGB"),
                       "the label and annotation fonts share a picture")
            }
        }
        let kept = AnnotationText.text(for: text, font: label, scale: 2, cacheToken: "sRGB")
        AnnotationText.purgeCache()
        expect(kept !== AnnotationText.text(for: text, font: label, scale: 2, cacheToken: "sRGB"), "a purge kept the picture")
        print("PASS: identical text across annotation/label fonts, 12/20/12 sizes, 1x/2x texture sizes, reuse per font, scale and colour space, and purge")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-annotation-cache-') as d:
    p = Path(d)
    (p / 'Check.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings', str(root / 'Horos/Sources/AnnotationOverlay.swift'),
                    str(root / 'Horos/Sources/ROICanvas.swift'),
                    str(p / 'Check.swift'), '-o', str(p / 'check')], check=True)
    raise SystemExit(subprocess.run([str(p / 'check')]).returncode)

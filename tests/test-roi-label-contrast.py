#!/usr/bin/env python3
"""ROI labels read over any image, and their settings live in the Viewer pane.

A label's text sits on a dark box, and its colour, the ROI's, is lightened
just enough for WCAG's 4.5:1 against that box over a white pixel, the
lightest background it can get. Every colour of the rotation, the dark blue
and grape included, is checked here with HorosROILabelContrast itself, read
from ROI.m's table. Switched off, labels are drawn as before.

The Viewer pane's "ROI labels" group binds the text size, the line thickness
of new ROIs, the colour rotation, the box and its opacity once in each of the
ten localized nibs, without overlapping the other groups.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
roi = (root / 'Horos/Sources/ROI.m').read_bytes().decode('latin1')
table = roi[roi.index('static RGBColor colorRotationTable[10]'):]
table = table[:table.index('};')]
rotation = [tuple(float(v) / 65535 for v in m) for m in
            re.findall(r'\.red=([\d.]+),\s*\.green=([\d.]+),\s*\.blue=([\d.]+)', table)]
assert len(rotation) == 10, rotation

driver = r'''
import AppKit

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!); exit(1) }
}
func rgb(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
    let d = c.usingColorSpace(.deviceRGB)!
    return (d.redComponent, d.greenComponent, d.blueComponent)
}
func contrast(_ c: NSColor, _ box: NSColor) -> CGFloat {
    let (r, g, b) = rgb(c)
    return ROILabelContrast.contrast(ROILabelContrast.luminance(red: r, green: g, blue: b),
                                     ROILabelContrast.worstBackgroundLuminance(box: box))
}

let defaults = UserDefaults.standard
defaults.setVolatileDomain([ROILabelContrast.backgroundKey: false, ROILabelContrast.backgroundOpacityKey: 0.6], forName: UserDefaults.argumentDomain)
check(ROILabelContrast.backgroundOpacity == 0, "switched off, the labels have a box")
defaults.setVolatileDomain([ROILabelContrast.backgroundKey: true, ROILabelContrast.backgroundOpacityKey: 0.6], forName: UserDefaults.argumentDomain)
check(abs(ROILabelContrast.backgroundOpacity - 0.6) < 0.0001, "opacity \(ROILabelContrast.backgroundOpacity)")
defaults.setVolatileDomain([ROILabelContrast.backgroundKey: true, ROILabelContrast.backgroundOpacityKey: 0.01], forName: UserDefaults.argumentDomain)
check(ROILabelContrast.backgroundOpacity == 0.2, "a box too faint to darken anything")
defaults.setVolatileDomain([ROILabelContrast.backgroundKey: true, ROILabelContrast.backgroundOpacityKey: 7], forName: UserDefaults.argumentDomain)
check(ROILabelContrast.backgroundOpacity == 1, "an opacity above one")

let sleeping = ROILabelContrast.boxColor(selected: false, opacity: 0.6)
let selected = ROILabelContrast.boxColor(selected: true, opacity: 0.6)
check(selected.alphaComponent > sleeping.alphaComponent && rgb(selected).0 > rgb(sleeping).0, "the selected box does not stand out")
check(abs(ROILabelContrast.luminance(red: 1, green: 1, blue: 1) - 1) < 0.0001 && ROILabelContrast.luminance(red: 0, green: 0, blue: 0) == 0, "luminance range")
check(abs(ROILabelContrast.contrast(1, 0) - 21) < 0.0001, "white on black is 21:1")

for opacity: CGFloat in [0.45, 0.6, 0.8, 1] {
    for box in [ROILabelContrast.boxColor(selected: false, opacity: opacity), ROILabelContrast.boxColor(selected: true, opacity: opacity)] {
        for (r, g, b) in ROTATION {
            let original = NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
            let text = ROILabelContrast.textColor(for: original, overBox: box)
            // Below about 0.55 not even white reaches it over a white pixel.
            if contrast(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), box) < 4.5 {
                check(rgb(text) == (1, 1, 1) || contrast(original, box) >= 4.5, "unreachable contrast, not white: \(text)")
                continue
            }
            check(contrast(text, box) >= 4.5, "\(original) over \(box): \(contrast(text, box))")
            if contrast(original, box) >= 4.5 {
                check(rgb(text) == rgb(original), "a colour that already reads was changed: \(original)")
            } else {
                // Lightened, not replaced: the strongest channel stays the strongest.
                let o = rgb(original), t = rgb(text)
                let strongest = [o.0, o.1, o.2].firstIndex(of: max(o.0, o.1, o.2))!
                check([t.0, t.1, t.2][strongest] == max(t.0, t.1, t.2), "hue lost: \(original) -> \(text)")
                check(contrast(text, box) < 4.7, "lightened more than needed: \(contrast(text, box))")
            }
        }
    }
}
// No mix can reach the contrast over a box too faint: the text is white.
let faint = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.2)
check(rgb(ROILabelContrast.textColor(for: NSColor(deviceRed: 0, green: 0.38, blue: 0.56, alpha: 1), overBox: faint)) == (1, 1, 1), "faint box")
print("PASS: box opacity and switch, selected box, every rotation colour at 4.5:1 or more, lightened minimally, hue kept")
'''.replace('ROTATION', '[' + ', '.join(f'({r!r}, {g!r}, {b!r})' for r, g, b in rotation) + ']')

with tempfile.TemporaryDirectory(prefix='horos-label-contrast-') as folder:
    main = Path(folder) / 'main.swift'
    main.write_text(driver)
    binary = Path(folder) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'modules'),
                    str(root / 'Horos/Sources/ROILabelContrast.swift'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# ROI.m draws the box and the lightened text for labels and text ROIs, and
# keeps the old drawing when the box is off.
def body(signature):
    start = roi.index(signature)
    return roi[start:roi.index('\n}\n', start)]
assert 'HorosROILabelContrast.backgroundOpacity' in body('- (NSColor*) labelBoxColor')
glstr = body('- (void) glStr: (NSString*) str')
assert 'labelBoxColor' in glstr and 'textColorFor:' in glstr and 'alpha: opacity]' in glstr, 'glStr lost a path'
textual = body('- (void) drawTextualData')
assert 'labelBoxColor' in textual and 'addFillRed: 0.3 green: 0 blue: 0 alpha: 0' in textual, 'the label box or its old path is missing'
assert roi.count('textColorFor:') == 2, 'the text ROI is not lightened'

defaults = (root / 'Horos/Sources/DefaultsOsiriX.m').read_bytes().decode('latin1')
assert 'setObject:@"1" forKey:@"ROILabelBackground"' in defaults
assert 'numberWithFloat: 0.8] forKey:@"ROILabelBackgroundOpacity"' in defaults
app = (root / 'Horos/Sources/AppController.swift').read_text()
assert 'ROILabelContrast.backgroundKey' in app and 'ROILabelContrast.backgroundOpacityKey' in app, 'open viewers are not redrawn'
assert 'name: NSNotification.Name.OsirixLabelGLFontChange' in app[app.index('runPreferencesUpdateCheck'):], 'the size field does not resize the labels'

BINDINGS = {'LabelFONTSIZE': 2, 'ROIThickness': 2, 'ROIColorRotation': 1, 'ROILabelBackground': 2, 'ROILabelBackgroundOpacity': 1}
panes = [root / 'Preference Panes/OSIViewerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')]
panes += [root / 'Horos/Resources' / f'{language}.lproj' for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')]
for pane in panes:
    tree = ET.parse(pane / 'OSIViewerPreferencePanePref.xib')
    group = tree.find('.//box[@id="roi-labels-box"]')
    assert group is not None and group.get('title'), pane.name
    for key, count in BINDINGS.items():
        everywhere = tree.findall(f'.//binding[@keyPath="values.{key}"]')
        inside = group.findall(f'.//binding[@keyPath="values.{key}"]')
        assert len(everywhere) == len(inside) == count, (pane.name, key, len(everywhere), len(inside))
    content = tree.find('.//window/view')
    height = float(content.find('rect').get('height'))
    frames = []
    for box in content.find('subviews').findall('box'):
        r = box.find('rect')
        frames.append((float(r.get('y')), float(r.get('y')) + float(r.get('height')), box.get('id')))
    frames.sort()
    for (_, top, a), (bottom, _, b) in zip(frames, frames[1:]):
        assert top <= bottom, f'{pane.name}: {a} overlaps {b}'
    assert frames[-1][1] <= height, f'{pane.name}: {frames[-1][2]} leaves the pane'
    inner = float(group.find('view/rect').get('width')), float(group.find('view/rect').get('height'))
    for control in group.find('view/subviews'):
        r = control.find('rect')
        x, y, w, h = (float(r.get(k)) for k in ('x', 'y', 'width', 'height'))
        assert x >= 0 and y >= 0 and x + w <= inner[0] and y + h <= inner[1], (pane.name, control.get('id'))
print(f'PASS: label switches registered, ROI.m paths, and the ROI labels group bound in {len(panes)} localizations')

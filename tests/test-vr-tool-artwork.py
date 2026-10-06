#!/usr/bin/env python3
"""The VR scissors and bone removal tools do not look disabled.

In the Volume Rendering "Mouse button function" item the scissors (t3DCut) and
the bone removal (tBonesRemoval) looked dimmed, in the customization palette
and on the bar. Nothing disables them: the cells are enabled in VR.xib, no
code turns them off, and VRView handles both tools. Their artwork is plain
black, drawn as it is, so on a dark toolbar it nearly disappears, like a
disabled control. VRController now gives the two cells template copies of
their artwork, which the matrix draws in the appearance's text colour.

The check reads VRController.mm and both VR.xib files, and draws a bevel cell
of the matrix's kind with the artwork in the dark appearance, as it is and as
a template copy.

`<git revision>` as an optional argument reads the sources from that
revision: that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


def code(text):
    """Without comments, so that what they recall is not taken for code."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


# The cells: enabled, with the black artwork, in the tools matrix of both nibs.
for locale in ('en', 'ja-JP'):
    document = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/VR.xib'))
    matrix = document.find('.//matrix[@id="243"]')
    if matrix is None:
        failures.append(f'{locale}: the tools matrix (243) is gone from VR.xib')
        continue
    cells = {cell.get('tag'): cell for cell in matrix.iter('buttonCell') if cell.get('key') != 'prototype'}
    for tag, image in (('17', '3DCut'), ('21', 'bonesRemoval')):
        cell = cells.get(tag)
        if cell is None or cell.get('image') != image:
            failures.append(f'{locale}: no {image} cell with tag {tag} in the tools matrix')
        elif cell.get('enabled') == 'NO':
            failures.append(f'{locale}: the {image} cell is disabled in VR.xib')

controller = code(read('Horos/Sources/VRController.mm').decode('latin1'))
disabled = re.findall(r'cellWithTag:\s*(?:17|21|t3DCut|tBonesRemoval)\s*\]\s*setEnabled:\s*NO', controller)
if disabled:
    failures.append('VRController disables the scissors or the bone removal cell')
loop = controller.find('for( NSCell *cell in [toolsMatrix cells])')
scissor_state = controller.find('[view updateScissorStateButtons];')
body = controller[loop:loop + 600] if loop >= 0 else ''
if loop < 0 or not (0 <= loop < scissor_state):
    failures.append('VRController does not go through the tools matrix cells when it opens')
else:
    for needle in ('t3DCut', 'tBonesRemoval', 'copy]', 'setTemplate: YES', 'setImage:'):
        if needle not in body:
            failures.append(f'the tools matrix loop lacks {needle}')

harness = r'''
import AppKit
let app = NSApplication.shared
var failures: [String] = []
func luminance(_ image: NSImage, template: Bool, _ appearance: NSAppearance.Name) -> CGFloat {
    let artwork = image.copy() as! NSImage
    artwork.isTemplate = template
    let cell = NSButtonCell(imageCell: artwork)
    cell.bezelStyle = .regularSquare
    cell.setButtonType(.momentaryPushIn)
    cell.imagePosition = .imageOnly
    cell.imageScaling = .scaleProportionallyUpOrDown
    cell.isBordered = false
    let size = NSSize(width: 32, height: 34)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 68, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: appearance)
        cell.draw(withFrame: view.bounds, in: view)
        NSGraphicsContext.restoreGraphicsState()
    }
    var sum: CGFloat = 0, weight: CGFloat = 0
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
            sum += (color.redComponent + color.greenComponent + color.blueComponent) / 3 * color.alphaComponent
            weight += color.alphaComponent
        }
    }
    return weight > 0 ? sum / weight : -1
}
for path in CommandLine.arguments.dropFirst() {
    let image = NSImage(contentsOfFile: path)!
    let name = URL(fileURLWithPath: path).lastPathComponent
    let plain = luminance(image, template: false, .darkAqua)
    let adapted = luminance(image, template: true, .darkAqua)
    // Plain black on a dark bar; the template copy is drawn light.
    if !(plain >= 0 && plain < 0.2) { failures.append("\(name): plain artwork luminance \(plain) in Dark mode") }
    if !(adapted > 0.6) { failures.append("\(name): template artwork luminance \(adapted) in Dark mode") }
    let light = luminance(image, template: true, .aqua)
    if !(light >= 0 && light < 0.4) { failures.append("\(name): template artwork luminance \(light) in Light mode") }
}
for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-vr-tool-artwork-') as folder:
    work = Path(folder)
    (work / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', str(work / 'main.swift'), '-o', str(work / 'harness')],
                   check=True, capture_output=True)
    artwork = [str(root / f'Horos/Resources/Icons/{name}.pdf') for name in ('3DCut', 'bonesRemoval')]
    drawn = subprocess.run([str(work / 'harness'), *artwork], capture_output=True, text=True)
    failures.extend(line.removeprefix('FAIL: ') for line in drawn.stderr.splitlines() if line.startswith('FAIL: '))
    if drawn.returncode and not drawn.stderr.strip():
        failures.append(f'the drawing harness exited {drawn.returncode}')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)

print('PASS: the scissors and bone removal cells are enabled and get template artwork that follows the appearance')

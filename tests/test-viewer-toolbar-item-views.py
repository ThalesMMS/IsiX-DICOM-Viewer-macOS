#!/usr/bin/env python3
"""The 2D viewer's toolbar item views lay out whole at their own size.

`ViewerController` gives each view-backed item a min and max size equal to the
view's frame in Viewer.xib, but the Customize Toolbar panel (and a toolbar that
sizes items by Auto Layout) uses the size the view's constraints fit. When the
constraints do not pin every control, that fitted size differs from the frame
and the controls collapse or overlap:

* Subtraction (#887): its sliders had no width, so the fitted view was 115 pt
  wide instead of 187, the sliders were zero wide and the mask index field ran
  under the Mask button and off the left edge.
* Fusion (#889): the percentage read "-" until a fusion was active, and the
  mode popup was 77 pt, too narrow for "High-Low-High" and "Inverse Log".
* Thick Slab (#890): the popup showed "MIP - Max Intensity Projection" and had
  a 149 pt minimum, the slider a 129 pt minimum, and the item could stretch
  200 pt past its 230 pt frame. The constraints did not pin the height, so the
  fitted view was 0 pt tall. The popup now shows the short name while its menu
  (and the overflow menu copied from it) keeps the full ones.
* Windows Tiling (#893): the popup showed Tiling1x1.pdf, a nearly black
  square that vanished on a dark bar, and its view had no size of its own
  (the constraints fitted 0 x 0). The images are now template grids drawn in
  code, one per arrangement, which AppKit tints for either appearance.
* A view whose only subview is a control (Windows Tiling among them) now
  holds it in a plain holder view (#942), so that the toolbar does not enlarge
  the control; the checks look through such holders.

The nib is neutralised (custom classes other than the ones compiled in here are
dropped, as in test-viewer-slider-hit-target.py) and instantiated for real; the
checks are on laid-out alignment rects, in both locales.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
swift_sources = [root / 'Horos/Sources/HorosCellSlider.swift',
                 root / 'Horos/Sources/ViewerToolbarItemViews.swift',
                 root / 'Horos/Sources/ToolbarMenuBridge.swift']
xibs = [root / 'Horos/Resources/en.lproj/Viewer.xib',
        root / 'Horos/Resources/ja-JP.lproj/Viewer.xib']
for source in [*swift_sources, *xibs]:
    assert source.is_file(), f'missing {source}'

# Toolbar item views checked, by xib id; the outlet names them in the code.
VIEWS = {
    '789': 'subCtrlView',      # Subtraction (#887)
    '475': 'BlendingView',     # Fusion (#889)
    '372': 'FusionView',       # Thick Slab (#890)
    '2536': 'windowsTiling',   # Windows Tiling (#893)
}
KEEP_CLASSES = {'HorosCellSlider', 'HorosCellSliderCell', 'HorosThickSlabModePopUpButtonCell'}

for xib in xibs:
    text = xib.read_text()
    for xid, outlet in VIEWS.items():
        assert f'<outlet property="{outlet}" destination="{xid}"' in text, f'{xib}: {outlet} is no longer view {xid}'


def neutralise(text):
    """Drop the custom classes the probe cannot link and label the item views."""
    text = re.sub(r'\s*customClass="([^"]+)"',
                  lambda m: f' customClass="{m.group(1)}"' if m.group(1) in KEEP_CLASSES else '',
                  text)
    text = text.replace('<customObject id="-2" userLabel="File\'s Owner">',
                        '<customObject id="-2" userLabel="File\'s Owner" customClass="ForgivingOwner">')
    text = text.replace('<customObject id="-1" userLabel="First Responder"/>',
                        '<customObject id="-1" userLabel="First Responder" customClass="FirstResponder"/>')
    for xid in VIEWS:
        start = re.search(r'<customView\b[^>]*\bid="%s"' % xid, text).start()
        end = text.index('</customView>', start)
        block = re.sub(r'<(customView|button|textField|slider|popUpButton)\b([^>]*?)\sid="([^"]+)"',
                       r'<\1\2 id="\3" identifier="xib\3"', text[start:end])
        text = text[:start] + block + text[end:]
    return text


# -blendWindows: shows the slider's percentage whether or not a fusion is active.
blending = (root / 'Horos/Sources/ViewerController+Blending.swift').read_text()
assert 'horos_blendingPercentage?.stringValue = "-"' not in blending, \
    'turning fusion off must keep the percentage, not write "-" (#889)'
assert blending.count('self.horos_blendingPercentage?.isEnabled = ') == 2, \
    'the percentage must be enabled and dimmed with the fusion slider (#889)'

# The Thick Slab item no longer stretches past its frame (#890).
toolbar = (root / 'Horos/Sources/ViewerController+Toolbar.swift').read_text()
thick_slab = toolbar[toolbar.index('itemIdent == FusionToolbarItemIdentifier {'):]
thick_slab = thick_slab[:thick_slab.index('} else if')]
assert 'setView(self.horos_FusionView)' in thick_slab, 'the Thick Slab item must take its view\'s frame as its size (#890)'
assert 'extraMaxWidth' not in toolbar, 'no toolbar item may stretch past its view\'s frame (#890)'

# The tiling popup's images come from code, not from the dark PDFs (#893).
tiling = toolbar[toolbar.index('itemIdent == WindowsTilingToolbarItemIdentifier {'):]
tiling = tiling[:tiling.index('} else if')]
assert 'WindowsTilingImage.install(in: self.horos_windowsTiling)' in tiling, \
    'the Windows Tiling item must draw its arrangement images (#893)'
for xib in xibs:
    assert not re.search(r'image="Tiling\dx\d"', xib.read_text()), f'{xib}: the tiling menu still names the old artwork (#893)'
assert not (root / 'Horos/Resources/Icons/Tiling').exists(), 'the unused tiling artwork is still in the tree (#893)'

owner_header = '''
#import <AppKit/AppKit.h>
@interface ForgivingOwner : NSObject
@property (nonatomic, strong) NSMutableDictionary *values;
- (IBAction) activateFusion: (id) sender;
- (IBAction) popFusionAction: (id) sender;
- (IBAction) sliderFusionAction: (id) sender;
@end
'''

owner_source = '''
#import "Owner.h"
@implementation ForgivingOwner
- (instancetype) init { if ((self = [super init])) { _values = [NSMutableDictionary new]; } return self; }
- (void) setValue:(id)value forUndefinedKey:(NSString *)key { if (value) _values[key] = value; }
- (id) valueForUndefinedKey:(NSString *)key { return _values[key]; }
- (void) setNilValueForKey:(NSString *)key {}
- (IBAction) activateFusion: (id) sender {}
- (IBAction) popFusionAction: (id) sender {}
- (IBAction) sliderFusionAction: (id) sender {}
@end
'''

code = r'''
import AppKit

var failures: [String] = []
func fail(_ message: String) { failures.append(message) }

func name(_ view: NSView) -> String {
    var title = ""
    if let button = view as? NSButton { title = button.title }
    else if let field = view as? NSTextField { title = field.stringValue }
    return "\(view.identifier?.rawValue ?? "?") \(type(of: view)) \"\(title)\""
}

/// The controls of a toolbar item view, through the plain views that hold them.
func parts(of view: NSView) -> [NSView] {
    view.subviews.flatMap { type(of: $0) == NSView.self ? parts(of: $0) : [$0] }
}

_ = NSApplication.shared
let expected = Set(CommandLine.arguments[2].split(separator: ",").map { "xib" + $0 })

for path in CommandLine.arguments[1].split(separator: ",").map(String.init) {
    let owner = ForgivingOwner()
    var top: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
    guard nib.instantiate(withOwner: owner, topLevelObjects: &top) else {
        print("FAIL: \(path): nib did not instantiate"); exit(1)
    }
    var seen = Set<String>()
    for case let view as NSView in (top as! [Any]) {
        guard let id = view.identifier?.rawValue, expected.contains(id) else { continue }
        seen.insert(id)
        let where_ = "\(path.split(separator: "/").last!) \(id)"
        let designed = view.frame.size

        // The size Auto Layout fits must be the frame the item's min/max size
        // come from, or the panel and the bar show two different layouts. It
        // is rounded to the main screen's pixels, so allow one point.
        view.translatesAutoresizingMaskIntoConstraints = false
        let fitting = view.fittingSize
        if abs(fitting.width - designed.width) > 1 || abs(fitting.height - designed.height) > 1 {
            fail("\(where_): constraints fit \(fitting), the xib frame is \(designed)")
        }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.setFrameSize(designed)
        view.layoutSubtreeIfNeeded()
        if view.hasAmbiguousLayout { fail("\(where_): ambiguous layout") }

        let bounds = view.bounds.insetBy(dx: -0.5, dy: -0.5)
        // A lone control sits in a holder view that fills the item (#942):
        // the controls are looked for through such plain views.
        let rects = parts(of: view).map { ($0, $0.superview!.convert($0.alignmentRect(forFrame: $0.frame), to: view)) }
        for (index, (sub, rect)) in rects.enumerated() {
            if !bounds.contains(rect) { fail("\(where_): \(name(sub)) at \(rect) leaves the item") }
            let intrinsic = sub.intrinsicContentSize
            if intrinsic.width > 0 && rect.width + 0.5 < intrinsic.width {
                fail("\(where_): \(name(sub)) is \(rect.width) wide, its content needs \(intrinsic.width)")
            }
            if sub is NSSlider && rect.width < 40 { fail("\(where_): \(name(sub)) is only \(rect.width) wide") }
            for (other, otherRect) in rects[..<index]
            where rect.insetBy(dx: 0.5, dy: 0.5).intersects(otherRect.insetBy(dx: 0.5, dy: 0.5)) {
                fail("\(where_): \(name(sub)) overlaps \(name(other))")
            }
        }
        if id == "xib475" {
            // Fusion: a percentage, dimmed with its slider while no fusion is active.
            let slider = view.subviews.compactMap { $0 as? NSSlider }.first!
            let percent = view.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "xib481" }!
            if percent.stringValue != String(format: "%0.0f%%", (slider.doubleValue + 256) / 5.12) {
                fail("\(where_): the percentage reads \"\(percent.stringValue)\" for a slider at \(slider.doubleValue)")
            }
            if percent.isEnabled != slider.isEnabled { fail("\(where_): the percentage is not dimmed with its slider") }
            let widest = NSTextField(labelWithString: "100%")
            widest.font = percent.font
            if widest.intrinsicContentSize.width > percent.alignmentRect(forFrame: percent.frame).width + 0.5 {
                fail("\(where_): \"100%\" does not fit the percentage field")
            }
        }
        if id == "xib372" {
            // Thick Slab: compact, a short mode name, full names in the menus.
            if view.bounds.width > 160 { fail("\(where_): Thick Slab is \(view.bounds.width) pt wide") }
            let popup = view.subviews.compactMap { $0 as? NSPopUpButton }.first!
            if !(popup.cell is ThickSlabModePopUpButtonCell) { fail("\(where_): the mode popup is a stock NSPopUpButtonCell") }
            let full = [1: "Mean", 2: "MIP - Max Intensity Projection", 3: "MinIP - Min Intensity Projection",
                        4: "Volume Rendering - Up", 5: "Volume Rendering - Down"]
            let short = [1: "Mean", 2: "MIP", 3: "MinIP", 4: "VR Up", 5: "VR Down"]
            if popup.selectedTag() != 2 || popup.title != "MIP" {
                fail("\(where_): the popup opens on \"\(popup.title)\" (tag \(popup.selectedTag())), not MIP")
            }
            for (tag, name) in full {
                if popup.menu?.item(withTag: tag)?.title != name { fail("\(where_): menu item \(tag) is not \"\(name)\"") }
                popup.selectItem(withTag: tag)
                view.layoutSubtreeIfNeeded()
                let rect = popup.alignmentRect(forFrame: popup.frame)
                if popup.selectedTag() != tag || popup.selectedItem?.title != name || popup.title != short[tag]! {
                    fail("\(where_): selecting \(tag) shows \"\(popup.title)\", selects \(popup.selectedTag())")
                }
                if popup.intrinsicContentSize.width > rect.width + 0.5 { fail("\(where_): \"\(popup.title)\" does not fit the popup") }
                if popup.toolTip != name { fail("\(where_): the popup's tooltip is \(popup.toolTip ?? "nil") for \(name)") }
            }
            popup.selectItem(at: popup.indexOfItem(withTag: 3))
            if popup.title != "MinIP" { fail("\(where_): selectItem(at:) shows \"\(popup.title)\"") }
            popup.selectItem(withTag: 2)
            // Overflow still offers every mode, by its full name, and the checkbox.
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Fusion"))
            item.label = "Thick Slab"
            item.view = view
            ToolbarMenuBridge.install(for: item)
            let commands = ToolbarMenuBridge.overflowCommands(for: item)
            for (tag, name) in full where !commands.contains(where: { $0.title == name && $0.tag == tag && $0.action != nil }) {
                fail("\(where_): overflow lost \"\(name)\"")
            }
            if !commands.contains(where: { $0.title == "Mode:" && $0.action != nil }) { fail("\(where_): overflow lost the Mode checkbox") }
        }
        if id == "xib2536" {
            // Windows Tiling: one template grid per arrangement, rows * 10 + columns.
            WindowsTilingImage.install(in: view)
            let popup = parts(of: view).compactMap { $0 as? NSPopUpButton }.first!
            if popup.itemArray.count != 11 { fail("\(where_): \(popup.itemArray.count) arrangements, expected 11") }
            for item in popup.itemArray {
                let rows = item.tag / 10, columns = item.tag % 10
                guard let image = item.image else { fail("\(where_): arrangement \(item.tag) has no image"); continue }
                if !image.isTemplate { fail("\(where_): arrangement \(item.tag) is not a template image") }
                if image.accessibilityDescription != "\(rows) × \(columns)" { fail("\(where_): arrangement \(item.tag) is described as \(image.accessibilityDescription ?? "nil")") }
                // Count the windows drawn across the middle of the first row
                // and down the middle of the first column.
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 44, bitsPerSample: 8,
                                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: NSRect(x: 0, y: 0, width: 60, height: 44))
                NSGraphicsContext.restoreGraphicsState()
                func runs(_ points: [(Int, Int)]) -> Int {
                    var count = 0, inside = false
                    for (x, y) in points {
                        let opaque = (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                        if opaque && !inside { count += 1 }
                        inside = opaque
                    }
                    return count
                }
                let firstRow = Int(2 + (40.0 / Double(rows)) / 2), firstColumn = Int(2 + (56.0 / Double(columns)) / 2)
                let across = runs((0..<60).map { ($0, firstRow) }), down = runs((0..<44).map { (firstColumn, $0) })
                if across != columns || down != rows {
                    fail("\(where_): arrangement \(item.tag) draws \(down) x \(across) windows")
                }
            }
            popup.selectItem(withTag: 22)
            if popup.selectedItem?.image?.accessibilityDescription != "2 × 2" { fail("\(where_): the popup does not show the selected arrangement") }
        }
        // A margin on both sides, so nothing touches the item's edge.
        if let left = rects.map({ $0.1.minX }).min(), left < 2 { fail("\(where_): a control starts \(left) pt from the left edge") }
        if let right = rects.map({ $0.1.maxX }).max(), right > view.bounds.width - 2 {
            fail("\(where_): a control ends \(view.bounds.width - right) pt from the right edge")
        }
    }
    for id in expected.subtracting(seen) { fail("\(path): view \(id) not found") }
}

if !failures.isEmpty {
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}
'''

with tempfile.TemporaryDirectory(prefix='horos-viewer-toolbar-items-') as folder:
    folder = Path(folder)
    (folder / 'Owner.h').write_text(owner_header)
    (folder / 'Owner.m').write_text(owner_source)
    (folder / 'main.swift').write_text(code)
    nibs = []
    for xib in xibs:
        source = folder / f'{xib.parent.name}.xib'
        compiled = folder / f'{xib.parent.name}.nib'
        source.write_text(neutralise(xib.read_text()))
        subprocess.run(['ibtool', '--compile', str(compiled), str(source)], check=True)
        nibs.append(str(compiled))
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5',
        '-import-objc-header', str(folder / 'Owner.h'),
        *[str(s) for s in swift_sources], str(folder / 'Owner.m'), str(folder / 'main.swift'),
        '-framework', 'AppKit',
        '-o', str(folder / 'test'),
    ], check=True)
    # Missing artwork is logged by AppKit; it is not what this test checks.
    result = subprocess.run([str(folder / 'test'), ','.join(nibs), ','.join(VIEWS)],
                            capture_output=True, text=True)
    print(result.stdout, end='')
    if result.returncode != 0:
        raise SystemExit(result.returncode)

print('PASS: the 2D toolbar item views fit their frames with every control whole, in both locales')

#!/usr/bin/env python3
"""Compile the real Viewer preference controls and check their bindings and layout.

Exercise every localized nib geometry with all twelve catalog translations,
including preference changes, inverse percentage mapping and popup choices.
The AppKit controls are instantiated without showing a window.
"""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PANE = ROOT / 'Preference Panes/OSIViewerPreferencePane/OSIViewerPreferencePanePref.swift'
source = PANE.read_text()
method = source[source.index('    private func addViewerInteractionControls()'):source.index('    /// The field shows the name')]
transformer = source[source.index('private final class ViewerMouseFactorTransformer:'):]
assert '        addViewerInteractionControls()' in source
keys = ['Remember MPR plane angles', 'Precise mouse for measuring and zoom', 'Mouse movement:',
        'Identify series in the list by:', 'Colors', 'Numbers', 'Colors and numbers',
        'Exponential thick slab slider', 'Series %@', 'Window %ld']
import sys  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.registered()
for key, value in {'RememberMPRPlaneAngles': False, 'PreciseMouseForMeasuringAndZoom': False,
                   'PreciseMouseFactor': 0.5, 'SeriesListIdentificationMode': 0,
                   'LogarithmicThickSlabSlider': False}.items():
    assert type(defaults.get(key)) is type(value) and defaults[key] == value, key

catalogs = {}
for path in sorted((ROOT / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    data = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'binary1', '-o', '-', str(path)]))
    for key in keys:
        assert data.get(key), f'{path.parent.name}: missing {key}'
        assert re.findall(r'%[@a-z]+', data[key]) == re.findall(r'%[@a-z]+', key), (path, key)
    catalogs[path.parent.stem] = {key: data[key] for key in keys}
assert len(catalogs) == 12

def rect(element):
    return [float(element.get(k, '0')) for k in ('x', 'y', 'width', 'height')]

variants = []
paths = sorted((ROOT / 'Preference Panes/OSIViewerPreferencePane').glob('*.lproj/OSIViewerPreferencePanePref.xib'))
paths += sorted((ROOT / 'Horos/Resources').glob('*.lproj/OSIViewerPreferencePanePref.xib'))
for path in paths:
    document = ET.parse(path).getroot()
    content = document.find('.//window/view[@key="contentView"]')
    boxes = []
    for box in content.findall('./subviews/box'):
        inner = box.find('./view[@key="contentView"]')
        children = []
        for child in inner.findall('./subviews/*'):
            frame = child.find('./rect[@key="frame"]')
            if frame is not None:
                children.append({'frame': rect(frame), 'anchor': child.find('.//binding[@keyPath="values.onlyDisplayImagesOfSamePatient"]') is not None})
        boxes.append({'frame': rect(box.find('./rect[@key="frame"]')), 'inner': rect(inner.find('./rect[@key="frame"]')), 'children': children})
    assert any(c['anchor'] for b in boxes for c in b['children']), path
    variants.append({'name': str(path.relative_to(ROOT)), 'frame': rect(content.find('./rect[@key="frame"]')), 'boxes': boxes})

preamble = r'''
import AppKit
var catalog: [String: String] = [:]
func NSLocalizedString(_ key: String, comment: String) -> String { catalog[key] ?? key }
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
@MainActor final class Probe: NSObject {
    var mainWindow: NSWindow?
    func build() { addViewerInteractionControls() }
'''
driver = r'''
func rect(_ values: Any) -> NSRect {
    let a = values as! [Double]
    return NSRect(x: a[0], y: a[1], width: a[2], height: a[3])
}
MainActor.assumeIsolated {
let input = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let catalogs = input["catalogs"] as! [String: [String: String]]
let variants = input["variants"] as! [[String: Any]]
_ = NSApplication.shared
let pref = NSUserDefaultsController.shared
let values: [String: Any] = ["RememberMPRPlaneAngles": false, "PreciseMouseForMeasuringAndZoom": false,
                           "PreciseMouseFactor": 0.5, "SeriesListIdentificationMode": 0, "LogarithmicThickSlabSlider": false]
for (key, value) in values { pref.setValue(value, forKeyPath: "values." + key) }
for (language, translations) in catalogs {
    catalog = translations
    for variant in variants {
        let context = language + " " + (variant["name"] as! String)
        let probe = Probe()
        let content = NSView(frame: rect(variant["frame"]!))
        let window = NSWindow(contentRect: content.frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView = content
        probe.mainWindow = window
        var target: NSBox!
        for b in variant["boxes"] as! [[String: Any]] {
            let box = NSBox(frame: rect(b["frame"]!))
            let inner = NSView(frame: rect(b["inner"]!))
            box.contentView = inner
            content.addSubview(box)
            for c in b["children"] as! [[String: Any]] {
                let view: NSView
                if c["anchor"] as! Bool {
                    let button = NSButton(checkboxWithTitle: "anchor", target: nil, action: nil)
                    button.bind(.value, to: pref, withKeyPath: "values.onlyDisplayImagesOfSamePatient", options: nil)
                    view = button
                    target = box
                } else { view = NSView() }
                view.frame = rect(c["frame"]!)
                inner.addSubview(view)
            }
        }
        let inner = target.contentView!
        let oldViews = inner.subviews
        let oldFrames = oldViews.map(\.frame)
        let oldHeight = content.frame.height
        let lowerBoxes = content.subviews.filter { $0.frame.maxY <= target.frame.minY }
        let lowerFrames = lowerBoxes.map(\.frame)
        probe.build()
        let added = inner.subviews.filter { view in !oldViews.contains { $0 === view } }
        check(added.count == 7, context + " all controls")
        check(content.frame.height == oldHeight + 112, context + " scroll content growth")
        for (view, frame) in zip(oldViews, oldFrames) {
            check(view.frame == frame.offsetBy(dx: 0, dy: 112), context + " existing controls preserved")
        }
        for (view, frame) in zip(lowerBoxes, lowerFrames) { check(view.frame == frame, context + " lower section unchanged") }
        for view in added {
            check(inner.bounds.contains(view.frame), context + " control outside box: " + view.description)
            for old in oldViews { check(!view.frame.intersects(old.frame), context + " old control overlap") }
            if let button = view as? NSButton, !(button is NSPopUpButton) {
                check(button.fittingSize.width <= button.frame.width + 1, context + " truncated: " + button.title)
            }
            for other in added where other !== view { check(!view.frame.intersects(other.frame), context + " new control overlap") }
        }
        let popups = added.compactMap { $0 as? NSPopUpButton }
        let factor = popups.first { ($0.infoForBinding(.selectedTag)?[.observedKeyPath] as? String) == "values.PreciseMouseFactor" }!
        let series = popups.first { ($0.infoForBinding(.selectedTag)?[.observedKeyPath] as? String) == "values.SeriesListIdentificationMode" }!
        check(factor.selectedTag() == 50 && !factor.isEnabled, context + " default mouse factor/disabled")
        check(series.selectedTag() == 0, context + " default colors")
        check(series.itemArray.map(\.tag) == [0, 1, 2], context + " series choices")
        check(factor.itemArray.map(\.tag) == [25, 50, 75], context + " percentage choices")
        pref.setValue(true, forKeyPath: "values.PreciseMouseForMeasuringAndZoom")
        check(factor.isEnabled, context + " mouse factor enabled")
        for percentage in [25, 50, 75] {
            pref.setValue(Double(percentage) / 100, forKeyPath: "values.PreciseMouseFactor")
            check(factor.selectedTag() == percentage, context + " factor binding")
            let inverse = ViewerMouseFactorTransformer().reverseTransformedValue(percentage) as! NSNumber
            check(inverse.doubleValue == Double(percentage) / 100, context + " reverse factor binding")
        }
        for mode in [0, 1, 2] {
            pref.setValue(mode, forKeyPath: "values.SeriesListIdentificationMode")
            check(series.selectedTag() == mode, context + " series binding")
        }
        series.selectItem(withTag: 1)
        series.sendAction(series.action, to: series.target)
        check((pref.value(forKeyPath: "values.SeriesListIdentificationMode") as! NSNumber).intValue == 1, context + " series selection persisted")
        factor.selectItem(withTag: 25)
        factor.sendAction(factor.action, to: factor.target)
        check((pref.value(forKeyPath: "values.PreciseMouseFactor") as! NSNumber).doubleValue == 0.25, context + " percentage selection persisted")
        for view in added {
            for binding in [NSBindingName.value, .selectedTag, .enabled] where view.infoForBinding(binding) != nil { view.unbind(binding) }
        }
        for view in oldViews where view.infoForBinding(.value) != nil { view.unbind(.value) }
        for (key, value) in values { pref.setValue(value, forKeyPath: "values." + key) }
        probe.mainWindow = nil
    }
}
print("PASS: twelve languages, all nib layouts, persistent bindings, percentages and mode choices")
}
'''
with tempfile.TemporaryDirectory(prefix='viewer-interaction-preferences-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(preamble + method + '}\n' + transformer + driver)
    (folder / 'input.json').write_text(json.dumps({'catalogs': catalogs, 'variants': variants}))
    executable = folder / 'preferences-test'
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(folder / 'modules'),
                    str(folder / 'main.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(folder / 'input.json')], check=True)

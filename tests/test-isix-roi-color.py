#!/usr/bin/env python3
"""A plugin's ROI colour and opacity reach the application's ROI and come back.

IsiXViewerAdapter gives a ROI the colour and opacity of a plugin's draft or
update with applyStyle, and reads them back into the plugin's IsiXROI with
pluginColor and the ROI's opacity. Those parts of the adapter are taken as
they stand from IsiXViewerAdapter.swift, and the ROI's own setColor(_:globally:)
and setOpacity(_:globally:) from ROI.swift, and compiled with swiftc, with the
plugin kit's sources, over a ROI that has only what those setters touch.
Checked:

* a colour and an opacity set on a ROI, of an outline or a brush, read back
  as set, within the 16 bits the application keeps a component in;
* nil leaves the ROI's colour and opacity as they were, and a later change
  of one leaves the other;
* the colour and opacity a new ROI gets from the preferences stay as they
  were: a plugin's ROI does not change the next one the user draws;
* addROI, the brush path of addROI and updateROI apply the draft's or the
  update's colour and opacity, and the ROI handed back reports them.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / 'Horos/Sources/IsiXViewerAdapter.swift'
ROI_SOURCE = ROOT / 'Horos/Sources/ROI.swift'
KIT = sorted((ROOT / 'IsiXPluginKit/Sources').glob('*.swift'))
failures = []


def extract(text, pattern, what):
    found = re.search(pattern, text, re.S | re.M)
    if not found:
        raise SystemExit(f'FAIL: no {what}')
    return found.group(0)


adapter = ADAPTER.read_text(encoding='utf-8')
style = extract(adapter, r'^    /// The application keeps each colour component with 16 bits\.\n.*?(?=^    private func snapshot)',
                'style helpers in IsiXViewerAdapter.swift')
roi = ROI_SOURCE.read_text(encoding='utf-8')
setters = [extract(roi, r'^    @objc\(setOpacity:globally:\)\n.*?^    \}\n', 'setOpacity(_:globally:) in ROI.swift'),
           extract(roi, r'^    @objc\(setColor:globally:\)\n.*?^    \}\n', 'setColor(_:globally:) in ROI.swift')]
setters = [s.replace('@objc(setOpacity:globally:)\n', '').replace('@objc(setColor:globally:)\n', '') for s in setters]

# Each path that makes or changes a ROI for a plugin applies its colour and
# opacity, and the snapshot it answers with reports them.
paths = {
    'addROI': (r'^    func addROI\(_ draft: IsiXROIDraft\) throws -> IsiXROI \{\n.*?^    \}\n',
               'Self.applyStyle(color: draft.color, opacity: draft.opacity, to: roi)'),
    'addBrush': (r'^    private func addBrush\(.*?^    \}\n', 'Self.applyStyle(color: draft.color, opacity: draft.opacity, to: roi)'),
    'updateROI': (r'^    func updateROI\(_ id: IsiXROIID, _ update: IsiXROIUpdate\) throws -> IsiXROI \{\n.*?^    \}\n',
                  'Self.applyStyle(color: update.color, opacity: update.opacity, to: roi)'),
    'snapshot': (r'^    private func snapshot\(.*?^    \}\n', 'color: Self.pluginColor(roi.rgbcolor), opacity: Double(roi.opacity)'),
}
for name, (pattern, call) in paths.items():
    body = extract(adapter, pattern, name)
    if call not in body:
        failures.append(f'{name} does not have {call}')
    elif name != 'snapshot' and body.index(call) > body.rindex('return '):
        failures.append(f'{name} applies the style after it answers')

PROGRAM = r'''
import AppKit

struct RGBColor: Equatable {
    var red: UInt16 = 0, green: UInt16 = 0, blue: UInt16 = 0
}
enum ToolMode { case tROI, tPlain, tText, tLayerROI }
struct ROISettings {
    var opacity: Float = 0.5, regionOpacity: Float = 0.5
    var colorR: Float = 0, colorG: Float = 65535, colorB: Float = 0
    var regionColorR: Float = 0, regionColorG: Float = 65535, regionColorB: Float = 0
    var textColorR: Float = 65535, textColorG: Float = 65535, textColorB: Float = 65535
}

final class ROI {
    nonisolated(unsafe) static var settings = ROISettings()
    var _type: ToolMode
    var _opacity: Float
    var color: RGBColor
    var _canColorizeLayer = false
    var layerColor: NSColor?
    init(_ type: ToolMode) {
        _type = type
        _opacity = type == .tPlain ? ROI.settings.regionOpacity : ROI.settings.opacity
        color = RGBColor(red: 0, green: 65535, blue: 0)
    }
    var rgbcolor: RGBColor { color }
    var opacity: Float { _opacity }
    func forgetLayerPixels() {}
SETTERS
}

enum Adapter {
STYLE
}

func describe(_ roi: ROI) -> String {
    let c = Adapter.pluginColor(roi.rgbcolor)
    return String(format: "%.6f,%.6f,%.6f %.3f", c.red, c.green, c.blue, roi.opacity)
}

var lines: [String] = []
for type in [ToolMode.tROI, .tPlain] {
    let roi = ROI(type)
    Adapter.applyStyle(color: nil, opacity: nil, to: roi)
    lines.append("\(type) default " + describe(roi))
    Adapter.applyStyle(color: IsiXROIColor(red: 1, green: 0.5, blue: 0.2), opacity: 0.25, to: roi)
    lines.append("\(type) set " + describe(roi))
    Adapter.applyStyle(color: IsiXROIColor(red: 0, green: 0, blue: 1), opacity: nil, to: roi)
    lines.append("\(type) recolour " + describe(roi))
    Adapter.applyStyle(color: nil, opacity: 0.75, to: roi)
    lines.append("\(type) opacity " + describe(roi))
}
let s = ROI.settings
lines.append("settings \(s.opacity) \(s.regionOpacity) \(s.colorR),\(s.colorG),\(s.colorB) \(s.regionColorR),\(s.regionColorG),\(s.regionColorB)")
// Every 16-bit component comes back as it went.
let exact = (0...65535).allSatisfy { Adapter.hostColor(Adapter.pluginColor(RGBColor(red: UInt16($0), green: 0, blue: 0))).red == UInt16($0) }
lines.append("exact \(exact)")
print(lines.joined(separator: "\n"))
'''

with tempfile.TemporaryDirectory(prefix='isix-roi-color-') as temporary:
    work = Path(temporary)
    program = work / 'main.swift'
    program.write_text(PROGRAM.replace('SETTERS', ''.join(setters)).replace('STYLE', style))
    binary = work / 'probe'
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Probe', '-o', str(binary),
                            str(program), *map(str, KIT)], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-3000:])
        sys.exit(1)
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        failures.append(f'probe exited {run.returncode}: {run.stderr[-1000:]}')
    lines = run.stdout.splitlines()
    expected = [
        'tROI default 0.000000,1.000000,0.000000 0.500',
        'tROI set 1.000000,0.500008,0.200000 0.250',
        'tROI recolour 0.000000,0.000000,1.000000 0.250',
        'tROI opacity 0.000000,0.000000,1.000000 0.750',
        'tPlain default 0.000000,1.000000,0.000000 0.500',
        'tPlain set 1.000000,0.500008,0.200000 0.250',
        'tPlain recolour 0.000000,0.000000,1.000000 0.250',
        'tPlain opacity 0.000000,0.000000,1.000000 0.750',
        'settings 0.5 0.5 0.0,65535.0,0.0 0.0,65535.0,0.0',
        'exact true',
    ]
    if lines != expected:
        failures.append('probe answered:\n' + '\n'.join(lines))

if failures:
    print('FAIL\n' + '\n'.join(failures))
    sys.exit(1)
print('a plugin\'s ROI colour and opacity reach the ROI and come back; nil keeps them; the preferences stay')

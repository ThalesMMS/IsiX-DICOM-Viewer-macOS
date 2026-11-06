#!/usr/bin/env python3
"""A series with missing slice positions opens again with empty slices in them.

Compiles SliceGapFill.swift (IsiXImaging) with a driver on synthetic stacks:
a 1.25 mm stack missing one slice and then three in a row gets one and three
empty slices and becomes regular; a descending stack too; a regular stack has
no gaps; a gap of 1.5 intervals and two slices at one position are refused;
the filled volume keeps the original pixels and holds only the fill value in
the empty slices. Then checks the wiring: 2D Viewer > Fill Spacing Gaps after
Split Series by b-value, sent to the main menu's ViewerStudyCommands and
enabled only for irregular slices, the Fill Gaps button of the irregular
interval warning, the empty slices marked by their missingPixelsReason, and
the file compiled into the app.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
fill_source = root / 'Modules/IsiXImaging/Sources/SeriesOperations/SliceGapFill.swift'


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


driver = r'''
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}
func plan(_ positions: [Double]) -> SliceGapFill? {
    if case .fill(let fill) = SliceGapFill.plan(positions: positions) { return fill }
    return nil
}
func filledPositions(_ fill: SliceGapFill, _ original: [Double]) -> [Double] {
    fill.slices.map { slice -> Double in
        switch slice {
        case .original(let i): return original[i]
        case let .empty(_, _, position): return position
        }
    }
}
func regular(_ positions: [Double], _ step: Double) -> Bool {
    (1..<positions.count).allSatisfy { abs(positions[$0] - positions[$0 - 1] - step) < 1e-9 }
}

let missing: Set<Int> = [5, 20, 21, 22]
let ascending = (0..<40).filter { !missing.contains($0) }.map { Double($0) * 1.25 - 30 }
guard let up = plan(ascending) else { check(false, "a stack with gaps is filled"); exit(1) }
check(up.slices.count == 40 && up.emptyCount == 4, "one empty slice per missing position")
check(up.slices.indices.filter { up.slices[$0].isEmpty } == [5, 20, 21, 22], "the empty slices are where the slices are missing")
check(regular(filledPositions(up, ascending), 1.25), "the filled stack is regular")

let descending = ascending.reversed().map { $0 }
guard let down = plan(descending) else { check(false, "a descending stack is filled"); exit(1) }
check(regular(filledPositions(down, descending), -1.25), "the filled descending stack is regular")

check(SliceGapFill.plan(positions: (0..<10).map { Double($0) * 2 }) == .noGaps(step: 2), "a regular stack has no gaps")
if case .refused(.notMultiple) = SliceGapFill.plan(positions: [0, 1, 2, 3, 4.5, 5.5, 6.5]) {} else {
    check(false, "a gap of 1.5 intervals is refused")
}
check(SliceGapFill.plan(positions: [0, 1, 1, 2]) == .refused(.coincidentSlices), "slices at one position are refused")

let small = [0.0, 1.25, 3.75]
guard let three = plan(small) else { check(false, "three slices with a gap are filled"); exit(1) }
let source: [Float] = [1, 2, 3, 4, 5, 6]
var volume = [Float](repeating: .nan, count: 8)
source.withUnsafeBufferPointer { s in
    volume.withUnsafeMutableBufferPointer { v in
        three.fillVolume(source: s.baseAddress!, sliceFloatCount: 2, into: v.baseAddress!, fillValue: -2048)
    }
}
check(volume == [1, 2, 3, 4, -2048, -2048, 5, 6], "the volume keeps the originals and fills the empty slice")
print("PASS: gaps found and filled on synthetic stacks")
'''

with tempfile.TemporaryDirectory(prefix='horos-gap-fill-') as tmp:
    work = Path(tmp)
    (work / 'main.swift').write_text(driver)
    if subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(fill_source),
                       str(work / 'main.swift'), '-o', str(work / 'check')]).returncode:
        fail('SliceGapFill.swift does not build with the driver')
    if subprocess.run([str(work / 'check')]).returncode:
        raise SystemExit(1)

command = (sources / 'ViewerSpacingGapFill.swift').read_text(encoding='utf-8')
for needle, why in (
    ('SliceGapFill.plan(positions:', 'places the empty slices with the rule of IsiXImaging'),
    ('SliceIntervalRegularity.regularity(', 'judges irregular slices as the warning does'),
    ('missingPixelsReason = Self.emptySliceNotice', 'marks the empty slices'),
    ('viewer.newWindow(', 'opens a new viewer'),
    ('setPostprocessed(true)', 'marks the new viewer postprocessed'),
    ('NSLocalizedString("Fill Gaps"', 'names the button of the warning'),
    ('response == HorosAlertPanel.alternateResponse', 'fills on the Fill Gaps button'),
):
    if needle not in command:
        fail(f'the command no longer {why}: {needle!r} is missing')
if 'extension ViewerController' in command:
    fail('the command grows the viewer class instead of keeping to its own type')

commands = (sources / 'ViewerStudyCommands.swift').read_text(encoding='utf-8')
if '@objc(fillSpacingGaps:)' not in commands or 'ViewerSpacingGapFill(viewer: viewer).fill()' not in commands:
    fail('the main menu commands have no fillSpacingGaps: action that fills the active viewer')
at = commands.index('case #selector(fillSpacingGaps(_:)):')
if 'ViewerSpacingGapFill(viewer: $0).isIrregular' not in commands[at:at + 300]:
    fail('Fill Spacing Gaps is not enabled by the irregularity of the slices')

warning = (sources / 'ViewerController+SliceInterval.swift').read_text(encoding='utf-8')
at = warning.index('    @objc(displayAWarningIfNonTrueVolumicData)')
body = warning[at:warning.index('    @objc(', at + 10)]
if 'ViewerSpacingGapFill(viewer: self).fill(ifChosen: HorosAlertPanel.runInformational(' not in body \
        or 'alternateButton: ViewerSpacingGapFill.fillGapsButton' not in body:
    fail('the irregular slice interval warning has no Fill Gaps button that runs the command')

menu = (root / 'Horos/Resources/en.lproj/MainMenu.xib').read_text(encoding='utf-8')
split = menu.index('id="Bvs-sp-Itm"')
at = menu.index('id="Fsg-gp-Itm"')
start = menu.rindex('<menuItem', 0, at)
if not split < at or menu[menu.index('</menuItem>', split) + len('</menuItem>'):start].strip():
    fail('2D Viewer > Fill Spacing Gaps does not come right after Split Series by b-value')
item = menu[start:menu.index('</menuItem>', at)]
if 'title="Fill Spacing Gaps"' not in item or 'selector="fillSpacingGaps:" target="Vsc-cm-Obj"' not in item:
    fail('2D Viewer > Fill Spacing Gaps does not send fillSpacingGaps: to the main menu commands')

pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
if pbx.count('/* ViewerSpacingGapFill.swift in Sources */') != 2:
    fail('ViewerSpacingGapFill.swift is not compiled into the app')
print('PASS: Fill Spacing Gaps is wired to the main menu commands and the warning')

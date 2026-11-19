#!/usr/bin/env python3
"""Curved MPR Stenosis tool: the summary of a measure, and the tool's place in the window.

The lumen and the NASCET degree on synthetic vessels, the calcium limit, its
margin and the correction by hand are the tests of the measure itself, in
Modules/IsiXImaging/Tests/ViewerReconstruction/StenosisMeasurementTests.swift.

Here StenosisSummary.swift is compiled with the module and a synthetic vessel
is measured the way the tool measures it, a tube that narrows from a 3 mm to a
1.5 mm radius with a plaque dimmer than the calcium limit beside the narrowing:

- the summary says how the lumen was told from the rest, the lumen edge and
  the calcium limit, as the share of each section's centerline intensity the
  lumen stops at and as the intensity calcium has to be above too to be left
  out even where the lumen surrounds it, the same share of the intensity in
  the middle of the reference's lumen, with the margin when there is one, and
  where calcium above the limit touched the lumen: with none, that plaque
  dimmer than the limit is in the areas;
- with the limit lowered to the lowest the slider offers the plaque leaves
  the minimum area, and the last line says calcium touched the lumen there;
- the strip beside the chart shows the numbers and, under them, that last
  line, so whether plaque is in the areas is seen without copying the
  summary; the calcium limit's tooltip says that calcium dimmer than the
  limit stays in the area and that Erase Plaque takes it out;
- with the narrowest section corrected by hand, every number it comes into
  carries an asterisk, and a line says what the asterisk means and how many
  sections were corrected;
- sections whose whole lumen the eraser or the calcium exclusion took are
  left out of the numbers, and a line under them says how many; when the
  calcium exclusion took one outside the reference, the minimum and the
  degrees carry a dagger, and the line says the stenosis is at least that
  severe.
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import subprocess
import sys
import tempfile

import isix_modules
from sources import source_text

ROOT = Path(__file__).resolve().parents[1]

driver = r'''
import Foundation
import IsiXImaging
import simd

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}

/// A lumen of radius r at (cx, cy) with an edge that falls from `value` to 0
/// over 0.4 mm, half of it at r.
func disc(_ p: SIMD3<Double>, cx: Double, cy: Double, r: Double, value: Double) -> Double {
    let rho = ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
    return value * min(max(0.5 - (rho - r) / 0.4, 0), 1)
}
/// The narrowing: 3 mm, down to 1.5 mm between z = 20 and 25, back up by 30.
func radius(_ z: Double) -> Double {
    switch z {
    case ..<15: return 3
    case ..<20: return 3 - 1.5 * (z - 15) / 5
    case ..<25: return 1.5
    case ..<30: return 1.5 + 1.5 * (z - 25) / 5
    default: return 3
    }
}
/// The lumen at 400 HU, and beside the narrowing a plaque of 560 HU, dimmer
/// than 1.6 × 400: it counts as lumen until the limit comes down.
func vessel(_ p: SIMD3<Double>) -> Float {
    let lumen = disc(p, cx: 0, cy: 0, r: radius(p.z), value: 400)
    let plaque = (19...26).contains(p.z) ? disc(p, cx: radius(p.z) + 0.9, cy: 0, r: 1.0, value: 560) : 0
    return Float(max(lumen, plaque))
}
let length = 50.0
func frame(_ t: Double) -> Stenosis.Frame {
    Stenosis.Frame(point: SIMD3(0, 0, t * length), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
}
let reference = Stenosis.defaultReference(stretch: length)
// The texts below are checked in English; the numbers follow the given locale.
let english = Locale(identifier: "en_US_POSIX")
func summary(_ settings: Stenosis.Settings, erasures: [Int: [Stenosis.Erasure]] = [:]) -> StenosisSummary {
    let sections = Stenosis.sections(from: 0, to: 1, length: length, settings: settings, erasures: erasures, frame: frame, sample: vessel)
    return StenosisSummary(stretchLength: length, result: Stenosis.result(of: sections, reference: reference)!, reference: reference, settings: settings, locale: english)
}
var settings = Stenosis.Settings()
settings.step = 2.5

// 1. As the tool starts: the plaque is in the minimum area, and the summary
// says by which rule calcium is left out.
let automatic = summary(settings)
print(automatic.text)
let lines = automatic.text.split(separator: "\n").map(String.init)
check(lines.count == 11, "eleven lines: \(lines.count)")
check(lines[0] == "Stenosis, curved MPR stretch of 50.0 mm", lines[0])
check(lines[8] == "Lumen edge at 50 % of the centerline intensity", lines[8])
check(lines[9] == "Calcium limit: 160 % of each section's centerline intensity, which the lumen stops at; calcium also above 640 (the same share of the intensity in the middle of the reference's lumen) is left out even where the lumen surrounds it", lines[9])
check(lines[10] == "No calcium above the limit touched the lumen: plaque dimmer than the limit is in the areas", lines[10])
check(abs(automatic.result.contrast - 400) < 1, "the contrast of the reference: \(automatic.result.contrast)")
check(automatic.result.calciumBesideCount == 0 && automatic.result.sectionsWithContrast == 21, "no calcium touched the lumen")
check(!automatic.text.contains("*"), "no asterisk without a correction")
check(automatic.numbers == Array(lines[1...7]), "the numbers are the lines under the title")
check(automatic.strip == Array(lines[1...7]) + [lines[10]], "the strip shows the numbers and whether calcium touched the lumen: " + automatic.strip.joined(separator: " | "))
check(automatic.result.minimumArea > .pi * 2.25 * 1.2, "the dim plaque counts as lumen: \(automatic.result.minimumArea)")

// 2. The limit lowered as far as the slider goes, with a margin: the plaque
// leaves the minimum area.
settings.upperFraction = Stenosis.Settings.calciumLimits.lowerBound
settings.calciumMargin = 0.2
let limited = summary(settings)
print(limited.text)
check(Array(limited.criteria.prefix(2)) == ["Lumen edge at 50 % of the centerline intensity",
                                            "Calcium limit: 130 % of each section's centerline intensity, which the lumen stops at; calcium also above 520 (the same share of the intensity in the middle of the reference's lumen) is left out even where the lumen surrounds it, and the lumen within 0.2 mm of it"], limited.criteria.joined(separator: " | "))
check(limited.result.minimumCalciumBeside && limited.result.calciumBesideCount > 0, "calcium touched the narrowest lumen")
check(limited.criteria.count == 3 && limited.criteria[2] == "Calcium above the limit touched the lumen and was left out in \(limited.result.calciumBesideCount) of 21 sections, the narrowest included", limited.criteria.last ?? "")
check(limited.strip == limited.numbers + [limited.criteria[2]], "the strip says calcium touched the narrowest lumen: " + (limited.strip.last ?? ""))
check(limited.result.minimumArea < automatic.result.minimumArea - 1, "the plaque left the minimum area: \(limited.result.minimumArea)")
check(abs(limited.result.minimumArea - .pi * 2.25) < .pi * 2.25 * 0.12, "the minimum area is the lumen's: \(limited.result.minimumArea)")
check(!limited.text.contains("*"), "no asterisk without a correction")

// 3. The plaque erased by hand at the narrowest section, with the limit as
// the tool starts: the numbers that section comes into say so.
settings = Stenosis.Settings()
settings.step = 2.5
let index = automatic.result.minimumIndex
let z = Double(index) * settings.step
let stroke = Stenosis.Erasure(points: stride(from: -3.0, through: 3.0, by: 0.25).map { SIMD3(radius(z) + 0.45, $0, z) }, radius: 0.4)
let corrected = summary(settings, erasures: [index: [stroke]])
print(corrected.text)
let marked = corrected.text.split(separator: "\n").map(String.init)
check(marked.count == 12, "a line for the asterisk: \(marked.count)")
check(corrected.result.minimumCorrected && corrected.result.correctedCount == 1, "one section corrected, the narrowest")
check(corrected.result.minimumArea < automatic.result.minimumArea - 1, "the erased plaque left the minimum area: \(corrected.result.minimumArea)")
check(marked[1].hasPrefix("Minimum area: ") && marked[1].hasSuffix(" *"), marked[1])
check(marked[2].hasPrefix("Reference area: ") && !marked[2].hasSuffix("*"), marked[2])
check(marked[3].hasPrefix("Mean area of the stretch: ") && marked[3].hasSuffix(" *"), marked[3])
check(marked[4].hasPrefix("NASCET by area: ") && marked[4].hasSuffix(" % *"), marked[4])
check(marked[5].hasPrefix("Minimum diameter: ") && marked[5].hasSuffix(" *"), marked[5])
check(marked[6].hasPrefix("Reference diameter: ") && !marked[6].hasSuffix("*"), marked[6])
check(marked[8] == "* With the lumen corrected by hand (sections corrected: 1)", marked[8])
check(marked[10] == "Calcium limit: 160 % of each section's centerline intensity, which the lumen stops at; calcium also above 640 (the same share of the intensity in the middle of the reference's lumen) is left out even where the lumen surrounds it", marked[10])
check(corrected.numbers.count == 8 && corrected.numbers.last == marked[8], "the asterisk's line comes under the numbers")
check(corrected.strip == corrected.numbers + [marked[11]], "the strip shows the asterisk's line, then whether calcium touched the lumen")

// 4. A section erased whole is left out of the numbers, and a line says so;
// so is one whose lumen the calcium limit and its margin took.
let whole = Stenosis.Erasure(points: [SIMD3(0, 0, 5)], radius: 6)
let erased = summary(settings, erasures: [2: [whole]])
print(erased.text)
check(erased.result.takenByHandCount == 1 && erased.result.takenByCalciumCount == 0 && erased.result.correctedCount == 0, "one section erased whole")
check(erased.numbers.count == 8 && erased.numbers.last == "Sections left out, erased whole by hand: 1", erased.numbers.last ?? "")
var taken = erased.result
taken.takenByCalciumCount = 2
let both = StenosisSummary(stretchLength: length, result: taken, reference: reference, settings: settings, locale: english)
check(Array(both.numbers.suffix(2)) == ["Sections left out, no lumen after the calcium exclusion: 2", "Sections left out, erased whole by hand: 1"],
      both.numbers.suffix(2).joined(separator: " | "))
check(both.text.split(separator: "\n").count == 13, "the left-out lines come between the numbers and the criteria")
check(!both.text.contains("†"), "no dagger while the sections left out are in the reference")

// 4b. Sections beside those that show a stent's struts that show none themselves: the summary and the strip say how many,
// and whether the narrowest is one of them. A stretch without such a section says nothing of struts.
check(automatic.strutsLine == nil && !automatic.text.contains("truts"), "a stretch without a stent names no struts")
var faded = automatic.result
faded.strutRingMissedCount = 2
let tip = StenosisSummary(stretchLength: length, result: faded, reference: reference, settings: settings, locale: english)
check(tip.numbers.last == "Stent struts not recognised in 2 sections beside sections that show them: their areas may include the struts", tip.numbers.last ?? "")
check(tip.strip == tip.numbers + [tip.calciumLine] && tip.text.contains("Stent struts not recognised in 2 sections"), "the strip and the copied summary carry the line")
faded.minimumStrutRingMissed = true
let narrowest = StenosisSummary(stretchLength: length, result: faded, reference: reference, settings: settings, locale: english)
check(narrowest.numbers.last == "Stent struts not recognised in 2 sections beside sections that show them, the narrowest included: their areas may include the struts", narrowest.numbers.last ?? "")

// 5. One of them outside the reference: the narrowest lumen may be among them,
// and the minimum and the degrees say they are at least that severe.
taken.takenByCalciumOutsideReference = true
let bound = StenosisSummary(stretchLength: length, result: taken, reference: reference, settings: settings, locale: english)
print(bound.text)
let daggers = bound.numbers
check(daggers[0].hasPrefix("Minimum area: ") && daggers[0].hasSuffix(" †"), daggers[0])
check(!daggers[1].contains("†") && !daggers[2].contains("†") && !daggers[5].contains("†"), "no dagger on the reference and the mean")
check(daggers[3].hasSuffix(" % †") && daggers[4].hasSuffix(" †") && daggers[6].hasSuffix(" % †"), "the degrees and the minimum diameter carry the dagger")
check(daggers[7] == "† Sections left out, no lumen after the calcium exclusion: 2; the narrowest lumen may be among them, so the stenosis is at least this severe", daggers[7])

// 6. Calcium touched the lumen elsewhere than at the narrowest section.
taken.calciumBesideCount = 3
taken.minimumCalciumBeside = false
let elsewhere = StenosisSummary(stretchLength: length, result: taken, reference: reference, settings: settings, locale: english)
check(elsewhere.criteria.last == "Calcium above the limit touched the lumen and was left out in 3 of 21 sections, not at the narrowest: plaque dimmer than the limit is in its area", elsewhere.criteria.last ?? "")

// 7. The numbers take the separator of the user's region: «Copy Summary»
// pastes them into a report in that language.
var portuguese = limited
portuguese.locale = Locale(identifier: "pt_BR")
let commas = portuguese.text
check(commas.contains("0,2 mm") && !commas.contains("0.2 mm"), "the margin with a comma: " + (portuguese.criteria.dropFirst().first ?? ""))
check(portuguese.numbers[0].range(of: #"^Minimum area: \d+,\d mm² at \d+,\d mm"#, options: .regularExpression) != nil, portuguese.numbers[0])
check(portuguese.numbers[4].range(of: #"\d,\d\d mm \(equivalent \d,\d\d mm\)"#, options: .regularExpression) != nil, portuguese.numbers[4])
check(StenosisSummary.decimal(1, 12.65, locale: Locale(identifier: "de_DE")) == "12,7" || StenosisSummary.decimal(1, 12.65, locale: Locale(identifier: "de_DE")) == "12,6", "German decimals")

// A coronary artery of 3 mm narrowed to half its diameter from 9 to 11 mm of
// a stretch of 20: measured against a proximal and a distal reference, its
// summary opens with the degree by diameter and says what each reference
// measured; a carotid's summary is as it was.
func coronaryRadius(_ z: Double) -> Double { (8.5...11.5).contains(z) ? 0.75 : 1.5 }
let coronaryLength = 20.0
var coronarySettings = Stenosis.Settings(vessel: .coronary)
coronarySettings.step = 1
let coronaryPlaces = (0...20).map { i in
    Stenosis.Place(position: Double(i), relativePosition: Double(i) / coronaryLength,
                   frame: Stenosis.Frame(point: SIMD3(0, 0, Double(i)), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0)))
}
let proximalReference = Stenosis.defaultProximalReference(stretch: coronaryLength), distalReference = Stenosis.defaultReference(stretch: coronaryLength)
let coronarySections = Stenosis.sections(at: coronaryPlaces, settings: coronarySettings, reference: distalReference, proximalReference: proximalReference) { p in
    Float(disc(p, cx: 0, cy: 0, r: coronaryRadius(p.z), value: 400))
}.sections
let coronaryResult = Stenosis.result(of: coronarySections, proximal: proximalReference, distal: distalReference)!
let coronary = StenosisSummary(stretchLength: coronaryLength, result: coronaryResult, reference: distalReference, settings: coronarySettings, locale: english)
print(coronary.text)
check(coronary.opensWithTheDegree && !automatic.opensWithTheDegree, "only the coronary summary opens with its degree")
check(coronary.title == "Coronary stenosis, curved MPR stretch of 20.0 mm", coronary.title)
check(abs(coronaryResult.nascetByDiameter - 50) < 6, "half the diameter, within 6 points: \(coronaryResult.nascetByDiameter)")
check(coronary.numbers[0].range(of: #"^Stenosis by diameter: \d\d %$"#, options: .regularExpression) != nil, coronary.numbers[0])
check(coronary.numbers[1].hasPrefix("Minimum diameter: "), coronary.numbers[1])
check(coronary.numbers[2].range(of: #"^Reference diameter: \d\.\d\d mm at the narrowest, between proximal \d\.\d\d mm and distal \d\.\d\d mm$"#, options: .regularExpression) != nil, coronary.numbers[2])
check(coronary.numbers[3].range(of: #"^Stenosis by area: \d\d %$"#, options: .regularExpression) != nil, coronary.numbers[3])
check(coronary.numbers[5].hasPrefix("Reference area: ") && coronary.numbers[5].contains("proximal") && coronary.numbers[5].contains("(0.0–5.0 mm)") && coronary.numbers[5].contains("(15.0–20.0 mm)"), coronary.numbers[5])
check(!coronary.text.contains("NASCET"), "NASCET is the carotid's criterion")
check(coronary.criteria[0] == "Measured as a coronary artery: the reference at the narrowest section is interpolated between the proximal and the distal one", coronary.criteria[0])
check(coronary.criteria[1] == "Vessel wall where the fat begins, below -30 HU; plaque as bright as the lumen edge or brighter is in the lumen", coronary.criteria[1])
check(coronary.criteria[2] == "Lumen edge at 50 % of the centerline intensity", coronary.criteria[2])
// That artery lies in tissue of 0 HU, with no fat to end its wall: the summary says its plaque was not measured.
check(coronary.numbers.last == "Plaque not measured: no section of the stretch has fat around the vessel to end its wall", coronary.numbers.last ?? "")

// The same lumen in fat, with plaque around it in three rings: its volume, its share of the vessel and its bands.
func ringed(_ p: SIMD3<Double>) -> Float {
    let rho = (p.x * p.x + p.y * p.y).squareRoot()
    func edge(_ r: Double) -> Double { min(max(0.5 - (rho - r) / 0.2, 0), 1) }
    // From the fat inwards: each ring over what lies outside it.
    var value = -90.0
    for (r, hu) in [(3.3, 0.0), (2.7, 80.0), (2.1, 150.0), (1.5, 400.0)] { value += (hu - value) * edge(r) }
    return Float(value)
}
let ringedSections = Stenosis.sections(at: coronaryPlaces, settings: coronarySettings, reference: distalReference, proximalReference: proximalReference, sample: ringed).sections
let found = Stenosis.plaque(of: ringedSections, step: coronarySettings.step, limits: coronarySettings.plaque!)
let withPlaque = StenosisSummary(stretchLength: coronaryLength, result: Stenosis.result(of: ringedSections, proximal: proximalReference, distal: distalReference)!,
                                 reference: distalReference, settings: coronarySettings, plaque: found, locale: english)
print(withPlaque.plaqueLines.joined(separator: "\n"))
let plaqueLines = withPlaque.plaqueLines
check(plaqueLines.count == 5, "five lines of plaque: \(plaqueLines.count)")
check(plaqueLines[0].range(of: #"^Plaque volume: \d+\.\d mm³, \d\d % of the vessel \(\d+\.\d mm³\)$"#, options: .regularExpression) != nil, plaqueLines[0])
check(plaqueLines[1].hasPrefix("Lipid-rich or necrotic (below 30 HU): ") && plaqueLines[2].hasPrefix("Fibro-fatty (30 to 130 HU): ")
      && plaqueLines[3].hasPrefix("Fibrous (130 to 350 HU): ") && plaqueLines[4].hasPrefix("Calcium (above 350 HU): "), plaqueLines.joined(separator: " | "))
let put = Double.pi * (3.3 * 3.3 - 1.5 * 1.5) * 21
check(found != nil && abs(found!.plaqueVolume - put) < 0.15 * put, "the plaque put there, within 15 %: \(found?.plaqueVolume ?? -1) of \(put)")
check(withPlaque.text.contains(plaqueLines[0]) && withPlaque.strip.contains(plaqueLines[0]), "the plaque is in the summary copied and on the strip")
check(automatic.plaqueLines.isEmpty && !automatic.text.contains("Plaque"), "a carotid has no line of plaque")
// Read with other bands, the summary says which.
var otherBands = coronarySettings
otherBands.plaque = Stenosis.PlaqueLimits(bands: [20, 100, 400])
let reread = Stenosis.sections(at: coronaryPlaces, settings: otherBands, reference: distalReference, proximalReference: proximalReference, sample: ringed).sections
let rereadSummary = StenosisSummary(stretchLength: coronaryLength, result: Stenosis.result(of: reread, proximal: proximalReference, distal: distalReference)!,
                                    reference: distalReference, settings: otherBands,
                                    plaque: Stenosis.plaque(of: reread, step: otherBands.step, limits: otherBands.plaque!), locale: english)
check(rereadSummary.plaqueLines[1].hasPrefix("Lipid-rich or necrotic (below 20 HU): ") && rereadSummary.plaqueLines[2].hasPrefix("Fibro-fatty (20 to 100 HU): ")
      && rereadSummary.plaqueLines[3].hasPrefix("Fibrous (100 to 400 HU): ") && rereadSummary.plaqueLines[4].hasPrefix("Calcium (above 400 HU): "), rereadSummary.plaqueLines.joined(separator: " | "))
check(rereadSummary.plaqueLines[0] == withPlaque.plaqueLines[0], "the volume of the plaque does not depend on its bands")
// With the limits of a coronary artery and one reference, the summary is the carotid's.
let single = StenosisSummary(stretchLength: coronaryLength, result: Stenosis.result(of: coronarySections, reference: distalReference)!, reference: distalReference, settings: coronarySettings, locale: english)
check(!single.opensWithTheDegree && single.title.hasPrefix("Stenosis, curved MPR") && single.numbers[6].hasPrefix("NASCET by diameter"), single.title)

if failures > 0 { exit(1) }
print("PASS: the summary says how calcium was told from the lumen and where it was left out, which numbers come from a corrected lumen, and which sections were left out, with the decimal separator of the user's region")
'''

with tempfile.TemporaryDirectory(prefix='horos-stenosis-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(driver)
    flags = isix_modules.module_flags('IsiXImaging', work / 'modules', ['-O'])
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-module-cache-path', str(work / 'cache'), *flags,
                            str(ROOT / 'Horos/Sources/StenosisSummary.swift'), str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=120)
    print(run.stdout.strip())
    failed = run.returncode != 0

# The tool's place in the curved MPR window: a toolbar button beside the Path
# Assistant, not a ToolMode; the strip under the reformation views; the
# stretched and straightened views hand it their drags and conversions.
controller = source_text('CPRController')
cpr_view = source_text('CPRView')
chart = source_text('StenosisChart')
checks = [
    ('NSToolbarItem.Identifier("tbPathAssistant"), NSToolbarItem.Identifier("tbStenosis")' in controller, 'default toolbar puts Stenosis after the Path Assistant'),
    ('CPRToolbarAdditions.insertOnce(into: toolbar, store: self.preferenceStore)' in controller
     and '(ReconstructionPreferences.cprToolbarStenosisInserted, ["tbStenosis"], "tbPathAssistant")' in source_text('CPRToolbarAdditions'), 'saved toolbars get the item once'),
    ('stenosisTool?.curvedPathDidChange()' in controller, 'a path edit reaches the tool'),
    ('stenosisTool?.setActive(false)' in controller, 'closing the window turns the tool off'),
    ('@objc public var stenosisStrip: NSView?' in cpr_view and 'rest.size.height -= stripHeight' in cpr_view, 'the strip takes the bottom of the CPR view'),
    ('currentTool' not in source_text('StenosisTool') and 'setCurrentTool' not in source_text('StenosisTool'), 'the tool does not change the shared ToolMode'),
]
for name in ('CPRStretchedView', 'CPRStraightenedView'):
    text = source_text(name)
    checks.append((all(f'stenosisTool?.{call}(event, in: self) == true' in text for call in ('handleMouseDown', 'handleMouseDragged', 'handleMouseUp')), f'{name} hands its drags to the tool'))
    checks.append((f'extension {name}: StenosisPathView' in text, f'{name} converts positions for the tool'))
    checks.append(('stenosisTool?.viewDidDraw(self)' in text, f'{name} redraws the overlay'))
checks.append(('stenosisViewPoint(forPatientVector' in source_text('CPRTransverseView'), 'the transverse view projects the outline'))
# The calcium limit and its margin are beside the lumen edge; the eraser takes
# the middle transverse view's drags only while it is on, through the overlay,
# and what it erased leaves with a new stretch or another path.
tool = source_text('StenosisTool')
checks += [
    (all(f'#selector({action}(_:))' in tool for action in ('edgeChanged', 'limitChanged', 'marginChanged', 'eraseChanged', 'undoStroke', 'resetSection')), 'the strip has the limit, the margin and the eraser'),
    ('guard let tool, tool.isErasing, tool.currentSection != nil else { return nil }' in tool, 'the overlay takes the mouse only while erasing a section of the stretch'),
    ('reference = nil; proximalReference = nil; sections = []; result = nil; corrections = []' in tool, 'a new stretch starts without corrections and without references'),
    ('            corrections = []\n            refresh()' in tool, 'another path drops the corrections'),
    ('frames[nearest].3 += correction.strokes' in tool, 'a measure of the stretch puts the erasures back on their sections'),
    ('corrected by hand' in tool and 'corrected: $0.corrected' in tool and 'for section in content.sections where section.corrected' in chart, 'the transverse view and the chart show a corrected section'),
    ('import IsiXImaging' in tool and 'enum Stenosis' not in tool, 'the measure is the module\'s'),
    ('minValue: Stenosis.Settings.calciumLimits.lowerBound' in tool, 'the calcium limit slider starts where the module says the noise stops reaching it'),
    ('job.measure(section: index, of: places, settings: settings, contrast: contrast, stented: stented)' in tool
     and 'let stented = sections[index].stretchHoldsStent' in tool and 'self.contrast = contrast' in tool
     and 'erasures: i == index ? strokes : []' in tool and 'Stenosis.section(index, of: places, settings: settings, contrast: contrast, stented: stented, sample: sample)' in tool,
     'a section measured again alone keeps the contrast of its reference and, with the places of its stretch, the ring of a stent its stretch tells it'),
    ('reference: measuredReference, proximalReference: measuredProximal, contrast: nil' in tool and 'Stenosis.sections(at: places, settings: settings, reference: reference, proximalReference: proximalReference,' in tool, 'the stretch is measured against the contrast of its reference'),
    ('controlsScroll.documentView = controls' in tool, 'the sliders and the buttons scroll when the strip is lower than they are'),
    ('numbersScroll.documentView = numbers' in tool, 'the numbers scroll when their notes do not fit the strip'),
    ('text = summary.strip.joined(separator: "\\n")' in tool, 'the strip shows the numbers and whether calcium touched the lumen'),
    ('Calcium dimmer than the limit stays in the area: take it out with Erase Plaque.' in tool, 'the calcium limit\'s tooltip says calcium dimmer than the limit stays in the area and the eraser takes it out'),
    ('lumenTaken: $0.lumenTaken != nil' in tool and 'for section in content.sections where section.lumenTaken' in chart, 'the chart marks the sections whose lumen was taken whole'),
    # The middle transverse view is about 140 pt wide: the area and its note
    # wrap to it; and the strip grows back to its height when the CPR view does.
    ('(text as NSString).draw(with: NSRect(x: 8, y: 8, width: width, height: height), options: [.usesLineFragmentOrigin]' in tool
     and 'draw(at: NSPoint(x: 8, y: 8)' not in tool, 'the area of the section wraps to the transverse view'),
    ('$0 is StenosisStrip ? StenosisStrip.height : $0.frame.height' in cpr_view
     and 'min(stenosisStrip?.frame.height' not in cpr_view, 'the strip grows back when the CPR view grows'),
    ('let area = StenosisSummary.decimal(1, section.area)' in tool and 'StenosisSummary.decimal(1, mm))' in tool
     and 'String(format: "%.1f"' not in tool, 'the section\'s area and the margin take the decimal separator of the user\'s region'),
]
# The plaque and the capture: the plaque of the sections goes to the summary,
# and a button saves the strip and the summary in the study, only when clicked.
capture = source_text('StenosisCapture')
checks += [
    ('plaque = settings.plaque.flatMap { Stenosis.plaque(of: sections, step: settings.step, limits: $0) }' in tool
     and 'settings: settings, plaque: plaque)' in tool, 'the tool measures the plaque of the stretch and hands it to the summary'),
    ('#selector(saveCapture(_:))' in tool and 'tool?.saveCapture(of: self)' in tool and tool.count('saveCapture(of: ') == 1,
     'the capture is saved by its button alone'),
    ('StenosisCapture.image(of: strip, summary: summary.text)' in tool and 'export.setSourceFile(sourceFile)' in capture
     and 'GeneratedSeriesImport.process.add(into: database, writing: { export.writeDCMFile($0) })' in capture,
     'the capture is the strip over the summary, a Secondary Capture in the study of the series measured'),
    ('NSPasteboard' not in capture and 'copySummary' not in capture, 'saving a capture leaves the clipboard alone'),
]
# The bands of the plaque: a pop-over of the strip edits them, the tool takes
# only three limits that rise above the fat and keeps them in the preferences.
checks += [
    ('#selector(editBands(_:))' in tool and 'StenosisBandsEditor(tool: tool)' in tool and 'bands.isEnabled = tool.settings.plaque != nil' in tool,
     'the strip opens the bands of the plaque, for a coronary stretch'),
    ('let limits = Stenosis.PlaqueLimits(bands: bands)\n        guard limits.bands == bands else { return false }' in tool,
     'bands that do not rise above the fat are refused'),
    ('for (key, value) in zip(Self.bandKeys, bands) { store.set(value, for: key) }' in tool
     and 'settings.plaque = Stenosis.PlaqueLimits(bands: storedPlaqueBands)' in tool
     and 'ReconstructionPreferences.stenosisPlaqueLipidLimit, ReconstructionPreferences.stenosisPlaqueFibroFattyLimit' in tool,
     'the bands are kept in the preferences and read when a stretch is measured as a coronary artery'),
    ('if settings.plaque != nil, settings.plaque != limits {' in tool, 'the same bands measure nothing again'),
]
# The coronary mode: a selector beside the eraser, a proximal reference that
# is dragged as the distal one, and the degree by diameter standing out.
checks += [
    ('#selector(vesselChanged(_:))' in tool and 'tool?.setVessel(cases[vessel.selectedSegment])' in tool
     and 'vessel.selectedSegment = Stenosis.Vessel.allCases.firstIndex(of: tool.settings.vessel) ?? 0' in tool, 'the strip chooses the vessel and shows the one chosen'),
    ('settings.measure(as: vessel)' in tool and 'proximalReference = Stenosis.defaultProximalReference(stretch: stretch)' in tool
     and 'if settings.vessel != .coronary {\n            proximalReference = nil' in tool, 'a coronary stretch has a proximal reference, a carotid none'),
    ('proximalReference.map { Stenosis.result(of: sections, proximal: $0, distal: distal) } ?? Stenosis.result(of: sections, reference: distal)' in tool,
     'the degree is read against both references when there are two'),
    ('case .proximalStart, .proximalEnd:' in tool and 'candidates.append((.proximalStart, t))' in tool, 'the proximal reference is dragged by its lines'),
    ('stroke(a, .systemTeal, "P")' in tool and 'references: [proximalReference, reference].compactMap { $0 }' in tool and 'for reference in content.references' in chart, 'the overlay and the chart show both references'),
    ('tool.summary?.opensWithTheDegree == true' in tool and 'weight: .semibold' in tool, 'the degree by diameter stands out on the strip'),
]
languages = sorted(p.name[:-6] for p in (ROOT / 'Horos/Resources').glob('*.lproj') if (p / 'Localizable.strings').exists())
for key in ('Carotid', 'Coronary', 'Stenosis by diameter: %@ %%', 'Stenosis by area: %@ %%', 'Coronary stenosis, curved MPR stretch of %@ mm',
            'Reference diameter: %@ mm at the narrowest, between proximal %@ mm and distal %@ mm',
            'Measured as a coronary artery: the reference at the narrowest section is interpolated between the proximal and the distal one',
            'Plaque volume: %@ mm³, %@ %% of the vessel (%@ mm³)', 'Fibro-fatty (%@ to %@ HU): %@ mm³, %@ %%', 'Save Capture', 'Stenosis - %@',
            'Plaque not measured: no section of the stretch has fat around the vessel to end its wall',
            'Bands…', 'Use Defaults', 'Fibro-fatty, up to (HU):'):
    for language in languages:
        text = (ROOT / f'Horos/Resources/{language}.lproj/Localizable.strings').read_bytes()
        text = text.decode('utf-16') if text[:2] in (b'\xff\xfe', b'\xfe\xff') else text.decode('utf-8')
        checks.append((f'"{key}" = ' in text, f'{language} has the text {key!r}'))
checks.append((len(languages) == 12, f'twelve catalogs: {languages}'))
for ok, what in checks:
    if not ok:
        print('FAIL:', what); failed = True
sys.exit(1 if failed else 0)

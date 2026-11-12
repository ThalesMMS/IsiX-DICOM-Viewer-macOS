#!/usr/bin/env python3
"""File > Export > Export as Synthetic DWI computes a b-value that was not acquired.

Compiles SyntheticDiffusion.swift (IsiXImaging) with a driver that fits the
series tools/generate-dwi-bvalue-fixture.py writes - a disc and a spot whose
signals fall with the b-value at known rates, at b = 0, 500 and 1000 - and
reads the image at b = 1600 against those rates, with the slices of a 4D
viewer and of a single stack, the numbers of the dialog and the pixels stored.
Then checks the wiring: the menu item of every language, the command that
takes it as its target at launch, what the export writes into the files, the
preference and the catalogs.
"""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
operations = root / 'Modules/IsiXImaging/Sources/BufferOperations'
LANGUAGES = ('ar', 'de', 'en', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


driver = r'''
import Foundation
import simd

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}
typealias S = SyntheticDiffusion

// The fixture's tissues: the disc loses its signal at 0.0020 mm²/s, the spot
// at 0.0006, and the background has none; each stored as a whole number.
let rates: [(s0: Double, adc: Double)] = [(1000, 0.0020), (1000, 0.0006)]
func signal(_ tissue: (s0: Double, adc: Double), _ b: Double) -> Float { Float((tissue.s0 * exp(-b * tissue.adc)).rounded(.down)) }
let acquired = [0.0, 500, 1000].map { b in S.Acquisition(bValue: b, samples: rates.map { signal($0, b) } + [0]) }

guard case .success(let image) = S.image(of: acquired, pixels: 3, at: 1600) else { print("FAIL: no image"); exit(1) }
// From signals cut to whole numbers: within 2 % of the exact decay.
check(abs(image[0] - 40.76) < 0.8, "the disc at b1600 is \(image[0]), not about 40.8")
check(abs(image[1] - 382.89) < 7.6, "the spot at b1600 is \(image[1]), not about 383")
check(image[2] == 0, "the background is not 0")
check(image[1] > image[0] * 9, "the restricted spot does not stand out at b1600")

// Two b-values are the two-point formula; the order of the images is free.
guard case .success(let two) = S.image(of: [acquired[2], acquired[0]], pixels: 3, at: 1600) else { print("FAIL: two"); exit(1) }
check(abs(two[0] - 1000 * pow(135.0 / 1000, 1.6)) < 0.1, "two points: \(two[0])")
check(S.image(of: [acquired[0], acquired[0]], pixels: 3, at: 1600) == .failure(.tooFewBValues), "one b-value twice is refused")
check(S.image(of: acquired, pixels: 4, at: 1600) == .failure(.sizeMismatch), "a size the images do not have is refused")

// The slices: one image per frame in 4D, the images of each position in a stack.
let frames = S.slices(movieCount: 3, sliceCount: 6)
check(frames.count == 6 && frames.allSatisfy { $0.map(\.movie) == [0, 1, 2] }, "4D slices")
let origins = (0..<18).map { SIMD3<Double>(0, 0, Double($0 % 6) * 5) }
guard case .success(let stack) = S.slices(origins: origins) else { print("FAIL: stack"); exit(1) }
check(stack.count == 6 && stack[2].map(\.slice) == [2, 8, 14], "a stack of three b-values over six positions")
check(S.slices(origins: Array(origins.prefix(7))) == .failure(.unpairedPositions), "a position with one image is refused")
check(S.template(of: [0, 500, 1000]) == 2, "the header comes from the highest b-value")

// The dialog.
check(S.bValues(in: "0, 500, 1000") ?? [] == [0, 500, 1000], "b-values read")
check(S.bValues(in: "0, ?, 1000") == nil && S.bValue(in: "-5") == nil && S.bValue(in: "1600") == 1600, "b-values refused")
check(S.text(of: [0, nil, 1000]) == "0, ?, 1000", "an unknown b-value is left to the user")
check(S.seriesName(bValue: 1600) == "Synthetic DWI b1600", "the proposed name")
check(S.defaultBValue == 1600, "the b-value proposed first")
check(S.sequenceName("*ep_b1000t", at: 1600) == "*ep_b1600t" && S.sequenceName("ep2d_diff", at: 1600) == nil,
      "a sequence name that carried the acquired b-value carries the computed one")

// Storage: whole numbers with a slope of 1 for usual signals.
check(S.storedSlope(maximum: 383) == 1 && S.stored([40.76, 382.89, 0], slope: 1) == [41, 383, 0], "stored pixels")
check(S.storedSlope(maximum: 200000) == 10, "values beyond 16 bits are scaled")
print("PASS: synthetic b-value, slices, dialog numbers and storage")
'''

with tempfile.TemporaryDirectory(prefix='horos-synthetic-dwi-') as tmp:
    work = Path(tmp)
    (work / 'main.swift').write_text(driver)
    if subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(operations / 'SyntheticDiffusion.swift'),
                       str(operations / 'T2FitMapping.swift'), str(work / 'main.swift'), '-o', str(work / 'check')]).returncode:
        fail('SyntheticDiffusion.swift does not build with the driver')
    if subprocess.run([str(work / 'check')]).returncode:
        raise SystemExit(1)

export = (sources / 'ViewerSyntheticDWI.swift').read_text(encoding='utf-8')
for needle, why in (
    ('@IBAction @objc(exportSyntheticDWI:)', 'is the menu action'),
    ('NSApp.mainWindow?.windowController as? ViewerController', 'runs on the 2D viewer whose window is the main one'),
    ('exportMenu?.items.first { $0.action == #selector(exportSyntheticDWI(_:)) }?.target = shared', 'takes the menu item as its target'),
    ('SyntheticDiffusion.slices(movieCount: movieCount, sliceCount: sliceCount)', 'reads a 4D viewer one b-value per frame'),
    ('SyntheticDiffusion.slices(origins: origins)', 'pairs the images of a single stack by position'),
    ('BValueSplit.bValue(BValueSplit.tags.map', 'reads the b-values where Split Series by b-value reads them'),
    ('SyntheticDiffusion.image(of: acquisitions', 'fits each slice with the rule of IsiXImaging'),
    ('alert.beginSheetModal(for: window)', 'asks on a sheet of the viewer'),
    ('processGraph.preferences.set(request.target, for: ViewerPreferences.syntheticDWIBValue)', 'remembers the b-value asked for'),
    ('exporter.setModalityAsSource(true)', 'keeps the modality of the series'),
    ('exporter.setSeriesDescription(request.seriesName)', 'names the series as the user asked'),
    ('forTag: 0x0018_9087', 'writes the computed b-value as the Diffusion b-value'),
    ('manufacturerBValueTags.forEach { dataset.removeElement(forTag: $0) }', "removes the manufacturer's b-value of the source image"),
    ('DERIVED\\\\SECONDARY\\\\DIFFUSION\\\\CALC_BVALUE', 'says the image is derived'),
    ('SyntheticDiffusion.sequenceName(name, at: target)', 'corrects a sequence name that carried the acquired b-value'),
    ('GeneratedSeriesImport(processGraph: processGraph).add(written, marksKeyImages: false)', 'indexes the series as an export does'),
    ('browser.openViewer(fromImages: [images]', 'opens the new series'),
):
    if needle not in export:
        fail(f'the export no longer {why}: {needle!r} is missing')
if 'static let manufacturerBValueTags: [UInt32] = [0x0019_100C, 0x0043_1039, 0x2001_1003]' not in export:
    fail("the manufacturer's b-value elements removed are not those Split Series by b-value reads")

preferences = (root / 'Modules/IsiXPreferences/Sources/ViewerPreferences.swift').read_text(encoding='utf-8')
if 'syntheticDWIBValue = PreferenceKey<Double>("SyntheticDWIBValue", registered: "1600")' not in preferences:
    fail('the last b-value asked for is not a preference of the viewer, 1600 at first')
if 'suvConversion, syntheticDWIBValue,' not in preferences:
    fail('SyntheticDWIBValue is not in the catalog of the viewer preferences')

TITLE = 'Export as Synthetic DWI…'
for language in LANGUAGES:
    folder = root / f'Horos/Resources/{language}.lproj'
    menu = (folder / 'MainMenu.xib').read_text(encoding='utf-8')
    if 'id="Sdw-ex-Itm"' not in menu:
        fail(f'{language}: File > Export has no Synthetic DWI item')
    at = menu.index('id="Sdw-ex-Itm"')
    if 'selector="exportSyntheticDWI:" target="-1"' not in menu[at:menu.index('</menuItem>', at)]:
        fail(f'{language}: the Synthetic DWI item does not send exportSyntheticDWI: to the first responder')
    # In the Export submenu, right after the DICOM export.
    submenu = menu[menu.index('identifier="org.horos.menu.export"'):]
    submenu = submenu[:submenu.index('</menu>')]
    if not 0 <= submenu.find('selector="exportDICOMFile:"') < submenu.find('id="Sdw-ex-Itm"'):
        fail(f'{language}: the Synthetic DWI item is not in File > Export after the DICOM export')
    catalog = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(folder / 'Localizable.strings')]))
    translated = catalog.get(TITLE)
    if not translated:
        fail(f'{language}: the catalog has no entry for the menu title')
    if language != 'en' and translated == TITLE:
        fail(f'{language}: the menu title is not translated')
    start = menu.rfind('<menuItem ', 0, at)
    if f'title="{translated}"' not in menu[start:at]:
        fail(f'{language}: the menu shows another title than its catalog has: {translated!r}')

# The command is a type of its own, installed as the application finishes
# launching: the viewer's class does not grow by it.
if 'extension ViewerController' in export:
    fail('the export adds to ViewerController: the command is SyntheticDWICommand')
lifecycle = (sources / 'ApplicationLifecycle.swift').read_text(encoding='utf-8')
launched = lifecycle[lifecycle.index('func didFinishLaunching() {'):]
if 'SyntheticDWICommand.install(in: processGraph.applicationMenus.exportMenu())' not in launched[:launched.index('\n    }\n')]:
    fail('the application does not give the menu item its target as it finishes launching')

pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
if 'ViewerSyntheticDWI.swift in Sources' not in pbx:
    fail('ViewerSyntheticDWI.swift is not compiled into the app')
print('PASS: Export as Synthetic DWI is wired to the viewer in every language')

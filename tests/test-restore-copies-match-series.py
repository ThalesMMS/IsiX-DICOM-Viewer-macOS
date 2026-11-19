#!/usr/bin/env python3
"""The slices read again from their files to restore pixels are brought to the
state of the series.

The restoring fill (Tab with the 3D scissors, Restore Content of the 2D ROIs)
copies pixels from slices read again from their files. A PET series converted
to SUV then got raw values among its SUV voxels, and a series corrected for a
gantry tilt got pixels of the tilted slices, of another place. The copies are
now converted by each slice's factor and corrected onto the plane the series
was corrected onto, and the restore is refused when they cannot be.

SeriesRestoreCopies.swift is compiled here with stand-ins of DCMPix and of the
correction, and linked with the imaging module, which tells the corrected
stack and its model slice.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the compiler
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]

STAND_INS = r'''
import Foundation
import IsiXImaging

final class DCMPix {
    var origin: [Double]
    var pixels: UnsafeMutablePointer<Float>?
    var decoded = 0
    var suvConverted = false, factorPET2SUV: Float = 0
    let pwidth = 2, pheight = 2
    var correctedOnto: Int?
    init(origin: [Double], value: Float? = 1) {
        self.origin = origin
        if let value {
            pixels = .allocate(capacity: 4)
            pixels?.update(repeating: value, count: 4)
        }
    }
    var originX: Double { decoded += 1; return origin[0] }
    var originY: Double { origin[1] }
    var originZ: Double { origin[2] }
    var fImage: UnsafeMutablePointer<Float>! { decoded += 1; return pixels }
    func orientationDouble(_ o: UnsafeMutablePointer<Double>) {
        for (i, value) in [1.0, 0, 0, 0, 1, 0, 0, 0, 1].enumerated() { o[i] = value }
    }
    var values: [Float] { (0..<4).map { pixels?[$0] ?? .nan } }
}

/// The correction, which here notes the slice it brought the others onto.
@MainActor struct GantryTiltSlices {
    static var fails = false
    let slices: [DCMPix]
    func correct(onto modelIndex: Int? = nil, progress: () -> Void) -> Bool {
        if GantryTiltSlices.fails { return false }
        for slice in slices { slice.correctedOnto = modelIndex ?? slices.count / 2 }
        return true
    }
}
'''

DRIVER = r'''
var failures: [String] = []
func check(_ condition: Bool, _ what: String) { if !condition { failures.append(what) } }

let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
// Six slices of a gantry tilted about x: 2 mm along z, 1 mm along y.
func files(value: Float? = 1) -> [DCMPix] { (0..<6).map { DCMPix(origin: [0, Double($0), 2 * Double($0)], value: value) } }
func corrected(_ slices: [DCMPix], onto model: Int) {
    let origins = slices.map(\.origin)
    for (i, slice) in slices.enumerated() {
        slice.origin = GantryTiltCorrection.projectedOrigin(modelOrigin: origins[model], model: axial,
                                                            offset: zip(origins[i], origins[model]).map { $0 - $1 })
    }
}

@MainActor func run() {
    // A series as its files give it: nothing to do, and only the first and
    // the last copies are decoded to know it.
    var series = files(), copies = files()
    check(SeriesRestoreCopies.match(copies, to: series), "the copies of a series as its files give it are refused")
    check(copies.allSatisfy { $0.values == [1, 1, 1, 1] && $0.correctedOnto == nil && !$0.suvConverted },
          "the copies of a series as its files give it were changed")
    check(copies.dropFirst().dropLast().allSatisfy { $0.decoded == 0 }, "every copy of a series as its files give it was decoded at once")

    // A PET series converted to SUV, each slice by its own factor.
    series = files(); copies = files(value: 1000)
    for (i, slice) in series.enumerated() { slice.suvConverted = true; slice.factorPET2SUV = 0.001 * Float(i + 1) }
    check(SeriesRestoreCopies.match(copies, to: series), "the copies of a series in SUV are refused")
    check(copies.enumerated().allSatisfy { i, copy in
        copy.suvConverted && copy.factorPET2SUV == series[i].factorPET2SUV && copy.values.allSatisfy { abs($0 - Float(i + 1)) < 0.0001 }
    }, "the copies of a series in SUV keep the raw values of their files: \(copies.map(\.values))")
    // A copy already in SUV is not converted twice.
    check(SeriesRestoreCopies.match(copies, to: series) && copies[1].values.allSatisfy { abs($0 - 2) < 0.0001 },
          "copies already in SUV were converted again")
    // A copy without pixels: no restore.
    series = files(); copies = files(value: nil)
    series[3].suvConverted = true; series[3].factorPET2SUV = 2
    check(!SeriesRestoreCopies.match(copies, to: series), "copies without pixels are accepted for a series in SUV")

    // A series corrected for a gantry tilt, onto its middle slice, and onto
    // another (a stack reversed since has another middle).
    for model in [3, 2] {
        series = files(); copies = files()
        corrected(series, onto: model)
        check(SeriesRestoreCopies.match(copies, to: series) && copies.allSatisfy { $0.correctedOnto == model },
              "the copies of a series corrected onto slice \(model) are not corrected onto it: \(copies.map(\.correctedOnto))")
    }
    // The correction fails: no restore.
    GantryTiltSlices.fails = true
    series = files(); copies = files()
    corrected(series, onto: 3)
    check(!SeriesRestoreCopies.match(copies, to: series), "copies that could not be corrected are accepted")
    GantryTiltSlices.fails = false

    // Slices moved in another way (their origin typed): not the files' place,
    // and not a correction the copies can be given.
    series = files(); copies = files()
    for slice in series { slice.origin[0] += 5 }
    check(!SeriesRestoreCopies.match(copies, to: series) && copies.allSatisfy { $0.correctedOnto == nil },
          "the copies of slices moved in another way are accepted")

    // Not one copy per slice.
    check(!SeriesRestoreCopies.match(Array(files().dropLast()), to: files()), "fewer copies than slices are accepted")
    check(!SeriesRestoreCopies.match([], to: []), "no slice is accepted")
}
MainActor.assumeIsolated { run() }
for failure in failures { print("FAIL: " + failure) }
exit(failures.isEmpty ? 0 : 1)
'''

failures = []
fill = (ROOT / 'Horos/Sources/DCMPix+ROIFill.swift').read_text(encoding='utf-8')
start = fill.find('    public dynamic func prepareRestore() -> Bool {')
prepare = fill[start:fill.find('\n    }\n', start)]
if not (-1 < prepare.find('SeriesRestoreCopies.match(cache, to: sources)') < prepare.find('restoreImageCache = cache')) or \
        'return false' not in prepare[prepare.find('SeriesRestoreCopies.match'):prepare.find('restoreImageCache = cache')]:
    failures.append('-prepareRestore: the copies are brought to the state of the series before they are the restore cache, or there is none')

with tempfile.TemporaryDirectory(prefix='horos-restore-copies-') as directory:
    folder = Path(directory)
    (folder / 'StandIns.swift').write_text(STAND_INS)
    (folder / 'main.swift').write_text('import Foundation\nimport IsiXImaging\n' + DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings',
                            *isix_modules.module_flags('IsiXImaging', folder / 'modules'),
                            str(ROOT / 'Horos/Sources/SeriesRestoreCopies.swift'), str(folder / 'StandIns.swift'), str(folder / 'main.swift'),
                            '-o', str(folder / 'test')], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        print('FAIL: SeriesRestoreCopies.swift does not compile with the stand-ins')
        sys.exit(1)
    ran = subprocess.run([str(folder / 'test')], capture_output=True, text=True)
    sys.stdout.write(ran.stdout)
    if ran.returncode != 0 and 'FAIL' not in ran.stdout:
        failures.append('the harness ended with %d: %s' % (ran.returncode, ran.stderr.strip()[-300:]))
    elif ran.returncode != 0:
        failures.append('the copies')

for failure in failures:
    if failure != 'the copies':
        print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print('PASS: the slices read again to restore pixels are in SUV and on the corrected plane as the series is, or the restore is refused')

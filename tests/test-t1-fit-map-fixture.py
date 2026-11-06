#!/usr/bin/env python3
"""The generated T1 phantoms carry their acquisition in DICOM tags, and T1Fitting
recovers their nominal T1 values from them.

tools/generate-t1-phantom-fixture.py writes an inversion recovery series (one
image per InversionTime) and a variable flip angle series (one image per
FlipAngle at one RepetitionTime). Read back with pydicom, each image must carry
the tags the app reads, and the inner voxels of each quadrant the curve of its
nominal T1. The pixels and tags then go to IsiXImaging's T1Fitting, compiled
here with the three files it uses, as the app hands them over: the series as
one slice, the acquisition of each image, the samples of each image. Every
inner voxel must come back within 1% of its compartment's T1, through the
method the tags call for, and the border must be counted below the signal
threshold.
"""
import importlib.util
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from python_with import prefer  # noqa: E402
prefer('import pydicom')

try:
    import pydicom
except ImportError as error:
    print('need pydicom to read the generated phantom:', error, file=sys.stderr)
    sys.exit(2)

root = Path(__file__).resolve().parents[1]
imaging = root / 'Modules/IsiXImaging/Sources'
sources = [imaging / 'BufferOperations/T1Fitting.swift', imaging / 'BufferOperations/T2FitMapping.swift',
           imaging / 'DICOMAttributeSource.swift', imaging / 'ParsedValue.swift']
generator = root / 'tools/generate-t1-phantom-fixture.py'
for path in sources + [generator]:
    if not path.is_file():
        print(f'FAIL: {path.relative_to(root)} is missing', file=sys.stderr)
        sys.exit(1)

SIZE = 16
failures = []


def read(folder, pattern):
    images = []
    for path in sorted(folder.glob(pattern), key=lambda p: int(p.stem.split('-')[1])):
        item = pydicom.dcmread(path)
        count = int(item.Rows) * int(item.Columns)
        images.append((item, struct.unpack('<%dH' % count, item.PixelData)))
    return images


def swift_array(values):
    return '[%s]' % ', '.join(repr(float(v)) for v in values)


with tempfile.TemporaryDirectory(prefix='horos-t1-phantom-') as folder:
    work = Path(folder)
    destination = work / 'phantom'
    subprocess.run([sys.executable, str(generator), str(destination), '--size', str(SIZE)],
                   check=True, capture_output=True)
    spec = importlib.util.spec_from_file_location('phantom', generator)
    phantom = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(phantom)

    ir = read(destination / 'ir', 'ti-*.dcm')
    vfa = read(destination / 'vfa', 'fa-*.dcm')
    times = [float(item.InversionTime) for item, _ in ir]
    angles = [float(item.FlipAngle) for item, _ in vfa]
    if times != list(phantom.INVERSION_TIMES_MS):
        failures.append(f'inversion times {times}')
    if angles != list(phantom.FLIP_ANGLES_DEG):
        failures.append(f'flip angles {angles}')
    if {float(item.RepetitionTime) for item, _ in vfa} != {phantom.VFA_REPETITION_TIME_MS}:
        failures.append('the flip angle series has more than one repetition time')
    if any('InversionTime' in item for item, _ in vfa):
        failures.append('the flip angle series carries an inversion time')
    if any(item.SeriesInstanceUID != ir[0][0].SeriesInstanceUID for item, _ in ir) \
            or ir[0][0].SeriesInstanceUID == vfa[0][0].SeriesInstanceUID:
        failures.append('each acquisition is not one series of its own')

    # The stored pixels are each compartment's curve, rounded.
    for (item, pixels), time in zip(ir, times):
        for row, column in ((3, 3), (3, 12), (12, 3), (12, 12), (0, 0)):
            t1 = phantom.compartment(row, column, SIZE)
            expected = 0 if t1 is None else round(phantom.inversion_recovery(t1, time))
            if pixels[row * SIZE + column] != expected:
                failures.append(f'IR TI {time} pixel {row},{column}: {pixels[row * SIZE + column]} != {expected}')

    driver = '''
import Foundation

func check(_ name: String, _ images: [[Float]], _ acquisitions: [T1Fitting.Acquisition], _ method: T1Fitting.Method,
           _ truth: [Double], border: Int, size: Int) -> Bool {
    let groups = T2FitMapping.groups(origins: images.map { _ in SIMD3<Double>(0, 0, 0) })
    let result = T1Fitting.map(groups: groups, size: (width: size, height: size)) { coordinate in
        T1Fitting.Image(width: size, height: size, acquisition: acquisitions[coordinate.slice], samples: images[coordinate.slice])
    }
    guard case .success(let map) = result else { print("FAIL: \\(name): \\(result)"); return false }
    var ok = map.methods == [method]
    if !ok { print("FAIL: \\(name) fitted as \\(map.methods)") }
    var worst = 0.0
    for row in 0..<size {
        for column in 0..<size {
            let value = Double(map.volume[row * size + column])
            if min(row, column) < border || max(row, column) >= size - border {
                if value != 0 { print("FAIL: \\(name) border \\(row),\\(column) = \\(value)"); ok = false }
                continue
            }
            let expected = truth[(row < size / 2 ? 0 : 2) + (column < size / 2 ? 0 : 1)]
            worst = max(worst, abs(value - expected) / expected)
        }
    }
    let inner = (size - 2 * border) * (size - 2 * border)
    if map.counts != T1Fitting.Counts(fitted: inner, belowThreshold: size * size - inner) {
        print("FAIL: \\(name) counts \\(map.counts)"); ok = false
    }
    if worst > 0.01 { print("FAIL: \\(name) worst relative error \\(worst)"); ok = false }
    print("\\(name): \\(map.counts.fitted) voxels fitted, \\(map.counts.belowThreshold) below the threshold, worst error \\(worst)")
    return ok
}

let truth: [Double] = %(truth)s
let irImages: [[Float]] = [%(ir)s]
let irAcquisitions = %(times)s.map { T1Fitting.Acquisition(inversionTime: $0, repetitionTime: %(ir_tr)r, flipAngle: 90) }
let vfaImages: [[Float]] = [%(vfa)s]
let vfaAcquisitions = %(angles)s.map { T1Fitting.Acquisition(repetitionTime: %(vfa_tr)r, flipAngle: $0) }
let ir = check("inversion recovery", irImages, irAcquisitions, .inversionRecovery, truth, border: %(border)d, size: %(size)d)
let vfa = check("variable flip angle", vfaImages, vfaAcquisitions, .variableFlipAngle, truth, border: %(border)d, size: %(size)d)
exit(ir && vfa ? 0 : 1)
''' % {
        'truth': swift_array(phantom.T1_MS),
        'ir': ',\n'.join(swift_array(pixels) for _, pixels in ir),
        'times': swift_array(times),
        'ir_tr': float(ir[0][0].RepetitionTime),
        'vfa': ',\n'.join(swift_array(pixels) for _, pixels in vfa),
        'angles': swift_array(angles),
        'vfa_tr': float(vfa[0][0].RepetitionTime),
        'border': phantom.BORDER,
        'size': SIZE,
    }
    (work / 'main.swift').write_text(driver)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-O', '-module-name', 'T1Phantom',
                            *map(str, sources), str(work / 'main.swift'), '-o', str(work / 'fit')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('T1Fitting does not build: ' + built.stderr[-2000:])
    else:
        run = subprocess.run([str(work / 'fit')], capture_output=True, text=True, timeout=120)
        print(run.stdout.strip())
        if run.returncode != 0:
            failures.append((run.stdout + run.stderr).strip())

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: the generated T1 phantoms carry their inversion times, flip angles and repetition time, '
      'and T1Fitting recovers 300/700/1200/2000 ms within 1% by inversion recovery and by variable flip angle')

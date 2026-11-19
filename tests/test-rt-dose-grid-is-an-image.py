#!/usr/bin/env python3
"""The dose grid of a radiotherapy plan is shown as the images it carries.

An object of the RT Dose Storage class carries Pixel Data, a plane of the dose
grid in each frame, but the class was among those the viewer takes for "not an
image": the series opened on an empty frame that said so. What is checked:

- the classes (the IsiXDICOMFile module, compiled here): RT Dose is the one
  radiotherapy class that is a dose grid; the lists of image and of non-image
  classes are as they were, for the listener and for whoever asks them;
- the viewer reads the frames of a dose grid that has Pixel Data as any
  image's, before the rule that draws an empty frame, and a radiotherapy object
  without pictures still gets that frame;
- a series of dose grids counts among the series that hold pictures;
- the fixture generator writes objects of that class as it says: frames,
  planes, scaling and stored values, read back with pydicom when there is one.

The dose itself, the stored value times Dose Grid Scaling in the unit Dose
Units names, is IsiXImagingTests.ImageAttributeReaderTests.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from isix_modules import build_module  # noqa: E402
import python_with  # noqa: E402

pix = (root / 'Horos/Sources/DCMPix+EncapsulatedDocuments.swift').read_text()
dose = pix.index('if DICOMSOPClass.isRTDose(sopClassUID) && dcmObject.attributeValue(withName: "PixelData") != nil {\n            return false')
empty = pix.index('if DICOMSOPClass.isNonImageStorage(sopClassUID) {\n            loadEmptyFrame(dcmObject)')
assert dose < empty, 'a dose grid with Pixel Data is drawn as an empty frame'

study = (root / 'Horos/Sources/DicomStudy.swift').read_text()
assert 'if uid == nil || DICOMSOPClass.isImageStorage(uid) || DICOMSOPClass.isRTDose(uid) {' in study, \
    'a series of dose grids is not among the series with pixels'
assert '|| DICOMSOPClass.isRTDose(uid)' in study[study.index('func isPictureSeries(sopClassUID uid: String?)'):][:400], \
    'a series of dose grids is sorted among the documents'

program = r"""
import Foundation
import IsiXDICOMFile
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
let rtDose = "1.2.840.10008.5.1.4.1.1.481.2"
// RT Image is an image class; the others are the radiotherapy objects without pictures.
let others = ["1.2.840.10008.5.1.4.1.1.481.3": "RT Structure Set", "1.2.840.10008.5.1.4.1.1.481.5": "RT Plan",
              "1.2.840.10008.5.1.4.1.1.481.4": "RT Beams Treatment Record", "1.2.840.10008.5.1.4.1.1.481.6": "RT Brachy Treatment Record",
              "1.2.840.10008.5.1.4.1.1.481.7": "RT Treatment Summary Record"]
check(DICOMSOPClass.isRTDose(rtDose), "RT Dose is not a dose grid")
check(DICOMSOPClass.isRadiotherapy(rtDose) && DICOMSOPClass.isNonImageStorage(rtDose) && !DICOMSOPClass.isImageStorage(rtDose),
      "the lists of classes changed for RT Dose")
for (uid, name) in others {
    check(!DICOMSOPClass.isRTDose(uid), "\(name) is taken for a dose grid")
    check(DICOMSOPClass.isRadiotherapy(uid) && DICOMSOPClass.isNonImageStorage(uid), "\(name) is no longer a radiotherapy object without pictures")
}
check(!DICOMSOPClass.isRTDose("1.2.840.10008.5.1.4.1.1.2") && !DICOMSOPClass.isRTDose(nil) && !DICOMSOPClass.isRTDose("1.2.840.10008.5.1.4.1.1.481.1"),
      "a CT image, an RT image or no class is taken for a dose grid")
print("PASS: RT Dose is the radiotherapy class that is a dose grid; the lists of image and non-image classes are as they were")
"""
with tempfile.TemporaryDirectory(prefix='horos-rt-dose-') as tmp:
    p = Path(tmp)
    modules = p / 'modules'
    build_module('IsiXImaging', modules)
    build_module('IsiXDICOMFile', modules, ['-I', str(modules)])
    (p / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-I', str(modules), '-L', str(modules), '-lIsiXDICOMFile', '-lIsiXImaging', '-lIsiXPreferences',
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    done = subprocess.run([str(p / 'test')], capture_output=True, text=True)
    print(done.stdout.strip() or done.stderr.strip())
    if done.returncode:
        sys.exit(1)
    print('PASS: the viewer reads a dose grid with Pixel Data as images, and its series holds pictures')

    python = python_with.interpreter('import pydicom', 'import numpy')
    if python is None:
        print('NOTE: no Python with pydicom and numpy here: the fixture generator was not run')
        sys.exit(0)
    out = p / 'fixture'
    subprocess.run([python, str(root / 'tools/generate-rt-dose-fixture.py'), str(out)], check=True)
    check = r'''
import sys
from pathlib import Path
import numpy as np
from pydicom import dcmread
expected = {'oblique': (5, 'GY', 0.001, [0, 6, 12, 18, 24]), 'absolute': (6, 'GY', 0.0005, [50, 53, 56, 59, 62, 65]),
            'relative': (7, 'RELATIVE', 0.01, [0, 2, 4, 6, 8, 10, 12])}
files = sorted(Path(sys.argv[1]).glob('*.dcm'))
assert [f.stem for f in files] == sorted(expected), [f.name for f in files]
for f in files:
    ds = dcmread(f)
    frames, units, scaling, vector = expected[f.stem]
    assert ds.SOPClassUID == '1.2.840.10008.5.1.4.1.1.481.2' and ds.file_meta.MediaStorageSOPClassUID == ds.SOPClassUID, f.name
    assert ds.Modality == 'RTDOSE' and int(ds.NumberOfFrames) == frames and ds.DoseUnits == units, f.name
    assert abs(float(ds.DoseGridScaling) - scaling) < 1e-12 and [float(v) for v in ds.GridFrameOffsetVector] == vector, f.name
    assert ds.BitsAllocated == 16 and ds.PixelRepresentation == 0 and ds.FrameIncrementPointer == 0x3004000C, f.name
    stored = np.frombuffer(ds.PixelData, dtype=np.uint16).reshape(frames, ds.Rows, ds.Columns)
    for k in range(frames):
        assert stored[k, 3, 5] == 1000 * (k + 1) + 35 and stored[k, 0, 0] == 1000 * (k + 1), (f.name, k)
print('PASS: the generator writes three RT Dose grids with the frames, planes, scaling and stored values it says')
'''
    (p / 'check.py').write_text(check)
    subprocess.run([python, str(p / 'check.py'), str(out)], check=True)
    refused = subprocess.run([python, str(root / 'tools/generate-rt-dose-fixture.py'), str(out)], capture_output=True, text=True)
    assert refused.returncode != 0 and 'empty output directory' in refused.stderr, 'the generator wrote into a directory that was not empty'

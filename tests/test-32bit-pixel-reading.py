#!/usr/bin/env python3
"""32-bit pixel data was copied into a float buffer and called floats.

The frame loading has one branch for `BitsAllocated == 32` - in
`-[DCMPix loadDICOMWithDCMTK]` then, in the IsiXImaging module's FrameLoader
now. It memcpy'd the words into the float image and only converted them when a
rescale happened to be there:

    memcpy( fImage, oImage, height * width * sizeof( float));
    if( slope != 1.0 || offset != 0 || […@"32bitDICOMAreAlwaysIntegers"])

Pixel Data (7fe0,0010) holds integers - the standard gives floating point pixels
their own attributes, (7fe0,0008) and (7fe0,0009) - so reinterpreting an integer
as an IEEE float turns any ordinary value into a denormal. Measured through the
series thumbnails the application itself builds, on a 64x64 left-to-right ramp:

    control: 16-bit unsigned ramp                   68 levels, monotone
    32-bit unsigned ramp, no rescale                 1 level
    32-bit signed ramp, no rescale                   1 level
    32-bit unsigned ramp with RescaleSlope 2        68 levels, monotone

One flat grey, which is the "all zeros" of the reports, and it went away as soon
as a rescale gave the file a reason to be converted.

The other half is the diagnosis: a file whose pixels are in Float Pixel Data was
reported as carrying "no pixel data at all", which is a false statement about a
file that carries a picture this application does not read. Neither (7fe0,0008)
nor (7fe0,0009) was in the vendored dictionary at all.
"""
from pathlib import Path
from dcmtk_build import dcmtk_flags
import subprocess
import sys
import tempfile
from sources import class_text

root = Path(__file__).resolve().parents[1]
failures = []
dcmtk = root / 'DCMTK'
pix = class_text('DCMPix')
frames = root / 'Modules/IsiXImaging/Sources'
loader = (frames / 'FrameLoader.swift').read_text()
load = (frames / 'FrameLoad.swift').read_text()
# The DICOM reading is Swift; the diagnosis's sentences are the IsiXDICOMFile module's.
reader = class_text('DicomFile')
rules = (root / 'Modules/IsiXDICOMFile/Sources/DICOMImportRules.swift').read_text()

# --- the words are converted, not reinterpreted --------------------------------
# DCMPix hands the frame to the module, with the preference; the module asks
# whether the object states Pixel Representation. The values themselves are
# checked by tests/test-dcmpix-frame-loading.py.
at = loader.find('func loadThirtyTwoBits(')
branch = loader[at:at + 1200] if at >= 0 else ''
if not branch or 'func loadFrame(' not in pix:
    failures.append('the 32-bit branch is gone')
else:
    asked = load[load.find('thirtyTwoBitWordsAreIntegers ='):load.find('thirtyTwoBitWordsAreIntegers =') + 200]
    if 'PixelRepresentation' not in asked:
        failures.append('nothing asks whether the object states Pixel Representation, which is '
                        'what says its Pixel Data holds integers')
    condition = branch[branch.find('if thirtyTwoBitWordsAreIntegers'):branch.find('if thirtyTwoBitWordsAreIntegers') + 200]
    if not condition:
        failures.append('a 32-bit integer image is still only converted when a rescale happens '
                        'to be present, so its values arrive as denormals')
    elif 'layout.slope != 1' not in condition or 'layout.offset != 0' not in condition:
        failures.append('the conversion no longer covers the cases it used to: %r' % condition)
    if '32bitDICOMAreAlwaysIntegers' not in pix or 'thirtyTwoBitPixelsAreIntegers' not in asked:
        failures.append('the preference that 32-bit pixels are always integers is no longer read')

# --- and a picture in another attribute is named, not denied -------------------
at = reader.find('func readPixelDataProblem(')
diagnosis = reader[at:reader.find('func readFrames(', at)] if at >= 0 else ''
at = rules.find('case let .absent(')
absent = rules[at:rules.find('case .native(', at)] if at >= 0 else ''
if not diagnosis or not absent:
    failures.append('the pixel-data diagnosis is gone')
else:
    for tag, flag, name in (('DicomFileTag.floatPixelData', 'if floatPixels', 'Float Pixel Data'),
                            ('DicomFileTag.doubleFloatPixelData', 'if doubleFloatPixels', 'Double Float Pixel Data')):
        if tag not in diagnosis or flag not in absent or name not in absent:
            failures.append('a file whose pixels are in %s is still reported as carrying none'
                            % name)
    if 'it carries no pixel data at all' not in absent:
        failures.append('a file that really has no pixel data is no longer named')

# --- the dictionary knows the attributes ---------------------------------------
DRIVER = '''
#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcdicent.h>
#include <cstdio>
int main() {
    DcmDataDictionary &dictionary = dcmDataDict.wrlock();
    const DcmTagKey keys[] = {DCM_PixelData, DCM_FloatPixelData, DCM_DoubleFloatPixelData};
    for (unsigned i = 0; i < 3; i++) {
        const DcmDictEntry *entry = dictionary.findEntry(keys[i], NULL);
        printf("%04x,%04x\\t%s\\n", keys[i].getGroup(), keys[i].getElement(),
               entry ? entry->getTagName() : "(absent)");
    }
    dcmDataDict.wrunlock();
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='horos-pixeltags-') as directory:
    driver = Path(directory) / 'main.cc'
    driver.write_text(DRIVER)
    binary = Path(directory) / 'pixeltags'
    build = subprocess.run(
        ['xcrun', 'clang++', '-std=c++11', str(driver), *dcmtk_flags(), '-o', str(binary)],
        capture_output=True, text=True)
    if build.returncode != 0:
        failures.append('the dictionary does not build with the pixel-data attributes:\n%s'
                        % build.stderr[-1200:])
    else:
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        named = dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)
        for tag, want in (('7fe0,0010', 'PixelData'),
                          ('7fe0,0008', 'FloatPixelData'),
                          ('7fe0,0009', 'DoubleFloatPixelData')):
            if named.get(tag) != want:
                failures.append('(%s) is %r, expected %r' % (tag, named.get(tag), want))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: 32-bit Pixel Data is read as the integers it holds, and a picture stored in Float or '
      'Double Float Pixel Data is named rather than denied')

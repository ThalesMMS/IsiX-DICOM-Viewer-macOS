#!/usr/bin/env python3
"""A frame with no pixels was shown as a picture of lines.

`-[DCMPix loadDICOMWithDCMTK]`, when a frame decoded to nothing, filled it in:

    long yo = 0;
    for( unsigned long i = 0 ; i < height * width; i++)
    {
        oImage[ i] = yo++;
        if( yo>= width) yo = 0;
    }

A ramp of 0..width-1 repeated on every row, which on screen is a picture of
bands - "lines instead of the examination" - and nothing said the pixels were
missing. An empty frame is now empty, and named.

Beside it, an object declaring a picture of zero width or zero height was copied
into the database folder and then dropped, with no row made for it and nothing
anywhere saying why. Measured on nine shapes that disagree with their pixels -
zero rows, zero columns, both zero, no Pixel Data element, an element of zero
length, four bytes for 64x64, PixelSpacing 0, 16384x16384 with one row, and four
frames with two frames of pixels - every one is now named:

    ---- 3.dcm: it declares a picture of 0 x 64
    ---- 5.dcm: its pixel data is empty; it is indexed and counted as an image anyway
    ---- 9.dcm: its pixel data is 16384 bytes where 32768 are needed for 64x64

and none of the nine crashed the application or stopped the database opening.
"""
from pathlib import Path
import re
import sys
from sources import class_text

root = Path(__file__).resolve().parents[1]
failures = []
pix = class_text('DCMPix')
# The DICOM reading is Swift (DicomFile+DICOMReading.swift); the messages are the
# IsiXDICOMFile module's rules.
reader = class_text('DicomFile') + (root / 'Modules/IsiXDICOMFile/Sources/DICOMImportRules.swift').read_text()


def strip(text):
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


# --- a frame with no pixels is empty, not invented -----------------------------
# DCMPix hands the decoded frame to the IsiXImaging module's frame loading,
# which fills what the frame does not carry with zeros;
# tests/test-dcmpix-frame-loading.py checks the empty frames' pixels.
code = strip(pix)
loader = strip((root / 'Modules/IsiXImaging/Sources/FrameLoader.swift').read_text())
at = code.find('if (pixData?.length ?? 0) == 0 {')
branch = code[at:at + 900] if at >= 0 else ''
if not branch:
    failures.append('the branch for a frame that decoded to nothing is gone')
else:
    if 'yo++' in branch or 'yo >= width' in branch or 'yo>= width' in branch:
        failures.append('a frame with no pixels is still filled with a ramp, which is the '
                        'picture of lines the reports describe')
    if 'memset' not in loader:
        failures.append('the empty frame is not zeroed, so it shows whatever malloc returned')
    if 'NSLog' not in branch:
        failures.append('nothing says the frame had no pixels')

# --- a frame that could not be read borrows the volume's buffer ---------------
# When the viewer opens a series it allocates one buffer for the whole volume and
# hands each image a slice of it. The failure branch adopted that slice without
# clearing it and then called the frame 128 by 128, which for a 64x64 image is
# four times what the slice holds: the view drew the frames beside it as black
# and white noise, under the sentence saying the image could not be read.
# Other paths set the same flag - an unloadable IVUS cine refuses before
# decoding, for one - so anchor on the branch that adopts the volume's buffer
# rather than on the first occurrence of the flag.
branch = ''
at = code.find('horos_notAbleToLoadImage = true')
while at >= 0:
    window = code[max(at - 900, 0):at + 500]
    if 'horos_fImage = volume' in window:
        branch = window
        break
    at = code.find('horos_notAbleToLoadImage = true', at + 1)
if not branch:
    failures.append('the branch for an image that could not be read is gone')
else:
    if 'memset' not in branch:
        failures.append('the frame that could not be read is not cleared, so it shows whatever '
                        'the buffer it borrowed held')
    if 'savedWidthInDB' not in branch:
        failures.append('the frame is still resized without regard for the buffer it borrowed')
    resize = branch[branch.find('horos_fExternalOwnedImage'):]
    if re.search(r'horos_fImage = volume[^}]*horos_width = 128', resize, flags=re.S):
        failures.append('an adopted buffer is still called 128 by 128, which reads past its end')

# --- a frame shorter than the picture says so ---------------------------------
# The module detects a short frame in its three readers - colour, 8-bit grey,
# 16-bit grey - and DCMPix names the one it reports.
if code.count('reportShortFrame(') != 2 or 'load.shortFrameNeeded' not in code:      # the method and its caller
    failures.append('a frame shorter than the image is not named where the module reports it')
if loader.count('report(frame.count, of:') != 3:
    failures.append('a frame shorter than the image is not reported everywhere it is detected')

# --- and a shape that is not a shape is named ----------------------------------
diagnosis = strip(reader)
at = diagnosis.find('rows == 0 || columns == 0')
if at < 0:
    failures.append('an object that declares a picture of zero width or height is still dropped '
                    'without anything saying so')
else:
    window = diagnosis[max(at - 300, 0):at + 600]
    if 'pixelDataProblem' not in window or 'NSLog' not in window:
        failures.append('the zero-sized picture is recognised and not reported')
    if 'claimsAPicture' not in window:
        failures.append('the check no longer asks whether the object claims a picture at all, so '
                        'an object that states no dimensions would be judged for having none')

# The checks that were already there have to survive beside the new one.
for fragment in ('it carries no pixel data at all', 'its pixel data is empty',
                 'bytes where \\(expected) are needed'):
    if fragment not in reader:
        failures.append('the diagnosis lost %r' % fragment)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a frame with no pixels is shown empty and named, and an object whose declared shape '
      'is not a shape is named rather than silently dropped')

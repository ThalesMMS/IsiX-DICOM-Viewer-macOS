#!/usr/bin/env python3
"""DCMPix reads the attributes and the geometry of an image as it always did.

The reading of the attributes that describe an image - spacing, orientation
and position, the normal and the slice location, rescale, the window, the
shared and per-frame functional groups of an enhanced object, the overlays of
group 6000, the SUV parameters, shutters and ultrasound regions - moved from
DCMPix.m to the IsiXImaging module, with DCMPix delegating to it.

tests/dcmpix_attribute_harness.py cuts that reading out of a revision of
DCMPix.m and runs it on synthetic CT, MR, PET, US, NM and enhanced multiframe
data sets, including mistyped values and malformed sequences, and on two
thousand pseudo-random plane geometries. This test

* checks what the reading of this checkout produces against values worked out
  by hand for the plainer cases, and
* when this checkout delegates to the module, runs the Objective-C reading of
  the revision before the move on the same input and requires every field, the
  sizes written back to the database, the exceptions raised and logged and the
  log lines to be identical - floating-point values to the bit - except where
  this checkout corrects that reading on purpose (CORRECTED below): there the
  reference has to show the fault and this checkout the correction.

Usage: test-dcmpix-attribute-reading.py [REFERENCE_REVISION]
"""
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dcmpix_attribute_harness as harness  # noqa: E402
from history_reference import before_text_removed, show  # noqa: E402
from isix_modules import build_module  # noqa: E402


def committed(path):
    """`path` as HEAD has it, or nothing once HEAD no longer has the file."""
    try:
        return show('HEAD', path).decode('latin1')
    except subprocess.CalledProcessError:
        return ''


ROOT = Path(__file__).resolve().parents[1]
PIX = 'Horos/Sources/DCMPix.m'

if shutil.which('xcrun') is None:
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)


def date(d=None, t=None):
    value = {}
    if d is not None:
        value['date'] = d
    if t is not None:
        value['time'] = t
    return value


def seq(*items):
    return {'seq': list(items)}


BYTES = {'bytes': '0102030405060708'}
AXIAL = ['1', '0', '0', '0', '1', '0']

CT = {
    'SOPClassUID': '1.2.840.10008.5.1.4.1.1.2', 'ImageType': ['ORIGINAL', 'PRIMARY', 'AXIAL'],
    'Rows': 512, 'Columns': 512, 'BitsAllocated': 16, 'BitsStored': 12, 'PixelRepresentation': 1,
    'RescaleIntercept': '-1024', 'RescaleSlope': '1', 'RescaleType': 'HU', 'WindowCenter': '40', 'WindowWidth': '400',
    'PixelSpacing': ['0.703125', '0.703125'], 'SliceThickness': '1.25', 'SpacingBetweenSlices': '1.25',
    'ImagePositionPatient': ['-180', '-180', '-37.5'], 'ImageOrientationPatient': AXIAL,
    'FrameofReferenceUID': '1.2.826.0.1.3680043.2.1412.1', 'PhotometricInterpretation': 'MONOCHROME2',
    'PatientPosition': 'HFS', 'PatientsWeight': '72.5',
}
OBLIQUE = dict(CT, **{
    'Rows': 383, 'Columns': 257, 'PixelSpacing': ['0.4882812', '0.53125'],
    'ImagePositionPatient': ['-123.456789', '87.654321', '-12.3456789'],
    'ImageOrientationPatient': ['0.9659258', '0.2588190', '0.0123', '-0.2578', '0.9640', '0.0712'],
    'RescaleType': 'houndsfield unit',
})
MR = {
    'SOPClassUID': '1.2.840.10008.5.1.4.1.1.4', 'Rows': 256, 'Columns': 192, 'BitsAllocated': 16, 'BitsStored': 16,
    'PixelRepresentation': 0, 'PixelSpacing': ['0.9375', '0.9375'], 'SliceThickness': '4', 'SpacingBetweenSlices': '4.4',
    'ImagePositionPatient': ['12.5', '-120', '110'], 'ImageOrientationPatient': ['0', '1', '0', '0', '0', '-1'],
    'RepetitionTime': '500', 'EchoTime': 12, 'FlipAngle': '90', 'ImageLaterality': 'L', 'ViewPosition': 'AP',
    'PositionerPrimaryAngle': '12.5', 'PositionerSecondaryAngle': -7, 'WindowCenter': ['600', '700'],
    'WindowWidth': ['1200', '1400'], 'PhotometricInterpretation': 'MONOCHROME2', 'FrameofReferenceUID': '1.2.3.4',
}
PET = {
    'SOPClassUID': '1.2.840.10008.5.1.4.1.1.128', 'Rows': 128, 'Columns': 128, 'BitsAllocated': 16, 'BitsStored': 16,
    'PixelRepresentation': 1, 'RescaleSlope': '0.0123', 'RescaleIntercept': '0', 'PixelSpacing': ['4.0728', '4.0728'],
    'SliceThickness': '3.27', 'ImagePositionPatient': ['-260.6', '-260.6', '-100.5'], 'ImageOrientationPatient': AXIAL,
    'PatientsWeight': '81', 'Units': 'BQML', 'DecayCorrection': 'START',
    'SeriesDate': date('20260320'), 'SeriesTime': date(t='101500.000000'),
    'AcquisitionDate': date('20260321'), 'AcquisitionTime': date(t='103000.250000'),
    'ContentDate': date('20260322'), 'ContentTime': date(t='104500'),
    'StudyDate': date('20260319'), 'StudyTime': date(t='094500'),
    'RadiopharmaceuticalInformationSequence': seq({
        'RadionuclideTotalDose': '370000000', 'RadionuclideHalfLife': '6586.2',
        'RadiopharmaceuticalStartTime': date(t='091000.000000'),
    }),
    '7053,1000': '0.000561',
}


def shared_groups(numberOfFrames):
    return seq({
        # Repetition time and flip angle are stated here only, for every frame.
        'MRTimingAndRelatedParametersSequence': seq({'RepetitionTime': '8.2', 'FlipAngle': '15'}),
        'PlaneOrientationSequence': seq({'ImageOrientationPatient': ['1', '0', '0', '0', '0.8660254', '-0.5']}),
        'PixelMeasuresSequence': seq({'PixelSpacing': ['0.8', '0.75'], 'SliceThickness': '3', 'SpacingBetweenSlices': '3.3'}),
        'FrameVOILUTSequence': seq({'WindowCenter': '300', 'WindowWidth': '-1500'}),
        'PixelValueTransformationSequence': seq({'RescaleIntercept': '-1000', 'RescaleSlope': '2', 'RescaleType': 'houndsfield unit'}),
    })


def per_frame(z, window=None):
    item = {
        'PlanePositionSequence': seq({'ImagePositionPatient': ['-100', '-80.5', z]}),
        'PixelMeasuresSequence': seq({'PixelSpacing': ['0.8', '0.75']}),
        'PixelValueTransformationSequence': seq({'RescaleIntercept': '-1024', 'RescaleSlope': '1'}),
        'MREchoSequence': seq({'EchoTime': '4.5'}),
    }
    if window:
        item['FrameVOILUTSequence'] = seq({'WindowCenter': window[0], 'WindowWidth': window[1]})
    return item


ENHANCED = {
    'SOPClassUID': '1.2.840.10008.5.1.4.1.1.4.1', 'Rows': 96, 'Columns': 80, 'BitsAllocated': 16, 'BitsStored': 12,
    'PixelRepresentation': 0, 'NumberofFrames': 3, 'ImageType': ['ORIGINAL', 'PRIMARY'],
    'SharedFunctionalGroupsSequence': shared_groups(3),
    'Per-frameFunctionalGroupsSequence': seq(per_frame('10'), per_frame('13.3', ('50', '350')), per_frame('16.6')),
}
LEGACY = dict(ENHANCED, **{'ImagePositionPatient': ['1', '2', '3'], 'ImageOrientationPatient': AXIAL})
# An enhanced object states its Frame of Reference UID once, at the top level;
# the plane position and orientation items of each frame do not repeat it.
ENHANCED_FRAME_OF_REFERENCE = '1.2.826.0.1.3680043.2.9.7'
ENHANCED_WITH_FRAME_OF_REFERENCE = dict(ENHANCED, FrameofReferenceUID=ENHANCED_FRAME_OF_REFERENCE)
# The echo time of an enhanced MR is Effective Echo Time, in each frame's
# MREchoSequence item, or in the shared one for a frame that states none.
ECHOES = (10, 20.5, 99.5)
ENHANCED_ECHOES = dict(ENHANCED, **{
    'SharedFunctionalGroupsSequence': seq(dict(shared_groups(3)['seq'][0], MREchoSequence=seq({'EffectiveEchoTime': {'double': ECHOES[2]}}))),
    'Per-frameFunctionalGroupsSequence': seq(
        dict(per_frame('10'), MREchoSequence=seq({'EffectiveEchoTime': {'double': ECHOES[0]}})),
        dict(per_frame('13.3'), MREchoSequence=seq({'EffectiveEchoTime': {'double': ECHOES[1]}})),
        {k: v for k, v in per_frame('16.6').items() if k != 'MREchoSequence'}),
})
US = {
    'SOPClassUID': '1.2.840.10008.5.1.4.1.1.3.1', 'Rows': 480, 'Columns': 640, 'BitsAllocated': 8, 'BitsStored': 8,
    'PhotometricInterpretation': 'RGB', 'PlanarConfiguration': 0, 'FrameTime': '33.3', 'PixelAspectRatio': ['4', '3'],
    'SequenceofUltrasoundRegions': seq(
        {'RegionSpatialFormat': 1, 'RegionDataType': 1, 'RegionFlags': 2, 'RegionLocationMinX0': 10, 'RegionLocationMinY0': 20,
         'RegionLocationMaxX1': 600, 'RegionLocationMaxY1': 460, 'ReferencePixelX0': 320, 'PhysicalUnitsXDirection': 3,
         'PhysicalUnitsYDirection': 3, 'PhysicalDeltaX': '-0.0213', 'PhysicalDeltaY': '0.0213', 'ReferencePixelPhysicalValueX': '0'},
        {'RegionSpatialFormat': 3, 'PhysicalUnitsXDirection': 4, 'PhysicalUnitsYDirection': 7, 'PhysicalDeltaX': '0.01',
         'PhysicalDeltaY': '2.5', 'DopplerCorrectionAngle': '60'}),
}
NM = {
    'SOPClassUID': '1.2.840.10008.5.1.4.1.1.20', 'Rows': 64, 'Columns': 64, 'BitsAllocated': 16, 'BitsStored': 16,
    'PixelSpacing': ['6.8', '6.8'], 'SliceThickness': '6.8',
    'DetectorInformationSequence': seq({'ImagePositionPatient': ['-217.6', '-217.6', '-150'],
                                        'ImageOrientationPatient': ['0', '0', '0', '0', '0', '0']}),
}


def overlay_bits(rows, columns, set_pixels):
    words = [0] * ((rows * columns + 15) // 16)
    for p in set_pixels:
        words[p // 16] |= 1 << (p % 16)
    return {'bytes': ''.join('%02x%02x' % (w & 0xFF, w >> 8) for w in words)}


OVERLAYS = dict(CT, **{
    '6000,3000': overlay_bits(4, 16, [0, 5, 17, 63]), '6000,0010': 4, '6000,0011': 16, '6000,0040': 'G',
    '6000,0050': [3, 7], '6000,0100': 1, '6000,0102': 0,
    '6004,3000': overlay_bits(2, 8, [1]), '6004,0010': '2', '6004,0011': 8, '6004,0040': 'R', '6004,0100': 1, '6004,0102': 0,
    '6006,3000': overlay_bits(2, 8, [2]), '6006,0010': 2, '6006,0011': 8, '6006,0100': 8,
    '6008,3000': overlay_bits(2, 8, [3]), '6008,0010': 2, '6008,0011': 8, '6008,0040': '', '6008,0100': 1, '6008,0102': 0,
    '601E,3000': 7, '601E,0010': 1, '601E,0011': 16, '601E,0100': 1, '601E,0102': 0,
})
SHUTTERS = dict(CT, **{
    'ShutterShape': ['RECTANGULAR', 'CIRCULAR', 'POLYGONAL', 'ELLIPTICAL'],
    'ShutterLeftVerticalEdge': '10', 'ShutterRightVerticalEdge': '500.5', 'ShutterUpperHorizontalEdge': 12,
    'ShutterLowerHorizontalEdge': '400', 'CenterofCircularShutter': ['256', '250'], 'RadiusofCircularShutter': '200.7',
    'VerticesofthePolygonalShutter': ['1', '2', '30', '4', '50', '60'],
})


def fixture(name, *datasets, settle=True, **context):
    return {'name': name, 'datasets': list(datasets), 'settle': settle, 'context': context}


FIXTURES = [
    fixture('ct', CT, savedHeight=512, savedWidth=512),
    fixture('ct-oblique', OBLIQUE),
    fixture('mr', MR, savedHeight=256, savedWidth=192),
    fixture('mr-reload', MR, dict(MR, ImageLaterality=None, Laterality='R', EchoTime=BYTES), {}),
    fixture('pet-series-time', PET, suvField=0),
    fixture('pet-acquisition-time', PET, suvField=1),
    fixture('pet-content-time', PET, suvField=2),
    fixture('pet-study-time', PET, suvField=3),
    fixture('pet-admin', dict(PET, DecayCorrection='ADMIN', **{'7053,1000': BYTES}), suvField=1),
    fixture('pet-no-times', dict(PET, SeriesTime=None, AcquisitionTime=None, ContentTime=None, StudyTime=None)),
    fixture('enhanced-frame-0', ENHANCED, frame=0, numberOfFrames=3),
    fixture('enhanced-frame-1', ENHANCED, frame=1, numberOfFrames=3),
    fixture('enhanced-frame-2', ENHANCED, frame=2, numberOfFrames=3),
    fixture('enhanced-single-frame', ENHANCED, frame=0, numberOfFrames=1),
    fixture('enhanced-missing-frame', ENHANCED, frame=7, numberOfFrames=3),
    fixture('legacy-converted', LEGACY, frame=2, numberOfFrames=3),
    fixture('enhanced-frame-of-reference', ENHANCED_WITH_FRAME_OF_REFERENCE, frame=1, numberOfFrames=3),
    *[fixture('enhanced-echo-%d' % frame, ENHANCED_ECHOES, frame=frame, numberOfFrames=3) for frame in range(3)],
    fixture('us', US),
    fixture('nm-frames', NM, NM, frame=3),
    fixture('nm-spacing', dict(NM, SpacingBetweenSlices='7.5', DetectorInformationSequence=seq(
        {'ImagePositionPatient': ['1', '2', '3'], 'ImageOrientationPatient': ['0', '1', '0', '0', '0', '-1']})), frame=2),
    fixture('overlays', OVERLAYS),
    fixture('shutters-ignored', SHUTTERS),
    fixture('shutters', SHUTTERS, useShutter=True),
    fixture('shutter-odd-polygon', dict(SHUTTERS, VerticesofthePolygonalShutter=['1', '2', '3']), useShutter=True),
    fixture('shutter-mistyped', dict(SHUTTERS, ShutterShape=[7]), useShutter=True),
    fixture('mistyped', dict(CT, WindowCenter=BYTES, WindowWidth=BYTES, RepetitionTime=BYTES, PatientPosition=BYTES,
                             PositionerPrimaryAngle=BYTES, ImagePositionPatient=[BYTES, '2', BYTES],
                             ImageOrientationPatient=['1', BYTES, '0', '0', '1', '0'], PixelSpacing=[BYTES, '0.5'],
                             FrameofReferenceUID=BYTES, SliceThickness=BYTES, Rows=BYTES)),
    fixture('rescale-type-number', dict(CT, RescaleType=5)),
    fixture('photometric-bytes', dict(CT, BitsAllocated=16, BitsStored=8, PhotometricInterpretation=BYTES)),
    fixture('rgb-8-in-16', dict(CT, BitsAllocated=16, BitsStored=8, PhotometricInterpretation='RGB')),
    fixture('palette', dict(CT, PhotometricInterpretation='PALETTE COLOR', WindowCenter='1', WindowWidth='2')),
    fixture('bits-stored-out-of-range', dict(CT, BitsStored=0), dict(CT, BitsStored=None, BitsAllocated=8), dict(CT, BitsStored=40)),
    fixture('imager-spacing', dict(CT, PixelSpacing=None, ImagerPixelSpacing=['0.143', '0.15'],
                                   EstimatedRadiographicMagnificationFactor='1.08')),
    fixture('single-spacing', dict(CT, PixelSpacing=['0.5'], PixelAspectRatio=['1', '0'])),
    fixture('absurd-spacing', dict(CT, PixelSpacing=['0.00001', '1'])),
    fixture('negative-spacing', dict(CT, PixelSpacing=['-0.5', '-0.25'])),
    fixture('cine', dict(CT, RecommendedDisplayFrameRate='0', CineRate='0', FrameDelay='-1', FrameTime='0', FrameTimeVector=['40', '41'])),
    fixture('cine-rate', dict(CT, CineRate='25', FrameTime='10')),
    fixture('database-size', dict(CT, Rows=600, Columns=500), savedHeight=512, savedWidth=512, external=True),
    fixture('database-size-unknown', CT, savedHeight=2147483647, savedWidth=2147483647),
    fixture('ophthalmic', dict(ENHANCED, **{'Per-frameFunctionalGroupsSequence': seq(
        {'OphthalmicFrameLocationSequence': seq({'ReferencedSOPInstanceUID': '1.2.3.9', 'ReferenceCoordinates': ['1.5', '2', '3', '4']})})}),
        frame=0, numberOfFrames=1),
    fixture('ophthalmic-without-coordinates', dict(ENHANCED, **{'Per-frameFunctionalGroupsSequence': seq(
        {'OphthalmicFrameLocationSequence': seq({'ReferencedSOPInstanceUID': '1.2.3.9'})})}), frame=0, numberOfFrames=1),
    fixture('empty-shared-item', dict(CT, SharedFunctionalGroupsSequence=seq({'PixelMeasuresSequence': seq()}))),
    fixture('shared-not-a-sequence', dict(CT, SharedFunctionalGroupsSequence='x')),
    fixture('shared-item-not-a-sequence', dict(CT, SharedFunctionalGroupsSequence=seq({'PlaneOrientationSequence': '1'}))),
    fixture('per-frame-not-a-sequence', dict(CT, **{'Per-frameFunctionalGroupsSequence': 3}), frame=0),
    fixture('per-frame-item-not-a-sequence', dict(CT, **{'Per-frameFunctionalGroupsSequence': seq({'PlanePositionSequence': 'x'})}), frame=0),
    fixture('per-frame-empty-item', dict(CT, **{'Per-frameFunctionalGroupsSequence': seq({'PlanePositionSequence': seq()})}), frame=0),
    fixture('radiopharmaceutical-mistyped', dict(PET, RadiopharmaceuticalInformationSequence=seq({'RadionuclideTotalDose': BYTES}))),
    fixture('radiopharmaceutical-not-a-sequence', dict(PET, RadiopharmaceuticalInformationSequence='x')),
    fixture('date-mistyped', dict(PET, SeriesDate='20260320'), suvField=0),
    fixture('detector-mistyped', dict(NM, DetectorInformationSequence=seq({'ImageOrientationPatient': ['0', BYTES]}))),
    fixture('ultrasound-region-mistyped', dict(US, SequenceofUltrasoundRegions=seq({'RegionSpatialFormat': BYTES}))),
    fixture('ultrasound-regions-not-a-sequence', dict(US, SequenceofUltrasoundRegions='x')),
    fixture('aspect-mistyped', dict(CT, PixelAspectRatio=[BYTES, '1'])),
    fixture('image-position-volume', dict(CT, ImagePositionPatient=['1', '2'], ImagePositionVolume=['4', '5', '6'],
                                          ImageOrientationPatient=None, ImageOrientationVolume=['0', '0', '1', '1', '0', '0'])),
    fixture('no-geometry', {'Rows': 32, 'Columns': 48}),
    fixture('empty', {}),
]


def clean(fixtures):
    """None removes an attribute that a dict(...) above inherited."""
    def strip(value):
        if isinstance(value, dict):
            if 'seq' in value:
                return {'seq': [strip(item) for item in value['seq']]}
            return {k: strip(v) for k, v in value.items() if v is not None}
        return value
    for f in fixtures:
        f['datasets'] = [strip(d) for d in f['datasets']]
    return fixtures


FIXTURES = clean(FIXTURES)

failures = []

# Where this checkout corrects the Objective-C reading on purpose. For each
# fixture, the fields that are allowed to differ from the reference, each with
# a check of the reference's value and this checkout's: the reference has to
# show the fault the case covers, or the case no longer proves the correction.
# The log of a corrected fixture may differ as well.
def shared_timing(old, new, also=()):
    """The repetition time and flip angle of the shared MR timing item: the
    position and orientation loader it was handed read neither. The fields in
    `also` are left to their own check."""
    rest = [i for i in range(len(old)) if i not in (4, 6, *also)]
    return (old[4] is None and old[6] is None and new[4] == '8.2' and new[6] == '15'
            and [old[i] for i in rest] == [new[i] for i in rest])


CORRECTED = {
    # The nested plane items, which carry no Frame of Reference UID, wiped the
    # object's own.
    'enhanced-frame-of-reference': {
        'text': lambda old, new: old[3] is None and new[3] == ENHANCED_FRAME_OF_REFERENCE and shared_timing(old, new, also=(3,)),
    },
    # Reference Coordinates were read as their first value, which was asked
    # for a count: the reading raised and the frame did not load. Read whole,
    # the reading goes on to the normal and the slice location.
    'ophthalmic': {
        'text': shared_timing,
        'raised': lambda old, new: old == 'NSInvalidArgumentException' and new is None,
        'referenceCoordinates': lambda old, new: old == [hexf(0)] * 4 and new == [hexf(v) for v in (1.5, 2, 3, 4)],
        'orientation': lambda old, new: old[:6] == new[:6] and old[6:] == [hexf(0), hexf(0), hexf(1)] and new[6:] != old[6:],
        'slice': lambda old, new: old[:2] == new[:2] and old[2] == hexf(0) and new[2] != old[2],
    },
    # The shared MRTimingAndRelatedParametersSequence went to the position and
    # orientation loader, not to the acquisition parameters.
    **{name: {'text': shared_timing} for name in ('enhanced-frame-0', 'enhanced-frame-1', 'enhanced-frame-2', 'enhanced-single-frame',
                                                  'enhanced-missing-frame', 'legacy-converted', 'ophthalmic-without-coordinates')},
    # Effective Echo Time, in the MR echo items, was not read.
    **{'enhanced-echo-%d' % frame: {'text': lambda old, new, echo=echo: old[5] is None and new[5] == '%g' % echo
                                    and shared_timing(old, new, also=(5,))}
       for frame, echo in enumerate(ECHOES)},
    # The Overlay Origin key was written without its comma and never found:
    # the overlay stayed at the image's corner.
    'overlays': {
        'overlays': lambda old, new: old[0][4:6] == [0, 0] and new[0][4:6] == [6, 2]
                                     and old[0][:4] + old[0][6:] == new[0][:4] + new[0][6:] and old[1:] == new[1:],
    },
}


def without_corrected(logs):
    """The log lines, without those of the corrected fixtures."""
    kept, skipping = [], False
    for line in logs:
        if line.startswith('=== '):
            skipping = line.split()[1] in CORRECTED
        if not skipping:
            kept.append(line)
    return kept


def state(states, name, step=0):
    return next(s['state'] for s in states if s['fixture'] == name and s['step'] == step)


def hexf(v):
    """A double as C's %a writes it: no trailing zeros in the fraction."""
    text = float.hex(float(v))
    mantissa, exponent = text.split('p')
    if '.' in mantissa:
        mantissa = mantissa.rstrip('0').rstrip('.')
    return mantissa + 'p' + exponent


def single(v):
    """A value rounded to a C float."""
    return struct.unpack('f', struct.pack('f', float(v)))[0]


def expect(condition, message):
    if not condition:
        failures.append(message)


def check_expectations(states, geometry):
    """What the reading has to produce, worked out by hand."""
    ct = state(states, 'ct')
    expect(ct['raised'] is None, 'the CT raised %r' % ct['raised'])
    expect(ct['origin'] == [hexf(-180), hexf(-180), hexf(-37.5)], 'the CT origin is %r' % ct['origin'])
    expect(ct['orientation'] == [hexf(v) for v in (1, 0, 0, 0, 1, 0, 0, 0, 1)], 'the CT orientation is %r' % ct['orientation'])
    expect(ct['spacing'][:3] == [hexf(0.703125), hexf(0.703125), hexf(1)], 'the CT spacing is %r' % ct['spacing'])
    expect(ct['slice'] == [hexf(1.25), hexf(1.25), hexf(-37.5)], 'the CT slice is %r' % ct['slice'])
    expect(ct['pixels'] == [1, 16, 12, 512, 512, 0, 0], 'the CT pixels are %r' % ct['pixels'])
    expect(ct['rescale'] == [hexf(1), hexf(-1024), 'HU'], 'the CT rescale is %r' % ct['rescale'])
    expect(ct['window'] == [hexf(40), hexf(400)], 'the CT window is %r' % ct['window'])
    expect(ct['storedSizes'] == [], 'the CT wrote a size %r' % ct['storedSizes'])

    oblique = state(states, 'ct-oblique')
    expect(oblique['rescale'][2] == 'HU', 'houndsfield unit is not read as HU')

    mr = state(states, 'mr')
    expect(mr['orientation'][6:] == [hexf(-1), hexf(0), hexf(0)], 'the sagittal normal is %r' % mr['orientation'][6:])
    expect(mr['slice'][2] == hexf(12.5), 'the sagittal slice location is %r' % mr['slice'][2])
    expect(mr['text'][4:10] == ['500', '12', '90', 'AP', None, 'L'], 'the MR parameters are %r' % mr['text'][4:10])
    expect(mr['angles'][:2] == ['12.5', '-7'] and mr['angles'][2] != 'nil', 'the positioner angles are %r' % mr['angles'])
    reload = state(states, 'mr-reload', 1)
    expect(reload['text'][9] == 'L' and reload['text'][5] is None, 'a reload kept %r' % reload['text'])

    for name, acquisition in (('pet-series-time', '20260320101500.000000'), ('pet-acquisition-time', '20260321103000.250000'),
                              ('pet-content-time', '20260322104500'), ('pet-study-time', '20260319094500')):
        pet = state(states, name)
        expect(pet['suv'][7] == acquisition, '%s counts the decay to %r' % (name, pet['suv'][7]))
        expect(pet['suv'][6] == acquisition[:8] + '091000.000000', '%s injected at %r' % (name, pet['suv'][6]))
        expect(pet['suv'][0] == hexf(81) and pet['suv'][2] == hexf(370000000), '%s dose %r' % (name, pet['suv']))
        expect(pet['suv'][3] != hexf(0), '%s has no corrected dose' % name)
    expect(state(states, 'pet-admin')['suv'][3] == hexf(370000000), 'ADMIN does not keep the injected dose')
    expect(state(states, 'pet-no-times')['suv'][6:] == [None, None], 'a PET without times got some')

    for frame, z, window in ((0, 10, (300, 1500)), (1, 13.3, (50, 350)), (2, 16.6, (300, 1500))):
        enhanced = state(states, 'enhanced-frame-%d' % frame)
        expect(enhanced['raised'] is None, 'frame %d raised %r' % (frame, enhanced['raised']))
        expect(enhanced['origin'][2] == hexf(z), 'frame %d is at %r' % (frame, enhanced['origin']))
        expect(enhanced['window'] == [hexf(window[0]), hexf(window[1])], 'frame %d window %r' % (frame, enhanced['window']))
        expect(enhanced['spacing'][:2] == [hexf(0.75), hexf(0.8)], 'frame %d spacing %r' % (frame, enhanced['spacing']))
        expect(enhanced['rescale'][:2] == [hexf(1), hexf(-1024)], 'frame %d rescale %r' % (frame, enhanced['rescale']))
        expect(enhanced['pixels'][6] == 0, 'frame %d was read as colour' % frame)
        # Repetition time and flip angle are stated in the shared group only.
        expect(enhanced['text'][4] == '8.2' and enhanced['text'][6] == '15',
               'frame %d has repetition time and flip angle %r' % (frame, enhanced['text'][4:7]))
    expect(state(states, 'legacy-converted')['origin'][2] == hexf(16.6), 'a legacy converted frame is placed with the first')
    echoes = [state(states, 'enhanced-echo-%d' % frame)['text'][5] for frame in range(3)]
    expect(echoes == ['10', '20.5', '99.5'], 'the enhanced frames have echo times %r' % echoes)
    expect(state(states, 'mr')['text'][5] == '12', 'a classic MR lost its echo time')
    with_reference = state(states, 'enhanced-frame-of-reference')
    expect(with_reference['text'][3] == ENHANCED_FRAME_OF_REFERENCE,
           'an enhanced frame lost the object\'s frame of reference: %r' % with_reference['text'][3])
    expect(with_reference['origin'][2] == hexf(13.3), 'the enhanced frame with a frame of reference is at %r' % with_reference['origin'])

    us = state(states, 'us')
    expect(len(us['usRegions']) == 2, 'the ultrasound regions are %r' % us['usRegions'])
    expect(us['spacing'][:2] == [hexf(abs(-0.0213) * 10), hexf(0.0213 * 10)] and us['spacingFromUltrasoundRegions'],
           'the ultrasound spacing is %r' % us['spacing'])
    expect(us['cineRate'] == hexf(single(1000.0 / single(33.3))), 'the frame time gives %r' % us['cineRate'])
    expect(us['spacing'][2] == hexf(1), 'regions in centimetres still let the aspect ratio stand: %r' % us['spacing'])

    nm = state(states, 'nm-frames', 1)
    expect(nm['origin'] == [hexf(-217.6), hexf(-217.6), hexf(-150 + 3 * 6.8)], 'the NM frame is at %r' % nm['origin'])
    expect(nm['orientation'] == [hexf(v) for v in (1, 0, 0, 0, 1, 0, 0, 0, 1)], 'the NM orientation is %r' % nm['orientation'])

    overlays = state(states, 'overlays')['overlays']
    # Overlay Origin 3\7 is row 3, column 7: zero-based column 6, row 2.
    expect(overlays[0] == [1, 4, 16, ord('G'), 6, 2, 1, 0, '0,5,17,63,'], 'plane 6000 is %r' % overlays[0])
    # Rows given as text are not taken, so the bitmap is made empty.
    expect(overlays[2] == [1, 0, 8, ord('R'), 0, 0, 1, 0, ''], 'plane 6004 is %r' % overlays[2])
    expect(overlays[3] == [1, 2, 8, 0, 0, 0, 8, 0, 'none'], 'plane 6006 is %r' % overlays[3])
    # An empty Overlay Type raises; the plane stops there, the others are read.
    expect(overlays[4] == [1, 2, 8, 0, 0, 0, 0, 0, 'none'], 'plane 6008 is %r' % overlays[4])
    # Overlay Data that is not bytes raises after the bitmap was cleared.
    expect(overlays[15] == [1, 1, 16, 0, 0, 0, 1, 0, ''], 'plane 601E is %r' % overlays[15])
    expect(state(states, 'overlays')['loggedExceptions'] == ['NSInvalidArgumentException', 'NSInvalidArgumentException'],
           'the overlays logged %r' % state(states, 'overlays')['loggedExceptions'])
    expect(overlays[1][0] == 0, 'plane 6002 is on')

    shutters = state(states, 'shutters')
    expect(shutters['raised'] is None and shutters['shutter'][0], 'the shutters %r' % shutters['shutter'])
    expect(shutters['polygon'] == ['{1, 2}', '{30, 4}', '{50, 60}'], 'the polygon is %r' % shutters['polygon'])
    expect(shutters['shutter'][3] == 200, 'the circle radius is %r' % shutters['shutter'][3])
    expect(not state(states, 'shutters-ignored')['shutter'][0], 'shutters were read when not asked for')
    expect(state(states, 'shutter-odd-polygon')['raised'] == 'NSRangeException', 'an odd polygon did not raise')

    mistyped = state(states, 'mistyped')
    expect(mistyped['raised'] is None, 'mistyped values raised %r' % mistyped['raised'])
    expect(mistyped['window'] == [hexf(0), hexf(0)] and mistyped['text'][4] is None, 'mistyped values were kept %r' % mistyped)
    for name, exception in (('rescale-type-number', 'NSInvalidArgumentException'), ('photometric-bytes', 'NSInvalidArgumentException'),
                            ('empty-shared-item', 'NSRangeException'), ('shared-not-a-sequence', 'NSInvalidArgumentException'),
                            ('per-frame-empty-item', 'NSRangeException'),
                            ('date-mistyped', 'NSInvalidArgumentException')):
        expect(state(states, name)['raised'] == exception, '%s raised %r' % (name, state(states, name)['raised']))
    expect(state(states, 'per-frame-item-not-a-sequence')['raised'] is None, 'a frame item that is not a sequence raised')
    ophthalmic = state(states, 'ophthalmic')
    expect(ophthalmic['raised'] is None, 'an ophthalmic frame with reference coordinates raised %r' % ophthalmic['raised'])
    expect(ophthalmic['referenceCoordinates'] == [hexf(1.5), hexf(2), hexf(3), hexf(4)],
           'the reference coordinates are %r' % ophthalmic['referenceCoordinates'])
    expect(ophthalmic['text'][2] == '1.2.3.9', 'the ophthalmic frame refers to %r' % ophthalmic['text'][2])
    expect(state(states, 'rgb-8-in-16')['pixels'][1] == 8, '8 bits stored in 16 RGB is not read as 8 bits')
    # The window is read before the photometric interpretation makes it colour.
    expect(state(states, 'palette')['pixels'][6] == 1 and state(states, 'palette')['window'] == [hexf(1), hexf(2)],
           'a palette is not colour, or lost its window: %r' % state(states, 'palette'))
    bits = [state(states, 'bits-stored-out-of-range', step)['pixels'][1:3] for step in range(3)]
    expect(bits == [[16, 16], [8, 8], [16, 16]], 'BitsStored out of range is read as %r' % bits)
    expect(state(states, 'absurd-spacing')['spacing'][:3] == [hexf(1), hexf(1), hexf(1)], 'an absurd spacing stood')
    expect(state(states, 'negative-spacing')['spacing'][:3] == [hexf(0.25), hexf(0.5), hexf(2)], 'a negative spacing stood')
    expect(state(states, 'cine')['cineRate'] == hexf(float.fromhex(hexf(1000.0 / 40))), 'the frame time vector gives %r'
           % state(states, 'cine')['cineRate'])
    expect(state(states, 'cine-rate')['cineRate'] == hexf(25), 'the cine rate is %r' % state(states, 'cine-rate')['cineRate'])
    size = state(states, 'database-size')
    expect(size['storedSizes'] == [{'height': 600, 'width': 500}] and size['pixels'][3:5] == [500, 512],
           'the database size %r %r' % (size['storedSizes'], size['pixels']))
    expect(state(states, 'database-size-unknown')['storedSizes'] == [{'height': 512, 'width': 512}], 'an unknown size was not written')
    expect(state(states, 'image-position-volume')['origin'] == [hexf(4), hexf(5), hexf(6)], 'the volume position was not read')
    expect(state(states, 'no-geometry')['orientation'][6:] == [hexf(0), hexf(0), hexf(0)], 'no orientation gave a normal')

    axial = ','.join(hexf(v) for v in (1, 0, 0, 0, 1, 0, 0, 0, 1))
    expect(geometry[:2] == ['init ' + axial, 'empty ' + axial], 'a new image is not axial: %r' % geometry[:2])
    expect(len([line for line in geometry if line.startswith('geometry ')]) == 2000, 'the plane arithmetic did not run')


with tempfile.TemporaryDirectory(prefix='horos-dcmpix-attributes-') as directory:
    work = Path(directory)
    # Once DCMPix is Swift, its reading (DCMPix+ImageAttributes.swift) is
    # compiled as it stands, over the same stand-ins.
    swift_class = not (ROOT / PIX).is_file()
    current = '' if swift_class else (ROOT / PIX).read_bytes().decode('latin1')

    if harness.is_objc(current):
        reference = None
    elif len(sys.argv) > 1:
        reference = sys.argv[1]
    elif harness.is_objc(committed(PIX)):
        reference = 'HEAD'  # the move is not committed yet
    else:
        reference = before_text_removed(PIX, harness.OBJC_MARKER)

    modules = work / 'modules'
    if not harness.is_objc(current):
        build_module('IsiXImaging', modules)
    if swift_class:
        binary, error = harness.compile_swift_class(work, 'current', modules)
    else:
        binary, error = harness.compile_revision(current, work, 'current', modules)
    if binary is None:
        print('FAIL: the reading of this checkout does not compile\n' + error[-4000:])
        sys.exit(1)
    states, geometry, logs = harness.run(binary, FIXTURES, work)
    check_expectations(states, geometry)

    compared = False
    if reference is None and not harness.is_objc(current):
        print('note: the history does not reach the Objective-C reading; only the expectations were checked')
    elif reference is not None:
        old = show(reference, PIX).decode('latin1')
        old_binary, error = harness.compile_revision(old, work, 'reference', header=show(reference, 'Horos/Sources/DCMPix.h'))
        if old_binary is None:
            print('FAIL: the Objective-C reading of %s does not compile\n%s' % (reference, error[-4000:]))
            sys.exit(1)
        old_states, old_geometry, old_logs = harness.run(old_binary, FIXTURES, work)
        compared = True
        for new, before in zip(states, old_states):
            corrected = CORRECTED.get(new['fixture'], {})
            differing = sorted(k for k in new['state'] if new['state'][k] != before['state'][k])
            unexpected = [k for k in differing if k not in corrected]
            if unexpected:
                failures.append('%s step %d differs from %s in %s: %r against %r' % (
                    new['fixture'], new['step'], reference[:12], unexpected,
                    {k: new['state'][k] for k in unexpected}, {k: before['state'][k] for k in unexpected}))
            for key, check in corrected.items():
                if not check(before['state'][key], new['state'][key]):
                    failures.append('%s step %d: the correction of %s does not hold against %s: %r, then %r' % (
                        new['fixture'], new['step'], key, reference[:12], before['state'][key], new['state'][key]))
        if len(states) != len(old_states):
            failures.append('%d states against %d' % (len(states), len(old_states)))
        for index, (new, before) in enumerate(zip(geometry, old_geometry)):
            if new != before:
                failures.append('plane arithmetic %d differs:\n  %s\n  %s' % (index, new, before))
                break
        if len(geometry) != len(old_geometry):
            failures.append('%d geometry lines against %d' % (len(geometry), len(old_geometry)))
        logs, old_logs = without_corrected(logs), without_corrected(old_logs)
        if logs != old_logs:
            import difflib
            failures.append('the log differs:\n' + '\n'.join(list(difflib.unified_diff(old_logs, logs, 'before', 'after', lineterm=''))[:60]))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: %d data sets read%s' % (len(states), ', identical to the Objective-C reading of %s, with 2000 plane geometries and the log,'
                                   ' but for %d corrected cases that show its fault' % (reference[:12], len(CORRECTED))
                                   if compared else ' by the Objective-C reading, as expected'))

#!/usr/bin/env python3
"""DCMPix turns a decoded frame into its image as it always did.

The frame loading of `-[DCMPix loadDICOMWithDCMTK]` - the photometric
interpretation, the sign extension of 12-bit samples, 8 to 16 bits, RGB to
ARGB, the modality LUT to float, 32-bit integers, overlays burnt in, short and
empty frames and an object without Pixel Data - moved from DCMPix.m to the
IsiXImaging module, with DCMPix delegating to it. The decoders stay where
they are: the module is handed the frame they decoded.

tests/dcmpix_frame_harness.py cuts that loading out of a revision of DCMPix.m
and runs it on synthetic frames of every kind. This test

* checks what the loading of this checkout produces against values worked out
  by hand for the plainer cases, and
* when this checkout delegates to the module, runs the Objective-C loading of
  the revision before the move on the same input and requires every pixel, the
  flags, the short frames reported, the VOI LUT step's input, the exceptions
  and the log to be identical - floating-point values to the bit - except where
  this checkout corrects that loading on purpose (CORRECTED below): there the
  reference has to show the fault and this checkout the correction.

Usage: test-dcmpix-frame-loading.py [REFERENCE_REVISION]
"""
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dcmpix_frame_harness as harness  # noqa: E402
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

random.seed(1413)
W, H = 8, 6


def pack(fmt, values):
    return struct.pack('<%d%s' % (len(values), fmt), *values).hex()


def u16(values):
    return pack('H', values)


def s16(values):
    return pack('h', values)


def ramp(n, start, step, mod):
    return [(start + i * step) % mod for i in range(n)]


def fixture(name, dataset, w=W, h=H, globals_=None, **state):
    base = {'width': w, 'height': h, 'bitsAllocated': 16, 'bitsStored': 16, 'isSigned': False, 'slope': 1, 'offset': 0}
    base.update(state)
    return {'name': name, 'dataset': dataset, 'state': base, 'globals': globals_ or {}}


def frames(*hexes, syntax=None):
    value = {'frames': list(hexes)}
    if syntax:
        value['syntax'] = syntax
    return value


N = W * H
GREY12 = ramp(N, 0, 97, 4096)
SIGNED12 = [v & 0x0FFF for v in ramp(N, -2048, 89, 4096)]
FIXTURES = [
    fixture('ct-unsigned', {'PhotometricInterpretation': 'MONOCHROME2', 'SamplesperPixel': 1, 'PixelData': frames(u16(GREY12))},
            bitsStored=12, slope=1, offset=-1024, savedWL=40, savedWW=400),
    fixture('ct-signed-12', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(SIGNED12))},
            bitsStored=12, isSigned=True, slope=1, offset=0),
    fixture('ct-signed-16', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(s16([v - 30000 for v in ramp(N, 0, 1201, 60000)]))},
            isSigned=True, slope=0.5, offset=-10.25),
    fixture('mr-rescale', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(ramp(N, 3, 1013, 65536)))},
            slope=1.7182818, offset=3.14159),
    fixture('monochrome1', {'PhotometricInterpretation': 'MONOCHROME1', 'Modality': 'CR', 'PixelData': frames(u16(GREY12))}, bitsStored=12),
    fixture('monochrome1-pet', {'PhotometricInterpretation': 'MONOCHROME1', 'Modality': 'PT', 'PixelData': frames(u16(GREY12))}),
    fixture('monochrome1-nm-opacity', {'PhotometricInterpretation': 'MONOCHROME1', 'Modality': 'NM', 'PixelData': frames(u16(GREY12))},
            globals_={'opacityTableNM': True}),
    fixture('monochrome1-nm', {'PhotometricInterpretation': 'MONOCHROME1', 'Modality': 'NM', 'PixelData': frames(u16(GREY12))}),
    fixture('grey-8', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(pack('B', ramp(N, 0, 37, 256)))},
            bitsAllocated=8, bitsStored=8, slope=2, offset=1),
    fixture('grey-8-short', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(pack('B', ramp(N - 10, 0, 37, 256)))},
            bitsAllocated=8, bitsStored=8),
    fixture('declared-16-carries-8', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(pack('B', ramp(N, 5, 41, 256)))}),
    fixture('declared-16-short', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(ramp(N - 7, 5, 41, 4096)))}),
    fixture('signed-12-carries-8', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(pack('B', ramp(N, 5, 41, 256)))},
            bitsStored=12, isSigned=True),
    fixture('rgb-888', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3, 'PixelData': frames(pack('B', ramp(N * 3, 1, 7, 256)))},
            bitsAllocated=8, bitsStored=8),
    fixture('rgb-888-short', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3, 'PixelData': frames(pack('B', ramp(N * 3 - 11, 1, 7, 256)))},
            bitsAllocated=8, bitsStored=8),
    fixture('rgb-16', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3, 'PixelData': frames(u16(ramp(N * 3, 300, 911, 65536)))}),
    fixture('rgb-16-short', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3,
                             'PixelData': frames(u16(ramp(N * 3, 300, 911, 65536)) + '00' * 0)}, h=H + 1),
    fixture('ybr', {'PhotometricInterpretation': 'YBR_FULL_422', 'SamplesperPixel': 3, 'PixelData': frames(pack('B', ramp(N * 3, 9, 13, 256)))},
            bitsAllocated=8, bitsStored=8, planar=1),
    fixture('palette', {'PhotometricInterpretation': 'PALETTE COLOR', 'SamplesperPixel': 1, 'PixelData': frames(pack('B', ramp(N * 3, 2, 5, 256)))}),
    fixture('rgb-says-one-sample', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 1, 'PixelData': frames(u16(GREY12))}),
    fixture('no-photometric', {'SamplesperPixel': 1, 'PixelData': frames(u16(GREY12))}),
    fixture('no-photometric-no-samples', {'PixelData': frames(u16(GREY12))}),
    fixture('int32-signed', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelRepresentation': 1,
                             'PixelData': frames(pack('i', [v - 4000000 for v in ramp(N, 0, 170001, 8000000)]))},
            bitsAllocated=32, bitsStored=32, isSigned=True, slope=0.001, offset=-3),
    fixture('int32-unsigned', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelRepresentation': 0,
                               'PixelData': frames(pack('I', ramp(N, 0, 83333, 4000000)))}, bitsAllocated=32, bitsStored=32),
    fixture('float32', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(pack('f', [i * 0.37 - 5 for i in range(N)]))},
            bitsAllocated=32, bitsStored=32),
    fixture('float32-always-integers', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(pack('I', ramp(N, 1, 999, 70000)))},
            bitsAllocated=32, bitsStored=32, globals_={'alwaysIntegers': True}),
    fixture('float32-rescaled', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(pack('I', ramp(N, 1, 999, 70000)))},
            bitsAllocated=32, bitsStored=32, slope=2),
    fixture('empty-frame', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames('')}, bitsStored=12),
    fixture('empty-frame-rgb', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3, 'PixelData': frames('')}, bitsAllocated=8, bitsStored=8),
    fixture('missing-frame', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(GREY12))}, frame=3),
    fixture('video-undecodable', {'PhotometricInterpretation': 'YBR_PARTIAL_420', 'SamplesperPixel': 3,
                                  'PixelData': frames('00', syntax='1.2.840.10008.1.2.4.102')}, bitsAllocated=8, bitsStored=8),
    fixture('video-frame', {'PhotometricInterpretation': 'YBR_PARTIAL_420', 'SamplesperPixel': 3,
                            'PixelData': frames(pack('B', ramp(N * 3, 4, 3, 256)), pack('B', ramp(N * 3, 40, 3, 256)),
                                                syntax='1.2.840.10008.1.2.4.102')}, bitsAllocated=8, bitsStored=8, frame=1),
    fixture('external-grey', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(GREY12))}, external=True, offset=-5),
    fixture('external-rgb', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3, 'PixelData': frames(pack('B', ramp(N * 3, 1, 7, 256)))},
            bitsAllocated=8, bitsStored=8, external=True),
    fixture('external-int32', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelRepresentation': 0,
                               'PixelData': frames(pack('I', ramp(N, 0, 83333, 4000000)))}, bitsAllocated=32, bitsStored=32, external=True),
    fixture('overlay-grey', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(GREY12))}, bitsStored=12, slope=2, offset=-7,
            overlays=[{'index': 0, 'rows': 3, 'columns': 4, 'x': 2, 'y': 1, 'set': [0, 5, 11]},
                      {'index': 3, 'rows': 2, 'columns': 2, 'x': 7, 'y': 5, 'set': [0, 1, 2, 3]}]),
    fixture('overlay-inverse', {'PhotometricInterpretation': 'MONOCHROME1', 'PixelData': frames(u16(GREY12))}, bitsStored=12, offset=-9,
            overlays=[{'index': 1, 'rows': 2, 'columns': 2, 'x': -1, 'y': 0, 'set': [0, 3]}]),
    fixture('overlay-rgb', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3, 'PixelData': frames(pack('B', ramp(N * 3, 1, 7, 256)))},
            bitsAllocated=8, bitsStored=8, overlays=[{'index': 15, 'rows': 2, 'columns': 3, 'x': 1, 'y': 1, 'set': [1, 2, 4]}]),
    fixture('overlay-off', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(GREY12))}, globals_={'overlays': False},
            overlays=[{'index': 0, 'rows': 2, 'columns': 2, 'x': 0, 'y': 0, 'set': [0]}]),
    fixture('voi-lut', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(GREY12))}, bitsStored=12, globals_={'voiLUT': True}),
    fixture('voi-lut-signed', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(SIGNED12))}, bitsStored=12, isSigned=True,
            globals_={'voiLUT': True}),
    fixture('voi-lut-8', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(pack('B', ramp(N, 0, 37, 256)))},
            bitsAllocated=8, bitsStored=8, globals_={'voiLUT': True}),
    fixture('voi-lut-short', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16(GREY12[:-3]))}, globals_={'voiLUT': True}),
    fixture('misaligned-ct', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': dict(frames(u16(GREY12)), misaligned=True)},
            bitsStored=12, offset=-1024),
    fixture('misaligned-signed', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': dict(frames(u16(SIGNED12)), misaligned=True)},
            bitsStored=12, isSigned=True, globals_={'voiLUT': True}),
    fixture('misaligned-rgb-16', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3,
                                  'PixelData': dict(frames(u16(ramp(N * 3, 300, 911, 65536))), misaligned=True)}),
    fixture('misaligned-int32', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelRepresentation': 1,
                                 'PixelData': dict(frames(pack('i', [v - 4000000 for v in ramp(N, 0, 170001, 8000000)])), misaligned=True)},
            bitsAllocated=32, bitsStored=32, isSigned=True, slope=0.001, offset=-3),
    # The Objective-C loading copied a 32-bit frame of any length as though it
    # were whole, reading past the end of its copy; these are only checked
    # against what they must be now.
    fixture('int32-short', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelRepresentation': 0,
                            'PixelData': frames(pack('I', ramp(N - 5, 7, 83333, 4000000)))}, bitsAllocated=32, bitsStored=32),
    fixture('int32-empty', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelRepresentation': 0, 'PixelData': frames('')},
            bitsAllocated=32, bitsStored=32, external=True),
    fixture('rtdose', {'PhotometricInterpretation': 'MONOCHROME2', 'Modality': 'RTDOSE', 'GridFrameOffsetVector': ['0', '2.5', '5.25'],
                       'PixelData': frames(u16(GREY12), u16(GREY12[::-1]))}, frame=1, originZ=-30.5, numberOfFrames=2),
    fixture('rtdose-missing-offset', {'PhotometricInterpretation': 'MONOCHROME2', 'Modality': 'RTDOSE', 'GridFrameOffsetVector': ['0'],
                                      'PixelData': frames(u16(GREY12), u16(GREY12))}, frame=1),
    fixture('photometric-number', {'PhotometricInterpretation': 7, 'PixelData': frames(u16(GREY12))}),
    fixture('no-pixel-data', {'PhotometricInterpretation': 'MONOCHROME2'}),
    fixture('no-pixel-data-external', {'PhotometricInterpretation': 'MONOCHROME2'}, external=True),
    fixture('large', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16([random.randrange(0, 4096) for _ in range(64 * 48)]))},
            w=64, h=48, bitsStored=12, slope=1.25, offset=-1024),
    fixture('large-signed', {'PhotometricInterpretation': 'MONOCHROME2', 'PixelData': frames(u16([random.randrange(0, 4096) for _ in range(64 * 48)]))},
            w=64, h=48, bitsStored=12, isSigned=True, offset=-1000),
    fixture('large-rgb', {'PhotometricInterpretation': 'RGB', 'SamplesperPixel': 3,
                          'PixelData': frames(pack('B', [random.randrange(0, 256) for _ in range(64 * 48 * 3)]))},
            w=64, h=48, bitsAllocated=8, bitsStored=8),
    # A multiframe object's frame 32 768: the decoder is asked for that index,
    # not for the one a 16-bit copy of it made (-32 768). Only the frames the
    # loading may ask for carry pixels, the others are empty.
    fixture('frame-32768', {'PhotometricInterpretation': 'MONOCHROME2',
                            'PixelData': frames(u16(GREY12[::-1]), *([''] * 32767), u16(GREY12))},
            bitsStored=12, frame=32768, numberOfFrames=32769),
]

# The fixtures whose Objective-C result depended on memory past the frame.
UNDEFINED_BEFORE = {'int32-short', 'int32-empty'}

# Where this checkout corrects the Objective-C loading on purpose: the fields
# allowed to differ, each with a check of the reference's value and this
# checkout's; the reference has to show the fault the case covers. The log of
# a corrected fixture may differ as well.
CORRECTED = {
    # The frame index was copied into a short: frame 32 768 was asked for as
    # -32 768, which the decoder has not, and the frame was shown empty.
    'frame-32768': {
        'buffer': lambda old, new: old == [hexf(0)] * N and new == [hexf(v) for v in GREY12],
        'reason': lambda old, new: old == 'empty frame -32768' and new is None,
    },
}

failures = []


def without_corrected(logs):
    """The log lines, without those of the corrected fixtures."""
    kept, skipping = [], False
    for line in logs:
        if line.startswith('=== '):
            skipping = line.split()[1] in CORRECTED
        if not skipping:
            kept.append(line)
    return kept


def state(states, name):
    return next(s['state'] for s in states if s['fixture'] == name)


def hexf(v):
    text = float.hex(float(v))
    mantissa, exponent = text.split('p')
    if '.' in mantissa:
        mantissa = mantissa.rstrip('0').rstrip('.')
    return mantissa + 'p' + exponent


def single(v):
    return struct.unpack('f', struct.pack('f', float(v)))[0]


def expect(condition, message):
    if not condition:
        failures.append(message)


def check_expectations(states, delegates):
    ct = state(states, 'ct-unsigned')
    expect(ct['buffer'] == [hexf(v - 1024) for v in GREY12], 'the unsigned CT is %r' % ct['buffer'][:4])
    expect(ct['flags'][:2] == [0, 0] and ct['flags'][6:] == [hexf(40), hexf(400)], 'the CT flags are %r' % ct['flags'])
    signed = state(states, 'ct-signed-12')
    expect(signed['buffer'] == [hexf(v - 4096 if v >= 2048 else v) for v in SIGNED12], 'the 12-bit signed CT is %r' % signed['buffer'][:4])
    mono1 = state(states, 'monochrome1')
    expect(mono1['flags'][1] == 1 and mono1['buffer'] == [hexf(v) for v in GREY12], 'MONOCHROME1 changed its values: %r' % mono1['flags'])
    expect(state(states, 'monochrome1-pet')['flags'][1] == 0, 'a PET MONOCHROME1 was inverted')
    expect(state(states, 'monochrome1-nm-opacity')['flags'][1] == 0 and state(states, 'monochrome1-nm')['flags'][1] == 1,
           'the NM opacity preference does not decide the polarity')
    grey8 = state(states, 'grey-8')
    expect(grey8['buffer'] == [hexf(single(v * 2 + 1)) for v in ramp(N, 0, 37, 256)], 'the 8-bit grey is %r' % grey8['buffer'][:4])
    expect(state(states, 'grey-8-short')['reason'] == 'short %d of %d' % (N - 10, N), 'a short 8-bit frame was not reported')
    carries8 = state(states, 'declared-16-carries-8')
    expect(carries8['buffer'] == [hexf(v) for v in ramp(N, 5, 41, 256)], 'a 16-bit frame of bytes is %r' % carries8['buffer'][:4])
    expect(state(states, 'declared-16-short')['buffer'] == [hexf(0)] * N, 'a short 16-bit frame was not blank')
    rgb = state(states, 'rgb-888')
    source = ramp(N * 3, 1, 7, 256)
    expect(rgb['flags'][0] == 1 and rgb['buffer'] == ''.join('ff%02x%02x%02x' % tuple(source[3 * i:3 * i + 3]) for i in range(N)),
           'the RGB frame is %r' % rgb['buffer'][:24])
    rgb16 = state(states, 'rgb-16')
    source = ramp(N * 3, 300, 911, 65536)
    expect(rgb16['buffer'] == ''.join('ff%02x%02x%02x' % tuple(v & 0xFF for v in source[3 * i:3 * i + 3]) for i in range(N)),
           'the 16-bit RGB frame is %r' % rgb16['buffer'][:24])
    expect(state(states, 'ybr')['flags'][5] == 0, 'YBR kept its planar configuration')
    expect(state(states, 'palette')['flags'][0] == 1 and state(states, 'palette')['flags'][2] == 8, 'a palette frame is not colour')
    expect(state(states, 'rgb-says-one-sample')['flags'][0] == 0, 'one sample per pixel was read as colour')
    int32 = state(states, 'int32-signed')
    expect(int32['buffer'] == [hexf(single(v * single(0.001) - 3)) for v in [v - 4000000 for v in ramp(N, 0, 170001, 8000000)]], 'the 32-bit integers are %r'
           % int32['buffer'][:3])
    floats = state(states, 'float32')
    expect(floats['buffer'] == [hexf(single(i * 0.37 - 5)) for i in range(N)], 'the 32-bit floats are %r' % floats['buffer'][:3])
    expect(state(states, 'empty-frame')['reason'] == 'empty frame 0' and state(states, 'empty-frame')['buffer'] == [hexf(0)] * N,
           'an empty frame is not empty and named')
    expect(state(states, 'video-undecodable')['reason'] == 'the video stream cannot be decoded', 'an undecodable video was not named')
    expect(state(states, 'external-grey')['external'] and state(states, 'external-rgb')['external'], 'the series buffer was not used')
    overlay = state(states, 'overlay-grey')
    top = single(single(4096 * 2) - 7)
    expect(overlay['buffer'][1 * W + 2] == hexf(top) and overlay['buffer'][2 * W + 3] == hexf(top) and overlay['buffer'][5 * W + 7] == hexf(top),
           'the overlay is not burnt in: %r' % overlay['buffer'][W:2 * W])
    expect(state(states, 'overlay-inverse')['buffer'][W] == hexf(-9), 'an inverted overlay is not at the offset')
    expect(state(states, 'overlay-off')['buffer'][0] == hexf(GREY12[0]), 'overlays were burnt in when turned off')
    expect(len(state(states, 'voi-lut')['voi']) == 1 and state(states, 'voi-lut')['buffer'][0] == hexf(GREY12[0] ^ 5),
           'the VOI LUT step did not run on the samples')
    expect(state(states, 'voi-lut-short')['voi'] == [], 'the VOI LUT ran on a short frame')
    expect(state(states, 'rtdose')['originZ'] == hexf(-28.0), 'the RT dose frame is at %r' % state(states, 'rtdose')['originZ'])
    expect(state(states, 'rtdose-missing-offset')['raised'] == 'NSRangeException', 'a missing grid offset did not raise')
    expect(state(states, 'photometric-number')['raised'] == 'NSInvalidArgumentException', 'a photometric number did not raise')
    for name, aligned in (('misaligned-ct', 'ct-unsigned'), ('misaligned-signed', 'voi-lut-signed'),
                          ('misaligned-rgb-16', 'rgb-16'), ('misaligned-int32', 'int32-signed')):
        expect(state(states, name)['buffer'] == state(states, aligned)['buffer'], '%s differs from %s' % (name, aligned))
    if delegates:
        short = state(states, 'int32-short')['buffer']
        expect(short[:N - 5] == [hexf(v) for v in ramp(N - 5, 7, 83333, 4000000)] and short[N - 5:] == [hexf(0)] * 5,
               'a short 32-bit frame is %r' % short[-6:])
        expect(state(states, 'int32-empty')['buffer'] == [hexf(0)] * N and state(states, 'int32-empty')['external'],
               'an empty 32-bit frame is not black')
    big = state(states, 'frame-32768')
    expect(big['buffer'] == [hexf(v) for v in GREY12] and big['reason'] is None,
           'frame 32768 is not the 32 769th frame: %r, %r' % (big['buffer'][:4], big['reason']))
    expect(state(states, 'no-pixel-data')['reason'] == 'no pixel data' and state(states, 'no-pixel-data')['buffer'] == [hexf(0)] * N,
           'an object without Pixel Data is not empty and named')


with tempfile.TemporaryDirectory(prefix='horos-dcmpix-frames-') as directory:
    work = Path(directory)
    # Once DCMPix is Swift, its frame loading (DCMPix+FrameLoading.swift) is
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
    build_module('IsiXImaging', modules)
    if swift_class:
        binary, error = harness.compile_swift_class(work, 'current', modules)
    else:
        binary, error = harness.compile_revision(current, work, 'current', modules)
    if binary is None:
        print('FAIL: the frame loading of this checkout does not compile\n' + error[-4000:])
        sys.exit(1)
    states, logs = harness.run(binary, FIXTURES, work)
    check_expectations(states, not harness.is_objc(current))

    compared = False
    if reference is None and not harness.is_objc(current):
        print('note: the history does not reach the Objective-C frame loading; only the expectations were checked')
    elif reference is not None:
        old = show(reference, PIX).decode('latin1')
        old_binary, error = harness.compile_revision(old, work, 'reference', modules, header=show(reference, 'Horos/Sources/DCMPix.h'))
        if old_binary is None:
            print('FAIL: the Objective-C frame loading of %s does not compile\n%s' % (reference, error[-4000:]))
            sys.exit(1)
        old_states, old_logs = harness.run(old_binary, FIXTURES, work)
        compared = True
        for new, before in zip(states, old_states):
            if new['fixture'] in UNDEFINED_BEFORE:
                continue
            corrected = CORRECTED.get(new['fixture'], {})
            differing = sorted(k for k in new['state'] if new['state'][k] != before['state'][k] and k not in corrected)
            if differing:
                failures.append('%s differs from %s in %s: %r against %r' % (
                    new['fixture'], reference[:12], differing,
                    {k: str(new['state'][k])[:300] for k in differing}, {k: str(before['state'][k])[:300] for k in differing}))
            for key, check in corrected.items():
                if not check(before['state'][key], new['state'][key]):
                    failures.append('%s: the correction of %s does not hold against %s: %s, then %s' % (
                        new['fixture'], key, reference[:12], str(before['state'][key])[:200], str(new['state'][key])[:200]))
        if len(states) != len(old_states):
            failures.append('%d states against %d' % (len(states), len(old_states)))
        logs, old_logs = without_corrected(logs), without_corrected(old_logs)
        if logs != old_logs:
            import difflib
            failures.append('the log differs:\n' + '\n'.join(list(difflib.unified_diff(old_logs, logs, 'before', 'after', lineterm=''))[:60]))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: %d frames loaded%s' % (len(states), ', identical to the Objective-C loading of %s, with the log, but for %d corrected cases'
                                  ' that show its fault' % (reference[:12], len(CORRECTED))
                                  if compared else ' by the Objective-C loading, as expected'))

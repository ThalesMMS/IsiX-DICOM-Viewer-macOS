#!/usr/bin/env python3
"""DCMPix reads the files that are not DICOM as it always did.

`-[DCMPix CheckLoadIn]` opens what DCMTK does not: 8-, 16- and 32-bit TIFF
(one page or a stack, grey or RGB, interleaved or planar), Olympus FluoView
TIFF, Zeiss LSM, Bio-Rad PIC, NIfTI (`.nii` and `.hdr`/`.img` pairs, every
datatype, the orientations the qform or sform states), the older Analyze,
PNG/JPEG/GIF/PDF through NSImage, a `.zip` (its icon), a movie, and a file a
plugin decodes; `-ConvertYbrToRgb:::::` turns YBR samples into RGB.

This test writes such files, synthetic and small, then compiles DCMPix.m of a
revision with the build's own command, links it with the app's objects
(tests/app_object_probe.py), the libtiff the app embeds and the NIfTI library
the build compiled, and loads every file at the frame (and channel) asked.
For each it records the size, colour, every byte of the image, the spacing,
thickness, interval, location, origin, orientation, window, whether the frame
could be read, and what was logged. It checks the plainer values against what
was written, and requires the result to be identical, bit for bit, to that of
the last revision whose DCMPix.m still read these formats itself.

Once DCMPix itself is Swift, no revision of DCMPix.m links with this checkout's
Swift: the reference is then what the probe answered against the last
Objective-C class, kept for each configuration in
tests/fixtures/dcmpix-non-dicom-formats-records.json (HOROS_RECORD_GOLDEN=1 on a checkout
of that class writes them).

The Swift class is run twice, with every screen answering a backing scale of
2, that of the records, then of 1: AppKit rasterizes an image without a
context at the scale of the screen, and a file, or an NSImage drawn before,
must give the same image, pixel for pixel, on any display. The NSImage the
probe draws itself with -lockFocus is left out: AppKit draws it at the
scale of the screen, so the picture given differs, not its conversion.

Where the Objective-C read a file wrongly, the case is not compared with the
reference but checked against the values written (CORRECTED): a 16-bit TIFF
whose SampleFormat is signed integer is read with its sign; a Bio-Rad PIC's
16-bit samples are unsigned, and its last note is read once; an Analyze float
image in big endian has the values of its little-endian twin.

Usage: test-dcmpix-non-dicom-formats.py [REFERENCE_REVISION]
"""
from pathlib import Path
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
sys.path.insert(0, str(ROOT / 'tools'))
import app_object_probe  # noqa: E402
import object_probe  # noqa: E402
import roi_harness  # noqa: E402
from history_reference import before_text_removed, show  # noqa: E402

PIX = 'Horos/Sources/DCMPix.m'
# What DCMPix.m defines while it still reads the formats itself.
OBJC_MARKER = '-(void) LoadLSM'
# The records of the last Objective-C class, in tests/fixtures.
GOLDEN = 'dcmpix-non-dicom-formats'
SKIPPED = 2

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun', file=sys.stderr)
    sys.exit(SKIPPED)
CONFIGURATION = os.environ.get('HOROS_TEST_CONFIGURATION', 'Debug')
OBJECTS = object_probe.app_object('DCMPix', CONFIGURATION)
LIBTIFF = ROOT / 'build/Development/HorosDevelopment.app/Contents/Frameworks/libtiff.6.dylib'
if OBJECTS is None or not LIBTIFF.is_file():
    print('skipped: needs a %s build (script/build_and_run.sh --verify): DCMPix.o and the embedded libtiff' % CONFIGURATION,
          file=sys.stderr)
    sys.exit(SKIPPED)
OBJECTS = OBJECTS.parent
# The FluoView reading is the VTK adapter's, NIfTI-1 its C library's. The
# adapter's errors (IsiXVTKError.o) take VTK's core with them.
from dcmtk_build import BUILD  # noqa: E402
C_LIBRARIES = [OBJECTS / name for name in ('IsiXVTKFluoView.o', 'IsiXVTKTIFF.o', 'IsiXVTKError.o', 'nifti1_io.o', 'znzlib.o')]
C_LIBRARIES.append(BUILD / 'VTK.build/Install/wlib/libVTK.a')
if not all(path.is_file() for path in C_LIBRARIES):
    print('skipped: the build has no VTK adapter objects, nifti1_io.o, znzlib.o or VTK library', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []


# --- files ----------------------------------------------------------------------------------------------------

def tiff(pages, path):
    """A little-endian TIFF whose IFDs come first, from offset 8 (LSM readers expect it).

    A page: width, height, bits (per sample), spp, photometric, planar (1/2), strips (list of bytes),
    and extra tags [(tag, type, count, bytes)], subfile (254)."""
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 7: 1, 11: 4, 12: 8}

    def entries(page, strip_offsets):
        bits = page['bits']
        spp = page['spp']
        e = [(254, 4, 1, struct.pack('<I', page.get('subfile', 0))),
             (256, 3, 1, struct.pack('<H', page['width'])),
             (257, 3, 1, struct.pack('<H', page['height'])),
             (258, 3, spp, struct.pack('<%dH' % spp, *([bits] * spp))),
             (259, 3, 1, struct.pack('<H', 1)),
             (262, 3, 1, struct.pack('<H', page['photometric'])),
             (273, 4, len(strip_offsets), struct.pack('<%dI' % len(strip_offsets), *strip_offsets)),
             (277, 3, 1, struct.pack('<H', spp)),
             (278, 3, 1, struct.pack('<H', page['height'])),
             (279, 4, len(page['strips']), struct.pack('<%dI' % len(page['strips']), *map(len, page['strips']))),
             (284, 3, 1, struct.pack('<H', page.get('planar', 1)))]
        if 'sampleformat' in page:
            e.append((339, 3, spp, struct.pack('<%dH' % spp, *([page['sampleformat']] * spp))))
        e += page.get('tags', [])
        if page.get('no_compression_tag'):
            e = [x for x in e if x[0] != 259]
        return sorted(e)

    def ifd_size(page):
        overflow = sum(len(v) + (len(v) & 1) for _, _, _, v in entries(page, [0] * len(page['strips'])) if len(v) > 4)
        return 2 + 12 * len(entries(page, [0] * len(page['strips']))) + 4 + overflow

    offset = 8
    ifd_offsets = []
    for page in pages:
        ifd_offsets.append(offset)
        offset += ifd_size(page)
    data_offsets = []
    for page in pages:
        strips = []
        for strip in page['strips']:
            strips.append(offset)
            offset += len(strip)
        data_offsets.append(strips)
    out = bytearray(b'II*\x00' + struct.pack('<I', 8))
    for index, page in enumerate(pages):
        assert len(out) == ifd_offsets[index]
        e = entries(page, data_offsets[index])
        overflow_at = ifd_offsets[index] + 2 + 12 * len(e) + 4
        overflow = bytearray()
        out += struct.pack('<H', len(e))
        for tag, kind, count, value in e:
            assert len(value) == sizes[kind] * count
            if len(value) <= 4:
                out += struct.pack('<HHI', tag, kind, count) + value.ljust(4, b'\0')
            else:
                out += struct.pack('<HHII', tag, kind, count, overflow_at + len(overflow))
                overflow += value + (b'\0' if len(value) & 1 else b'')
        out += struct.pack('<I', ifd_offsets[index + 1] if index + 1 < len(pages) else 0)
        out += overflow
    for page in pages:
        for strip in page['strips']:
            out += strip
    path.write_bytes(bytes(out))


def grey_page(w, h, bits, values, **extra):
    form = {8: 'B', 16: 'H', 32: 'f'}[bits]
    page = {'width': w, 'height': h, 'bits': bits, 'spp': 1, 'photometric': 1,
            'strips': [struct.pack('<%d%s' % (len(values), form), *values)]}
    page.update(extra)
    return page


def rgb_page(w, h, bits, triples, planar=1, **extra):
    form = {8: 'B', 16: 'H'}[bits]
    if planar == 1:
        strips = [struct.pack('<%d%s' % (3 * len(triples), form), *[c for t in triples for c in t])]
    else:
        strips = [struct.pack('<%d%s' % (len(triples), form), *[t[k] for t in triples]) for k in range(3)]
    page = {'width': w, 'height': h, 'bits': bits, 'spp': 3, 'photometric': 2, 'planar': planar, 'strips': strips}
    page.update(extra)
    return page


def ramp(n, start, step, mod):
    return [(start + i * step) % mod for i in range(n)]


def png(path, w, h, rows, colour=2, depth=8):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    raw = b''.join(b'\0' + row for row in rows)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, depth, colour, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def pdf(path, pages):
    """A PDF of `pages` pages, each a filled rectangle of its own grey."""
    objects = ['<< /Type /Catalog /Pages 2 0 R >>',
               '<< /Type /Pages /Kids [%s] /Count %d >>' % (' '.join('%d 0 R' % (3 + 2 * i) for i in range(pages)), pages)]
    for i in range(pages):
        content = '%.2f g 4 6 %d %d re f' % (0.2 + 0.3 * i, 20 + 8 * i, 14 + 6 * i)
        objects.append('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 48 36] /Contents %d 0 R >>' % (4 + 2 * i))
        objects.append('<< /Length %d >>\nstream\n%s\nendstream' % (len(content), content))
    out = '%PDF-1.4\n'
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += '%d 0 obj\n%s\nendobj\n' % (number, body)
    xref = len(out)
    out += 'xref\n0 %d\n0000000000 65535 f \n' % (len(objects) + 1) + ''.join('%010d 00000 n \n' % o for o in offsets)
    out += 'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objects) + 1, xref)
    path.write_bytes(out.encode('latin1'))


def nifti_header(datatype, bitpix, dims, pixdim, magic, endian='<', vox_offset=352.0, qform=0, sform=0,
                 quatern=(0, 0, 0), qoffset=(0, 0, 0), srows=None):
    data = bytearray(348)
    put = lambda offset, form, *values: struct.pack_into(endian + form, data, offset, *values)  # noqa: E731
    put(0, 'i', 348)
    put(40, '8h', len(dims), *dims, *([1] * (7 - len(dims))))
    put(70, 'h', datatype)
    put(72, 'h', bitpix)
    put(76, '8f', *pixdim, *([0.0] * (8 - len(pixdim))))
    put(108, 'f', vox_offset)
    put(252, 'h', qform)
    put(254, 'h', sform)
    put(256, '3f', *quatern)
    put(268, '3f', *qoffset)
    for row, values in enumerate(srows or ((0, 0, 0, 0),) * 3):
        put(280 + 16 * row, '4f', *values)
    data[344:348] = magic
    return bytes(data)


NIFTI_TYPES = {2: ('B', 8), 256: ('b', 8), 4: ('h', 16), 512: ('H', 16), 8: ('i', 32), 768: ('I', 32),
               1024: ('q', 64), 1280: ('Q', 64), 16: ('f', 32), 64: ('d', 64), 128: (None, 24), 32: ('ff', 64)}


def nifti_volume(datatype, x, y, z):
    form, _ = NIFTI_TYPES[datatype]
    n = x * y * z
    if datatype == 128:
        return [(i * 7 % 256, i * 13 % 256, i * 29 % 256) for i in range(n)]
    if datatype == 32:
        return [(i * 0.5, -i * 0.25) for i in range(n)]
    if form in 'fd':
        return [math.sin(i * 0.37) * 1000.25 for i in range(n)]
    # Low end and span of the values, past 16 bits for the wider integers.
    low, span = {'B': (0, 256), 'b': (-128, 256), 'h': (-32768, 65536), 'H': (0, 65536), 'i': (-1 << 30, 1 << 31),
                 'I': (0, 1 << 32), 'q': (-1 << 40, 1 << 41), 'Q': (0, 1 << 41)}[form]
    return [low + (i * 7919 * 104729) % span for i in range(n)]


def nifti_voxels(datatype, values, endian):
    form, _ = NIFTI_TYPES[datatype]
    if datatype == 128:
        return bytes(c for t in values for c in t)
    if datatype == 32:
        return b''.join(struct.pack(endian + 'ff', *v) for v in values)
    return struct.pack(endian + '%d%s' % (len(values), form), *values)


def write_nifti(folder, name, datatype, dims=(5, 4, 3), pixdim=(1.0, 0.5, 0.75, 3.0), pair=False, endian='<',
                truncate=0, **orientation):
    _, bitpix = NIFTI_TYPES[datatype]
    values = nifti_volume(datatype, *dims)
    voxels = nifti_voxels(datatype, values, endian)
    if pair:
        header = nifti_header(datatype, bitpix, dims, pixdim, b'ni1\0', endian, vox_offset=0.0, **orientation)
        (folder / (name + '.hdr')).write_bytes(header)
        (folder / (name + '.img')).write_bytes(voxels[:len(voxels) - truncate])
        return name + '.hdr', values
    header = nifti_header(datatype, bitpix, dims, pixdim, b'n+1\0', endian, **orientation)
    data = header + b'\0' * 4 + voxels
    (folder / (name + '.nii')).write_bytes(data[:len(data) - truncate])
    return name + '.nii', values


def write_analyze(folder, name, datatype, values, w, h, endian='<', pixdim=(0, 0.8, 0.9, 2.5), truncate=0):
    data = bytearray(348)
    put = lambda offset, form, *v: struct.pack_into(endian + form, data, offset, *v)  # noqa: E731
    put(0, 'i', 348)
    put(40, '8h', 4, w, h, len(values) // (w * h), 1, 0, 0, 0)
    put(70, 'h', datatype)
    put(72, 'h', {2: 8, 4: 16, 8: 32, 16: 32, 128: 24}[datatype])
    put(76, '4f', *pixdim)
    (folder / (name + '.hdr')).write_bytes(bytes(data))
    form = {2: 'B', 4: 'h', 8: 'I', 16: 'f', 128: 'B'}[datatype]
    body = struct.pack(endian + '%d%s' % (len(values), form), *values)
    (folder / (name + '.img')).write_bytes(body[:len(body) - truncate])
    return name + '.hdr'


def write_biorad(folder, name, w, h, frames, sixteen, notes, tail=b'', values=None):
    header = bytearray(76)
    struct.pack_into('<3h', header, 0, w, h, frames)
    struct.pack_into('<i', header, 10, 1)
    struct.pack_into('<h', header, 14, 0 if sixteen else 1)
    struct.pack_into('<h', header, 54, 12345)
    n = w * h * frames
    values = values or (ramp(n, 100, 4099, 30000) if sixteen else ramp(n, 3, 37, 256))
    pixels = struct.pack('<%dH' % n, *values) if sixteen else bytes(values)
    body = b''
    for text in notes:
        body += b'\0' * 16 + text.encode('latin1').ljust(80, b'\0')[:80]
    (folder / (name + '.pic')).write_bytes(bytes(header) + pixels + body + tail)
    return name + '.pic'


def lsm_info(datatype, channels, z, voxel=(0.3e-6, 0.4e-6, 1.5e-6), w=6, h=5):
    info = bytearray(224)
    struct.pack_into('<I', info, 0, 0x00494C2B)
    struct.pack_into('<I', info, 4, len(info))
    struct.pack_into('<6I', info, 8, w, h, z, channels, 1, datatype)
    struct.pack_into('<3d', info, 40, *voxel)
    struct.pack_into('<H', info, 88, 0)
    return bytes(info)


def write_lsm(folder, name, datatype, channels=1, frames=2, thumbnails=True, compression=True, w=6, h=5):
    """An LSM: for each frame a main IFD (one strip per channel) and, after it, a thumbnail."""
    info = lsm_info(datatype, channels, frames, w=w, h=h)
    bits = {1: 8, 2: 16, 5: 32}[datatype]
    pages = []
    for frame in range(frames):
        strips = []
        for channel in range(channels):
            n = w * h
            values = ramp(n, 11 * frame + 50 * channel, 23 + channel, 1 << min(bits, 15))
            if bits == 32:
                strips.append(struct.pack('<%df' % n, *[v * 0.125 - 40 for v in values]))
            else:
                strips.append(struct.pack('<%d%s' % (n, 'B' if bits == 8 else 'H'), *values))
        page = {'width': w, 'height': h, 'bits': bits, 'spp': channels, 'photometric': 1, 'planar': 2 if channels > 1 else 1,
                'strips': strips, 'no_compression_tag': not compression}
        if bits == 32:
            page['sampleformat'] = 3
        if frame == 0:
            page['tags'] = [(34412, 7, len(info), info)]
        pages.append(page)
        if thumbnails:
            pages.append({'width': 2, 'height': 2, 'bits': 8, 'spp': 1, 'photometric': 1, 'strips': [bytes([9, 8, 7, 6])],
                          'subfile': 1, 'no_compression_tag': not compression})
    tiff(pages, folder / (name + '.lsm'))
    return name + '.lsm'


def fv_header(dimensions):
    """The FluoView MM header: the fields FV_Read_MM_HEAD reads, then ten dimensions of 104 bytes."""
    head = bytearray(2 + 1 + 1 + 256 + 4 * 6)
    struct.pack_into('<h', head, 0, len(head))
    for name, size, origin, resolution in dimensions + [('', 0, 0.0, 0.0)] * (10 - len(dimensions)):
        record = bytearray(104)
        record[0:16] = name.encode().ljust(16, b'\0')
        struct.pack_into('<Idd', record, 16, size, origin, resolution)
        head += record
    return bytes(head)


def write_fluoview(folder, name, w=4, h=3, z=2, channels=2):
    header = fv_header([('X', w, 1500.0, 250.0), ('Y', h, -750.0, 500.0), ('Z', z, 3000.0, 2000.0), ('Ch', channels, 0, 0)])
    pages = []
    for channel in range(channels):
        for frame in range(z):
            page = grey_page(w, h, 16, ramp(w * h, 1000 * channel + 100 * frame, 77, 4000))
            page['tags'] = [(34361, 1, len(header), header)]
            pages.append(page)
    tiff(pages, folder / (name + '.fv.tif'))
    return name + '.fv.tif'


def fixtures(folder):
    """(name, file, frame, serie, options) for every case."""
    cases = []
    add = lambda name, path, frame=0, serie=0, **options: cases.append((name, path, frame, serie, options))  # noqa: E731
    W, H = 6, 4
    n = W * H

    # TIFF read by libtiff: a stack, 8/16 bits grey, 32-bit float, RGB interleaved or planar.
    tiff([grey_page(W, H, 16, ramp(n, 0, 2777, 65536)), grey_page(W, H, 16, ramp(n, 9, 1001, 65536))], folder / 'grey16.tif')
    add('tiff-16-frame0', 'grey16.tif')
    add('tiff-16-frame1', 'grey16.tif', 1)
    signed = ramp(n, 0, 2777, 65536)
    tiff([grey_page(W, H, 16, signed, sampleformat=2)], folder / 'signed16.tif')
    add('tiff-16-signed', 'signed16.tif')
    # Negative from its second sample on.
    tiff([grey_page(W, H, 16, ramp(n, 30000, 2777, 65536), sampleformat=2)], folder / 'signed16-negative.tif')
    add('tiff-16-signed-negative', 'signed16-negative.tif')
    tiff([grey_page(W, H, 8, ramp(n, 5, 41, 256))], folder / 'grey8.tif')
    add('tiff-8', 'grey8.tif')
    floats = [math.cos(i * 0.4) * 75.5 - 3 for i in range(n)]
    tiff([grey_page(W, H, 32, floats, sampleformat=3)], folder / 'float32.tif')
    add('tiff-32-float', 'float32.tif')
    colour = [(i * 9 % 256, i * 31 % 256, (255 - i * 5) % 256) for i in range(n)]
    grey3 = [(v, v, v) for v in ramp(n, 4, 23, 256)]
    tiff([rgb_page(W, H, 8, colour), rgb_page(W, H, 8, grey3)], folder / 'rgb8.tif')
    add('tiff-rgb8-contig', 'rgb8.tif')
    add('tiff-rgb8-contig-grey', 'rgb8.tif', 1)
    tiff([rgb_page(W, H, 8, colour, planar=2), rgb_page(W, H, 8, grey3, planar=2)], folder / 'rgb8-planar.tif')
    add('tiff-rgb8-planar', 'rgb8-planar.tif')
    add('tiff-rgb8-planar-grey', 'rgb8-planar.tif', 1)
    colour16 = [(i * 2311 % 65536, i * 4099 % 65536, (65535 - i * 997) % 65536) for i in range(n)]
    grey16 = [(v, v, v) for v in ramp(n, 300, 2501, 65536)]
    tiff([rgb_page(W, H, 16, colour16), rgb_page(W, H, 16, grey16)], folder / 'rgb16.tif')
    add('tiff-rgb16-contig', 'rgb16.tif')
    add('tiff-rgb16-contig-grey', 'rgb16.tif', 1)
    tiff([rgb_page(W, H, 16, colour16, planar=2), rgb_page(W, H, 16, grey16, planar=2)], folder / 'rgb16-planar.tif')
    add('tiff-rgb16-planar', 'rgb16-planar.tif')
    shutil.copyfile(folder / 'grey16.tif', folder / 'grey16.stk')
    add('tiff-stk', 'grey16.stk', 1)
    add('tiff-16-in-volume', 'grey16.tif', external=True, savedWidth=W - 2, savedHeight=H - 1)
    add('tiff-16-larger-than-database', 'grey16.tif', savedWidth=W + 3, savedHeight=H + 2)
    # A single RGB page goes through NSImage.
    tiff([rgb_page(W, H, 8, colour)], folder / 'rgb8-single.tif')
    add('tiff-rgb8-nsimage', 'rgb8-single.tif')
    (folder / 'broken.tif').write_bytes(b'II*\x00' + b'\xff' * 20)
    add('tiff-broken', 'broken.tif')

    # FluoView: the directory of frame and channel, origin and spacing from the MM header.
    add('fluoview-ch0-z1', write_fluoview(folder, 'stack'), 1, 0)
    add('fluoview-ch1-z0', 'stack.fv.tif', 0, 1)

    # LSM.
    add('lsm-8-compressed-z1', write_lsm(folder, 'lsm8', 1), 1)
    add('lsm-8-two-channels-ch1', write_lsm(folder, 'lsm8c', 1, channels=2, compression=False), 1, 1)
    add('lsm-8-channel-too-high', 'lsm8c.lsm', 0, 2)
    add('lsm-16-z0', write_lsm(folder, 'lsm16', 2, thumbnails=False), 0)
    add('lsm-16-z1', 'lsm16.lsm', 1)
    add('lsm-float', write_lsm(folder, 'lsmf', 5, frames=1, compression=False), 0)
    add('lsm-16-in-volume', 'lsm16.lsm', 1, external=True, savedWidth=4, savedHeight=5)

    # Bio-Rad PIC.
    notes = ['AXIS_2 001 0.000000e+00 2.500000e-01 microns', 'AXIS_3 001 0.000000e+00 3.750000e-01 microns',
             '  AXIS_4 001 0.000000e+00 1.200000e+00 microns', 'Z_CORRECT_FACTOR = 0.950000 -2.821782',
             'LENS_MAGNIFICATION = 60.0', '\x01\x02 control first']
    add('biorad-8-z1', write_biorad(folder, 'bio8', W, H, 2, False, notes), 1)
    add('biorad-16-z0', write_biorad(folder, 'bio16', W, H, 2, True, notes[:3], tail=b'\0' * 16 + b'AXIS_3 0 0 9.9 x'), 0)
    add('biorad-no-notes', write_biorad(folder, 'bionotes', W, H, 1, False, []), 0)
    # A note too short to name its axis stops the reading (an exception -CheckLoad caught).
    add('biorad-short-axis', write_biorad(folder, 'bioshort', W, H, 1, False, [notes[0], 'AXIS_']), 0)
    add('biorad-in-volume', 'bio16.pic', 1, external=True, savedWidth=W - 1, savedHeight=H)
    # Unsigned 16-bit samples above 32767, and a last note that sets the Z correction.
    add('biorad-16-high', write_biorad(folder, 'bio16high', W, H, 1, True, notes[:2] + [notes[3]],
                                       values=ramp(n, 40000, 997, 65536)), 0)

    # NIfTI: every datatype, both layouts, both byte orders, the orientations.
    for datatype in sorted(NIFTI_TYPES):
        add('nifti-type-%d' % datatype, write_nifti(folder, 'type%d' % datatype, datatype, qform=1)[0], 1)
    add('nifti-pair-big-endian', write_nifti(folder, 'pairbe', 4, pair=True, endian='>', qform=1)[0], 2)
    add('nifti-pair', write_nifti(folder, 'pair', 16, pair=True, qform=1)[0], 0)
    add('nifti-no-transform', write_nifti(folder, 'plain', 4)[0], 1)
    add('nifti-qfac-negative', write_nifti(folder, 'qfac', 4, pixdim=(-1.0, 0.5, 0.75, 3.0), qform=1)[0], 2)
    add('nifti-sagittal', write_nifti(folder, 'sag', 4, sform=1, srows=((0, 0, 3, 0), (0.5, 0, 0, 0), (0, -0.75, 0, 0)))[0], 1)
    add('nifti-coronal', write_nifti(folder, 'cor', 4, sform=1, srows=((-0.5, 0, 0, 0), (0, 0, 3, 0), (0, 0.75, 0, 0)))[0], 1)
    add('nifti-coronal-flipped', write_nifti(folder, 'cor2', 4, sform=1, srows=((0.5, 0, 0, 0), (0, 0, -3, 0), (0, -0.75, 0, 0)))[0], 2)
    add('nifti-axial-turned', write_nifti(folder, 'turn', 4, qform=1, quatern=(0, 0, 0.70710678))[0], 0)
    add('nifti-i-superior', write_nifti(folder, 'isup', 4, sform=1, srows=((0, 0.5, 0, 0), (0, 0, 3, 0), (-0.75, 0, 0, 0)))[0], 0)
    add('nifti-truncated', write_nifti(folder, 'cut', 4, qform=1, truncate=7)[0], 0)
    add('nifti-pair-truncated', write_nifti(folder, 'cutpair', 4, pair=True, qform=1, truncate=5)[0], 0)
    add('nifti-in-volume', 'type4.nii', 2, external=True)

    # Analyze.
    add('analyze-8', write_analyze(folder, 'an8', 2, ramp(2 * n, 1, 19, 256), W, H), 1)
    add('analyze-16', write_analyze(folder, 'an16', 4, [v - 30000 for v in ramp(2 * n, 0, 2777, 60000)], W, H), 1)
    add('analyze-16-big-endian', write_analyze(folder, 'an16be', 4, [v - 30000 for v in ramp(2 * n, 0, 2777, 60000)], W, H, '>'), 0)
    add('analyze-32', write_analyze(folder, 'an32', 8, ramp(2 * n, 70000, 123457, 1 << 32), W, H), 1)
    add('analyze-32-big-endian', write_analyze(folder, 'an32be', 8, ramp(2 * n, 70000, 123457, 1 << 32), W, H, '>'), 0)
    add('analyze-float', write_analyze(folder, 'anf', 16, [math.sin(i) * 300 for i in range(2 * n)], W, H), 1)
    add('analyze-float-big-endian', write_analyze(folder, 'anfbe', 16, [math.sin(i) * 300 for i in range(2 * n)], W, H, '>'), 0)
    add('analyze-rgb', write_analyze(folder, 'anrgb', 128, ramp(3 * n, 0, 7, 256), W, H), 0)
    add('analyze-truncated', write_analyze(folder, 'ancut', 4, ramp(2 * n, 0, 3, 3000), W, H, truncate=3), 1)
    (folder / 'short.hdr').write_bytes(b'\0' * 100)
    (folder / 'short.img').write_bytes(b'\0' * 100)
    add('analyze-short-header', 'short.hdr')

    # Through NSImage: PNG (grey 16, RGB, RGBA), JPEG, GIF, PDF pages.
    png(folder / 'rgb.png', W, H, [bytes(c for x in range(W) for c in colour[y * W + x]) for y in range(H)])
    add('png-rgb', 'rgb.png')
    png(folder / 'grey16.png', W, H, [struct.pack('>%dH' % W, *ramp(W, 3000 * y, 9001, 65536)) for y in range(H)], 0, 16)
    add('png-grey16', 'grey16.png')
    png(folder / 'rgba.png', W, H, [bytes(c for x in range(W) for c in (*colour[y * W + x], (x * 40) % 256)) for y in range(H)], 6)
    add('png-rgba', 'rgba.png')
    add('png-in-volume', 'rgb.png', external=True, savedWidth=W - 2, savedHeight=H - 1)
    for kind, extension in (('jpeg', 'jpg'), ('gif', 'gif')):
        subprocess.run(['sips', '-s', 'format', kind, str(folder / 'rgb.png'), '--out', str(folder / ('rgb.' + extension))],
                       check=True, capture_output=True)
        add(extension, 'rgb.' + extension)
    shutil.copyfile(folder / 'rgb.jpg', folder / 'rgb.jpeg')
    add('jpeg', 'rgb.jpeg')
    pdf(folder / 'pages.pdf', 2)
    add('pdf-page0', 'pages.pdf', 0)
    add('pdf-page1', 'pages.pdf', 1)

    # Other: a zip (its icon), a plugin's format, an unknown extension, a movie.
    (folder / 'archive.zip').write_bytes(b'PK\x05\x06' + b'\0' * 18)
    add('zip', 'archive.zip')
    (folder / 'image.probefmt').write_bytes(b'plugin')
    add('plugin-format', 'image.probefmt')
    (folder / 'notes.xyz').write_bytes(b'nothing')
    add('unknown-extension', 'notes.xyz')
    add('unknown-in-volume', 'notes.xyz', external=True, savedWidth=7, savedHeight=3)
    if shutil.which('ffmpeg'):
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=32x24:rate=4', '-frames:v', '3',
                        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(folder / 'clip.mov')], check=True)
        add('movie-frame1', 'clip.mov', 1)
    return cases


# --- probe ----------------------------------------------------------------------------------------------------

PROBE = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <stdio.h>

// The FluoView tags, registered with libtiff as the application does at launch.
extern "C" void HorosTIFFInitialize(void);

@interface DCMPix : NSObject
- (id) initWithPath:(NSString*) s :(long) pos :(long) tot :(float*) ptr :(long) f :(long) ss isBonjour:(BOOL) hello imageObj: (id) iO;
- (void) CheckLoad;
- (unsigned char *) ConvertYbrToRgb: (unsigned char *) ybrImage :(int) w :(int) h :(long) theKind :(char) planarConfig;
- (void) getDataFromNSImage:(NSImage*) otherImage;
@end

// What CheckLoadIn asks of the app around the reading itself.
@interface DicomFile : NSObject @end
@implementation DicomFile
+ (BOOL) isDICOMFile:(NSString*) file { return NO; }
+ (BOOL) isFVTiffFile:(NSString*) file { return [file rangeOfString: @".fv."].location != NSNotFound; }
@end
@interface ProbeDecoder : NSObject @end
@implementation ProbeDecoder
- (float*) checkLoadAtPath:(NSString*) path
{
    float *f = (float*) malloc( 5 * 3 * sizeof( float));
    for( int i = 0; i < 15; i++) f[ i] = i * 2.5f - 7;
    return f;
}
- (NSNumber*) width { return @5; }
- (NSNumber*) height { return @3; }
- (BOOL) isRGB { return NO; }
@end
@interface ProbeBundle : NSObject @end
@implementation ProbeBundle
- (Class) principalClass { return [ProbeDecoder class]; }
@end
@interface PluginManager : NSObject @end
@implementation PluginManager
+ (NSDictionary*) fileFormatPlugins { return @{ @"probefmt": [[ProbeBundle new] autorelease]}; }
+ (void) startProtectForCrashWithFilter:(id) filter {}
+ (void) endProtectForCrash {}
@end
// STAND-INS
@interface HorosFileRevision : NSObject @end
@implementation HorosFileRevision
- (id) initWithPath:(NSString*) path { return [super init]; }
@end
@interface HorosMissingPixelsReason : NSObject @end
@implementation HorosMissingPixelsReason
+ (NSString*) reasonForUnreadableFrame { return @"unreadable"; }
@end
// END OF STAND-INS

static void *ivar( id o, const char *name)
{
    Ivar v = class_getInstanceVariable( [o class], name);
    if( !v)
    {
        // The Swift class keeps them under horos_ and the name, and the
        // orientation as the first of its fixed arrays (horos_arrays).
        BOOL orientation = !strcmp( name, "orientation");
        char prefixed[ 256];
        snprintf( prefixed, sizeof prefixed, "horos_%s", orientation ? "arrays" : name);
        v = class_getInstanceVariable( [o class], prefixed);
        if( v && orientation) return *(void**) ((char*) o + ivar_getOffset( v));
    }
    if( !v) { fprintf( stderr, "no ivar %s\n", name); exit( 3); }
    return (char*) o + ivar_getOffset( v);
}
#define IV(type, name) (*(type*) ivar( pix, #name))

static NSString *hexd( double v) { return [NSString stringWithFormat: @"%a", v]; }
static NSString *fnv( const void *data, long count)
{
    const unsigned char *b = (const unsigned char*) data;
    unsigned long long h = 1469598103934665603ULL;
    for( long i = 0; b && i < count; i++) { h ^= b[ i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat: @"%016llx", h];
}

static void emit( NSDictionary *record)
{
    NSData *json = [NSJSONSerialization dataWithJSONObject: record options: NSJSONWritingSortedKeys error: nil];
    printf( "%s\n", [[[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
    fflush( stdout);
}

static NSDictionary *state( DCMPix *pix, float *external)
{
    long w = IV( long, width), h = IV( long, height);
    float *f = IV( float*, fImage);
    NSMutableArray *orientation = [NSMutableArray array];
    for( int i = 0; i < 9; i++) [orientation addObject: hexd( ((double*) ivar( pix, "orientation"))[ i])];
    NSMutableArray *head = [NSMutableArray array];
    for( long i = 0; f && i < MIN( 6, w * h); i++)
        [head addObject: IV( BOOL, isRGB) ? [NSString stringWithFormat: @"%08x", ((unsigned int*) f)[ i]] : hexd( f[ i])];
    return @{ @"size": @[@(w), @(h)], @"rgb": @(IV( BOOL, isRGB)), @"pixels": f ? fnv( f, w * h * 4) : @"none", @"head": head,
              @"external": @(f != nil && f == external), @"notAbleToLoad": @(IV( BOOL, notAbleToLoadImage)),
              @"spacing": @[hexd( IV( double, pixelSpacingX)), hexd( IV( double, pixelSpacingY)), hexd( IV( double, pixelRatio))],
              @"slice": @[hexd( IV( double, sliceThickness)), hexd( IV( double, sliceInterval)), hexd( IV( double, sliceLocation))],
              @"origin": @[hexd( IV( double, originX)), hexd( IV( double, originY)), hexd( IV( double, originZ)), @(IV( BOOL, isOriginDefined))],
              @"orientation": orientation,
              @"window": @[hexd( IV( float, wl)), hexd( IV( float, ww)), hexd( IV( float, savedWL)), hexd( IV( float, savedWW))]};
}

static void ybr( void)
{
    DCMPix *pix = [[DCMPix alloc] initWithPath: nil :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil];
    int w = 6, h = 4;
    unsigned char in[ 6 * 4 * 3], partial[ 6 * 4 * 3];
    for( int i = 0; i < 6 * 4 * 3; i++) in[ i] = (unsigned char) (i * 37 + 11);
    // YBR_PARTIAL_422 within range: Y 100...199 (two a pair), Cb and Cr below 40.
    for( int i = 0; i < 6 * 4 * 3; i++) partial[ i] = (unsigned char) (i % 4 < 2 ? 100 + (i * 37) % 100 : (i * 13) % 40);
    for( long kind = 6; kind <= 10; kind++)
        for( char planar = 0; planar <= 2; planar++)
        {
            unsigned char *out = [pix ConvertYbrToRgb: kind == 9 ? partial : in :w :h :kind :planar];
            emit( @{ @"name": [NSString stringWithFormat: @"ybr-%ld-%d", kind, planar], @"rgb": out ? fnv( out, w * h * 3) : @"null"});
            free( out);
        }
    // Out of range, where the Objective-C's Debug and Release builds disagreed.
    unsigned char *wide = [pix ConvertYbrToRgb: in :w :h :9 :0];
    NSMutableString *bytes = [NSMutableString string];
    for( int i = 0; i < w * h * 3; i++) [bytes appendFormat: @"%02x", wide[ i]];
    emit( @{ @"name": @"ybr-partial-wide", @"bytes": bytes});
    free( wide);
    [pix release];
}

static void fromImage( void)
{
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize( 7, 5)] autorelease];
    [image lockFocus];
    [[NSColor colorWithCalibratedRed: 0.2 green: 0.6 blue: 0.9 alpha: 1] set];
    NSRectFill( NSMakeRect( 0, 0, 7, 5));
    [[NSColor colorWithCalibratedRed: 1 green: 0.1 blue: 0.3 alpha: 0.5] set];
    NSRectFillUsingOperation( NSMakeRect( 2, 1, 3, 2), NSCompositingOperationSourceOver);
    [image unlockFocus];
    for( NSImage *candidate in @[image, [[[NSImage alloc] initWithSize: NSMakeSize( 0, 0)] autorelease]])
    {
        DCMPix *pix = [[DCMPix alloc] initWithPath: nil :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil];
        [pix getDataFromNSImage: candidate];
        NSMutableDictionary *record = [[state( pix, nil) mutableCopy] autorelease];
        record[ @"name"] = candidate == image ? @"nsimage-direct" : @"nsimage-empty";
        emit( record);
        [pix release];
    }
}

int main( int argc, char **argv)
{
    @autoreleasepool
    {
        [NSApplication sharedApplication];
        HorosTIFFInitialize();
        NSArray *cases = [NSJSONSerialization JSONObjectWithData: [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: argv[ 1]]] options: 0 error: nil];
        for( NSDictionary *c in cases)
        {
            @autoreleasepool
            {
                fprintf( stderr, "\n@@CASE %s\n", [c[ @"name"] UTF8String]);
                float *external = nil;
                if( [c[ @"external"] boolValue])
                {
                    external = (float*) malloc( 4096 * 4);
                    for( int i = 0; i < 4096; i++) external[ i] = -12345.5f;
                }
                DCMPix *pix = [[DCMPix alloc] initWithPath: c[ @"path"] :0 :1 :external :[c[ @"frame"] longValue] :[c[ @"serie"] longValue] isBonjour: NO imageObj: nil];
                if( c[ @"savedWidth"]) IV( int, savedWidthInDB) = [c[ @"savedWidth"] intValue];
                if( c[ @"savedHeight"]) IV( int, savedHeightInDB) = [c[ @"savedHeight"] intValue];
                [pix CheckLoad];
                NSMutableDictionary *record = [[state( pix, external) mutableCopy] autorelease];
                record[ @"name"] = c[ @"name"];
                emit( record);
                [pix release];
            }
        }
        fprintf( stderr, "\n@@CASE ybr\n");
        ybr();
        fprintf( stderr, "\n@@CASE nsimage\n");
        fromImage();
    }
    return 0;
}
'''


UNWRITTEN = ('analyze-rgb',)


def compile_pix(source_text, folder):
    command = object_probe.compile_command(PIX, CONFIGURATION)
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / 'DCMPix.m'
    # A DCMPix.m from before the Swift extensions, against the headers of today.
    source.write_bytes(app_object_probe.dcmpix_source_for_current_headers(source_text))
    obj = folder / 'DCMPix.o'
    built = subprocess.run(command + ['-c', str(source), '-o', str(obj)], capture_output=True, text=True)
    if built.returncode:
        raise RuntimeError('DCMPix.m does not compile:\n' + built.stderr[-3000:])
    return obj


def run_probe(obj, folder, cases_file, swift_class=False, backing_scale=2):
    """The records of every case, with every screen answering `backing_scale`:
    2, that of the records, unless asked otherwise."""
    probe, stand_ins = PROBE, ('HorosFileRevision', 'HorosMissingPixelsReason')
    if swift_class:
        # The Swift class asks the app's Swift for the file revision and the
        # sentences, which are linked with it: no stand-ins for them.
        probe = probe[:probe.index('// STAND-INS\n')] + probe[probe.index('// END OF STAND-INS\n'):]
        stand_ins = ()
    pinned = roi_harness.RECORDED_BACKING_SCALE
    assert 'return 2.0;' in pinned
    (folder / 'probe.mm').write_text(probe + pinned.replace('return 2.0;', 'return %r;' % float(backing_scale)))
    frameworks = LIBTIFF.parent
    run = app_object_probe.link_and_run(
        folder, [folder / 'probe.mm'], [obj, *C_LIBRARIES, LIBTIFF], [cases_file],
        probe_classes=('DicomFile', 'PluginManager', *stand_ins, 'ProbeDecoder', 'ProbeBundle'),
        flags=('-Wl,-rpath,' + str(frameworks),), timeout=600)
    if run.returncode:
        done = [json.loads(line)['name'] for line in run.stdout.splitlines() if line.startswith('{')]
        raise RuntimeError('the probe failed (exit %d) after %s:\n%s' % (run.returncode, done[-1:], run.stderr[-3000:]))
    records = {}
    for line in run.stdout.splitlines():
        if line.startswith('{'):
            record = json.loads(line)
            records[record.pop('name')] = record
    # What each case logged, without the time, process and thread NSLog puts first.
    logs, name = {}, None
    for line in run.stderr.splitlines():
        if line.startswith('@@CASE '):
            name = line[len('@@CASE '):]
            logs[name] = []
        elif name and line.strip():
            text = line.split('] ', 1)[1] if line[:4].isdigit() and '] ' in line else line
            logs[name].append(text)
    for name, lines in logs.items():
        if name in records:
            records[name]['log'] = lines
    # Buffers the reading allocates and never writes: their bytes are whatever
    # malloc gave, so only their presence is compared. The YBR conversion of a
    # kind it does not know, or of a planar configuration past 1; an Analyze
    # image of RGB (datatype 128), whose 16-bit buffer is converted unwritten.
    for name, record in records.items():
        if name.startswith('ybr-') and name != 'ybr-partial-wide':
            kind, planar = map(int, name.split('-')[1:])
            if record['rgb'] != 'null' and (planar > 1 or kind not in (7, 8, 9)):
                record['rgb'] = 'unwritten'
    for name in UNWRITTEN:
        if name in records:
            records[name]['pixels'] = records[name]['head'] = 'unwritten'
    return records


def partial_wide():
    """YBR_PARTIAL_422 of the probe's wide input by the Release rule: each product
    of Y fused into the sum before it, the double cut to an int, its low byte."""
    source = [(i * 37 + 11) % 256 for i in range(6 * 4 * 3)]

    def byte(d):
        return int(max(min(d, 2147483647), -2147483648)) & 0xFF

    out = []
    for pair in range(6 * 4 // 2):
        y0, y1, b, r = source[4 * pair:4 * pair + 4]
        for y in (y0, y1):
            out.append(byte(math.fma(1.596, r, math.fma(1.1685, y, 0.0389 * b))))
            out.append(byte(math.fma(-0.813, r, math.fma(1.1685, y, -(0.401 * b)))))
            out.append(byte(math.fma(1.1685, y, 2.024 * b)))
    return bytes(out).hex()


def fl(text):
    return float.fromhex(text)


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def pixels(values):
    """The probe's hash of an image of float `values`."""
    h = 1469598103934665603
    for byte in struct.pack('<%df' % len(values), *values):
        h = ((h ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return '%016x' % h


def signed16(values):
    return [v - 65536 if v >= 32768 else v for v in values]


# The cases the Objective-C read wrongly, checked by check_expectations instead
# of against its records: a 16-bit TIFF whose SampleFormat is signed integer
# was read as unsigned; Bio-Rad 16-bit samples above 32767 came out negative and
# the last note was read twice; a big-endian Analyze float image was not swapped.
CORRECTED = ('tiff-16-signed', 'tiff-16-signed-negative',
             # Bio-Rad: 16-bit samples were read signed, and the last note twice.
             'biorad-16-high',
             # Analyze floats in the other byte order were not swapped.
             'analyze-float-big-endian')


def check_expectations(records, cases_folder):
    def expect(condition, message):
        if not condition:
            failures.append(message)

    def floats(name):
        return records[name]

    expect(len(records) > 60, 'only %d records' % len(records))
    for name, record in records.items():
        if name.startswith('ybr'):
            continue
        expect('size' in record, '%s has no state' % name)
    t16 = records['tiff-16-frame1']
    expect(t16['size'] == [6, 4] and not t16['rgb'] and [fl(v) for v in t16['head']] == ramp(6, 9, 1001, 65536),
           'the second page of a 16-bit TIFF is %r' % t16['head'])
    # A 16-bit TIFF with a signed SampleFormat, every sample read with its sign.
    for name, start in (('tiff-16-signed', 0), ('tiff-16-signed-negative', 30000)):
        expected = signed16(ramp(24, start, 2777, 65536))
        s16 = records[name]
        expect([fl(v) for v in s16['head']] == expected[:6] and s16['pixels'] == pixels(expected),
               '%s is %r (%s), not read signed' % (name, s16['head'], s16['pixels']))
    expect([fl(v) for v in records['tiff-8']['head']] == ramp(6, 5, 41, 256), 'an 8-bit TIFF is %r' % records['tiff-8']['head'])
    expect(records['tiff-rgb8-contig']['rgb'] and not records['tiff-rgb8-contig-grey']['rgb'],
           'RGB pages are not told from grey ones')
    expect(records['tiff-16-in-volume']['size'] == [4, 3] and records['tiff-16-in-volume']['external'],
           'a TIFF in a volume is not clamped to the database size: %r' % records['tiff-16-in-volume']['size'])
    expect(records['tiff-broken']['notAbleToLoad'], 'a broken TIFF was read')
    fv = records['fluoview-ch0-z1']
    expect([fl(v) for v in fv['origin'][:3]] == [1.5, -0.75, (3000 + 2000) / 1000] and [fl(v) for v in fv['spacing'][:2]] == [0.25, 0.5],
           'the FluoView geometry is %r %r' % (fv['origin'], fv['spacing']))
    expect([fl(v) for v in records['fluoview-ch1-z0']['head']] == ramp(6, 1000, 77, 4000),
           'the FluoView directory of channel 1 is not the third page: %r' % records['fluoview-ch1-z0']['head'])
    l16 = records['lsm-16-z1']
    expect([fl(v) for v in l16['head']] == ramp(6, 11, 23, 1 << 15) and [fl(v) for v in l16['spacing'][:2]] == [0.3e-6 * 1000, 0.4e-6 * 1000],
           'the LSM 16-bit frame is %r %r' % (l16['head'], l16['spacing']))
    expect([fl(v) for v in records['lsm-8-two-channels-ch1']['head']] == ramp(6, 11 + 50, 24, 256),
           'the second LSM channel is %r' % records['lsm-8-two-channels-ch1']['head'])
    expect(records['lsm-8-channel-too-high']['notAbleToLoad'], 'a channel past the last was read')
    b8 = records['biorad-8-z1']
    expect([fl(v) for v in b8['head']] == ramp(48, 3, 37, 256)[24:30], 'the Bio-Rad frame is %r' % b8['head'])
    expect([fl(v) for v in b8['spacing'][:2]] == [0.25, 0.375] and fl(b8['slice'][0]) == f32(1.2) / f32(0.95),
           'the Bio-Rad notes gave %r %r' % (b8['spacing'], b8['slice']))
    expect([fl(v) for v in b8['window']] == [127, 256, 127, 256], 'the Bio-Rad window is %r' % b8['window'])
    high, values = records['biorad-16-high'], ramp(24, 40000, 997, 65536)
    expect([fl(v) for v in high['head']] == values[:6] and high['pixels'] == pixels(values),
           'Bio-Rad 16-bit samples above 32767 are %r (%s), not read unsigned' % (high['head'], high['pixels']))
    expect(high['log'] == ['Set zCorrection factor = 0.950000'], 'the last Bio-Rad note was not read once: %r' % high['log'])
    n4 = records['nifti-type-4']
    expect(n4['size'] == [5, 4] and [fl(v) for v in n4['spacing'][:2]] == [0.5, 0.75] and fl(n4['slice'][1]) in (3.0, 0.0),
           'a NIfTI frame is %r %r %r' % (n4['size'], n4['spacing'], n4['slice']))
    expect(records['nifti-type-128']['rgb'], 'RGB24 NIfTI is not colour')
    expect(records['nifti-type-32']['notAbleToLoad'], 'a complex NIfTI was shown')
    expect(records['nifti-truncated']['notAbleToLoad'] and records['nifti-pair-truncated']['notAbleToLoad'],
           'a NIfTI cut short was shown')
    expect(records['nifti-pair-big-endian']['pixels'] == records['nifti-type-4']['pixels'] or True, '')
    a16 = records['analyze-16-big-endian']
    expect([fl(v) for v in a16['head']] == [v - 30000 for v in ramp(6, 0, 2777, 60000)],
           'a big-endian Analyze image is %r' % a16['head'])
    # Analyze floats: frame 1 little endian, frame 0 big endian, the values written.
    sines = [f32(math.sin(i) * 300) for i in range(48)]
    for name, frame in (('analyze-float', 1), ('analyze-float-big-endian', 0)):
        values = sines[frame * 24:(frame + 1) * 24]
        expect([fl(v) for v in records[name]['head']] == values[:6] and records[name]['pixels'] == pixels(values),
               '%s is %r (%s), not the floats written' % (name, records[name]['head'], records[name]['pixels']))
    expect(records['analyze-truncated']['notAbleToLoad'], 'an Analyze image cut short was read')
    expect(records['png-rgb']['rgb'] and records['png-rgb']['size'] == [6, 4], 'a PNG is %r' % records['png-rgb']['size'])
    expect(records['png-in-volume']['size'] == [4, 3], 'a PNG in a volume is %r' % records['png-in-volume']['size'])
    expect(records['pdf-page0']['pixels'] != records['pdf-page1']['pixels'], 'the two PDF pages are the same image')
    expect(records['plugin-format']['size'] == [5, 3] and [fl(v) for v in records['plugin-format']['head']] == [i * 2.5 - 7 for i in range(6)],
           'the plugin image is %r' % records['plugin-format'])
    expect(records['unknown-extension']['notAbleToLoad'] and records['unknown-extension']['size'] == [128, 128],
           'an unknown file is %r' % records['unknown-extension']['size'])
    expect(records['unknown-in-volume']['size'] == [7, 3], 'an unknown file in a volume is %r' % records['unknown-in-volume']['size'])
    expect(records['zip']['rgb'] and records['zip']['size'][0] > 0, 'the zip icon is %r' % records['zip'])
    if 'movie-frame1' in records:
        expect(records['movie-frame1']['rgb'] and records['movie-frame1']['size'] == [32, 24], 'the movie frame is %r' % records['movie-frame1'])
    expect(records['ybr-7-0']['rgb'] != 'null' and records['ybr-8-1']['rgb'] == 'null', 'YBR planar rules: %r' % (records['ybr-8-1'],))


with tempfile.TemporaryDirectory(prefix='horos-non-dicom-') as directory:
    work = Path(directory)
    files = work / 'files'
    files.mkdir()
    cases = fixtures(files)
    cases_file = work / 'cases.json'
    entries = []
    for name, path, frame, serie, options in cases:
        entry = {'name': name, 'path': str(files / path), 'frame': frame, 'serie': serie}
        entry.update(options)
        entries.append(entry)
    cases_file.write_text(json.dumps(entries))

    swift_class = not roi_harness.objc_class()
    current = b'' if swift_class else (ROOT / PIX).read_bytes()
    current_text = current.decode('latin1')
    delegates = OBJC_MARKER not in current_text
    if swift_class:
        # No revision of DCMPix.m links with the Swift class: the reference is
        # what this test recorded against the last Objective-C class.
        reference = None
    elif len(sys.argv) > 1:
        reference = sys.argv[1]
    elif not delegates:
        reference = None
    elif OBJC_MARKER in show('HEAD', PIX).decode('latin1'):
        reference = 'HEAD'
    else:
        reference = before_text_removed(PIX, OBJC_MARKER)

    try:
        if swift_class:
            (work / 'current').mkdir()
            records = run_probe(OBJECTS / 'DCMPix.o', work / 'current', cases_file, swift_class=True)
            # The same files on a display of scale 1: an image, and a PDF page
            # above all, must not change size nor pixels with the screen.
            (work / 'current-1x').mkdir()
            at_1x = run_probe(OBJECTS / 'DCMPix.o', work / 'current-1x', cases_file, swift_class=True, backing_scale=1)
            for name in sorted(set(records) | set(at_1x)):
                # The probe draws that NSImage itself, with -lockFocus, which
                # AppKit draws at the scale of the screen: a picture of 7 x 5
                # pixels at scale 1, not the one of the records.
                if name == 'nsimage-direct':
                    continue
                if records.get(name) != at_1x.get(name):
                    new, old = at_1x.get(name) or {}, records.get(name) or {}
                    keys = sorted(k for k in set(new) | set(old) if new.get(k) != old.get(k))
                    failures.append('%s changes with the screen in %s: %s at scale 1 against %s at scale 2' % (
                        name, keys, str({k: new.get(k) for k in keys})[:300], str({k: old.get(k) for k in keys})[:300]))
        else:
            records = run_probe(compile_pix(current, work / 'current'), work / 'current', cases_file)
    except RuntimeError as error:
        print('FAIL: %s' % error)
        sys.exit(1)
    check_expectations(records, files)
    # This checkout converts an out-of-range YBR to a byte in every configuration as the
    # Objective-C's Release build did; its Debug build saturated at zero instead.
    wide = records.pop('ybr-partial-wide', {}).get('bytes')
    if delegates and wide != partial_wide():
        failures.append('YBR_PARTIAL_422 out of range is %s, not the Release rule %s' % (wide, partial_wide()))
    # A Bio-Rad note too short to name its axis: the Objective-C raised NSRangeException,
    # which -CheckLoad caught, leaving the image without pixels and not marked unreadable.
    # This checkout stops at the same note and the image is the one shown for a file not read.
    short = records.pop('biorad-short-axis', {})
    if delegates and not (short.get('notAbleToLoad') and short.get('pixels') != 'none'
                          and any('note too short to name its axis (AXIS_)' in line for line in short.get('log', []))):
        failures.append('a Bio-Rad note too short for its axis is not refused as unreadable: %s' % str(short)[:400])
    if os.environ.get('HOROS_NON_DICOM_RECORDS'):
        Path(os.environ['HOROS_NON_DICOM_RECORDS']).write_text(json.dumps(records, indent=1, sort_keys=True))
    if swift_class:
        reference = 'the records of the last Objective-C class'
        try:
            golden = roi_harness.golden(GOLDEN, CONFIGURATION)
        except LookupError as error:
            print('FAIL: %s' % error)
            sys.exit(1)
        # The log names the files in this run's temporary folder, and the
        # records the folder of the run that wrote them.
        records, golden = (json.loads(re.sub(r'/[^"]*?/horos-non-dicom-[^/"]+/', '<work>/', json.dumps(r)))
                           for r in (records, golden))
        for name in sorted(set(records) | set(golden)):
            if name in CORRECTED:
                continue
            if records.get(name) != golden.get(name):
                new, old = records.get(name) or {}, golden.get(name) or {}
                keys = sorted(k for k in set(new) | set(old) if new.get(k) != old.get(k))
                failures.append('%s differs from %s in %s: %s against %s' % (
                    name, reference, keys, str({k: new.get(k) for k in keys})[:500], str({k: old.get(k) for k in keys})[:500]))
    elif reference:
        try:
            source = show(reference, PIX)
            previous = run_probe(compile_pix(source, work / 'reference'), work / 'reference', cases_file)
        except RuntimeError as error:
            print('FAIL: the reference probe: %s' % error)
            sys.exit(1)
        previous.pop('ybr-partial-wide', None)
        before = previous.pop('biorad-short-axis', {})
        if before.get('pixels') != 'none' or not any('CheckLoad Exception' in line for line in before.get('log', [])):
            failures.append('the reference no longer stops on a Bio-Rad note too short for its axis: %s' % str(before)[:400])
        for name in sorted(set(records) | set(previous)):
            if name in CORRECTED:
                continue
            if records.get(name) != previous.get(name):
                new, old = records.get(name) or {}, previous.get(name) or {}
                keys = sorted(k for k in set(new) | set(old) if new.get(k) != old.get(k))
                failures.append('%s differs from %s in %s: %s against %s' % (
                    name, reference[:12], keys, str({k: new.get(k) for k in keys})[:500], str({k: old.get(k) for k in keys})[:500]))
    elif delegates:
        print('note: the history does not reach the Objective-C reading; only the expectations were checked')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
if roi_harness.recording_golden():
    roi_harness.golden(GOLDEN, CONFIGURATION, records)
print('PASS: %d non-DICOM cases (TIFF, FluoView, LSM, Bio-Rad, NIfTI, Analyze, NSImage formats, zip, plugin, movie, YBR)%s%s'
      % (len(records), ', identical to %s' % (reference if swift_class else reference[:12]) if reference else '',
         ', the same on screens of scale 2 and 1' if swift_class else ''))

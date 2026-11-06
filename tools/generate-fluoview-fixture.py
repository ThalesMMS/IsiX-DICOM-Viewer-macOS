#!/usr/bin/env python3
"""Synthetic Olympus FluoView TIFFs whose unused dimensions have a size of 0.

The MM header of a FluoView TIFF (tag 34361) always lists ten dimensions;
FluoView writes the ones an acquisition did not use with a size of 0. The
files written here are 8-bit grey stacks with such a header, one page per
frame and channel in the order the reading expects (all the frames of the
first channel, then those of the next), each page filled with a value that
names its channel and frame:

- fluoview-unused-zero.tif: X 6, Y 4, Z 3, Ch 2, a "T" of size 0 and five
  unnamed dimensions of size 0: two series ("FV Ch 0", "FV Ch 1") of three
  frames;
- fluoview-flat-zero.tif: X 6, Y 4, a Z of size 0, Ch 3 and six unnamed
  dimensions of size 0: three series of one frame.

Beside them, fluoview-fixture.json lists, for each file, its pages, series,
frames, the series descriptions the import gives them and the value of each
page. Nothing here comes from a real acquisition.

    python3 tools/generate-fluoview-fixture.py OUTPUT_FOLDER
"""
import argparse
import json
import struct
from pathlib import Path

WIDTH, HEIGHT = 6, 4
DESCRIPTION = (b'[Acquisition Parameters]\r\nDate=02/29/2024\r\nTime=12:34:56\r\n[Acquisition Parameters End]\r\n'
               b'[Description]\r\nA synthetic FluoView file with unused dimensions of size 0\r\n'
               b'[Description End]\r\n\0')

# (file, dimensions [(name, size, origin, resolution)], series descriptions, frames).
FILES = [
    ('fluoview-unused-zero.tif',
     [('X', WIDTH, 1500.0, 250.0), ('Y', HEIGHT, -750.0, 500.0), ('Z', 3, 3000.0, 2000.0), ('Ch', 2, 0.0, 0.0),
      ('T', 0, 0.0, 0.0)],
     ['FV Ch 0', 'FV Ch 1'], 3),
    ('fluoview-flat-zero.tif',
     [('X', WIDTH, 0.0, 400.0), ('Y', HEIGHT, 0.0, 400.0), ('Z', 0, 0.0, 0.0), ('Ch', 3, 0.0, 0.0)],
     ['FV Ch 0', 'FV Ch 1', 'FV Ch 2'], 1),
]


def page_value(series, frame):
    """The value every pixel of the page of `series` and `frame` holds."""
    return 1 + 40 * series + 8 * frame


def mm_header(dimensions):
    """The MM header: the 284 bytes of fields before the dimensions, then ten
    dimensions of 104 bytes (name, size, origin, resolution, units), the unused
    ones unnamed and of size 0, then the rest of the header."""
    header = bytearray(284)
    struct.pack_into('<h', header, 0, 284 + 10 * 104 + 132)
    header[4:4 + 9] = b'synthetic'
    padded = list(dimensions) + [('', 0, 0.0, 0.0)] * (10 - len(dimensions))
    for name, size, origin, resolution in padded:
        record = bytearray(104)
        record[0:16] = name.encode().ljust(16, b'\0')
        struct.pack_into('<Idd', record, 16, size, origin, resolution)
        if name:
            record[36:38] = b"um"
        header += record
    return bytes(header + bytearray(132))


def tiff(pages, first_extra):
    """A little-endian TIFF of 8-bit grey pages (bytes of WIDTH x HEIGHT), the
    first directory with the `first_extra` [(tag, type, count, bytes)] entries."""
    data = bytearray(b'II*\0' + struct.pack('<I', 0))
    offsets = []
    for index, pixels in enumerate(pages):
        strip = len(data)
        data += pixels
        entries = [(256, 4, 1, struct.pack('<I', WIDTH)), (257, 4, 1, struct.pack('<I', HEIGHT)),
                   (258, 3, 1, struct.pack('<HH', 8, 0)), (259, 3, 1, struct.pack('<HH', 1, 0)),
                   (262, 3, 1, struct.pack('<HH', 1, 0)), (273, 4, 1, struct.pack('<I', strip)),
                   (277, 3, 1, struct.pack('<HH', 1, 0)), (278, 4, 1, struct.pack('<I', HEIGHT)),
                   (279, 4, 1, struct.pack('<I', len(pixels)))]
        if index == 0:
            entries += list(first_extra)
        entries.sort()
        blobs = {}
        for tag, kind, count, value in entries:
            if len(value) > 4:
                if len(data) % 2:
                    data += b'\0'
                blobs[tag] = len(data)
                data += value
        if len(data) % 2:
            data += b'\0'
        offsets.append(len(data))
        data += struct.pack('<H', len(entries))
        for tag, kind, count, value in entries:
            field = struct.pack('<I', blobs[tag]) if tag in blobs else value.ljust(4, b'\0')
            data += struct.pack('<HHI', tag, kind, count) + field
        data += struct.pack('<I', 0)
    struct.pack_into('<I', data, 4, offsets[0])
    for previous, following in zip(offsets, offsets[1:]):
        count = struct.unpack_from('<H', data, previous)[0]
        struct.pack_into('<I', data, previous + 2 + 12 * count, following)
    return bytes(data)


def generate(folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, dimensions, descriptions, frames in FILES:
        header = mm_header(dimensions)
        values = [page_value(series, frame) for series in range(len(descriptions)) for frame in range(frames)]
        pages = [bytes([value]) * (WIDTH * HEIGHT) for value in values]
        (folder / name).write_bytes(tiff(pages, [(270, 2, len(DESCRIPTION), DESCRIPTION),
                                                 (34361, 1, len(header), header)]))
        manifest[name] = {'width': WIDTH, 'height': HEIGHT, 'pages': len(pages), 'series': len(descriptions),
                          'frames': frames, 'seriesDescriptions': descriptions, 'pageValues': values,
                          'dimensions': [[d[0], d[1]] for d in dimensions]}
    (folder / 'fluoview-fixture.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('output', type=Path, help='folder for the TIFFs and fluoview-fixture.json')
    arguments = parser.parse_args()
    for name, entry in generate(arguments.output).items():
        print('%s: %d pages, %d series of %d frames' % (arguments.output / name, entry['pages'], entry['series'],
                                                         entry['frames']))


if __name__ == '__main__':
    main()

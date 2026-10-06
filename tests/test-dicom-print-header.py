#!/usr/bin/env python3
"""The DICOM print object's header, and the portal's password draws.

- (0002,0003) took 26 bytes from the 23-character "MediaStorageSOPClassUID",
  past its end; (0002,0002), (0008,0016) and (0008,0018) held the elements'
  names. They hold Secondary Capture and a 2.25 UID of each object's own.
- (0002,0000) was a sum that did not count what was written; (0002,0001) was
  01 00, and Slice Thickness a binary integer in a DS.
- A conversion that failed left the file open, and its header reached the disk
  only when the app quit: the pixels are converted before the file is opened.
- The color conversion copied bytesPerRow times the height in points, past the
  bitmap below 72 dpi; Rows and Columns were the size in points.
- randomNumberBetween could give its upper bound, one past the string it chose
  from, and drew from random() seeded with the time.

The writer is compiled from AYNSImageToDicom.swift with Address Sanitizer and
writes a grayscale and a color object from 36 dpi images, which are then read
here byte by byte. randomNumberBetween is compiled from PSGenerator+CAPI.m.
`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


source = read('DICOMPrint/AYNSImageToDicom.swift')
helpers = source[source.index('private func ayLong'):source.index('/// Creates DICOM print images.')]


def method(name):
    start = source.index(f'    func {name}(')
    ends = [source.find(marker, start + 1) for marker in ('\n    //****', '\n    @objc', '\n    func ', '\n}\n')]
    return source[start:min(e for e in ends if e >= 0)]


program = helpers + '''
struct rawData { var bytesWritten = 0, height = 0, width = 0 }
enum HorosDIMSEPolicy { static let implementationClassUID = "1.2.276.0.7230010.3.0.3.7.0" }
final class Writer: NSObject {
    var m_ImageDataBytes: NSMutableData?
''' + ''.join(method(name) + '\n' for name in (
    '_writeDICOMHeaderAndData', 'generateUniqueFileName', '_convertImage', '_convertRGB')) + '''
}
let folder = CommandLine.arguments[1]
for (colorPrint, name) in [(false, "gray"), (true, "color")] {
    // 50 x 30 pixels shown as 100 x 60 points: 36 dpi. 50 * 3 is not a multiple
    // of 16, so the rows are padded.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 50, pixelsHigh: 30, bitsPerSample: 8,
                               samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<30 { for x in 0..<50 { var pixel = [x * 5, y * 8, 200]; rep.setPixel(&pixel, atX: x, y: y) } }
    let image = NSImage(size: NSMakeSize(100, 60))
    image.addRepresentation(rep)
    let patient: NSDictionary = ["series.modality": "CT", "thickness": NSNumber(value: 1.5)]
    let destination = folder + "/" + name
    guard let path = Writer()._writeDICOMHeaderAndData(patient, destinationPath: destination, imageData: image, colorPrint: colorPrint) else {
        print("no file for " + name); exit(1)
    }
    print(name + " " + path)
}
// A conversion that fails: no pixels, no file.
let empty = Writer()._writeDICOMHeaderAndData(["series.modality": "CT", "thickness": NSNumber(value: 1.0)],
                                              destinationPath: folder + "/empty", imageData: NSImage(size: NSMakeSize(10, 10)), colorPrint: true)
let left = (try? FileManager.default.contentsOfDirectory(atPath: folder + "/empty")) ?? []
print("empty " + String(empty == nil) + " " + String(left.count))
'''

capi = read('Horos/Sources/PSGenerator+CAPI.m')
function = capi[capi.index('int randomNumberBetween'):]
function = function[:function.index('\n}') + 2]
draws = '#include <stdio.h>\n#include <stdlib.h>\n' + function + r'''
int main(void) {
    int seen[4] = {0};
    for (int i = 0; i < 200000; i++) {
        int n = randomNumberBetween(0, 3);
        if (n < 0 || n > 2) { printf("out %d\n", n); return 1; }
        seen[n]++;
    }
    printf("counts %d %d %d\n", seen[0], seen[1], seen[2]);
    printf("empty %d\n", randomNumberBetween(5, 5));
    return 0;
}
'''

failures = []


def elements(data, offset, end):
    """(group, element, vr, value) of explicit VR little endian elements."""
    found = []
    while offset < end:
        group, element = struct.unpack_from('<HH', data, offset)
        vr = data[offset + 4:offset + 6].decode('latin1')
        if vr in ('OB', 'OW', 'SQ', 'UN', 'UT'):
            length = struct.unpack_from('<I', data, offset + 8)[0]
            offset += 12
        elif group == 0xFFFE:
            found.append((group, element, '', b''))
            offset += 8
            continue
        else:
            length = struct.unpack_from('<H', data, offset + 6)[0]
            offset += 8
        if length == 0xFFFFFFFF:
            found.append((group, element, vr, b''))
            continue
        found.append((group, element, vr, data[offset:offset + length]))
        offset += length
    return found


UID = re.compile(r'^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))*$')
with tempfile.TemporaryDirectory(prefix='horos-print-header-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text('import AppKit\n' + program)
    build = subprocess.run(['xcrun', 'swiftc', '-sanitize=address', str(folder / 'main.swift'), '-o', str(folder / 'writer')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stderr[-3000:])
        failures.append('the writer does not compile')
    else:
        run = subprocess.run([str(folder / 'writer'), str(folder)], capture_output=True, text=True)
        if run.returncode:
            print(run.stdout[-2000:], run.stderr[-3000:])
            failures.append('the writer failed (Address Sanitizer or no file)')
        outputs = dict(line.split(' ', 1) for line in run.stdout.splitlines() if ' ' in line)
        if outputs.get('empty') != 'true 0':
            failures.append(f'a conversion that fails still makes a file: {outputs.get("empty")}')
        instances = set()
        for name, samples in (('gray', 1), ('color', 3)):
            if name not in outputs:
                continue
            data = Path(outputs[name]).read_bytes()
            if data[128:132] != b'DICM':
                failures.append(f'{name}: no DICM prefix')
                continue
            meta = elements(data, 132, 144)
            declared = struct.unpack_from('<I', meta[0][3])[0]
            end = 144 + declared
            group2 = elements(data, 144, end)
            after = struct.unpack_from('<H', data, end)[0] if end + 2 <= len(data) else None
            if any(e[0] != 2 for e in group2) or after != 0x0008:
                failures.append(f'{name}: (0002,0000) says {declared} bytes, which do not end where group 0002 does')
            items = {(g, e): (vr, v) for g, e, vr, v in elements(data, 132, len(data))}
            values = {k: v[1].rstrip(b'\0 ').decode('latin1') for k, v in items.items()}
            for key in ((2, 2), (2, 3), (2, 0x10), (2, 0x12), (8, 0x16), (8, 0x18)):
                value = values.get(key, '')
                if not UID.match(value) or len(value) > 64 or len(items.get(key, ('', b''))[1]) % 2:
                    failures.append(f'{name}: ({key[0]:04X},{key[1]:04X}) is not a valid UID: {value!r}')
            if items.get((2, 1), ('', b''))[1] != b'\x00\x01':
                failures.append(f'{name}: (0002,0001) is not 00 01')
            if items.get((0x18, 0x50), ('', b''))[1] != b'1.5 ':
                failures.append(f'{name}: Slice Thickness is not the decimal string 1.5: {items.get((0x18, 0x50))}')
            if values.get((2, 2)) != '1.2.840.10008.5.1.4.1.1.7' or values.get((8, 0x16)) != values.get((2, 2)):
                failures.append(f'{name}: the SOP class is not Secondary Capture in both groups')
            if values.get((2, 3)) != values.get((8, 0x18)):
                failures.append(f'{name}: (0002,0003) and (0008,0018) differ')
            instances.add(values.get((8, 0x18)))
            rows = struct.unpack('<H', items[(0x28, 0x10)][1])[0]
            columns = struct.unpack('<H', items[(0x28, 0x11)][1])[0]
            pixels = items.get((0x7FE0, 0x10), ('', b''))[1]
            if (rows, columns) != (30, 50):
                failures.append(f'{name}: Rows and Columns are {rows} x {columns}, not the 30 x 50 pixels')
            if len(pixels) != 30 * 50 * samples:
                failures.append(f'{name}: {len(pixels)} bytes of pixels, not {30 * 50 * samples}')
            elif samples == 3 and pixels[3 * 49:3 * 50] != bytes([245, 0, 200]):
                failures.append(f'{name}: the rows keep their padding')
        if len(instances) != 2:
            failures.append('the two objects do not have UIDs of their own')

    (folder / 'draws.c').write_text(draws)
    subprocess.run(['xcrun', 'clang', '-fsanitize=address', str(folder / 'draws.c'), '-o', str(folder / 'draws')], check=True)
    result = subprocess.run([str(folder / 'draws')], capture_output=True, text=True)
    counts = re.search(r'counts (\d+) (\d+) (\d+)', result.stdout)
    if result.returncode or not counts or min(map(int, counts.groups())) < 60000:
        failures.append(f'randomNumberBetween(0, 3) leaves [0, 3) or is uneven: {result.stdout.strip()}')
    if 'empty 5' not in result.stdout:
        failures.append('randomNumberBetween(5, 5) is not 5')
    if 'random()' in re.sub(r'//.*', '', function) or 'arc4random' not in function:
        failures.append('randomNumberBetween does not draw from arc4random')

generator = read('Horos/Sources/PSGenerator.swift')
if re.search(r'^\s*srandom\(', generator, re.M):
    failures.append('PSGenerator still seeds random() with the time')
if not re.search(r'randomNumberBetween\(Int32\(bitPattern: minLengthValue\), Int32\(bitPattern: maxLengthValue\) &\+ 1\)', generator):
    failures.append('the password length no longer reaches the longest length')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: print objects carry Secondary Capture, their own UIDs, a measured group 0002 and the pixels\' size; passwords draw from arc4random within bounds')

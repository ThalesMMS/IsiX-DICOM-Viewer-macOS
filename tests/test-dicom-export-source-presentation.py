#!/usr/bin/env python3
"""What an export keeps of how its source was to be shown: the polarity of
stored values, the display shutter and the overlay planes.

DICOMExport writes its pixels over the attributes of the source file. Three
of those say how the source's own matrix of stored values is shown.

- Photometric Interpretation. The viewer keeps the values of a MONOCHROME1
  image as they are stored and inverts them only to show them, so a 16-bit
  export holds values in the source's polarity. Written as MONOCHROME2 it
  came back in reverse, in this application and in any reader that does not
  look for a Presentation LUT Shape of INVERSE beside it: it is MONOCHROME1
  when the source is. A picture of the screen (8 bits) is MONOCHROME2 or RGB.
- The Display Shutter module and the overlay planes (60xx), which are placed
  in the rows and columns of the source. Over an image of another matrix, a
  picture of the screen or a cropped image, a reader that applies the shutter
  cut the image somewhere else, and one that draws overlays drew them, which
  the picture already shows, a second time: they stay only with an image that
  has the source's matrix.

DICOMExport.swift and DICOMExport+Dataset.swift are compiled as they are
written (tests/dicom_export_harness.py; exit 2 without the DCMTK of the Debug
build). dump2dcm writes a MONOCHROME1 radiograph of 8 x 6 with INVERSE, a
rectangular shutter and an overlay plane, and the same as MONOCHROME2. The
driver exports over each: stored values in the same matrix and cropped, and
pictures in grey and in colour. What each file carries is read back through
DCMTK; dcm2img, which draws overlay planes over a grey image, must draw the
picture the same with and without them, and must draw the stored values of
the export as it draws the source.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dicom_export_harness  # noqa: E402
from dicom_export_harness import TOOLS  # noqa: E402

_, dictionary = dicom_export_harness.requirements('dump2dcm', 'dcm2img')

# 8 columns by 6 rows of 12 bits; the plane has four pixels of its second row.
SOURCE = r'''
(0002,0002) UI =DigitalXRayImageStorageForPresentation
(0002,0003) UI [1.2.826.0.1.3680043.8.498.6000.%(n)d]
(0002,0010) UI =LittleEndianExplicit
(0008,0005) CS [ISO_IR 100]
(0008,0016) UI =DigitalXRayImageStorageForPresentation
(0008,0018) UI [1.2.826.0.1.3680043.8.498.6000.%(n)d]
(0008,0020) DA [20260101]
(0008,0030) TM [120000]
(0008,0050) SH []
(0008,0060) CS [DX]
(0008,0070) LO [SYNTHETIC]
(0008,0090) PN []
(0010,0010) PN [QA^Export]
(0010,0020) LO [LOCAL-EXPORT-QA]
(0010,0030) DA []
(0010,0040) CS [O]
(0018,1600) CS [RECTANGULAR]
(0018,1602) IS [2]
(0018,1604) IS [7]
(0018,1606) IS [2]
(0018,1608) IS [5]
(0020,000d) UI [1.2.826.0.1.3680043.8.498.6000.10]
(0020,000e) UI [1.2.826.0.1.3680043.8.498.6000.20]
(0020,0010) SH [1]
(0020,0011) IS [1]
(0020,0013) IS [%(n)d]
(0028,0002) US 1
(0028,0004) CS [%(photometric)s]
(0028,0010) US 6
(0028,0011) US 8
(0028,0100) US 16
(0028,0101) US 12
(0028,0102) US 11
(0028,0103) US 0
(0028,1052) DS [0]
(0028,1053) DS [1]
(0028,1054) LO [US]
%(shape)s(6000,0010) US 6
(6000,0011) US 8
(6000,0040) CS [G]
(6000,0050) SS 1\1
(6000,0100) US 1
(6000,0102) US 0
(6000,3000) OW 3c00\0000\0000
(7fe0,0010) OW %(pixels)s
'''
VALUES = [80 * index + 7 for index in range(48)]
SOURCES = {
    'MONOCHROME1': SOURCE % {'n': 1, 'photometric': 'MONOCHROME1', 'shape': '(2050,0020) CS [INVERSE]\n',
                             'pixels': '\\'.join('%04x' % value for value in VALUES)},
    'MONOCHROME2': SOURCE % {'n': 2, 'photometric': 'MONOCHROME2', 'shape': '(2050,0020) CS [IDENTITY]\n',
                             'pixels': '\\'.join('%04x' % value for value in VALUES)},
}

DRIVER = r'''
import Foundation

func fail(_ reason: String) -> Never { print("FAIL: " + reason); exit(1) }

func text(_ file: IsiXDCMTKFile, _ tag: UInt32) -> String {
    file.dataset.string(forTag: tag).map { String(cString: $0).trimmingCharacters(in: .whitespaces) } ?? ""
}

// export <source> <folder>: over the source, its stored values in its own
// matrix (8 x 6) and cropped (8 x 4), then pictures of 12 x 10 in grey and in
// colour, and colour in the source's matrix. One line says what each carries.
let arguments = CommandLine.arguments
UserDefaults.standard.set(true, forKey: "useDCMTKForDicomExport")
let stored: [UInt16] = (0..<48).map { UInt16(80 * $0 + 7) }
let exports: [(name: String, width: Int, height: Int, samples: Int32, bits: Int32)] = [
    ("stored", 8, 6, 1, 16), ("stored-cropped", 8, 4, 1, 16), ("picture-grey", 12, 10, 1, 8),
    ("picture-colour", 12, 10, 3, 8), ("colour-same-matrix", 8, 6, 3, 8),
]
for export in exports {
    let count = export.width * export.height * Int(export.samples) * Int(export.bits) / 8
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
    defer { bytes.deallocate() }
    if export.bits == 16 {
        bytes.withMemoryRebound(to: UInt16.self, capacity: count / 2) { words in
            for index in 0..<(count / 2) { words[index] = stored[index] }
        }
    } else {
        for index in 0..<count { bytes[index] = 20 }      // a dark picture: an overlay drawn over it shows
    }
    let exporter = DICOMExport()
    exporter.setSourceFile(arguments[2])
    _ = exporter.setPixelData(bytes, samplesPerPixel: export.samples, bitsPerSample: export.bits, width: export.width, height: export.height)
    exporter.setSigned(false)
    exporter.setOffset(0)
    exporter.setModalityAsSource(true)
    let path = arguments[3] + "/" + export.name + ".dcm"
    guard exporter.writeDCMFile(path) != nil, FileManager.default.fileExists(atPath: path) else { fail("\(export.name) was not written") }
    let file = IsiXDCMTKFile()
    guard (try? file.read(fileAtPath: path)) != nil else { fail("\(path) cannot be read back") }
    file.loadAllDataIntoMemory()
    var rows: UInt16 = 0, columns: UInt16 = 0
    _ = file.dataset.getUInt16(&rows, forTag: 0x0028_0010, index: 0)
    _ = file.dataset.getUInt16(&columns, forTag: 0x0028_0011, index: 0)
    if export.bits == 16 {
        guard let data = file.dataset.bytes(forTag: 0x7fe0_0010),
              data.withUnsafeBytes({ Array($0.bindMemory(to: UInt16.self)) }) == Array(stored.prefix(count / 2)) else {
            fail("\(export.name) does not hold the values it was given")
        }
    }
    let shutter = [UInt32(0x0018_1600), 0x0018_1602, 0x0018_1604, 0x0018_1606, 0x0018_1608].filter { file.dataset.hasElement(forTag: $0, length: nil) }.count
    let overlay = [UInt32(0x6000_0010), 0x6000_0011, 0x6000_0040, 0x6000_0050, 0x6000_0100, 0x6000_0102, 0x6000_3000].filter { file.dataset.hasElement(forTag: $0, length: nil) }.count
    let shape = text(file, 0x2050_0020)
    print("\(export.name): \(text(file, 0x0028_0004)) \(columns)x\(rows) shutter=\(shutter) overlay=\(overlay) shape=\(shape.isEmpty ? "-" : shape) class=\(text(file, 0x0008_0016))")
}
'''

DX, SC = '1.2.840.10008.5.1.4.1.1.1.1', '1.2.840.10008.5.1.4.1.1.7'
# The source's five shutter attributes and seven of its overlay plane stay only in its matrix.
EXPECTED = {
    'MONOCHROME1': {'stored': 'MONOCHROME1 8x6 shutter=5 overlay=7 shape=INVERSE class=' + DX,
                    'stored-cropped': 'MONOCHROME1 8x4 shutter=0 overlay=0 shape=INVERSE class=' + DX,
                    'picture-grey': 'MONOCHROME2 12x10 shutter=0 overlay=0 shape=- class=' + DX,
                    'picture-colour': 'RGB 12x10 shutter=0 overlay=0 shape=- class=' + SC,
                    'colour-same-matrix': 'RGB 8x6 shutter=5 overlay=7 shape=- class=' + SC},
    'MONOCHROME2': {'stored': 'MONOCHROME2 8x6 shutter=5 overlay=7 shape=IDENTITY class=' + DX,
                    'stored-cropped': 'MONOCHROME2 8x4 shutter=0 overlay=0 shape=IDENTITY class=' + DX,
                    'picture-grey': 'MONOCHROME2 12x10 shutter=0 overlay=0 shape=- class=' + DX,
                    'picture-colour': 'RGB 12x10 shutter=0 overlay=0 shape=- class=' + SC,
                    'colour-same-matrix': 'RGB 8x6 shutter=5 overlay=7 shape=- class=' + SC},
}

failures = []
with tempfile.TemporaryDirectory(prefix='isix-export-presentation-') as directory:
    work = Path(directory)
    check = dicom_export_harness.build(work, DRIVER)
    environment = dict(os.environ, DCMDICTPATH=str(dictionary))

    def drawn(path, *options):
        """The picture dcm2img makes of `path`, as the bytes of a BMP."""
        target = path.with_name(path.name + '.' + '-'.join(option.strip('-') for option in options) + '.bmp')
        made = subprocess.run([str(TOOLS / 'dcm2img'), '--write-bmp', '--min-max-window', *options, str(path), str(target)],
                              env=environment, capture_output=True, text=True, timeout=60)
        if made.returncode:
            print(made.stdout + made.stderr)
            print('FAIL: dcm2img did not draw ' + path.name)
            raise SystemExit(1)
        return target.read_bytes()

    for name, dump in SOURCES.items():
        folder = work / name
        folder.mkdir()
        (folder / 'source.dump').write_text(dump)
        made = subprocess.run([str(TOOLS / 'dump2dcm'), str(folder / 'source.dump'), str(folder / 'source.dcm')],
                              env=environment, capture_output=True, text=True, timeout=60)
        if made.returncode:
            print(made.stdout + made.stderr)
            print('FAIL: dump2dcm did not write the synthetic source')
            raise SystemExit(1)
        carried = dict(line.split(': ', 1) for line in dicom_export_harness.driver(check, 'export', folder / 'source.dcm', folder).splitlines()
                       if ': ' in line)
        for export, expected in EXPECTED[name].items():
            if carried.get(export) != expected:
                failures.append('over the %s source, %s is "%s", not "%s"' % (name, export, carried.get(export), expected))
        # The plane of the source, with pixels set, is drawn by dcm2img over what carries it.
        if drawn(folder / 'source.dcm') == drawn(folder / 'source.dcm', '--no-overlays'):
            failures.append('dcm2img does not draw the overlay plane of the %s source: the check below proves nothing' % name)
        if drawn(folder / 'picture-grey.dcm') != drawn(folder / 'picture-grey.dcm', '--no-overlays'):
            failures.append('over the %s source, dcm2img draws an overlay of the source over the grey picture of the screen' % name)
        # The stored values exported in the source's matrix are drawn as the source is, polarity included.
        if drawn(folder / 'stored.dcm') != drawn(folder / 'source.dcm'):
            failures.append('over the %s source, dcm2img does not draw the exported stored values as it draws the source' % name)
        print('%s source: %s' % (name, '; '.join('%s %s' % (export, carried.get(export)) for export in EXPECTED[name])))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    raise SystemExit(1)
print('PASS: stored values exported over a MONOCHROME1 source are MONOCHROME1, and MONOCHROME2 over another; the display '
      'shutter and the overlay planes of the source stay with an image of its matrix only, and DCMTK draws no overlay '
      'over a picture of the screen')

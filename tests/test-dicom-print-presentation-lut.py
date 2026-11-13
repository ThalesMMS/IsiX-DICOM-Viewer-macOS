#!/usr/bin/env python3
"""A film printed from a radiograph has the polarity of the screen.

The image a DICOM print job sends is a capture of the viewer: 8-bit
MONOCHROME2 pixels as the screen showed them, written by DICOMExport over the
attributes of the source file, twice (the capture, then the page as the
preview left it). A source of a digital radiograph often says how its own
stored values are to be presented: Presentation LUT Shape (2050,0020) INVERSE
beside MONOCHROME1, a Presentation LUT Sequence (2050,0010), a VOI LUT
Sequence or a window. None of that describes the captured pixels, and
dcmpsprt, which lays out the film, reads the shape from the image it is
given: with INVERSE left in the capture it inverted the film.

DICOMExport.swift and DICOMExport+Dataset.swift are compiled here as they are
written, with the IsiXDICOMFile module and the DCMTK adapter they call
(IsiXDCMTKFile, against the DCMTK of the Debug build: exit 2 without it).
dump2dcm of that build writes two synthetic sources, a MONOCHROME1 radiograph
with INVERSE, a window and a VOI LUT Sequence, and one with a Presentation LUT
Sequence. The driver writes the two captures of a print job over each, black
on the left and white on the right, and lists what the capture still carries
of the source's presentation; dcmpsprt of the same build then prepares the
film with the printer configuration of the app, and the hardcopy must be
black on the left and white on the right.

--resources DIR takes dcmpsprt, HorosStoredPrint and dicom.dic from the
Resources folder of an application bundle. With --scp-python PYTHON as well
(an interpreter with pydicom and pynetdicom), the film is also sent to the
loopback print SCP of tools/validate-dicom-print-scp.py, and the image box
the printer received must have the same polarity.
"""
import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dicom_export_harness  # noqa: E402
from dicom_export_harness import INSTALL, ROOT  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('--resources', type=Path,
                    help='Resources folder of an application bundle: its dcmpsprt, HorosStoredPrint and dicom.dic')
parser.add_argument('--scp-python', type=Path,
                    help='an interpreter with pydicom and pynetdicom: also send the film to the loopback print SCP')
args = parser.parse_args()

_, dictionary = dicom_export_harness.requirements('dump2dcm', *([] if args.resources else ['dcmpsprt']))
if args.resources:
    resources = args.resources.resolve()
    tools = {'dcmpsprt': resources / 'dcmpsprt', 'sender': resources / 'HorosStoredPrint', 'dictionary': resources / 'dicom.dic'}
    absent = [path for path in tools.values() if not path.is_file()]
    if absent:
        print('skipped: not in --resources: ' + str(absent[0]))
        raise SystemExit(2)
else:
    tools = {'dcmpsprt': INSTALL / 'bin/dcmpsprt', 'dictionary': dictionary}
if args.scp_python and not args.resources:
    parser.error('--scp-python needs --resources, for HorosStoredPrint')

# The printer configuration the app writes for a job, with a printer of 1 x 1.
controller = (ROOT / 'DICOMPrint/AYDicomPrintWindowController.swift').read_text(encoding='utf-8')
template = re.search(r'^private let DCMTK_PRINTER_CONFIG_TEMPLATE = """\n(.*?)\n"""', controller, re.M | re.S)
assert template, 'the printer configuration literal of the print window is not where it was'


def configuration(port):
    text = template.group(1)
    for key, value in {'PRINTER_AETITLE': 'PRINTQA', 'HOST': '127.0.0.1', 'PORT': str(port), 'HOROS_AETITLE': 'ISIXQA',
                       'COLUMNS': '1', 'ROWS': '1', 'FILM_DESTINATION': 'PROCESSOR', 'FILM_SIZE': '14INX17IN',
                       'MEDIUM_TYPE': 'PAPER', 'MAGNIFICATION_TYPE': 'BILINEAR'}.items():
        text = text.replace('{{' + key + '}}', value)
    assert '{{' not in text, text
    return text


# A digital radiograph as its stored values are: 4 x 4, 12 bits, MONOCHROME1.
HEADER = r'''
(0002,0002) UI =DigitalXRayImageStorageForPresentation
(0002,0003) UI [1.2.826.0.1.3680043.8.498.2050.%(n)d]
(0002,0010) UI =LittleEndianExplicit
(0008,0005) CS [ISO_IR 100]
(0008,0016) UI =DigitalXRayImageStorageForPresentation
(0008,0018) UI [1.2.826.0.1.3680043.8.498.2050.%(n)d]
(0008,0020) DA [20260101]
(0008,0030) TM [120000]
(0008,0050) SH []
(0008,0060) CS [DX]
(0008,0070) LO [SYNTHETIC]
(0008,0090) PN []
(0010,0010) PN [QA^Print]
(0010,0020) LO [LOCAL-PRINT-QA]
(0010,0030) DA []
(0010,0040) CS [O]
(0020,000d) UI [1.2.826.0.1.3680043.8.498.2050.10]
(0020,000e) UI [1.2.826.0.1.3680043.8.498.2050.20]
(0020,0010) SH [1]
(0020,0011) IS [1]
(0020,0013) IS [%(n)d]
(0028,0002) US 1
(0028,0004) CS [MONOCHROME1]
(0028,0010) US 4
(0028,0011) US 4
(0028,0100) US 16
(0028,0101) US 12
(0028,0102) US 11
(0028,0103) US 0
(0028,1040) CS [LOG]
(0028,1041) SS -1
(0028,1052) DS [0]
(0028,1053) DS [1]
(0028,1054) LO [US]
'''
PIXELS = '(7fe0,0010) OW ' + '\\'.join(['0000', '0555', '0aaa', '0fff'] * 4) + '\n'
SOURCES = {
    # What a detector usually writes beside MONOCHROME1.
    'inverse shape': HEADER % {'n': 1} + r'''
(0028,1050) DS [2048]
(0028,1051) DS [4096]
(0028,1056) CS [LINEAR]
(0028,3010) SQ (Sequence with undefined length)
  (fffe,e000) na (Item with undefined length)
    (0028,3002) US 4\0\8
    (0028,3006) US 255\170\85\0
  (fffe,e00d) na (ItemDelimitationItem)
(fffe,e0dd) na (SequenceDelimitationItem)
(2050,0020) CS [INVERSE]
''' + PIXELS,
    # The other form of a Presentation LUT: a table over the stored values.
    'presentation table': HEADER % {'n': 2} + r'''
(2050,0010) SQ (Sequence with undefined length)
  (fffe,e000) na (Item with undefined length)
    (0028,3002) US 4\0\12
    (0028,3006) US 4095\2730\1365\0
  (fffe,e00d) na (ItemDelimitationItem)
(fffe,e0dd) na (SequenceDelimitationItem)
''' + PIXELS,
}

DRIVER = r'''
import Foundation

func fail(_ reason: String) -> Never { print("FAIL: " + reason); exit(1) }

func open(_ path: String) -> IsiXDCMTKFile {
    let file = IsiXDCMTKFile()
    guard (try? file.read(fileAtPath: path)) != nil else { fail("\(path) cannot be read back") }
    file.loadAllDataIntoMemory()
    return file
}

func text(_ file: IsiXDCMTKFile, _ tag: UInt32) -> String {
    file.dataset.string(forTag: tag).map { String(cString: $0).trimmingCharacters(in: .whitespaces) } ?? ""
}

func size(_ file: IsiXDCMTKFile) -> (rows: Int, columns: Int) {
    var rows: UInt16 = 0, columns: UInt16 = 0
    guard file.dataset.getUInt16(&rows, forTag: 0x0028_0010, index: 0),
          file.dataset.getUInt16(&columns, forTag: 0x0028_0011, index: 0) else { fail("no Rows and Columns") }
    return (Int(rows), Int(columns))
}

// What the screen showed: black on the left, grey, white on the right.
let width = 96, height = 64
func shown(_ x: Int) -> UInt8 { x < width / 3 ? 0 : (x < 2 * width / 3 ? 128 : 255) }

let arguments = CommandLine.arguments
switch arguments[1] {
case "capture":
    // capture <source> <folder>: the capture of the viewer over the source,
    // then the page of the preview over that capture, as a print job writes.
    UserDefaults.standard.set(true, forKey: "useDCMTKForDicomExport")
    let screen = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
    for y in 0..<height { for x in 0..<width { screen[y * width + x] = shown(x) } }
    var source = arguments[2]
    for name in ["viewer.dcm", "page.dcm"] {
        let exporter = DICOMExport()
        exporter.setSourceFile(source)
        _ = exporter.setPixelData(screen, samplesPerPixel: 1, bitsPerSample: 8, width: width, height: height)
        let path = arguments[3] + "/" + name
        guard exporter.writeDCMFile(path) != nil, FileManager.default.fileExists(atPath: path) else {
            fail("\(name) was not written over \(source)")
        }
        source = path
    }
    let page = open(source)
    guard text(page, 0x0028_0004) == "MONOCHROME2", size(page) == (height, width),
          let pixels = page.dataset.bytes(forTag: 0x7fe0_0010), pixels.count == width * height,
          pixels.elementsEqual(UnsafeBufferPointer(start: screen, count: width * height)) else {
        fail("the page is not the 8-bit MONOCHROME2 pixels of the screen")
    }
    if text(page, 0x0010_0010) != "QA^Print" { fail("the page lost the patient of its source") }
    // The source's presentation of its own stored values, by tag.
    let presentation: [(UInt32, String)] = [
        (0x2050_0020, "Presentation LUT Shape"), (0x2050_0010, "Presentation LUT Sequence"),
        (0x0028_3010, "VOI LUT Sequence"), (0x0028_1050, "Window Center"), (0x0028_1051, "Window Width"),
        (0x0028_1056, "VOI LUT Function"), (0x0028_3000, "Modality LUT Sequence"),
        (0x0028_1040, "Pixel Intensity Relationship"), (0x0028_1041, "Pixel Intensity Relationship Sign"),
    ]
    for (tag, name) in presentation where page.dataset.hasElement(forTag: tag, length: nil) {
        let value = text(page, tag)
        print("carries: \(name)" + (value.isEmpty ? "" : " = \(value)"))
    }
    screen.deallocate()
case "hardcopy":
    // hardcopy <file>: the film image dcmpsprt prepared, 12 bits in words.
    let film = open(arguments[2])
    let (rows, columns) = size(film)
    guard let data = film.dataset.bytes(forTag: 0x7fe0_0010), data.count == rows * columns * 2 else {
        fail("the hardcopy has no 16-bit pixel data of \(columns) x \(rows)")
    }
    let words = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    func at(_ sixth: Int) -> UInt16 { words[(rows / 2) * columns + columns * sixth / 6] }
    print("hardcopy: \(text(film, 0x0028_0004)) shape=\(text(film, 0x2050_0020)) left=\(at(1)) middle=\(at(3)) right=\(at(5))")
default:
    fail("unknown mode")
}
'''


driver = dicom_export_harness.driver


class PrintSCP:
    """The loopback print SCP of tools/validate-dicom-print-scp.py, listening
    for one job; `received()` stops it and gives what it captured."""

    def __init__(self, python, folder):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        self.folder = folder
        folder.mkdir()
        self.process = subprocess.Popen([str(python), str(ROOT / 'tools/validate-dicom-print-scp.py'), str(tools['dcmpsprt'].parent),
                                         str(folder), '--serve', '--port', str(self.port), '--columns', '1', '--rows', '1'],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        line = self.process.stdout.readline()
        if 'listening' not in line:
            self.process.kill()
            print('FAIL: the print SCP did not start: ' + line + self.process.stdout.read()[-2000:])
            raise SystemExit(1)

    def received(self):
        self.process.send_signal(signal.SIGINT)
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()
        path = self.folder / 'received.json'
        return json.loads(path.read_text()) if path.is_file() else {}


failures = []
with tempfile.TemporaryDirectory(prefix='isix-print-presentation-') as directory:
    work = Path(directory)
    check = dicom_export_harness.build(work, DRIVER)
    environment = dict(os.environ, DCMDICTPATH=str(tools['dictionary']))
    for index, (name, dump) in enumerate(SOURCES.items()):
        job = work / ('job-%d' % index)
        (job / 'database').mkdir(parents=True)
        (job / 'source.dump').write_text(dump)
        made = subprocess.run([str(INSTALL / 'bin/dump2dcm'), str(job / 'source.dump'), str(job / 'source.dcm')],
                              env=dict(os.environ, DCMDICTPATH=str(dictionary)), capture_output=True, text=True, timeout=60)
        if made.returncode:
            print(made.stdout + made.stderr)
            print('FAIL: dump2dcm did not write the synthetic source')
            raise SystemExit(1)
        carried = [line[len('carries: '):] for line in driver(check, 'capture', job / 'source.dcm', job).splitlines()
                   if line.startswith('carries: ')]
        scp = PrintSCP(args.scp_python, job / 'received') if args.scp_python else None
        (job / 'print.cfg').write_text(configuration(scp.port if scp else 1))
        try:
            # The options of the app's print script for one page of 1 x 1.
            layout = subprocess.run([str(tools['dcmpsprt']), '-c', 'print.cfg', '--printer', 'PRINTSCP', '--layout', '1', '1',
                                     '--filmsize', '14INX17IN', '--magnification', 'BILINEAR', '--border', 'BLACK',
                                     '--empty-image', 'BLACK', '--no-trim', '--portrait', 'page.dcm'],
                                    cwd=job, env=environment, capture_output=True, text=True, timeout=60)
            hardcopies = sorted((job / 'database').glob('HG_*'))
            if layout.returncode or len(hardcopies) != 1:
                print(layout.stdout + layout.stderr)
                print('FAIL: dcmpsprt did not prepare one film image for the source with the ' + name)
                raise SystemExit(1)
            film = driver(check, 'hardcopy', hardcopies[0]).strip()
            wire = None
            if scp:
                sent = subprocess.run([str(tools['sender']), '-c', 'print.cfg', '--printer', 'PRINTSCP', '--copies', '1',
                                       '--priority', 'MED', '--destination', 'PROCESSOR', '--medium-type', 'PAPER',
                                       *map(str, sorted((job / 'database').glob('SP_*')))],
                                      cwd=job, env=environment, capture_output=True, text=True, timeout=60)
                wire = scp.received()
                if sent.returncode or len(wire.get('images', [])) != 1 or wire.get('actions') != 1:
                    print(sent.stdout + sent.stderr)
                    print('FAIL: the print SCP did not receive the film of the source with the %s: %s' % (name, wire))
                    raise SystemExit(1)
        finally:
            if scp and scp.process.poll() is None:
                scp.process.kill()
        if carried:
            failures.append('the page written over the source with the %s still carries: %s' % (name, '; '.join(carried)))
        match = re.fullmatch(r'hardcopy: (\S*) shape=(\S*) left=(\d+) middle=(\d+) right=(\d+)', film)
        assert match, film
        photometric, shape, left, middle, right = match.group(1), match.group(2), *map(int, match.groups()[2:])
        # The hardcopy is MONOCHROME2 with no shape of its own: its values are the film's.
        if (photometric, shape) != ('MONOCHROME2', '') or not (left == 0 and left < middle < right == 4095):
            failures.append('the film of the source with the %s is not black, grey, white as the screen was: %s' % (name, film))
        if wire:
            image = wire['images'][0]
            if not (image['top_left'] == 0 and image['bottom_right'] == image['maximum'] > 0 and image['minimum'] == 0):
                failures.append('the image box the printer received for the source with the %s is not black to white: %s'
                                % (name, image))
        print('%s: %s; the page carries %s%s' % (name, film, '; '.join(carried) or 'none of the source\'s presentation',
                                                    '; printer received top left %d, bottom right %d of %d bits'
                                                    % (wire['images'][0]['top_left'], wire['images'][0]['bottom_right'],
                                                       wire['images'][0]['bits']) if wire else ''))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    raise SystemExit(1)
print('PASS: the pages of a print job written over a MONOCHROME1 radiograph with Presentation LUT Shape INVERSE, a window and '
      'a VOI LUT Sequence, and over one with a Presentation LUT Sequence, carry none of them, and dcmpsprt prepares a film '
      'with the polarity of the screen' + ('; the loopback print SCP received it so' if args.scp_python else ''))

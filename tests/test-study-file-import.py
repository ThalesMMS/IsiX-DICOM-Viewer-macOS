#!/usr/bin/env python3
"""Images and PDFs become DICOM objects of an existing study.

Database window > File > Import > Import Images and PDFs into Selected Study…,
the same item of the list's contextual menu and a drop of such files on a
study row convert JPEG, PNG and TIFF files into Secondary Capture images and
PDF files into Encapsulated PDF documents of a new series of that study
(StudyFileImporter). The attributes are IsiXDICOMFile's StudyFileImport; the
objects are written by StudyFileDICOMWriter through the DCMTK file adapter.

StudyFileDICOMWriter.swift is compiled as it is written, with the IsiXDICOMFile
module and the DCMTK adapters of the Debug build (horos_reader.py), into a
driver that converts synthetic files this test writes itself:

- an RGB PNG, an RGB TIFF and a grey PNG, whose pixels must come back
  identical; an RGBA PNG, composited over black; a JPEG made of the RGB PNG by
  sips, within the error of its compression;
- an Encapsulated PDF written by HorosDICOMWriter with the values the
  reports' conversion gives an object without a source file (an empty
  patient name, series 0, a report description), over which the study's
  attributes are set, as StudyFileImporter does after that conversion;
- a file that is not an image, which must be refused.

pydicom then reads every object: the SOP class, UTF-8 text, the patient and
study of the study (a non-ASCII name with its components), one series per
kind with instances numbered from 1, the conversion type, the pixel module and
the pixels against the source, and the PDF bytes.

Usage: python test-study-file-import.py PRODUCTS_DIR PYTHON
       PYTHON has pydicom and numpy
"""
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT
import horos_reader

if len(sys.argv) != 3:
    print('skipped: needs the DCMTK of the Debug build and a Python with pydicom/numpy: PRODUCTS_DIR PYTHON',
          file=sys.stderr)
    raise SystemExit(2)
products, python = Path(sys.argv[1]).resolve(), sys.argv[2]
if horos_reader.missing(products):
    print('skipped: %s: PRODUCTS_DIR PYTHON' % horos_reader.missing(products), file=sys.stderr)
    raise SystemExit(2)

WIDTH, HEIGHT = 7, 5


def rgb_pixels():
    """An asymmetric pattern: a white square in the top left corner tells a flip."""
    rows = []
    for y in range(HEIGHT):
        row = []
        for x in range(WIDTH):
            if x < 2 and y < 2:
                row.append((255, 255, 255))
            else:
                row.append(((x * 37 + y * 11) % 256, (x * 5 + y * 53) % 256, (200 - x * 13 - y * 7) % 256))
        rows.append(row)
    return rows


def png(path, rows, colour_type):
    """A PNG without colour chunks (no profile), 8 bits a sample, filter 0."""
    channels = {0: 1, 2: 3, 6: 4}[colour_type]
    raw = b''.join(b'\0' + bytes(v for pixel in row for v in (pixel if channels > 1 else (pixel,))) for row in rows)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    header = struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, colour_type, 0, 0, 0)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def tiff(path, rows):
    """A baseline uncompressed RGB TIFF, little endian, one strip."""
    data = bytes(v for row in rows for pixel in row for v in pixel)
    entries = [(256, 3, 1, WIDTH), (257, 3, 1, HEIGHT), (258, 3, 3, None), (259, 3, 1, 1), (262, 3, 1, 2),
               (273, 4, 1, None), (277, 3, 1, 3), (278, 3, 1, HEIGHT), (279, 4, 1, len(data)), (284, 3, 1, 1)]
    ifd_offset = 8
    ifd_size = 2 + len(entries) * 12 + 4
    bits_offset = ifd_offset + ifd_size
    data_offset = bits_offset + 6
    ifd = struct.pack('<H', len(entries))
    for tag, kind, count, value in entries:
        if tag == 258:
            value = bits_offset
        elif tag == 273:
            value = data_offset
        ifd += struct.pack('<HHI', tag, kind, count) + (struct.pack('<HH', value, 0) if kind == 3 and count == 1
                                                         else struct.pack('<I', value))
    ifd += struct.pack('<I', 0)
    path.write_bytes(b'II*\0' + struct.pack('<I', ifd_offset) + ifd + struct.pack('<HHH', 8, 8, 8) + data)


PDF = b'%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n'

PROBE = r'''
import Foundation
import IsiXDICOMFile

@_cdecl("StudyImportProbeMain")
public func studyImportProbeMain(_ folderText: UnsafePointer<CChar>) -> Int32 {
    let folder = URL(fileURLWithPath: String(cString: folderText))
    // Loads the DCMTK dictionary beside the executable, as the application does at launch.
    _ = IsiXDCMTKDictionary.valueRepresentation(forTag: 0x0010_0010)
    let study = StudyFileImport.StudyValues([
        .patientName: "Müller^José", .patientID: "PID-738", .patientBirthDate: "19700131", .patientSex: "O",
        .studyInstanceUID: "1.2.826.0.1.3680043.2.1125.77.1", .studyID: "42", .studyDate: "20260926",
        .studyTime: "123456", .accessionNumber: "ACC-1", .studyDescription: "Tórax",
        .referringPhysicianName: "House^Gregory"])
    let numbers = StudyFileImport.newSeriesNumbers(existing: [1, 2, 5002], count: 2)
    let imageSeries = StudyFileImport.Series(uid: IsiXDCMTKFile.generateUID(root: .series), number: numbers[0],
                                             description: StudyFileImport.seriesDescription(of: .image))
    let pdfSeries = StudyFileImport.Series(uid: IsiXDCMTKFile.generateUID(root: .series), number: numbers[1],
                                           description: StudyFileImport.seriesDescription(of: .pdf))
    let created = Date()
    let selection = StudyFileImport.selection(of: ["rgb.png", "rgb.tif", "grey.png", "rgba.png", "rgb.jpg",
                                                   "letter.pdf", "notes.txt"].map { folder.appendingPathComponent($0).path })
    guard selection.refused.map({ ($0 as NSString).lastPathComponent }) == ["notes.txt"], selection.pdfs.count == 1 else {
        print("FAIL: selection \(selection)")
        return 1
    }
    var instance = 1
    for source in selection.images {
        let name = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        let suffix = (source as NSString).pathExtension
        do {
            let pixels = try StudyFileDICOMWriter.pixels(ofImageAt: URL(fileURLWithPath: source))
            let attributes = StudyFileImport.attributes(of: .image, study: study, series: imageSeries, instanceNumber: instance,
                                                        documentTitle: name, created: created)
            try StudyFileDICOMWriter.writeSecondaryCapture(pixels, attributes: attributes,
                                                           to: folder.appendingPathComponent("\(name)-\(suffix).dcm").path)
            print("written \(name)-\(suffix).dcm as instance \(instance)")
            instance += 1
        } catch {
            print("FAIL: \(source): \(error)")
            return 1
        }
    }
    do {
        _ = try StudyFileDICOMWriter.pixels(ofImageAt: folder.appendingPathComponent("notes.txt"))
        print("FAIL: a text file was read as an image")
        return 1
    } catch StudyFileConversionError.unreadableImage {
        print("refused: notes.txt is not an image")
    } catch {
        print("FAIL: notes.txt: \(error)")
        return 1
    }

    // What the reports' conversion writes without a source file.
    let pdfPath = folder.appendingPathComponent("letter.dcm").path
    let report = HorosDICOMWriter()
    var ok = report.setValues([StudyFileImport.encapsulatedPDFStorage], forName: "SOPClassUID")
    for (name, value) in [("PatientsName", ""), ("PatientID", "0"), ("SeriesNumber", "0"), ("StudyID", "1"),
                          ("InstanceNumber", "1"), ("SeriesDescription", "Report PDF"), ("Modality", "OT"),
                          ("ConversionType", "WSD"), ("BurnedInAnnotation", "NO"),
                          ("MIMETypeOfEncapsulatedDocument", "application/pdf"),
                          ("StudyInstanceUID", HorosDICOMWriter.newStudyInstanceUID()),
                          ("SeriesInstanceUID", HorosDICOMWriter.newSeriesInstanceUID()),
                          ("SOPInstanceUID", HorosDICOMWriter.newSOPInstanceUID())] {
        ok = report.setValues([value], forName: name) && ok
    }
    ok = report.setEmptySequenceForName("ConceptNameCodeSequence") && ok
    let pdf = FileManager.default.contents(atPath: selection.pdfs[0]) ?? Data()
    ok = report.setData(pdf, forName: "EncapsulatedDocument", vr: "OB") && ok
    ok = report.write(toFile: pdfPath, transferSyntax: "1.2.840.10008.1.2.1") && ok
    guard ok else {
        print("FAIL: the Encapsulated PDF was not written")
        return 1
    }
    do {
        let attributes = StudyFileImport.attributes(of: .pdf, study: study, series: pdfSeries, instanceNumber: 1,
                                                    documentTitle: StudyFileImport.documentTitle(ofPath: selection.pdfs[0]),
                                                    created: created)
        try StudyFileDICOMWriter.setAttributes(attributes, ofFileAt: pdfPath)
    } catch {
        print("FAIL: letter.dcm: \(error)")
        return 1
    }
    print("written letter.dcm")
    return 0
}
'''

MAIN = r'''
#import <Foundation/Foundation.h>
extern "C" int StudyImportProbeMain(const char *folder);
int main(int argc, char **argv) { @autoreleasepool { return StudyImportProbeMain(argv[1]); } }
'''

CHECK = r'''
import sys
import numpy as np
import pydicom

folder = sys.argv[1]
W, H = %(width)d, %(height)d

def source_rgb():
    rows = []
    for y in range(H):
        for x in range(W):
            if x < 2 and y < 2:
                rows.append((255, 255, 255))
            else:
                rows.append(((x * 37 + y * 11) %% 256, (x * 5 + y * 53) %% 256, (200 - x * 13 - y * 7) %% 256))
    return np.array(rows, dtype=np.uint8).reshape(H, W, 3)

rgb = source_rgb()
grey = rgb[:, :, 1].copy()
alpha = np.fromfunction(lambda y, x: (x * 36 + y * 20) %% 256, (H, W), dtype=int).astype(np.uint8)
failures = []

def expect(condition, message):
    if not condition:
        failures.append(message)

def study_and_series(ds, name, sop_class, modality, series_number):
    expect(ds.SOPClassUID == sop_class, '%%s: SOP class %%s' %% (name, ds.SOPClassUID))
    expect(ds.file_meta.MediaStorageSOPClassUID == sop_class, '%%s: meta SOP class' %% name)
    expect(ds.file_meta.MediaStorageSOPInstanceUID == ds.SOPInstanceUID, '%%s: meta SOP instance' %% name)
    expect(str(ds.file_meta.TransferSyntaxUID) == '1.2.840.10008.1.2.1', '%%s: transfer syntax' %% name)
    expect(ds.SpecificCharacterSet == 'ISO_IR 192', '%%s: character set %%r' %% (name, ds.SpecificCharacterSet))
    expect(str(ds.PatientName) == 'Müller^José', '%%s: patient name %%r' %% (name, str(ds.PatientName)))
    expect(ds.PatientName.family_name == 'Müller' and ds.PatientName.given_name == 'José', '%%s: name components' %% name)
    expect(ds.PatientID == 'PID-738' and ds.PatientBirthDate == '19700131' and ds.PatientSex == 'O', '%%s: patient' %% name)
    expect(ds.StudyInstanceUID == '1.2.826.0.1.3680043.2.1125.77.1', '%%s: study UID %%s' %% (name, ds.StudyInstanceUID))
    expect(ds.StudyID == '42' and ds.StudyDate == '20260926' and ds.StudyTime == '123456', '%%s: study' %% name)
    expect(ds.AccessionNumber == 'ACC-1' and ds.StudyDescription == 'Tórax', '%%s: accession, description' %% name)
    expect(str(ds.ReferringPhysicianName) == 'House^Gregory', '%%s: referring physician' %% name)
    expect(ds.Modality == modality and ds.ConversionType == 'WSD', '%%s: modality %%s, conversion' %% (name, ds.Modality))
    expect(int(ds.SeriesNumber) == series_number, '%%s: series number %%s' %% (name, ds.SeriesNumber))
    expect(len(ds.ContentDate) == 8 and len(ds.ContentTime) >= 6, '%%s: content date and time' %% name)

images = {}
for name in ('grey-png', 'rgb-png', 'rgb-tif', 'rgb-jpg', 'rgba-png'):
    ds = pydicom.dcmread('%%s/%%s.dcm' %% (folder, name))
    images[name] = ds
    study_and_series(ds, name, '1.2.840.10008.5.1.4.1.1.7', 'OT', 3)
    expect(ds.SeriesDescription == 'Imported images', '%%s: series description' %% name)
    expect(list(ds.ImageType) == ['DERIVED', 'SECONDARY'], '%%s: image type' %% name)
    expect(ds.Rows == H and ds.Columns == W, '%%s: %%s x %%s' %% (name, ds.Columns, ds.Rows))
    expect(ds.BitsAllocated == 8 and ds.BitsStored == 8 and ds.HighBit == 7 and ds.PixelRepresentation == 0,
           '%%s: bits' %% name)
    expect(ds.DateOfSecondaryCapture == ds.ContentDate, '%%s: date of secondary capture' %% name)
expect(len({ds.SeriesInstanceUID for ds in images.values()}) == 1, 'the images are in one series')
expect(len({ds.SOPInstanceUID for ds in images.values()}) == 5, 'each image has its own instance UID')
# Finder order of the names: grey.png, rgb.jpg, rgb.png, rgb.tif, rgba.png.
order = {name: int(ds.InstanceNumber) for name, ds in images.items()}
expect(order == {'grey-png': 1, 'rgb-jpg': 2, 'rgb-png': 3, 'rgb-tif': 4, 'rgba-png': 5}, 'instance numbers %%s' %% order)

g = images['grey-png']
expect(g.SamplesPerPixel == 1 and g.PhotometricInterpretation == 'MONOCHROME2', 'grey: pixel module')
expect(np.array_equal(g.pixel_array, grey), 'grey: pixels %%s' %% g.pixel_array.tolist())
for name in ('rgb-png', 'rgb-tif'):
    ds = images[name]
    expect(ds.SamplesPerPixel == 3 and ds.PhotometricInterpretation == 'RGB' and ds.PlanarConfiguration == 0,
           '%%s: pixel module' %% name)
    expect(np.array_equal(ds.pixel_array, rgb), '%%s: pixels differ from the source by up to %%d'
           %% (name, np.abs(ds.pixel_array.astype(int) - rgb).max()))
over_black = np.round(rgb.astype(float) * alpha[:, :, None] / 255.0)
error = np.abs(images['rgba-png'].pixel_array.astype(float) - over_black).max()
expect(error <= 1, 'rgba: composited over black within 1, off by %%s' %% error)
jpeg_error = np.abs(images['rgb-jpg'].pixel_array.astype(int) - rgb)
expect(jpeg_error.mean() <= 16 and images['rgb-jpg'].pixel_array[0, 0].min() >= 200,
       'jpeg: mean error %%.2f, top left %%s' %% (jpeg_error.mean(), images['rgb-jpg'].pixel_array[0, 0]))

p = pydicom.dcmread(folder + '/letter.dcm')
study_and_series(p, 'pdf', '1.2.840.10008.5.1.4.1.1.104.1', 'DOC', 4)
expect(p.SeriesInstanceUID != g.SeriesInstanceUID, 'pdf: a series of its own')
expect(p.SeriesDescription == 'Imported PDF' and p.DocumentTitle == 'letter', 'pdf: description and title')
expect(int(p.InstanceNumber) == 1 and p.MIMETypeOfEncapsulatedDocument == 'application/pdf', 'pdf: instance, MIME type')
pdf = open(folder + '/letter.pdf', 'rb').read()
expect(p.EncapsulatedDocument.rstrip(b'\0') == pdf.rstrip(b'\0'), 'pdf: bytes')
expect(p.BurnedInAnnotation == 'NO' and p.ConceptNameCodeSequence == [], 'pdf: the conversion\'s own attributes stay')

for failure in failures:
    print('FAIL: ' + failure)
if not failures:
    print('PASS: 5 Secondary Captures and 1 Encapsulated PDF carry the study, their series and the source pixels')
sys.exit(1 if failures else 0)
''' % {'width': WIDTH, 'height': HEIGHT}

with tempfile.TemporaryDirectory(prefix='isix-study-file-import-') as work:
    work = Path(work)
    out = work / 'out'
    out.mkdir()
    rows = rgb_pixels()
    png(out / 'rgb.png', rows, 2)
    tiff(out / 'rgb.tif', rows)
    png(out / 'grey.png', [[pixel[1] for pixel in row] for row in rows], 0)
    png(out / 'rgba.png', [[pixel + ((x * 36 + y * 20) % 256,) for x, pixel in enumerate(row)] for y, row in enumerate(rows)], 6)
    subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '100', str(out / 'rgb.png'),
                    '--out', str(out / 'rgb.jpg')], check=True, capture_output=True)
    (out / 'letter.pdf').write_bytes(PDF)
    (out / 'notes.txt').write_text('not an image\n')

    objects = horos_reader.host_objects(products, work)
    modules = work / 'modules'
    (work / 'probe.swift').write_text(PROBE)
    probe = work / 'probe.o'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library',
                    '-module-name', 'StudyImportProbe', '-target', 'arm64-apple-macos15.0', '-wmo', '-c',
                    '-import-objc-header', str(work / 'horos-writer-bridge.h'),
                    '-Xcc', '-I' + str(horos_reader.ADAPTERS), '-Xcc', '-I' + str(ROOT / 'Horos/Sources'),
                    '-Xcc', '-I' + str(modules), '-I', str(modules),
                    str(ROOT / 'Horos/Sources/StudyFileDICOMWriter.swift'), str(work / 'probe.swift'),
                    '-o', str(probe)], check=True)
    (work / 'main.mm').write_text(MAIN)
    driver = work / 'bin/driver'
    driver.parent.mkdir()
    shipped = BUILD.parent.parent.parent / 'Products' / BUILD.name / 'DCMTK/dicom.dic'
    if shipped.is_file():
        shutil.copy(shipped, driver.parent / 'dicom.dic')
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-w', '-mmacosx-version-min=15.0',
                    '-x', 'objective-c++', str(work / 'main.mm'), '-x', 'none', str(probe), *objects,
                    '-framework', 'Foundation', *horos_reader.link_flags(products), '-o', str(driver)], check=True)
    subprocess.run([str(driver), str(out)], check=True)
    result = subprocess.run([python, '-c', CHECK, str(out)])
    sys.exit(result.returncode)

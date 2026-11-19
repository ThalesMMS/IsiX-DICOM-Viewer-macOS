#!/usr/bin/env python3
"""A segment thresholded in a fractional SEG is all there in what is exported.

Segmentation Type and Maximum Fractional Value are one for the object (PS 3.3
C.8.20.2). A document read as FRACTIONAL kept that type when it was exported,
whatever its segments had become: a thresholded segment, a mask of 0 and 1, was
written as fractions of 255, and read back as present by 1/255. What is checked,
with pydicom reading what the codec writes:

- every segment thresholded: the object is BINARY, one bit a voxel, the mask as
  it is;
- a mask beside a fractional segment: the object is FRACTIONAL with the maximum
  of the fractional segment, the mask written as that maximum, all there, and
  the fractions as they were;
- an untouched fractional document: as it was read, with its fractional type.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from python_with import interpreter_or_skip  # noqa: E402

root = Path(__file__).resolve().parents[1]
source = root / 'Horos/Sources/DicomSEG.swift'

MAIN = r'''
import Foundation

func expect(_ ok: Bool, _ message: String) {
    if !ok { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
// 4 x 4, one plane. A: fractions out of 200 with a centre past the threshold. B: other fractions.
let a: [UInt8] = [0, 0, 0, 0,  0, 200, 150, 0,  0, 99, 100, 0,  0, 0, 0, 20]
let b: [UInt8] = [10, 0, 0, 0,  0, 0, 0, 0,  0, 0, 60, 199,  0, 0, 200, 1]
let geometry = DicomSEGGeometry(rows: 4, columns: 4, frames: 1, spacingRow: 1, spacingCol: 1, sliceThickness: 1,
    origin: [0, 0, 0], orientation: [1, 0, 0, 0, 1, 0], frameOfReferenceUID: "1.2.3.4", frameOrigins: [[0, 0, 0]])
let identity = DicomSEGIdentity(sopInstanceUID: "1.2.3.5", seriesInstanceUID: "1.2.3.6", studyInstanceUID: "1.2.3",
    frameOfReferenceUID: "1.2.3.4", sourceSOPInstanceUIDs: ["1.2.3.10"])
func segment(_ number: UInt16, _ label: String, _ values: [UInt8]) -> DicomSEGSegment {
    DicomSEGSegment(number: number, label: label, trackingUID: "1.2.3.7.\(number)", color: (1, 0, 0), visible: true,
        kind: .fractional, algorithm: "AUTOMATIC", provenance: "synthetic", referencedSOPInstanceUIDs: ["1.2.3.10"],
        frames: [Data(values)], maximumFractionalValue: 200)
}
var original = DicomSEGDocument(identity: identity, geometry: geometry, kind: .fractional,
    segments: [segment(1, "A", a), segment(2, "B", b)], diagnoses: [], sourceBytes: nil)
original.fractionalType = "OCCUPANCY"
// Read from an object, as a document a user opens is.
let read = DicomSEGCodec.decode(try DicomSEGCodec.encode(original))
expect(read.diagnoses.isEmpty, "the fractional object is diagnosed \(read.diagnoses)")
expect(read.kind == .fractional && read.fractionalType == "OCCUPANCY", "the type of the object read")
expect(read.segments.map(\.frames) == [[Data(a)], [Data(b)]] && read.segments.allSatisfy { $0.maximumFractionalValue == 200 },
       "the fractions read")

let untouched = DicomSEGStore(document: read)
try untouched.exportDerived().write(to: folder.appendingPathComponent("untouched.dcm"))

let mixed = DicomSEGStore(document: read)
expect(mixed.binarize(segment: 1, threshold: 100) == nil, "threshold A")
expect(mixed.document.segments[0].kind == .binary && mixed.document.segments[1].kind == .fractional, "one mask and one fractional segment")
expect(mixed.document.writtenKind == .fractional && mixed.document.writtenMaximumFractionalValue == 200, "a mixed document is a fractional object")
let mixedBytes = try mixed.exportDerived()
try mixedBytes.write(to: folder.appendingPathComponent("mixed.dcm"))
// Read back by the codec: the mask is all there, out of the object's maximum.
let mixedRead = DicomSEGCodec.decode(mixedBytes)
expect(mixedRead.kind == .fractional && mixedRead.segments[0].maximumFractionalValue == 200, "the mixed object read back")
expect(mixedRead.segments[0].frames == [Data(a.map { $0 >= 100 ? UInt8(200) : 0 })], "the mask is not all there: \(Array(mixedRead.segments[0].frames[0]))")
expect(mixedRead.segments[1].frames == [Data(b)], "the fractions beside the mask changed")
// Undone, the document is the fractional one again.
expect(mixed.undo(), "undo of the threshold")
let undone = DicomSEGCodec.decode(try mixed.exportDerived())
expect(undone.kind == .fractional && undone.segments.map(\.frames) == [[Data(a)], [Data(b)]], "the fractions after the undo")

let all = DicomSEGStore(document: read)
expect(all.binarize(segment: 1, threshold: 100) == nil && all.binarize(segment: 2, threshold: 60) == nil, "threshold both")
expect(all.document.kind == .fractional && all.document.writtenKind == .binary, "a document of masks is a binary object, whatever it was read as")
let allBytes = try all.exportDerived()
try allBytes.write(to: folder.appendingPathComponent("thresholded.dcm"))
let allRead = DicomSEGCodec.decode(allBytes)
expect(allRead.kind == .binary && allRead.segments.allSatisfy { $0.kind == .binary }, "the thresholded object read back")
expect(allRead.segments.map(\.frames) == [[Data(a.map { $0 >= 100 ? UInt8(1) : 0 })], [Data(b.map { $0 >= 60 ? UInt8(1) : 0 })]], "the masks read back")

// Fractions out of another maximum are brought to the object's.
var uneven = read
uneven.segments[1].maximumFractionalValue = 100
uneven.segments[1].frames = [Data(b.map { $0 / 2 })]
expect(uneven.fractionalFrames(of: uneven.segments[1]) == [Data(b.map { ($0 / 2) * 2 })], "fractions of another maximum")
print("PASS: a thresholded segment is written all there, in a binary object or beside fractions")
'''

CHECK = r'''
import sys
from pathlib import Path
import numpy as np
from pydicom import dcmread
out = Path(sys.argv[1])
A = np.array([0, 0, 0, 0, 0, 200, 150, 0, 0, 99, 100, 0, 0, 0, 0, 20], dtype=np.uint8)
B = np.array([10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60, 199, 0, 0, 200, 1], dtype=np.uint8)
def planes(ds):
    order = [int(f.SegmentIdentificationSequence[0].ReferencedSegmentNumber) for f in ds.PerFrameFunctionalGroupsSequence]
    assert order == [1, 2], order
    if ds.BitsAllocated == 1:
        bits = np.unpackbits(np.frombuffer(ds.PixelData, dtype=np.uint8), bitorder='little')[:32]
        return bits[:16], bits[16:]
    values = np.frombuffer(ds.PixelData, dtype=np.uint8)[:32]
    return values[:16], values[16:]

ds = dcmread(out / 'untouched.dcm')
assert ds.SegmentationType == 'FRACTIONAL' and ds.MaximumFractionalValue == 200 and ds.BitsAllocated == 8, 'untouched: type'
assert ds.SegmentationFractionalType == 'OCCUPANCY', 'untouched: the fractional type of the object read is lost'
a, b = planes(ds)
assert (a == A).all() and (b == B).all(), 'untouched: the fractions changed'

ds = dcmread(out / 'mixed.dcm')
assert ds.SegmentationType == 'FRACTIONAL' and ds.BitsAllocated == 8 and ds.BitsStored == 8, 'mixed: %s' % ds.SegmentationType
assert ds.MaximumFractionalValue == 200, 'mixed: maximum %s' % ds.MaximumFractionalValue
assert ds.SegmentationFractionalType == 'OCCUPANCY'
a, b = planes(ds)
presence = a.astype(float) / ds.MaximumFractionalValue
assert (presence == (A >= 100).astype(float)).all(), 'mixed: the thresholded segment is present by %r' % sorted(set(presence.tolist()))
assert (b == B).all(), 'mixed: the fractional segment changed: %r' % b.tolist()

ds = dcmread(out / 'thresholded.dcm')
assert ds.SegmentationType == 'BINARY' and ds.BitsAllocated == 1 and ds.BitsStored == 1 and ds.HighBit == 0, 'thresholded: %s, %d bits' % (ds.SegmentationType, ds.BitsAllocated)
assert 'MaximumFractionalValue' not in ds and 'SegmentationFractionalType' not in ds, 'thresholded: a binary object states fractions'
a, b = planes(ds)
assert (a == (A >= 100)).all() and (b == (B >= 60)).all(), 'thresholded: the masks changed'
print('PASS: another reader finds the mask all there in the binary and in the mixed object, and the fractions as they were')
'''

python = interpreter_or_skip('import pydicom', 'import numpy', need='the independent SEG reader needs')
with tempfile.TemporaryDirectory(prefix='horos-seg-threshold-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(MAIN)
    (path / 'check.py').write_text(CHECK)
    objects = path / 'objects'
    objects.mkdir()
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(source), str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(objects)], check=True)
    subprocess.run([python, str(path / 'check.py'), str(objects)], check=True)

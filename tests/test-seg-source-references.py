#!/usr/bin/env python3
"""Prove frame-level provenance refusal and multiframe round trips in the real SEG codec,
and that the series a segmentation was made from is read and written as PS 3.3 C.12.2 names it.

The second part needs a reader and a writer that are not this codec: objects written with
pydicom are imported, exported again, and the exports read back with pydicom."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402  - ROIInterchange.swift writes IsiXROI's ROIInterchangeDocument
import argparse
import subprocess
import tempfile
from python_with import interpreter_or_skip  # noqa: E402

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', help='run the original-API refusal case against a Git revision')
args = parser.parse_args()
setup = r'''
import Foundation
func expect(_ ok: Bool, _ reason: String) { if !ok { fatalError(reason) } }
let domain = "org.horos.test.seg-source.\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: domain)!
defer { preferences.removePersistentDomain(forName: domain) }
let registry = VolumeSessionRegistry()
let volume = registry.open(identity: VolumeIdentity(studyInstanceUID:"1.2.3",seriesInstanceUID:"1.2.3.8",
    frameOfReferenceUID:"1.2.3.4",timeIndex:0,generation:0)!,owner:"viewer")!
let refs = ["1.2.3.10", "1.2.3.11"]
let geometry = DicomSEGGeometry(rows:2,columns:2,frames:2,spacingRow:1,spacingCol:1,sliceThickness:2,
    origin:[0,0,0],orientation:[1,0,0,0,1,0],frameOfReferenceUID:"1.2.3.4",frameOrigins:[[0,0,0],[0,0,2]])
let identity = DicomSEGIdentity(sopInstanceUID:"1.2.3.5",seriesInstanceUID:"1.2.3.6",studyInstanceUID:"1.2.3",
    frameOfReferenceUID:"1.2.3.4",sourceSOPInstanceUIDs:refs)
let segment = DicomSEGSegment(number:1,label:"Original",trackingUID:"1.2.3.7",color:(1,0,0),visible:true,
    kind:.binary,algorithm:"MANUAL",provenance:"synthetic",referencedSOPInstanceUIDs:refs,
    frames:[Data([1,1,1,1]),Data([1,1,1,1])],maximumFractionalValue:1)
var document = DicomSEGDocument(identity:identity,geometry:geometry,kind:.binary,segments:[segment],diagnoses:[],sourceBytes:nil)
let session = SEGViewerSession(volume:volume,sourceSOPInstanceUIDs:refs,preferences:preferences)
expect(session.load(try DicomSEGCodec.encode(document)) == nil, "valid classic source")
document.segments[0].label = "Wrong source"
document.segments[0].referencedSOPInstanceUIDs[0] = "9.8.7"
expect(session.load(try DicomSEGCodec.encode(document)) != nil, "per-frame foreign SOP accepted despite valid general list")
expect(session.snapshots[0].label == "Original", "refusal replaced current state")
print("PASS: frame provenance is checked independently of the general reference list")
'''
multiframe = r'''
let enhancedCT = "1.2.840.10008.5.1.4.1.1.2.1"
func reference(_ uid: String, _ frames: [Int]) -> DicomSEGSourceReference {
    DicomSEGSourceReference(sopInstanceUID:uid,sopClassUID:enhancedCT,frameNumbers:frames)
}
document.segments = [segment]
document.segments[0].frameReferences = [[reference(refs[0],[]),reference("9.8.7",[])], [reference(refs[1],[])]]
expect(session.load(try DicomSEGCodec.encode(document)) != nil, "second SourceImage item escaped validation")
let uid = "1.2.3.20"
document.identity.sourceSOPInstanceUIDs = [uid]
document.segments[0].referencedSOPInstanceUIDs = [uid,uid]
document.segments[0].frameReferences = [[reference(uid,[1])], [reference(uid,[2])]]
let sourceSeriesUID = "1.2.3.8", segmentationSeriesUID = "1.2.3.6"
let partial = SEGViewerSession(volume:volume,sourceFrames:[1,2].map {
    SEGSourceFrame(sopInstanceUID:uid,frameNumber:$0,frameCount:4)!
},preferences:preferences,origins:[uid: DicomSEGSourceSeries(seriesInstanceUID:sourceSeriesUID,
    instances:[DicomSEGSourceInstance(sopInstanceUID:uid,sopClassUID:enhancedCT)])])
expect(partial.load(try DicomSEGCodec.encode(document)) == nil, "matching multiframe timepoint refused")
partial.rename(1,label:"Derived")
let derived = try partial.exportDerived()
let decoded = DicomSEGCodec.decode(derived)
expect(decoded.segments[0].frameReferences == document.segments[0].frameReferences, "derived SEG lost SOP class/frame numbers")
// The series the sources are of, which the viewer knows and the document did not state, with its
// instances under Referenced Instance Sequence: one item, one instance, and neither list empty.
let generalItems = DicomBinary.sequence(DicomBinary.parse(derived),0x0008,0x1115)
expect(generalItems.count == 1, "the derived SEG names \(generalItems.count) source series")
let general = generalItems[0]
expect(DicomBinary.string(general,0x0020,0x000E) == sourceSeriesUID, "the derived SEG names \(DicomBinary.string(general,0x0020,0x000E)) as its source series")
expect(decoded.identity.seriesInstanceUID != sourceSeriesUID && decoded.identity.seriesInstanceUID != segmentationSeriesUID,
    "the derived SEG is not in a series of its own")
let generalInstances = DicomBinary.sequence(general,0x0008,0x114A)
expect(generalInstances.count == 1 && DicomBinary.string(generalInstances[0],0x0008,0x1155) == uid
    && DicomBinary.string(generalInstances[0],0x0008,0x1150) == enhancedCT, "general reference lost the instance or its Enhanced CT SOP class")
expect(DicomBinary.sequence(general,0x0008,0x1140).isEmpty, "the instances are still under Referenced Image Sequence")
expect(decoded.identity.sourceSeries == [DicomSEGSourceSeries(seriesInstanceUID:sourceSeriesUID,
    instances:[DicomSEGSourceInstance(sopInstanceUID:uid,sopClassUID:enhancedCT)])], "source series not read back: \(decoded.identity.sourceSeries)")
try derived.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("derived-frames.dcm"))
expect(partial.load(derived) == nil, "derived multiframe SEG cannot reopen")
document.segments[0].frameReferences[0] = [reference(uid,[1,3])]
expect(partial.load(try DicomSEGCodec.encode(document)) != nil, "out-of-timepoint frame accepted")
expect(partial.snapshots[0].label == "Derived", "bad frame import changed prior document")
document.segments[0].frameReferences[0] = [reference(uid,[0])]
expect(DicomSEGCodec.decode(try DicomSEGCodec.encode(document)).diagnoses.contains(.invalidSourceReference), "zero DICOM frame accepted")
document.segments[0].frameReferences = [[reference(uid,[])], [reference(uid,[])]]
expect(partial.load(try DicomSEGCodec.encode(document)) != nil, "whole object accepted in partial timepoint")
let complete = SEGViewerSession(volume:volume,sourceFrames:(1...4).map {
    SEGSourceFrame(sopInstanceUID:uid,frameNumber:$0,frameCount:4)!
},preferences:preferences)
expect(complete.load(try DicomSEGCodec.encode(document)) == nil, "whole object refused with every source frame open")
document.segments[0].frameReferences = [[reference(uid,[1,2])], [reference(uid,[3,4])]]
expect(complete.load(try DicomSEGCodec.encode(document)) == nil, "valid frame list refused")
expect(DicomSEGCodec.decode(try complete.exportDerived()).segments[0].frameReferences == document.segments[0].frameReferences,
    "multi-valued frame list changed")
expect(SEGSourceFrame(sopInstanceUID:uid,frameNumber:0,frameCount:4) == nil, "zero-based native ID leaked")
expect(SEGSourceFrame(sopInstanceUID:uid,frameNumber:5,frameCount:4) == nil, "invalid source frame accepted")
print("PASS: all SourceImage items, multiframe timepoint boundaries, whole-object references and derived frame identity")
'''
series = r'''
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
func file(_ name: String) -> Data { try! Data(contentsOf: folder.appendingPathComponent(name)) }
let ct = "1.2.840.10008.5.1.4.1.1.2", mr = "1.2.840.10008.5.1.4.1.1.4"
func instance(_ uid: String, _ sopClass: String) -> DicomSEGSourceInstance { DicomSEGSourceInstance(sopInstanceUID:uid,sopClassUID:sopClass) }
func origins(_ sopClass: String) -> [String: DicomSEGSourceSeries] {
    Dictionary(uniqueKeysWithValues: refs.map { ($0, DicomSEGSourceSeries(seriesInstanceUID:sourceSeriesUID,instances:[instance($0,sopClass)])) })
}
// An object another program wrote: the sources under Referenced Instance Sequence, of a series that
// is not the segmentation's.
let independent = DicomSEGCodec.decode(file("independent.dcm"))
expect(independent.diagnoses.isEmpty, "the independent SEG is diagnosed \(independent.diagnoses)")
expect(independent.identity.seriesInstanceUID == "1.2.3.60", "the segmentation's own series")
expect(independent.identity.sourceSeries == [DicomSEGSourceSeries(seriesInstanceUID:sourceSeriesUID,
    instances:[instance(refs[0],ct),instance(refs[1],ct)])], "Referenced Instance Sequence not read: \(independent.identity.sourceSeries)")
expect(independent.identity.sourceSOPInstanceUIDs == refs, "sources not read: \(independent.identity.sourceSOPInstanceUIDs)")
let other = SEGViewerSession(volume:volume,sourceSOPInstanceUIDs:refs,preferences:preferences)
let refusal = other.load(file("independent.dcm"))
expect(refusal == nil, "a segmentation with Referenced Instance Sequence is refused: \(refusal ?? "")")
try other.exportDerived().write(to: folder.appendingPathComponent("derived-independent.dcm"))

// Sources of two series.
let two = DicomSEGCodec.decode(file("two.dcm"))
expect(two.identity.sourceSeries == [DicomSEGSourceSeries(seriesInstanceUID:sourceSeriesUID,instances:[instance(refs[0],ct)]),
    DicomSEGSourceSeries(seriesInstanceUID:"1.2.3.9",instances:[instance(refs[1],mr)])], "two source series not read: \(two.identity.sourceSeries)")
expect(two.identity.sourceSOPInstanceUIDs == refs, "sources of two series not read")
let both = SEGViewerSession(volume:volume,sourceSOPInstanceUIDs:refs,preferences:preferences)
expect(both.load(file("two.dcm")) == nil, "a segmentation of two source series is refused")
try both.exportDerived().write(to: folder.appendingPathComponent("derived-two.dcm"))

// What this application wrote before: the instances under Referenced Image Sequence, and the
// segmentation's own series for theirs. The sources are kept and no series is taken for theirs.
let legacy = DicomSEGCodec.decode(file("legacy.dcm"))
expect(legacy.diagnoses.isEmpty, "the legacy SEG is diagnosed \(legacy.diagnoses)")
expect(legacy.identity.sourceSOPInstanceUIDs == refs, "legacy sources not read: \(legacy.identity.sourceSOPInstanceUIDs)")
expect(legacy.identity.sourceSeries == [DicomSEGSourceSeries(seriesInstanceUID:"",instances:[instance(refs[0],ct),instance(refs[1],ct)])],
    "the segmentation's own series is taken for the source's: \(legacy.identity.sourceSeries)")
// A viewer that does not know the series of its images: nothing is stated, and the sources are still read back.
let unknowing = SEGViewerSession(volume:volume,sourceSOPInstanceUIDs:refs,preferences:preferences)
expect(unknowing.load(file("legacy.dcm")) == nil, "a legacy SEG is refused")
let unstated = try unknowing.exportDerived()
try unstated.write(to: folder.appendingPathComponent("derived-legacy-unstated.dcm"))
expect(DicomSEGCodec.decode(unstated).identity.sourceSOPInstanceUIDs == refs, "sources lost with no series stated")
expect(unknowing.load(unstated) == nil, "a SEG that states no source series cannot reopen")
// The viewer the application opens knows it, and the export says it.
let knowing = SEGViewerSession(volume:volume,sourceFrames:refs.map { SEGSourceFrame(sopInstanceUID:$0,frameNumber:1,frameCount:1)! },
    preferences:preferences,origins:origins(ct))
expect(knowing.load(file("legacy.dcm")) == nil, "a legacy SEG is refused by a viewer that knows its series")
try knowing.exportDerived().write(to: folder.appendingPathComponent("derived-legacy.dcm"))
print("PASS: source series read from Referenced Instance Sequence and from legacy objects, one or two, and written for another reader")
'''
MAKE = r'''
"""Three binary segmentations of 2 x 2 x 2 written without this application's codec."""
import sys
from pathlib import Path
from pydicom.dataset import Dataset, FileDataset, FileMetaDataset
from pydicom.sequence import Sequence
from pydicom.uid import ExplicitVRLittleEndian
out = Path(sys.argv[1])
SEG, CT, MR = '1.2.840.10008.5.1.4.1.1.66.4', '1.2.840.10008.5.1.4.1.1.2', '1.2.840.10008.5.1.4.1.1.4'
SOURCES = ['1.2.3.10', '1.2.3.11']
def item(**values):
    ds = Dataset()
    for key, value in values.items(): setattr(ds, key, value)
    return ds
def segmentation(name, instance, referenced):
    meta = FileMetaDataset(); meta.MediaStorageSOPClassUID = SEG; meta.MediaStorageSOPInstanceUID = instance
    meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds = FileDataset(name, {}, file_meta=meta, preamble=b'\0' * 128)
    ds.SOPClassUID = SEG; ds.SOPInstanceUID = instance; ds.Modality = 'SEG'
    ds.StudyInstanceUID = '1.2.3'; ds.SeriesInstanceUID = '1.2.3.60'; ds.FrameOfReferenceUID = '1.2.3.4'
    ds.PatientName = 'SEG^SYNTHETIC'; ds.PatientID = 'SEG-2033'
    ds.Rows = 2; ds.Columns = 2; ds.NumberOfFrames = 2; ds.SamplesPerPixel = 1; ds.PhotometricInterpretation = 'MONOCHROME2'
    ds.BitsAllocated = 1; ds.BitsStored = 1; ds.HighBit = 0; ds.PixelRepresentation = 0
    ds.SegmentationType = 'BINARY'
    ds.SegmentSequence = Sequence([item(SegmentNumber=1, SegmentLabel='Independent', SegmentAlgorithmType='MANUAL',
                                        TrackingUID='1.2.3.70')])
    ds.SharedFunctionalGroupsSequence = Sequence([item(
        PixelMeasuresSequence=Sequence([item(PixelSpacing=[1, 1], SliceThickness=2)]),
        PlaneOrientationSequence=Sequence([item(ImageOrientationPatient=[1, 0, 0, 0, 1, 0])]))])
    ds.PerFrameFunctionalGroupsSequence = Sequence([item(
        PlanePositionSequence=Sequence([item(ImagePositionPatient=[0, 0, 2 * k])]),
        SegmentIdentificationSequence=Sequence([item(ReferencedSegmentNumber=1)]),
        DerivationImageSequence=Sequence([item(SourceImageSequence=Sequence([
            item(ReferencedSOPClassUID=referenced[k][2], ReferencedSOPInstanceUID=SOURCES[k])]))]))
        for k in range(2)])
    ds.PixelData = b'\xff'
    return ds
def instances(*numbers): return Sequence([item(ReferencedSOPClassUID=CT if n == 0 else SOURCE_CLASS[n], ReferencedSOPInstanceUID=SOURCES[n]) for n in numbers])
SOURCE_CLASS = [CT, CT]
one = [('1.2.3.8', 0, CT), ('1.2.3.8', 1, CT)]
ds = segmentation('independent', '1.2.3.61', one)
ds.ReferencedSeriesSequence = Sequence([item(SeriesInstanceUID='1.2.3.8', ReferencedInstanceSequence=instances(0, 1))])
ds.save_as(out / 'independent.dcm', enforce_file_format=True)
SOURCE_CLASS = [CT, MR]
ds = segmentation('two', '1.2.3.62', [('1.2.3.8', 0, CT), ('1.2.3.9', 1, MR)])
ds.ReferencedSeriesSequence = Sequence([item(SeriesInstanceUID='1.2.3.8', ReferencedInstanceSequence=instances(0)),
                                        item(SeriesInstanceUID='1.2.3.9', ReferencedInstanceSequence=instances(1))])
ds.save_as(out / 'two.dcm', enforce_file_format=True)
SOURCE_CLASS = [CT, CT]
ds = segmentation('legacy', '1.2.3.63', one)
ds.ReferencedSeriesSequence = Sequence([item(SeriesInstanceUID='1.2.3.60', ReferencedImageSequence=instances(0, 1))])
ds.save_as(out / 'legacy.dcm', enforce_file_format=True)
'''
CHECK = r'''
"""What another reader finds in the segmentations this application exported."""
import sys
from pathlib import Path
from pydicom import dcmread
out = Path(sys.argv[1])
CT, MR, ENHANCED = '1.2.840.10008.5.1.4.1.1.2', '1.2.840.10008.5.1.4.1.1.4', '1.2.840.10008.5.1.4.1.1.2.1'
def referenced(ds):
    return [(str(s.SeriesInstanceUID), [(str(i.ReferencedSOPClassUID), str(i.ReferencedSOPInstanceUID)) for i in s.ReferencedInstanceSequence])
            for s in ds.get('ReferencedSeriesSequence', [])]
def frames(ds):
    return [[(str(i.ReferencedSOPClassUID), str(i.ReferencedSOPInstanceUID), [int(n) for n in i.get('ReferencedFrameNumber', []) or []]
              if not isinstance(i.get('ReferencedFrameNumber'), int) else [int(i.ReferencedFrameNumber)])
             for i in f.DerivationImageSequence[0].SourceImageSequence] for f in ds.PerFrameFunctionalGroupsSequence]
def check(name, series, per_frame):
    ds = dcmread(out / name)
    assert ds.SOPClassUID == '1.2.840.10008.5.1.4.1.1.66.4', name
    own = str(ds.SeriesInstanceUID)
    got = referenced(ds)
    assert got == series, '%s names %r as its sources, expected %r' % (name, got, series)
    assert all(uid and uid != own for uid, _ in got), '%s names its own series %s as a source' % (name, own)
    assert all(instances for _, instances in got), '%s has a source series without instances' % name
    assert all('ReferencedImageSequence' not in s for s in ds.get('ReferencedSeriesSequence', [])), name
    assert frames(ds) == per_frame, '%s frames are made from %r, expected %r' % (name, frames(ds), per_frame)
    tags = [e.tag for e in ds]
    assert tags == sorted(tags), '%s is not written in the order of its tags' % name
    return ds
classic = [[(CT, '1.2.3.10', [])], [(CT, '1.2.3.11', [])]]
ds = check('derived-independent.dcm', [('1.2.3.8', [(CT, '1.2.3.10'), (CT, '1.2.3.11')])], classic)
assert ds.SeriesInstanceUID not in ('1.2.3.60', '1.2.3.8') and ds.SOPInstanceUID != '1.2.3.61', 'the export is not an object of its own'
check('derived-two.dcm', [('1.2.3.8', [(CT, '1.2.3.10')]), ('1.2.3.9', [(MR, '1.2.3.11')])], [[(CT, '1.2.3.10', [])], [(MR, '1.2.3.11', [])]])
check('derived-legacy.dcm', [('1.2.3.8', [(CT, '1.2.3.10'), (CT, '1.2.3.11')])], classic)
check('derived-legacy-unstated.dcm', [], classic)
check('derived-frames.dcm', [('1.2.3.8', [(ENHANCED, '1.2.3.20')])], [[(ENHANCED, '1.2.3.20', [1])], [(ENHANCED, '1.2.3.20', [2])]])
print('PASS: another reader finds the source series, classes, instances and frames in every export')
'''
with tempfile.TemporaryDirectory(prefix='horos-seg-source-') as folder:
    tmp = Path(folder)
    files = []
    for name in ('VolumeSession.swift', 'DicomSEG.swift', 'ROISurfaceAlgorithm.swift',
                 'HorosSEGSurface.swift', 'SEGViewerSession.swift',
                 'ROIInterchange.swift', 'ROIArchiveFormat.swift', 'HorosLegacyROISeg.swift'):
        path = tmp / name
        source = root / 'Horos/Sources' / name
        path.write_bytes(subprocess.check_output(['git','show',f'{args.baseline}:Horos/Sources/{name}'],cwd=root)
                         if args.baseline else source.read_bytes())
        files.append(str(path))
    python = None if args.baseline else interpreter_or_skip('import pydicom', need='the independent SEG reader and writer need')
    (tmp/'main.swift').write_text(setup + ('' if args.baseline else multiframe + series))
    subprocess.run(['xcrun','swiftc',*isix_modules.module_flags('IsiXROI',tmp/'modules'),*files,str(tmp/'main.swift'),'-o',str(tmp/'probe')],check=True)
    objects = tmp/'objects'
    objects.mkdir()
    if python:
        (tmp/'make.py').write_text(MAKE)
        subprocess.run([python,str(tmp/'make.py'),str(objects)],check=True)
    subprocess.run([str(tmp/'probe'),str(objects)],check=True)
    if python:
        (tmp/'check.py').write_text(CHECK)
        subprocess.run([python,str(tmp/'check.py'),str(objects)],check=True)

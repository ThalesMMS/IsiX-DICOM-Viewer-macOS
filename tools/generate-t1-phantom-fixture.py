#!/usr/bin/env python3
"""Synthetic MR T1 phantoms with four known T1 compartments.

Two series of one study, one slice each, in an empty destination:

- ir/: inversion recovery magnitudes |A - B*exp(-TI/T1)|, A = 1000, B = 2000,
  at the inversion times INVERSION_TIMES_MS (InversionTime, 0018,0082), with
  RepetitionTime 10000 ms and FlipAngle 90;
- vfa/: spoiled gradient echo signals M0*sin(a)*(1 - E1)/(1 - cos(a)*E1),
  E1 = exp(-TR/T1), M0 = 20000, at the flip angles FLIP_ANGLES_DEG
  (FlipAngle, 0018,1314) and RepetitionTime (0018,0080) 15 ms.

The four quadrants of each image have the T1 values T1_MS (top left, top right,
bottom left, bottom right). A border BORDER pixels wide is 0, the background a
T1 map leaves at 0 and counts below the signal threshold. Pixels are rounded to
unsigned 16-bit integers. Does not write into the repository.

    python3 tools/generate-t1-phantom-fixture.py <empty dir> [--size 32]
"""
import argparse
import math
import struct
from pathlib import Path

from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, MRImageStorage, generate_uid

T1_MS = (300.0, 700.0, 1200.0, 2000.0)
INVERSION_TIMES_MS = (50.0, 100.0, 200.0, 400.0, 800.0, 1600.0, 3200.0)
IR_REPETITION_TIME_MS = 10000.0
IR_A, IR_B = 1000.0, 2000.0
FLIP_ANGLES_DEG = (2.0, 5.0, 10.0, 15.0, 20.0)
VFA_REPETITION_TIME_MS = 15.0
VFA_M0 = 20000.0
BORDER = 2


def compartment(row, column, size):
    """The T1 of a pixel, or None in the border."""
    if min(row, column) < BORDER or max(row, column) >= size - BORDER:
        return None
    return T1_MS[(0 if row < size // 2 else 2) + (0 if column < size // 2 else 1)]


def inversion_recovery(t1, inversion_time):
    return abs(IR_A - IR_B * math.exp(-inversion_time / t1))


def spoiled_gradient_echo(t1, flip_angle):
    e1 = math.exp(-VFA_REPETITION_TIME_MS / t1)
    radians = math.radians(flip_angle)
    return VFA_M0 * math.sin(radians) * (1 - e1) / (1 - math.cos(radians) * e1)


def frame(size, signal):
    values = []
    for row in range(size):
        for column in range(size):
            t1 = compartment(row, column, size)
            values.append(0 if t1 is None else int(round(signal(t1))))
    return struct.pack('<%dH' % (size * size), *values)


def dataset(study, frame_of_reference, series, number, index, size, description):
    sop = generate_uid()
    item = Dataset()
    item.file_meta = FileMetaDataset()
    item.file_meta.MediaStorageSOPClassUID = MRImageStorage
    item.file_meta.MediaStorageSOPInstanceUID = sop
    item.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    item.file_meta.ImplementationClassUID = generate_uid()
    item.SpecificCharacterSet = 'ISO_IR 100'
    item.SOPClassUID = MRImageStorage
    item.SOPInstanceUID = sop
    item.StudyInstanceUID = study
    item.SeriesInstanceUID = series
    item.PatientName = 'T1^PHANTOM'
    item.PatientID = 'T1-PHANTOM'
    item.PatientBirthDate = '19700101'
    item.PatientSex = 'O'
    item.StudyDate = item.ContentDate = '20261108'
    item.StudyTime = item.ContentTime = '120000'
    item.AccessionNumber = 'T1PHANTOM'
    item.StudyID = '1'
    item.StudyDescription = 'T1 Fit Map Phantom'
    item.SeriesDescription = description
    item.SeriesNumber = number
    item.InstanceNumber = index + 1
    item.Modality = 'MR'
    item.Manufacturer = 'Synthetic fixture'
    item.Rows = item.Columns = size
    item.SamplesPerPixel = 1
    item.PhotometricInterpretation = 'MONOCHROME2'
    item.BitsAllocated = item.BitsStored = 16
    item.HighBit = 15
    item.PixelRepresentation = 0
    item.PixelSpacing = [1.0, 1.0]
    item.SliceThickness = 5.0
    item.ImageOrientationPatient = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    item.ImagePositionPatient = [0.0, 0.0, 0.0]
    item.FrameOfReferenceUID = frame_of_reference
    item.MRAcquisitionType = '2D'
    item.SequenceVariant = 'NONE'
    item.ScanOptions = ''
    return item


def generate(destination, size=32):
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise SystemExit('%s is not empty' % destination)
    study, frame_of_reference = generate_uid(), generate_uid()

    folder = destination / 'ir'
    folder.mkdir()
    series = generate_uid()
    for index, inversion_time in enumerate(INVERSION_TIMES_MS):
        item = dataset(study, frame_of_reference, series, 1, index, size, 'IR T1 phantom')
        item.ScanningSequence = 'IR'
        item.InversionTime = inversion_time
        item.RepetitionTime = IR_REPETITION_TIME_MS
        item.EchoTime = 10.0
        item.FlipAngle = 90.0
        item.PixelData = frame(size, lambda t1: inversion_recovery(t1, inversion_time))
        item.save_as(folder / ('ti-%d.dcm' % (index + 1)), enforce_file_format=True)

    folder = destination / 'vfa'
    folder.mkdir()
    series = generate_uid()
    for index, flip_angle in enumerate(FLIP_ANGLES_DEG):
        item = dataset(study, frame_of_reference, series, 2, index, size, 'VFA SPGR T1 phantom')
        item.ScanningSequence = 'GR'
        item.SequenceVariant = 'SP'
        item.RepetitionTime = VFA_REPETITION_TIME_MS
        item.EchoTime = 2.0
        item.FlipAngle = flip_angle
        item.PixelData = frame(size, lambda t1: spoiled_gradient_echo(t1, flip_angle))
        item.save_as(folder / ('fa-%d.dcm' % (index + 1)), enforce_file_format=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--size', type=int, default=32)
    arguments = parser.parse_args()
    generate(arguments.destination, arguments.size)
    print('Wrote %d inversion recovery and %d flip angle images to %s'
          % (len(INVERSION_TIMES_MS), len(FLIP_ANGLES_DEG), arguments.destination))

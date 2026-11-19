#!/usr/bin/env python3
"""Create synthetic RT Dose grids, objects of the RT Dose Storage class, for the 2D viewer.

Three grids in one study, 16 bits unsigned, each frame a plane of the grid
placed by the Grid Frame Offset Vector (PS 3.3 C.8.8.3.2):

  oblique   5 planes, first at (10, 20, 30), rows along x and columns along z
            (normal -y), distances 0, 6 ... 24; Dose Units GY, scaling 0.001
  absolute  6 transverse planes, first at (0, 0, 50), z coordinates 50, 53 ...
            65; Dose Units GY, scaling 0.0005
  relative  7 transverse planes, first at (4, 5, 6), distances 0, 2 ... 12;
            Dose Units RELATIVE, scaling 0.01

The stored value of row r, column c of frame k is 1000 (k + 1) + 10 r + c, so
the dose of a point, stored value times Dose Grid Scaling, says which plane,
row and column it is. Needs pydicom and numpy. The output directory must be
empty.
"""
import argparse
import uuid
from pathlib import Path

import numpy as np
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.tag import Tag
from pydicom.uid import ExplicitVRLittleEndian

RT_DOSE_STORAGE = '1.2.840.10008.5.1.4.1.1.481.2'
ROWS = COLUMNS = 32

GRIDS = [
    ('oblique', 5, [10, 20, 30], [1, 0, 0, 0, 0, 1], [6.0 * k for k in range(5)], 'GY', 0.001),
    ('absolute', 6, [0, 0, 50], [1, 0, 0, 0, 1, 0], [50 + 3.0 * k for k in range(6)], 'GY', 0.0005),
    ('relative', 7, [4, 5, 6], [1, 0, 0, 0, 1, 0], [2.0 * k for k in range(7)], 'RELATIVE', 0.01),
]


def uid(name):
    return '2.25.' + str(uuid.uuid5(uuid.NAMESPACE_URL, 'isix-rt-dose-fixture-' + name).int)


def stored(frame):
    rows, columns = np.meshgrid(np.arange(ROWS), np.arange(COLUMNS), indexing='ij')
    return (1000 * (frame + 1) + 10 * rows + columns).astype(np.uint16)


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Use an empty output directory')
    for number, (name, count, position, orientation, vector, units, scaling) in enumerate(GRIDS):
        meta = FileMetaDataset()
        meta.MediaStorageSOPClassUID = RT_DOSE_STORAGE
        meta.MediaStorageSOPInstanceUID = uid(name)
        meta.TransferSyntaxUID = ExplicitVRLittleEndian
        ds = FileDataset(str(output / f'{name}.dcm'), {}, file_meta=meta, preamble=b'\0' * 128)
        ds.SOPClassUID = RT_DOSE_STORAGE
        ds.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
        ds.PatientName = 'DOSEGRID^SYNTHETIC'
        ds.PatientID = 'SYN-RTDOSE'
        ds.StudyInstanceUID = uid('study')
        ds.SeriesInstanceUID = uid('series-' + name)
        ds.FrameOfReferenceUID = uid('frame-of-reference')
        ds.Modality = 'RTDOSE'
        ds.StudyDate = '20261116'
        ds.StudyDescription = 'Synthetic dose grids'
        ds.SeriesNumber = number + 1
        ds.SeriesDescription = name
        ds.InstanceNumber = 1
        ds.Rows = ROWS
        ds.Columns = COLUMNS
        ds.SamplesPerPixel = 1
        ds.PhotometricInterpretation = 'MONOCHROME2'
        ds.BitsAllocated = 16
        ds.BitsStored = 16
        ds.HighBit = 15
        ds.PixelRepresentation = 0
        ds.PixelSpacing = [2, 2]
        ds.NumberOfFrames = count
        ds.FrameIncrementPointer = Tag(0x3004, 0x000C)
        ds.GridFrameOffsetVector = vector
        ds.ImagePositionPatient = position
        ds.ImageOrientationPatient = orientation
        ds.DoseUnits = units
        ds.DoseType = 'PHYSICAL'
        ds.DoseSummationType = 'PLAN'
        ds.DoseGridScaling = scaling
        ds.PixelData = np.stack([stored(k) for k in range(count)]).tobytes()
        ds.save_as(output / f'{name}.dcm', enforce_file_format=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path)
    generate(parser.parse_args().output)

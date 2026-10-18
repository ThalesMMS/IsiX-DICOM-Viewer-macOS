#!/usr/bin/env python3
"""Generate a synthetic diffusion MR series that stacks three b-values.

One series of 18 axial images: six slice positions for b = 0, then the same
six for b = 500, then for b = 1000, as some scanners export DWI. Each b-value
is written where a different vendor puts it, so splitting the series reads
all of them:

- b = 0: the standard Diffusion b-value (0018,9087);
- b = 500: Siemens' private (0019,100C), under "SIEMENS MR HEADER";
- b = 1000: only in Siemens' sequence name, "*ep_b1000t".

The images are a disc whose signal falls with the b-value and a small spot
that keeps more of it, so the three b-values look different side by side.

    local-validation/email-venv/bin/python tools/generate-dwi-bvalue-fixture.py <empty folder>
"""
import argparse
from pathlib import Path
import uuid

import numpy as np
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, MRImageStorage

SIZE = 64
POSITIONS = 6
B_VALUES = (0, 500, 1000)


def uid(name):
    return '2.25.' + str(uuid.uuid5(uuid.NAMESPACE_URL, 'urn:horos:dwi-bvalue:' + name).int)


def pixels(b_value, slice_index):
    y, x = np.mgrid[0:SIZE, 0:SIZE]
    disc = (x - SIZE / 2) ** 2 + (y - SIZE / 2) ** 2 < (SIZE * 0.4) ** 2
    spot = (x - SIZE * 0.6) ** 2 + (y - SIZE * (0.4 + 0.03 * slice_index)) ** 2 < (SIZE * 0.08) ** 2
    image = np.zeros((SIZE, SIZE))
    image[disc] = 1000 * np.exp(-b_value * 0.0020)
    image[spot] = 1000 * np.exp(-b_value * 0.0006)
    return image.astype(np.uint16)


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Use an empty output directory')
    instance = 0
    for b_value in B_VALUES:
        for position in range(POSITIONS):
            instance += 1
            meta = FileMetaDataset()
            meta.MediaStorageSOPClassUID = MRImageStorage
            meta.MediaStorageSOPInstanceUID = uid(f'image-{instance}')
            meta.TransferSyntaxUID = ExplicitVRLittleEndian
            ds = FileDataset(str(output / f'{instance:02d}.dcm'), {}, file_meta=meta, preamble=b'\0' * 128)
            ds.SOPClassUID = MRImageStorage
            ds.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
            ds.PatientName = 'QA^Diffusion b-values'
            ds.PatientID = 'LOCAL-DWI-BVALUE'
            ds.StudyInstanceUID = uid('study')
            ds.SeriesInstanceUID = uid('series')
            ds.FrameOfReferenceUID = uid('frame')
            ds.StudyDate = ds.SeriesDate = ds.AcquisitionDate = ds.ContentDate = '20261018'
            ds.StudyTime = ds.SeriesTime = ds.AcquisitionTime = ds.ContentTime = '120000'
            ds.StudyID = 'DWIB'
            ds.StudyDescription = 'Synthetic diffusion b-values'
            ds.SeriesDescription = 'DWI b0 b500 b1000'
            ds.SeriesNumber = 1
            ds.InstanceNumber = instance
            ds.Modality = 'MR'
            ds.ImageType = ['ORIGINAL', 'PRIMARY', 'DIFFUSION', 'NONE']
            ds.ImagePositionPatient = [-SIZE * 2.0, -SIZE * 2.0, 5.0 * position]
            ds.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
            ds.SliceLocation = 5.0 * position
            ds.SliceThickness = 5.0
            ds.PixelSpacing = [4.0, 4.0]
            ds.Rows = ds.Columns = SIZE
            ds.SamplesPerPixel = 1
            ds.PhotometricInterpretation = 'MONOCHROME2'
            ds.BitsAllocated = 16
            ds.BitsStored = 16
            ds.HighBit = 15
            ds.PixelRepresentation = 0
            ds.WindowCenter = 500
            ds.WindowWidth = 1000
            if b_value == 0:
                ds.add_new(0x00189087, 'FD', 0.0)
                ds.SequenceName = 'ep2d_diff'
            elif b_value == 500:
                ds.add_new(0x00190010, 'LO', 'SIEMENS MR HEADER')
                ds.add_new(0x0019100C, 'IS', '500')
                ds.SequenceName = 'ep2d_diff'
            else:
                ds.SequenceName = '*ep_b1000t'
            ds.PixelData = pixels(b_value, position).tobytes()
            ds.save_as(output / f'{instance:02d}.dcm', enforce_file_format=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('output', type=Path)
    generate(parser.parse_args().output)


if __name__ == '__main__':
    main()

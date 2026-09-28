#pragma once

#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmjpls/djrparam.h>
#include "HorosJPEG2000Codec.h"

// Changes the pixel encoding of the dataset in memory through the DCMTK codecs
// the host registers, JPEG 2000 included (HorosJPEG2000Codec). `quality` takes
// the DCM_CompressionQuality values (0 lossless) and chooses the JPEG 2000 and
// JPEG-LS parameters, whose representation parameter classes callers do not
// build; for the other syntaxes `parameters` is passed through. On failure the
// dataset keeps its current representation, and publication and source-file
// ownership stay with the caller.
inline OFCondition HorosChooseDICOMRepresentation(DcmFileFormat& file,
    E_TransferSyntax target, const DcmRepresentationParameter* parameters = NULL, int quality = 0)
{
    DcmDataset* dataset = file.getDataset();
    if (target == EXS_JPEG2000LosslessOnly || target == EXS_JPEG2000)
    {
        HorosJPEG2000RepresentationParameter jpeg2000(target == EXS_JPEG2000LosslessOnly ? 0 : quality);
        return dataset->chooseRepresentation(target, &jpeg2000);
    }
    if (target == EXS_JPEGLSLossless || target == EXS_JPEGLSLossy)
    {
        // The former JPEG parameter class is not a JPEG-LS parameter object.
        DJLSRepresentationParameter jpegLS(Uint16(quality < 0 ? 0 : quality),
            target == EXS_JPEGLSLossless || quality == 0);
        return dataset->chooseRepresentation(target, &jpegLS);
    }
    return dataset->chooseRepresentation(target, parameters);
}

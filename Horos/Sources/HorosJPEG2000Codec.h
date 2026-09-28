#pragma once

// JPEG 2000 codec for DCMTK, on the OpenJPEG the host already builds.
//
// Upstream DCMTK has no JPEG 2000 codec. Registering this one makes
// DcmDataset::chooseRepresentation decode 1.2.840.10008.1.2.4.90/.91 to a
// native syntax and encode native pixel data to either, like the RLE, JPEG and
// JPEG-LS codecs registered next to it. The encoder keeps the parameters the
// DCM Framework used: reversible 5/3 wavelet, no multi-component transform,
// one quality layer whose rate comes from the DCM_CompressionQuality value
// (0 lossless, 1 high, 2 medium, 3 low). It writes a bare J2K codestream, as
// PS3.5 A.4.4 requires; the decoder also reads streams in a JP2 wrapper, which
// the DCM Framework wrote.

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dccodec.h>
#include <dcmtk/dcmdata/dcpixel.h>

class HorosJPEG2000RepresentationParameter : public DcmRepresentationParameter
{
public:
    // `quality` takes the DCM_CompressionQuality values of DCM.h.
    explicit HorosJPEG2000RepresentationParameter(int quality = 0) : quality_(quality < 0 ? 0 : quality) {}
    int quality() const { return quality_; }
    DcmRepresentationParameter* clone() const override { return new HorosJPEG2000RepresentationParameter(*this); }
    const char* className() const override { return "HorosJPEG2000RepresentationParameter"; }
    OFBool operator==(const DcmRepresentationParameter& other) const override;
private:
    int quality_;
};

class HorosJPEG2000Registration
{
public:
    // Idempotent. Register once per process, next to the other DCMTK codecs.
    static void registerCodecs();
    static void cleanup();
};

// OpenJPEG rate for a DCM_CompressionQuality value, 0 meaning lossless.
// Exposed for the tests; the encoder is the only other caller.
int HorosJPEG2000RateForQuality(int quality, Uint16 rows, Uint16 columns);

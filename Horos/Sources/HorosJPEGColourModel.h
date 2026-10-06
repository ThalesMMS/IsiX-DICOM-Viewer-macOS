#pragma once

// The colour model of a lossy JPEG stream whose own markers contradict the
// DICOM Photometric Interpretation (the UseJPEGColorSpace preference).
//
// The JPEG decoders are registered with EDC_photometricInterpretation: the
// Photometric Interpretation decides whether the three components are YCbCr,
// to be converted to RGB, or RGB already. Some devices label a JFIF stream,
// which is YCbCr by definition, as RGB, and the picture then shows with the
// wrong colours. With the preference on, and only for a lossy JPEG stream of
// three components, a JFIF or Adobe marker that says otherwise wins:
//
// - JFIF, or Adobe with transform 1 (YCbCr), under RGB: decoded as YBR_FULL,
//   so converted to RGB;
// - Adobe with transform 0 (RGB) under YBR_*: decoded as RGB, not converted.
//
// Nothing else changes: not lossless JPEG, not one component, and never a
// guess from the component identifiers, which is what turned lossless RGB
// green. The viewer (HorosDCMTKObject) and every transcoding
// (HorosChooseDICOMRepresentation, which the Decompress helper uses too)
// apply this one policy, so the helper writes what the viewer shows.

#include <atomic>
#include <cstddef>
#include <cstring>
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcitem.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcxfer.h>

/// UseJPEGColorSpace for this process. On by default, as the preference; the
/// application follows its user defaults, the helper the settings it reads.
inline std::atomic<bool>& HorosJPEGMarkersDecideColour()
{
    static std::atomic<bool> enabled(true);
    return enabled;
}

enum HorosJPEGMarkedColour { HorosJPEGUnmarked = 0, HorosJPEGMarkedYCbCr, HorosJPEGMarkedRGB };

/// What the markers before the first scan say about a lossy stream of three
/// components; unmarked for anything else, or when they say nothing.
inline HorosJPEGMarkedColour HorosJPEGStreamMarkedColour(const Uint8* data, size_t length)
{
    if (data == NULL || length < 4 || data[0] != 0xFF || data[1] != 0xD8)
        return HorosJPEGUnmarked;
    bool jfif = false, adobe = false, lossy = false;
    int transform = -1, components = 0;
    size_t at = 2;
    while (at + 4 <= length)
    {
        if (data[at] != 0xFF)
            return HorosJPEGUnmarked;
        const Uint8 marker = data[at + 1];
        if (marker == 0xFF) // fill byte
        {
            at++;
            continue;
        }
        if (marker == 0xDA || marker == 0xD9) // start of scan, end of image
            break;
        const size_t segment = (size_t(data[at + 2]) << 8) | data[at + 3];
        if (segment < 2 || at + 2 + segment > length)
            return HorosJPEGUnmarked;
        const Uint8* payload = data + at + 4;
        const size_t size = segment - 2;
        if (marker == 0xE0 && size >= 5 && memcmp(payload, "JFIF\0", 5) == 0)
            jfif = true;
        else if (marker == 0xEE && size >= 12 && memcmp(payload, "Adobe", 5) == 0)
        {
            adobe = true;
            transform = payload[11];
        }
        else if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC)
        {
            // SOF3, SOF7, SOF11 and SOF15 are the lossless processes.
            lossy = marker != 0xC3 && marker != 0xC7 && marker != 0xCB && marker != 0xCF;
            components = size >= 6 ? payload[5] : 0;
        }
        at += 2 + segment;
    }
    if (!lossy || components != 3)
        return HorosJPEGUnmarked;
    // The IJG library's order: JFIF first, then the Adobe transform.
    if (jfif)
        return HorosJPEGMarkedYCbCr;
    if (adobe && transform == 1)
        return HorosJPEGMarkedYCbCr;
    if (adobe && transform == 0)
        return HorosJPEGMarkedRGB;
    return HorosJPEGUnmarked;
}

/// The Photometric Interpretation the JPEG decoder has to be given instead of
/// the dataset's for these fragments, or NULL to decode by the dataset's.
inline const char* HorosJPEGDecodingPhotometric(DcmItem* dataset, E_TransferSyntax syntax, DcmPixelSequence* sequence)
{
    if (!HorosJPEGMarkersDecideColour().load(std::memory_order_relaxed) || dataset == NULL || sequence == NULL)
        return NULL;
    if (syntax < EXS_JPEGProcess1 || syntax > EXS_JPEGProcess14SV1)
        return NULL;
    Uint16 samples = 0;
    OFString stated;
    if (dataset->findAndGetUint16(DCM_SamplesPerPixel, samples).bad() || samples != 3 ||
        dataset->findAndGetOFString(DCM_PhotometricInterpretation, stated).bad())
        return NULL;
    // Item 0 is the offset table; the first frame starts in the next one.
    for (unsigned long i = 1; i < sequence->card(); i++)
    {
        DcmPixelItem* item = NULL;
        Uint8* bytes = NULL;
        if (sequence->getItem(item, i).bad() || item == NULL || item->getUint8Array(bytes).bad() || bytes == NULL ||
            item->getLength() == 0)
            continue;
        switch (HorosJPEGStreamMarkedColour(bytes, item->getLength()))
        {
            case HorosJPEGMarkedYCbCr:
                return stated == "RGB" ? "YBR_FULL" : NULL;
            case HorosJPEGMarkedRGB:
                return stated.compare(0, 4, "YBR_") == 0 ? "RGB" : NULL;
            default:
                return NULL;
        }
    }
    return NULL;
}

/// Gives the dataset the Photometric Interpretation of the stream for the
/// length of a decode, and puts the stated one back unless -keep is called
/// because the decoder has written the one that describes its output.
class HorosJPEGDecodingColour
{
public:
    HorosJPEGDecodingColour(DcmItem* dataset, E_TransferSyntax syntax, DcmPixelSequence* sequence)
        : _dataset(dataset), _active(false)
    {
        const char* decoding = HorosJPEGDecodingPhotometric(dataset, syntax, sequence);
        if (decoding && dataset->findAndGetOFString(DCM_PhotometricInterpretation, _stated).good())
            _active = dataset->putAndInsertString(DCM_PhotometricInterpretation, decoding).good();
    }

    /// For a change of representation: only when the dataset has nothing but
    /// its JPEG pixels, so that DCMTK has to decode them to reach `target`.
    HorosJPEGDecodingColour(DcmItem* dataset, E_TransferSyntax target)
        : _dataset(dataset), _active(false)
    {
        DcmElement* element = NULL;
        if (dataset == NULL || dataset->findAndGetElement(DCM_PixelData, element).bad() || element == NULL ||
            element->ident() != EVR_PixelData)
            return;
        DcmPixelData* pixels = OFstatic_cast(DcmPixelData*, element);
        E_TransferSyntax current = EXS_Unknown;
        const DcmRepresentationParameter* parameter = NULL;
        pixels->getCurrentRepresentationKey(current, parameter);
        DcmPixelSequence* sequence = NULL;
        if (current == target || pixels->hasRepresentation(EXS_LittleEndianExplicit, NULL) ||
            pixels->hasRepresentation(target, NULL) ||
            pixels->getEncapsulatedRepresentation(current, parameter, sequence).bad())
            return;
        const char* decoding = HorosJPEGDecodingPhotometric(dataset, current, sequence);
        if (decoding && dataset->findAndGetOFString(DCM_PhotometricInterpretation, _stated).good())
            _active = dataset->putAndInsertString(DCM_PhotometricInterpretation, decoding).good();
    }

    ~HorosJPEGDecodingColour()
    {
        if (_active)
            _dataset->putAndInsertString(DCM_PhotometricInterpretation, _stated.c_str());
    }

    bool relabelled() const { return _active; }
    void keep() { _active = false; }

private:
    HorosJPEGDecodingColour(const HorosJPEGDecodingColour&);
    HorosJPEGDecodingColour& operator=(const HorosJPEGDecodingColour&);
    DcmItem* _dataset;
    OFString _stated;
    bool _active;
};

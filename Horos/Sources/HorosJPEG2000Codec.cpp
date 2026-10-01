#include "HorosJPEG2000Codec.h"

#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcvrpobw.h>
#include <dcmtk/dcmdata/dcswap.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/ofstd/ofstd.h>
#include <OpenJPEG/openjpeg.h>

#include <cstring>
#include <vector>

OFBool HorosJPEG2000RepresentationParameter::operator==(const DcmRepresentationParameter& other) const
{
    if (strcmp(other.className(), className()) != 0) return OFFalse;
    return static_cast<const HorosJPEG2000RepresentationParameter&>(other).quality_ == quality_;
}

int HorosJPEG2000RateForQuality(int quality, Uint16 rows, Uint16 columns)
{
    // The rates DCMPixelDataAttribute -encodeJPEG2000:quality: passed to
    // OpenJPEG, so a transcoded series keeps the size it had before.
    switch (quality)
    {
        case 1: return 4;
        case 2: return (columns <= 600 || rows <= 600) ? 6 : 8;
        case 3: return 16;
        default: return 0;
    }
}

namespace {

class CodecParameter : public DcmCodecParameter
{
public:
    DcmCodecParameter* clone() const override { return new CodecParameter(*this); }
    const char* className() const override { return "HorosJPEG2000CodecParameter"; }
};

struct ImageInfo
{
    Uint16 rows = 0, columns = 0, samplesPerPixel = 0;
    Uint16 bitsAllocated = 0, bitsStored = 0, highBit = 0;
    Uint16 pixelRepresentation = 0, planarConfiguration = 0;
    Sint32 frames = 1;
    OFBool framesPresent = OFFalse;
    OFString photometric;
};

OFCondition readInfo(DcmItem* dataset, ImageInfo& info)
{
    if (dataset->findAndGetUint16(DCM_Rows, info.rows).bad() ||
        dataset->findAndGetUint16(DCM_Columns, info.columns).bad() ||
        dataset->findAndGetUint16(DCM_SamplesPerPixel, info.samplesPerPixel).bad() ||
        dataset->findAndGetUint16(DCM_BitsAllocated, info.bitsAllocated).bad() ||
        dataset->findAndGetUint16(DCM_BitsStored, info.bitsStored).bad() ||
        dataset->findAndGetUint16(DCM_HighBit, info.highBit).bad())
        return EC_TagNotFound;
    dataset->findAndGetUint16(DCM_PixelRepresentation, info.pixelRepresentation);
    dataset->findAndGetOFString(DCM_PhotometricInterpretation, info.photometric);
    if (info.samplesPerPixel > 1)
        dataset->findAndGetUint16(DCM_PlanarConfiguration, info.planarConfiguration);
    Sint32 frames = 0;
    if (dataset->findAndGetSint32(DCM_NumberOfFrames, frames).good())
    {
        info.framesPresent = OFTrue;
        info.frames = frames;
    }
    if (info.frames < 1) info.frames = 1;
    if (info.rows < 1 || info.columns < 1) return EC_InvalidValue;
    if (info.samplesPerPixel != 1 && info.samplesPerPixel != 3) return EC_CannotChangeRepresentation;
    return EC_Normal;
}

DcmItem* pixelDataParent(const DcmStack& objStack)
{
    DcmStack stack(objStack);
    stack.pop(); // the pixel data element
    DcmObject* parent = stack.pop();
    if (!parent || (parent->ident() != EVR_dataset && parent->ident() != EVR_item)) return NULL;
    return static_cast<DcmItem*>(parent);
}

// Photometric interpretation of the decoded pixels. OpenJPEG undoes the
// multi-component transform that YBR_RCT and YBR_ICT announce.
OFString decodedPhotometric(const OFString& photometric)
{
    if (photometric == "YBR_RCT" || photometric == "YBR_ICT") return "RGB";
    return photometric;
}

// ---- OpenJPEG memory streams ------------------------------------------------

struct MemoryStream
{
    const Uint8* input = NULL;
    Uint64 size = 0;
    Uint64 offset = 0;
    std::vector<Uint8>* output = NULL;
};

OPJ_SIZE_T readMemory(void* buffer, OPJ_SIZE_T count, void* user)
{
    MemoryStream* stream = static_cast<MemoryStream*>(user);
    if (stream->offset >= stream->size) return (OPJ_SIZE_T)-1;
    Uint64 available = stream->size - stream->offset;
    if (count > available) count = (OPJ_SIZE_T)available;
    memcpy(buffer, stream->input + stream->offset, count);
    stream->offset += count;
    return count;
}

OPJ_SIZE_T writeMemory(void* buffer, OPJ_SIZE_T count, void* user)
{
    MemoryStream* stream = static_cast<MemoryStream*>(user);
    if (stream->output->size() < stream->offset + count) stream->output->resize(stream->offset + count);
    memcpy(stream->output->data() + stream->offset, buffer, count);
    stream->offset += count;
    return count;
}

OPJ_OFF_T skipMemory(OPJ_OFF_T count, void* user)
{
    MemoryStream* stream = static_cast<MemoryStream*>(user);
    if (stream->output)
    {
        if (count < 0 && Uint64(-count) > stream->offset) count = -OPJ_OFF_T(stream->offset);
        stream->offset += count;
        if (stream->output->size() < stream->offset) stream->output->resize(stream->offset);
        return count;
    }
    if (count < 0)
    {
        if (Uint64(-count) > stream->offset) count = -OPJ_OFF_T(stream->offset);
    }
    else if (stream->offset + Uint64(count) > stream->size)
        count = OPJ_OFF_T(stream->size - stream->offset);
    stream->offset += count;
    return count;
}

OPJ_BOOL seekMemory(OPJ_OFF_T position, void* user)
{
    MemoryStream* stream = static_cast<MemoryStream*>(user);
    if (position < 0) return OPJ_FALSE;
    if (stream->output)
    {
        if (stream->output->size() < Uint64(position)) stream->output->resize(position);
    }
    else if (Uint64(position) > stream->size)
        return OPJ_FALSE;
    stream->offset = position;
    return OPJ_TRUE;
}

opj_stream_t* createStream(MemoryStream* memory)
{
    const OPJ_BOOL input = memory->output ? OPJ_FALSE : OPJ_TRUE;
    opj_stream_t* stream = opj_stream_create(OPJ_J2K_STREAM_CHUNK_SIZE, input);
    if (!stream) return NULL;
    if (input)
    {
        opj_stream_set_read_function(stream, readMemory);
        opj_stream_set_user_data_length(stream, memory->size);
    }
    else
        opj_stream_set_write_function(stream, writeMemory);
    opj_stream_set_skip_function(stream, skipMemory);
    opj_stream_set_seek_function(stream, seekMemory);
    opj_stream_set_user_data(stream, memory, NULL);
    return stream;
}

void ignoreMessage(const char*, void*) {}
void warnError(const char* message, void*) { DCMDATA_WARN("OpenJPEG: " << message); }

struct OpenJPEGSession
{
    opj_codec_t* codec = NULL;
    opj_stream_t* stream = NULL;
    opj_image_t* image = NULL;
    ~OpenJPEGSession()
    {
        if (stream) opj_stream_destroy(stream);
        if (codec) opj_destroy_codec(codec);
        if (image) opj_image_destroy(image);
    }
    void quiet()
    {
        opj_set_info_handler(codec, ignoreMessage, NULL);
        opj_set_warning_handler(codec, ignoreMessage, NULL);
        opj_set_error_handler(codec, warnError, NULL);
    }
};

const Uint8 JP2Signature[12] = {0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A};

OFBool startsCodestream(const Uint8* data, Uint32 length)
{
    if (length >= 4 && data[0] == 0xFF && data[1] == 0x4F && data[2] == 0xFF && data[3] == 0x51) return OFTrue;
    return length >= sizeof(JP2Signature) && memcmp(data, JP2Signature, sizeof(JP2Signature)) == 0;
}

// ---- Decoding -----------------------------------------------------------------

Uint16 bytesPerDecodedSample(Uint16 bitsAllocated, Uint16 bitsStored)
{
    if (bitsStored < 1 || bitsStored > 16 || bitsStored > bitsAllocated) return 0;
    return (bitsAllocated <= 8) ? 1 : 2;
}

Sint32 framesInSequence(const ImageInfo& info, DcmPixelSequence* sequence)
{
    Sint32 frames = info.frames;
    // The first item is the offset table. More frames than fragments is garbage.
    if (frames >= Sint32(sequence->card())) frames = Sint32(sequence->card()) - 1;
    return frames < 1 ? 1 : frames;
}

// Fragments that hold frame `frame`, starting at item `first`: the rest of the
// sequence for the last frame, one when there is one per frame, then the basic
// offset table, then the next item that opens a codestream.
Uint32 fragmentsForFrame(Sint32 frames, Uint32 frame, Uint32 first, DcmPixelSequence* sequence)
{
    const unsigned long items = sequence->card();
    if (first >= items) return 0;
    if (frames <= 1 || frame + 1 == Uint32(frames)) return Uint32(items - first);
    if (Uint32(frames) + 1 == items) return 1;

    DcmPixelItem* item = NULL;
    Uint8* bytes = NULL;
    if (sequence->getItem(item, 0).good() && item && item->getLength() == Uint32(frames) * 4 &&
        item->getUint8Array(bytes).good() && bytes)
    {
        Uint32 next = 0;
        memcpy(&next, bytes + 4 * (frame + 1), 4);
        swapIfNecessary(gLocalByteOrder, EBO_LittleEndian, &next, 4, 4);
        Uint32 counted = 0;
        for (Uint32 index = 1; index < items && counted < next; ++index)
        {
            if (sequence->getItem(item, index).bad() || !item) break;
            counted += item->getLength() + 8;
            if (counted == next && index + 1 > first) return index + 1 - first;
        }
    }
    for (Uint32 index = first + 1; index < items; ++index)
    {
        if (sequence->getItem(item, index).bad() || !item) break;
        bytes = NULL;
        if (item->getUint8Array(bytes).good() && bytes && startsCodestream(bytes, item->getLength()))
            return index - first;
    }
    return 0;
}

// Decodes one codestream into `output`: interleaved samples, one or two bytes
// each in host order, exactly rows x columns x samples.
OFCondition decodeCodestream(const Uint8* data, Uint32 length, const ImageInfo& info,
                             Uint16 bytesPerSample, Uint8* output, Uint64 outputSize)
{
    OPJ_CODEC_FORMAT format;
    if (length >= sizeof(JP2Signature) && memcmp(data, JP2Signature, sizeof(JP2Signature)) == 0)
        format = OPJ_CODEC_JP2;
    else if (length >= 2 && data[0] == 0xFF && data[1] == 0x4F)
        format = OPJ_CODEC_J2K;
    else
        return EC_CannotChangeRepresentation;

    const Uint64 samples = Uint64(info.rows) * info.columns;
    if (samples * info.samplesPerPixel * bytesPerSample > outputSize) return EC_CannotChangeRepresentation;

    MemoryStream memory;
    memory.input = data;
    memory.size = length;
    OpenJPEGSession session;
    opj_dparameters_t parameters;
    opj_set_default_decoder_parameters(&parameters);
    session.codec = opj_create_decompress(format);
    if (!session.codec) return EC_MemoryExhausted;
    session.quiet();
    session.stream = createStream(&memory);
    if (!session.stream) return EC_MemoryExhausted;
    if (!opj_setup_decoder(session.codec, &parameters) ||
        !opj_read_header(session.stream, session.codec, &session.image) ||
        !opj_decode(session.codec, session.stream, session.image) ||
        !opj_end_decompress(session.codec, session.stream))
        return EC_CannotChangeRepresentation;

    opj_image_t* image = session.image;
    if (image->numcomps < info.samplesPerPixel) return EC_CannotChangeRepresentation;
    for (Uint16 component = 0; component < info.samplesPerPixel; ++component)
    {
        const opj_image_comp_t& plane = image->comps[component];
        if (plane.w != info.columns || plane.h != info.rows || !plane.data || plane.prec > 16)
            return EC_CannotChangeRepresentation;
    }
    const Uint16 spp = info.samplesPerPixel;
    if (bytesPerSample == 1)
    {
        for (Uint16 component = 0; component < spp; ++component)
        {
            const OPJ_INT32* source = image->comps[component].data;
            Uint8* target = output + component;
            for (Uint64 i = 0; i < samples; ++i, target += spp) *target = Uint8(source[i]);
        }
    }
    else
    {
        Uint16* words = reinterpret_cast<Uint16*>(output);
        for (Uint16 component = 0; component < spp; ++component)
        {
            const OPJ_INT32* source = image->comps[component].data;
            Uint16* target = words + component;
            for (Uint64 i = 0; i < samples; ++i, target += spp) *target = Uint16(source[i]);
        }
    }
    return EC_Normal;
}

OFCondition decodeFrameAt(DcmPixelSequence* sequence, const ImageInfo& info, Sint32 frames, Uint32 frame,
                          Uint32& item, Uint16 bytesPerSample, Uint8* output, Uint64 outputSize)
{
    const Uint32 count = fragmentsForFrame(frames, frame, item, sequence);
    if (count == 0) return EC_CannotChangeRepresentation;
    DcmPixelItem* fragment = NULL;
    Uint8* bytes = NULL;
    OFCondition result;
    if (count == 1)
    {
        result = sequence->getItem(fragment, item);
        if (result.good() && fragment) result = fragment->getUint8Array(bytes);
        if (result.bad() || !bytes) return result.bad() ? result : EC_CannotChangeRepresentation;
        result = decodeCodestream(bytes, fragment->getLength(), info, bytesPerSample, output, outputSize);
        item += 1;
        return result;
    }
    std::vector<Uint8> joined;
    for (Uint32 index = 0; index < count; ++index)
    {
        result = sequence->getItem(fragment, item + index);
        if (result.good() && fragment) result = fragment->getUint8Array(bytes);
        if (result.bad()) return result;
        if (bytes) joined.insert(joined.end(), bytes, bytes + fragment->getLength());
    }
    item += count;
    if (joined.empty() || joined.size() > 0xFFFFFFFFu) return EC_CannotChangeRepresentation;
    return decodeCodestream(joined.data(), Uint32(joined.size()), info, bytesPerSample, output, outputSize);
}

class Decoder : public DcmCodec
{
public:
    explicit Decoder(E_TransferSyntax syntax) : syntax_(syntax) {}

    OFCondition decode(const DcmRepresentationParameter*, DcmPixelSequence* sequence,
                       DcmPolymorphOBOW& uncompressed, const DcmCodecParameter*,
                       const DcmStack& objStack, OFBool& removeOldRep) const override
    {
        removeOldRep = OFTrue;
        DcmItem* dataset = pixelDataParent(objStack);
        if (!dataset || !sequence) return EC_InvalidTag;
        ImageInfo info;
        OFCondition result = readInfo(dataset, info);
        if (result.bad()) return result;
        const Uint16 bytesPerSample = bytesPerDecodedSample(info.bitsAllocated, info.bitsStored);
        if (!bytesPerSample) return EC_CannotChangeRepresentation;
        const Sint32 frames = framesInSequence(info, sequence);
        const Uint64 frameSize = Uint64(bytesPerSample) * info.rows * info.columns * info.samplesPerPixel;
        Uint64 totalSize = frameSize * frames;
        if (totalSize & 1) totalSize++;
        if (totalSize >= 0xFFFFFFFFu) return EC_ElemLengthExceeds32BitField;

        Uint16* words = NULL;
        result = uncompressed.createUint16Array(Uint32(totalSize / 2), words);
        if (result.bad()) return result;
        Uint8* output = reinterpret_cast<Uint8*>(words);
        Uint32 item = 1;
        for (Sint32 frame = 0; frame < frames && result.good(); ++frame)
            result = decodeFrameAt(sequence, info, frames, Uint32(frame), item, bytesPerSample,
                                   output + frameSize * frame, totalSize - frameSize * frame);
        if (result.bad()) return result;
        if (bytesPerSample == 1)
            result = swapIfNecessary(gLocalByteOrder, EBO_LittleEndian, words, Uint32(totalSize), sizeof(Uint16));
        if (result.good() && (info.framesPresent || frames > 1))
        {
            char text[20];
            OFStandard::snprintf(text, sizeof(text), "%ld", long(frames));
            result = dataset->putAndInsertString(DCM_NumberOfFrames, text);
        }
        if (result.good() && info.samplesPerPixel == 3)
            result = dataset->putAndInsertUint16(DCM_PlanarConfiguration, 0);
        const OFString photometric = decodedPhotometric(info.photometric);
        if (result.good() && photometric != info.photometric)
            result = dataset->putAndInsertString(DCM_PhotometricInterpretation, photometric.c_str());
        return result;
    }

    OFCondition decodeFrame(const DcmRepresentationParameter*, DcmPixelSequence* sequence,
                            const DcmCodecParameter*, DcmItem* dataset, Uint32 frameNo,
                            Uint32& startFragment, void* buffer, Uint32 bufSize,
                            OFString& decompressedColorModel) const override
    {
        if (!dataset || !sequence || !buffer) return EC_IllegalCall;
        ImageInfo info;
        OFCondition result = readInfo(dataset, info);
        if (result.bad()) return result;
        const Uint16 bytesPerSample = bytesPerDecodedSample(info.bitsAllocated, info.bitsStored);
        if (!bytesPerSample) return EC_CannotChangeRepresentation;
        const Sint32 frames = framesInSequence(info, sequence);
        if (frameNo >= Uint32(frames)) return EC_IllegalCall;
        if (startFragment == 0) result = determineStartFragment(frameNo, frames, sequence, startFragment);
        if (result.good())
            result = decodeFrameAt(sequence, info, frames, frameNo, startFragment, bytesPerSample,
                                   static_cast<Uint8*>(buffer), bufSize);
        if (result.good() && bytesPerSample == 1)
            result = swapIfNecessary(gLocalByteOrder, EBO_LittleEndian, buffer, bufSize & ~Uint32(1), sizeof(Uint16));
        if (result.good()) decompressedColorModel = decodedPhotometric(info.photometric);
        return result;
    }

    OFCondition encode(const Uint16*, const Uint32, const DcmRepresentationParameter*, DcmPixelSequence*&,
                       const DcmCodecParameter*, DcmStack&, OFBool&) const override { return EC_IllegalCall; }
    OFCondition encode(const E_TransferSyntax, const DcmRepresentationParameter*, DcmPixelSequence*,
                       const DcmRepresentationParameter*, DcmPixelSequence*&, const DcmCodecParameter*,
                       DcmStack&, OFBool&) const override { return EC_IllegalCall; }

    OFBool canChangeCoding(const E_TransferSyntax oldRepType, const E_TransferSyntax newRepType) const override
    {
        return oldRepType == syntax_ && DcmXfer(newRepType).usesNativeFormat();
    }

    Uint16 decodedBitsAllocated(Uint16 bitsAllocated, Uint16 bitsStored) const override
    {
        return Uint16(bytesPerDecodedSample(bitsAllocated, bitsStored) * 8);
    }

    OFCondition determineDecompressedColorModel(const DcmRepresentationParameter*, DcmPixelSequence*,
                                                const DcmCodecParameter*, DcmItem* dataset,
                                                OFString& decompressedColorModel) const override
    {
        if (!dataset) return EC_IllegalCall;
        OFString photometric;
        OFCondition result = dataset->findAndGetOFString(DCM_PhotometricInterpretation, photometric);
        if (result.good()) decompressedColorModel = decodedPhotometric(photometric);
        return result;
    }

private:
    E_TransferSyntax syntax_;
};

// ---- Encoding -----------------------------------------------------------------

class Encoder : public DcmCodec
{
public:
    explicit Encoder(E_TransferSyntax syntax) : syntax_(syntax) {}

    OFCondition encode(const Uint16* pixelData, const Uint32 length, const DcmRepresentationParameter* toRepParam,
                       DcmPixelSequence*& pixSeq, const DcmCodecParameter*, DcmStack& objStack,
                       OFBool& removeOldRep) const override
    {
        removeOldRep = OFTrue;
        DcmItem* dataset = pixelDataParent(objStack);
        if (!dataset || !pixelData) return EC_InvalidTag;
        ImageInfo info;
        OFCondition result = readInfo(dataset, info);
        if (result.bad()) return result;
        if ((info.bitsAllocated != 8 && info.bitsAllocated != 16) || info.bitsStored < 1 ||
            info.bitsStored > info.bitsAllocated || info.highBit + 1 != info.bitsStored ||
            info.photometric.compare(0, 12, "YBR_FULL_422") == 0 || info.photometric.compare(0, 11, "YBR_PARTIAL") == 0)
            return EC_CannotChangeRepresentation;

        const Uint16 bytesPerSample = info.bitsAllocated / 8;
        const Uint64 samples = Uint64(info.rows) * info.columns;
        const Uint64 frameSize = samples * info.samplesPerPixel * bytesPerSample;
        if (frameSize * info.frames > length) return EC_CannotChangeRepresentation;

        int quality = 0;
        if (toRepParam && strcmp(toRepParam->className(), "HorosJPEG2000RepresentationParameter") == 0)
            quality = static_cast<const HorosJPEG2000RepresentationParameter*>(toRepParam)->quality();
        if (syntax_ == EXS_JPEG2000LosslessOnly) quality = 0;
        const int rate = HorosJPEG2000RateForQuality(quality, info.rows, info.columns);

        // OW pixel data is in host order; 8-bit samples are bytes in file order.
        const Uint8* bytes = reinterpret_cast<const Uint8*>(pixelData);
        std::vector<Uint8> swapped;
        if (bytesPerSample == 1 && gLocalByteOrder == EBO_BigEndian)
        {
            swapped.assign(bytes, bytes + (length & ~Uint32(1)));
            swapIfNecessary(EBO_LittleEndian, gLocalByteOrder, swapped.data(), Uint32(swapped.size()), sizeof(Uint16));
            bytes = swapped.data();
        }

        DcmPixelSequence* sequence = new DcmPixelSequence(DCM_PixelSequenceTag);
        DcmPixelItem* offsetTable = new DcmPixelItem(DCM_PixelItemTag);
        sequence->insert(offsetTable);
        DcmOffsetList offsets;
        Uint64 compressedSize = 0;
        std::vector<Uint8> codestream;
        for (Sint32 frame = 0; frame < info.frames && result.good(); ++frame)
        {
            codestream.clear();
            result = encodeFrame(bytes + frameSize * frame, info, rate, codestream);
            if (result.good())
            {
                if (codestream.size() & 1) codestream.push_back(0);
                if (codestream.size() > 0xFFFFFFF0u) result = EC_ElemLengthExceeds32BitField;
            }
            if (result.good())
            {
                result = sequence->storeCompressedFrame(offsets, codestream.data(), Uint32(codestream.size()), 0);
                compressedSize += codestream.size();
            }
        }
        if (result.good()) result = offsetTable->createOffsetTable(offsets);
        if (result.bad())
        {
            delete sequence;
            pixSeq = NULL;
            return result;
        }
        pixSeq = sequence;

        if (info.samplesPerPixel == 3) result = dataset->putAndInsertUint16(DCM_PlanarConfiguration, 0);
        if (result.good() && rate > 0 && compressedSize)
            result = recordLossyCompression(dataset, double(frameSize * info.frames) / double(compressedSize));
        return result;
    }

    OFCondition encode(const E_TransferSyntax, const DcmRepresentationParameter*, DcmPixelSequence*,
                       const DcmRepresentationParameter*, DcmPixelSequence*&, const DcmCodecParameter*,
                       DcmStack&, OFBool&) const override { return EC_IllegalCall; }
    OFCondition decode(const DcmRepresentationParameter*, DcmPixelSequence*, DcmPolymorphOBOW&,
                       const DcmCodecParameter*, const DcmStack&, OFBool&) const override { return EC_IllegalCall; }
    OFCondition decodeFrame(const DcmRepresentationParameter*, DcmPixelSequence*, const DcmCodecParameter*,
                            DcmItem*, Uint32, Uint32&, void*, Uint32, OFString&) const override { return EC_IllegalCall; }

    OFBool canChangeCoding(const E_TransferSyntax oldRepType, const E_TransferSyntax newRepType) const override
    {
        return newRepType == syntax_ && DcmXfer(oldRepType).usesNativeFormat();
    }

    Uint16 decodedBitsAllocated(Uint16, Uint16) const override { return 0; }

    OFCondition determineDecompressedColorModel(const DcmRepresentationParameter*, DcmPixelSequence*,
                                                const DcmCodecParameter*, DcmItem*, OFString&) const override
    {
        return EC_IllegalCall;
    }

private:
    static OFCondition encodeFrame(const Uint8* frame, const ImageInfo& info, int rate, std::vector<Uint8>& output)
    {
        const Uint16 spp = info.samplesPerPixel;
        const OFBool isSigned = info.pixelRepresentation == 1;
        opj_image_cmptparm_t planes[3];
        memset(planes, 0, sizeof(planes));
        for (Uint16 component = 0; component < spp; ++component)
        {
            planes[component].dx = planes[component].dy = 1;
            planes[component].w = info.columns;
            planes[component].h = info.rows;
            planes[component].prec = info.bitsStored;
            planes[component].sgnd = isSigned ? 1 : 0;
        }
        OpenJPEGSession session;
        const OPJ_COLOR_SPACE space = spp == 1 ? OPJ_CLRSPC_GRAY
            : (info.photometric.compare(0, 3, "YBR") == 0 ? OPJ_CLRSPC_SYCC : OPJ_CLRSPC_SRGB);
        session.image = opj_image_create(spp, planes, space);
        if (!session.image) return EC_MemoryExhausted;
        session.image->x0 = session.image->y0 = 0;
        session.image->x1 = info.columns;
        session.image->y1 = info.rows;

        const Uint64 samples = Uint64(info.rows) * info.columns;
        const OPJ_INT32 mask = OPJ_INT32((1u << info.bitsStored) - 1);
        const OPJ_INT32 signBit = OPJ_INT32(1u << (info.bitsStored - 1));
        const Uint16* words = reinterpret_cast<const Uint16*>(frame);
        for (Uint16 component = 0; component < spp; ++component)
        {
            OPJ_INT32* target = session.image->comps[component].data;
            for (Uint64 i = 0; i < samples; ++i)
            {
                const Uint64 index = info.planarConfiguration == 1 ? component * samples + i : i * spp + component;
                OPJ_INT32 value = OPJ_INT32(info.bitsAllocated == 8 ? frame[index] : words[index]) & mask;
                if (isSigned && (value & signBit)) value -= OPJ_INT32(1u << info.bitsStored);
                target[i] = value;
            }
        }

        opj_cparameters_t parameters;
        opj_set_default_encoder_parameters(&parameters);
        parameters.tcp_numlayers = 1;
        parameters.cp_disto_alloc = 1;
        parameters.tcp_rates[0] = float(rate);
        parameters.irreversible = 0;
        parameters.tcp_mct = 0;
        const Uint16 smallest = info.rows < info.columns ? info.rows : info.columns;
        while (parameters.numresolution > 1 && (1u << (parameters.numresolution - 1)) > smallest)
            parameters.numresolution--;

        session.codec = opj_create_compress(OPJ_CODEC_J2K);
        if (!session.codec) return EC_MemoryExhausted;
        session.quiet();
        if (!opj_setup_encoder(session.codec, &parameters, session.image)) return EC_CannotChangeRepresentation;
        MemoryStream memory;
        memory.output = &output;
        session.stream = createStream(&memory);
        if (!session.stream) return EC_MemoryExhausted;
        if (!opj_start_compress(session.codec, session.image, session.stream) ||
            !opj_encode(session.codec, session.stream) ||
            !opj_end_compress(session.codec, session.stream))
            return EC_CannotChangeRepresentation;
        output.resize(memory.offset);
        return output.empty() ? EC_CannotChangeRepresentation : EC_Normal;
    }

    static OFCondition recordLossyCompression(DcmItem* dataset, double ratio)
    {
        OFCondition result = dataset->putAndInsertString(DCM_LossyImageCompression, "01");
        if (result.bad()) return result;
        OFString ratios, methods;
        const char* previous = NULL;
        if (dataset->findAndGetString(DCM_LossyImageCompressionRatio, previous).good() && previous)
            ratios = OFString(previous) + "\\";
        previous = NULL;
        if (dataset->findAndGetString(DCM_LossyImageCompressionMethod, previous).good() && previous)
            methods = OFString(previous) + "\\";
        // Keep the two multi-valued attributes aligned, one method per ratio.
        size_t ratioCount = 0, methodCount = 0;
        for (char c : ratios) ratioCount += c == '\\';
        for (char c : methods) methodCount += c == '\\';
        while (methodCount++ < ratioCount) methods += "\\";
        char text[64];
        OFStandard::ftoa(text, sizeof(text), ratio, OFStandard::ftoa_uppercase, 0, 5);
        result = dataset->putAndInsertString(DCM_LossyImageCompressionRatio, (ratios + text).c_str());
        if (result.good())
            result = dataset->putAndInsertString(DCM_LossyImageCompressionMethod, (methods + "ISO_15444_1").c_str());
        return result;
    }

    E_TransferSyntax syntax_;
};

OFBool registered = OFFalse;
CodecParameter* codecParameter = NULL;
HorosJPEG2000RepresentationParameter* defaultParameter = NULL;
// Decoders for .90, .91 and the HTJ2K syntaxes .201, .202 and .203, whose
// codestreams OpenJPEG 2.5 decodes like any other J2K stream; then the .90 and
// .91 encoders. OpenJPEG does not encode HTJ2K.
DcmCodec* codecs[7] = {NULL, NULL, NULL, NULL, NULL, NULL, NULL};

} // namespace

void HorosJPEG2000Registration::registerCodecs()
{
    if (registered) return;
    codecParameter = new CodecParameter();
    defaultParameter = new HorosJPEG2000RepresentationParameter(0);
    codecs[0] = new Decoder(EXS_JPEG2000LosslessOnly);
    codecs[1] = new Decoder(EXS_JPEG2000);
    codecs[2] = new Decoder(EXS_HighThroughputJPEG2000LosslessOnly);
    codecs[3] = new Decoder(EXS_HighThroughputJPEG2000withRPCLOptionsLosslessOnly);
    codecs[4] = new Decoder(EXS_HighThroughputJPEG2000);
    codecs[5] = new Encoder(EXS_JPEG2000LosslessOnly);
    codecs[6] = new Encoder(EXS_JPEG2000);
    for (DcmCodec* codec : codecs) DcmCodecList::registerCodec(codec, defaultParameter, codecParameter);
    registered = OFTrue;
}

void HorosJPEG2000Registration::cleanup()
{
    if (!registered) return;
    for (DcmCodec*& codec : codecs)
    {
        DcmCodecList::deregisterCodec(codec);
        delete codec;
        codec = NULL;
    }
    delete defaultParameter;
    delete codecParameter;
    defaultParameter = NULL;
    codecParameter = NULL;
    registered = OFFalse;
}

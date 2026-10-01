//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.
#pragma once

#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmdata/dcistrmf.h>
#include <dcmtk/dcmdata/dcistrmz.h>
#include <zlib.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

// Owns the backing before the file object, so deferred values remain readable
// through conversion/save and the file object is destroyed before unlinking.
// Do not reload the original deflated source or force all values into memory.
class HorosDCMTKSeekableInput
{
    struct Backing
    {
        std::string path;
        int descriptor = -1;
        ~Backing()
        {
            if (descriptor >= 0) close(descriptor);
            if (!path.empty()) unlink(path.c_str());
        }
    } backing;
    DcmFileFormat file;
    bool loadStarted = false;

public:
    // DcmMetaInfo reads the first UL group length with getUint32, which loads
    // the entire value. Check its fixed width before allowing that accessor.
    static OFCondition checkGroupLengthWidth(const char *source)
    {
        FILE *input = fopen(source, "rb");
        if (!input) return EC_InvalidStream;
        unsigned char magic[4], header[8];
        bool preamble = fseek(input, 128, SEEK_SET) == 0 &&
            fread(magic, 1, 4, input) == 4 && memcmp(magic, "DICM", 4) == 0;
        rewind(input);
        if (preamble) fseek(input, 132, SEEK_SET);
        size_t count = fread(header, 1, sizeof(header), input);
        fclose(input);
        if (count == sizeof(header) && header[0] == 2 && header[1] == 0 &&
            header[2] == 0 && header[3] == 0 && header[4] == 'U' && header[5] == 'L' &&
            (header[6] != 4 || header[7] != 0)) return EC_CorruptedData;
        return EC_Normal;
    }

private:
    OFCondition inflateToBacking(DcmInputFileStream &input, const char *directory)
    {
        backing.path = std::string(directory) + "/.horos-inflate-XXXXXX";
        // mkstemp mutates the template; keep private permissions and own it
        // immediately, including all error paths during decompression.
        backing.descriptor = mkstemp(&backing.path[0]);
        if (backing.descriptor < 0) { backing.path.clear(); return EC_InvalidStream; }
        z_stream stream = {};
        if (inflateInit2(&stream, dcmZlibExpectRFC1950Encoding.get() ? MAX_WBITS : -MAX_WBITS) != Z_OK)
            return EC_MemoryExhausted;
        struct EndInflation { z_stream &stream; ~EndInflation() { inflateEnd(&stream); } } end{stream};
        unsigned char compressed[65536], expanded[65536];
        for (;;)
        {
            if (stream.avail_in == 0)
            {
                offile_off_t count = input.read(compressed, sizeof(compressed));
                if (count <= 0 || input.status().bad()) return EC_CorruptedData;
                stream.next_in = compressed;
                stream.avail_in = static_cast<uInt>(count);
            }
            stream.next_out = expanded;
            stream.avail_out = sizeof(expanded);
            uInt before = stream.avail_in;
            int result = inflate(&stream, Z_NO_FLUSH);
            size_t length = sizeof(expanded) - stream.avail_out;
            for (size_t written = 0; written < length;)
            {
                ssize_t count = write(backing.descriptor, expanded + written, length - written);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) return EC_InvalidStream;
                written += static_cast<size_t>(count);
            }
            if (result == Z_STREAM_END) break;
            if (result != Z_OK || (length == 0 && before == stream.avail_in)) return EC_CorruptedData;
        }
        if (fsync(backing.descriptor) != 0) return EC_InvalidStream;
        int descriptor = backing.descriptor;
        backing.descriptor = -1;
        if (close(descriptor) != 0) return EC_InvalidStream;
        return EC_Normal;
    }

public:
    HorosDCMTKSeekableInput() = default;
    HorosDCMTKSeekableInput(const HorosDCMTKSeekableInput &) = delete;
    HorosDCMTKSeekableInput &operator=(const HorosDCMTKSeekableInput &) = delete;
    DcmFileFormat &fileFormat() { return file; }

    // One load per owner. The caller chooses a writable private working
    // directory; publication and removal of the source remain its decisions.
    OFCondition load(const char *source, const char *directory)
    {
        if (loadStarted || !source || !*source || !directory || !*directory) return EC_IllegalCall;
        loadStarted = true;
        OFCondition condition = checkGroupLengthWidth(source);
        if (condition.bad()) return condition;
        DcmInputFileStream input(source);
        DcmMetaInfo *meta = file.getMetaInfo();
        meta->transferInit();
        condition = meta->read(input, EXS_Unknown, EGL_noChange, DCM_MaxReadLength);
        meta->transferEnd();
        if (condition.bad()) return condition;
        DcmElement *syntaxElement = NULL;
        OFString syntax;
        if (meta->findAndGetElement(DCM_TransferSyntaxUID, syntaxElement, OFFalse).good())
        {
            if (syntaxElement->ident() != EVR_UI || syntaxElement->getLength() > 64)
                return EC_InvalidValue;
            condition = syntaxElement->getOFString(syntax, 0);
            if (condition.bad()) return condition;
        }
        if (syntax != UID_DeflatedExplicitVRLittleEndianTransferSyntax)
            return file.loadFile(source, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
        condition = inflateToBacking(input, directory);
        if (condition.bad()) return condition;
        // Only the dataset is replaced. Retain the original meta information;
        // saveFile updates its transfer syntax for the chosen output encoding.
        return file.getDataset()->loadFile(backing.path.c_str(), EXS_LittleEndianExplicit,
                                          EGL_noChange, DCM_MaxReadLength);
    }
};

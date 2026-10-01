// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
// Distributed under the GNU Lesser General Public License, version 3.
// WITHOUT ANY WARRANTY; see the GNU Lesser General Public License for details.

#ifndef HOROS_DICOM_PROBE_H
#define HOROS_DICOM_PROBE_H

#include "HorosDCMTKSeekableInput.h"
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcistrmf.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcvrui.h>

namespace HorosDICOMProbe {
struct Result {
    bool recognized = false;
    bool datasetReadable = false;
    bool image = false;
    bool compressed = false;
    bool mayTranscode = false;
    bool needsInflation = false;
    OFString transferSyntax;
    OFString diagnostic;
};

// Only identity strings are materialized. A corrupt UID length must never
// turn a deferred element into an allocation proportional to its declared VL.
inline OFString boundedUID(DcmItem *item, const DcmTagKey &tag) {
    DcmElement *element = NULL;
    OFString value;
    if (item->findAndGetElement(tag, element, OFFalse).good() && element &&
        element->getVR() == EVR_UI && element->getLength() > 0 && element->getLength() <= 64)
        element->getOFString(value, 0);
    if (DcmUniqueIdentifier::checkStringValue(value, "1").bad()) value.clear();
    return value;
}

inline bool decodedSyntax(const OFString &uid) {
    static const char *const syntaxes[] = {
        "1.2.840.10008.1.2.4.50", "1.2.840.10008.1.2.4.51",
        "1.2.840.10008.1.2.4.57", "1.2.840.10008.1.2.4.70",
        "1.2.840.10008.1.2.4.80", "1.2.840.10008.1.2.4.81",
        "1.2.840.10008.1.2.4.90", "1.2.840.10008.1.2.4.91",
        "1.2.840.10008.1.2.4.201", "1.2.840.10008.1.2.4.202",
        "1.2.840.10008.1.2.4.203", "1.2.840.10008.1.2.5"
    };
    for (const char *syntax : syntaxes)
        if (uid == syntax) return true;
    return false;
}

// The same probe runs regardless of which flags the caller requests. Values
// (including small pixels and fragments) stay deferred on the seekable file;
// no pixel arrays, representations or decoder registrations are accessed.
inline Result inspect(const char *path) {
    Result result;
    if (!path || !*path) return result;
    try {
        if (HorosDCMTKSeekableInput::checkGroupLengthWidth(path).bad()) {
            result.diagnostic = "invalid file meta group length";
            return result;
        }
        // Read the envelope directly. DcmFileFormat looks up the syntax as
        // part of reading, which would materialize a malformed binary value
        // posing as TransferSyntaxUID before we could bound it.
        DcmInputFileStream stream(path);
        DcmMetaInfo meta;
        meta.transferInit();
        OFCondition metaStatus = meta.read(stream, EXS_Unknown, EGL_noChange, 0);
        meta.transferEnd();
        result.transferSyntax = boundedUID(&meta, DCM_TransferSyntaxUID);
        if (metaStatus.bad() || (meta.tagExists(DCM_TransferSyntaxUID, OFFalse) && result.transferSyntax.empty())) {
            result.diagnostic = "invalid file meta information";
            return result;
        }
        if (result.transferSyntax == "1.2.840.10008.1.2.1.99") {
            // The inflater has no lazy factory. Only the isolated conversion
            // path may validate the expanded, seekable dataset. Recognizing
            // this envelope is a routing decision, never index approval.
            result.recognized = true;
            result.compressed = true;
            result.needsInflation = true;
            result.diagnostic = "dataset requires seekable inflation";
            return result;
        }

        DcmFileFormat file;
        // Walk headers through EOF, including out-of-order tags and trailing
        // data, but defer every nonempty value. This reports damaged structure
        // without losing recognition or normalizing a damaged file by transcode.
        OFCondition status = file.loadFile(path, EXS_Unknown, EGL_noChange, 0, ERM_autoDetect);
        DcmDataset *dataset = file.getDataset();
        // A successful empty/meta-only parse is not a DICOM object. Series UID
        // is not mandatory for SR, waveform or other non-image objects.
        result.recognized = !boundedUID(dataset, DCM_SOPClassUID).empty() ||
            !boundedUID(dataset, DCM_SeriesInstanceUID).empty();
        // Damage before the root identity can leave a parsed element and a
        // genuine storage identity in the envelope. Preserve it for diagnosis;
        // neither a meta-only file nor arbitrary bytes provide that evidence.
        if (!result.recognized && status.bad() && dataset->card() > 0)
            result.recognized = !boundedUID(&meta, DCM_MediaStorageSOPClassUID).empty();
        result.datasetReadable = result.recognized && status.good();
        result.diagnostic = status.text();
        result.image = result.recognized && dataset->tagExists(DCM_PixelData, OFFalse);
        if (result.transferSyntax.empty())
            result.transferSyntax = DcmXfer(dataset->getOriginalXfer()).getXferID();
        result.compressed = result.recognized && decodedSyntax(result.transferSyntax);
        const bool native = result.transferSyntax == "1.2.840.10008.1.2" ||
            result.transferSyntax == "1.2.840.10008.1.2.1" ||
            result.transferSyntax == "1.2.840.10008.1.2.2";
        result.mayTranscode = result.datasetReadable && result.image &&
            (native || result.compressed);
    } catch (...) {
        result.datasetReadable = false;
        result.mayTranscode = false;
        result.diagnostic = "DICOM probe failed";
    }
    return result;
}
} // namespace HorosDICOMProbe
#endif

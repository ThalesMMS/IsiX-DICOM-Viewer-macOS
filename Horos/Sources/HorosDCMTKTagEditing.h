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
#include <dcmtk/dcmdata/dctk.h>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

// Sequence item indexes are zero-based, as in the metadata editor's paths.
typedef struct
{
    unsigned short group;
    unsigned short element;
    unsigned int item;
} HorosTagPathStep;

// A textual value from the editor must not accidentally enable putString's
// numeric or hexadecimal interpretations for binary VRs.
static inline bool HorosDICOMEditingTextVR(DcmEVR vr)
{
    switch (vr) {
        case EVR_AE: case EVR_AS: case EVR_CS: case EVR_DA: case EVR_DS:
        case EVR_DT: case EVR_IS: case EVR_LO: case EVR_LT: case EVR_PN:
        case EVR_SH: case EVR_ST: case EVR_TM: case EVR_UC: case EVR_UI:
        case EVR_UR: case EVR_UT: return true;
        default: return false;
    }
}

// Locate existing items numerically. A private sequence's actual element VR,
// rather than the dictionary VR of its tag, determines whether it is a SQ.
// Keep ancestors for the caller to resolve the effective character set.
static inline DcmItem *HorosDICOMEditingResolveItem(DcmItem &root,
    const std::vector<HorosTagPathStep> &path, std::vector<DcmItem *> &ancestors,
    std::string *reason)
{
    ancestors.clear();
    DcmItem *item = &root;
    ancestors.push_back(item);
    for (const HorosTagPathStep &step : path) {
        DcmElement *element = nullptr;
        const DcmTagKey key(step.group, step.element);
        if (item->findAndGetElement(key, element, OFFalse).bad() || !element) {
            if (reason) {
                std::ostringstream message;
                message << "the file does not carry the sequence " << key;
                *reason = message.str();
            }
            return nullptr;
        }
        if (element->ident() != EVR_SQ) {
            if (reason) *reason = "that element is not a sequence";
            return nullptr;
        }
        DcmSequenceOfItems *sequence = static_cast<DcmSequenceOfItems *>(element);
        if (step.item >= sequence->card()) {
            if (reason) {
                std::ostringstream message;
                message << "the sequence has " << sequence->card()
                        << " item(s), and item " << step.item << " was asked for";
                *reason = message.str();
            }
            return nullptr;
        }
        item = sequence->getItem(step.item);
        if (!item) {
            if (reason) *reason = "the sequence item could not be read";
            return nullptr;
        }
        ancestors.push_back(item);
    }
    return item;
}

// The value is already encoded in the destination item's effective charset.
// A refused replacement never modifies the original leaf. Insertion of a
// nested or private data element is deliberately unsupported; existing private
// VRs and creator blocks are retained, without dictionary reinterpretation.
static inline bool HorosDICOMEditingWriteElement(DcmItem &item, const DcmTagKey &key,
    bool removes, const std::string &value, bool nested, std::string *reason)
{
    DcmElement *existing = nullptr;
    item.findAndGetElement(key, existing, OFFalse);
    if (removes) {
        if (!existing) {
            if (!nested) return true;
            if (reason) *reason = "that item does not carry this element";
            return false;
        }
        delete item.remove(existing);
        return true;
    }
    const bool privateCreator = (key.getGroup() & 1) && key.getElement() >= 0x0010 && key.getElement() <= 0x00ff;
    const bool privateData = (key.getGroup() & 1) && !privateCreator;
    if (!existing && (nested || ((key.getGroup() & 1) && !privateCreator))) {
        if (reason) *reason = nested ? "that item does not carry this element" :
            "the file does not carry this private element";
        return false;
    }
    DcmTag tag(key);
    if (!existing && privateCreator) tag.setVR(EVR_LO);
    const DcmEVR vr = existing ? existing->getVR() : tag.getEVR();
    const bool rawUnknown = vr == EVR_UN && existing && (nested || privateData);
    const bool topEmpty = !nested && value.empty() &&
        (existing || (DcmVR(vr).isStandard() && vr != EVR_UN));
    if (!nested && key.getGroup() < 0x0008 && !(vr == EVR_SQ && value.empty())) {
        if (reason) *reason = "file header elements are not editable as dataset text";
        return false;
    }
    if (!topEmpty && !HorosDICOMEditingTextVR(vr) && !rawUnknown) {
        if (reason) {
            if (vr == EVR_SQ) *reason = "a sequence cannot be given a text value";
            else {
                std::ostringstream message;
                message << "value representation " << DcmVR(vr).getVRName() << " is not editable as text";
                *reason = message.str();
            }
        }
        return false;
    }
    if (value.find('\0') != std::string::npos || value.size() >= std::numeric_limits<Uint32>::max()) {
        if (reason) *reason = "the value contains NUL or exceeds the DICOM value length";
        return false;
    }
    DcmElement *created = nullptr;
    OFCondition result = EC_Normal;
    if (existing) created = static_cast<DcmElement *>(existing->clone());
    else result = DcmItem::newDicomElementWithVR(created, tag);
    std::unique_ptr<DcmElement> replacement(created);
    if (!replacement || result.bad()) {
        if (reason) *reason = "the replacement element could not be created";
        return false;
    }
    if (topEmpty) result = replacement->clear();
    else if (rawUnknown) {
        // Preserve the editor's legacy raw UN operation, including space pad.
        // putString would interpret this byte field as hexadecimal input.
        std::string padded = value;
        if (padded.size() & 1) padded += ' ';
        result = replacement->putUint8Array(reinterpret_cast<const Uint8 *>(padded.data()),
                                            static_cast<unsigned long>(padded.size()));
    } else result = replacement->putString(value.data(), static_cast<Uint32>(value.size()));
    if (result.good()) result = item.insert(replacement.get(), OFTrue);
    if (result.bad()) {
        if (reason) *reason = result.text();
        return false;
    }
    replacement.release(); // DcmItem owns the successfully inserted element.
    return true;
}

// Keep file-format identity coherent when its corresponding dataset UID is an
// explicit edit target. Do not generate a replacement UID or rebuild unrelated
// meta information. Dataset-only files keep their original form.
static inline bool HorosDICOMEditingSynchronizeUID(DcmFileFormat &file,
    const DcmTagKey &editedKey, std::string *reason)
{
    if (!file.getMetaInfo()->card()) return true;
    DcmTagKey metaKey;
    if (editedKey == DCM_SOPClassUID) metaKey = DCM_MediaStorageSOPClassUID;
    else if (editedKey == DCM_SOPInstanceUID) metaKey = DCM_MediaStorageSOPInstanceUID;
    else return true;
    DcmElement *source = nullptr;
    if (file.getDataset()->findAndGetElement(editedKey, source, OFFalse).bad() || !source) {
        delete file.getMetaInfo()->remove(metaKey);
        return true;
    }
    OFString value;
    OFCondition result = source->getOFStringArray(value);
    if (result.good()) result = file.getMetaInfo()->putAndInsertString(metaKey, value.c_str());
    if (result.bad()) {
        if (reason) *reason = result.text();
        return false;
    }
    return true;
}

/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// Compiled with ARC.

#import "IsiXDCMTKAnonymizer.h"
#import "IsiXDCMTKInternal.hpp"

#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcspchrs.h>
#include "HorosDCMTKSeekableInput.h"
#include "HorosSelectedAnonymizationCatalog.h"
#include <algorithm>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error "IsiXDCMTKAnonymizer.mm is compiled with ARC (-fobjc-arc)"
#endif

namespace {

DcmTagKey Key(uint32_t tag)
{
    return DcmTagKey((Uint16)(tag >> 16), (Uint16)(tag & 0xffff));
}

// Bytes as they are: a UID is ASCII, and anything else must still compare
// equal to itself on the way back.
NSString *Text(const OFString &value)
{
    return [[NSString alloc] initWithBytes:value.data() length:value.length() encoding:NSISOLatin1StringEncoding];
}

OFString Bytes(NSString *value)
{
    NSData *data = [value dataUsingEncoding:NSISOLatin1StringEncoding] ?: [NSData data];
    return OFString(static_cast<const char *>(data.bytes), data.length);
}

bool rootUID(DcmItem &item, const DcmTagKey &key, OFString &value)
{
    DcmElement *element = nullptr;
    return item.findAndGetElement(key, element, OFFalse).good() &&
        element->getVR() == EVR_UI && element->getLengthField() > 0 &&
        element->getLengthField() <= 64 && element->getOFStringArray(value).good() && !value.empty();
}

E_TransferSyntax sourceTransferSyntax(DcmFileFormat &file)
{
    // A deflated source is read through an Explicit LE backing dataset. Its
    // original serialization syntax remains in the retained file meta.
    OFString syntax;
    if (rootUID(*file.getMetaInfo(), DCM_TransferSyntaxUID, syntax))
        return DcmXfer(syntax.c_str()).getXfer();
    return file.getDataset()->getOriginalXfer(); // Dataset without file meta.
}

unsigned publicPolicy(const DcmTagKey &key)
{
    if (key.getElement() == 0) return 2; // Generic group length.
    uint32_t group = key.getGroup();
    if ((group & 0xff00) == 0x5000 || (group & 0xff00) == 0x6000 || (group & 0xff00) == 0x7f00)
        group &= 0xff00; // Retired repeating groups in the frozen catalog.
    uint64_t needle = uint64_t((group << 16) | key.getElement()) << 8;
    auto begin = std::begin(HorosSelectedPublicFields), end = std::end(HorosSelectedPublicFields);
    auto found = std::lower_bound(begin, end, needle);
    return found != end && (*found >> 8) == (needle >> 8) ? unsigned(*found & 255) : 0;
}

// Capture serialized leaf sizes and tree boundaries before writing. DCMTK can
// turn an inaccessible deferred value into an empty element while reporting a
// successful header write. A fresh full parse must still have this shape.
using Shape = std::vector<uint64_t>;
bool elementShape(DcmElement &element, E_TransferSyntax xfer, Shape &shape);
bool itemShape(DcmItem &item, E_TransferSyntax xfer, Shape &shape)
{
    shape.push_back(0x100000000ULL);
    for (unsigned long i = 0; i < item.card(); ++i) {
        DcmElement *element = item.getElement(i);
        if (element->getTag().getElement() == 0 || element->getTag() == DCM_DataSetTrailingPadding) continue;
        if (!elementShape(*element, xfer, shape)) return false;
    }
    shape.push_back(0x200000000ULL);
    return true;
}

bool elementShape(DcmElement &element, E_TransferSyntax xfer, Shape &shape)
{
    shape.push_back((uint32_t(element.getTag().getGroup()) << 16) | element.getTag().getElement());
    if (element.ident() == EVR_SQ) {
        auto &sequence = static_cast<DcmSequenceOfItems &>(element);
        shape.push_back(sequence.card());
        for (unsigned long i = 0; i < sequence.card(); ++i)
            if (!itemShape(*sequence.getItem(i), xfer, shape)) return false;
        return true;
    }
    if (element.ident() == EVR_PixelData) {
        auto &pixels = static_cast<DcmPixelData &>(element);
        E_TransferSyntax representation;
        const DcmRepresentationParameter *parameters = nullptr;
        pixels.getOriginalRepresentationKey(representation, parameters);
        if (DcmXfer(representation).usesEncapsulatedFormat()) {
            DcmPixelSequence *sequence = nullptr;
            if (pixels.getEncapsulatedRepresentation(representation, parameters, sequence).bad() || !sequence) return false;
            shape.push_back(sequence->card());
            for (unsigned long i = 0; i < sequence->card(); ++i) {
                DcmPixelItem *fragment = nullptr;
                if (sequence->getItem(fragment, i).bad() || !fragment || !elementShape(*fragment, xfer, shape)) return false;
            }
            return true;
        }
    }
    const Uint32 length = element.getLength(xfer, EET_UndefinedLength);
    shape.push_back(length);
    if (!element.valueLoaded() && length) {
        // A skipped value may extend past EOF even when loadFile succeeds.
        // Probe its final byte without loading its payload into memory.
        Uint8 byte;
        if (element.getPartialValue(&byte, length - 1, 1).bad()) return false;
    }
    return true;
}

bool sameSource(const char *path, const struct stat &before)
{
    struct stat now;
    return stat(path, &now) == 0 && S_ISREG(now.st_mode) && (now.st_mode & 0444) &&
        access(path, R_OK) == 0 && now.st_dev == before.st_dev && now.st_ino == before.st_ino &&
        now.st_size == before.st_size && now.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec &&
        now.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec &&
        now.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec && now.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec;
}

// What the file's guarded calls answer when DCMTK throws.
template <typename Body>
bool Guarded(const char *operation, Body &&body)
{
    bool answer = false;
    IsiXDCMTKGuard(NULL, operation, [&]() -> NSError * { answer = body(); return nil; });
    return answer;
}

} // namespace

@implementation IsiXDCMTKSelectedElement
{
@package
    BOOL _exists, _isPixelData;
    NSString *_valueRepresentation, *_dictionaryValueRepresentation;
    NSInteger _catalogPolicy;
}
- (BOOL)exists { return _exists; }
- (BOOL)isPixelData { return _isPixelData; }
- (NSString *)valueRepresentation { return _valueRepresentation ?: @""; }
- (NSString *)dictionaryValueRepresentation { return _dictionaryValueRepresentation ?: @""; }
- (NSInteger)catalogPolicy { return _catalogPolicy; }
@end

@implementation IsiXDCMTKAnonymizationFile
{
    std::unique_ptr<HorosDCMTKSeekableInput> _input;
    std::string _path, _folder;
    NSString *_folderPath;
    struct stat _source;
    E_TransferSyntax _xfer;
    Shape _shape;
    // The declared character set's converters, prepared at the first text
    // that needs them: the selected-field editor cannot change the declaration
    // without re-encoding every unselected text value, and DCMTK decodes code
    // extensions but does not encode into them.
    std::unique_ptr<DcmSpecificCharacterSet> _encoder, _decoder;
    bool _prepared, _usable;
}

+ (instancetype)stagedFileAtPath:(NSString *)path
{
    IsiXDCMTKAnonymizationFile *file = [[self alloc] initPrivately];
    const char *filename = path.fileSystemRepresentation;
    NSString *folderPath = path.stringByDeletingLastPathComponent;
    const char *folder = folderPath.fileSystemRepresentation;
    if (!filename || !folder) return nil;
    file->_folderPath = folderPath;
    const bool loaded = Guarded("DcmFileFormat::loadFile", [&]() {
        file->_path = filename;
        file->_folder = folder;
        file->_input.reset(new HorosDCMTKSeekableInput());
        file->_input->fileFormat().setMaxNestingDepth(16);
        if (stat(filename, &file->_source) != 0 || !S_ISREG(file->_source.st_mode) ||
            !(file->_source.st_mode & 0444) || access(filename, R_OK) != 0 ||
            file->_input->load(filename, folder).bad()) return false;
        file->_xfer = sourceTransferSyntax(file->_input->fileFormat());
        return true;
    });
    return loaded ? file : nil;
}

- (instancetype)initPrivately
{
    if ((self = [super init])) {
        _xfer = EXS_Unknown;
        _prepared = _usable = false;
    }
    return self;
}

- (DcmFileFormat &)file
{
    return _input->fileFormat();
}

- (NSString *)UIDForTag:(const DcmTagKey &)key inMeta:(BOOL)meta
{
    NSString *uid = nil;
    Guarded("DcmItem::findAndGetElement", [&]() {
        OFString value;
        DcmItem *item = meta ? (DcmItem *)[self file].getMetaInfo() : (DcmItem *)[self file].getDataset();
        if (rootUID(*item, key, value)) uid = Text(value);
        return true;
    });
    return uid;
}

- (NSString *)datasetSOPClassUID { return [self UIDForTag:DCM_SOPClassUID inMeta:NO]; }
- (NSString *)datasetSOPInstanceUID { return [self UIDForTag:DCM_SOPInstanceUID inMeta:NO]; }
- (NSString *)metaStorageSOPClassUID { return [self UIDForTag:DCM_MediaStorageSOPClassUID inMeta:YES]; }
- (NSString *)metaStorageSOPInstanceUID { return [self UIDForTag:DCM_MediaStorageSOPInstanceUID inMeta:YES]; }

- (BOOL)canKeepTransferSyntax
{
    return Guarded("DcmDataset::canWriteXfer", [&]() {
        return _xfer != EXS_Unknown && [self file].getDataset()->canWriteXfer(_xfer);
    });
}

- (BOOL)recordShape
{
    return Guarded("DcmItem::getLength", [&]() {
        Shape shape;
        if (!itemShape(*[self file].getDataset(), _xfer, shape) || !sameSource(_path.c_str(), _source)) return false;
        _shape = std::move(shape);
        return true;
    });
}

- (NSData *)characterSet
{
    NSData *declared = [NSData data];
    Guarded("DcmItem::findAndGetOFStringArray", [&]() {
        OFString charset;
        [self file].getDataset()->findAndGetOFStringArray(DCM_SpecificCharacterSet, charset, OFFalse);
        declared = [NSData dataWithBytes:charset.data() length:charset.length()];
        return true;
    });
    return declared;
}

- (IsiXDCMTKSelectedElement *)elementForTag:(uint32_t)tag
{
    IsiXDCMTKSelectedElement *facts = [IsiXDCMTKSelectedElement new];
    Guarded("DcmItem::findAndGetElement", [&]() {
        const DcmTagKey key = Key(tag);
        DcmElement *existing = nullptr;
        [self file].getDataset()->findAndGetElement(key, existing, OFFalse); // Only the dataset root.
        facts->_exists = existing != nullptr;
        facts->_isPixelData = existing && existing->ident() == EVR_PixelData;
        facts->_valueRepresentation = existing ? @(DcmVR(existing->getVR()).getVRName()) : @"";
        facts->_dictionaryValueRepresentation = @(DcmVR(DcmTag(key).getEVR()).getVRName());
        facts->_catalogPolicy = publicPolicy(key);
        return true;
    });
    return facts;
}

- (NSData *)encodeUTF8:(NSData *)utf8Data valueRepresentation:(NSString *)valueRepresentation
        codeExtensions:(BOOL)extensions
{
    NSData *encodedData = nil;
    Guarded("DcmSpecificCharacterSet::convertString", [&]() {
        OFString declaration;
        [self file].getDataset()->findAndGetOFStringArray(DCM_SpecificCharacterSet, declaration, OFFalse);
        if (!_prepared) {
            _prepared = true;
            const OFString charset = declaration == "ISO_IR 6" ? "" : declaration;
            _decoder.reset(new DcmSpecificCharacterSet());
            _usable = _decoder->selectCharacterSet(charset, "ISO_IR 192").good() &&
                _decoder->setConversionFlags(OFCharacterEncoding::AbortTranscodingOnIllegalSequence).good();
            if (_usable && !extensions) {
                _encoder.reset(new DcmSpecificCharacterSet());
                _usable = _encoder->selectCharacterSet("ISO_IR 192", charset).good() &&
                    _encoder->setConversionFlags(OFCharacterEncoding::AbortTranscodingOnIllegalSequence).good();
            }
        }
        if (!_usable) return false;
        const OFString utf8(static_cast<const char *>(utf8Data.bytes), utf8Data.length);
        const DcmEVR vr = DcmVR(valueRepresentation.UTF8String).getEVR();
        const OFString delimiters = vr == EVR_PN ? "\\^=" :
            (vr == EVR_ST || vr == EVR_LT || vr == EVR_UT ? "" : "\\");
        OFString encoded, decoded;
        if (extensions) encoded = utf8; // ASCII needs no escape; prove its declared meaning below.
        else if (!_encoder || _encoder->convertString(utf8, encoded, delimiters).bad()) return false;
        if (encoded.find('\0') != OFString_npos || encoded.find('\x1b') != OFString_npos ||
            _decoder->convertString(encoded, decoded, delimiters).bad() || decoded != utf8) return false;
        encodedData = [NSData dataWithBytes:encoded.data() length:encoded.length()];
        return true;
    });
    return encodedData;
}

- (BOOL)applyReplacement:(IsiXDCMTKSelectedReplacement)replacement toTag:(uint32_t)tag value:(NSData *)valueData
{
    return Guarded("DcmItem::insert", [&]() {
        DcmDataset &dataset = *[self file].getDataset();
        const DcmTagKey key = Key(tag);
        const std::string value(static_cast<const char *>(valueData.bytes), valueData.length);
        DcmElement *existing = nullptr;
        dataset.findAndGetElement(key, existing, OFFalse); // Only the dataset root.
        DcmTag dictionaryTag(key);
        switch (replacement) {
            case IsiXDCMTKSelectedReplacementClearExisting:
                return existing != nullptr && existing->clear().good();
            case IsiXDCMTKSelectedReplacementInsertEmptySequence:
                return dataset.insertEmptyElement(DcmTag(key, EVR_SQ), OFTrue).good();
            case IsiXDCMTKSelectedReplacementEmptyPixelData: {
                if (!existing) return false;
                // clear() inherited from the byte value does not clear encapsulated
                // representations. Replace the selected value with a truly empty one.
                auto &pixels = static_cast<DcmPixelData &>(*existing);
                E_TransferSyntax representation;
                const DcmRepresentationParameter *parameters = nullptr;
                pixels.getOriginalRepresentationKey(representation, parameters);
                std::unique_ptr<DcmPixelData> empty(new DcmPixelData(existing->getTag()));
                if (DcmXfer(representation).usesEncapsulatedFormat()) {
                    std::unique_ptr<DcmPixelSequence> sequence(new DcmPixelSequence(DCM_PixelSequenceTag));
                    std::unique_ptr<DcmPixelItem> offsets(new DcmPixelItem(DCM_PixelItemTag));
                    if (sequence->insert(offsets.get()).bad()) return false;
                    offsets.release();
                    empty->putOriginalRepresentation(representation, parameters, sequence.release());
                }
                if (dataset.insert(empty.get(), OFTrue).bad()) return false;
                empty.release();
                return true;
            }
            case IsiXDCMTKSelectedReplacementInsertEmpty:
                return dataset.insertEmptyElement(dictionaryTag, OFTrue).good();
            case IsiXDCMTKSelectedReplacementPutIntoExisting:
                return existing != nullptr && existing->putString(value.c_str()).good();
            case IsiXDCMTKSelectedReplacementInsertText:
                if (key.isPrivateReservation()) dictionaryTag.setVR(EVR_LO);
                return dataset.putAndInsertString(dictionaryTag, value.c_str(), OFTrue).good();
        }
        return false;
    });
}

- (BOOL)writeVerifiedCopyToPath:(NSString *)outputPath temporaryTemplate:(NSString *)temporaryTemplate
                   storageClass:(NSString *)storageClass instance:(NSString *)instance
{
    const char *output = outputPath.fileSystemRepresentation;
    const char *temporaryPath = [_folderPath stringByAppendingPathComponent:temporaryTemplate].fileSystemRepresentation;
    std::vector<char> name;
    int fd = -1;
    const bool written = output && temporaryPath && Guarded("DcmFileFormat::saveFile", [&]() {
        name.assign(temporaryPath, temporaryPath + strlen(temporaryPath) + 1);
        fd = mkstemp(name.data());
        if (fd < 0 || close(fd) != 0) return false;
        if ([self file].saveFile(name.data(), _xfer, EET_UndefinedLength, EGL_recalcGL,
                                 EPD_noChange, 0, 0, EWM_updateMeta).bad()) return false;
        // A fresh parse of what was written must have the shape recorded and
        // name the identity the dataset had.
        HorosDCMTKSeekableInput verificationInput;
        DcmFileFormat &verified = verificationInput.fileFormat();
        verified.setMaxNestingDepth(16);
        Shape actual;
        OFString metaStorage, metaInstance;
        if (!sameSource(_path.c_str(), _source) ||
            verificationInput.load(name.data(), _folder.c_str()).bad() ||
            sourceTransferSyntax(verified) != _xfer ||
            !itemShape(*verified.getDataset(), _xfer, actual) || _shape != actual ||
            !rootUID(*verified.getMetaInfo(), DCM_MediaStorageSOPClassUID, metaStorage) || metaStorage != Bytes(storageClass) ||
            !rootUID(*verified.getMetaInfo(), DCM_MediaStorageSOPInstanceUID, metaInstance) || metaInstance != Bytes(instance))
            return false;
        return rename(name.data(), output) == 0;
    });
    if (!written && fd >= 0) unlink(name.data());
    return written;
}

@end

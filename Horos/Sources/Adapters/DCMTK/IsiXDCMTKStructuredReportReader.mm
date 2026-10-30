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

#import "IsiXDCMTKStructuredReportReader.h"
#include "IsiXDCMTKInternal.hpp"
#include <dcmtk/dcmdata/dcfilefo.h>
#include "HorosStructuredReportBridge.hpp"
#include "HorosDCMTKCompatibility.h"
#include "HorosAtomicFileWriter.h"
#include <dcmtk/dcmdata/dcdeftag.h>
#include <cstring>
#include <memory>

// Loads the file and reads it as a report; the document is nil when either
// step fails, with the condition DCMTK gave.
static NSError *IsiXDCMTKReadReport(NSString *path, DcmFileFormat &file, std::unique_ptr<HorosSRDocument> &document)
{
    const char *fileSystemPath = path.length ? path.fileSystemRepresentation : NULL;
    if (!fileSystemPath) return IsiXDCMTKFailure(@"The structured report has no usable path");
    OFCondition status = file.loadFile(fileSystemPath);
    if (status.bad()) return IsiXDCMTKErrorFromCondition(status);
    std::unique_ptr<HorosSRDocument> read(new HorosSRDocument());
    status = read->read(*file.getDataset());
    if (status.bad()) return IsiXDCMTKErrorFromCondition(status);
    document = std::move(read);
    return nil;
}

@implementation IsiXDCMTKStructuredReportReader

+ (BOOL)canReadReportAtPath:(NSString *)path error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "HorosSRDocument::read", [&]() -> NSError * {
        DcmFileFormat file;
        std::unique_ptr<HorosSRDocument> document;
        return IsiXDCMTKReadReport(path, file, document);
    });
}

+ (NSString *)titleMeaningOfReportAtPath:(NSString *)path error:(NSError **)error
{
    NSString *meaning = nil;
    BOOL read = IsiXDCMTKGuard(error, "HorosSRDocument::read", [&]() -> NSError * {
        DcmFileFormat file;
        std::unique_ptr<HorosSRDocument> document;
        if (NSError *failure = IsiXDCMTKReadReport(path, file, document)) return failure;
        OFString codeMeaning = document->getTree().getCurrentContentItem().getConceptName().getCodeMeaning();
        meaning = [NSString stringWithUTF8String:codeMeaning.c_str()];
        return nil;
    });
    return read ? meaning : nil;
}

+ (NSArray<NSString *> *)referencedImageInstancesOfReportAtPath:(NSString *)path
{
    NSMutableArray<NSString *> *references = [NSMutableArray array];
    IsiXDCMTKGuard(NULL, "HorosSRDocument::read", [&]() -> NSError * {
        DcmFileFormat file;
        std::unique_ptr<HorosSRDocument> document;
        if (NSError *failure = IsiXDCMTKReadReport(path, file, document)) return failure;
        do {
            if (!document->getTree().currentImageSOPInstanceUID().empty()) {
                OFString instance = document->getTree().currentImageSOPInstanceUID();
                if (NSString *uid = [NSString stringWithUTF8String:instance.c_str()])
                    [references addObject:uid];
            }
        } while (document->getTree().iterate());
        return nil;
    });
    return references;
}

@end

namespace {

DSRTypes::E_DocumentType IsiXDCMTKDocumentType(IsiXDCMTKReportType type)
{
    return type == IsiXDCMTKReportTypeComprehensive ? DSRTypes::DT_ComprehensiveSR : DSRTypes::DT_BasicTextSR;
}

DSRCodedEntryValue IsiXDCMTKCodedEntry(NSString *code, NSString *scheme, NSString *meaning)
{
    return DSRCodedEntryValue(code.UTF8String ?: "", scheme.UTF8String ?: "", meaning.UTF8String ?: "");
}

NSData *IsiXDCMTKCStringData(const char *value)
{
    return value ? [NSData dataWithBytes:value length:strlen(value)] : [NSData data];
}

// What the report's guarded calls do when DCMTK throws: nothing.
template <typename Body>
void IsiXDCMTKReportCall(const char *operation, Body &&body)
{
    IsiXDCMTKGuard(NULL, operation, [&]() -> NSError * { body(); return nil; });
}

} // namespace

@implementation IsiXDCMTKStructuredReport
{
    std::unique_ptr<HorosSRDocument> _document;
    std::unique_ptr<DcmFileFormat> _prepared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        try { _document.reset(new HorosSRDocument()); }
        catch (...) { return nil; }
    }
    return self;
}

- (BOOL)readFileAtPath:(NSString *)path loaded:(BOOL *)loaded encapsulatedDocument:(NSData **)encapsulatedDocument
{
    BOOL read = NO;
    if (loaded) *loaded = NO;
    IsiXDCMTKReportCall("HorosSRDocument::read", [&]() {
        DcmFileFormat file;
        OFCondition status = file.loadFile(path.UTF8String);
        if (loaded) *loaded = status.good();
        if (status.good()) status = _document->read(*file.getDataset());
        read = status.good();
        const Uint8 *buffer = NULL;
        unsigned long length = 0;
        if (encapsulatedDocument &&
            file.getDataset()->findAndGetUint8Array(DCM_EncapsulatedDocument, buffer, &length, OFFalse).good())
            *encapsulatedDocument = buffer ? [NSData dataWithBytes:buffer length:length] : [NSData data];
    });
    return read;
}

+ (NSData *)archivedDataOfFileAtPath:(NSString *)path
{
    NSData *archive = nil;
    IsiXDCMTKReportCall("DcmFileFormat::loadFile", [&]() {
        DcmFileFormat file;
        if (file.loadFile(path.UTF8String) != EC_Normal) return;
        const Uint8 *buffer = NULL;
        unsigned long length = 0;
        if (file.getDataset()->findAndGetUint8Array(DCM_EncapsulatedDocument, buffer, &length, OFFalse).good())
            archive = [NSData dataWithBytes:buffer length:(unsigned)length];
        else if (file.getDataset()->findAndGetUint8Array(DCM_OsirixROI, buffer, &length, OFFalse).good())
            archive = [NSData dataWithBytes:buffer length:(unsigned)length];
    });
    return archive;
}

- (void)createNewDocument:(IsiXDCMTKReportType)type
{
    IsiXDCMTKReportCall("HorosSRDocument::createNewDocument", [&]() {
        _document->createNewDocument(IsiXDCMTKDocumentType(type));
    });
}

- (void)clearTree
{
    IsiXDCMTKReportCall("HorosSRTree::clear", [&]() { _document->getTree().clear(); });
}

- (void)addRootContainerWithCode:(NSString *)code scheme:(NSString *)scheme meaning:(NSString *)meaning
{
    IsiXDCMTKReportCall("HorosSRTree::addContentItem", [&]() {
        _document->getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
        _document->getTree().getCurrentContentItem().setConceptName(IsiXDCMTKCodedEntry(code, scheme, meaning));
    });
}

- (void)addTextWithCode:(NSString *)code scheme:(NSString *)scheme meaning:(NSString *)meaning value:(NSString *)value
{
    IsiXDCMTKReportCall("HorosSRTree::addContentItem", [&]() {
        _document->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent);
        _document->getTree().getCurrentContentItem().setConceptName(IsiXDCMTKCodedEntry(code, scheme, meaning));
        if (value) _document->getTree().getCurrentContentItem().setStringValue(value.UTF8String ?: "");
    });
}

- (void)addImageReferenceWithCode:(NSString *)code scheme:(NSString *)scheme meaning:(NSString *)meaning
                         SOPClass:(NSString *)sopClass instance:(NSString *)instance frames:(NSString *)frames
{
    IsiXDCMTKReportCall("HorosSRTree::addContentItem", [&]() {
        _document->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, DSRTypes::AM_belowCurrent);
        _document->getTree().getCurrentContentItem().setConceptName(IsiXDCMTKCodedEntry(code, scheme, meaning));
        HorosSRImageReference reference(OFString(sopClass.UTF8String ?: ""), OFString(instance.UTF8String ?: ""));
        reference.getFrameList().putString(frames.UTF8String);
        _document->getTree().getCurrentContentItem().setImageReference(reference);
        _document->getTree().goUp(); // go up to the root element
    });
}

- (NSString *)currentConceptMeaning
{
    NSString *meaning = nil;
    IsiXDCMTKReportCall("HorosSRItem::getConceptName", [&]() {
        OFString value = _document->getTree().getCurrentContentItem().getConceptName().getCodeMeaning();
        meaning = [NSString stringWithUTF8String:value.c_str()];
    });
    return meaning;
}

- (NSData *)referencedInstanceOfItemWithCode:(NSString *)code scheme:(NSString *)scheme meaning:(NSString *)meaning
{
    NSData *instance = nil;
    IsiXDCMTKReportCall("HorosSRTree::gotoNamedNode", [&]() {
        if (_document->getTree().gotoNamedNode(IsiXDCMTKCodedEntry(code, scheme, meaning), OFTrue, OFTrue) > 0) {
            HorosSRImageReference reference = _document->getTree().getCurrentContentItem().getImageReference();
            instance = IsiXDCMTKCStringData(reference.getSOPInstanceUID().c_str());
        }
    });
    return instance;
}

- (NSData *)valueOfField:(IsiXDCMTKReportField)field
{
    NSData *value = [NSData data];
    IsiXDCMTKReportCall("HorosSRDocument::get", [&]() {
        HorosSRDocument &document = *_document;
        const char *text = NULL;
        switch (field) {
            case IsiXDCMTKReportFieldAccessionNumber: text = document.getAccessionNumber(); break;
            case IsiXDCMTKReportFieldContentDate: text = document.getContentDate(); break;
            case IsiXDCMTKReportFieldInstanceNumber: text = document.getInstanceNumber(); break;
            case IsiXDCMTKReportFieldManufacturer: text = document.getManufacturer(); break;
            case IsiXDCMTKReportFieldPatientID: text = document.getPatientID(); break;
            case IsiXDCMTKReportFieldPatientBirthDate: text = document.getPatientsBirthDate(); break;
            case IsiXDCMTKReportFieldPatientName: text = document.getPatientsName(); break;
            case IsiXDCMTKReportFieldSeriesDescription: text = document.getSeriesDescription(); break;
            case IsiXDCMTKReportFieldSeriesInstanceUID: text = document.getSeriesInstanceUID(); break;
            case IsiXDCMTKReportFieldSeriesNumber: text = document.getSeriesNumber(); break;
            case IsiXDCMTKReportFieldSOPClassUID: text = document.getSOPClassUID(); break;
            case IsiXDCMTKReportFieldSOPInstanceUID: text = document.getSOPInstanceUID(); break;
            case IsiXDCMTKReportFieldSpecificCharacterSet: text = document.getSpecificCharacterSet(); break;
            case IsiXDCMTKReportFieldStudyInstanceUID: text = document.getStudyInstanceUID(); break;
            default: break;
        }
        value = IsiXDCMTKCStringData(text);
    });
    return value;
}

- (void)setValue:(const char *)value ofField:(IsiXDCMTKReportField)field
{
    IsiXDCMTKReportCall("HorosSRDocument::set", [&]() {
        HorosSRDocument &document = *_document;
        const OFString text(value ?: "");
        switch (field) {
            case IsiXDCMTKReportFieldAccessionNumber: document.setAccessionNumber(text); break;
            case IsiXDCMTKReportFieldContentDate: document.setContentDate(text); break;
            case IsiXDCMTKReportFieldContentTime: document.setContentTime(text); break;
            case IsiXDCMTKReportFieldInstanceNumber: document.setInstanceNumber(text); break;
            case IsiXDCMTKReportFieldManufacturer: document.setManufacturer(text); break;
            case IsiXDCMTKReportFieldPatientID: document.setPatientID(text); break;
            case IsiXDCMTKReportFieldPatientBirthDate: document.setPatientsBirthDate(text); break;
            case IsiXDCMTKReportFieldPatientName: document.setPatientsName(text); break;
            case IsiXDCMTKReportFieldPatientSex: document.setPatientsSex(text); break;
            case IsiXDCMTKReportFieldReferringPhysicianName: document.setReferringPhysiciansName(text); break;
            case IsiXDCMTKReportFieldSeriesDescription: document.setSeriesDescription(text); break;
            case IsiXDCMTKReportFieldSeriesNumber: document.setSeriesNumber(text); break;
            case IsiXDCMTKReportFieldSpecificCharacterSet: document.setSpecificCharacterSet(text); break;
            case IsiXDCMTKReportFieldStudyDescription: document.setStudyDescription(text); break;
            case IsiXDCMTKReportFieldStudyID: document.setStudyID(text); break;
            default: break;
        }
    });
}

- (BOOL)createNewSeriesInStudy:(NSString *)studyInstanceUID error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "HorosSRDocument::createNewSeriesInStudy", [&]() -> NSError * {
        OFCondition result = _document->createNewSeriesInStudy(studyInstanceUID.UTF8String ?: "");
        return IsiXDCMTKErrorFromCondition(result);
    });
}

- (BOOL)prepareFileWithEncapsulatedDocument:(NSData *)encapsulatedDocument seriesInstanceUID:(NSString *)seriesInstanceUID
                                      error:(NSError **)error
{
    _prepared.reset();
    return IsiXDCMTKGuard(error, "HorosSRDocument::write", [&]() -> NSError * {
        std::unique_ptr<DcmFileFormat> file(new DcmFileFormat());
        DcmDataset *dataset = file->getDataset();
        OFCondition status = EC_Normal;
        // The data the report carries, archived ROIs or the report file.
        if (encapsulatedDocument) {
            const Uint8 *buffer = (const Uint8 *)encapsulatedDocument.bytes;
            if (buffer)
                status = dataset->putAndInsertUint8Array(DCM_EncapsulatedDocument, buffer,
                                                         encapsulatedDocument.length, OFTrue);
        }
        _document->getCodingSchemeIdentification().addPrivateDcmtkCodingScheme();
        if (status.bad()) return IsiXDCMTKErrorFromCondition(status);
        status = _document->write(*dataset);
        if (status.bad()) return IsiXDCMTKErrorFromCondition(status);
        if (seriesInstanceUID)
            status = dataset->putAndInsertString(DCM_SeriesInstanceUID, seriesInstanceUID.UTF8String, OFTrue);
        if (status.bad()) return IsiXDCMTKErrorFromCondition(status);
        _prepared = std::move(file);
        return nil;
    });
}

- (BOOL)writePreparedFileAtomicallyToPath:(NSString *)path
{
    if (!_prepared) return NO;
    DcmFileFormat *prepared = _prepared.get();
    return HorosWriteFileAtomically(path, ^BOOL(NSString *temporary) {
        NSError *failure = nil;
        BOOL saved = IsiXDCMTKGuard(&failure, "DcmFileFormat::saveFile", [&]() -> NSError * {
            const char *fileSystemPath = IsiXDCMTKFileSystemPath(temporary);
            if (!fileSystemPath) return IsiXDCMTKFailure(@"The structured report has no usable path");
            return IsiXDCMTKErrorFromCondition(prepared->saveFile(fileSystemPath, EXS_LittleEndianExplicit));
        });
        if (!saved)
            NSLog(@"Failed to serialize DICOM SR: %@", failure.userInfo[IsiXDCMTKConditionTextKey] ?: failure.localizedDescription);
        return saved;
    });
}

@end

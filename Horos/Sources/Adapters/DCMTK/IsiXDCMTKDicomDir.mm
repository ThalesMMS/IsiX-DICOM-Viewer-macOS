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

#import "IsiXDCMTKDicomDir.h"
#include "IsiXDCMTKInternal.hpp"
#include <dcmtk/dcmdata/dcdicdir.h>
#include <dcmtk/dcmdata/dcdirrec.h>
#include <dcmtk/dcmdata/dcsequen.h>
#include <dcmtk/dcmdata/dcddirif.h>
#include <dcmtk/dcmjpeg/ddpiimpl.h>
#include <dcmtk/ofstd/ofstd.h>
#include "HorosDicomDirIcons.h"
#include <sys/stat.h>
#include <cstring>
#include <map>
#include <set>
#include <vector>

@interface IsiXDCMTKDirectoryIcon ()
@property (readwrite) uint16_t bitsAllocated;
@property (readwrite) uint16_t bitsStored;
@property (readwrite) uint16_t rows;
@property (readwrite) uint16_t columns;
@property (readwrite, copy, nullable) NSString *photometricInterpretation;
@property (readwrite, copy) NSData *pixels;
@end

@implementation IsiXDCMTKDirectoryIcon
@end

@interface IsiXDCMTKDirectoryRecord ()
@property (readwrite, copy) NSDictionary<NSNumber *, id> *values;
@property (readwrite, nullable) IsiXDCMTKDirectoryIcon *icon;
@end

@implementation IsiXDCMTKDirectoryRecord
@end

namespace {

const uint32_t IsiXDCMTKReferencedFileID = 0x00041500;
const uint32_t IsiXDCMTKIconImageSequence = 0x00880200;

// The elements of one record by tag, with the element itself for the icon.
typedef std::map<uint32_t, DcmElement *> RecordElements;

uint32_t TagOf(DcmElement *element)
{
    const DcmTagKey &key = element->getTag();
    return ((uint32_t)key.getGroup() << 16) | key.getElement();
}

IsiXDCMTKDirectoryIcon *IconOf(DcmElement *element)
{
    if (!element || element->ident() != EVR_SQ) return nil;
    DcmSequenceOfItems *sequence = (DcmSequenceOfItems *)element;
    if (sequence->card() != 1) return nil;
    DcmItem *thumb = sequence->getItem(0);
    Uint16 bitsAllocated, bitsStored, rows, columns;
    if (!thumb->findAndGetUint16(DcmTagKey(0x0028, 0x0100), bitsAllocated).good()) return nil;
    if (!thumb->findAndGetUint16(DcmTagKey(0x0028, 0x0101), bitsStored).good()) return nil;
    if (!thumb->findAndGetUint16(DcmTagKey(0x0028, 0x0010), rows).good()) return nil;
    if (!thumb->findAndGetUint16(DcmTagKey(0x0028, 0x0011), columns).good()) return nil;
    const Uint8 *data = NULL;
    unsigned long count = 0;
    if (!thumb->findAndGetUint8Array(DcmTagKey(0x7fe0, 0x0010), data, &count).good() || !data) return nil;
    IsiXDCMTKDirectoryIcon *icon = [[IsiXDCMTKDirectoryIcon alloc] init];
    icon.bitsAllocated = bitsAllocated;
    icon.bitsStored = bitsStored;
    icon.rows = rows;
    icon.columns = columns;
    icon.pixels = [NSData dataWithBytes:data length:count];
    OFString photometric;
    if (thumb->findAndGetOFString(DcmTagKey(0x0028, 0x0004), photometric).good())
        icon.photometricInterpretation = [[NSString alloc] initWithBytes:photometric.c_str()
                                                                  length:strlen(photometric.c_str())
                                                                encoding:NSISOLatin1StringEncoding];
    return icon;
}

id ValueOf(DcmElement *element)
{
    OFString text;
    if (element->getOFStringArray(text).good())
        return [NSData dataWithBytes:text.c_str() length:strlen(text.c_str())];
    return [NSNull null];
}

// Depth first, as the media scan always read a DICOMDIR: a record that names
// a file gives an entry with its own elements over those of the records
// above it, then the records under it are read with it in the context.
void Collect(DcmDirectoryRecord *record, std::vector<RecordElements> &context,
             const std::set<uint32_t> &tags, NSMutableArray<IsiXDCMTKDirectoryRecord *> *records)
{
    RecordElements own;
    for (unsigned long index = 0; index < record->card(); ++index) {
        DcmElement *element = record->getElement(index);
        if (element) own[TagOf(element)] = element;
    }
    context.push_back(own);

    if (own.count(IsiXDCMTKReferencedFileID)) {
        RecordElements merged;
        for (const RecordElements &level : context)
            for (const auto &entry : level)
                merged[entry.first] = entry.second;
        NSMutableDictionary<NSNumber *, id> *values = [NSMutableDictionary dictionary];
        for (const auto &entry : merged)
            if (tags.count(entry.first))
                values[@(entry.first)] = ValueOf(entry.second);
        IsiXDCMTKDirectoryRecord *found = [[IsiXDCMTKDirectoryRecord alloc] init];
        found.values = values;
        auto icon = merged.find(IsiXDCMTKIconImageSequence);
        if (icon != merged.end()) found.icon = IconOf(icon->second);
        [records addObject:found];
    }

    for (unsigned long index = 0; index < record->cardSub(); ++index)
        Collect(record->getSub(index), context, tags, records);
    context.pop_back();
}

} // namespace

@implementation IsiXDCMTKDicomDir

+ (NSArray<IsiXDCMTKDirectoryRecord *> *)fileRecordsOfDicomDirAtPath:(NSString *)path
                                                               tags:(NSArray<NSNumber *> *)tags
                                                              error:(NSError **)error
{
    NSMutableArray<IsiXDCMTKDirectoryRecord *> *records = [NSMutableArray array];
    BOOL read = IsiXDCMTKGuard(error, "DcmDicomDir", [&]() -> NSError * {
        const char *fileSystemPath = path.length ? path.fileSystemRepresentation : NULL;
        if (!fileSystemPath) return IsiXDCMTKFailure(@"The DICOMDIR has no usable path");
        std::set<uint32_t> wanted;
        for (NSNumber *tag in tags) wanted.insert(tag.unsignedIntValue);
        DcmDicomDir dicomdir(fileSystemPath);
        std::vector<RecordElements> context;
        Collect(&dicomdir.getRootRecord(), context, wanted, records);
        return nil;
    });
    return read ? records : nil;
}

+ (BOOL)readRootRecordOfDicomDirAtPath:(NSString *)path error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmDicomDir", [&]() -> NSError * {
        const char *fileSystemPath = IsiXDCMTKFileSystemPath(path);
        if (!fileSystemPath) return IsiXDCMTKFailure(@"The DICOMDIR has no usable path");
        DcmDicomDir dicomdir(fileSystemPath);
        DcmDirectoryRecord &record = dicomdir.getRootRecord();
        for (unsigned long i = 0; i < record.card(); i += 10)
        {
            DcmElement *element = record.getElement(i);
            OFString text;
            if (element) element->getOFStringArray(text);
        }
        return nil;
    });
}

+ (NSArray<NSString *> *)relativePathsOfFilesInFolder:(NSString *)folder error:(NSError **)error
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    BOOL listed = IsiXDCMTKGuard(error, "OFStandard::searchDirectoryRecursively", [&]() -> NSError * {
        const char *root = IsiXDCMTKFileSystemPath(folder);
        if (!root) return IsiXDCMTKFailure(@"The folder has no usable path");
        OFList<OFString> fileNames;
        // The pattern is an OFString, a std::string in this DCMTK: an empty one
        // takes every file, as dcmmkdir +r +id does.
        OFStandard::searchDirectoryRecursively("", fileNames, "", root);
        for (OFListIterator(OFString) iter = fileNames.begin(); iter != fileNames.end(); ++iter)
            if (NSString *relative = [NSString stringWithUTF8String:(*iter).c_str()])
                [paths addObject:relative];
        return nil;
    });
    return listed ? paths : nil;
}

+ (BOOL)writeDicomDirAtPath:(NSString *)path folder:(NSString *)folder
              relativePaths:(NSArray<NSString *> *)relativePaths error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DicomDirInterface", [&]() -> NSError * {
        const char *archive = IsiXDCMTKFileSystemPath(path);
        const char *root = IsiXDCMTKFileSystemPath(folder);
        if (!archive || !root) return IsiXDCMTKFailure(@"The DICOMDIR has no usable path");
        DicomDirInterface ddir;
        ddir.disableConsistencyCheck(); // -W
        ddir.disableTransferSyntaxCheck(); // -Nxc
        ddir.enableInventMode(OFTrue); // +I
        // One icon per series is added below through public directory records.
        ddir.setIconSize(128);
        DicomDirImageImplementation imagePlugin;
        ddir.addImageSupport(&imagePlugin);

        OFCondition result = ddir.createNewDicomDir(DicomDirInterface::AP_USBandFlashJPEG, archive, DEFAULT_FILESETID); // -Pfl
        if (result.bad())
            return IsiXDCMTKErrorFromCondition(result, [NSString stringWithFormat:@"Couldn't create new DICOMDIR file: %s",
                                                        result.text()]);
        ddir.setFilesetDescriptor(NULL, DEFAULT_DESCRIPTOR_CHARSET);
        for (NSString *relative in relativePaths) {
            const char *name = relative.UTF8String;
            result = ddir.addDicomFile(name, root);
            if (result.bad())
                return IsiXDCMTKErrorFromCondition(result, [NSString stringWithFormat:@"Couldn't add %s to DICOMDIR: %s",
                                                            name, result.text()]);
        }
        result = ddir.writeDicomDir(EET_ExplicitLength, EGL_withoutGL);
        if (result.bad())
            return IsiXDCMTKErrorFromCondition(result, [NSString stringWithFormat:@"Couldn't write DICOMDIR file: %s",
                                                        result.text()]);
        HorosDicomDirIcons icons;
        result = icons.addSeriesIcons(archive, root);
        if (result.bad())
            return IsiXDCMTKErrorFromCondition(result, [NSString stringWithFormat:@"Could not write DICOMDIR series icons: %s",
                                                        result.text()]);
        chmod(archive, 0755);
        return nil;
    });
}

@end

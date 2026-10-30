//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// DICOM structured reports through DCMTK's dcmsr (HorosStructuredReportBridge):
// what the database reads of a report file - whether it reads as one, the
// meaning of its document title, and the images it references, each call
// reading the file again - and the documents the app writes. Objective-C and
// C types only, for the bridging header.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

@interface IsiXDCMTKStructuredReportReader : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Whether the file loads and reads as a structured report document.
+ (BOOL)canReadReportAtPath:(NSString *)path error:(NSError **)error;

/// The code meaning of the concept name of the document's current content item
/// once read: its title, which for a key object selection is the kind of
/// selection. nil, with an error, when the file is not a readable report.
+ (nullable NSString *)titleMeaningOfReportAtPath:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(titleMeaning(ofReportAtPath:));

/// The SOP Instance UIDs of the image items, in the order the document tree
/// is iterated. Empty when the file is not a readable report.
+ (NSArray<NSString *> *)referencedImageInstancesOfReportAtPath:(NSString *)path
    NS_SWIFT_NAME(referencedImageInstances(ofReportAtPath:));

@end

/// The kinds of report the app writes.
typedef NS_ENUM(NSInteger, IsiXDCMTKReportType) {
    IsiXDCMTKReportTypeBasicText,
    IsiXDCMTKReportTypeComprehensive,
};

/// The header fields of a report the app reads or sets, as DCMTK's
/// DSRDocument names them.
typedef NS_ENUM(NSInteger, IsiXDCMTKReportField) {
    IsiXDCMTKReportFieldAccessionNumber,
    IsiXDCMTKReportFieldContentDate,
    IsiXDCMTKReportFieldContentTime,
    IsiXDCMTKReportFieldInstanceNumber,
    IsiXDCMTKReportFieldManufacturer,
    IsiXDCMTKReportFieldPatientID,
    IsiXDCMTKReportFieldPatientBirthDate,
    IsiXDCMTKReportFieldPatientName,
    IsiXDCMTKReportFieldPatientSex,
    IsiXDCMTKReportFieldReferringPhysicianName,
    IsiXDCMTKReportFieldSeriesDescription,
    IsiXDCMTKReportFieldSeriesInstanceUID,
    IsiXDCMTKReportFieldSeriesNumber,
    IsiXDCMTKReportFieldSOPClassUID,
    IsiXDCMTKReportFieldSOPInstanceUID,
    IsiXDCMTKReportFieldSpecificCharacterSet,
    IsiXDCMTKReportFieldStudyDescription,
    IsiXDCMTKReportFieldStudyID,
    IsiXDCMTKReportFieldStudyInstanceUID,
};

/// A structured report document held by DCMTK (DSRDocument, through
/// HorosStructuredReportBridge): read from a file or made new, its tree built
/// item by item, its header set, and written. The app assembles the reports
/// it writes (SRAnnotation); this only does what it asks. A C++ exception is
/// logged and reads as a failure, or as nothing read.
@interface IsiXDCMTKStructuredReport : NSObject

/// An empty Basic Text SR document.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// Loads the file at `path` (its UTF-8 path, as the reports have always been
/// opened) and, when it loads, reads it as this document. `loaded` receives
/// whether it loaded; `encapsulatedDocument` the Encapsulated Document
/// (0042,0011) of what was loaded, whether or not the report read, when it
/// has one. Whether both steps succeeded.
- (BOOL)readFileAtPath:(NSString *)path loaded:(nullable BOOL *)loaded
  encapsulatedDocument:(NSData * _Nullable * _Nullable)encapsulatedDocument;

/// The Encapsulated Document (0042,0011) of the file at `path` (UTF-8), or
/// else its OsiriX ROI element (0071,0011), where ROI reports keep their
/// archive; nil when the file does not load or has neither.
+ (nullable NSData *)archivedDataOfFileAtPath:(NSString *)path NS_SWIFT_NAME(archivedData(ofFileAtPath:));

/// Replaces the document with a new one of `type`.
- (void)createNewDocument:(IsiXDCMTKReportType)type;
/// Empties the document tree.
- (void)clearTree;

/// Adds the root container, named by the coded entry.
- (void)addRootContainerWithCode:(NSString *)code scheme:(NSString *)scheme meaning:(NSString *)meaning;
/// Adds a text item the root contains, below the current item, named by the
/// coded entry, with `value` when given.
- (void)addTextWithCode:(NSString *)code scheme:(NSString *)scheme meaning:(NSString *)meaning
                  value:(nullable NSString *)value;
/// Adds an image reference the root contains, below the current item, named
/// by the coded entry, with the frames given as text, and goes back up to
/// the root.
- (void)addImageReferenceWithCode:(NSString *)code scheme:(NSString *)scheme meaning:(NSString *)meaning
                         SOPClass:(NSString *)sopClass instance:(NSString *)instance frames:(nullable NSString *)frames;

/// The current item's concept name meaning, as UTF-8.
@property (readonly, nullable) NSString *currentConceptMeaning;

/// The SOP Instance UID (its bytes) of the image item named by the coded
/// entry, searched from the root through the whole tree; nil when there is none.
- (nullable NSData *)referencedInstanceOfItemWithCode:(NSString *)code scheme:(NSString *)scheme
                                              meaning:(NSString *)meaning;

/// A header field's value, as the bytes DCMTK holds (no terminating NUL).
- (NSData *)valueOfField:(IsiXDCMTKReportField)field;
/// Sets a header field to the C string `value`, bytes as they are; NULL
/// sets it empty.
- (void)setValue:(nullable const char *)value ofField:(IsiXDCMTKReportField)field;

/// Makes the document a new series of the study `studyInstanceUID`, taken as
/// the scanner wrote it (a component with a leading zero included). The
/// condition's text when DCMTK refuses it.
- (BOOL)createNewSeriesInStudy:(NSString *)studyInstanceUID error:(NSError **)error;

/// Builds the file to write: `encapsulatedDocument` when it has bytes, the
/// private DCMTK coding scheme, the document, and `seriesInstanceUID` over
/// the document's when given. Kept for -writePreparedFileToPath:error:.
- (BOOL)prepareFileWithEncapsulatedDocument:(nullable NSData *)encapsulatedDocument
                          seriesInstanceUID:(nullable NSString *)seriesInstanceUID error:(NSError **)error;
/// Writes the prepared file, Explicit VR Little Endian, beside `path` and
/// moves it over `path` once complete (HorosWriteFileAtomically). A failure
/// to serialize is logged.
- (BOOL)writePreparedFileAtomicallyToPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>
#import "DCMObject.h"

NS_ASSUME_NONNULL_BEGIN

/// A DICOM file read by DCMTK and presented through the DCMObject interface.
///
/// DcmFileFormat parses the file; every element becomes the DCMAttribute,
/// DCMSequenceAttribute or DCMCalendarDate value the DCM Framework produced for
/// the same element, so code written against DCMObject reads it unchanged. The
/// Pixel Data attribute decodes frames through the DCMTK codecs the host
/// registers (RLE, JPEG, JPEG-LS, JPEG 2000) and keeps the frame layout
/// -decodeFrameAtIndex: always returned: host byte order, samples interleaved,
/// YBR and palette colour converted to RGB.
///
/// It is also what DCM.framework hands out when a plugin reads a file through
/// DCMObject: the facade has no parser of its own and forwards here.
/// Edits made through the DCMObject interface stay in memory until the object
/// is written, which HorosDICOMWriter does through DCMTK.
@interface HorosDCMTKObject : DCMObject

/// Nil when DCMTK cannot read the file.
+ (nullable instancetype)objectWithContentsOfFile:(NSString *)path;

/// What -[DCMObject initWithContentsOfFile:decodingPixelData:] and
/// DCMLimitedObject forward to. `decodePixelData` decodes every frame at load,
/// as the DCM Framework did; `lastGroup` stops reading after that group
/// (0xFFFF reads everything).
+ (nullable instancetype)objectWithContentsOfFile:(NSString *)path decodingPixelData:(BOOL)decodePixelData
                                        lastGroup:(unsigned short)lastGroup;
/// The same for bytes in memory: a file, with or without preamble and meta
/// header, or a bare dataset in `transferSyntax` when that is given.
+ (nullable instancetype)objectWithData:(NSData *)data transferSyntax:(nullable NSString *)transferSyntax
                      decodingPixelData:(BOOL)decodePixelData lastGroup:(unsigned short)lastGroup;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
#include <memory>
class DcmFileFormat;

@interface HorosDCMTKObject (DCMTKFile)
/// A view of a DcmFileFormat already in memory, which the object keeps alive.
+ (nonnull instancetype)objectWithDCMTKFile:(std::shared_ptr<DcmFileFormat>)file;
@end
#endif

#import <Foundation/Foundation.h>
#import "DCMModel.h"

@class IsiXDCMTKFile;

NS_ASSUME_NONNULL_BEGIN

/// The DICOM reader of the dataset model: DCMTK parses a file, and every
/// element becomes the DCMAttribute, DCMSequenceAttribute or date value the
/// DCM Framework produced for the same element, so code written against
/// DCMObject reads it unchanged. The Pixel Data attribute keeps the parsed
/// file as its frame source (HorosDCMTKFrameSource): frames decode through the
/// DCMTK codecs the host registers (RLE, JPEG, JPEG-LS, JPEG 2000), and the
/// attribute gives them the layout -decodeFrameAtIndex: always returned: host
/// byte order, samples interleaved, YBR and palette colour converted to RGB.
///
/// +[DCMObject objectWithContentsOfFile:] and the other reading messages of
/// the IsiXDICOMDataset module find this class by name (IsiXDCMReading). Edits
/// made through the DCMObject stay in memory until the object is written,
/// which IsiXDCMTKObjectWriter does through DCMTK.
///
/// It is part of the DCMTK adapters; the application and the Decompress
/// service both compile it, and the dataset model finds it by name. Every call into
/// DCMTK is guarded; a C++ exception is logged and reads as a file DCMTK cannot
/// read, or a frame it cannot decode.
@interface HorosDCMTKObject : NSObject

/// Nil when DCMTK cannot read the file.
+ (nullable DCMObject *)objectWithContentsOfFile:(NSString *)path;

/// What +[DCMObject objectWithContentsOfFile:decodingPixelData:] forwards to.
/// `decodePixelData` decodes every frame at load, as the DCM Framework did;
/// `lastGroup` stops reading after that group (0xFFFF reads everything).
+ (nullable DCMObject *)objectWithContentsOfFile:(NSString *)path decodingPixelData:(BOOL)decodePixelData
                                       lastGroup:(unsigned short)lastGroup;
/// The same for bytes in memory: a file, with or without preamble and meta
/// header, or a bare dataset in `transferSyntax` when that is given.
+ (nullable DCMObject *)objectWithData:(NSData *)data transferSyntax:(nullable NSString *)transferSyntax
                     decodingPixelData:(BOOL)decodePixelData lastGroup:(unsigned short)lastGroup;
/// A view of a file already in memory, which the object's pixel data keeps alive.
+ (nullable DCMObject *)objectWithFile:(IsiXDCMTKFile *)file;

@end

NS_ASSUME_NONNULL_END

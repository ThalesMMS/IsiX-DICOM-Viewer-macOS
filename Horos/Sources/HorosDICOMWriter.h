#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A DICOM object built and written by DCMTK, for the places that used
/// to assemble a DCMObject and let the DCM Framework write it.
///
/// Attributes are named the way DCMAttributeTag names them ("PatientsName",
/// "SamplesperPixel") and resolved through the host's DCMTK dictionaries.
/// Values are NSString, NSNumber or DCMCalendarDate, formatted for the
/// element's VR; an empty array writes an empty element. Text is written in
/// UTF-8 and Specific Character Set says ISO_IR 192.
@interface HorosDICOMWriter : NSObject

/// A new UID under the site root DCMTK uses for the host's other objects.
/// These MRC factories return autoreleased strings (+0), despite the new prefix.
+ (NSString *)newStudyInstanceUID NS_RETURNS_NOT_RETAINED;
+ (NSString *)newSeriesInstanceUID NS_RETURNS_NOT_RETAINED;
+ (NSString *)newSOPInstanceUID NS_RETURNS_NOT_RETAINED;

/// Sets or replaces an attribute; NO when the name is unknown.
- (BOOL)setValues:(NSArray *)values forName:(NSString *)name;
/// The values last set for a name, or nil.
- (nullable NSArray *)valuesForName:(NSString *)name;
/// Binary value (EncapsulatedDocument, PixelData); `vr` is "OB" or "OW".
- (BOOL)setData:(NSData *)data forName:(NSString *)name vr:(NSString *)vr;
/// An empty sequence.
- (BOOL)setEmptySequenceForName:(NSString *)name;

/// Writes the object with a file meta header in the given syntax (a native one).
- (BOOL)writeToFile:(NSString *)path transferSyntax:(NSString *)transferSyntaxUID;

@end

@class DCMObject;

/// Where DCM.framework sends DCMObject writing: the facade has no writer
/// of its own. The object's attributes become a DcmDataset by tag and value
/// representation - sequences, pixel data native or encapsulated, private
/// elements included - and DCMTK changes the pixel encoding and writes it.
///
/// Text keeps the Specific Character Set it declares when every value can be
/// written in it; otherwise, or when it declares several, the object is written
/// in UTF-8 as ISO_IR 192. `quality` is a DCM_CompressionQuality (0 lossless).
@interface HorosDICOMWriter (DCMObject)

/// A file with meta header; nil `transferSyntaxUID` keeps the object's own.
+ (BOOL)writeObject:(DCMObject *)object toFile:(NSString *)path transferSyntax:(nullable NSString *)transferSyntaxUID
            quality:(int)quality AET:(nullable NSString *)aet;
/// The dataset alone, as it is sent over the network.
+ (nullable NSData *)datasetOfObject:(DCMObject *)object transferSyntax:(nullable NSString *)transferSyntaxUID
                             quality:(int)quality;
/// The object with its pixel data in another syntax, read back as a new object.
+ (nullable DCMObject *)objectByConvertingObject:(DCMObject *)object toTransferSyntax:(NSString *)transferSyntaxUID
                                         quality:(int)quality;

@end

/// A Part 10 file written again in another transfer syntax, for a
/// DICOMweb node whose Send Syntax is not "As stored". The pixel data goes
/// through the codecs the host registers (HorosChooseDICOMRepresentation);
/// lossy syntaxes use high quality. `destination` appears only once complete.
@interface HorosDICOMWriter (Transcoding)

+ (BOOL)transcodeFileAtPath:(NSString *)source toPath:(NSString *)destination
             transferSyntax:(NSString *)transferSyntaxUID error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A DICOM object built and written by DCMTK, for the places that used
/// to assemble a DCMObject and let the DCM Framework write it. A DCMObject
/// itself is written by the DCMTK adapter (IsiXDCMTKObjectWriter).
///
/// Attributes are named the way IsiXDICOMAttributeTag names them ("PatientsName",
/// "SamplesperPixel") and resolved through the host's DCMTK dictionaries.
/// Values are NSString, NSNumber or DCMCalendarDate, formatted for the
/// element's VR; an empty array writes an empty element. Text is written in
/// UTF-8 and Specific Character Set says ISO_IR 192.
@interface HorosDICOMWriter : NSObject

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

/// A new UID under the site root DCMTK uses for the host's other objects.
/// These factories return autoreleased strings (+0), despite the new prefix.
/// They are Objective-C (IsiXDCMTKObjectWriter.mm): a Swift implementation of
/// a selector of the new family returns +1 whatever the declaration says.
@interface HorosDICOMWriter (Identifiers)

+ (NSString *)newStudyInstanceUID NS_RETURNS_NOT_RETAINED;
+ (NSString *)newSeriesInstanceUID NS_RETURNS_NOT_RETAINED;
+ (NSString *)newSOPInstanceUID NS_RETURNS_NOT_RETAINED;

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

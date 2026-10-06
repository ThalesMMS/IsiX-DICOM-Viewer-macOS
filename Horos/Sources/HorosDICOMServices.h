#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// DICOM metadata conversions on DCMTK for the DCM Framework's facade classes.
// Compiled into the application and Decompress; DCMTransferSyntax and
// DCMCalendarDate find these classes by name and use them when present.

/// Transfer syntax properties from DcmXfer.
@interface HorosDICOMTransferSyntaxes : NSObject
/// {isEncapsulated, isLittleEndian, isExplicit, Name} for a UID DCMTK knows, nil otherwise.
/// Name keeps the DCM Framework's spelling for the syntaxes it named.
+ (nullable NSDictionary<NSString *, id> *)propertiesForTransferSyntax:(NSString *)uid;
@end

/// DA, TM and DT values parsed by DCMTK, returned as canonical strings for
/// NSCalendarDate: "YYYYMMDD", "HHMMSS" and "YYYYMMDDHHMMSS". Nil where DCMTK
/// does not read the value.
@interface HorosDICOMDates : NSObject
+ (nullable NSString *)canonicalDate:(NSString *)dicomDate;
+ (nullable NSString *)canonicalTime:(NSString *)dicomTime microseconds:(unsigned long *)microseconds;
/// `timeZoneSeconds` is set only when the value states an offset, and then `hasTimeZone` is YES.
+ (nullable NSString *)canonicalDateTime:(NSString *)dicomDateTime microseconds:(unsigned long *)microseconds
                         timeZoneSeconds:(NSInteger *)timeZoneSeconds hasTimeZone:(BOOL *)hasTimeZone;
@end

/// Text decoded under a Specific Character Set by DCMTK (oficonv), to UTF-8.
@interface HorosDICOMCharacterSets : NSObject
/// Nil when DCMTK does not know the character set or cannot convert the bytes.
+ (nullable NSString *)stringWithBytes:(const char *)bytes length:(NSUInteger)length
                          characterSet:(nullable NSString *)specificCharacterSet;
@end

NS_ASSUME_NONNULL_END

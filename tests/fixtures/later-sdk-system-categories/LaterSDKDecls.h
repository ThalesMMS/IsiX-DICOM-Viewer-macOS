#import <AppKit/AppKit.h>
#import <compression.h>
typedef NSInteger TextAlignment;

@protocol LaterSDKProbe_NSString
- (NSString*)stringAfterString:(NSString*)a0;
- (NSString*)stringBetweenString:(NSString*)a0 andString:(NSString*)a1;
- (NSArray*)stringsBetweenString:(NSString*)a0 andString:(NSString*)a1;
- (NSString*)stringByDeletingPrefix:(NSString*)a0;
- (NSString*)stringByDeletingSuffix:(NSString*)a0;
- (NSString*)stringByRemovingCombiningMarks;
- (NSString*)withoutWhitespaceSequences;
- (NSString*)sanitizeFileName;
- (NSString*)sha1;
- (NSString*)urlDecodedString;
- (BOOL)validURL;
- (NSString*)quotedPrintableString;
- (NSString*)numberToSuperscript;
+ (NSString*)randomStringWithLength:(int)a0;
+ (id)stringWithData:(NSData*)a0;
+ (NSString*)timeString:(NSTimeInterval)a0 maxUnits:(NSInteger)a1 abbreviated:(BOOL)a2;
- (NSSize)sizeOfStringWithFont:(NSFont*)a0;
- (void)drawStringInRect:(CGRect)a0 withAttributes:(NSDictionary*)a1 alignment:(TextAlignment)a2;
@end
@interface NSString (LaterSDKProbe)
- (NSString*)stringAfterString:(NSString*)a0;
- (NSString*)stringBetweenString:(NSString*)a0 andString:(NSString*)a1;
- (NSArray*)stringsBetweenString:(NSString*)a0 andString:(NSString*)a1;
- (NSString*)stringByDeletingPrefix:(NSString*)a0;
- (NSString*)stringByDeletingSuffix:(NSString*)a0;
- (NSString*)stringByRemovingCombiningMarks;
- (NSString*)withoutWhitespaceSequences;
- (NSString*)sanitizeFileName;
- (NSString*)sha1;
- (NSString*)urlDecodedString;
- (BOOL)validURL;
- (NSString*)quotedPrintableString;
- (NSString*)numberToSuperscript;
+ (NSString*)randomStringWithLength:(int)a0;
+ (id)stringWithData:(NSData*)a0;
+ (NSString*)timeString:(NSTimeInterval)a0 maxUnits:(NSInteger)a1 abbreviated:(BOOL)a2;
- (NSSize)sizeOfStringWithFont:(NSFont*)a0;
- (void)drawStringInRect:(CGRect)a0 withAttributes:(NSDictionary*)a1 alignment:(TextAlignment)a2;
@end

@protocol LaterSDKProbe_NSArray
- (NSArray*)arrayByRemovingDuplicates;
- (NSArray*)arrayByRemovingFirstObject;
- (NSArray*)arrayByRemovingLastObject;
- (NSArray*)arrayByRemovingObject:(id)a0;
- (NSArray*)arrayByRemovingObjectAtIndex:(NSUInteger)a0;
- (NSArray*)arrayByRemovingObjectFirstOccurenceOf:(id)a0;
- (NSArray*)arrayByRemovingObjectsFromArray:(NSArray*)a0;
- (NSUInteger)indexOfSmallestValue;
- (BOOL)intersectArray:(NSArray*)a0;
- (NSArray*)intersectionArray:(NSArray*)a0;
- (NSNumber*)medianNumberFromNumbersArray;
- (id)randomObject;
- (NSArray*)randomizedArray;
- (NSString*)arrayAsString;
+ (NSArray*)arrayFromString:(NSString*)a0;
- (NSString*)arrayAsJSONwithOptions:(NSJSONWritingOptions)a0;
+ (NSArray*)arrayFromJSON:(NSString*)a0 withOptions:(NSJSONReadingOptions)a1;
@end
@interface NSArray (LaterSDKProbe)
- (NSArray*)arrayByRemovingDuplicates;
- (NSArray*)arrayByRemovingFirstObject;
- (NSArray*)arrayByRemovingLastObject;
- (NSArray*)arrayByRemovingObject:(id)a0;
- (NSArray*)arrayByRemovingObjectAtIndex:(NSUInteger)a0;
- (NSArray*)arrayByRemovingObjectFirstOccurenceOf:(id)a0;
- (NSArray*)arrayByRemovingObjectsFromArray:(NSArray*)a0;
- (NSUInteger)indexOfSmallestValue;
- (BOOL)intersectArray:(NSArray*)a0;
- (NSArray*)intersectionArray:(NSArray*)a0;
- (NSNumber*)medianNumberFromNumbersArray;
- (id)randomObject;
- (NSArray*)randomizedArray;
- (NSString*)arrayAsString;
+ (NSArray*)arrayFromString:(NSString*)a0;
- (NSString*)arrayAsJSONwithOptions:(NSJSONWritingOptions)a0;
+ (NSArray*)arrayFromJSON:(NSString*)a0 withOptions:(NSJSONReadingOptions)a1;
@end

@protocol LaterSDKProbe_NSMutableArray
- (void)addObjectIfNotNil:(id)a0;
- (void)addString:(NSString*)a0;
- (void)replaceLasObjectWith:(id)a0;
@end
@interface NSMutableArray (LaterSDKProbe)
- (void)addObjectIfNotNil:(id)a0;
- (void)addString:(NSString*)a0;
- (void)replaceLasObjectWith:(id)a0;
@end

@protocol LaterSDKProbe_NSDictionary
- (NSDictionary*)dictionaryByAddingDictionary:(NSDictionary*)a0;
- (NSDictionary*)dictionaryByAddingObject:(id)a0 forKey:(id)a1;
- (NSDictionary*)dictionaryByRemovingKey:(id)a0;
- (NSDictionary*)dictionaryByRemovingKeysWithPrefix:(NSString*)a0;
- (id)objectForCaseInsensitiveKey:(NSString*)a0;
- (NSString*)dictionaryAsString;
+ (NSDictionary*)dictionaryFromString:(NSString*)a0;
- (NSString*)dictionaryAsJSONwithOptions:(NSJSONWritingOptions)a0;
+ (NSDictionary*)dictionaryFromJSON:(NSString*)a0 withOptions:(NSJSONReadingOptions)a1;
@end
@interface NSDictionary (LaterSDKProbe)
- (NSDictionary*)dictionaryByAddingDictionary:(NSDictionary*)a0;
- (NSDictionary*)dictionaryByAddingObject:(id)a0 forKey:(id)a1;
- (NSDictionary*)dictionaryByRemovingKey:(id)a0;
- (NSDictionary*)dictionaryByRemovingKeysWithPrefix:(NSString*)a0;
- (id)objectForCaseInsensitiveKey:(NSString*)a0;
- (NSString*)dictionaryAsString;
+ (NSDictionary*)dictionaryFromString:(NSString*)a0;
- (NSString*)dictionaryAsJSONwithOptions:(NSJSONWritingOptions)a0;
+ (NSDictionary*)dictionaryFromJSON:(NSString*)a0 withOptions:(NSJSONReadingOptions)a1;
@end

@protocol LaterSDKProbe_NSMutableDictionary
- (void)changeKeyFrom:(NSString*)a0 to:(NSString*)a1;
- (void)setObjectIfNonNil:(id)a0 forKey:(NSString*)a1;
@end
@interface NSMutableDictionary (LaterSDKProbe)
- (void)changeKeyFrom:(NSString*)a0 to:(NSString*)a1;
- (void)setObjectIfNonNil:(id)a0 forKey:(NSString*)a1;
@end

@protocol LaterSDKProbe_NSSet
- (NSArray*)array;
@end
@interface NSSet (LaterSDKProbe)
- (NSArray*)array;
@end

@protocol LaterSDKProbe_NSOrderedSet
- (id)anyObject;
@end
@interface NSOrderedSet (LaterSDKProbe)
- (id)anyObject;
@end

@protocol LaterSDKProbe_NSData
- (NSString*)base64Encoded;
- (NSData*)base64Decoded;
- (NSString*)encodeBase64;
- (NSString*)encodeBase64WithNewlines:(BOOL)a0;
- (NSData*)decodeBase64;
- (NSData*)decodeBase64WithNewLines:(BOOL)a0;
- (NSString*)hexStringValue;
- (NSString*)hexval;
- (NSString*)hexdump;
- (NSData*)md5Digest;
- (NSData*)sha1Digest;
- (NSString*)dataAsStringWithEncoding:(NSStringEncoding)a0;
- (NSData*)compressDataWithAlgorithm:(compression_algorithm)a0;
- (void*)decompressDataWithDestinationSize:(size_t)a0 algorithm:(compression_algorithm)a1;
+ (NSData*)dataWithFirstBytes:(unsigned long)a0 ofFile:(NSString*)a1;
+ (NSData*)dataWithLong:(unsigned long)a0;
+ (NSData*)dataWithShort:(unsigned short)a0;
+ (NSDictionary*)headerValuesFromString:(NSString*)a0;
@end
@interface NSData (LaterSDKProbe)
- (NSString*)base64Encoded;
- (NSData*)base64Decoded;
- (NSString*)encodeBase64;
- (NSString*)encodeBase64WithNewlines:(BOOL)a0;
- (NSData*)decodeBase64;
- (NSData*)decodeBase64WithNewLines:(BOOL)a0;
- (NSString*)hexStringValue;
- (NSString*)hexval;
- (NSString*)hexdump;
- (NSData*)md5Digest;
- (NSData*)sha1Digest;
- (NSString*)dataAsStringWithEncoding:(NSStringEncoding)a0;
- (NSData*)compressDataWithAlgorithm:(compression_algorithm)a0;
- (void*)decompressDataWithDestinationSize:(size_t)a0 algorithm:(compression_algorithm)a1;
+ (NSData*)dataWithFirstBytes:(unsigned long)a0 ofFile:(NSString*)a1;
+ (NSData*)dataWithLong:(unsigned long)a0;
+ (NSData*)dataWithShort:(unsigned short)a0;
+ (NSDictionary*)headerValuesFromString:(NSString*)a0;
@end

@protocol LaterSDKProbe_NSDate
- (NSString*)javaScriptDate;
- (NSString*)javaScriptDateTime;
+ (NSDate*)dateWithJavaScriptDate:(NSString*)a0;
+ (NSDate*)dateWithJavaScriptDateTime:(NSString*)a0;
- (NSString*)rfc1123String;
- (NSDateComponents*)differenceWithDate:(NSDate*)a0;
- (NSString*)dateAsStringWithCalendarFormat:(NSString*)a0;
+ (id)dateWithString:(NSString*)a0 calendarFormat:(NSString*)a1;
+ (id)dateWithString:(NSString*)a0 calendarFormat:(NSString*)a1 error:(BOOL*)a2;
@end
@interface NSDate (LaterSDKProbe)
- (NSString*)javaScriptDate;
- (NSString*)javaScriptDateTime;
+ (NSDate*)dateWithJavaScriptDate:(NSString*)a0;
+ (NSDate*)dateWithJavaScriptDateTime:(NSString*)a0;
- (NSString*)rfc1123String;
- (NSDateComponents*)differenceWithDate:(NSDate*)a0;
- (NSString*)dateAsStringWithCalendarFormat:(NSString*)a0;
+ (id)dateWithString:(NSString*)a0 calendarFormat:(NSString*)a1;
+ (id)dateWithString:(NSString*)a0 calendarFormat:(NSString*)a1 error:(BOOL*)a2;
@end

@protocol LaterSDKProbe_NSNumber
+ (BOOL)parseString:(NSString*)a0 intoNSInteger:(NSInteger*)a1;
+ (BOOL)parseString:(NSString*)a0 intoNSUInteger:(NSUInteger*)a1;
+ (BOOL)parseString:(NSString*)a0 intoSInt64:(SInt64*)a1;
+ (BOOL)parseString:(NSString*)a0 intoUInt64:(UInt64*)a1;
@end
@interface NSNumber (LaterSDKProbe)
+ (BOOL)parseString:(NSString*)a0 intoNSInteger:(NSInteger*)a1;
+ (BOOL)parseString:(NSString*)a0 intoNSUInteger:(NSUInteger*)a1;
+ (BOOL)parseString:(NSString*)a0 intoSInt64:(SInt64*)a1;
+ (BOOL)parseString:(NSString*)a0 intoUInt64:(UInt64*)a1;
@end

@protocol LaterSDKProbe_NSURL
- (NSDictionary*)queryItems;
- (NSURL*)URLByAppendingQueryParameters:(NSDictionary*)a0;
- (NSURL*)URLByRemovingQueryParameters:(NSArray*)a0;
@end
@interface NSURL (LaterSDKProbe)
- (NSDictionary*)queryItems;
- (NSURL*)URLByAppendingQueryParameters:(NSDictionary*)a0;
- (NSURL*)URLByRemovingQueryParameters:(NSArray*)a0;
@end

@protocol LaterSDKProbe_NSNotificationCenter
- (void)addUniqueObserver:(id)a0 selector:(SEL)a1 name:(NSNotificationName)a2 object:(id)a3;
@end
@interface NSNotificationCenter (LaterSDKProbe)
- (void)addUniqueObserver:(id)a0 selector:(SEL)a1 name:(NSNotificationName)a2 object:(id)a3;
@end

@protocol LaterSDKProbe_NSThread
- (NSInteger)getThreadNum;
@end
@interface NSThread (LaterSDKProbe)
- (NSInteger)getThreadNum;
@end

@protocol LaterSDKProbe_NSObject
- (void)OsiriXPerformSelectorOnMainThread:(SEL)a0 withObject:(id)a1 waitUntilDone:(BOOL)a2;
- (void)OsiriXPerformSelectorOnMainThread:(SEL)a0 withObject:(id)a1 rootCallStack:(BOOL)a2;
- (void)OsiriXPerformSelectorOnMainThread:(SEL)a0 withObject:(id)a1 afterDelay:(float)a2;
- (void)OsiriXPerformSelectorOnMainThread:(SEL)a0 withObject:(id)a1 rootCallStack:(BOOL)a2 afterDelay:(float)a3;
@end
@interface NSObject (LaterSDKProbe)
- (void)OsiriXPerformSelectorOnMainThread:(SEL)a0 withObject:(id)a1 waitUntilDone:(BOOL)a2;
- (void)OsiriXPerformSelectorOnMainThread:(SEL)a0 withObject:(id)a1 rootCallStack:(BOOL)a2;
- (void)OsiriXPerformSelectorOnMainThread:(SEL)a0 withObject:(id)a1 afterDelay:(float)a2;
- (void)OsiriXPerformSelectorOnMainThread:(SEL)a0 withObject:(id)a1 rootCallStack:(BOOL)a2 afterDelay:(float)a3;
@end

@protocol LaterSDKProbe_NSFileManager
- (NSString*)confirmDirectoryAtPath:(NSString*)a0 createIntermediateDirectories:(BOOL)a1;
- (unsigned long long)fileSize:(NSString*)a0;
- (unsigned long long)folderSize:(NSString*)a0;
- (unsigned long)countFolderItemsForPath:(NSString*)a0;
- (unsigned long)crc32ForPath:(NSString*)a0;
- (NSArray*)filesWithExtension:(NSString*)a0 inDirectory:(NSString*)a1;
- (NSArray*)filesWithExtensions:(NSArray*)a0 inDirectory:(NSString*)a1;
- (BOOL)removeContentOfDirectoryAtPath:(NSString*)a0;
- (BOOL)removeItemsWithPrefix:(NSString*)a0 error:(NSError**)a1;
- (BOOL)testWritingPermission:(NSString*)a0 error:(NSError**)a1;
- (void)correctWritingPermissionForDirectory:(NSString*)a0 error:(NSError**)a1;
- (BOOL)correctWritingPermissionForFile:(NSString*)a0;
- (BOOL)getTotalSize:(unsigned long long*)a0 andFreeSize:(unsigned long long*)a1 forPath:(NSString*)a2;
- (NSString*)tmpFilePathInDir:(NSString*)a0 withExtension:(NSString*)a1;
- (NSString*)tmpFilePathInTmpWithExtension:(NSString*)a0;
- (NSString*)tmpFilePathInTmpWithName:(NSString*)a0;
- (NSString*)userApplicationSupportFolderForApp:(NSString*)a0;
@end
@interface NSFileManager (LaterSDKProbe)
- (NSString*)confirmDirectoryAtPath:(NSString*)a0 createIntermediateDirectories:(BOOL)a1;
- (unsigned long long)fileSize:(NSString*)a0;
- (unsigned long long)folderSize:(NSString*)a0;
- (unsigned long)countFolderItemsForPath:(NSString*)a0;
- (unsigned long)crc32ForPath:(NSString*)a0;
- (NSArray*)filesWithExtension:(NSString*)a0 inDirectory:(NSString*)a1;
- (NSArray*)filesWithExtensions:(NSArray*)a0 inDirectory:(NSString*)a1;
- (BOOL)removeContentOfDirectoryAtPath:(NSString*)a0;
- (BOOL)removeItemsWithPrefix:(NSString*)a0 error:(NSError**)a1;
- (BOOL)testWritingPermission:(NSString*)a0 error:(NSError**)a1;
- (void)correctWritingPermissionForDirectory:(NSString*)a0 error:(NSError**)a1;
- (BOOL)correctWritingPermissionForFile:(NSString*)a0;
- (BOOL)getTotalSize:(unsigned long long*)a0 andFreeSize:(unsigned long long*)a1 forPath:(NSString*)a2;
- (NSString*)tmpFilePathInDir:(NSString*)a0 withExtension:(NSString*)a1;
- (NSString*)tmpFilePathInTmpWithExtension:(NSString*)a0;
- (NSString*)tmpFilePathInTmpWithName:(NSString*)a0;
- (NSString*)userApplicationSupportFolderForApp:(NSString*)a0;
@end

@protocol LaterSDKProbe_NSImage
- (NSBitmapImageRep*)bitmapImageRepresentation;
- (NSBitmapImageRep*)bitmapImageRepresentationWithBitsPerSample:(int)a0 andBitsPerPixel:(int)a1;
- (NSBitmapImageRep*)bitmapImageRepresentationWithBitsPerSample:(int)a0 andBitsPerPixel:(int)a1 scalingFactor:(float)a2;
- (NSBitmapImageRep*)bitmapImageRepresentationWithBitsPerSample:(int)a0 andBitsPerPixel:(int)a1 scalingFactor:(float)a2 alphaFirst:(BOOL)a3;
- (NSBitmapImageRep*)resizedImageRepresentationToPixelDimensions:(NSSize)a0;
- (NSData*)getDataOfType:(NSBitmapImageFileType)a0 compressionFactor:(float)a1;
- (NSData*)JPEGRepresentation;
- (NSData*)PDFRepresentation;
- (NSImage*)crop:(NSRect)a0;
- (NSImage*)flipImageX:(BOOL)a0 Y:(BOOL)a1;
- (NSImage*)rotateBy:(float)a0;
- (NSImage*)imageByScalingToSize:(NSSize)a0 retinaSupport:(BOOL)a1 proportionally:(BOOL)a2;
- (NSImage*)imageByScalingProportionallyToSize:(NSSize)a0 retinaSupport:(BOOL)a1;
- (NSImage*)imageByScalingProportionallyToMaxSizeUsingNSImage:(NSSize)a0;
- (NSImage*)imageWithOpaqueBackgroundColor:(NSColor*)a0;
- (NSImage*)imageWithShadowOffset:(NSSize)a0 blur:(float)a1 color:(NSColor*)a2;
+ (float)backingScaleNSImage;
+ (NSImage*)imageWithPreviewOfFileAtPath:(NSString*)a0 ofSize:(NSSize)a1;
@end
@interface NSImage (LaterSDKProbe)
- (NSBitmapImageRep*)bitmapImageRepresentation;
- (NSBitmapImageRep*)bitmapImageRepresentationWithBitsPerSample:(int)a0 andBitsPerPixel:(int)a1;
- (NSBitmapImageRep*)bitmapImageRepresentationWithBitsPerSample:(int)a0 andBitsPerPixel:(int)a1 scalingFactor:(float)a2;
- (NSBitmapImageRep*)bitmapImageRepresentationWithBitsPerSample:(int)a0 andBitsPerPixel:(int)a1 scalingFactor:(float)a2 alphaFirst:(BOOL)a3;
- (NSBitmapImageRep*)resizedImageRepresentationToPixelDimensions:(NSSize)a0;
- (NSData*)getDataOfType:(NSBitmapImageFileType)a0 compressionFactor:(float)a1;
- (NSData*)JPEGRepresentation;
- (NSData*)PDFRepresentation;
- (NSImage*)crop:(NSRect)a0;
- (NSImage*)flipImageX:(BOOL)a0 Y:(BOOL)a1;
- (NSImage*)rotateBy:(float)a0;
- (NSImage*)imageByScalingToSize:(NSSize)a0 retinaSupport:(BOOL)a1 proportionally:(BOOL)a2;
- (NSImage*)imageByScalingProportionallyToSize:(NSSize)a0 retinaSupport:(BOOL)a1;
- (NSImage*)imageByScalingProportionallyToMaxSizeUsingNSImage:(NSSize)a0;
- (NSImage*)imageWithOpaqueBackgroundColor:(NSColor*)a0;
- (NSImage*)imageWithShadowOffset:(NSSize)a0 blur:(float)a1 color:(NSColor*)a2;
+ (float)backingScaleNSImage;
+ (NSImage*)imageWithPreviewOfFileAtPath:(NSString*)a0 ofSize:(NSSize)a1;
@end

@protocol LaterSDKProbe_NSColor
- (NSString*)hexadecimalValue;
- (NSString*)rgbaCSSValue;
- (NSColor*)inverted;
- (NSColor*)oppsite;
+ (NSColor*)colorFromHexString:(NSString*)a0;
@end
@interface NSColor (LaterSDKProbe)
- (NSString*)hexadecimalValue;
- (NSString*)rgbaCSSValue;
- (NSColor*)inverted;
- (NSColor*)oppsite;
+ (NSColor*)colorFromHexString:(NSString*)a0;
@end

@protocol LaterSDKProbe_NSView
- (NSImage*)screenCapture;
@end
@interface NSView (LaterSDKProbe)
- (NSImage*)screenCapture;
@end

@protocol LaterSDKProbe_NSWindow
- (BOOL)isDarkMode;
@end
@interface NSWindow (LaterSDKProbe)
- (BOOL)isDarkMode;
@end

static inline NSArray<Protocol *> *LaterSDKProbeProtocols(void) {
    return @[@protocol(LaterSDKProbe_NSString), @protocol(LaterSDKProbe_NSArray), @protocol(LaterSDKProbe_NSMutableArray), @protocol(LaterSDKProbe_NSDictionary), @protocol(LaterSDKProbe_NSMutableDictionary), @protocol(LaterSDKProbe_NSSet), @protocol(LaterSDKProbe_NSOrderedSet), @protocol(LaterSDKProbe_NSData), @protocol(LaterSDKProbe_NSDate), @protocol(LaterSDKProbe_NSNumber), @protocol(LaterSDKProbe_NSURL), @protocol(LaterSDKProbe_NSNotificationCenter), @protocol(LaterSDKProbe_NSThread), @protocol(LaterSDKProbe_NSObject), @protocol(LaterSDKProbe_NSFileManager), @protocol(LaterSDKProbe_NSImage), @protocol(LaterSDKProbe_NSColor), @protocol(LaterSDKProbe_NSView), @protocol(LaterSDKProbe_NSWindow)];
}

// The host services DCM.framework forwards to (#742). The framework has no DICOM
// parser, writer or codec of its own: the application (and the Decompress
// helper) provide these classes, found by name at run time, on DCMTK.
//
// HorosDCMTKObject reads; HorosDICOMWriter writes and changes pixel encodings.

#import <Foundation/Foundation.h>

@class DCMObject;

@interface NSObject (DCMHostServices)
+ (id)objectWithContentsOfFile:(NSString *)path decodingPixelData:(BOOL)decodePixelData lastGroup:(unsigned short)lastGroup;
+ (id)objectWithData:(NSData *)data transferSyntax:(NSString *)transferSyntax decodingPixelData:(BOOL)decodePixelData lastGroup:(unsigned short)lastGroup;
+ (BOOL)writeObject:(DCMObject *)object toFile:(NSString *)path transferSyntax:(NSString *)transferSyntax quality:(int)quality AET:(NSString *)aet;
+ (NSData *)datasetOfObject:(DCMObject *)object transferSyntax:(NSString *)transferSyntax quality:(int)quality;
+ (DCMObject *)objectByConvertingObject:(DCMObject *)object toTransferSyntax:(NSString *)transferSyntax quality:(int)quality;
@end

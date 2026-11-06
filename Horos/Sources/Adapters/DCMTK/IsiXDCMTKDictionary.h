//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The DICOM data dictionary DCMTK loaded: the dicom.dic the process ships laid
// over it, the keyword and the value representation of a tag, the tag of a
// standard keyword, its public attributes, and the two dictionaries the dataset
// model and the IsiXDICOMFile tags name attributes with. Objective-C and C types only, as every header of
// Adapters/DCMTK. Compiled into the application and into the Decompress service.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Lays a dicom.dic over the process dictionary DCMTK compiles in: whether it
/// loaded. Unknown VRs the 2005 parser cannot name are rewritten so the load
/// stays quiet and the keywords still resolve.
BOOL HorosLoadVendoredDicomDictionary(NSString * _Nullable path);

/// The dicom.dic shipped with this process: its bundle's (the application's,
/// or the Decompress service's own copy), or the file next to the executable.
NSString * _Nullable HorosVendoredDicomDictionaryPath(void);

#ifdef __cplusplus
}
#endif

@interface IsiXDCMTKDictionary : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// The keyword DCMTK gives the tag (group << 16 | element), as DcmTag's
/// getTagName(): "Unknown Tag & Data" for a tag it does not know. Nil with an
/// error only when DCMTK failed.
+ (nullable NSString *)keywordForTag:(uint32_t)tag error:(NSError **)error
    NS_SWIFT_NAME(keyword(forTag:));

/// Walks the attributes of the dictionary that no private creator owns and
/// whose group is not 0, in tag order, one tag each, with its keyword. The
/// dictionary is locked for the walk, and unlocked however it ends. NO with an
/// error when the dictionary is not loaded or the walk failed (an exception
/// thrown by the block included); entries already given stay given.
+ (BOOL)enumeratePublicAttributesUsingBlock:(NS_NOESCAPE void (^)(uint32_t tag, NSString *keyword))block
                                      error:(NSError **)error
    NS_SWIFT_NAME(enumeratePublicAttributes(_:));

/// The tag of a standard (even group) attribute whose keyword DCMTK knows,
/// the shipped dicom.dic loaded first: whether there is one. The keyword is
/// matched as written; its other spellings are the caller's.
+ (BOOL)getStandardTag:(uint32_t *)tag forKeyword:(NSString *)keyword
    NS_SWIFT_NAME(getStandardTag(_:forKeyword:));

/// The value representation DCMTK gives the tag ("DA", "UN" for one it does
/// not know), as DcmTag's getEVR().
+ (NSString *)valueRepresentationForTag:(uint32_t)tag NS_SWIFT_NAME(valueRepresentation(forTag:));

@end

/// The two dictionaries the IsiXDICOMFile tags read, built from the DCMTK
/// dictionary: "GGGG,EEEE" -> {Description, VR, VM}, and name -> "GGGG,EEEE".
/// The module finds this class by name, since it cannot link the adapters.
@interface HorosDICOMDictionaries : NSObject
+ (NSDictionary<NSString *, NSDictionary *> *)tagDictionary;
+ (NSDictionary<NSString *, NSString *> *)tagForNameDictionary;
@end

NS_ASSUME_NONNULL_END

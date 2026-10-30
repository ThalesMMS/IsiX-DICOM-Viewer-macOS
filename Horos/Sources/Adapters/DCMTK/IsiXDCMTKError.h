//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The errors of the DCMTK adapters. This header, like every header of
// Adapters/DCMTK, declares only Objective-C and C types: Swift reads it through
// the bridging header, and nothing of DCMTK reaches the files that import it.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A DCMTK condition other than EC_Normal, or a C++ exception caught in an
/// adapter. A condition's code is (module << 16) | code of its OFCondition.
FOUNDATION_EXPORT NSErrorDomain const IsiXDCMTKErrorDomain;
/// NSNumber: the OFCondition's module and code, as DCMTK numbers them.
FOUNDATION_EXPORT NSString * const IsiXDCMTKConditionModuleKey;
FOUNDATION_EXPORT NSString * const IsiXDCMTKConditionCodeKey;
/// NSString: the OFCondition's text.
FOUNDATION_EXPORT NSString * const IsiXDCMTKConditionTextKey;
/// NSNumber (BOOL): the condition is good() though not EC_Normal.
FOUNDATION_EXPORT NSString * const IsiXDCMTKConditionGoodKey;
/// NSNumber: an IsiXDCMTKConditionKind.
FOUNDATION_EXPORT NSString * const IsiXDCMTKConditionKindKey;
/// NSNumber (BOOL): the failure came from setting up TLS for the association.
FOUNDATION_EXPORT NSString * const IsiXDCMTKSecureTransportKey;
/// NSNumber (BOOL): the failure came from the peer's address.
FOUNDATION_EXPORT NSString * const IsiXDCMTKPeerAddressKey;
/// NSString: the DCMTK call that failed, when the error names one
/// (ASC_initializeNetwork, ASC_setTransportLayer, ASC_destroyAssociation…).
FOUNDATION_EXPORT NSString * const IsiXDCMTKOperationKey;

/// The code of an error that is a C++ exception rather than a DCMTK condition.
FOUNDATION_EXPORT const NSInteger IsiXDCMTKErrorCodeException;
/// The code of a failure that DCMTK reports without a condition (a TLS file
/// that does not load, a missing identifier).
FOUNDATION_EXPORT const NSInteger IsiXDCMTKErrorCodeFailure;

/// The conditions callers tell apart.
typedef NS_ENUM(NSInteger, IsiXDCMTKConditionKind) {
    IsiXDCMTKConditionKindOther = 0,
    IsiXDCMTKConditionKindAssociationRejected,
    IsiXDCMTKConditionKindPeerRequestedRelease,
    IsiXDCMTKConditionKindPeerAbortedAssociation,
    IsiXDCMTKConditionKindNetworkClosed,
    IsiXDCMTKConditionKindIllegalParameter,
    IsiXDCMTKConditionKindNoPresentationContext,
    IsiXDCMTKConditionKindException,
    /// DIMSE_BADMESSAGE: what a C-STORE that was not accepted ends on.
    IsiXDCMTKConditionKindBadMessage,
};

/// The errors callers make themselves, for a condition the operation did not
/// give: an association given up (DUL_NETWORKCLOSED), one that never came
/// (EC_IllegalParameter), and a C-GET that ended with sub-operations missing
/// (DIMSEC_RECEIVEFAILED with `text`).
@interface IsiXDCMTKError : NSObject
+ (NSError *)errorForConditionKind:(IsiXDCMTKConditionKind)kind;
+ (NSError *)receiveFailedErrorWithText:(NSString *)text;
/// The kind of an error of IsiXDCMTKErrorDomain, Other for any other error.
+ (IsiXDCMTKConditionKind)kindOfError:(nullable NSError *)error;
/// "mmmm:cccc text", as the logs and notices have always given a condition.
+ (NSString *)conditionDescriptionOfError:(NSError *)error;
@end

NS_ASSUME_NONNULL_END

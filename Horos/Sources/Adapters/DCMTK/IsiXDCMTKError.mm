//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXDCMTKInternal.hpp"

#include <dcmtk/dcmnet/dimse.h>

NSErrorDomain const IsiXDCMTKErrorDomain = @"IsiXDCMTKErrorDomain";
NSString * const IsiXDCMTKConditionModuleKey = @"IsiXDCMTKConditionModule";
NSString * const IsiXDCMTKConditionCodeKey = @"IsiXDCMTKConditionCode";
NSString * const IsiXDCMTKConditionTextKey = @"IsiXDCMTKConditionText";
NSString * const IsiXDCMTKConditionGoodKey = @"IsiXDCMTKConditionGood";
NSString * const IsiXDCMTKConditionKindKey = @"IsiXDCMTKConditionKind";
NSString * const IsiXDCMTKSecureTransportKey = @"IsiXDCMTKSecureTransport";
NSString * const IsiXDCMTKPeerAddressKey = @"IsiXDCMTKPeerAddress";
NSString * const IsiXDCMTKOperationKey = @"IsiXDCMTKOperation";
const NSInteger IsiXDCMTKErrorCodeException = -1;
const NSInteger IsiXDCMTKErrorCodeFailure = -2;

static IsiXDCMTKConditionKind IsiXDCMTKKindOfCondition(const OFCondition &condition)
{
    if (condition == DUL_ASSOCIATIONREJECTED) return IsiXDCMTKConditionKindAssociationRejected;
    if (condition == DUL_PEERREQUESTEDRELEASE) return IsiXDCMTKConditionKindPeerRequestedRelease;
    if (condition == DUL_PEERABORTEDASSOCIATION) return IsiXDCMTKConditionKindPeerAbortedAssociation;
    if (condition == DUL_NETWORKCLOSED) return IsiXDCMTKConditionKindNetworkClosed;
    if (condition == EC_IllegalParameter) return IsiXDCMTKConditionKindIllegalParameter;
    if (condition == DIMSE_NOVALIDPRESENTATIONCONTEXTID) return IsiXDCMTKConditionKindNoPresentationContext;
    if (condition == DIMSE_BADMESSAGE) return IsiXDCMTKConditionKindBadMessage;
    return IsiXDCMTKConditionKindOther;
}

NSError *IsiXDCMTKErrorFromCondition(const OFCondition &condition, NSString *description, BOOL secureTransport)
{
    if (condition == EC_Normal) return nil;
    NSString *text = [NSString stringWithUTF8String:condition.text() ?: ""] ?: @"";
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:@{
        NSLocalizedDescriptionKey: description ?: text,
        IsiXDCMTKConditionModuleKey: @(condition.module()),
        IsiXDCMTKConditionCodeKey: @(condition.code()),
        IsiXDCMTKConditionTextKey: text,
        IsiXDCMTKConditionGoodKey: @(condition.good() ? YES : NO),
        IsiXDCMTKConditionKindKey: @(IsiXDCMTKKindOfCondition(condition)),
    }];
    if (secureTransport) info[IsiXDCMTKSecureTransportKey] = @YES;
    return [NSError errorWithDomain:IsiXDCMTKErrorDomain
                               code:(NSInteger)(((unsigned)condition.module() << 16) | condition.code())
                           userInfo:info];
}

NSError *IsiXDCMTKFailure(NSString *description, BOOL secureTransport)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (secureTransport) info[IsiXDCMTKSecureTransportKey] = @YES;
    return [NSError errorWithDomain:IsiXDCMTKErrorDomain code:IsiXDCMTKErrorCodeFailure userInfo:info];
}

NSError *IsiXDCMTKErrorFromException(const char *what, const char *operation)
{
    NSString *reason = [NSString stringWithUTF8String:what ?: ""] ?: @"";
    NSString *call = [NSString stringWithUTF8String:operation ?: ""] ?: @"";
    NSLog(@"---- DCMTK adapter: %@ threw a C++ exception: %@", call, reason);
    return [NSError errorWithDomain:IsiXDCMTKErrorDomain code:IsiXDCMTKErrorCodeException userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", call, reason],
        IsiXDCMTKConditionTextKey: reason,
        IsiXDCMTKConditionKindKey: @(IsiXDCMTKConditionKindException),
    }];
}

const char *IsiXDCMTKFileSystemPath(NSString *path)
{
    if (path.length == 0) return NULL;
    const char *representation = NULL;
    @try { representation = path.fileSystemRepresentation; }
    @catch (NSException *exception) { representation = NULL; }
    return representation && *representation ? representation : NULL;
}

@implementation IsiXDCMTKError

+ (NSError *)errorForConditionKind:(IsiXDCMTKConditionKind)kind
{
    switch (kind) {
        case IsiXDCMTKConditionKindAssociationRejected: return IsiXDCMTKErrorFromCondition(DUL_ASSOCIATIONREJECTED);
        case IsiXDCMTKConditionKindPeerRequestedRelease: return IsiXDCMTKErrorFromCondition(DUL_PEERREQUESTEDRELEASE);
        case IsiXDCMTKConditionKindPeerAbortedAssociation: return IsiXDCMTKErrorFromCondition(DUL_PEERABORTEDASSOCIATION);
        case IsiXDCMTKConditionKindNetworkClosed: return IsiXDCMTKErrorFromCondition(DUL_NETWORKCLOSED);
        case IsiXDCMTKConditionKindIllegalParameter: return IsiXDCMTKErrorFromCondition(EC_IllegalParameter);
        case IsiXDCMTKConditionKindNoPresentationContext: return IsiXDCMTKErrorFromCondition(DIMSE_NOVALIDPRESENTATIONCONTEXTID);
        case IsiXDCMTKConditionKindException: return IsiXDCMTKErrorFromException("exception", "IsiXDCMTKError");
        case IsiXDCMTKConditionKindBadMessage: return IsiXDCMTKErrorFromCondition(DIMSE_BADMESSAGE);
        case IsiXDCMTKConditionKindOther: break;
    }
    return IsiXDCMTKFailure(@"DCMTK failure");
}

+ (NSError *)receiveFailedErrorWithText:(NSString *)text
{
    // The condition owns a copy of the text.
    return IsiXDCMTKErrorFromCondition(makeDcmnetCondition(DIMSEC_RECEIVEFAILED, OF_error, text.UTF8String ?: ""));
}

+ (IsiXDCMTKConditionKind)kindOfError:(NSError *)error
{
    if (![error.domain isEqualToString:IsiXDCMTKErrorDomain]) return IsiXDCMTKConditionKindOther;
    return (IsiXDCMTKConditionKind)[error.userInfo[IsiXDCMTKConditionKindKey] integerValue];
}

+ (NSString *)conditionDescriptionOfError:(NSError *)error
{
    NSNumber *module = error.userInfo[IsiXDCMTKConditionModuleKey], *code = error.userInfo[IsiXDCMTKConditionCodeKey];
    NSString *text = error.userInfo[IsiXDCMTKConditionTextKey] ?: error.localizedDescription;
    if (!module || !code) return text;
    return [NSString stringWithFormat:@"%04x:%04x %@", module.unsignedShortValue, code.unsignedShortValue, text];
}

@end

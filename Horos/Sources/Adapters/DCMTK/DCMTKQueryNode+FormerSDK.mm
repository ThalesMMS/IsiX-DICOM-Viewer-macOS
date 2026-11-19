//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The selectors of DCMTKQueryNode in the plug-in SDK of Horos and OsiriX that
// answer an OFCondition, a C++ class Swift cannot name: the steps of a query or
// a retrieve on an association. A plug-in built with DCMTK's headers sends them
// without being rebuilt.
//
// In Horos each ran one DIMSE service on the association the node had just
// opened. The node now opens and releases its association inside the service
// (IsiXDCMTKAssociation), and a plug-in has no association of this DCMTK to
// give: the one it passes is not read. Each selector runs the same service with
// the dataset given, on an association of the node's own, and answers
// EC_Normal when it went through.

#import <Foundation/Foundation.h>

#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmdata/dcuid.h"
#include "dcmtk/dcmnet/assoc.h"
#include "dcmtk/ofstd/ofcond.h"

#import "DCMTKServiceClassUser.h"

class DcmDataset;

// The node is a Swift class of the application. This file names of it only
// its superclass and the message it sends, so that the adapter does not read
// the application's generated header. -addPresentationContext:abstractSyntax:,
// which the SDK declared for the node too, is the one the node inherits from
// DCMTKServiceClassUser.
@interface DCMTKQueryNode : DCMTKServiceClassUser
- (BOOL)setupNetworkWithSyntax:(const char *)abstractSyntax dataset:(const void *)dataset destination:(NSString *)destination;
@end

static OFCondition IsiXFormerSDKServiceResult(BOOL done)
{
    return done ? EC_Normal : makeOFCondition(OFM_dcmnet, 0x7f0, OF_error, "The service did not complete");
}

@interface DCMTKQueryNode (FormerSDKAssociations)
@end

@implementation DCMTKQueryNode (FormerSDKAssociations)

- (OFCondition)findSCU:(T_ASC_Association *)assoc dataset:(DcmDataset *)dataset
{
    return IsiXFormerSDKServiceResult([self setupNetworkWithSyntax:UID_FINDStudyRootQueryRetrieveInformationModel dataset:dataset destination:nil]);
}

- (OFCondition)cfind:(T_ASC_Association *)assoc dataset:(DcmDataset *)dataset
{
    return [self findSCU:assoc dataset:dataset];
}

- (OFCondition)moveSCU:(T_ASC_Association *)assoc network:(T_ASC_Network *)net dataset:(DcmDataset *)dataset destination:(char *)destination
{
    NSString *title = destination ? [NSString stringWithUTF8String:destination] : nil;
    return IsiXFormerSDKServiceResult([self setupNetworkWithSyntax:UID_MOVEStudyRootQueryRetrieveInformationModel dataset:dataset destination:title]);
}

- (OFCondition)moveSCU:(T_ASC_Association *)assoc network:(T_ASC_Network *)net dataset:(DcmDataset *)dataset
{
    return [self moveSCU:assoc network:net dataset:dataset destination:NULL];
}

- (OFCondition)cmove:(T_ASC_Association *)assoc network:(T_ASC_Network *)net dataset:(DcmDataset *)dataset destination:(char *)destination
{
    return [self moveSCU:assoc network:net dataset:dataset destination:destination];
}

- (OFCondition)cmove:(T_ASC_Association *)assoc network:(T_ASC_Network *)net dataset:(DcmDataset *)dataset
{
    return [self moveSCU:assoc network:net dataset:dataset destination:NULL];
}

- (OFCondition)getSCU:(T_ASC_Association *)assoc network:(T_ASC_Network *)net dataset:(DcmDataset *)dataset
{
    return IsiXFormerSDKServiceResult([self setupNetworkWithSyntax:UID_GETStudyRootQueryRetrieveInformationModel dataset:dataset destination:nil]);
}

- (OFCondition)cget:(T_ASC_Association *)assoc network:(T_ASC_Network *)net dataset:(DcmDataset *)dataset
{
    return [self getSCU:assoc network:net dataset:dataset];
}

@end

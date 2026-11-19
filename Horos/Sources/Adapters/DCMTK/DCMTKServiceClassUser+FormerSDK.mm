//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The selector of DCMTKServiceClassUser in the plug-in SDK of Horos and OsiriX
// that takes the parameters of an association and answers an OFCondition, C++
// and C types of DCMTK that the class's header and Swift cannot name. A
// plug-in built with DCMTK's headers sends it without being rebuilt, to the
// base class, to a query node, which inherits it, or to a subclass of its own.
//
// OFCondition is returned in memory the caller gives, and has here the layout
// it had in the DCMTK of that SDK: a module, a code, a status, a text and
// whether the text is the condition's to free.

#import <Foundation/Foundation.h>

#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmdata/dcuid.h"
#include "dcmtk/dcmnet/assoc.h"
#include "dcmtk/ofstd/ofcond.h"

#import "DCMTKServiceClassUser.h"

@interface DCMTKServiceClassUser (FormerSDKAssociations)
- (OFCondition)addPresentationContext:(T_ASC_Parameters *)params abstractSyntax:(const char *)abstractSyntax;
@end

@implementation DCMTKServiceClassUser (FormerSDKAssociations)

// Proposes the abstract syntax in the first presentation context, with the
// transfer syntaxes the SDK's class proposed for the services it was the base
// of (C-FIND, C-MOVE, C-ECHO): explicit little endian first, then explicit big
// endian and implicit little endian.
- (OFCondition)addPresentationContext:(T_ASC_Parameters *)params abstractSyntax:(const char *)abstractSyntax
{
    if (!params || !abstractSyntax) return EC_IllegalParameter;
    const char *transferSyntaxes[] = {UID_LittleEndianExplicitTransferSyntax, UID_BigEndianExplicitTransferSyntax,
                                      UID_LittleEndianImplicitTransferSyntax};
    return ASC_addPresentationContext(params, 1, abstractSyntax, transferSyntaxes, 3);
}

@end

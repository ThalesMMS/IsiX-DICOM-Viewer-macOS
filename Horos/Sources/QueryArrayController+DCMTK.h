/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#import <Foundation/Foundation.h>
#import "QueryArrayController.h"

/** \brief The DCMTK part of QueryArrayController.
 *
 * QueryArrayController is Swift since #713. The query node it runs is a
 * DCMTKRootQueryNode, whose header is DCMTK C++ and cannot be read by Swift, so
 * the messages sent to the node stay Objective-C++ in
 * QueryArrayController+DCMTK.mm. Each is the former call, unchanged.
 */

#ifdef HOROS_BRIDGING_HEADER
// Swift compiles the class itself and has no Objective-C interface of it to
// extend here, so the methods are declared on the superclass for Swift code to
// send: only QueryArrayController (DCMTK) implements them.
@interface NSObject (QueryArrayControllerDCMTK)
#else
@interface QueryArrayController (DCMTK)
#endif

/** [DCMTKRootQueryNode queryNodeWithDataset:nil callingAET:... transferSyntax:0 compression:0 extraParameters:...] */
+ (id) dcmtkRootQueryNodeWithCallingAET:(NSString*) callingAET calledAET:(NSString*) calledAET hostname:(NSString*) hostname port:(int) port extraParameters:(NSDictionary*) extraParameters
    NS_SWIFT_NAME(dcmtkRootQueryNode(callingAET:calledAET:hostname:port:extraParameters:));

/** [node setShowErrorMessage: showError]; [node queryWithValues: values]; */
+ (void) dcmtkQueryNode:(id) node withValues:(NSArray*) values showErrorMessage:(BOOL) showError
    NS_SWIFT_NAME(dcmtkQuery(node:values:showErrorMessage:));

/** [node children] */
+ (NSArray*) dcmtkChildrenOfQueryNode:(id) node
    NS_SWIFT_NAME(dcmtkChildren(ofQueryNode:));

/** [[node numberImages] intValue] */
+ (int) dcmtkNumberImagesOfQueryNode:(id) node
    NS_SWIFT_NAME(dcmtkNumberImages(ofQueryNode:));

@end

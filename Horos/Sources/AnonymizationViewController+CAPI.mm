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

// What AnonymizationViewController (now in Swift) keeps in Objective-C++.

#import <Foundation/Foundation.h>
#import "DCMAttributeTag.h"

// Defined in a .mm without extern "C" before the class moved to Swift, so the
// executable exports it with its C++ name; it stays here with that name. The
// Swift class sorts with an equivalent comparator, so nothing in the app calls
// it any more: __attribute__((used)) keeps Release dead stripping from dropping
// it.
__attribute__((used)) NSInteger CompareArraysByNameOfDCMAttributeTagAtIndexZero(id arg1, id arg2, void* context) {
	return [[[arg1 objectAtIndex:0] name] caseInsensitiveCompare:[[arg2 objectAtIndex:0] name]];
}

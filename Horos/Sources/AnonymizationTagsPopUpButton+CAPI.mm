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

// What AnonymizationTagsPopUpButton (Swift since #712) keeps in Objective-C++.

#import "AnonymizationTagsPopUpButton.h"
#import "DCMAttributeTag.h"

// Defined in a .mm without extern "C" before #712, so the executable exports
// them with their C++ names; they stay here with those names. The Swift class
// sorts with equivalent comparators, so nothing in the app calls these any
// more: __attribute__((used)) keeps Release dead stripping from dropping them.
__attribute__((used)) NSInteger CompareDCMAttributeTagNames(id lsp, id rsp, void* context) {
	return [[lsp name] caseInsensitiveCompare: [rsp name]];
}

__attribute__((used)) NSInteger CompareDCMAttributeTagStringValues(id lsp, id rsp, void* context) {
	return [[lsp stringValue] caseInsensitiveCompare:[rsp stringValue]];
}

// -selectedTag and -setSelectedTag:, declared in AnonymizationTagsPopUpButton.h:
// Swift cannot declare a getter with the selector of NSPopUpButton's
// -selectedTag. As before, they return and set selectedDCMAttributeTag.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincompatible-property-type"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
@implementation AnonymizationTagsPopUpButton (SelectedTag)

- (DCMAttributeTag *)selectedTag {
    return self.selectedDCMAttributeTag;
}

- (void)setSelectedTag:(DCMAttributeTag *)tag {
    [self setSelectedDCMAttributeTag:tag];
}

@end
#pragma clang diagnostic pop

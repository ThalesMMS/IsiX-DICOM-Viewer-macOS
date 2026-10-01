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

#import "OSICustomImageAnnotations.h"
#import "HorosAlertPanel.h"

// The C part of the Annotations preference pane, which is otherwise Swift
// since #711.

// Unchanged from the former OSICustomImageAnnotations.m.
NSComparisonResult  compareViewTags(id firstView, id secondView, void * context)
{
   int firstTag;
   int secondTag;
   id v = context;
	
	if( [v boolValue])
	{
		secondTag = [firstView tag];
		firstTag = [secondView tag];
	}
	else
	{
		firstTag = [firstView tag];
		secondTag = [secondView tag];
	}

   if (firstTag == secondTag) {return NSOrderedSame;}
   else
   {
       if (firstTag < secondTag) {return NSOrderedAscending;}
       else {return NSOrderedDescending;}
   }
}

// Preserve the published C entry points and historical 1/0/-1 responses.
// Messages are literal strings, as in the current shared NSAlert bridge.
NSInteger CIARunAlertPanel(NSString *title, NSString *message, NSString *defaultButton, NSString *alternateButton, NSString *otherButton)
{
    return [HorosAlertPanel runWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton];
}

NSInteger CIARunInformationalAlertPanel(NSString *title, NSString *message, NSString *defaultButton, NSString *alternateButton, NSString *otherButton)
{
    return [HorosAlertPanel runInformationalWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton];
}

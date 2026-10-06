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

// OSIROIManager is implemented in Swift
// (Horos/Sources/OSIROIManager.swift). This header keeps <Horos/OSIROIManager.h>:
// it brings in the generated interface, which declares the same class name and
// selectors, and it keeps declaring the OSIROIManagerDelegate protocol, which
// the generated interface names. The OSIROIManager class defines the interface
// to discover ROIs and filter for the ROIs of interest. After creating an
// instance of OSIROIManager a client can use it to get an array of ROIs and can
// register itself as a delegate to recieve updates about the ROIs in the given
// OSIVolumeWindow. OSIROIManager+Private.h keeps declaring the application's
// own method.

#import <Cocoa/Cocoa.h>

// anyone who is interested in dealing with ROIs can create one of these and learn about what is going on with ROIs

// and OSIROIManager is meant to act as a filter, it will return ROIs

// what I want is an object that will give me a list of volume ROIs

extern const NSString *OSILineROIType;
//extern const NSString *OSI;

@class OSIStudy;
@class OSIROI;
@class OSIVolumeWindow;

/**  
 
 The `OSIROIManager` sends a `OSIROIManagerROIsDidUpdateNotification` whenever there is any change in the managed ROIs
 
 */

extern NSString* const OSIROIManagerROIsDidUpdateNotification; 

extern NSString* const OSIROIUpdatedROIKey;
extern NSString* const OSIROIRemovedROIKey;
extern NSString* const OSIROIAddedROIKey;

@class OSIROIManager;

/**  
 
 The `OSIROIManagerDelegate` Protocol is to be implemented by the delegate of an OSIROIManager to be notified of changes in the managed ROIs.
 
 @warning *Important:* None of these methodes are implemented yet. Listen for the `OSIROIManagerROIsDidUpdateNotification` notification instead
 
 */


@protocol OSIROIManagerDelegate <NSObject>
@optional

/** Informs the delegate that `ROI` was added to the Volume Window.
 
 @param ROIManager the ROIManager that sent the message.
 @param ROI The ROI that was added.
 
 @warning *Important:* Not implemented yet. Listen for the `OSIROIManagerROIsDidUpdateNotification` notification instead

 */
- (void)ROIManager:(OSIROIManager *)ROIManager didAddROI:(OSIROI *)ROI;
/** Informs the delegate that `ROI` was removed to the Volume Window.
 
 @param ROIManager the ROIManager that sent the message.
 @param ROI The ROI that was removed.
 
 @warning *Important:* Not implemented yet. Listen for the `OSIROIManagerROIsDidUpdateNotification` notification instead
 */
- (void)ROIManager:(OSIROIManager *)ROIManager didRemoveROI:(OSIROI *)ROI;
/** Informs the delegate that `ROI` was modified.
 
 @param ROIManager the ROIManager that sent the message.
 @param ROI The ROI that was modified.
 
 @warning *Important:* Not implemented yet. Listen for the `OSIROIManagerROIsDidUpdateNotification` notification instead
 */
- (void)ROIManager:(OSIROIManager *)ROIManager didModifyROI:(OSIROI *)ROI;

@end

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class OSIROIManager;
#else
#import "Horos-Swift.h"
#endif

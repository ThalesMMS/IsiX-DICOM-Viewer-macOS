/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)

 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.

 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.

 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html

 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL

  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// Notifications.h of the legacy plugin SDK, kept by IsiXLegacyBridge: the
// notifications of a 2D viewer's events, which the kit posts in the plugin's
// notification center (IsiXLegacyNotificationCenter.h) with the kit's objects.
// The names are the legacy ones, as constants of the plugin's own: a plugin
// that wrote the string, as @"mouseDown", gets the same notifications.
//
// - OsirixMouseDownNotification: a click of the left button, without a
//   modifier key, on a viewer's image. Object: the ViewerController. userInfo,
//   mutable: X (whole pixels) and Y, the position on the image with the
//   centre of the first pixel at (0.5, 0.5); set stopMouseDown to YES and the
//   viewer does nothing else with the click.
// - OsirixCloseViewerNotification: the viewer is closing. Object: the ViewerController.
// - OsirixDCMUpdateCurrentImageNotification: the viewer shows another image.
//   Object: its DCMView.
// - OsirixAddROINotification (object: the DCMView; userInfo: ROI and
//   sliceNumber), OsirixROIChangeNotification, OsirixROISelectedNotification
//   and OsirixRemoveROINotification (object: the ROI): a ROI of a viewer was
//   added, changed, selected or removed, by the user or by the plugin. A ROI
//   the plugin posts OsirixROIChangeNotification for joins its viewer.
// - OsirixDrawObjectsNotification: the viewer draws its image. Object: its
//   DCMView. userInfo: context, a CGContextRef whose user space is the
//   image's pixels, the centre of the first pixel at (0.5, 0.5), as ROI
//   points; pointSize, the length of one point of the screen in pixels;
//   spacingX and spacingY. Draw with Core Graphics: there is no OpenGL
//   context.
// - OsirixUpdateViewNotification: posted by the plugin, redraws the viewers.
// - OsirixAddToDBNotification: images entered the database, one batch at a
//   time. userInfo: the images, as the kit's DicomImage, under
//   OsirixAddToDBNotificationImagesArray; those received from the network,
//   by the calling AE title, under OsirixAddToDBNotificationImagesPerAETDictionary
//   (SOP Instance UIDs).
// - OsirixAddToDBCompleteNotification: an import ended. userInfo: every image
//   it added, under OsirixAddToDBCompleteNotificationImagesArray.
// - OsirixXMLRPCMessageNotification: an XML-RPC call of a method the plugin
//   listed under IsiXLegacyXMLRPCMethods in its Info.plist. The object is a
//   mutable dictionary: the first parameter's members, MethodName, methodName
//   and NSXMLDocument (the request). The plugin answers by setting Response
//   (Cocoa values) or NSXMLDocumentResponse, or Processed.

#import "IsiXLegacyBridgeDefines.h"

#define OsirixMouseDownNotification @"mouseDown"
#define OsirixCloseViewerNotification @"CloseViewerNotification"
#define OsirixDCMUpdateCurrentImageNotification @"DCMUpdateCurrentImage"
#define OsirixAddROINotification @"addROI"
#define OsirixROIChangeNotification @"roiChange"
#define OsirixROISelectedNotification @"roiSelected"
#define OsirixRemoveROINotification @"removeROI"
#define OsirixDrawObjectsNotification @"PLUGINdrawObjects"
#define OsirixUpdateViewNotification @"updateView"
#define OsirixAddToDBNotification @"OsirixAddToDBNotification"
#define OsirixAddToDBCompleteNotification @"OsirixAddToDBCompleteNotification"
#define OsirixAddToDBNotificationImagesArray @"OsiriXAddToDBArray"
#define OsirixAddToDBCompleteNotificationImagesArray @"OsiriXAddToDBArray"
#define OsirixAddToDBNotificationImagesPerAETDictionary @"PerAETDictionary"
#define OsirixXMLRPCMessageNotification @"OsiriXXMLRPCMessage"

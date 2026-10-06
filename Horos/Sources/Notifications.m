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

#import "Notifications.h"

__attribute__((used)) NSString* const OsirixUpdateWLWWMenuNotification = @"UpdateWLWWMenu";
__attribute__((used)) NSString* const OsirixChangeWLWWNotification = @"changeWLWW";
__attribute__((used)) NSString* const OsirixROIChangeNotification = @"roiChange";
__attribute__((used)) NSString* const OsirixCloseViewerNotification = @"CloseViewerNotification";
__attribute__((used)) NSString* const OsirixUpdate2dCLUTMenuNotification = @"Update2DCLUTMenu";
__attribute__((used)) NSString* const OsirixUpdate2dWLWWMenuNotification = @"Update2DWLWWMenu";
__attribute__((used)) NSString* const OsirixLLMPRResliceNotification = @"LLMPRReslice";
__attribute__((used)) NSString* const OsirixROIVolumePropertiesChangedNotification = @"ROIVolumePropertiesChanged";
__attribute__((used)) NSString* const OsirixVRViewDidBecomeFirstResponderNotification = @"VRViewDidBecomeFirstResponder";
__attribute__((used)) NSString* const OsirixUpdateVolumeDataNotification = @"updateVolumeData";
__attribute__((used)) NSString* const OsirixRevertSeriesNotification = @"revertSeriesNotification";
__attribute__((used)) NSString* const OsirixOpacityChangedNotification = @"OpacityChanged";
__attribute__((used)) NSString* const OsirixDefaultToolModifiedNotification = @"defaultToolModified";
__attribute__((used)) NSString* const OsirixDefaultRightToolModifiedNotification = @"defaultRightToolModified";
__attribute__((used)) NSString* const OsirixDefaultMiddleToolModifiedNotification = @"defaultMiddleToolModified";
__attribute__((used)) NSString* const OsirixUpdateConvolutionMenuNotification = @"UpdateConvolutionMenu";
__attribute__((used)) NSString* const OsirixCLUTChangedNotification = @"CLUTChanged";
__attribute__((used)) NSString* const OsirixUpdateCLUTMenuNotification = @"UpdateCLUTMenu";
__attribute__((used)) NSString* const OsirixUpdateOpacityMenuNotification = @"UpdateOpacityMenu";
__attribute__((used)) NSString* const OsirixRecomputeROINotification = @"recomputeROI";
__attribute__((used)) NSString* const OsirixStopPlayingNotification = @"notificationStopPlaying";
__attribute__((used)) NSString* const OsirixChatBroadcastNotification = @"notificationiChatBroadcast";
__attribute__((used)) NSString* const OsirixSyncSeriesNotification = @"notificationSyncSeries";
__attribute__((used)) NSString* const OsirixOrthoMPRSyncSeriesNotification = @"orthoMPRSyncSeriesNotification";
__attribute__((used)) NSString* const OsirixReportModeChangedNotification = @"reportModeChanged";
__attribute__((used)) NSString* const OsirixDeletedReportNotification = @"OsirixDeletedReport";
__attribute__((used)) NSString* const OsirixStudyAnnotationsChangedNotification = @"OsirixStudyAnnotationsChanged";
__attribute__((used)) NSString* const OsirixGLFontChangeNotification = @"changeGLFontNotification";
__attribute__((used)) NSString* const OsirixAddToDBNotification = @"OsirixAddToDBNotification";
__attribute__((used)) NSString* const OsirixAddNewStudiesDBNotification = @"OsirixAddNewStudiesDBNotification";
__attribute__((used)) NSString* const OsirixDicomDatabaseDidChangeContextNotification = @"OsirixDicomDatabaseDidChangeContextNotification";
#define OsiriXAddToDBArrayKey @"OsiriXAddToDBArray"
__attribute__((used)) NSString* const OsirixAddToDBNotificationImagesArray = OsiriXAddToDBArrayKey;
__attribute__((used)) NSString* const OsirixAddToDBNotificationImagesPerAETDictionary = @"PerAETDictionary";
__attribute__((used)) NSString* const OsirixAddToDBCompleteNotification = @"OsirixAddToDBCompleteNotification";
__attribute__((used)) NSString* const OsirixAddToDBCompleteNotificationImagesArray = OsiriXAddToDBArrayKey; // is deprecated in favor of OsirixAddToDBNotificationImagesArray
__attribute__((used)) NSString* const _O2AddToDBAnywayNotification = @"_O2AddToDBAnywayNotification";
__attribute__((used)) NSString* const _O2AddToDBAnywayCompleteNotification = @"_O2AddToDBAnywayCompleteNotification";
__attribute__((used)) NSString* const O2DatabaseInvalidateAlbumsCacheNotification = @"InvalidateAlbumsCache";
__attribute__((used)) NSString* const OsirixDatabaseObjectsMayBecomeUnavailableNotification = @"OsirixDatabaseObjectsMayBecomeUnavailableNotification";
__attribute__((used)) NSString* const OsirixNewStudySelectedNotification = @"NewStudySelectedNotification";
__attribute__((used)) NSString* const OsirixDidLoadNewObjectNotification = @"OsiriX Did Load New Object";
__attribute__((used)) NSString* const OsirixRTStructNotification = @"RTSTRUCTNotification";
__attribute__((used)) NSString* const OsirixAlternateButtonPressedNotification = @"AlternateButtonPressed";
__attribute__((used)) NSString* const OsirixROISelectedNotification = @"roiSelected";
__attribute__((used)) NSString* const OsirixRemoveROINotification = @"removeROI";
__attribute__((used)) NSString* const OsirixROIRemovedFromArrayNotification = @"roiRemovedFromArray";
__attribute__((used)) NSString* const OsirixChangeFocalPointNotification = @"changeFocalPoint";
__attribute__((used)) NSString* const OsirixWindow3dCloseNotification = @"Window3DClose";
__attribute__((used)) NSString* const OsirixDisplay3dPointNotification = @"Display3DPoint";
__attribute__((used)) NSString* const AppPluginDownloadInstallDidFinishNotification = @"PluginManagerControllerDownloadAndInstallDidFinish";
__attribute__((used)) NSString* const OsirixXMLRPCMessageNotification = @"OsiriXXMLRPCMessage";
__attribute__((used)) NSString* const OsirixDragMatrixImageMovedNotification = @"DragMatrixImageMoved";
__attribute__((used)) NSString* const OsirixNotification = @"VRCameraDidChange";
__attribute__((used)) NSString* const OsiriXFileReceivedNotification = @"OsiriXFileReceivedNotification";
__attribute__((used)) NSString* const OsirixDCMSendStatusNotification = @"DCMSendStatus";
__attribute__((used)) NSString* const OsirixDCMUpdateCurrentImageNotification = @"DCMUpdateCurrentImage";
__attribute__((used)) NSString* const OsirixDCMViewIndexChangedNotification = @"DCMViewIndexChanged";
__attribute__((used)) NSString* const OsirixRightMouseUpNotification = @"PLUGINrightMouseUp";
__attribute__((used)) NSString* const OsirixMouseDownNotification = @"mouseDown";
__attribute__((used)) NSString* const OsirixVRCameraDidChangeNotification = @"VRCameraDidChange";
__attribute__((used)) NSString* const OsirixSyncNotification = @"sync";
__attribute__((used)) NSString* const OsirixOrthoMPRPosChangeNotification = @"orthoMPRPosChangeNotification";
__attribute__((used)) NSString* const OsirixAddROINotification = @"addROI";
__attribute__((used)) NSString* const OsirixRightMouseDownNotification = @"PLUGINrightMouseDown";
__attribute__((used)) NSString* const OsirixRightMouseDraggedNotification = @"PLUGINrightMouseDragged";
__attribute__((used)) NSString* const OsirixLabelGLFontChangeNotification = @"changeLabelGLFontNotification";
__attribute__((used)) NSString* const OsirixDrawTextInfoNotification = @"PLUGINdrawTextInfo";
__attribute__((used)) NSString* const OsirixDrawObjectsNotification = @"PLUGINdrawObjects";
__attribute__((used)) NSString* const HorosDrawObjectsCanvasNotification = @"HorosDrawObjectsCanvas";
__attribute__((used)) NSString* const OsirixDCMViewDidBecomeFirstResponderNotification = @"DCMViewDidBecomeFirstResponder";
__attribute__((used)) NSString* const OsirixPerformDragOperationNotification = @"PluginDragOperationNotification";
__attribute__((used)) NSString* const OsirixViewerWillChangeNotification = @"ViewerWillChangeNotification";
__attribute__((used)) NSString* const OsirixViewerDidChangeNotification = @"ViewerDidChangeNotification";
__attribute__((used)) NSString* const OsirixUpdateViewNotification = @"updateView";
__attribute__((used)) NSString* const OsirixViewerControllerDidLoadImagesNotification = @"OsirixViewerControllerDidLoadImagesNotification";
__attribute__((used)) NSString* const OsirixViewerControllerWillFreeVolumeDataNotification = @"OsirixViewerControllerWillFreeVolumeDataNotification"; // userinfo dict will contain an NSData with @"volumeData" key and a NSNumber with @"movieIndex" key
__attribute__((used)) NSString* const OsirixViewerControllerDidAllocateVolumeDataNotification = @"OsirixViewerControllerDidAllocateVolumeDataNotification"; // userinfo dict will contain an NSData with @"volumeData" key and a NSNumber with @"movieIndex" key
__attribute__((used)) NSString* const KFSplitViewDidCollapseSubviewNotification = @"KFSplitViewDidCollapseSubviewNotification";
__attribute__((used)) NSString* const KFSplitViewDidExpandSubviewNotification = @"KFSplitViewDidExpandSubviewNotification";
__attribute__((used)) NSString* const BLAuthenticatedNotification = @"BLAuthenticatedNotification";
__attribute__((used)) NSString* const BLDeauthenticatedNotification = @"BLDeauthenticatedNotification";

__attribute__((used)) NSString* const OsirixActiveLocalDatabaseDidChangeNotification = @"OsirixActiveLocalDatabaseDidChangeNotification";

__attribute__((used)) NSString* const OsirixPopulatedContextualMenuNotification = @"OsirixPopulatedContextualMenuNotification";
__attribute__((used)) NSString* const OsiriXLogEvent = @"OsiriXLogEvent";

__attribute__((used)) NSString* const OsirixNodeRemovedFromCurvePathNotification = @"OsirixNodeRemovedFromCurvePath";
__attribute__((used)) NSString* const OsirixUpdateCurvedPathCostNotification = @"OsirixUpdateCurvedPathCost";
__attribute__((used)) NSString* const OsirixDeletedCurvedPathNotification = @"OsirixDeletedCurvedPath";

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
 ============================================================================*/

#define HOROS_BRIDGING_HEADER 1
#import "BrowserController.h"
#import "ViewerController.h"
#import "DicomDatabase.h"
#import "DCMPix.h"
#import "DCMView.h"
#import "DicomStudy.h"
#import "DicomSeries.h"
#import "DicomImage.h"
#import "ThreadsManager.h"
#import "N2AdaptiveBox.h"
#import "N2Alignment.h"
#import "N2Button.h"
#import "N2ButtonCell.h"
#import "N2ColorWell.h"
#import "N2ColumnLayout.h"
#import "N2CustomTitledPopUpButtonCell.h"
#import "N2Debug.h"
#import "N2DirectoryEnumerator.h"
#import "N2DisclosureBox.h"
#import "N2DisclosureButtonCell.h"
#import "N2Exceptions.h"
#import "N2FlippedView.h"
#import "N2HexadecimalNumberFormatter.h"
#import "N2HighlightImageButtonCell.h"
#import "N2ImageButtonCell.h"
#import "N2ImageView.h"
#import "N2Layout.h"
#import "N2Locker.h"
#import "N2ManagedDatabase.h"
#import "N2MutableUInteger.h"
#import "N2Panel.h"
#import "N2PopUpButton.h"
#import "N2PopUpMenu.h"
#import "N2Resizer.h"
#import "N2SOAPWebServiceClient.h"
#import "N2Shell.h"
#import "N2Step.h"
#import "N2StepView.h"
#import "N2Steps.h"
#import "N2StepsView.h"
#import "N2Stuff.h"
#import "N2TextField.h"
#import "N2UnclickableSplitView.h"
#import "N2UserDefaults.h"
#import "N2View.h"
#import "N2WSDL.h"
#import "N2Window.h"
#import "N2XMLRPC.h"
#import "N2XMLRPCWebServiceClient.h"
#import "HorosObjCException.h"
#import "IsiXPluginExceptionGuard.h"
#import "N2MinMax.h"
#import "N2CellDescriptor.h"
#import "NSView+N2.h"
#import "NS(Attributed)String+Geometrics.h"
#import "NSUserDefaultsController+N2.h"
#import "SMTPClient.h"
#import "NSThread+N2.h"
#import "NSFileManager+N2.h"
// The preference panes.
#import "NSPreferencePane+OsiriX.h"
#import "CIAPlaceHolder.h"
#import "OSICustomImageAnnotations.h"
#import "DNDArrayController.h"
#import "DICOMTLS.h"
#import "url.h"
#import "DefaultsOsiriX.h"
#import "NSUserDefaults+OsiriX.h"
#import "AppController.h"
#import "WindowLayoutManager.h"
#import "PluginManager.h"
#import "DicomFile.h"
#import "Adapters/VTK/IsiXVTKTIFF.h"
#import "Adapters/DCMTK/IsiXDCMTKFileProbe.h"
#import "WaitRendering.h"
#import "CIADICOMField.h"
#import "HorosAlertPanel.h"
#import "WebPortal.h"
#import "WebPortalDatabase.h"
#import "WebPortalUser.h"
#import "DicomAlbum.h"
#import "sourcesTableView.h"
#import "AYDicomPrintWindowController.h"
// PreferencesWindowController.authView, and the General pane's language rows.
#import "SFHorosAuthorizationView.h"
#import "../../Preference Panes/OSIGeneralPreferencePane/HorosLanguagePreferences.h"
// The anonymization engine and interface (the panels' AnonymizationPanelEnds
// and AnonymizationSavePanelEnds values, and the DICOM tags they list).
#import "Adapters/DCMTK/HorosDICOMServices.h"
#import "Adapters/DCMTK/IsiXDCMTKFile.h"
#import "Wait.h"
#import "HorosAnonymizationSafety.h"
#import "HorosRasterSeriesFolder.h"
#import "HorosGDCMAnonymizer.h"
#import "AnonymizationPanelController.h"
#import "AnonymizationSavePanelController.h"
// QueryArrayController -parameters;
// ThumbnailCell sizes itself by the O2ViewerThumbnailsMatrixRepresentedObject
// the viewer gives it.
#import "O2ViewerThumbnailsMatrix.h"
// The smart album predicate editor.
#import "O2DicomPredicateEditor.h"
#import "O2DicomPredicateEditorView.h"
#import "O2DicomPredicateEditorCodeStrings.h"
#import "O2DicomPredicateEditorDCMAttributeTag.h"
#import "O2DicomPredicateEditorPopUpButton.h"
#import "O2DicomPredicateEditorDatePicker.h"
#import "O2DicomPredicateEditorFormatters.h"
// The viewer's auxiliary windows read the ROI and its notifications, the
// histogram size, the split view's scaling helper, the switch cell's colours
// and the navigator window the thumbnails sit below.
#import "Notifications.h"
#import "ROI.h"
#import "MyPoint.h"
#import "HistogramWindow.h"
#import "KFSplitView.h"
#import "OnOffSwitchControlCell.h"
#import "NavigatorWindowController.h"
// The 3D viewers' editing panels. Window3DController is the superclass
// of ROIVolumeController.
#import "Window3DController.h"
#import "Camera.h"
#import "Point3D.h"
#import "Interpolation3D.h"
#import "QuicktimeExport.h"
#import "DICOMExport.h"
// DICOM print (AYNSImageToDicom's enum and struct, the
// DICOMExport writer, the viewer's window flags, the OpenGL font reset, the
// printers' echo, the password generator's C function); the disc burner
// (burnerDestination, DICOMDIR, the DCMTK categories, the bounded tasks); the
// reports (the DicomStudy (Report) category, the report templates' helpers, the
// DICOM PDF writer and the sequences a report field reads through).
#import "AYNSImageToDicom.h"
#import "DICOMExport.h"
#import "OSIWindow.h"
#import "PSGenerator.h"
#import "BurnerWindowController.h"
#import "DicomDatabase+DCMTK.h"
#import "DicomDir.h"
#import "DicomFileDCMTKCategory.h"
#import "DicomStudy+Report.h"
#import "HorosBoundedTask.h"
#import "MutableArrayCategory.h"
#import "HorosDICOMWriter.h"
#import "HorosReportFileReplacement.h"
#import "HorosReportFields.h"
#import "HorosOpenDocument.h"
#import "HorosPagesCompatibility.h"
// The send interface (transfer syntax codes; DCMTKStoreSCU is Swift and
// reaches DCMTK through the adapter below); WADODownload's log and abort
// check; the C function BLAuthentication keeps in its +CAPI.m;
// NSString (DICOMToNSString) hands the character set to the one table;
// NSError (OsiriX) is the compatibility header of its Swift extension.
#import "SendController.h"
#import "CSMailMailClient.h"
#import "BLAuthentication.h"
#import "LogManager.h"
#import "HorosDICOMGlobalAbort.h"
#import "WADODownload.h"
#import "ThreadCell.h"
#import "ThreadModalForWindowController.h"
#import "NSError+OsiriX.h"
// The web portal. Its classes are Swift behind their compatibility headers,
// over the SwiftNIO server of HTTPConnectionEngine.swift; the data routes reach
// DCM, the path checks and the Core Data helpers.
#import "WebPortalConnection.h"
#import "WebPortalConnection+Data.h"
#import "WebPortalResponse.h"
#import "WebPortalSession.h"
#import "WebPortalStudy.h"
#import "WebPortal+Email+Log.h"
#import "HorosWebPathSafety.h"
#import "NSManagedObject+N2.h"
#import "NSImage+OsiriX.h"
// The CPR generator and its operations sample the volume through the C
// inline functions and types of CPRVolumeData.h and draw the curve with
// N3BezierPath; CPRCurvedPath keeps its token typedef, CPRProjectionOperation
// its mode enum, OSIROIMask its run type and C functions, and the image rep
// the volume hands out stays reachable by name.
#import "N3BezierPath.h"
#import "CPRVolumeData.h"
#import "CPRProjectionOperation.h"
#import "CPRCurvedPath.h"
#import "CPRUnsignedInt16ImageRep.h"
#import "OSIROIMask.h"
// The plugin manager builds the plugin SDK's environment and volume
// windows, and its window controller reads the catalog through the transport
// helpers, whose manual retain/release lines are guarded for ARC.
#import "OSIEnvironment.h"
#import "OSIVolumeWindow.h"
#import "PluginManagerController.h"
#import "HorosPluginCatalogTransport.h"
// The Core Data entities. DataNodeIdentifier and LocalDatabaseNodeIdentifier
// stay Objective-C, subclassed by BrowserController+Sources; the images and
// studies reach the SR annotations, the XML controller's DCMTK editing and the
// pixel-data import, and remote nodes the remote database.
#import "DataNodeIdentifier.h"
#import "RemoteDicomDatabase.h"
#import "XMLController.h"
// The scroll position preview's geometry (static inline C).
#import "ScrollPositionPreviewGeometry.h"
#import "SRAnnotation.h"
// DicomDatabase is implemented in Swift; what it keeps in Objective-C
// (DicomDatabase+CAPI.m) only the application's own code imports. The
// browser's sources list scans volumes with HorosVolumeDiscovery and the
// database's scan.
#import "HorosDatabaseFileValidation.h"
#import "DicomDatabase+CAPI.h"
#import "DicomDatabase+Scan.h"
#import "HorosVolumeDiscovery.h"
#import "VRController.h"
// The fly through of the surface rendering ViewerController+ThreeDViewers.swift
// opens (the window controllers are Swift).
#import "FlyThruController.h"
// ITK, for the region growing, the resampling by a transform and the volume
// they read (ITKSegmentation3D, ITKTransform, ITKVolumeImport), and the outline
// VTK traces around a mask (the region's polygons and a brush ROI's contour).
#import "Adapters/ITK/IsiXITKError.h"
#import "Adapters/ITK/IsiXITKVolume.h"
#import "Adapters/ITK/IsiXITKRegionGrowing.h"
#import "Adapters/ITK/IsiXITKResampler.h"
#import "Adapters/VTK/IsiXVTKContour.h"
// The windows of ViewerController+WindowLifecycle.swift and +FullScreen: the
// full screen window, and the detach of AppKit's Autounbinder before the close.
#import "NSFullScreenWindow.h"
#import "ViewerAutounbinderDetach.h"
#import "OSIGeometry.h"
#import "OSIROI.h"
#import "OSIROIManager.h"
#import "MPRHostMessages.h"
// What DCMPix keeps in Objective-C (DCMPix.swift is its implementation).
#import "DCMPix+CAPI.h"
#import "DCMTKFileFormat.h"
#import "ThickSlabController.h"
#import "DCMPix+NonDICOMCAPI.h"
#import "Window3DController+SwiftIvars.h"
// The browser's matrix outlet is a BrowserMatrix.
#import "BrowserMatrix.h"
// The query nodes, the send and the listener's C-MOVE destinations reach DCMTK
// through its adapter, whose headers carry no C++.
#import "Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCU.h"
// The Query window reads the DICOM dictionary through the same adapter.
#import "Adapters/DCMTK/IsiXDCMTKDictionary.h"
#import "Adapters/DCMTK/IsiXDCMTKStoreSCU.h"
#import "Adapters/DCMTK/IsiXDCMTKMoveDestination.h"
// The listener (DCMTKQueryRetrieveSCP.swift) and its database
// (SCPDatabaseSession*.swift) are served by the same adapter.
#import "Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCP.h"
// The codecs AppController registers, the browser's and the database's
// transcoding, the media scan's DICOMDIR, the key objects of an image, the XML
// editor's tag editing and dcmodify-style command line go through the same
// adapter.
#import "Adapters/DCMTK/IsiXDCMTKCodecs.h"
#import "Adapters/DCMTK/IsiXDCMTKTranscoding.h"
#import "Adapters/DCMTK/IsiXDCMTKDicomDir.h"
#import "Adapters/DCMTK/IsiXDCMTKStructuredReportReader.h"
#import "Adapters/DCMTK/IsiXDCMTKTagEditor.h"
#import "Adapters/DCMTK/IsiXDCMTKModifyCLI.h"
#import "Adapters/DCMTK/IsiXDCMTKAnonymizer.h"
// The 3D view's Metal host reads VTK through its adapter, whose headers carry
// no C++; the presenter and the ROI canvas are what the adapter draws with.
#import "Adapters/VTK/IsiXVTKError.h"
#import "Adapters/VTK/IsiXVTKFramePresenter.h"
#import "Adapters/VTK/IsiXVTKVolumeScene.h"
#import "Adapters/VTK/IsiXVTKScene.h"
#import "Adapters/VTK/IsiXVTKSceneOverlay.h"
// VRView (VRView.swift) reaches its VTK objects through the adapter; the
// fly-thru's splines, the thick slab's opacity and the ROI volumes' surfaces
// reach VTK through it too.
#import "Adapters/VTK/IsiXVTKVolumeView.h"
#import "Adapters/VTK/IsiXVTKCurves.h"
#import "Adapters/VTK/IsiXVTKRendererProps.h"
#import "OrthogonalMPRViewer.h"
#import "OrthogonalMPRPETCTViewer.h"
// The CPR views are Swift subclasses of DCMView, and their window's
// controller and CPRView are Swift too.
#import "CPRController.h"
#import "CPRView.h"
#import "CPRMPRDCMView.h"
#import "CPRStretchedView.h"
#import "CPRStraightenedView.h"
#import "CPRTransverseView.h"
#import "CPRDisplayInfo.h"
#import "CPRGeneratorRequest.h"
#import "N3BezierCoreAdditions.h"
#import "NSColor+N2.h"
// The DicomDatabase blocks derive series UIDs and print the stack of
// the exceptions the database upgrade caught.
#import "HorosDerivedUID.h"
#import "NSException+N2.h"
#import "FlyAssistant.h"
#import "EndoscopyViewer.h"
// OrthogonalMPRController copies the brush lines of the plain ROIs into
// the resliced views.
#import "HorosMPRBrush.h"
// The opening scale to fit finds the content bounds of the pixels. The
// header defines C functions that are not valid C++, and the Objective-C++
// files read this header through Horos-Swift.h: Swift, which reads it as
// Objective-C, is the only reader that needs it.
#ifndef __cplusplus
#import "HorosContentBounds.h"
#endif

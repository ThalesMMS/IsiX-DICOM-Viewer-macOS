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
#import "N2Connection.h"
#import "N2ConnectionListener.h"
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
#import "N2OpenGLViewWithSplitsWindow.h"
#import "N2Operators.h"
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
#import "N2XMLRPCConnection.h"
#import "N2XMLRPCWebServiceClient.h"
#import "HorosObjCException.h"
#import "N2MinMax.h"
#import "N2CellDescriptor.h"
#import "NSView+N2.h"
#import "NS(Attributed)String+Geometrics.h"
#import "NSUserDefaultsController+N2.h"
#import "SMTPClient.h"
#import "NSThread+N2.h"
#import "NSFileManager+N2.h"
#import "NSString+SymlinksAndAliases.h"
// #711: the preference panes.
#import "NSPreferencePane+OsiriX.h"
#import "CIAPlaceHolder.h"
#import "OSICustomImageAnnotations.h"
#import "DNDArrayController.h"
#import "DICOMTLS.h"
#import "DDKeychain.h"
#import "url.h"
#import "DefaultsOsiriX.h"
#import "NSUserDefaults+OsiriX.h"
#import "AppController.h"
#import "WindowLayoutManager.h"
#import "PluginManager.h"
#import "DCMAbstractSyntaxUID.h"
#import "BrowserControllerDCMTKCategory.h"
#import "DicomFile.h"
#import "WaitRendering.h"
#import "PreferencesWindowController+DCMTK.h"
#import "CIADICOMField.h"
#import "HorosAlertPanel.h"
#import "WebPortal.h"
#import "WebPortalDatabase.h"
#import "WebPortalUser.h"
#import "DCMNetServiceDelegate.h"
#import "DicomAlbum.h"
#import "sourcesTableView.h"
#import "AYDicomPrintWindowController.h"
// #711: PreferencesWindowController.authView, and the General pane's language rows.
#import "SFHorosAuthorizationView.h"
#import "../../Preference Panes/OSIGeneralPreferencePane/HorosLanguagePreferences.h"
// #712: the anonymization engine and interface (the panels' AnonymizationPanelEnds
// and AnonymizationSavePanelEnds values, and the DICOM tags they list).
#import "DCMAttributeTag.h"
#import "DCMAttribute.h"
#import "DCMTagDictionary.h"
#import "DCMCalendarDate.h"
#import "HorosDCMTKObject.h"
#import "Wait.h"
#import "HorosAnonymizationSafety.h"
#import "HorosGDCMAnonymizer.h"
#import "AnonymizationPanelController.h"
#import "AnonymizationSavePanelController.h"
// #713: QueryArrayController -parameters, and the DCMTK part it sends to;
// ThumbnailCell sizes itself by the O2ViewerThumbnailsMatrixRepresentedObject
// the viewer gives it.
#import "DCMTransferSyntax.h"
#import "QueryArrayController+DCMTK.h"
#import "O2ViewerThumbnailsMatrix.h"
// #713: the smart album predicate editor.
#import "O2DicomPredicateEditor.h"
#import "O2DicomPredicateEditorView.h"
#import "O2DicomPredicateEditorCodeStrings.h"
#import "O2DicomPredicateEditorDCMAttributeTag.h"
#import "O2DicomPredicateEditorPopUpButton.h"
#import "O2DicomPredicateEditorDatePicker.h"
#import "O2DicomPredicateEditorFormatters.h"
// #714: the viewer's auxiliary windows read the ROI and its notifications, the
// calibration parser, the histogram size, the split view's scaling helper, the
// switch cell's colours and the navigator window the thumbnails sit below.
#import "Notifications.h"
#import "ROI.h"
#import "MyPoint.h"
#import "HorosCalibration.h"
#import "HistogramWindow.h"
#import "KFSplitView.h"
#import "OnOffSwitchControlCell.h"
#import "NavigatorWindowController.h"
// #715: the 3D viewers' editing panels. Window3DController is the superclass
// of ROIVolumeController; the host bridges send what VRView.h, SRView.h,
// Spline3D.h, Piecewise3D.h, ROIVolume.h, ROIVolumeView.h and ThickSlabVR.h
// declare in C++ headers.
#import "Window3DController.h"
#import "Camera.h"
#import "Point3D.h"
#import "Interpolation3D.h"
#import "QuicktimeExport.h"
#import "DICOMExport.h"
#import "CLUTOpacityViewVRBridge.h"
#import "FlyThruHostBridge.h"
#import "ROIVolumeHostBridge.h"
#import "ROIVolumeViewHostBridge.h"
#import "ThickSlabHostBridge.h"
// #717: DICOM print (AYNSImageToDicom's enum, struct and FULL32BITPIPELINE, the
// DICOMExport writer, the viewer's window flags, the OpenGL font reset, the
// printers' echo, the password generator's C function); the disc burner
// (burnerDestination, DICOMDIR, the DCMTK categories, the bounded tasks); the
// reports (the DicomStudy (Report) category, the report templates' helpers, the
// DICOM PDF writer and the sequences a report field reads through).
#import "AYNSImageToDicom.h"
#import "DICOMExport.h"
#import "OSIWindow.h"
#import "QueryController.h"
#import "PSGenerator.h"
#import "BurnerWindowController.h"
#import "BrowserController+Sources.h"
#import "DicomDatabase+DCMTK.h"
#import "DicomDir.h"
#import "DicomFileDCMTKCategory.h"
#import "DicomStudy+Report.h"
#import "DCMUIDs.h"
#import "Horos.h"
#import "HorosBoundedTask.h"
#import "MutableArrayCategory.h"
#import "DCMSequenceAttribute.h"
#import "HorosDICOMWriter.h"
#import "HorosReportFileReplacement.h"
#import "HorosReportFields.h"
#import "HorosOpenDocument.h"
#import "HorosPagesCompatibility.h"
// #716: the send interface (transfer syntax codes, and DCMTKStoreSCU, which
// stays Objective-C++ behind a pure Objective-C header); WADODownload's log,
// abort check and N2LogStackTrace helper; the C functions CSMailMailClient,
// BLAuthentication, ThreadCell and ThreadModalForWindowController keep in their
// +CAPI.m; NSString (DICOMToNSString) hands the character set to the one table;
// NSError (OsiriX) names its domain.
#import "SendController.h"
#import "DCMTKStoreSCU.h"
#import "CSMailMailClient.h"
#import "BLAuthentication.h"
#import "LogManager.h"
#import "HorosDICOMGlobalAbort.h"
#import "WADODownload.h"
#import "ThreadCell.h"
#import "ThreadModalForWindowController.h"
#import "DCMCharacterSet.h"
#import "NSError+OsiriX.h"
// #718: the web portal. The cocoahttpserver classes the connection, the
// responses and the server subclass (HTTPConnection, HTTPResponse, AsyncSocket,
// DDData) stay Objective-C; the portal's own classes are Swift behind their
// compatibility headers, and the data routes reach DCM, the path checks and
// the Core Data helpers.
#import "AsyncSocket.h"
#import "DDData.h"
#import "HTTPConnection.h"
#import "HTTPResponse.h"
#import "WebPortalConnection.h"
#import "WebPortalConnection+Data.h"
#import "WebPortalResponse.h"
#import "WebPortalSession.h"
#import "WebPortalStudy.h"
#import "WebPortal+Email+Log.h"
#import "HorosWebPathSafety.h"
#import "NSManagedObject+N2.h"
#import "NSImage+OsiriX.h"
#import "DCM.h"
// #719: the CPR generator and its operations sample the volume through the C
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
// #720: the plugin manager builds the plugin SDK's environment and volume
// windows, and its window controller reads the catalog through the transport
// helpers, whose manual retain/release lines are guarded for ARC.
#import "OSIEnvironment.h"
#import "OSIVolumeWindow.h"
#import "PluginManagerController.h"
#import "HorosPluginCatalogTransport.h"
// #721: the Core Data entities. DataNodeIdentifier and LocalDatabaseNodeIdentifier
// stay Objective-C, subclassed by BrowserController+Sources; the images and
// studies reach the SR annotations, the XML controller's DCMTK editing and the
// pixel-data import, and remote nodes the remote database.
#import "DataNodeIdentifier.h"
#import "RemoteDicomDatabase.h"
#import "XMLControllerDCMTKCategory.h"
#import "SRAnnotation.h"
#import "DCMObjectPixelDataImport.h"
// #722: the BrowserController and DicomDatabase categories are Swift extensions.
// They read the classes' Objective-C ivars through the private +SwiftIvars
// accessors, which API-Headers.pl keeps out of the SDK's umbrella header; the
// sources list scans volumes with HorosVolumeDiscovery and the database's scan.
#import "BrowserController+SwiftIvars.h"
#import "DicomDatabase+SwiftIvars.h"
#import "DicomDatabase+Scan.h"
#import "HorosVolumeDiscovery.h"

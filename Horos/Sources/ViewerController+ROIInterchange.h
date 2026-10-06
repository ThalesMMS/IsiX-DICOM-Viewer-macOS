/*
 ViewerController+ROIInterchange.h
 Horos

 Export and import of ROIs in the open JSON interchange format. The schema,
 validation and image matching live in ROIInterchange.swift; this category
 converts between the interchange records and ROI/DCMPix objects and drives
 the UI.
*/

// The ViewerController (ROIInterchange) category is implemented in Swift
// (ViewerController+ROIInterchange.swift). This header keeps
// <Horos/ViewerController+ROIInterchange.h>: the generated interface declares
// +installROIInterchangeMenuItems, -roiExportInterchange:,
// -exportROIInterchangeToURL:error:, -importROIInterchangeFromPath:error:,
// -importROIArchiveFromPath:error:, -importROIFiles:error:,
// -roiLoadFromInterchangeFile: and -presentROIImportErrorForPath:error: in a
// category of ViewerController.

#import "ViewerController.h"

#ifndef HOROS_BRIDGING_HEADER
#import "Horos-Swift.h"
#endif

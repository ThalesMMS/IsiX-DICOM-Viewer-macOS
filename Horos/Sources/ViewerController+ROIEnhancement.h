/*
 ViewerController+ROIEnhancement.h
 Horos

 Sample the open 4D series with computeROI, matching ROI Enhancement II 2.3.1.
 The curve lives in ROIEnhancement.swift; this category only reads DCMPix
 pixels / acquisition times and the current-slice ROIs.
*/

// The ViewerController (ROIEnhancement) category is implemented in Swift since
// #722 (ViewerController+ROIEnhancement.swift). This header keeps
// <Horos/ViewerController+ROIEnhancement.h>: the generated interface declares
// -roiEnhancementProcessCurrentSeries in a category of ViewerController that
// adopts ROIEnhancementViewerProcessing.

#import "ViewerController.h"

#ifndef HOROS_BRIDGING_HEADER
#import "Horos-Swift.h"
#endif

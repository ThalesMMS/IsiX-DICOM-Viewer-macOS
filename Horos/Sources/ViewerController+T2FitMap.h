/*
 ViewerController+T2FitMap.h
 Horos

 Apply the native T2 Fit Map to the open multi-echo series.
 The fit lives in T2FitMap.swift; this category only reads DCMPix
 echo times / pixels and opens the resulting map.
*/

// The ViewerController (T2FitMap) category is implemented in Swift since #722
// (ViewerController+T2FitMap.swift). This header keeps
// <Horos/ViewerController+T2FitMap.h>: the generated interface declares
// -t2FitMapProcessCurrentSeries in a category of ViewerController that adopts
// T2FitMapViewerProcessing.

#import "ViewerController.h"

#ifndef HOROS_BRIDGING_HEADER
#import "Horos-Swift.h"
#endif

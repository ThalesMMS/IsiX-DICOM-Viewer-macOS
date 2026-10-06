// BrowserController (GSPS) is implemented in Swift
// (Horos/Sources/BrowserController+GSPS.swift). This header keeps
// <Horos/BrowserController+GSPS.h>: the generated interface declares the Swift
// extension of BrowserController with the same selector:
//
// - (BOOL)horos_tryOpenGSPSSeries:(DicomSeries *)series
//                          viewer:(ViewerController *)viewer
//                   keyImagesOnly:(BOOL)keyImages
//                   openedViewer:(ViewerController **)outViewer;
//
// If `series` is a Softcopy Presentation State, it opens the referenced images
// (when they are in the same study) and applies the documented GSPS subset.
// It returns YES when the series was handled as a presentation state, even if
// every reference is missing — in that case no empty viewer is opened.

#import "BrowserController.h"

@class DicomSeries;
@class ViewerController;

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the extension itself.
#else
#import "Horos-Swift.h"
#endif

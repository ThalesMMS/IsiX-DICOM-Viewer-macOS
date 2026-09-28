// The VR view's 2D layer without VTK drawing it (#731): the text actors, the
// 2D actors and the orientation cube stay VTK objects that hold what to show,
// and HorosVROverlay draws them over the volume.

#import "VRView.h"

@interface VRView (Overlay)

/// Starts drawing the view's 2D actors over the volume instead of in VTK's
/// render, around each render of its renderer.
- (void) horosObserveOverlay;
- (void) horosForgetOverlay;

/// Draws the view's visible 2D actors and the orientation cube in the overlay.
- (void) horosDrawOverlay;

@end

// A VTK scene presented by Metal, without VTK's OpenGL view (#733): what
// VTKView and vtkCocoaGLView gave the surface and ROI volume views. VTK keeps
// the camera and the props, and renders through HorosVRRenderWindow and
// HorosVRRenderer, which draw with HorosVRPresenter into a CAMetalLayer. The
// mouse moves the camera through HorosVRInteractor as VTK's trackball style
// did, and the 2D actors, the orientation cube and a picked prop's outline are
// drawn on the annotation overlay.

#import <AppKit/AppKit.h>

#ifdef __cplusplus
#include "VRPresentation.h"
#include "VRInteraction.h"
class vtkActor;
#else
typedef char* HorosVRRenderWindow;
typedef char* HorosVRRenderer;
typedef char* HorosVRInteractor;
typedef char* HorosBoxWidget;
#endif

@class HorosVRPresenter;
@class HorosStereoPresentation;

@interface HorosSceneView : NSView
{
    HorosVRRenderWindow *sceneWindow;
    HorosVRRenderer *sceneRenderer;
    HorosVRInteractor *sceneInteractor;
    HorosVRPresenter *scenePresenter;
    void *scenePicked;
    unsigned long sceneOverlayTag;
    BOOL sceneCubeShown;
    /// The Stereo menu's mode and the right eye's picture (#734).
    HorosStereoPresentation *sceneStereo;
}

#ifdef __cplusplus
/// The renderer and the window VTK renders through, and the interactor that
/// takes VTK's mouse events, as vtkCocoaGLView had them.
- (vtkRenderer *) renderer;
- (vtkRenderWindow *) renderWindow;
- (vtkRenderWindow *) getVTKRenderWindow;
- (HorosVRInteractor *) getInteractor;
/// The crop box drawn over the scene, if any; none here.
- (HorosBoxWidget *) horosOverlayBoxWidget;
/// The prop the last pick found, or nil.
- (vtkActor *) horosPickedActor;
#endif

/// Brings the window's size in line with the view's, in pixels. NO when
/// there is nothing to render into.
- (BOOL) prepareRenderWindow;
/// Kept for callers of VTKView's: nothing to unlink any more.
- (void) prepareForRelease;
- (void) removeAllActors;

/// Whether the annotated orientation cube is drawn in the top right corner.
@property (nonatomic) BOOL horosOrientationCubeShown;

/// The actors 'p' can pick, as NSValue pointers; none here.
- (NSArray *) horosPickableActors;
/// Picks the pickable actor nearest the viewer under a position in pixels
/// from the bottom left, as vtkPropPicker did for spheres.
- (void) horosPickAtX:(double) x y:(double) y;
- (void) horosClearPick;

/// The Stereo menu (#734): its items' tags are the modes of
/// HorosStereoPresentation; a sender that is not a menu item switches red/blue
/// on and off, as the toolbar button did.
- (IBAction) SwitchStereoMode:(id) sender;
/// The Stereo menu's mode in effect; two screens fall back to one on one screen.
- (NSInteger) horosStereoMode;
- (void) horosSetStereoMode:(NSInteger) mode;
/// Called when stereo goes on or off: what a subclass hides in stereo.
- (void) horosStereoDidChange:(BOOL) on;
- (IBAction) invertedSides:(id) sender;
/// Sets the view and eye angles for a screen `height` high seen from
/// `distance`, the eyes `separation` apart, in the same unit.
- (void) horosSetStereoScreenHeight:(double) height distance:(double) distance eyeSeparation:(double) separation;

/// Hands a mouse event to the interactor as vtkCocoaGLView did: its position
/// in pixels from the bottom left, control or command as control.
- (void) horosInvokeVTKEvent:(unsigned long) eventId forEvent:(NSEvent *) event;

/// Redraws the overlay after each render.
- (void) horosDrawOverlay;

@end

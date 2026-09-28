// The 2D layer of a VTK scene without VTK drawing it (#731, #733). VTK's text
// and 2D actors stay VTK objects that hold what to show; this draws them,
// with the orientation cube, the crop box and a picked prop's outline, on the
// view's annotation overlay, as VTK drew them over the 3D picture.

#import <AppKit/AppKit.h>

#ifdef __cplusplus
#include <vector>

class vtkRenderer;
class vtkActor;
class vtkActor2D;
class HorosBoxWidget;

struct HorosSceneOverlayExtras {
    /// The annotated orientation cube in the top right corner.
    bool cube = false;
    /// The crop box, drawn when enabled.
    HorosBoxWidget *box = nullptr;
    /// The prop the last pick found, outlined in red.
    vtkActor *picked = nullptr;
};

/// The renderer's visible 2D actors.
std::vector<vtkActor2D *> HorosVisibleActors2D(vtkRenderer *renderer);

/// Draws `shown` and the extras on the overlay of `view`, in the renderer's
/// display pixels.
void HorosDrawSceneOverlay(NSView *view, vtkRenderer *renderer, const std::vector<vtkActor2D *> &shown,
                           const HorosSceneOverlayExtras &extras);
#endif

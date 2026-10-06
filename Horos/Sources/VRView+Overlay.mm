// The VR view's 2D layer without VTK drawing it. See VRView+Overlay.h.

#import "VRView+Overlay.h"
#import "SceneOverlay.h"
#import "Horos-Swift.h"
#import "ROICanvasGL.h"

#include <map>
#include <vector>
#include <algorithm>
#include <vtkRenderer.h>
#include <vtkRenderWindow.h>
#include <vtkActor2D.h>
#include <vtkActor2DCollection.h>
#include <vtkPropCollection.h>
#include <vtkNew.h>
#include <vtkTextActor.h>
#include <vtkTextProperty.h>
#include <vtkProperty2D.h>
#include <vtkPolyDataMapper2D.h>
#include <vtkPolyData.h>
#include <vtkCellArray.h>
#include <vtkAlgorithm.h>
#include <vtkCoordinate.h>
#include <vtkCamera.h>
#include <vtkMatrix4x4.h>
#include <vtkCallbackCommand.h>

namespace {
struct OverlayState {
    vtkRenderer *renderer = nullptr;
    unsigned long startTag = 0, endTag = 0;
    /// The 2D actors that were visible when the render started, hidden from
    /// VTK for the render and drawn by the overlay after it.
    std::vector<vtkActor2D *> shown;
};
std::map<VRView *, OverlayState> states;
}

@implementation VRView (Overlay)

- (void) horosObserveOverlay
{
    OverlayState &state = states[self];
    if( state.renderer == aRenderer) return;
    [self horosForgetOverlay];
    OverlayState &fresh = states[self];
    fresh.renderer = aRenderer;
    
    // After the view's own start observers, which place and show the
    // measurements for this render.
    vtkCallbackCommand *start = vtkCallbackCommand::New();
    start->SetClientData( self);
    start->SetCallback([](vtkObject *, unsigned long, void *context, void *) {
        VRView *view = (VRView *) context;
        auto found = states.find( view);
        if( found == states.end()) return;
        OverlayState &s = found->second;
        for( vtkActor2D *actor : s.shown) actor->SetVisibility( 1);
        s.shown.clear();
        // Collect each prop's 2D actors, including assemblies, just as the
        // former viewport GetActors2D implementation did.
        vtkNew<vtkActor2DCollection> actors;
        vtkPropCollection *props = s.renderer->GetViewProps();
        vtkCollectionSimpleIterator iterator;
        props->InitTraversal(iterator);
        while (vtkProp *prop = props->GetNextProp(iterator)) prop->GetActors2D(actors);
        actors->InitTraversal();
        while( vtkActor2D *actor = actors->GetNextActor2D())
        {
            if( actor->GetVisibility())
            {
                s.shown.push_back( actor);
                actor->SetVisibility( 0);
            }
        }
    });
    fresh.startTag = aRenderer->AddObserver( vtkCommand::StartEvent, start, -1.0);
    start->Delete();
    
    vtkCallbackCommand *end = vtkCallbackCommand::New();
    end->SetClientData( self);
    end->SetCallback([](vtkObject *, unsigned long, void *context, void *) {
        VRView *view = (VRView *) context;
        auto found = states.find( view);
        if( found == states.end()) return;
        for( vtkActor2D *actor : found->second.shown) actor->SetVisibility( 1);
        [view horosDrawOverlay];
        for( vtkActor2D *actor : found->second.shown) actor->SetVisibility( 1);
        found->second.shown.clear();
    });
    fresh.endTag = aRenderer->AddObserver( vtkCommand::EndEvent, end);
    end->Delete();
}

- (void) horosForgetOverlay
{
    auto found = states.find( self);
    if( found == states.end()) return;
    OverlayState &s = found->second;
    for( vtkActor2D *actor : s.shown) actor->SetVisibility( 1);
    if( s.renderer)
    {
        s.renderer->RemoveObserver( s.startTag);
        s.renderer->RemoveObserver( s.endTag);
    }
    states.erase( found);
}

- (void) horosDrawOverlay
{
    auto found = states.find( self);
    if( found == states.end()) return;
    HorosSceneOverlayExtras extras;
    // In stereo, the cube and the orientation letters go away, as they did
    // from the original stereo mode.
    BOOL stereo = [self horosStereoMode] != 0;
    extras.cube = orientationCubeShown && !stereo;
    extras.box = croppingBox;
    extras.picked = display3DPoints ? horosPicked3DPoint : nullptr;
    std::vector<vtkActor2D *> shown = found->second.shown;
    if( stereo)
        shown.erase( std::remove_if( shown.begin(), shown.end(), [self]( vtkActor2D *actor) {
            return std::find( oText, oText + 4, actor) != oText + 4;
        }), shown.end());
    HorosDrawSceneOverlay( self, aRenderer, shown, extras);
}
@end

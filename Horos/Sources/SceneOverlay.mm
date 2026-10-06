// The 2D layer of a VTK scene drawn without VTK: the text
// actors, the 2D actors, the orientation cube, the crop box and the outline of
// a picked prop, drawn with the annotation overlay over the view's frame.
// See SceneOverlay.h.

#import "SceneOverlay.h"
#import "Horos-Swift.h"
#import "ROICanvasGL.h"
#import "VRInteraction.h"

#include <vtkRenderer.h>
#include <vtkRenderWindow.h>
#include <vtkActor.h>
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

std::vector<vtkActor2D *> HorosVisibleActors2D(vtkRenderer *renderer)
{
    std::vector<vtkActor2D *> shown;
    if( renderer == nullptr) return shown;
    vtkNew<vtkActor2DCollection> actors;
    vtkPropCollection *props = renderer->GetViewProps();
    vtkCollectionSimpleIterator iterator;
    for( props->InitTraversal(iterator); vtkProp *prop = props->GetNextProp(iterator);)
        prop->GetActors2D(actors);
    actors->InitTraversal();
    while( vtkActor2D *actor = actors->GetNextActor2D())
        if( actor->GetVisibility()) shown.push_back( actor);
    return shown;
}

void HorosDrawSceneOverlay(NSView *view, vtkRenderer *aRenderer, const std::vector<vtkActor2D *> &shown, const HorosSceneOverlayExtras &extras)
{
    vtkRenderWindow *window = aRenderer ? aRenderer->GetRenderWindow() : nullptr;
    if( view == nil || window == nullptr) return;
    int *size = window->GetSize();
    int width = size[0], height = size[1];
    if( width <= 0 || height <= 0) return;
    
    NSView *existing = [[view subviews] lastObject];
    HorosBoxWidget *croppingBox = extras.box;
    bool boxShown = croppingBox && croppingBox->GetEnabled();
    vtkActor *picked = extras.picked;
    bool orientationCubeShown = extras.cube;
    vtkCamera *aCamera = aRenderer->GetActiveCamera();
    if( shown.empty() && !orientationCubeShown && !boxShown && !picked && ![existing isKindOfClass: [HorosAnnotationOverlay class]])
        return;
    
    CGFloat scale = view.window.backingScaleFactor > 0 ? view.window.backingScaleFactor : 1;
    HorosAnnotationOverlay *overlay = [HorosAnnotationOverlay overlayForView: view];
    [overlay beginFrameWidth: width height: height];
    HorosROICanvas *canvas = overlay.canvas;
    // Display pixels, from the bottom left, as VTK's 2D actors hold them.
    [canvas setModelview: CGAffineTransformMake( 2.0 / width, 0, 0, 2.0 / height, -1, -1) viewport: NSMakeRect( 0, 0, width, height)];
    
    if( orientationCubeShown && aCamera)
    {
        vtkMatrix4x4 *view = aCamera->GetViewTransformMatrix();
        NSMutableArray *matrix = [NSMutableArray arrayWithCapacity: 16];
        for( int r = 0; r < 4; r++) for( int c = 0; c < 4; c++) [matrix addObject: @(view->GetElement( r, c))];
        CGContextRef context = [canvas modelContext];
        if( context)
            [HorosVROverlay drawOrientationCubeIn: context rect: CGRectMake( 0.9 * width, 0.9 * height, 0.1 * width, 0.1 * height)
                                     viewRotation: matrix
                                           labels: @[NSLocalizedString( @"L", @"L: Left"), NSLocalizedString( @"R", @"R: Right"),
                                                     NSLocalizedString( @"P", @"P: Posterior"), NSLocalizedString( @"A", @"A: Anterior"),
                                                     NSLocalizedString( @"S", @"S: Superior"), NSLocalizedString( @"I", @"I: Inferior")]];
    }
    
    // The crop box, which VTK drew as 3D geometry.
    if( boxShown) croppingBox->Draw();
    
    // The picked point's bounds, in red, as vtkInteractorStyle outlined it.
    if( picked)
    {
        double *bounds = picked->GetBounds(), corner[8][3];
        for( int i = 0; i < 8; i++)
            HorosVRInteractor::ComputeWorldToDisplay( aRenderer, bounds[i & 1], bounds[2 + ((i >> 1) & 1)], bounds[4 + ((i >> 2) & 1)], corner[i]);
        roiDisable( GL_BLEND);
        roiColor4f( 1, 0, 0, 1);
        roiLineWidth( 1);
        roiBegin( GL_LINES);
        for( int i = 0; i < 8; i++)
            for( int axis = 0; axis < 3; axis++)
                if( ( i & (1 << axis)) == 0)
                {
                    roiVertex2f( corner[i][0], corner[i][1]);
                    roiVertex2f( corner[i | (1 << axis)][0], corner[i | (1 << axis)][1]);
                }
        roiEnd();
    }
    
    double dpi = window->GetDPI() > 0 ? window->GetDPI() : 72.0 * scale;
    for( vtkActor2D *actor : shown)
    {
        if( vtkTextActor *text = vtkTextActor::SafeDownCast( actor))
        {
            const char *input = text->GetInput();
            if( input == nullptr) continue;
            vtkTextProperty *property = text->GetTextProperty();
            double colour[3]; property->GetColor( colour);
            int *anchor = text->GetPositionCoordinate()->GetComputedDisplayValue( aRenderer);
            const char *family = property->GetFontFamilyAsString();
            [HorosVROverlay addText: [NSString stringWithUTF8String: input] ?: @""
                         fontFamily: family ? [NSString stringWithUTF8String: family] : @"Arial"
                           fontSize: property->GetFontSize() * dpi / 72.0
                               bold: property->GetBold() != 0
                                red: colour[0] green: colour[1] blue: colour[2] opacity: property->GetOpacity()
                                  x: anchor[0] y: anchor[1]
                      justification: property->GetJustification()
              verticalJustification: property->GetVerticalJustification()
                         viewHeight: height scale: scale window: view.window overlay: overlay];
            continue;
        }
        
        vtkPolyDataMapper2D *mapper = vtkPolyDataMapper2D::SafeDownCast( actor->GetMapper());
        if( mapper == nullptr) continue;
        if( mapper->GetInputAlgorithm()) mapper->GetInputAlgorithm()->Update();
        vtkPolyData *data = mapper->GetInput();
        if( data == nullptr || data->GetNumberOfPoints() == 0) continue;
        int *origin = actor->GetPositionCoordinate()->GetComputedDisplayValue( aRenderer);
        vtkProperty2D *property = actor->GetProperty();
        double colour[3]; property->GetColor( colour);
        double opacity = property->GetOpacity();
        
        if( opacity < 1)
        {
            roiEnable( GL_BLEND);
            roiBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        }
        else roiDisable( GL_BLEND);
        roiColor4f( colour[0], colour[1], colour[2], opacity);
        
        auto cells = [&]( vtkCellArray *array, GLenum mode) {
            if( array == nullptr || array->GetNumberOfCells() == 0) return;
            vtkIdType count; const vtkIdType *ids;
            for( array->InitTraversal(); array->GetNextCell( count, ids); )
            {
                roiBegin( mode);
                for( vtkIdType k = 0; k < count; k++)
                {
                    double p[3]; data->GetPoint( ids[k], p);
                    roiVertex2f( origin[0] + p[0], origin[1] + p[1]);
                }
                roiEnd();
            }
        };
        roiLineWidth( property->GetLineWidth());
        roiPointSize( property->GetPointSize());
        cells( data->GetPolys(), GL_POLYGON);
        cells( data->GetLines(), GL_LINE_STRIP);
        cells( data->GetVerts(), GL_POINTS);
    }
    roiDisable( GL_BLEND);
    
    [overlay commitInverted: NO scale: scale];
}


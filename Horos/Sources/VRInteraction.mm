// The VR view's mouse interaction without VTK's interactor.
// See VRInteraction.h. The camera moves and the box's are VTK's own
// (vtkInteractorStyleTrackballCamera, vtkBoxWidget), kept to the letter so the
// view answers the mouse as it did.

#import "VRInteraction.h"
#import "Horos-Swift.h"
#import "ROICanvasGL.h"

#include <cmath>
#include <vtkObjectFactory.h>
#include <vtkRenderer.h>
#include <vtkRenderWindow.h>
#include <vtkCamera.h>
#include <vtkMath.h>
#include <vtkProp3D.h>
#include <vtkPlanes.h>
#include <vtkPoints.h>
#include <vtkDoubleArray.h>
#include <vtkPolyData.h>
#include <vtkCellArray.h>
#include <vtkTransform.h>
#include <vtkMatrix4x4.h>
#include <vtkProperty.h>

// MARK: - Interactor

vtkStandardNewMacro(HorosVRInteractor);

HorosVRInteractor::HorosVRInteractor() {}

HorosVRInteractor::~HorosVRInteractor() {}

void HorosVRInteractor::SetEventInformation(int x, int y, int control, int shift, char, int repeatCount)
{
    this->LastEventPosition[0] = this->EventPosition[0];
    this->LastEventPosition[1] = this->EventPosition[1];
    this->EventPosition[0] = x;
    this->EventPosition[1] = y;
    this->ControlKey = control;
    this->ShiftKey = shift;
    this->RepeatCount = repeatCount;
}

void HorosVRInteractor::AddWidget(HorosBoxWidget *widget)
{
    for( HorosBoxWidget *w : this->Widgets) if( w == widget) return;
    this->Widgets.push_back( widget);
}

void HorosVRInteractor::RemoveWidget(HorosBoxWidget *widget)
{
    for( auto i = this->Widgets.begin(); i != this->Widgets.end(); ++i)
        if( *i == widget) { this->Widgets.erase( i); break; }
    if( this->Grabbed == widget) this->Grabbed = nullptr;
}

void HorosVRInteractor::Render()
{
    if( this->Renderer && this->Renderer->GetRenderWindow())
        this->Renderer->GetRenderWindow()->Render();
}

void HorosVRInteractor::ComputeWorldToDisplay(vtkRenderer *renderer, double x, double y, double z, double display[3])
{
    renderer->SetWorldPoint( x, y, z, 1.0);
    renderer->WorldToDisplay();
    renderer->GetDisplayPoint( display);
}

void HorosVRInteractor::ComputeDisplayToWorld(vtkRenderer *renderer, double x, double y, double z, double world[4])
{
    renderer->SetDisplayPoint( x, y, z);
    renderer->DisplayToWorld();
    renderer->GetWorldPoint( world);
    if( world[3])
    {
        world[0] /= world[3];
        world[1] /= world[3];
        world[2] /= world[3];
        world[3] = 1.0;
    }
}

int HorosVRInteractor::InvokeEvent(unsigned long event, void *)
{
    if( this->Renderer == nullptr) return 0;

    int button = -1;
    bool press = false, release = false;
    switch( event)
    {
        case vtkCommand::LeftButtonPressEvent: button = 0; press = true; break;
        case vtkCommand::MiddleButtonPressEvent: button = 1; press = true; break;
        case vtkCommand::RightButtonPressEvent: button = 2; press = true; break;
        case vtkCommand::LeftButtonReleaseEvent: button = 0; release = true; break;
        case vtkCommand::MiddleButtonReleaseEvent: button = 1; release = true; break;
        case vtkCommand::RightButtonReleaseEvent: button = 2; release = true; break;
    }

    if( press)
    {
        // The widgets first, as their observers came before the style's.
        for( HorosBoxWidget *widget : this->Widgets)
        {
            if( widget->OnButtonDown( button))
            {
                this->Grabbed = widget;
                return 1;
            }
        }
        if( button == 0)
        {
            if( this->ShiftKey) this->Start( this->ControlKey ? Dollying : Panning);
            else this->Start( this->ControlKey ? Spinning : Rotating);
        }
        else if( button == 1) this->Start( Panning);
        else this->Start( Dollying);
        return 1;
    }

    if( release)
    {
        if( this->Grabbed)
        {
            HorosBoxWidget *widget = this->Grabbed;
            this->Grabbed = nullptr;
            widget->OnButtonUp( button);
            return 1;
        }
        // The style ends whatever it was doing on the left button; the
        // middle and right ones end only their own move.
        if( (button == 0 && this->CurrentState != None) ||
            (button == 1 && this->CurrentState == Panning) ||
            (button == 2 && this->CurrentState == Dollying))
            this->Stop();
        return 1;
    }

    switch( event)
    {
        case vtkCommand::MouseMoveEvent:
            if( this->Grabbed) { this->Grabbed->OnMouseMove(); return 1; }
            switch( this->CurrentState)
            {
                case Rotating: this->Rotate(); break;
                case Panning: this->Pan(); break;
                case Spinning: this->Spin(); break;
                case Dollying: this->Dolly(); break;
                case None: break;
            }
            return 1;
        case vtkCommand::MouseWheelForwardEvent:
        case vtkCommand::MouseWheelBackwardEvent:
        {
            this->Start( Dollying);
            double factor = this->MotionFactor * (event == vtkCommand::MouseWheelForwardEvent ? 0.2 : -0.2) * this->MouseWheelMotionFactor;
            this->Dolly( pow( 1.1, factor));
            this->Stop();
            return 1;
        }
    }
    return 0;
}

void HorosVRInteractor::Start(State state)
{
    this->CurrentState = state;
    if( this->Renderer->GetRenderWindow())
        this->Renderer->GetRenderWindow()->SetDesiredUpdateRate( this->GetDesiredUpdateRate());
}

void HorosVRInteractor::Stop()
{
    this->CurrentState = None;
    if( this->Renderer->GetRenderWindow())
        this->Renderer->GetRenderWindow()->SetDesiredUpdateRate( this->GetStillUpdateRate());
    this->Render();
}

void HorosVRInteractor::Rotate()
{
    vtkRenderWindow *window = this->Renderer->GetRenderWindow();
    if( window == nullptr) return;
    int dx = this->EventPosition[0] - this->LastEventPosition[0];
    int dy = this->EventPosition[1] - this->LastEventPosition[1];
    int *size = window->GetSize();
    double deltaElevation = -20.0 / size[1];
    double deltaAzimuth = -20.0 / size[0];
    vtkCamera *camera = this->Renderer->GetActiveCamera();
    camera->Azimuth( dx * deltaAzimuth * this->MotionFactor);
    camera->Elevation( dy * deltaElevation * this->MotionFactor);
    camera->OrthogonalizeViewUp();
    this->Renderer->ResetCameraClippingRange();
    this->Renderer->UpdateLightsGeometryToFollowCamera();
    this->Render();
}

void HorosVRInteractor::Spin()
{
    double *centre = this->Renderer->GetCenter();
    double newAngle = vtkMath::DegreesFromRadians( atan2( this->EventPosition[1] - centre[1], this->EventPosition[0] - centre[0]));
    double oldAngle = vtkMath::DegreesFromRadians( atan2( this->LastEventPosition[1] - centre[1], this->LastEventPosition[0] - centre[0]));
    vtkCamera *camera = this->Renderer->GetActiveCamera();
    camera->Roll( newAngle - oldAngle);
    camera->OrthogonalizeViewUp();
    this->Render();
}

void HorosVRInteractor::Pan()
{
    vtkCamera *camera = this->Renderer->GetActiveCamera();
    double focus[4], viewPoint[3], newPick[4], oldPick[4];
    camera->GetFocalPoint( focus);
    ComputeWorldToDisplay( this->Renderer, focus[0], focus[1], focus[2], focus);
    double depth = focus[2];
    ComputeDisplayToWorld( this->Renderer, this->EventPosition[0], this->EventPosition[1], depth, newPick);
    ComputeDisplayToWorld( this->Renderer, this->LastEventPosition[0], this->LastEventPosition[1], depth, oldPick);
    double motion[3] = { oldPick[0] - newPick[0], oldPick[1] - newPick[1], oldPick[2] - newPick[2] };
    camera->GetFocalPoint( focus);
    camera->GetPosition( viewPoint);
    camera->SetFocalPoint( motion[0] + focus[0], motion[1] + focus[1], motion[2] + focus[2]);
    camera->SetPosition( motion[0] + viewPoint[0], motion[1] + viewPoint[1], motion[2] + viewPoint[2]);
    this->Renderer->UpdateLightsGeometryToFollowCamera();
    this->Render();
}

void HorosVRInteractor::Dolly()
{
    double *centre = this->Renderer->GetCenter();
    int dy = this->EventPosition[1] - this->LastEventPosition[1];
    this->Dolly( pow( 1.1, this->MotionFactor * dy / centre[1]));
}

void HorosVRInteractor::Dolly(double factor)
{
    vtkCamera *camera = this->Renderer->GetActiveCamera();
    if( camera->GetParallelProjection())
        camera->SetParallelScale( camera->GetParallelScale() / factor);
    else
    {
        camera->Dolly( factor);
        this->Renderer->ResetCameraClippingRange();
    }
    this->Renderer->UpdateLightsGeometryToFollowCamera();
    this->Render();
}

// MARK: - Crop box

vtkStandardNewMacro(HorosBoxWidget);

// Each face's corners, as vtkBoxWidget orders its cells: -x, +x, -y, +y, -z, +z.
static const int BoxFaces[6][4] = { {3, 0, 4, 7}, {1, 2, 6, 5}, {0, 1, 5, 4}, {2, 3, 7, 6}, {0, 3, 2, 1}, {4, 5, 6, 7} };
static const int BoxEdges[12][2] = { {0, 1}, {1, 2}, {2, 3}, {3, 0}, {4, 5}, {5, 6}, {6, 7}, {7, 4}, {0, 4}, {1, 5}, {2, 6}, {3, 7} };

HorosBoxWidget::HorosBoxWidget()
{
    this->HandleProperty = vtkProperty::New();
    this->HandleProperty->SetColor( 1, 1, 1);
    double bounds[6] = {-0.5, 0.5, -0.5, 0.5, -0.5, 0.5};
    double factor = this->PlaceFactor;
    this->PlaceFactor = 1.0;
    this->PlaceWidget( bounds);
    this->PlaceFactor = factor;
}

HorosBoxWidget::~HorosBoxWidget()
{
    if( this->Interactor) this->Interactor->RemoveWidget( this);
    this->HandleProperty->Delete();
}

void HorosBoxWidget::SetInteractor(HorosVRInteractor *interactor)
{
    if( this->Interactor == interactor) return;
    if( this->Interactor) this->Interactor->RemoveWidget( this);
    this->Interactor = interactor;
    if( this->Enabled && this->Interactor) this->Interactor->AddWidget( this);
}

vtkRenderer *HorosBoxWidget::CurrentRenderer()
{
    if( this->Renderer) return this->Renderer;
    return this->Interactor ? this->Interactor->GetRenderer() : nullptr;
}

void HorosBoxWidget::SetEnabled(int enabled)
{
    if( this->Enabled == enabled || this->Interactor == nullptr) return;
    this->Enabled = enabled;
    if( enabled)
    {
        this->Interactor->AddWidget( this);
        this->InvokeEvent( vtkCommand::EnableEvent, nullptr);
    }
    else
    {
        this->Interactor->RemoveWidget( this);
        this->State = Start;
        this->CurrentHandle = this->CurrentHexFace = -1;
        this->OutlineHighlighted = false;
        this->InvokeEvent( vtkCommand::DisableEvent, nullptr);
    }
    this->Interactor->Render();
}

void HorosBoxWidget::PlaceWidget()
{
    double bounds[6] = {-1, 1, -1, 1, -1, 1};
    if( this->Prop3D) this->Prop3D->GetBounds( bounds);
    this->PlaceWidget( bounds);
}

void HorosBoxWidget::PlaceWidget(double bds[6])
{
    double centre[3] = { (bds[0] + bds[1]) / 2.0, (bds[2] + bds[3]) / 2.0, (bds[4] + bds[5]) / 2.0 };
    double b[6];
    for( int i = 0; i < 3; i++)
    {
        b[2 * i] = centre[i] + this->PlaceFactor * (bds[2 * i] - centre[i]);
        b[2 * i + 1] = centre[i] + this->PlaceFactor * (bds[2 * i + 1] - centre[i]);
    }
    const double corners[8][3] = { {b[0], b[2], b[4]}, {b[1], b[2], b[4]}, {b[1], b[3], b[4]}, {b[0], b[3], b[4]},
                                   {b[0], b[2], b[5]}, {b[1], b[2], b[5]}, {b[1], b[3], b[5]}, {b[0], b[3], b[5]} };
    for( int i = 0; i < 8; i++) for( int k = 0; k < 3; k++) this->Points[i][k] = corners[i][k];
    for( int i = 0; i < 6; i++) this->InitialBounds[i] = b[i];
    this->InitialLength = sqrt( (b[1] - b[0]) * (b[1] - b[0]) + (b[3] - b[2]) * (b[3] - b[2]) + (b[5] - b[4]) * (b[5] - b[4]));
    this->PositionHandles();
    this->ComputeNormals();
}

void HorosBoxWidget::PositionHandles()
{
    auto average = [&]( int a, int b, int into) {
        for( int k = 0; k < 3; k++) this->Points[into][k] = (this->Points[a][k] + this->Points[b][k]) / 2.0;
    };
    average( 0, 7, 8);
    average( 1, 6, 9);
    average( 0, 5, 10);
    average( 2, 7, 11);
    average( 1, 3, 12);
    average( 5, 7, 13);
    average( 0, 6, 14);
}

void HorosBoxWidget::ComputeNormals()
{
    for( int k = 0; k < 3; k++)
    {
        this->N[0][k] = this->Points[0][k] - this->Points[1][k];
        this->N[2][k] = this->Points[0][k] - this->Points[3][k];
        this->N[4][k] = this->Points[0][k] - this->Points[4][k];
    }
    vtkMath::Normalize( this->N[0]);
    vtkMath::Normalize( this->N[2]);
    vtkMath::Normalize( this->N[4]);
    for( int k = 0; k < 3; k++)
    {
        this->N[1][k] = -this->N[0][k];
        this->N[3][k] = -this->N[2][k];
        this->N[5][k] = -this->N[4][k];
    }
}

void HorosBoxWidget::GetPlanes(vtkPlanes *planes)
{
    if( planes == nullptr) return;
    this->ComputeNormals();
    vtkPoints *points = vtkPoints::New( VTK_DOUBLE);
    points->SetNumberOfPoints( 6);
    vtkDoubleArray *normals = vtkDoubleArray::New();
    normals->SetNumberOfComponents( 3);
    normals->SetNumberOfTuples( 6);
    double factor = this->InsideOut ? -1.0 : 1.0;
    for( int i = 0; i < 6; i++)
    {
        points->SetPoint( i, this->Points[8 + i]);
        normals->SetTuple3( i, factor * this->N[i][0], factor * this->N[i][1], factor * this->N[i][2]);
    }
    planes->SetPoints( points);
    planes->SetNormals( normals);
    points->Delete();
    normals->Delete();
}

void HorosBoxWidget::GetPolyData(vtkPolyData *polyData)
{
    vtkPoints *points = vtkPoints::New( VTK_DOUBLE);
    points->SetNumberOfPoints( 15);
    for( int i = 0; i < 15; i++) points->SetPoint( i, this->Points[i]);
    vtkCellArray *cells = vtkCellArray::New();
    for( int i = 0; i < 6; i++)
    {
        vtkIdType ids[4] = { BoxFaces[i][0], BoxFaces[i][1], BoxFaces[i][2], BoxFaces[i][3] };
        cells->InsertNextCell( 4, ids);
    }
    polyData->SetPoints( points);
    polyData->SetPolys( cells);
    points->Delete();
    cells->Delete();
}

void HorosBoxWidget::GetTransform(vtkTransform *t)
{
    double *p0 = this->Points[0], *p1 = this->Points[1], *p3 = this->Points[3], *p4 = this->Points[4], *p14 = this->Points[14];
    double initialCentre[3], translate[3], scale[3];
    t->Identity();
    for( int i = 0; i < 3; i++)
    {
        initialCentre[i] = (this->InitialBounds[2 * i + 1] + this->InitialBounds[2 * i]) / 2.0;
        translate[i] = p14[i];
    }
    t->Translate( translate[0], translate[1], translate[2]);
    vtkMatrix4x4 *matrix = vtkMatrix4x4::New();
    this->PositionHandles();
    this->ComputeNormals();
    for( int i = 0; i < 3; i++)
    {
        matrix->SetElement( i, 0, this->N[1][i]);
        matrix->SetElement( i, 1, this->N[3][i]);
        matrix->SetElement( i, 2, this->N[5][i]);
    }
    t->Concatenate( matrix);
    matrix->Delete();
    double vectors[3][3];
    for( int i = 0; i < 3; i++)
    {
        vectors[0][i] = p1[i] - p0[i];
        vectors[1][i] = p3[i] - p0[i];
        vectors[2][i] = p4[i] - p0[i];
    }
    for( int i = 0; i < 3; i++)
    {
        scale[i] = vtkMath::Norm( vectors[i]);
        if( this->InitialBounds[2 * i + 1] != this->InitialBounds[2 * i])
            scale[i] /= this->InitialBounds[2 * i + 1] - this->InitialBounds[2 * i];
    }
    t->Scale( scale[0], scale[1], scale[2]);
    t->Translate( -initialCentre[0], -initialCentre[1], -initialCentre[2]);
}

void HorosBoxWidget::SetTransform(vtkTransform *t)
{
    if( t == nullptr) return;
    t->Update();
    const double *b = this->InitialBounds;
    const double corners[8][3] = { {b[0], b[2], b[4]}, {b[1], b[2], b[4]}, {b[1], b[3], b[4]}, {b[0], b[3], b[4]},
                                   {b[0], b[2], b[5]}, {b[1], b[2], b[5]}, {b[1], b[3], b[5]}, {b[0], b[3], b[5]} };
    for( int i = 0; i < 8; i++) t->InternalTransformPoint( corners[i], this->Points[i]);
    this->PositionHandles();
}

double HorosBoxWidget::HandleRadius()
{
    vtkRenderer *renderer = this->CurrentRenderer();
    if( !this->ValidPick || renderer == nullptr || renderer->GetRenderWindow() == nullptr || renderer->GetActiveCamera() == nullptr)
        return this->HandleSize * 1.5 * this->InitialLength;
    double focal[3], lower[4], upper[4];
    HorosVRInteractor::ComputeWorldToDisplay( renderer, this->LastPickPosition[0], this->LastPickPosition[1], this->LastPickPosition[2], focal);
    double *viewport = renderer->GetViewport();
    int *size = renderer->GetRenderWindow()->GetSize();
    HorosVRInteractor::ComputeDisplayToWorld( renderer, size[0] * viewport[0], size[1] * viewport[1], focal[2], lower);
    HorosVRInteractor::ComputeDisplayToWorld( renderer, size[0] * viewport[2], size[1] * viewport[3], focal[2], upper);
    double radius = 0;
    for( int i = 0; i < 3; i++) radius += (upper[i] - lower[i]) * (upper[i] - lower[i]);
    return sqrt( radius) * 1.5 * this->HandleSize;
}

/// The handle under (x, y), front first, and where it was picked.
int HorosBoxWidget::PickHandle(int x, int y, double pick[3])
{
    vtkRenderer *renderer = this->CurrentRenderer();
    if( renderer == nullptr) return -1;
    double radius = this->HandleRadius(), up[3];
    renderer->GetActiveCamera()->GetViewUp( up);
    int best = -1;
    double bestDepth = 2.0;
    for( int i = 0; i < 7; i++)
    {
        double *c = this->Points[8 + i], centre[3], rim[3];
        HorosVRInteractor::ComputeWorldToDisplay( renderer, c[0], c[1], c[2], centre);
        HorosVRInteractor::ComputeWorldToDisplay( renderer, c[0] + radius * up[0], c[1] + radius * up[1], c[2] + radius * up[2], rim);
        double r = hypot( rim[0] - centre[0], rim[1] - centre[1]) + 1.0;
        if( hypot( x - centre[0], y - centre[1]) <= r && centre[2] < bestDepth)
        {
            best = i;
            bestDepth = centre[2];
            for( int k = 0; k < 3; k++) pick[k] = c[k];
        }
    }
    return best;
}

/// The face under (x, y), front first, and where the ray meets it.
int HorosBoxWidget::PickFace(int x, int y, double pick[3])
{
    vtkRenderer *renderer = this->CurrentRenderer();
    if( renderer == nullptr) return -1;
    double near[4], far[4];
    HorosVRInteractor::ComputeDisplayToWorld( renderer, x, y, 0.0, near);
    HorosVRInteractor::ComputeDisplayToWorld( renderer, x, y, 1.0, far);
    double ray[3] = { far[0] - near[0], far[1] - near[1], far[2] - near[2] };
    int best = -1;
    double bestT = 2.0;
    for( int f = 0; f < 6; f++)
    {
        const double *a = this->Points[BoxFaces[f][0]], *b = this->Points[BoxFaces[f][1]], *d = this->Points[BoxFaces[f][3]];
        double u[3] = { b[0] - a[0], b[1] - a[1], b[2] - a[2] }, v[3] = { d[0] - a[0], d[1] - a[1], d[2] - a[2] }, n[3];
        vtkMath::Cross( u, v, n);
        double denominator = vtkMath::Dot( n, ray);
        if( fabs( denominator) < 1e-12) continue;
        double w[3] = { a[0] - near[0], a[1] - near[1], a[2] - near[2] };
        double t = vtkMath::Dot( n, w) / denominator;
        if( t < 0 || t > 1 || t >= bestT) continue;
        double p[3] = { near[0] + t * ray[0], near[1] + t * ray[1], near[2] + t * ray[2] };
        double q[3] = { p[0] - a[0], p[1] - a[1], p[2] - a[2] };
        double s = vtkMath::Dot( q, u) / vtkMath::Dot( u, u), r = vtkMath::Dot( q, v) / vtkMath::Dot( v, v);
        if( s < -0.001 || s > 1.001 || r < -0.001 || r > 1.001) continue;
        best = f;
        bestT = t;
        for( int k = 0; k < 3; k++) pick[k] = p[k];
    }
    return best;
}

bool HorosBoxWidget::OnButtonDown(int button)
{
    vtkRenderer *renderer = this->CurrentRenderer();
    if( !this->Enabled || this->Interactor == nullptr || renderer == nullptr) return false;
    int x = this->Interactor->GetEventPosition()[0], y = this->Interactor->GetEventPosition()[1];
    if( !renderer->IsInViewport( x, y)) { this->State = Outside; return false; }

    double pick[3];
    int handle = this->PickHandle( x, y, pick);
    int face = handle < 0 ? this->PickFace( x, y, pick) : -1;
    if( handle < 0 && face < 0)
    {
        this->CurrentHandle = this->CurrentHexFace = -1;
        this->OutlineHighlighted = false;
        this->State = Outside;
        return false;
    }
    for( int k = 0; k < 3; k++) this->LastPickPosition[k] = pick[k];
    this->ValidPick = 1;

    if( button == 2)
    {
        this->State = Scaling;
        this->OutlineHighlighted = true;
    }
    else
    {
        this->State = Moving;
        if( button == 1 || (handle < 0 && this->Interactor->GetShiftKey()))
        {
            this->CurrentHandle = 6;
            this->OutlineHighlighted = true;
        }
        else if( handle >= 0)
        {
            this->CurrentHandle = handle;
            this->CurrentHexFace = handle < 6 ? handle : -1;
            this->OutlineHighlighted = handle == 6;
        }
        else
        {
            this->CurrentHandle = 7;
            this->CurrentHexFace = face;
        }
    }
    this->InvokeEvent( vtkCommand::StartInteractionEvent, nullptr);
    this->Interactor->Render();
    return true;
}

void HorosBoxWidget::OnButtonUp(int button)
{
    if( this->State == Outside || (button != 2 && this->State == Start)) return;
    this->State = Start;
    this->CurrentHandle = this->CurrentHexFace = -1;
    this->OutlineHighlighted = false;
    this->InvokeEvent( vtkCommand::EndInteractionEvent, nullptr);
    if( this->Interactor) this->Interactor->Render();
}

void HorosBoxWidget::OnMouseMove()
{
    vtkRenderer *renderer = this->CurrentRenderer();
    if( this->State == Outside || this->State == Start || renderer == nullptr || this->Interactor == nullptr) return;
    vtkCamera *camera = renderer->GetActiveCamera();
    if( camera == nullptr) return;
    int x = this->Interactor->GetEventPosition()[0], y = this->Interactor->GetEventPosition()[1];
    double focal[3], previous[4], pick[4];
    HorosVRInteractor::ComputeWorldToDisplay( renderer, this->LastPickPosition[0], this->LastPickPosition[1], this->LastPickPosition[2], focal);
    HorosVRInteractor::ComputeDisplayToWorld( renderer, this->Interactor->GetLastEventPosition()[0], this->Interactor->GetLastEventPosition()[1], focal[2], previous);
    HorosVRInteractor::ComputeDisplayToWorld( renderer, x, y, focal[2], pick);

    if( this->State == Moving)
    {
        if( this->RotationEnabled && this->CurrentHandle == 7)
        {
            double normal[3];
            camera->GetViewPlaneNormal( normal);
            this->Rotate( x, y, previous, pick, normal);
        }
        else if( this->CurrentHandle == 6) this->Translate( previous, pick);
        else if( this->CurrentHandle >= 0 && this->CurrentHandle < 6)
        {
            this->ComputeNormals();
            static const double axes[6][3] = { {-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1} };
            // The face's own normal, or what the others make of it, as
            // vtkBoxWidget::GetDirection.
            static const int others[6][3] = { {0, 4, 2}, {1, 3, 5}, {2, 0, 4}, {3, 5, 1}, {4, 2, 0}, {5, 1, 3} };
            static const int corners[6][4] = { {0, 3, 4, 7}, {1, 2, 5, 6}, {0, 1, 4, 5}, {2, 3, 6, 7}, {0, 1, 2, 3}, {4, 5, 6, 7} };
            int h = this->CurrentHandle;
            double dir[3] = { axes[h][0], axes[h][1], axes[h][2] };
            this->GetDirection( this->N[others[h][0]], this->N[others[h][1]], this->N[others[h][2]], dir);
            this->MoveFace( previous, pick, dir, corners[h][0], corners[h][1], corners[h][2], corners[h][3]);
        }
    }
    else if( this->State == Scaling) this->Scale( y);

    this->InvokeEvent( vtkCommand::InteractionEvent, nullptr);
    this->Interactor->Render();
}

void HorosBoxWidget::GetDirection(const double nx[3], const double ny[3], const double nz[3], double dir[3])
{
    if( vtkMath::Dot( nx, nx) != 0)
    {
        for( int k = 0; k < 3; k++) dir[k] = nx[k];
        return;
    }
    double dotNy = vtkMath::Dot( ny, ny), dotNz = vtkMath::Dot( nz, nz), y[3];
    if( dotNy != 0 && dotNz != 0) vtkMath::Cross( ny, nz, dir);
    else if( dotNy != 0) { vtkMath::Cross( ny, dir, y); vtkMath::Cross( y, ny, dir); }
    else if( dotNz != 0) { vtkMath::Cross( nz, dir, y); vtkMath::Cross( y, nz, dir); }
}

void HorosBoxWidget::MoveFace(const double *p1, const double *p2, const double *dir, int a, int b, int c, int d)
{
    double v[3] = { p2[0] - p1[0], p2[1] - p1[1], p2[2] - p1[2] }, n[3] = { dir[0], dir[1], dir[2] };
    vtkMath::Normalize( n);
    double f = vtkMath::Dot( v, n);
    for( int corner : { a, b, c, d})
        for( int k = 0; k < 3; k++) this->Points[corner][k] += f * n[k];
    this->PositionHandles();
}

void HorosBoxWidget::Translate(const double *p1, const double *p2)
{
    double v[3] = { p2[0] - p1[0], p2[1] - p1[1], p2[2] - p1[2] };
    for( int i = 0; i < 8; i++) for( int k = 0; k < 3; k++) this->Points[i][k] += v[k];
    this->PositionHandles();
}

void HorosBoxWidget::Scale(int y)
{
    double factor = y > this->Interactor->GetLastEventPosition()[1] ? 1.03 : 0.97;
    double *centre = this->Points[14];
    double c[3] = { centre[0], centre[1], centre[2] };
    for( int i = 0; i < 8; i++) for( int k = 0; k < 3; k++) this->Points[i][k] = factor * (this->Points[i][k] - c[k]) + c[k];
    this->PositionHandles();
}

void HorosBoxWidget::Rotate(int x, int y, const double *p1, const double *p2, const double *vpn)
{
    double v[3] = { p2[0] - p1[0], p2[1] - p1[1], p2[2] - p1[2] }, axis[3];
    vtkMath::Cross( vpn, v, axis);
    if( vtkMath::Normalize( axis) == 0.0) return;
    vtkRenderer *renderer = this->CurrentRenderer();
    int *size = renderer->GetSize();
    int *last = this->Interactor->GetLastEventPosition();
    double l2 = (x - last[0]) * (x - last[0]) + (y - last[1]) * (y - last[1]);
    double theta = 360.0 * sqrt( l2 / (size[0] * size[0] + size[1] * size[1]));
    double *c = this->Points[14];
    vtkTransform *transform = vtkTransform::New();
    transform->Translate( c[0], c[1], c[2]);
    transform->RotateWXYZ( theta, axis);
    transform->Translate( -c[0], -c[1], -c[2]);
    for( int i = 0; i < 8; i++)
    {
        double p[3] = { this->Points[i][0], this->Points[i][1], this->Points[i][2] };
        transform->TransformPoint( p, this->Points[i]);
    }
    transform->Delete();
    this->PositionHandles();
}

void HorosBoxWidget::Draw()
{
    vtkRenderer *renderer = this->CurrentRenderer();
    if( !this->Enabled || renderer == nullptr || renderer->GetActiveCamera() == nullptr) return;
    double display[15][3];
    for( int i = 0; i < 15; i++)
        HorosVRInteractor::ComputeWorldToDisplay( renderer, this->Points[i][0], this->Points[i][1], this->Points[i][2], display[i]);

    // The picked face, yellow at a quarter of opacity.
    if( this->CurrentHexFace >= 0)
    {
        roiEnable( GL_BLEND);
        roiBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        roiColor4f( 1, 1, 0, 0.25);
        roiBegin( GL_POLYGON);
        for( int k = 0; k < 4; k++) roiVertex2f( display[BoxFaces[this->CurrentHexFace][k]][0], display[BoxFaces[this->CurrentHexFace][k]][1]);
        roiEnd();
        roiDisable( GL_BLEND);
    }

    // The edges, white, green while the whole box moves.
    roiLineWidth( 2.0);
    if( this->OutlineHighlighted) roiColor4f( 0, 1, 0, 1);
    else roiColor4f( 1, 1, 1, 1);
    for( int e = 0; e < 12; e++)
    {
        roiBegin( GL_LINES);
        roiVertex2f( display[BoxEdges[e][0]][0], display[BoxEdges[e][0]][1]);
        roiVertex2f( display[BoxEdges[e][1]][0], display[BoxEdges[e][1]][1]);
        roiEnd();
    }

    // The handles, as discs of the spheres' size; the moving one red.
    double radius = this->HandleRadius(), up[3], colour[3];
    renderer->GetActiveCamera()->GetViewUp( up);
    this->HandleProperty->GetColor( colour);
    roiEnable( GL_POINT_SMOOTH);
    for( int i = 0; i < 7; i++)
    {
        double *c = this->Points[8 + i], rim[3];
        HorosVRInteractor::ComputeWorldToDisplay( renderer, c[0] + radius * up[0], c[1] + radius * up[1], c[2] + radius * up[2], rim);
        double r = hypot( rim[0] - display[8 + i][0], rim[1] - display[8 + i][1]);
        if( i == this->CurrentHandle) roiColor4f( 1, 0, 0, 1);
        else roiColor4f( colour[0], colour[1], colour[2], 1);
        roiPointSize( MAX( 2.0, 2.0 * r));
        roiBegin( GL_POINTS);
        roiVertex2f( display[8 + i][0], display[8 + i][1]);
        roiEnd();
    }
    roiDisable( GL_POINT_SMOOTH);
}

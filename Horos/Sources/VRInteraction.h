// The VR view's mouse interaction without VTK's interactor.
//
// HorosVRInteractor takes the mouse events the view used to hand VTK's
// interactor, with the same calls, and moves the camera as
// vtkInteractorStyleTrackballCamera did: rotate, spin, pan and dolly. The crop
// box, HorosBoxWidget, takes the calls the view made to vtkBoxWidget and gets
// the events first, as the widget did; it is drawn over the volume.
//
// C++, because the camera, the renderer and the planes are VTK objects.

#ifndef HOROS_VR_INTERACTION_H
#define HOROS_VR_INTERACTION_H

#ifdef __cplusplus

#include <vector>
#include <vtkObject.h>
#include <vtkCommand.h>

class vtkRenderer;
class vtkProp3D;
class vtkPlanes;
class vtkPolyData;
class vtkTransform;
class vtkProperty;
class HorosBoxWidget;

class HorosVRInteractor : public vtkObject
{
public:
    static HorosVRInteractor *New();
    vtkTypeMacro(HorosVRInteractor, vtkObject);

    void SetRenderer(vtkRenderer *renderer) { this->Renderer = renderer; }
    vtkRenderer *GetRenderer() { return this->Renderer; }

    /// The event's position in display pixels from the bottom left, and its
    /// keys; the previous position becomes the last one, as VTK keeps them.
    void SetEventInformation(int x, int y, int control = 0, int shift = 0, char keyCode = 0, int repeatCount = 0);
    void SetAltKey(int alt) { this->AltKey = alt; }
    int *GetEventPosition() { return this->EventPosition; }
    int *GetLastEventPosition() { return this->LastEventPosition; }
    int GetControlKey() { return this->ControlKey; }
    int GetShiftKey() { return this->ShiftKey; }
    int GetAltKey() { return this->AltKey; }
    int GetRepeatCount() { return this->RepeatCount; }
    bool GetLightFollowCamera() { return true; }

    /// Handles a VTK mouse event: the crop box first, then the camera.
    int InvokeEvent(unsigned long event, void *callData);

    /// Draws the view now, as the interactor's Render() did.
    void Render();

    /// Interaction rates, as vtkRenderWindowInteractor's: the render window's
    /// desired update rate while a camera move lasts, and after it.
    double GetDesiredUpdateRate() { return 15.0; }
    double GetStillUpdateRate() { return 0.0001; }

    void AddWidget(HorosBoxWidget *widget);
    void RemoveWidget(HorosBoxWidget *widget);

    static void ComputeWorldToDisplay(vtkRenderer *renderer, double x, double y, double z, double display[3]);
    static void ComputeDisplayToWorld(vtkRenderer *renderer, double x, double y, double z, double world[4]);

protected:
    HorosVRInteractor();
    ~HorosVRInteractor() override;

private:
    HorosVRInteractor(const HorosVRInteractor &) = delete;
    void operator=(const HorosVRInteractor &) = delete;

    enum State { None, Rotating, Panning, Spinning, Dollying };
    void Start(State state);
    void Stop();
    void Rotate();
    void Spin();
    void Pan();
    void Dolly();
    void Dolly(double factor);

    vtkRenderer *Renderer = nullptr;
    int EventPosition[2] = {0, 0}, LastEventPosition[2] = {0, 0};
    int ControlKey = 0, ShiftKey = 0, AltKey = 0, RepeatCount = 0;
    State CurrentState = None;
    double MotionFactor = 10.0, MouseWheelMotionFactor = 1.0;
    std::vector<HorosBoxWidget *> Widgets;
    HorosBoxWidget *Grabbed = nullptr;
};

/// The crop box as vtkBoxWidget was: eight corners, a handle on each face and
/// one in the middle, picked on the handles or on the faces. A face handle
/// moves its face, the middle one or a shift-picked face moves the box, a
/// picked face rotates it, the right button scales it.
class HorosBoxWidget : public vtkObject
{
public:
    static HorosBoxWidget *New();
    vtkTypeMacro(HorosBoxWidget, vtkObject);

    void SetInteractor(HorosVRInteractor *interactor);
    void SetDefaultRenderer(vtkRenderer *renderer) { this->Renderer = renderer; }
    void SetProp3D(vtkProp3D *prop) { this->Prop3D = prop; }
    vtkProp3D *GetProp3D() { return this->Prop3D; }
    void SetPlaceFactor(double factor) { this->PlaceFactor = factor; }
    void SetHandleSize(double size) { this->HandleSize = size; }
    void SetRotationEnabled(int enabled) { this->RotationEnabled = enabled; }
    void SetInsideOut(int insideOut) { this->InsideOut = insideOut; }
    void OutlineCursorWiresOff() {}
    vtkProperty *GetHandleProperty() { return this->HandleProperty; }

    void PlaceWidget();
    void PlaceWidget(double bounds[6]);

    void On() { this->SetEnabled(1); }
    void Off() { this->SetEnabled(0); }
    void SetEnabled(int enabled);
    int GetEnabled() { return this->Enabled; }

    void GetPlanes(vtkPlanes *planes);
    void GetPolyData(vtkPolyData *polyData);
    void GetTransform(vtkTransform *transform);
    void SetTransform(vtkTransform *transform);

    // The events, from the interactor: YES when the box took the press.
    bool OnButtonDown(int button);
    void OnButtonUp(int button);
    void OnMouseMove();

    /// Draws the box on the current ROI canvas, in display pixels from the
    /// bottom left.
    void Draw();

protected:
    HorosBoxWidget();
    ~HorosBoxWidget() override;

private:
    HorosBoxWidget(const HorosBoxWidget &) = delete;
    void operator=(const HorosBoxWidget &) = delete;

    enum WidgetState { Start, Moving, Scaling, Outside };
    void PositionHandles();
    void ComputeNormals();
    double HandleRadius();
    int PickHandle(int x, int y, double pick[3]);
    int PickFace(int x, int y, double pick[3]);
    void GetDirection(const double nx[3], const double ny[3], const double nz[3], double dir[3]);
    void MoveFace(const double *p1, const double *p2, const double *dir, int a, int b, int c, int d);
    void Translate(const double *p1, const double *p2);
    void Scale(int y);
    void Rotate(int x, int y, const double *p1, const double *p2, const double *vpn);
    vtkRenderer *CurrentRenderer();

    HorosVRInteractor *Interactor = nullptr;
    vtkRenderer *Renderer = nullptr;
    vtkProp3D *Prop3D = nullptr;
    vtkProperty *HandleProperty = nullptr;
    double Points[15][3];
    double N[6][3];
    double InitialBounds[6] = {-0.5, 0.5, -0.5, 0.5, -0.5, 0.5};
    double InitialLength = 1;
    double LastPickPosition[3] = {0, 0, 0};
    double PlaceFactor = 0.5, HandleSize = 0.01;
    int Enabled = 0, RotationEnabled = 1, InsideOut = 0, ValidPick = 0;
    WidgetState State = Start;
    /// The handle being moved (0-5 the faces, 6 the middle), 7 a face
    /// being turned, -1 none.
    int CurrentHandle = -1;
    int CurrentHexFace = -1;
    bool OutlineHighlighted = false;
};

#endif
#endif

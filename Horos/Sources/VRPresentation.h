// The VR view's render window and renderer without OpenGL (#731).
//
// VTK keeps the camera, the props and the ray caster; nothing of it draws.
// HorosVRRenderer, asked to render as any vtkRenderer is, draws the actors'
// surfaces with the view's HorosVRPresenter, lets each volume cast its rays -
// in Metal or on the CPU - and draws the image they leave in the mapper over
// the surfaces, as VTK's OpenGL passes did. HorosVRRenderWindow is the window
// VTK renders through: its size is the view's in pixels, its pixel and depth
// reads are the presenter's frame, and a finished frame goes to the layer.
//
// C++, because both are VTK classes.

#ifndef HOROS_VR_PRESENTATION_H
#define HOROS_VR_PRESENTATION_H

#ifdef __cplusplus

#include <map>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>

@class HorosVRPresenter;
@class NSData;
class vtkActor;
class vtkPolyData;
class vtkImageData;
class vtkVolume;

class HorosVRRenderWindow : public vtkRenderWindow
{
public:
    static HorosVRRenderWindow *New();
    vtkTypeMacro(HorosVRRenderWindow, vtkRenderWindow);

    void SetPresenter(HorosVRPresenter *presenter);
    HorosVRPresenter *GetPresenter() { return this->Presenter; }

    // What a window with no drawable of its own does: nothing.
    void Start() override {}
    void Finalize() override {}
    void MakeCurrent() override {}
    bool IsCurrent() override { return true; }
    void WaitForCompletion() override {}
    void HideCursor() override {}
    void ShowCursor() override {}
    void SetFullScreen(vtkTypeBool) override {}
    void WindowRemap() override {}
    int GetEventPending() override { return 0; }
    int *GetScreenSize() override { return this->Size; }
    void SetDisplayId(void *) override {}
    void SetWindowId(void *) override {}
    void SetNextWindowId(void *) override {}
    void SetParentId(void *) override {}
    void *GetGenericDisplayId() override { return nullptr; }
    void *GetGenericWindowId() override { return nullptr; }
    void *GetGenericParentId() override { return nullptr; }
    void *GetGenericContext() override { return nullptr; }
    void *GetGenericDrawable() override { return nullptr; }
    void SetWindowInfo(const char *) override {}
    void SetNextWindowInfo(const char *) override {}
    void SetParentInfo(const char *) override {}
    int GetDepthBufferSize() override { return 32; }
    int GetColorBufferSizes(int *rgba) override;

    /// The second picture of two-buffer stereo (#734): with the stereo type
    /// VTK_STEREO_CRYSTAL_EYES, the frame shows the left eye and this
    /// presenter the right one. Nil for one picture.
    void SetEyePresenter(HorosVRPresenter *presenter);
    HorosVRPresenter *GetEyePresenter() { return this->EyePresenter; }
    void StereoMidpoint() override;
    void StereoRenderComplete() override;

    /// Shows the frame the renderers drew.
    void Frame() override;

    // The frame's pixels and depth, rows from the bottom.
    unsigned char *GetPixelData(int x, int y, int x2, int y2, int front, int right = 0) override;
    int GetPixelData(int x, int y, int x2, int y2, int front, vtkUnsignedCharArray *data, int right = 0) override;
    int SetPixelData(int x, int y, int x2, int y2, unsigned char *data, int front, int right = 0) override;
    int SetPixelData(int x, int y, int x2, int y2, vtkUnsignedCharArray *data, int front, int right = 0) override;
    float *GetRGBAPixelData(int x, int y, int x2, int y2, int front, int right = 0) override;
    int GetRGBAPixelData(int x, int y, int x2, int y2, int front, vtkFloatArray *data, int right = 0) override;
    int SetRGBAPixelData(int x, int y, int x2, int y2, float *data, int front, int blend = 0, int right = 0) override;
    int SetRGBAPixelData(int, int, int, int, vtkFloatArray *, int, int blend = 0, int right = 0) override;
    void ReleaseRGBAPixelData(float *data) override;
    unsigned char *GetRGBACharPixelData(int x, int y, int x2, int y2, int front, int right = 0) override;
    int GetRGBACharPixelData(int x, int y, int x2, int y2, int front, vtkUnsignedCharArray *data, int right = 0) override;
    int SetRGBACharPixelData(int x, int y, int x2, int y2, unsigned char *data, int front, int blend = 0, int right = 0) override;
    int SetRGBACharPixelData(int x, int y, int x2, int y2, vtkUnsignedCharArray *data, int front, int blend = 0, int right = 0) override;
    float *GetZbufferData(int x, int y, int x2, int y2) override;
    int GetZbufferData(int x, int y, int x2, int y2, float *z) override;
    int GetZbufferData(int x, int y, int x2, int y2, vtkFloatArray *z) override;
    int SetZbufferData(int, int, int, int, float *) override { return VTK_ERROR; }
    int SetZbufferData(int, int, int, int, vtkFloatArray *) override { return VTK_ERROR; }

protected:
    HorosVRRenderWindow();
    ~HorosVRRenderWindow() override;

private:
    HorosVRRenderWindow(const HorosVRRenderWindow &) = delete;
    void operator=(const HorosVRRenderWindow &) = delete;
    NSData *Read(int x, int y, int x2, int y2, bool alpha, int *width, int *height, bool right = false);
    bool Write(int x, int y, int x2, int y2, const unsigned char *bytes, bool alpha);

    HorosVRPresenter *Presenter = nullptr;
    HorosVRPresenter *EyePresenter = nullptr;
    bool EyeDrawn = false;
};

/// Puts `window` in a mode of the Stereo menu (#734), by the tags of
/// HorosStereoMode: VTK's anaglyph, red/blue or interlaced combination of the
/// two eyes, two-buffer stereo with `eye` showing the right eye, or one view.
void HorosSetStereoMode(vtkRenderWindow *window, long mode, HorosVRPresenter *eye);

class HorosVRRenderer : public vtkRenderer
{
public:
    static HorosVRRenderer *New();
    vtkTypeMacro(HorosVRRenderer, vtkRenderer);

    /// The render VTK's OpenGL renderer did: opaque surfaces, translucent
    /// ones, then the volumes, each ray-cast image drawn as it is made.
    void DeviceRender() override;

    // No hardware picking: the view picks its points itself.
    vtkAssemblyPath *PickProp(double, double) override { return nullptr; }
    vtkAssemblyPath *PickProp(double, double, double, double) override { return nullptr; }

protected:
    HorosVRRenderer();
    ~HorosVRRenderer() override;

private:
    HorosVRRenderer(const HorosVRRenderer &) = delete;
    void operator=(const HorosVRRenderer &) = delete;

    struct Mesh {
        unsigned long long time = 0;
        NSData *vertices = nullptr, *indices = nullptr;
        /// The polylines' segments.
        NSData *lines = nullptr;
        bool normals = false, textureCoordinates = false;
    };
    struct Picture {
        unsigned long long time = 0;
        NSData *pixels = nullptr;
        int width = 0, height = 0;
    };
    bool DrawActor(HorosVRPresenter *presenter, vtkActor *actor, bool translucent);
    void DrawVolumeImage(HorosVRPresenter *presenter, vtkVolume *volume);
    const Mesh *MeshFor(vtkPolyData *data);
    const Mesh *FlatMeshFor(vtkPolyData *data, const Mesh *mesh);
    const Picture *PictureFor(vtkImageData *image);
    void Forget();

    std::map<vtkPolyData *, Mesh> Meshes;
    std::map<vtkImageData *, Picture> Pictures;
    std::map<vtkPolyData *, Mesh> FlatMeshes;
    std::map<vtkPolyData *, bool> MeshesUsed, FlatMeshesUsed;
    std::map<vtkImageData *, bool> PicturesUsed;
};

#endif
#endif

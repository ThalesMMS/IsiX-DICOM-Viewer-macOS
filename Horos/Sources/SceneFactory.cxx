// VTK's scene classes without a rendering backend (#735).
//
// VTK 8.2 makes vtkActor, vtkProperty, vtkCamera, vtkLight, vtkTexture, the poly
// data mappers, vtkImageMapper and the ray cast display helper only through a
// rendering backend's object factory, and returns nullptr without one. The app
// builds VTK with no backend; this factory makes them, and VRPresentation.mm
// adds the renderer and the window. C++ only, so that the checks in tests/ build
// it as the app does.

#include <vtkObjectFactory.h>
#include <vtkVersion.h>
#include <vtkAutoInit.h>
#include <vtkActor.h>
#include <vtkProperty.h>
#include <vtkCamera.h>
#include <vtkLight.h>
#include <vtkTexture.h>
#include <vtkPolyDataMapper.h>
#include <vtkPolyDataMapper2D.h>
#include <vtkImageMapper.h>
#include <vtkRayCastImageDisplayHelper.h>
#include <vtkFixedPointRayCastImage.h>

// VTK makes these only through a rendering backend's object factory, and the
// app links none: the renderer and the window VRPresentation.mm gives draw
// what they hold with Metal.
// The props keep their state; the mappers and helpers draw nothing.
namespace {

class HorosSceneActor : public vtkActor
{
public:
    static HorosSceneActor *New();
    vtkTypeMacro(HorosSceneActor, vtkActor);
};
vtkStandardNewMacro(HorosSceneActor);

class HorosSceneProperty : public vtkProperty
{
public:
    static HorosSceneProperty *New();
    vtkTypeMacro(HorosSceneProperty, vtkProperty);
};
vtkStandardNewMacro(HorosSceneProperty);

class HorosSceneCamera : public vtkCamera
{
public:
    static HorosSceneCamera *New();
    vtkTypeMacro(HorosSceneCamera, vtkCamera);
};
vtkStandardNewMacro(HorosSceneCamera);

class HorosSceneLight : public vtkLight
{
public:
    static HorosSceneLight *New();
    vtkTypeMacro(HorosSceneLight, vtkLight);
};
vtkStandardNewMacro(HorosSceneLight);

class HorosSceneTexture : public vtkTexture
{
public:
    static HorosSceneTexture *New();
    vtkTypeMacro(HorosSceneTexture, vtkTexture);
};
vtkStandardNewMacro(HorosSceneTexture);

class HorosScenePolyDataMapper : public vtkPolyDataMapper
{
public:
    static HorosScenePolyDataMapper *New();
    vtkTypeMacro(HorosScenePolyDataMapper, vtkPolyDataMapper);
    void RenderPiece(vtkRenderer *, vtkActor *) override {}
};
vtkStandardNewMacro(HorosScenePolyDataMapper);

class HorosScenePolyDataMapper2D : public vtkPolyDataMapper2D
{
public:
    static HorosScenePolyDataMapper2D *New();
    vtkTypeMacro(HorosScenePolyDataMapper2D, vtkPolyDataMapper2D);
};
vtkStandardNewMacro(HorosScenePolyDataMapper2D);

class HorosSceneImageMapper : public vtkImageMapper
{
public:
    static HorosSceneImageMapper *New();
    vtkTypeMacro(HorosSceneImageMapper, vtkImageMapper);
    void RenderData(vtkViewport *, vtkImageData *, vtkActor2D *) override {}
};
vtkStandardNewMacro(HorosSceneImageMapper);

// The ray cast mapper's image is drawn by the renderer (HorosVRRenderer).
class HorosSceneDisplayHelper : public vtkRayCastImageDisplayHelper
{
public:
    static HorosSceneDisplayHelper *New();
    vtkTypeMacro(HorosSceneDisplayHelper, vtkRayCastImageDisplayHelper);
    void RenderTexture(vtkVolume *, vtkRenderer *, int[2], int[2], int[2], int[2], float, unsigned char *) override {}
    void RenderTexture(vtkVolume *, vtkRenderer *, int[2], int[2], int[2], int[2], float, unsigned short *) override {}
    void RenderTexture(vtkVolume *, vtkRenderer *, vtkFixedPointRayCastImage *, float) override {}
};
vtkStandardNewMacro(HorosSceneDisplayHelper);

class HorosSceneFactory : public vtkObjectFactory
{
public:
    static HorosSceneFactory *New();
    vtkTypeMacro(HorosSceneFactory, vtkObjectFactory);
    const char *GetVTKSourceVersion() override { return VTK_SOURCE_VERSION; }
    const char *GetDescription() override { return "Horos scene classes, drawn by Metal"; }

protected:
    HorosSceneFactory()
    {
        this->Add<HorosSceneActor>("vtkActor", "HorosSceneActor");
        this->Add<HorosSceneProperty>("vtkProperty", "HorosSceneProperty");
        this->Add<HorosSceneCamera>("vtkCamera", "HorosSceneCamera");
        this->Add<HorosSceneLight>("vtkLight", "HorosSceneLight");
        this->Add<HorosSceneTexture>("vtkTexture", "HorosSceneTexture");
        this->Add<HorosScenePolyDataMapper>("vtkPolyDataMapper", "HorosScenePolyDataMapper");
        this->Add<HorosScenePolyDataMapper2D>("vtkPolyDataMapper2D", "HorosScenePolyDataMapper2D");
        this->Add<HorosSceneImageMapper>("vtkImageMapper", "HorosSceneImageMapper");
        this->Add<HorosSceneDisplayHelper>("vtkRayCastImageDisplayHelper", "HorosSceneDisplayHelper");
    }

private:
    template <class T> void Add(const char *base, const char *name)
    {
        this->RegisterOverride(base, name, "Horos scene class", 1,
                               []() -> vtkObject * { return T::New(); });
    }
};
vtkStandardNewMacro(HorosSceneFactory);

// Registered as VTK registers a backend's factory, when the app loads.
struct HorosSceneFactoryRegistration
{
    HorosSceneFactoryRegistration()
    {
        HorosSceneFactory *factory = HorosSceneFactory::New();
        vtkObjectFactory::RegisterFactory(factory);
        factory->Delete();
    }
} horosSceneFactoryRegistration;

}

// The modules that give VTK's other factory-made classes: the text renderer
// (FreeType) and the default interactor style. A backend's code pulled their
// initialisation in; without one, the app does.
VTK_MODULE_INIT(vtkRenderingFreeType)
VTK_MODULE_INIT(vtkInteractionStyle)

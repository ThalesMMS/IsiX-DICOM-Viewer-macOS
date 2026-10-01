"""A VTK render window whose buffers are pixels in memory, for the capture checks.

The VR and SR captures read a vtkRenderWindow's pixels with GetPixelData,
rows from the bottom, and turn them top-down. The checks used to paint a
pattern into an offscreen vtkCocoaRenderWindow with OpenGL; VTK is built
without OpenGL since #735, and the app's own window (HorosVRRenderWindow)
reads a Metal picture. PatternWindow keeps a left and a right buffer as VTK's
reads return them, so a check paints them and reads them through the same
calls.

`WINDOW` is the C++ class. `SCENE` adds a renderer that puts nothing on a
screen and
registers the two as VTK's vtkRenderWindow and vtkRenderer; with the app's
SceneFactory.cxx, which `compile(..., scene=True)` builds in, vtkActor::New()
and the other classes a backend used to make work as in the app.
`compile(install, root, source, output)` builds a probe against the VTK install.
"""
import subprocess

WINDOW = r'''
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkRendererCollection.h>
#include <vtkUnsignedCharArray.h>
#include <vtkFloatArray.h>
#include <algorithm>
#include <vector>
// A window with no drawable: a left and a right buffer of RGB pixels, rows
// from the bottom, which GetPixelData reads as VTK's windows do.
class PatternWindow : public vtkRenderWindow {
public:
 static PatternWindow *New(){auto w=new PatternWindow;w->InitializeObjectBase();return w;}
 // Lets go of its renderers, as VTK's windows and the app's do.
 ~PatternWindow() override{
  vtkCollectionSimpleIterator it;this->Renderers->InitTraversal(it);
  while(vtkRenderer *renderer=this->Renderers->GetNextRenderer(it))renderer->SetRenderWindow(nullptr);
 }
 std::vector<unsigned char> Buffers[2];
 // Window depth, 0 to 1 as OpenGL's and the app's: what PatternRenderer draws.
 std::vector<float> Depth;
 void Allocate(int w,int h){this->Size[0]=w;this->Size[1]=h;for(auto &b:Buffers)b.assign(size_t(w)*h*3,0);Depth.assign(size_t(w)*h,1.f);}
 void SetSize(int w,int h) override{if(w!=this->Size[0]||h!=this->Size[1])Allocate(w,h);this->vtkRenderWindow::SetSize(w,h);}
 void SetSize(int *a) override{this->SetSize(a[0],a[1]);}
 // Paints [x0, x1) x [y0, y1), y from the bottom, of one buffer.
 void Fill(int right,int x0,int y0,int x1,int y1,const unsigned char *rgb){
  for(int y=std::max(0,y0);y<std::min(y1,this->Size[1]);y++)for(int x=std::max(0,x0);x<std::min(x1,this->Size[0]);x++)
   std::copy(rgb,rgb+3,&Buffers[right?1:0][3*(size_t(y)*this->Size[0]+x)]);
 }
 int GetPixelData(int x,int y,int x2,int y2,int,vtkUnsignedCharArray *data,int right) override{
  if(x2<x)std::swap(x,x2);if(y2<y)std::swap(y,y2);
  if(x<0||y<0||x2>=this->Size[0]||y2>=this->Size[1])return VTK_ERROR;
  const int w=x2-x+1,h=y2-y+1;data->SetNumberOfComponents(3);data->SetNumberOfTuples(vtkIdType(w)*h);
  for(int row=0;row<h;row++)
   std::copy_n(&Buffers[right?1:0][3*(size_t(y+row)*this->Size[0]+x)],3*w,data->GetPointer(0)+3*size_t(row)*w);
  return VTK_OK;
 }
 unsigned char *GetPixelData(int,int,int,int,int,int) override{return nullptr;}
 int SetPixelData(int,int,int,int,unsigned char *,int,int) override{return VTK_ERROR;}
 int SetPixelData(int,int,int,int,vtkUnsignedCharArray *,int,int) override{return VTK_ERROR;}
 float *GetRGBAPixelData(int,int,int,int,int,int) override{return nullptr;}
 int GetRGBAPixelData(int,int,int,int,int,vtkFloatArray *,int) override{return VTK_ERROR;}
 int SetRGBAPixelData(int,int,int,int,float *,int,int,int) override{return VTK_ERROR;}
 int SetRGBAPixelData(int,int,int,int,vtkFloatArray *,int,int,int) override{return VTK_ERROR;}
 void ReleaseRGBAPixelData(float *) override{}
 unsigned char *GetRGBACharPixelData(int,int,int,int,int,int) override{return nullptr;}
 int GetRGBACharPixelData(int,int,int,int,int,vtkUnsignedCharArray *,int) override{return VTK_ERROR;}
 int SetRGBACharPixelData(int,int,int,int,unsigned char *,int,int,int) override{return VTK_ERROR;}
 int SetRGBACharPixelData(int,int,int,int,vtkUnsignedCharArray *,int,int,int) override{return VTK_ERROR;}
 float *GetZbufferData(int,int,int,int) override{return nullptr;}
 int GetZbufferData(int x,int y,int x2,int y2,float *z) override{
  if(x2<x)std::swap(x,x2);if(y2<y)std::swap(y,y2);
  if(!z||x<0||y<0||x2>=this->Size[0]||y2>=this->Size[1]||Depth.empty())return VTK_ERROR;
  for(int row=y;row<=y2;row++)std::copy_n(&Depth[size_t(row)*this->Size[0]+x],x2-x+1,z+size_t(row-y)*(x2-x+1));
  return VTK_OK;
 }
 int GetZbufferData(int x,int y,int x2,int y2,vtkFloatArray *z) override{
  z->SetNumberOfComponents(1);z->SetNumberOfTuples(vtkIdType(std::abs(x2-x)+1)*(std::abs(y2-y)+1));
  return this->GetZbufferData(x,y,x2,y2,z->GetPointer(0));
 }
 int SetZbufferData(int,int,int,int,float *) override{return VTK_ERROR;}
 int SetZbufferData(int,int,int,int,vtkFloatArray *) override{return VTK_ERROR;}
 void Start() override{} void Finalize() override{} void Frame() override{} void WaitForCompletion() override{}
 void MakeCurrent() override{} bool IsCurrent() override{return true;}
 void HideCursor() override{} void ShowCursor() override{} void SetFullScreen(vtkTypeBool) override{}
 void WindowRemap() override{} int GetEventPending() override{return 0;} int *GetScreenSize() override{return this->Size;}
 void SetDisplayId(void *) override{} void SetWindowId(void *) override{} void SetNextWindowId(void *) override{}
 void SetParentId(void *) override{} void *GetGenericDisplayId() override{return nullptr;}
 void *GetGenericWindowId() override{return nullptr;} void *GetGenericParentId() override{return nullptr;}
 void *GetGenericContext() override{return nullptr;} void *GetGenericDrawable() override{return nullptr;}
 void SetWindowInfo(const char *) override{} void SetNextWindowInfo(const char *) override{}
 void SetParentInfo(const char *) override{} int GetDepthBufferSize() override{return 0;}
 int GetColorBufferSizes(int *rgba) override{rgba[0]=rgba[1]=rgba[2]=8;rgba[3]=0;return 24;}
};
'''

SCENE = r'''
#include <vtkRenderer.h>
#include <vtkNew.h>
#include <vtkObjectFactory.h>
#include <vtkVersion.h>
#include <vtkLight.h>
#include <vtkLightCollection.h>
#include <vtkVolume.h>
#include <vtkActor.h>
#include <vtkCamera.h>
#include <vtkMapper.h>
#include <vtkPolyData.h>
#include <vtkCellArray.h>
#include <vtkMatrix4x4.h>
// A renderer that goes through the scene as the app's HorosVRRenderer does -
// the lights, with a headlight when none is on, the opaque polygons' depth and
// each volume's ray cast - and puts no colour on a screen, where
// HorosVRRenderer draws with Metal. The depth is the window's, 0 to 1, as the
// app's mesh pass writes it for the ray cast to stop at.
class PatternRenderer : public vtkRenderer {
public:
 static PatternRenderer *New(){auto r=new PatternRenderer;r->InitializeObjectBase();return r;}
 void DeviceRender() override{
  this->NumberOfPropsRendered=0;this->UpdateLightGeometry();
  bool lit=false;vtkCollectionSimpleIterator it;vtkLight *light=nullptr;
  for(this->GetLights()->InitTraversal(it);(light=this->GetLights()->GetNextLight(it));)lit=lit||light->GetSwitch();
  if(!lit&&this->AutomaticLightCreation){this->CreateLight();this->UpdateLightGeometry();}
  if(auto window=dynamic_cast<PatternWindow*>(this->RenderWindow)){
   std::fill(window->Depth.begin(),window->Depth.end(),1.f);
   for(vtkProp *prop:this->PropArray)
    if(vtkActor *actor=vtkActor::SafeDownCast(prop))
     if(actor->GetVisibility()&&!actor->HasTranslucentPolygonalGeometry()&&this->DrawDepth(window,actor))++this->NumberOfPropsRendered;
  }
  for(vtkProp *prop:this->PropArray)
   if(vtkVolume *volume=vtkVolume::SafeDownCast(prop))this->NumberOfPropsRendered+=volume->RenderVolumetricGeometry(this);
 }
 bool DrawDepth(PatternWindow *window,vtkActor *actor){
  auto polys=vtkPolyData::SafeDownCast(actor->GetMapper()?(actor->GetMapper()->Update(),actor->GetMapper()->GetInput()):nullptr);
  if(!polys||!polys->GetPolys()||!polys->GetPolys()->GetNumberOfCells())return false;
  const int w=window->GetSize()[0],h=window->GetSize()[1];
  double aspect[2];this->ComputeAspect();this->GetAspect(aspect);
  vtkNew<vtkMatrix4x4> clip,model;actor->GetMatrix(model);
  vtkMatrix4x4::Multiply4x4(this->GetActiveCamera()->GetProjectionTransformMatrix(aspect[0]/aspect[1],-1,1),this->GetActiveCamera()->GetViewTransformMatrix(),clip);
  vtkMatrix4x4::Multiply4x4(clip,model,clip);
  auto screen=[&](vtkIdType id,double out[3]){
   double p[4];polys->GetPoint(id,p);p[3]=1;double c[4];clip->MultiplyPoint(p,c);
   out[0]=(c[0]/c[3]+1)*0.5*w;out[1]=(c[1]/c[3]+1)*0.5*h;out[2]=(c[2]/c[3]+1)*0.5;
  };
  vtkIdType count;const vtkIdType *ids;auto cells=polys->GetPolys();
  for(cells->InitTraversal();cells->GetNextCell(count,ids);)
   for(vtkIdType k=1;k+1<count;++k){
    double a[3],b[3],c[3];screen(ids[0],a);screen(ids[k],b);screen(ids[k+1],c);
    const double area=(b[0]-a[0])*(c[1]-a[1])-(c[0]-a[0])*(b[1]-a[1]);if(area==0)continue;
    const int x0=std::max(0,int(std::floor(std::min({a[0],b[0],c[0]})))),x1=std::min(w-1,int(std::ceil(std::max({a[0],b[0],c[0]}))));
    const int y0=std::max(0,int(std::floor(std::min({a[1],b[1],c[1]})))),y1=std::min(h-1,int(std::ceil(std::max({a[1],b[1],c[1]}))));
    for(int y=y0;y<=y1;++y)for(int x=x0;x<=x1;++x){
     const double px=x+0.5,py=y+0.5;
     const double u=((b[0]-px)*(c[1]-py)-(c[0]-px)*(b[1]-py))/area,v=((c[0]-px)*(a[1]-py)-(a[0]-px)*(c[1]-py))/area,t=1-u-v;
     if(u<0||v<0||t<0)continue;
     const float z=float(u*a[2]+v*b[2]+t*c[2]);float &d=window->Depth[size_t(y)*w+x];
     if(z>=0&&z<=d)d=z;
    }
   }
  return true;
 }
};
// Makes them VTK's window and renderer, as the app's VRPresentation.mm does.
class PatternFactory : public vtkObjectFactory {
public:
 static PatternFactory *New(){auto f=new PatternFactory;f->InitializeObjectBase();return f;}
 const char *GetVTKSourceVersion() override{return VTK_SOURCE_VERSION;}
 const char *GetDescription() override{return "Pattern window and renderer";}
 PatternFactory(){
  this->RegisterOverride("vtkRenderWindow","PatternWindow","",1,[]()->vtkObject*{return PatternWindow::New();});
  this->RegisterOverride("vtkRenderer","PatternRenderer","",1,[]()->vtkObject*{return PatternRenderer::New();});
 }
};
static struct PatternFactoryRegistration{PatternFactoryRegistration(){auto f=PatternFactory::New();vtkObjectFactory::RegisterFactory(f);f->Delete();}} patternFactoryRegistration;
'''

LIBRARIES = ['vtkRenderingCore', 'vtkFiltersCore', 'vtkFiltersGeneral', 'vtkFiltersSources', 'vtkFiltersGeometry',
             'vtkImagingCore', 'vtksys', 'vtkdoubleconversion']


def compile(install, root, source, output, scene=False, libraries=(), frameworks=()):
    """Builds `source` against the VTK install; with `scene`, the app's
    SceneFactory.cxx too. `libraries` names more VTK libraries, `frameworks`
    system frameworks."""
    # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
    libs = [install / 'wlib' / 'libVTK.a']
    sources = [str(source)] + ([str(root / 'Horos/Sources/SceneFactory.cxx')] if scene else [])
    extra = [flag for framework in frameworks for flag in ('-framework', framework)]
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fsanitize=address', '-I' + str(install / 'include'),
                    '-I' + str(root / 'Horos/Sources'), *sources, *[str(x) for x in libs], '-lz', *extra,
                    '-o', str(output)], check=True)

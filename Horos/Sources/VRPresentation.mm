// The VR view's render window and renderer without OpenGL.
// See VRPresentation.h.

#import "VRPresentation.h"
#import "Horos-Swift.h"

#include <algorithm>
#include <cstring>
#include <vector>
#include <vtkObjectFactory.h>
#include <vtkNew.h>
#include <vtkActor.h>
#include <vtkVolume.h>
#include <vtkProperty.h>
#include <vtkMapper.h>
#include <vtkPolyData.h>
#include <vtkPointData.h>
#include <vtkDataArray.h>
#include <vtkCellArray.h>
#include <vtkIdList.h>
#include <vtkPoints.h>
#include <vtkCamera.h>
#include <vtkMatrix4x4.h>
#include <vtkMatrix3x3.h>
#include <vtkTexture.h>
#include <vtkImageData.h>
#include <vtkLight.h>
#include <vtkLightCollection.h>
#include <vtkRendererCollection.h>
#include <vtkUnsignedCharArray.h>
#include <vtkFloatArray.h>
#include <vtkFixedPointRayCastImage.h>
#include "vtkHorosFixedPointVolumeRayCastMapper.h"
#include <vtkPolyDataMapper.h>
#include <vtkVersion.h>

// MARK: - Window

vtkStandardNewMacro(HorosVRRenderWindow);

HorosVRRenderWindow::HorosVRRenderWindow()
{
    // One buffer: what is read is what was drawn.
    this->DoubleBuffer = 0;
    // The eye presenter is the second buffer of two-buffer stereo.
    this->StereoCapableWindow = 1;
}

HorosVRRenderWindow::~HorosVRRenderWindow()
{
    // A renderer that outlives the window must not keep pointing at it; VTK's
    // own windows let go of theirs the same way.
    vtkCollectionSimpleIterator it;
    this->Renderers->InitTraversal(it);
    while (vtkRenderer *renderer = this->Renderers->GetNextRenderer(it))
        renderer->SetRenderWindow(nullptr);
    [this->Presenter release];
    [this->EyePresenter release];
}

void HorosVRRenderWindow::SetPresenter(HorosVRPresenter *presenter)
{
    if (presenter == this->Presenter) return;
    [this->Presenter release];
    this->Presenter = [presenter retain];
}

int HorosVRRenderWindow::GetColorBufferSizes(int *rgba)
{
    if (rgba) rgba[0] = rgba[1] = rgba[2] = rgba[3] = 8;
    return 32;
}

void HorosVRRenderWindow::SetEyePresenter(HorosVRPresenter *presenter)
{
    if (presenter == this->EyePresenter) return;
    [this->EyePresenter release];
    this->EyePresenter = [presenter retain];
}

// Two-buffer stereo: the left eye is kept in the eye presenter while
// the right one is drawn, and the two are exchanged when both are done, so the
// frame shows the left eye and the eye presenter the right one.
void HorosVRRenderWindow::StereoMidpoint()
{
    this->vtkRenderWindow::StereoMidpoint();
    if (this->StereoType != VTK_STEREO_CRYSTAL_EYES || !this->EyePresenter) return;
    this->EyeDrawn = [this->Presenter copyFrameInto:this->EyePresenter];
}

void HorosVRRenderWindow::StereoRenderComplete()
{
    this->vtkRenderWindow::StereoRenderComplete();
    if (this->StereoType != VTK_STEREO_CRYSTAL_EYES || !this->EyePresenter || !this->EyeDrawn) return;
    [this->Presenter exchangeFrameWith:this->EyePresenter];
}

void HorosVRRenderWindow::Frame()
{
    [this->Presenter present];
    if (this->EyeDrawn) [this->EyePresenter present];
    this->EyeDrawn = false;
}

void HorosSetStereoMode(vtkRenderWindow *window, long mode, HorosVRPresenter *eye)
{
    if (!window) return;
    if (HorosVRRenderWindow *horos = HorosVRRenderWindow::SafeDownCast(window))
        horos->SetEyePresenter(mode == 4 || mode == 5 ? eye : nil);
    switch (mode)
    {
        case 1: window->SetStereoTypeToAnaglyph(); break;
        case 2: window->SetStereoTypeToRedBlue(); break;
        case 3: window->SetStereoTypeToInterlaced(); break;
        case 4: case 5: window->SetStereoTypeToCrystalEyes(); break;
    }
    window->SetStereoRender(mode >= 1 && mode <= 5 && (mode < 4 || eye) ? 1 : 0);
}

static void HorosOrderCorners(int &x, int &y, int &x2, int &y2)
{
    if (x2 < x) std::swap(x, x2);
    if (y2 < y) std::swap(y, y2);
}

NSData *HorosVRRenderWindow::Read(int x, int y, int x2, int y2, bool alpha, int *width, int *height, bool right)
{
    HorosOrderCorners(x, y, x2, y2);
    *width = x2 - x + 1;
    *height = y2 - y + 1;
    // The right buffer of two-buffer stereo is the right eye's picture.
    HorosVRPresenter *presenter = right && this->EyePresenter ? this->EyePresenter : this->Presenter;
    return [presenter readPixelsWithX:x y:y width:*width height:*height alpha:alpha];
}

bool HorosVRRenderWindow::Write(int x, int y, int x2, int y2, const unsigned char *bytes, bool alpha)
{
    if (!bytes) return false;
    HorosOrderCorners(x, y, x2, y2);
    int width = x2 - x + 1, height = y2 - y + 1;
    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:(NSUInteger)width * height * (alpha ? 4 : 3) freeWhenDone:NO];
    return [this->Presenter writePixels:data x:x y:y width:width height:height alpha:alpha];
}

unsigned char *HorosVRRenderWindow::GetPixelData(int x, int y, int x2, int y2, int, int right)
{
    int width, height;
    NSData *data = this->Read(x, y, x2, y2, false, &width, &height, right != 0);
    if (!data) return nullptr;
    unsigned char *copy = new unsigned char[data.length];
    memcpy(copy, data.bytes, data.length);
    return copy;
}

int HorosVRRenderWindow::GetPixelData(int x, int y, int x2, int y2, int, vtkUnsignedCharArray *array, int right)
{
    int width, height;
    NSData *data = this->Read(x, y, x2, y2, false, &width, &height, right != 0);
    if (!data || !array) return VTK_ERROR;
    array->SetNumberOfComponents(3);
    array->SetNumberOfTuples((vtkIdType)width * height);
    memcpy(array->GetPointer(0), data.bytes, data.length);
    return VTK_OK;
}

int HorosVRRenderWindow::SetPixelData(int x, int y, int x2, int y2, unsigned char *data, int, int)
{
    return this->Write(x, y, x2, y2, data, false) ? VTK_OK : VTK_ERROR;
}

int HorosVRRenderWindow::SetPixelData(int x, int y, int x2, int y2, vtkUnsignedCharArray *data, int, int)
{
    if (!data || data->GetNumberOfComponents() != 3) return VTK_ERROR;
    return this->Write(x, y, x2, y2, data->GetPointer(0), false) ? VTK_OK : VTK_ERROR;
}

unsigned char *HorosVRRenderWindow::GetRGBACharPixelData(int x, int y, int x2, int y2, int, int)
{
    int width, height;
    NSData *data = this->Read(x, y, x2, y2, true, &width, &height);
    if (!data) return nullptr;
    unsigned char *copy = new unsigned char[data.length];
    memcpy(copy, data.bytes, data.length);
    return copy;
}

int HorosVRRenderWindow::GetRGBACharPixelData(int x, int y, int x2, int y2, int, vtkUnsignedCharArray *array, int)
{
    int width, height;
    NSData *data = this->Read(x, y, x2, y2, true, &width, &height);
    if (!data || !array) return VTK_ERROR;
    array->SetNumberOfComponents(4);
    array->SetNumberOfTuples((vtkIdType)width * height);
    memcpy(array->GetPointer(0), data.bytes, data.length);
    return VTK_OK;
}

int HorosVRRenderWindow::SetRGBACharPixelData(int x, int y, int x2, int y2, unsigned char *data, int, int, int)
{
    return this->Write(x, y, x2, y2, data, true) ? VTK_OK : VTK_ERROR;
}

int HorosVRRenderWindow::SetRGBACharPixelData(int x, int y, int x2, int y2, vtkUnsignedCharArray *data, int, int, int)
{
    if (!data || data->GetNumberOfComponents() != 4) return VTK_ERROR;
    return this->Write(x, y, x2, y2, data->GetPointer(0), true) ? VTK_OK : VTK_ERROR;
}

float *HorosVRRenderWindow::GetRGBAPixelData(int x, int y, int x2, int y2, int, int)
{
    int width, height;
    NSData *data = this->Read(x, y, x2, y2, true, &width, &height);
    if (!data) return nullptr;
    float *values = new float[data.length];
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    for (NSUInteger i = 0; i < data.length; ++i) values[i] = bytes[i] / 255.0f;
    return values;
}

int HorosVRRenderWindow::GetRGBAPixelData(int x, int y, int x2, int y2, int front, vtkFloatArray *array, int right)
{
    float *values = this->GetRGBAPixelData(x, y, x2, y2, front, right);
    if (!values || !array) { delete [] values; return VTK_ERROR; }
    HorosOrderCorners(x, y, x2, y2);
    vtkIdType count = (vtkIdType)(x2 - x + 1) * (y2 - y + 1);
    array->SetNumberOfComponents(4);
    array->SetNumberOfTuples(count);
    memcpy(array->GetPointer(0), values, count * 4 * sizeof(float));
    delete [] values;
    return VTK_OK;
}

int HorosVRRenderWindow::SetRGBAPixelData(int x, int y, int x2, int y2, float *data, int, int, int)
{
    if (!data) return VTK_ERROR;
    HorosOrderCorners(x, y, x2, y2);
    size_t count = (size_t)(x2 - x + 1) * (y2 - y + 1) * 4;
    std::vector<unsigned char> bytes(count);
    for (size_t i = 0; i < count; ++i) bytes[i] = (unsigned char)lround(std::min(1.0f, std::max(0.0f, data[i])) * 255);
    return this->Write(x, y, x2, y2, bytes.data(), true) ? VTK_OK : VTK_ERROR;
}

int HorosVRRenderWindow::SetRGBAPixelData(int x, int y, int x2, int y2, vtkFloatArray *data, int front, int blend, int right)
{
    if (!data || data->GetNumberOfComponents() != 4) return VTK_ERROR;
    return this->SetRGBAPixelData(x, y, x2, y2, data->GetPointer(0), front, blend, right);
}

void HorosVRRenderWindow::ReleaseRGBAPixelData(float *data)
{
    delete [] data;
}

float *HorosVRRenderWindow::GetZbufferData(int x, int y, int x2, int y2)
{
    HorosOrderCorners(x, y, x2, y2);
    float *values = new float[(size_t)(x2 - x + 1) * (y2 - y + 1)];
    if (this->GetZbufferData(x, y, x2, y2, values) != VTK_OK) { delete [] values; return nullptr; }
    return values;
}

int HorosVRRenderWindow::GetZbufferData(int x, int y, int x2, int y2, float *z)
{
    if (!z) return VTK_ERROR;
    HorosOrderCorners(x, y, x2, y2);
    return [this->Presenter readDepthWithX:x y:y width:x2 - x + 1 height:y2 - y + 1 into:z] ? VTK_OK : VTK_ERROR;
}

int HorosVRRenderWindow::GetZbufferData(int x, int y, int x2, int y2, vtkFloatArray *z)
{
    if (!z) return VTK_ERROR;
    HorosOrderCorners(x, y, x2, y2);
    z->SetNumberOfComponents(1);
    z->SetNumberOfTuples((vtkIdType)(x2 - x + 1) * (y2 - y + 1));
    return this->GetZbufferData(x, y, x2, y2, z->GetPointer(0));
}

// MARK: - Renderer

vtkStandardNewMacro(HorosVRRenderer);

HorosVRRenderer::HorosVRRenderer() {}

HorosVRRenderer::~HorosVRRenderer()
{
    this->MeshesUsed.clear();
    this->PicturesUsed.clear();
    this->FlatMeshesUsed.clear();
    this->Forget();
}

/// Drops the surfaces and textures the last frame did not draw.
void HorosVRRenderer::Forget()
{
    for (auto i = this->Meshes.begin(); i != this->Meshes.end(); )
    {
        if (this->MeshesUsed.count(i->first)) { ++i; continue; }
        [i->second.vertices release];
        [i->second.indices release];
        [i->second.lines release];
        i = this->Meshes.erase(i);
    }
    for (auto i = this->Pictures.begin(); i != this->Pictures.end(); )
    {
        if (this->PicturesUsed.count(i->first)) { ++i; continue; }
        [i->second.pixels release];
        i = this->Pictures.erase(i);
    }
    for (auto i = this->FlatMeshes.begin(); i != this->FlatMeshes.end(); )
    {
        if (this->FlatMeshesUsed.count(i->first)) { ++i; continue; }
        [i->second.vertices release];
        [i->second.indices release];
        i = this->FlatMeshes.erase(i);
    }
    this->MeshesUsed.clear();
    this->PicturesUsed.clear();
    this->FlatMeshesUsed.clear();
}

/// A surface's points, normals and texture coordinates, and its polygons and
/// strips as triangles, rebuilt when the data changes.
const HorosVRRenderer::Mesh *HorosVRRenderer::MeshFor(vtkPolyData *data)
{
    this->MeshesUsed[data] = true;
    Mesh &mesh = this->Meshes[data];
    if (mesh.vertices && mesh.time == data->GetMTime()) return &mesh;
    [mesh.vertices release]; mesh.vertices = nullptr;
    [mesh.indices release]; mesh.indices = nullptr;
    [mesh.lines release]; mesh.lines = nullptr;
    mesh.time = data->GetMTime();

    vtkIdType count = data->GetNumberOfPoints();
    vtkDataArray *normals = data->GetPointData() ? data->GetPointData()->GetNormals() : nullptr;
    vtkDataArray *coordinates = data->GetPointData() ? data->GetPointData()->GetTCoords() : nullptr;
    if (normals && normals->GetNumberOfTuples() < count) normals = nullptr;
    if (coordinates && coordinates->GetNumberOfTuples() < count) coordinates = nullptr;
    mesh.normals = normals != nullptr;
    mesh.textureCoordinates = coordinates != nullptr;

    NSMutableData *vertices = [NSMutableData dataWithLength:(NSUInteger)count * 8 * sizeof(float)];
    float *v = (float *)vertices.mutableBytes;
    for (vtkIdType i = 0; i < count; ++i, v += 8)
    {
        double p[3];
        data->GetPoint(i, p);
        v[0] = p[0]; v[1] = p[1]; v[2] = p[2];
        if (normals) { double *n = normals->GetTuple3(i); v[3] = n[0]; v[4] = n[1]; v[5] = n[2]; }
        if (coordinates) { double *t = coordinates->GetTuple(i); v[6] = t[0]; v[7] = coordinates->GetNumberOfComponents() > 1 ? t[1] : 0; }
    }

    // Triangles from the polygons and strips; the polylines as segments.
    // Each cell is copied into an id list: GetNextCell(vtkIdList *) is the same
    // call in VTK 8.2 and 9, whereas the pointer overload changed its type.
    std::vector<uint32_t> triangles, lines;
    vtkNew<vtkIdList> cell;
    if (vtkCellArray *polys = data->GetPolys())
        for (polys->InitTraversal(); polys->GetNextCell(cell); )
        {
            const vtkIdType size = cell->GetNumberOfIds(), *ids = cell->GetPointer(0);
            for (vtkIdType k = 1; k + 1 < size; ++k)
                triangles.insert(triangles.end(), {(uint32_t)ids[0], (uint32_t)ids[k], (uint32_t)ids[k + 1]});
        }
    if (vtkCellArray *strips = data->GetStrips())
        for (strips->InitTraversal(); strips->GetNextCell(cell); )
        {
            const vtkIdType size = cell->GetNumberOfIds(), *ids = cell->GetPointer(0);
            for (vtkIdType k = 0; k + 2 < size; ++k)
            {
                if (k % 2 == 0) triangles.insert(triangles.end(), {(uint32_t)ids[k], (uint32_t)ids[k + 1], (uint32_t)ids[k + 2]});
                else triangles.insert(triangles.end(), {(uint32_t)ids[k + 1], (uint32_t)ids[k], (uint32_t)ids[k + 2]});
            }
        }
    if (vtkCellArray *polylines = data->GetLines())
        for (polylines->InitTraversal(); polylines->GetNextCell(cell); )
        {
            const vtkIdType size = cell->GetNumberOfIds(), *ids = cell->GetPointer(0);
            for (vtkIdType k = 0; k + 1 < size; ++k)
                lines.insert(lines.end(), {(uint32_t)ids[k], (uint32_t)ids[k + 1]});
        }
    mesh.vertices = [vertices retain];
    mesh.indices = [[NSData alloc] initWithBytes:triangles.data() length:triangles.size() * sizeof(uint32_t)];
    mesh.lines = [[NSData alloc] initWithBytes:lines.data() length:lines.size() * sizeof(uint32_t)];
    return &mesh;
}

/// The mesh with each triangle's own three vertices, carrying the face's
/// normal, for a wireframe of a surface without normals.
const HorosVRRenderer::Mesh *HorosVRRenderer::FlatMeshFor(vtkPolyData *data, const Mesh *mesh)
{
    this->FlatMeshesUsed[data] = true;
    Mesh &flat = this->FlatMeshes[data];
    if (flat.vertices && flat.time == mesh->time) return &flat;
    [flat.vertices release]; flat.vertices = nullptr;
    [flat.indices release]; flat.indices = nullptr;
    flat.time = mesh->time;
    NSUInteger count = mesh->indices.length / sizeof(uint32_t);
    const uint32_t *triangles = (const uint32_t *)mesh->indices.bytes;
    const float *source = (const float *)mesh->vertices.bytes;
    NSMutableData *vertices = [NSMutableData dataWithLength:count * 8 * sizeof(float)];
    NSMutableData *indices = [NSMutableData dataWithLength:count * sizeof(uint32_t)];
    float *v = (float *)vertices.mutableBytes;
    uint32_t *order = (uint32_t *)indices.mutableBytes;
    for (NSUInteger t = 0; t + 2 < count; t += 3)
    {
        const float *a = source + triangles[t] * 8, *b = source + triangles[t + 1] * 8, *c = source + triangles[t + 2] * 8;
        double e1[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]}, e2[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
        double n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        double length = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (length > 0) for (int k = 0; k < 3; ++k) n[k] /= length;
        for (int corner = 0; corner < 3; ++corner)
        {
            const float *p = corner == 0 ? a : corner == 1 ? b : c;
            float *out = v + (t + corner) * 8;
            memcpy(out, p, 8 * sizeof(float));
            out[3] = n[0]; out[4] = n[1]; out[5] = n[2];
            order[t + corner] = (uint32_t)(t + corner);
        }
    }
    flat.vertices = [vertices retain];
    flat.indices = [indices retain];
    flat.normals = true;
    return &flat;
}

/// A texture's image as RGBA bytes, rows from the bottom.
const HorosVRRenderer::Picture *HorosVRRenderer::PictureFor(vtkImageData *image)
{
    this->PicturesUsed[image] = true;
    Picture &picture = this->Pictures[image];
    if (picture.pixels && picture.time == image->GetMTime()) return &picture;
    [picture.pixels release]; picture.pixels = nullptr;
    picture.time = image->GetMTime();
    int *dimensions = image->GetDimensions();
    vtkDataArray *scalars = image->GetPointData() ? image->GetPointData()->GetScalars() : nullptr;
    int components = scalars ? scalars->GetNumberOfComponents() : 0;
    if (!scalars || components < 1 || components > 4 || dimensions[0] <= 0 || dimensions[1] <= 0) return nullptr;
    picture.width = dimensions[0];
    picture.height = dimensions[1];
    vtkIdType count = (vtkIdType)picture.width * picture.height;
    if (scalars->GetNumberOfTuples() < count) return nullptr;
    // An 8-bit image is taken as it is; any other type as VTK's texture
    // took it, scaled from its range.
    double range[2] = {0, 255};
    if (scalars->GetDataType() != VTK_UNSIGNED_CHAR) scalars->GetRange(range, -1);
    double scale = range[1] > range[0] ? 255.0 / (range[1] - range[0]) : 1;
    NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)count * 4];
    unsigned char *out = (unsigned char *)pixels.mutableBytes;
    for (vtkIdType i = 0; i < count; ++i, out += 4)
    {
        double value[4] = {0, 0, 0, 255};
        for (int c = 0; c < components; ++c) value[c] = (scalars->GetComponent(i, c) - range[0]) * scale;
        if (components <= 2) { value[3] = components == 2 ? value[1] : 255; value[1] = value[2] = value[0]; }
        for (int c = 0; c < 4; ++c) out[c] = (unsigned char)lround(std::min(255.0, std::max(0.0, value[c])));
    }
    picture.pixels = [pixels retain];
    return &picture;
}

bool HorosVRRenderer::DrawActor(HorosVRPresenter *presenter, vtkActor *actor, bool translucent)
{
    vtkMapper *mapper = actor->GetMapper();
    if (!mapper) return false;
    mapper->Update();
    vtkPolyData *data = vtkPolyData::SafeDownCast(mapper->GetInput());
    if (!data || data->GetNumberOfPoints() == 0) return false;
    const Mesh *mesh = this->MeshFor(data);
    if (!mesh || (mesh->indices.length == 0 && mesh->lines.length == 0)) return false;

    int width, height, x0, y0;
    this->GetTiledSizeAndOrigin(&width, &height, &x0, &y0);
    if (width <= 0 || height <= 0) return false;
    vtkCamera *camera = this->GetActiveCamera();
    vtkMatrix4x4 *model = actor->GetMatrix();
    vtkNew<vtkMatrix4x4> clip, modelView, normal;
    // The projection with the stereo eye's shear: the composite matrix leaves
    // it out, being meant for picking.
    vtkMatrix4x4::Multiply4x4(camera->GetViewTransformMatrix(), model, modelView);
    vtkMatrix4x4::Multiply4x4(camera->GetProjectionTransformMatrix((double)width / height, -1, 1), modelView, clip);
    vtkMatrix4x4::Invert(modelView, normal);
    normal->Transpose();

    float u[68] = {0};
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r)
        {
            u[c * 4 + r] = clip->GetElement(r, c);
            u[16 + c * 4 + r] = modelView->GetElement(r, c);
        }
    for (int c = 0; c < 3; ++c)
        for (int r = 0; r < 3; ++r) u[32 + c * 4 + r] = normal->GetElement(r, c);

    vtkProperty *property = actor->GetProperty();
    double ambientColour[3], diffuseColour[3], specularColour[3];
    property->GetAmbientColor(ambientColour);
    property->GetDiffuseColor(diffuseColour);
    property->GetSpecularColor(specularColour);
    double ambient = property->GetAmbient(), diffuse = property->GetDiffuse(), specular = property->GetSpecular();
    bool lighting = property->GetLighting();
    for (int c = 0; c < 3; ++c)
    {
        // Without lighting, VTK shows the ambient and diffuse colours as they are.
        u[44 + c] = ambient * ambientColour[c] + (lighting ? 0 : diffuse * diffuseColour[c]);
        u[48 + c] = lighting ? diffuse * diffuseColour[c] : 0;
        u[52 + c] = lighting ? specular * specularColour[c] : 0;
    }
    u[55] = property->GetSpecularPower();
    u[56] = property->GetOpacity();
    u[57] = mesh->normals ? 1 : 0;
    u[59] = camera->GetParallelProjection() ? 1 : 0;

    // The light: the renderer's first one switched on, or the headlight VTK
    // makes when there is none.
    double lightColour[3] = {1, 1, 1}, intensity = 1, direction[3] = {0, 0, 1};
    vtkLightCollection *lights = this->GetLights();
    vtkCollectionSimpleIterator it;
    vtkLight *light = nullptr;
    for (lights->InitTraversal(it); (light = lights->GetNextLight(it)); ) if (light->GetSwitch()) break;
    if (light)
    {
        light->GetDiffuseColor(lightColour);
        intensity = light->GetIntensity();
        if (!light->LightTypeIsHeadlight())
        {
            double *position = light->GetTransformedPosition(), *focal = light->GetTransformedFocalPoint();
            double towards[4] = {position[0] - focal[0], position[1] - focal[1], position[2] - focal[2], 0};
            if (light->LightTypeIsSceneLight()) camera->GetViewTransformMatrix()->MultiplyPoint(towards, towards);
            for (int c = 0; c < 3; ++c) direction[c] = towards[c];
        }
    }
    for (int c = 0; c < 3; ++c) { u[60 + c] = direction[c]; u[64 + c] = lightColour[c] * intensity; }
    u[63] = 1; u[67] = 1;

    NSData *texture = nil;
    int textureWidth = 0, textureHeight = 0;
    vtkTexture *vtkPicture = actor->GetTexture();
    if (vtkPicture && mesh->textureCoordinates)
    {
        if (vtkPicture->GetInputAlgorithm()) vtkPicture->GetInputAlgorithm()->Update();
        vtkImageData *image = vtkPicture->GetInput();
        if (const Picture *picture = image ? this->PictureFor(image) : nullptr)
        {
            texture = picture->pixels;
            textureWidth = picture->width;
            textureHeight = picture->height;
            u[58] = texture ? 1 : 0;
        }
    }

    int cull = property->GetBackfaceCulling() ? 1 : property->GetFrontfaceCulling() ? 2 : 0;
    NSData *uniforms = [NSData dataWithBytes:u length:sizeof(u)];
    // Lines are lit only with normals, as VTK's mapper had it; without, they
    // show their ambient and diffuse colours as they are.
    float unlitLines[68];
    memcpy(unlitLines, u, sizeof(u));
    for (int c = 0; c < 3; ++c) { unlitLines[44 + c] += unlitLines[48 + c]; unlitLines[48 + c] = unlitLines[52 + c] = 0; }
    NSData *lineUniforms = mesh->normals ? uniforms : [NSData dataWithBytes:unlitLines length:sizeof(unlitLines)];
    // A wireframe is the triangles' edges, culled as the faces are, lit as
    // they are. Points are drawn as surfaces.
    bool wireframe = property->GetRepresentation() == VTK_WIREFRAME;
    if (wireframe && !mesh->normals && mesh->indices.length)
    {
        // Without normals, a face is lit by its own normal, which the shader
        // takes from the screen derivatives; along a line they vanish. OpenGL
        // took them from the triangle; here each triangle carries its normal.
        const Mesh *flat = this->FlatMeshFor(data, mesh);
        u[57] = 1;
        [presenter drawMeshWithVertices:flat->vertices indices:flat->indices uniforms:[NSData dataWithBytes:u length:sizeof(u)]
                                texture:texture textureWidth:textureWidth textureHeight:textureHeight
                            translucent:translucent cull:cull wireframe:YES];
    }
    else if (mesh->indices.length)
        [presenter drawMeshWithVertices:mesh->vertices indices:mesh->indices uniforms:uniforms texture:texture
                           textureWidth:textureWidth textureHeight:textureHeight translucent:translucent cull:cull
                              wireframe:wireframe];
    if (mesh->lines.length)
        [presenter drawLinesWithVertices:mesh->vertices indices:mesh->lines uniforms:lineUniforms translucent:translucent];
    return true;
}

/// The volume's ray-cast image, as the display helper drew it after the
/// mapper's render.
void HorosVRRenderer::DrawVolumeImage(HorosVRPresenter *presenter, vtkVolume *volume)
{
    // The Horos mapper has no type macro of its own: SafeDownCast would stop at its parent.
    auto *mapper = dynamic_cast<vtkHorosFixedPointVolumeRayCastMapper *>(volume->GetMapper());
    if (!mapper || !mapper->GetImageDisplayed()) return;
    vtkFixedPointRayCastImage *image = mapper->GetRayCastImage();
    int memory[2], viewport[2], used[2], origin[2];
    image->GetImageMemorySize(memory);
    image->GetImageViewportSize(viewport);
    image->GetImageInUseSize(used);
    image->GetImageOrigin(origin);
    if (!image->GetImage()) return;
    [presenter drawImageWithPixels:image->GetImage() memoryWidth:memory[0] memoryHeight:memory[1]
                         usedWidth:used[0] usedHeight:used[1] originX:origin[0] originY:origin[1]
                     viewportWidth:viewport[0] viewportHeight:viewport[1]
                             depth:mapper->GetImageDepth() scale:vtkHorosFixedPointVolumeRayCastMapper::GetImagePixelScale()];
}

// vtkCamera keeps its stereo switch to itself; VTK's OpenGL camera set it
// from the window on every render, and the eye's shear follows from it.
struct HorosStereoCamera : vtkCamera
{
    static void Set(vtkCamera *camera, int stereo) { camera->*(&HorosStereoCamera::Stereo) = stereo; }
};

void HorosVRRenderer::DeviceRender()
{
    HorosStereoCamera::Set(this->GetActiveCamera(), this->RenderWindow->GetStereoRender());
    HorosVRRenderWindow *window = HorosVRRenderWindow::SafeDownCast(this->RenderWindow);
    HorosVRPresenter *presenter = window ? window->GetPresenter() : nil;
    int *size = this->RenderWindow->GetSize();
    double background[3];
    this->GetBackground(background);
    bool framed = presenter && [presenter beginWithWidth:size[0] height:size[1]
                                                      red:background[0] green:background[1] blue:background[2]];
    this->NumberOfPropsRendered = 0;

    // The lights, as VTK's OpenGL renderer set them up before drawing: a
    // headlight when none is on, all of them following the camera. The ray
    // caster shades with them.
    this->UpdateLightGeometry();
    bool lit = false;
    vtkCollectionSimpleIterator it;
    vtkLight *light = nullptr;
    for (this->GetLights()->InitTraversal(it); (light = this->GetLights()->GetNextLight(it)); ) lit = lit || light->GetSwitch();
    if (!lit && this->AutomaticLightCreation)
    {
        this->CreateLight();
        this->UpdateLightGeometry();
    }

    std::vector<vtkActor *> opaque, translucent;
    for (vtkProp *prop : this->PropArray)
        if (vtkActor *actor = vtkActor::SafeDownCast(prop))
            (actor->HasTranslucentPolygonalGeometry() ? translucent : opaque).push_back(actor);
    if (framed)
    {
        for (vtkActor *actor : opaque) if (this->DrawActor(presenter, actor, false)) ++this->NumberOfPropsRendered;
        for (vtkActor *actor : translucent) if (this->DrawActor(presenter, actor, true)) ++this->NumberOfPropsRendered;
        // Blended over the frame before the volumes, as VTK's translucent pass did.
        [presenter compositeTranslucent];
    }
    for (vtkProp *prop : this->PropArray)
        if (vtkVolume *volume = vtkVolume::SafeDownCast(prop))
        {
            this->NumberOfPropsRendered += volume->RenderVolumetricGeometry(this);
            if (framed && !this->RenderWindow->GetAbortRender()) this->DrawVolumeImage(presenter, volume);
        }
    if (framed) [presenter finish];
    this->Forget();
}

// MARK: - Renderer and window for VTK

// SceneFactory.cxx makes VTK's props, mappers and helpers; this makes the
// renderer and the window, which HorosVRPresenter draws with Metal.
namespace {

class HorosPresentationFactory : public vtkObjectFactory
{
public:
    static HorosPresentationFactory *New();
    vtkTypeMacro(HorosPresentationFactory, vtkObjectFactory);
    const char *GetVTKSourceVersion() override { return VTK_SOURCE_VERSION; }
    const char *GetDescription() override { return "Horos renderer and window, drawn by Metal"; }

protected:
    HorosPresentationFactory()
    {
        this->RegisterOverride("vtkRenderer", "HorosVRRenderer", "Horos scene class", 1,
                               []() -> vtkObject * { return HorosVRRenderer::New(); });
        this->RegisterOverride("vtkRenderWindow", "HorosVRRenderWindow", "Horos scene class", 1,
                               []() -> vtkObject * { return HorosVRRenderWindow::New(); });
    }
};
vtkStandardNewMacro(HorosPresentationFactory);

struct HorosPresentationFactoryRegistration
{
    HorosPresentationFactoryRegistration()
    {
        HorosPresentationFactory *factory = HorosPresentationFactory::New();
        vtkObjectFactory::RegisterFactory(factory);
        factory->Delete();
    }
} horosPresentationFactoryRegistration;

}

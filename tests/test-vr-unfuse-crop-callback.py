#!/usr/bin/env python3
"""The crop callback reaches only live mappers: after unfusing, and before
the view installs its engine.

When a series is fused, `setBlendingPixSource:` hands the fused `vtkVolume` to
the crop callback, which then clips that volume's mapper with the crop planes
too. Unfusing (the fused 2D viewer closes) deleted the volume but left the
callback holding it, and the next run of the callback - every engine switch
runs it - read the mapper of freed memory: `EXC_BAD_ACCESS` in
`vtkMyCallbackVR::Execute`.

The callback and the fused series' VTK objects are the VTK adapter's
(IsiXVTKVolumeView): its callback class, its -releaseFusion and the accessors
the view asks are compiled here, with the view's own blocks over them.

The production callback class and the production unfuse block are compiled
here against stand-in VTK types whose deleted volume fails the test when its
mapper is asked for. The run fuses, crops (both mappers take the planes),
unfuses and crops again, as the engine switch does: the primary mapper still
takes the planes and nothing reaches the deleted volume.

A 3D window whose controller never loaded its 3D state has a volume with no
mapper until something calls `-setEngine:` (`load3DState` does), and
turning the crop box on clipped that null mapper: SIGSEGV in
`vtkAbstractMapper::SetClippingPlanes`. The production `showCropCube:`
and `installEngineIfNeeded` run here on such a view, whose `setEngine:` stand-in
installs the mapper as the real one does: the box goes on and the new mapper
takes the planes. The callback run on a volume still without a mapper leaves
the crop in the box, and the next run, the one `-instantiateEngine:` makes,
applies it.

The crop box toggle is Swift (VRView+Crop.swift), an extension of VRView: its
`showCropCube:` is compiled here as an extension of the harness, which
declares what the method reaches of the view (`horos_vtk`, the controller,
the engine install, the box placement and the tool), with the application's
own VTKRetinaGeometry. A revision whose toggle is still in VRView.m runs the
Objective-C toggle instead.

The unfuse block (VRView+Volume.swift) and the engine install
(VRView+Engine.swift) are Swift too: they are compiled in the same extension,
over the harness's `horos_blendingData8` and `horos_blendingPixList`, the
view's own properties; a revision that still has them in VRView.m runs the
Objective-C.

`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]


def read(path):
    return (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]) if len(sys.argv) > 1
            else (root / path).read_bytes()).decode('latin1')


def read_utf8(path):
    return (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]) if len(sys.argv) > 1
            else (root / path).read_bytes()).decode('utf-8')


try:
    source = read('Horos/Sources/VRView.m')
except (OSError, subprocess.CalledProcessError):
    # The class is Swift since (VRView.swift): its extensions are read below.
    source = ''
internal = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeViewInternal.hpp')
crop = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeCrop.mm')
pipeline = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm')
volume_view = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeView.mm')


def braced(text, start):
    """The text from `start` to the brace that closes the first one after it."""
    depth, index = 0, text.index('{', start)
    while True:
        if text[index] == '{': depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0: return text[start:index + 1]
        index += 1


callback_start = internal.index('class IsiXVTKCropCallback : public vtkCommand')
callback = internal[callback_start:internal.index('\n};', callback_start) + 3] + '\n' + \
    braced(crop, crop.index('void IsiXVTKCropCallback::Execute('))
swift_volume = '-(void) setBlendingPixSource:(ViewerController*) bC' not in source
if swift_volume:
    view_volume = read_utf8('Horos/Sources/VRView+Volume.swift')
    setter = view_volume.index('    @objc(setBlendingPixSource:)\n')
    unfuse = braced(view_volume, view_volume.index('            if vtk.hasBlendingVolume {', view_volume.index('        } else {', setter)))
    view_engine = read_utf8('Horos/Sources/VRView+Engine.swift')
    start = view_engine.index('    @objc(installEngineIfNeeded)\n')
    swift_install = view_engine[start:view_engine.index('\n    }\n', start) + 7]
else:
    setter = source.index('-(void) setBlendingPixSource:(ViewerController*) bC')
    unfuse = braced(source, source.index('if( vtk.hasBlendingVolume)', source.index('    else\n    {', setter)))
swift_toggle = '-(void) showCropCube:(id) sender' not in source
if swift_toggle:
    view_crop = read_utf8('Horos/Sources/VRView+Crop.swift')
    start = view_crop.index('    @objc(showCropCube:)\n')
    toggle = view_crop[start:view_crop.index('\n    }\n', start) + 7]
else:
    toggle = braced(source, source.index('-(void) showCropCube:(id) sender'))
install = (braced(source, source.index('- (void) installEngineIfNeeded'))
           if '- (void) installEngineIfNeeded' in source else '')
# The adapter's side: the accessors the view's blocks ask, the callback's run
# and the fusion's release.
adapter = '\n'.join([
    braced(volume_view, volume_view.index('- (BOOL)hasVolume')),
    braced(volume_view, volume_view.index('- (BOOL)hasBlendingVolume')),
    braced(volume_view, volume_view.index('- (BOOL)hasCropBox')),
    braced(volume_view, volume_view.index('- (BOOL)volumeHasMapper')),
    braced(crop, crop.index('- (BOOL)cropBoxEnabled')),
    braced(crop, crop.index('- (void)setCropBoxEnabled:(BOOL)enabled')),
    braced(crop, crop.index('- (void)executeCropCallback')),
    braced(pipeline, pipeline.index('- (void)releaseFusion'))])

header = r'''
#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(int, ToolMode) { t3DRotate = 7 };
@interface IsiXVTKVolumeView : NSObject
@property (readonly) BOOL hasVolume, hasBlendingVolume, hasCropBox, volumeHasMapper, cropBoxEnabled;
- (void)setCropBoxEnabled:(BOOL)enabled;
- (void)executeCropCallback;
- (void)releaseFusion;
@end
@interface StubController : NSObject
- (nullable NSMatrix *)toolsMatrix;
@end
// What the view's toggle reaches of the view.
@interface Harness : NSObject
@property (readonly) IsiXVTKVolumeView *horos_vtk;
@property (readonly, nullable) StubController *horos_controller;
INSTALL_DECL- (void)placeCropBoxOnAppliedCrop;
- (void)setCurrentTool:(ToolMode)tool;
- (void)setEngine:(long)engine showWait:(BOOL)wait;
UNFUSE_DECL@end
NS_ASSUME_NONNULL_END
'''
if swift_volume:
    header = header.replace('INSTALL_DECL', '').replace('UNFUSE_DECL', '''@property (nonatomic, nullable) char *horos_blendingData8;
@property (nonatomic, assign, nullable) NSMutableArray *horos_blendingPixList;
''')
else:
    header = header.replace('INSTALL_DECL', '- (void)installEngineIfNeeded;\n').replace('UNFUSE_DECL', '- (void)unfuse;\n')

harness = r'''
#import "harness.h"
#include <cstdio>
#include <cstdlib>
struct vtkObject { virtual ~vtkObject() {} };
struct vtkCommand : vtkObject { virtual void Execute(vtkObject *, unsigned long, void *) = 0; };
struct vtkPlanes : vtkObject { static vtkPlanes *New() { return new vtkPlanes; } void Delete() { delete this; } };
struct vtkVolumeMapper : vtkObject {
    int clipped = 0; bool deleted = false;
    void SetClippingPlanes(vtkPlanes *) { if (deleted) { fprintf(stderr, "FAIL: a deleted mapper was clipped\n"); exit(1); } ++clipped; }
    void Delete() { deleted = true; }
};
typedef vtkVolumeMapper vtkHorosFixedPointVolumeRayCastMapper;
typedef vtkVolumeMapper vtkGPUVolumeRayCastMapper;
struct vtkVolume : vtkObject {
    vtkVolumeMapper *mapper = nullptr; bool deleted = false;
    vtkVolumeMapper *GetMapper() {
        if (deleted) { fprintf(stderr, "FAIL: the crop callback reached the deleted fused volume\n"); exit(1); }
        return mapper;
    }
    void Delete() { deleted = true; }
};
struct HorosBoxWidget : vtkObject {
    vtkVolume *prop = nullptr; int enabled = 0;
    vtkVolume *GetProp3D() { return prop; }
    void GetPlanes(vtkPlanes *) {}
    void SetHandleSize(double) {}
    int GetEnabled() { return enabled; }
    void On() { enabled = 1; }
    void Off() { enabled = 0; }
};
RETINA_STUB
@implementation StubController
- (NSMatrix *)toolsMatrix { return nil; }
@end
struct vtkRenderer { void RemoveVolume(vtkVolume *) {} };
struct Deletable { bool deleted = false; void Delete() { deleted = true; } };
typedef HorosBoxWidget vtkBoxWidget;
typedef Deletable vtkPiecewiseFunction, vtkVolumeProperty, vtkColorTransferFunction, vtkImageImport;
#define override
#include <initializer_list>
template <typename Body>
static void IsiXVTKVolumeRun(const char *, std::initializer_list<vtkObject *>, Body &&body) { body(); }

CALLBACK

// The adapter's objects, as many as the blocks here reach.
struct IsiXVTKVolumeViewObjects {
    vtkVolume *volume = nullptr; HorosBoxWidget *croppingBox = nullptr; IsiXVTKCropCallback *cropcallback = nullptr;
    vtkRenderer *aRenderer = nullptr; vtkVolume *blendingVolume = nullptr;
    vtkHorosFixedPointVolumeRayCastMapper *blendingVolumeMapper = nullptr;
    vtkPiecewiseFunction *blendingOpacityTransferFunction = nullptr; vtkVolumeProperty *blendingVolumeProperty = nullptr;
    vtkColorTransferFunction *blendingColorTransferFunction = nullptr; vtkImageImport *blendingReader = nullptr;
};
@interface IsiXVTKVolumeView () {
@public
    IsiXVTKVolumeViewObjects *_o;
}
@end
@implementation IsiXVTKVolumeView
ADAPTER
@end

@interface Harness () {
@public
    IsiXVTKVolumeView *vtk;
    char *blendingData8; NSMutableArray *blendingPixList;
    StubController *controller; vtkVolumeMapper *engineMapper; int engineInstalls;
}
@end
// The Swift toggle (and unfuse), declared for main().
@interface Harness (Toggle)
- (void)showCropCube:(nullable id)sender;
- (void)unfuse;
@end
@implementation Harness
- (IsiXVTKVolumeView *)horos_vtk { return vtk; }
- (StubController *)horos_controller { return controller; }
UNFUSE_METHOD
- (void)setEngine:(long)engine showWait:(BOOL)wait { ++engineInstalls; vtk->_o->volume->mapper = engineMapper; }
- (void)placeCropBoxOnAppliedCrop {}
- (void)setCurrentTool:(ToolMode)tool {}
INSTALL
TOGGLE
@end

int main() { @autoreleasepool {
    {
        // A window opened without its 3D state: the volume has no mapper yet.
        vtkVolumeMapper installed; vtkVolume bare; vtkBoxWidget box; box.prop = &bare;
        Harness *v = [Harness new];
        v->vtk = [IsiXVTKVolumeView new]; v->vtk->_o = new IsiXVTKVolumeViewObjects;
        IsiXVTKVolumeViewObjects *o = v->vtk->_o;
        o->volume = &bare; o->croppingBox = &box; v->engineMapper = &installed;
        o->cropcallback = IsiXVTKCropCallback::New();
        o->cropcallback->SetBlendingVolume(nullptr);
        o->cropcallback->Execute(&box, 0, nullptr);
        if (installed.clipped) { fprintf(stderr, "FAIL: a mapper not yet installed was clipped\n"); return 1; }
        [v showCropCube:nil];
        if (!box.enabled) { fprintf(stderr, "FAIL: the crop box did not turn on\n"); return 1; }
        if (v->engineInstalls != 1 || installed.clipped != 1) {
            fprintf(stderr, "FAIL: turning the crop on did not install the engine and clip its mapper (%d, %d)\n", v->engineInstalls, installed.clipped);
            return 1;
        }
        [v showCropCube:nil];
        [v showCropCube:nil];
        if (box.enabled != 1 || v->engineInstalls != 1 || installed.clipped != 2) {
            fprintf(stderr, "FAIL: off and on again, the crop does not reach the one mapper (%d, %d)\n", v->engineInstalls, installed.clipped);
            return 1;
        }
        // A fused volume still without its mapper is left alone too.
        vtkVolume fusedBare; o->cropcallback->SetBlendingVolume(&fusedBare);
        o->cropcallback->Execute(&box, 0, nullptr);
        if (installed.clipped != 3) { fprintf(stderr, "FAIL: a fused volume without a mapper stopped the crop\n"); return 1; }
    }
    vtkVolumeMapper primaryMapper, fusedMapper;
    vtkVolume primary, *fused = new vtkVolume;
    primary.mapper = &primaryMapper; fused->mapper = &fusedMapper;
    vtkBoxWidget widget; widget.prop = &primary;
    Harness *h = [Harness new];
    h->vtk = [IsiXVTKVolumeView new]; h->vtk->_o = new IsiXVTKVolumeViewObjects;
    IsiXVTKVolumeViewObjects *o = h->vtk->_o;
    o->aRenderer = new vtkRenderer;
    o->cropcallback = IsiXVTKCropCallback::New();
    o->cropcallback->SetBlendingVolume(nullptr);
    o->blendingVolume = fused; o->blendingVolumeMapper = &fusedMapper;
    o->blendingOpacityTransferFunction = new Deletable; o->blendingVolumeProperty = new Deletable;
    o->blendingColorTransferFunction = new Deletable; o->blendingReader = new Deletable;
    h->blendingData8 = (char *)malloc(16); h->blendingPixList = [[NSMutableArray alloc] init];
    o->cropcallback->SetBlendingVolume(o->blendingVolume);

    o->cropcallback->Execute(&widget, 0, nullptr);
    if (primaryMapper.clipped != 1 || fusedMapper.clipped != 1) { fprintf(stderr, "FAIL: fused, the crop does not reach both mappers\n"); return 1; }
    [h unfuse];
    if (o->blendingVolume || !fused->deleted) { fprintf(stderr, "FAIL: the unfuse block no longer deletes the fused volume\n"); return 1; }
    if (h->blendingData8 || h->blendingPixList) { fprintf(stderr, "FAIL: the unfuse block keeps the fused series' voxels or frames\n"); return 1; }
    o->cropcallback->Execute(&widget, 0, nullptr);
    if (primaryMapper.clipped != 2) { fprintf(stderr, "FAIL: after unfusing, the crop no longer reaches the primary mapper\n"); return 1; }
    printf("ok\n");
} return 0; }
'''.replace('CALLBACK', callback).replace('ADAPTER', adapter) \
    .replace('UNFUSE_METHOD', '@synthesize horos_blendingData8 = blendingData8, horos_blendingPixList = blendingPixList;' if swift_volume
             else '- (void)unfuse {\n' + unfuse + '\n}') \
    .replace('INSTALL', '' if swift_volume else install).replace('TOGGLE', '' if swift_toggle else toggle) \
    .replace('RETINA_STUB', '' if swift_toggle else """@interface HorosVTKRetinaGeometry : NSObject
+ (BOOL)cropBoxEnabledAfterToggle:(BOOL)enabled;
@end
@implementation HorosVTKRetinaGeometry
+ (BOOL)cropBoxEnabledAfterToggle:(BOOL)enabled { return !enabled; }
@end""")

# The Swift toggle runs on the main actor, as the view's does.
swift = """import AppKit

@MainActor extension Harness {
TOGGLE
}
""".replace('TOGGLE', toggle)
if swift_volume:
    swift += """
@MainActor extension Harness {
INSTALL
    @objc func unfuse() {
        let vtk = horos_vtk
UNFUSE
    }
}
""".replace('INSTALL', swift_install).replace('UNFUSE', unfuse)

with tempfile.TemporaryDirectory() as work:
    folder = Path(work)
    (folder / 'harness.h').write_text(header)
    program = folder / 'unfuse.mm'
    program.write_text(harness)
    binary = folder / 'unfuse'
    objects = []
    if swift_toggle:
        (folder / 'toggle.swift').write_text(swift)
        built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'Harness', '-parse-as-library', '-wmo',
                                '-swift-version', '6', '-warnings-as-errors',
                                '-import-objc-header', str(folder / 'harness.h'),
                                '-c', str(folder / 'toggle.swift'),
                                str(root / 'Horos/Sources/VTKRetinaGeometry.swift'),
                                str(root / 'Horos/Sources/VRInteractionGeometry.swift'),
                                '-o', str(folder / 'swift.o')], capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: the Swift toggle does not build:\n' + built.stderr[-3000:])
        objects.append(str(folder / 'swift.o'))
    built = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-x', 'objective-c++', '-I', str(folder),
                            '-c', str(program), '-o', str(folder / 'unfuse.o')], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the harness does not build:\n' + built.stderr[-3000:])
    built = subprocess.run(['xcrun', 'swiftc', str(folder / 'unfuse.o'), *objects, '-lc++',
                            '-framework', 'Cocoa', '-o', str(binary)], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the harness does not link:\n' + built.stderr[-3000:])
    run = subprocess.run([str(binary)], capture_output=True, text=True)
    if run.returncode or run.stdout.strip() != 'ok':
        sys.exit((run.stderr or run.stdout).strip() or 'FAIL: the harness stopped with %d' % run.returncode)
print('ok: unfusing clears the crop callback before the fused volume is deleted; '
      'the crop box installs the engine before it clips, and the callback waits for a mapper')

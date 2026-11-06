#!/usr/bin/env python3
"""The SEG surfaces' window lets its views and the VR renderers it borrowed go when they close.

The SEG Surfaces panel (ViewerSEGSurface.swift) is reusable: each close of its
own window must let its surface view go (-prepareForRelease, which the view
does not repeat by itself after the first close). It also shows its surfaces in
the volume rendering windows of its series, through scenes that borrow their
renderers (IsiXVTKScene, Adapters/VTK); when one of those windows closes, its
actors leave that renderer and the panel forgets the renderer, which a borrowed
scene retains.

The close handler is checked in the Swift source; the borrowing is run: the
scene adapter is compiled against the VTK the Debug build installed (exit 2
without that build) with a driver whose stand-in VR view answers -renderer
with a real vtkRenderer, adds an actor through one borrowed scene and removes
it through another, as the panel does at the close, and checks that the
renderer is released with the last scene that borrowed it.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
ADAPTER = SOURCES / 'Adapters/VTK'

source = (SOURCES / 'ViewerSEGSurface.swift').read_text(encoding='utf-8')
start = source.index('    @objc(windowWillClose:)')
handler = source[start:source.index('\n    }\n', start)]
own, _, other = handler.partition('} else {')
failures = []
if 'surfaceView.prepareForRelease()' not in own.split('=== window', 1)[-1]:
    failures.append('closing the panel does not let its surface view go at every close')
if 'ownsWindowController(controller)' not in other or 'IsiXVTKScene(borrowingRendererOf:' not in other:
    failures.append('closing a VR window of the series does not reach its renderer')
if not re.search(r'for actor in actors \{ closing\.removeActor\(actor\) \}', other):
    failures.append('the closing VR window keeps the panel\'s actors')
if 'externalScenes.removeAll { $0.rendererIdentity == closing.rendererIdentity }' not in other:
    failures.append('the panel keeps the closed VR window\'s renderer')
for contract in ('nc.addObserver(self, selector: #selector(sourceClosed(_:)), name: .OsirixViewerWillChange, object: viewer)',
                 'nc.addObserver(self, selector: #selector(sourceVolumeChanged(_:)), name: .OsirixUpdateVolumeData, object: nil)',
                 '(image.frameID?.intValue ?? 0) + 1', 'SEGViewerSession(volume: volume, sourceFrames: references)'):
    if contract not in source:
        failures.append('the panel lost ' + contract)
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

INSTALL = next((base / 'Intermediates.noindex/Horos.build/Debug/VTK.build/Install'
                for base in (ROOT / 'build', ROOT / 'build/Build')
                if (base / 'Intermediates.noindex/Horos.build/Debug/VTK.build/Install/wlib/libVTK.a').is_file()), None)
if INSTALL is None:
    print('skipped: needs the VTK of a Debug build from script/build_and_run.sh --verify')
    sys.exit(2)

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXVTKScene.h"
#include <vtkActor.h>
#include <vtkRenderer.h>
#include <cstdio>

@interface StandInVRView : NSObject { @public vtkRenderer *backing; }
- (vtkRenderer *)renderer;
@end
@implementation StandInVRView
- (vtkRenderer *)renderer { return backing; }
@end

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}

int main() {
    vtkRenderer *renderer = vtkRenderer::New();
    @autoreleasepool {
        StandInVRView *view = [StandInVRView new];
        view->backing = renderer;
        IsiXVTKActor *actor = [IsiXVTKActor sphereAt:(IsiXVTKPoint){0, 0, 0} radius:1 error:NULL];
        NSMutableArray<IsiXVTKScene *> *external = [NSMutableArray array];
        @autoreleasepool {
            IsiXVTKScene *shown = [IsiXVTKScene sceneOfView:view];
            [shown addActor:actor];
            [external addObject:shown];
        }
        check(renderer->GetActors()->GetNumberOfItems() == 1, "the panel's actor is in the VR renderer");
        check(renderer->GetReferenceCount() == 2, "the borrowed scene retains the renderer");
        @autoreleasepool {
            // The close: another scene borrows the same renderer, the actors leave
            // it, and the panel forgets the scenes of that renderer.
            IsiXVTKScene *closing = [IsiXVTKScene sceneOfView:view];
            [closing removeActor:actor];
            NSIndexSet *same = [external indexesOfObjectsPassingTest:^BOOL(IsiXVTKScene *scene, NSUInteger, BOOL *) {
                return scene.rendererIdentity == closing.rendererIdentity;
            }];
            [external removeObjectsAtIndexes:same];
        }
        check(renderer->GetActors()->GetNumberOfItems() == 0, "the closing VR window keeps none of the panel's actors");
        check(external.count == 0 && renderer->GetReferenceCount() == 1, "and the renderer is let go with the last borrowed scene");
        check([IsiXVTKScene sceneOfView:[NSObject new]] == nil, "a view without a renderer lends none");
    }
    renderer->Delete();
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory(prefix='isix-seg-teardown-') as folder:
    folder = Path(folder)
    (folder / 'driver.mm').write_text(DRIVER)
    sources = [folder / 'driver.mm', ADAPTER / 'IsiXVTKError.mm', ADAPTER / 'IsiXVTKScene.mm',
               ADAPTER / 'IsiXVTKSceneActors.mm', ADAPTER / 'IsiXVTKSceneOverlay.mm',
               ADAPTER / 'IsiXVTKVolumePresentation.mm', ADAPTER / 'IsiXVTKVolumeInteraction.mm']
    plain = [SOURCES / 'Adapters/VTK/vtkHorosFixedPointVolumeRayCastMapper.cxx', SOURCES / 'Adapters/VTK/vtkHorosFixedPointVolumeRayCastMIPHelper.cxx',
             SOURCES / 'Adapters/VTK/SceneFactory.cxx']
    objects = []
    for index, path in enumerate(sources + plain):
        output = folder / f'{index}.o'
        language = ['-x', 'objective-c++', '-fobjc-arc'] if path.suffix == '.mm' else ['-x', 'c++']
        compiled = subprocess.run(['xcrun', 'clang++', '-std=c++17', *language, '-c', '-I' + str(INSTALL / 'include'),
                                   '-I' + str(ADAPTER), '-iquote', str(SOURCES), str(path), '-o', str(output)],
                                  capture_output=True, text=True)
        if compiled.returncode:
            print(compiled.stderr[-4000:])
            print('FAIL: ' + path.name + ' does not compile against VTK')
            sys.exit(1)
        objects.append(str(output))
    external = INSTALL.parent.parent / 'ExternalInputs.build/Install/lib'
    linked = subprocess.run(['xcrun', 'clang++', *objects, str(INSTALL / 'wlib/libVTK.a'), '-L' + str(external),
                             '-lpng16', '-ltiff', '-Wl,-rpath,' + str(external), '-lz', '-framework', 'Foundation',
                             '-framework', 'AppKit', '-o', str(folder / 'driver')], capture_output=True, text=True)
    if linked.returncode:
        print(linked.stderr[-4000:])
        sys.exit(1)
    run = subprocess.run([str(folder / 'driver')], capture_output=True, text=True, timeout=60)
    print(run.stdout, end='')
    if run.returncode:
        print(run.stderr[-2000:])
        sys.exit(1)
print('PASS: the SEG panel lets its view go at each close and the VR renderers it borrowed when they close')

#!/usr/bin/env python3
"""An engine switch keeps the crop in place, a saved camera's included.

setCamera: puts a camera's six crop planes on the mapper and hides the crop
widget without moving it. Every engine switch goes through instantiateEngine:,
which ended by executing the crop callback: the callback re-applied the
widget's planes - the whole box, or the last crop made by hand - and a
camera's crop was lost at every switch, including the switch to the CPU that
prepareFullDepthCapture makes. Fusing a series (setBlendingEngine:) did the
same. Checked here:

* instantiateEngine: holds the crop the mapper has before the switch and puts
  it on the new engine's mappers, and runs the callback only when there is no
  crop yet;
* setBlendingEngine: gives a fused series the crop in place, not the widget's;
* the crop is copied into each mapper's own collection - VTK refills a
  mapper's collection in place, so a shared one would move every crop at once.

The crop's VTK objects are the adapter's (IsiXVTKVolumePipeline.mm): the view
holds, applies and releases the crop through it. The view's engines are Swift
(VRView+Engine.swift), an extension of the class; a revision that still has
them in VRView.m is read there.

`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]


def read(path):
    return (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]) if len(sys.argv) > 1
            else (root / path).read_bytes()).decode('latin1')


try:
    view_source = read('Horos/Sources/VRView.m')
except (OSError, subprocess.CalledProcessError):
    # The class is Swift since (VRView.swift): its engines are read below.
    view_source = ''
adapter_source = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm')


def method(signature, source):
    start = source.find(signature)
    if start < 0: return ''
    depth, index = 0, source.index('{', start)
    while True:
        if source[index] == '{': depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0: return source[start:index + 1]
        index += 1


failures = []
engine = method('- (void) instantiateEngine: (int) e', view_source)
blending = method('- (void) setBlendingEngine: (long) engineID showWait:(BOOL) showWait', view_source)
if engine:
    hold_call, switch_call, release_call = '[vtk holdAppliedCrop];', 'switch( e)', '[vtk releaseHeldCrop];'
    apply_held = r'if\( \[vtk applyHeldCrop\] == NO\)\s*\[vtk executeCropCallback\];'
    reapply_applied = r'if\( \[vtk reapplyAppliedCrop\] == NO\)\s*\[vtk executeCropCallback\];'
else:
    engine_source = read('Horos/Sources/VRView+Engine.swift')
    engine = method('private func instantiate(engine e: Int32)', engine_source)
    blending = method('func setBlendingEngine(_ engineID: Int, showWait: Bool)', engine_source)
    hold_call, switch_call, release_call = 'vtk.holdAppliedCrop()', 'switch e {', 'vtk.releaseHeldCrop()'
    apply_held = r'if !vtk\.applyHeldCrop\(\) \{\s*vtk\.executeCropCallback\(\)\s*\}'
    reapply_applied = r'if !vtk\.reapplyAppliedCrop\(\) \{\s*vtk\.executeCropCallback\(\)\s*\}'
apply = method('- (void)applyCropPlanes:(vtkPlaneCollection *)crop', adapter_source)
hold = method('- (void)holdAppliedCrop', adapter_source)
release = method('- (void)releaseHeldCrop', adapter_source)
applied = method('static vtkPlaneCollection *IsiXVTKAppliedCrop(IsiXVTKVolumeViewObjects *o)', adapter_source)
reapply = method('- (BOOL)reapplyAppliedCrop', adapter_source)

held = engine.find(hold_call)
switch = engine.find(switch_call)
if held < 0 or switch < 0 or held > switch or \
        'return o->volume && o->volume->GetMapper() ? o->volume->GetMapper()->GetClippingPlanes() : nullptr;' not in applied or \
        'o->heldCrop = IsiXVTKAppliedCrop(o);' not in hold:
    failures.append('instantiateEngine: does not hold the crop the mapper has before the switch')
if not re.search(apply_held, engine) or \
        '[self applyCropPlanes:o->heldCrop];' not in method('- (BOOL)applyHeldCrop', adapter_source):
    failures.append('instantiateEngine: re-applies the widget\'s planes over the crop in place')
if engine.count(release_call) != 1 or hold.count('o->heldCrop->Register(nullptr);') != 1 or \
        release.count('o->heldCrop->UnRegister(nullptr);') != 1:
    failures.append('instantiateEngine: does not keep the held crop alive across the switch, or leaks it')
if not re.search(reapply_applied, blending) or \
        'vtkPlaneCollection *crop = IsiXVTKAppliedCrop(o);' not in reapply or '[self applyCropPlanes:crop];' not in reapply:
    failures.append('setBlendingEngine: gives a fused series the widget\'s planes, not the crop in place')
for mapper in ('volumeMapper', 'blendingVolumeMapper'):
    if 'if( o->%s) o->%s->SetClippingPlanes( planes);' % (mapper, mapper) not in apply:
        failures.append('the crop does not reach ' + mapper)
if 'SetClippingPlanes( crop)' in apply or 'vtkPlanes *planes = vtkPlanes::New();' not in apply:
    failures.append('the mappers share one plane collection instead of their own copies')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('ok: an engine switch and a fusion keep the crop in place, a saved camera\'s included')

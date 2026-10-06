#!/usr/bin/env python3
"""An orthogonal MPR view drops the planar thick slab it keeps when its images are resliced.

The planar draw copies the other slices of a thick slab (mean, MIP, MinIP) once
and keeps them on the view between draws, recognised by the address of each
DCMPix and of its pixels. OrthogonalReslice hands the sagittal and coronal
views the same DCMPix objects on every reslice, their pixels rewritten in
place, so the addresses never change: with the slab on, a scroll in those
views reduced the new current slice with the slices of the old position, and
the projection hardly moved.

Source-level contract:

- the bridge keys its copy of the slices by their addresses (the reason for
  the rest) and has `horosPlanarForgetSlab`, declared in its header, which
  clears both the key and the copy;
- `-[OrthogonalMPRView setPixList:::]`, which every reslice goes through, and
  through it the PET-CT and endoscopy views, calls it after the new list is
  set and before the view draws it;
- the reslicer still reuses its images, which is what makes the call needed.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'],
                              check=True, capture_output=True, text=True).stdout
    return (root / path).read_text()


bridge = read('Horos/Sources/PlanarHostBridge.m')
header = read('Horos/Sources/PlanarHostBridge.h')
view = read('Horos/Sources/OrthogonalMPRView.swift')
reslicer = read('Horos/Sources/OrthogonalReslice.swift')

# The cache is recognised by addresses, so rewritten pixels keep its key.
assert '[key appendFormat:@"/%p:%p", slice, samples];' in bridge, 'the slab key is no longer made of addresses'
assert 'objc_getAssociatedObject(view, &slabKeyKey) isEqualToString:key]' in bridge

# The bridge can forget it: key and copy both.
assert re.search(r'^- \(void\)horosPlanarForgetSlab;$', header, re.M), 'horosPlanarForgetSlab is not declared'
forget = re.search(r'- \(void\)horosPlanarForgetSlab \{(.*?)\n\}', bridge, re.S)
assert forget, 'horosPlanarForgetSlab is not implemented'
assert 'objc_setAssociatedObject(self, &slabKeyKey, nil,' in forget.group(1)
assert 'objc_setAssociatedObject(self, &slabDataKey, nil,' in forget.group(1)

# The orthogonal view forgets it whenever its images are replaced, before it draws them.
start = view.index('@objc(setPixList:::)')
body = view[start:view.index('@objc(setPixList::)', start)]
assert 'self.horosPlanarForgetSlab()' in body, 'setPixList::: keeps the slab of the previous images'
assert body.index('sendSetPixels(self, pix') < body.index('self.horosPlanarForgetSlab()') < body.index('self.setIndex(0)')

# The reason: the reslicer reuses its images and rewrites their pixels.
assert 'curPix = newPixListX.object(at: stack) as! DCMPix' in reslicer
assert 'curPix = newPixListY.object(at: stack) as! DCMPix' in reslicer

print('orthogonal MPR slab refresh: ok')

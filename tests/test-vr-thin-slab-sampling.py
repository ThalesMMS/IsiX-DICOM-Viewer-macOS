#!/usr/bin/env python3
"""A slab thinner than the ray caster's sample distance is still sampled.

The planes of the 3D MPR that the Metal reslice refuses are read from the
picture of VTK's fixed point ray caster, and so is every slab VTK draws. That
ray caster gives no sample to a ray shorter than its sample distance. Measured
in the application, in the units of the scene (3.5 to the millimetre there):
at the usual distance of 1.2 a slab 1.4 deep was drawn and one 1.05 deep was
blank, and at 0.3 a slab 0.35 deep was drawn and one 0.175 deep was blank. A
series with slices of 0.1 mm, a slab 0.35 deep, opened on three empty planes.
On an interactive render VTK samples every 2.0 instead, whatever the view
asked for, and a slab of 0.5 mm, 1.75 deep, that had been drawn went blank.

What is checked:

- the rule (VRRaySlabSampling.h, compiled here): the distance is kept to half
  the depth between the clipping planes, so a ray holds two steps; a view
  volume twice as deep as the distance or more, the whole volume of a
  rendering among them, is sampled as it was;
- the ray caster applies it to both distances, the usual and the interactive
  one, for the picture it renders, after the Metal picture had its turn, and
  puts back what the view set.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
header = root / 'Horos/Sources/Adapters/VTK/VRRaySlabSampling.h'
mapper = (root / 'Horos/Sources/Adapters/VTK/vtkHorosFixedPointVolumeRayCastMapper.cxx').read_text()

MAIN = r'''
#include <stdio.h>
#include <stdlib.h>
#include "VRRaySlabSampling.h"

#define check(c, m) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", m); exit(1); } } while (0)

/* What was measured: a ray is sampled when it is longer than the distance. */
static int sampled(float distance, double depth) { return depth > distance; }

int main(void) {
    const double depths[] = {0.01, 0.175, 0.35, 0.7, 1.05, 1.4, 1.75, 2.39, 2.4, 3.5, 4.0, 7.0, 500.0};
    const float distances[] = {1.2f, 2.0f, 0.3f, 1.0f};
    /* The measures themselves. */
    check(sampled(1.2f, 1.4) && !sampled(1.2f, 1.05) && sampled(0.3f, 0.35) && !sampled(0.3f, 0.175), "the measures");
    for (int d = 0; d < 4; d++)
        for (int s = 0; s < 13; s++) {
            float distance = HorosRaySampleDistanceForDepth(distances[d], depths[s]);
            check(sampled(distance, depths[s]), "a slab is left without a sample");
            check(depths[s] / distance >= 1.999, "a ray does not hold two steps");
            check(distance <= distances[d], "a slab is sampled more coarsely than the view asked");
            if (depths[s] >= distances[d] * 2)
                check(distance == distances[d], "a view volume twice as deep as the distance changed its sampling");
        }
    /* The cases of the report: slices of 0.1 mm, and 0.5 mm on an interactive render. */
    check(!sampled(1.2f, 0.35) && sampled(HorosRaySampleDistanceForDepth(1.2f, 0.35), 0.35), "0.1 mm at the usual distance");
    check(!sampled(2.0f, 1.75) && sampled(HorosRaySampleDistanceForDepth(2.0f, 1.75), 1.75), "0.5 mm on an interactive render");
    /* No slab, or a distance that is not one: as given. */
    check(HorosRaySampleDistanceForDepth(1.2f, 0) == 1.2f && HorosRaySampleDistanceForDepth(1.2f, -3) == 1.2f, "no depth");
    check(HorosRaySampleDistanceForDepth(0, 0.1) == 0, "no distance");
    puts("PASS: every slab holds two steps, and a view volume twice as deep as the distance is sampled as it was");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='horos-thin-slab-') as folder:
    folder = Path(folder)
    (folder / 'main.c').write_text(MAIN)
    subprocess.run(['xcrun', 'clang', '-Wall', '-Werror', '-I', str(header.parent), str(folder / 'main.c'), '-o', str(folder / 'test')], check=True)
    subprocess.run([str(folder / 'test')], check=True)

assert '#include "VRRaySlabSampling.h"' in mapper, 'the ray caster does not know the rule'
render = mapper[mapper.index('void vtkHorosFixedPointVolumeRayCastMapper::Render('):]
render = render[:render.index('\nvoid vtkHoros', 10)]
external, fitted, initialised = (render.index('if (this->ExternalImageValid)'),
                                 render.index('HorosRaySampleDistanceForDepth(this->SampleDistance'),
                                 render.index('this->PerImageInitialization('))
assert external < fitted < initialised, 'the distances are fitted after the Metal picture had its turn and before VTK reads them'
assert re.search(r'this->InteractiveSampleDistance = HorosRaySampleDistanceForDepth\(this->InteractiveSampleDistance, range\[1\] - range\[0\]\)', render), \
    'the interactive distance, which VTK takes in place of the usual one, is not fitted'
assert 'camera->GetClippingRange(range)' in render, 'the depth is not the one between the camera\'s clipping planes'
kept = render.index('} kept(this->SampleDistance, this->InteractiveSampleDistance);')
assert kept < fitted and '~SampleDistancesKept() { Usual = KeptUsual; Interactive = KeptInteractive; }' in render, \
    'the distances the view set are not put back when the picture is done'
print('PASS: the ray caster fits both sample distances to the slab for the picture it renders, and puts them back')

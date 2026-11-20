#!/usr/bin/env python3
"""The crosshair travels as patient coordinates, and the slab ends agree.

The crosshair is placed by patient coordinates between viewers. Two
things have to hold for that.

**The point has to be patient coordinates.** `-[DCMView sync3DPosition]` converts
the mouse position to DICOM coordinates and sends them; the receiver finds the
nearest plane and converts back into its own slice. Those two conversions are
`-[DCMPix convertPixX:pixY:toDICOMCoords:pixelCenter:]` and
`-[DCMPix convertDICOMCoords:toSliceCoords:]`, and this links the application's
own `DCMPix.o` to put a point through both across series that do not share an
orientation.

**Both ends of a thick slab have to be the right ones.** The sender ships the
current slice and the far end of the slab, so the receiver can draw the band
rather than one line. `-syncMessage:` honoured `flippedData` when picking that
far end and `-sync3DPosition` — the one that carries the crosshair — did not, so
a reversed series sent the band from the wrong side. A slab is centred on the
slice shown and kept inside its series, and one rule says which slices it is
made of, IsiXImaging's `ThickSlabSpan`: both senders, and the receiver, take the
slab from `SyncedSlab`, which asks it with the direction of the view, and the
rule is run here for both directions, an even slab and a slab pulled back from
an end of the series.

**The slab stands where its middle is.** The slice in the middle of the slab is
the slice shown, except within half a slab of an end of the series. The point
of the crosshair is told on that plane, the location the other viewers follow
is its location, the receiver follows it, and draws the two ends of the slab.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import app_object_probe  # noqa: E402
import isix_modules  # noqa: E402
import roi_harness  # noqa: E402

obj = app_object_probe.built_object('DCMPix')
if obj is None:
    print('needs a built DCMPix.o: build Debug or Release once', file=sys.stderr)
    raise SystemExit(2)

failures = []

# -------------------------------------------------------------- the slab rule

driver = r'''
import Foundation
import IsiXImaging

@main struct Check {
    static func main() {
        func slab(_ images: Int, at current: Int, of count: Int, reversed: Bool) -> ThickSlabSpan {
            ThickSlabSpan(images: images, at: current, of: count, towardsStart: reversed)
        }
        // No slab: the slice alone, which has no second end to send.
        for images in [1, 0] {
            let alone = slab(images, at: 4, of: 16, reversed: false)
            precondition(alone.nearEnd == 4 && alone.farEnd == 4 && alone.middle == 4 && alone.count == 1)
        }

        // The slab is around the slice shown, and goes forward, or backward when
        // the series is reversed. This is the difference -sync3DPosition did not make.
        let forward = slab(5, at: 8, of: 16, reversed: false), backward = slab(5, at: 8, of: 16, reversed: true)
        precondition(forward.nearEnd == 6 && forward.farEnd == 10 && forward.middle == 8)
        precondition(backward.nearEnd == 10 && backward.farEnd == 6 && backward.middle == 8)
        precondition(forward.farEnd != backward.farEnd)
        // An even slab has its slice more on the side it goes.
        precondition(slab(4, at: 8, of: 16, reversed: false).indices == 7...10 && slab(4, at: 8, of: 16, reversed: false).farEnd == 10)
        precondition(slab(4, at: 8, of: 16, reversed: true).indices == 6...9 && slab(4, at: 8, of: 16, reversed: true).farEnd == 6)

        // A slab that would reach past an end is pulled back: its ends are slices
        // of the series, it keeps its slices, and its middle is not the slice shown.
        let last = slab(8, at: 14, of: 16, reversed: false)
        precondition(last.nearEnd == 8 && last.farEnd == 15 && last.middle == 11 && last.count == 8)
        let first = slab(8, at: 1, of: 16, reversed: true)
        precondition(first.nearEnd == 7 && first.farEnd == 0 && first.middle == 4 && first.count == 8)
        precondition(slab(8, at: 15, of: 16, reversed: false) == last && slab(8, at: 11, of: 16, reversed: false) == last)
        precondition(slab(2, at: 0, of: 1, reversed: false).indices == 0...0)
        print("rule ok")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='horos-thick-slab-') as folder:
    path = Path(folder)
    (path / 'Check.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'Check.swift'),
                            *isix_modules.module_flags('IsiXImaging', path / 'modules'), '-o', str(path / 'check')],
                           capture_output=True, text=True)
    if build.returncode:
        failures.append('the slab rule does not compile: %s'
                        % build.stderr.strip().splitlines()[-3:])
    else:
        run = subprocess.run([str(path / 'check')], capture_output=True, text=True)
        if run.returncode:
            failures.append('the slab rule does not answer: %s' % run.stderr.strip())

# ----------------------------------------------------- both senders ask for it

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402


def swift_method(text, signature):
    """A Swift method, from its @objc name to the brace that closes its body."""
    start = text.find(signature)
    if start < 0:
        return None
    depth = 0
    for end in range(text.index('{', start), len(text)):
        if text[end] == '{':
            depth += 1
        elif text[end] == '}':
            depth -= 1
            if depth == 0:
                return text[text.index('{', start) + 1:end]
    return None


# -sync3DPosition is Swift, in DCMView+MouseTracking.swift; -syncMessage: and
# -sync: in DCMView+WindowLevel.swift.
tracking = source_text('DCMView+MouseTracking')
windowLevel = source_text('DCMView+WindowLevel')
# The message's values and keys are ViewerSyncMessage's (IsiXImaging); the
# dictionary of the notification is made and read in DCMView+WindowLevel.swift.
syncMessage = (root / 'Modules/IsiXImaging/Sources/ViewerNavigation/ViewerSyncMessage.swift').read_text()
keys = dict(re.findall(r'public static let (\w+) = "([^"]*)"', syncMessage))

sender = swift_method(tracking, '@objc(sync3DPosition)')
if not sender:
    failures.append('-[DCMView sync3DPosition] is gone')
else:
    text = sender
    if 'let slab = SyncedSlab(shownIn: self)' not in text or 'let thickDCM = slab.farEnd' not in text:
        failures.append('sync3DPosition must ask SyncedSlab for the far end of the slab')
    if 'location: Float((slab.middle ?? dcmPixList.object(at: current) as? DCMPix)?.sliceLocation ?? 0)' not in text:
        failures.append('sync3DPosition does not send the location of the middle of the slab')
    if re.search(r'stack\s*-\s*1\)', text):
        failures.append('sync3DPosition still computes the slab end itself')
    if 'farEndImage: thickDCM' not in text:
        failures.append('sync3DPosition no longer sends the far end at all')
    if not re.search(r'patientPoint: ViewerSyncMessage\.PatientPoint\(x: location\[0\], y: location\[1\], z: location\[2\]\)', text):
        failures.append('sync3DPosition no longer sends the point in patient coordinates')

message = swift_method(windowLevel, '@objc(syncMessage:)')
if message is None:
    failures.append('-[DCMView syncMessage:] is gone')
else:
    if 'let slab = SyncedSlab(shownIn: self)' not in message or 'let thickDCM = slab.farEnd' not in message:
        failures.append('syncMessage: must ask SyncedSlab for the far end of the slab')
    if 'let p = slab.middle ?? self.horos_dcmPixList?.object(at: current) as? DCMPix' not in message \
            or 'location: Float(p?.sliceLocation ?? 0)' not in message or 'image: self.curDCM, farEndImage: thickDCM' not in message:
        failures.append('syncMessage: does not send the image shown with the location of the middle of the slab')
    # stack -1), in Swift also through the optional chain: stack ?? 0) - 1).
    if re.search(r'stack(?:\s*\?\?\s*0\s*\))?\s*-\s*1\)', message):
        failures.append('syncMessage: still computes the slab end itself')
    if 'farEndImage: thickDCM' not in message or keys.get('farEndImage') != 'DCMPix2':
        failures.append('syncMessage: no longer sends the far end at all')

# One answer for the slab: the rule, asked with the direction of the view
# (flipped data) or of the image's own slab, never an end computed in place.
shared = windowLevel[windowLevel.index('@MainActor struct SyncedSlab {'):]
shared = shared[:shared.index('\n}\n')]
if 'ThickSlabSpan(images: stack, at: current, of: count, towardsStart: flipped)' not in shared \
        or '(nearEnd, farEnd, middle) = (image(span.nearEnd), image(span.farEnd), image(span.middle))' not in shared \
        or 'flipped: view.horos_flippedData' not in shared or "flipped: (pix?.stackDirection ?? 0) != 0" not in shared:
    failures.append('SyncedSlab does not take the ends and the middle of the slab from ThickSlabSpan, in the direction of the slab')
if re.search(r'stack\s*-\s*1\)', shared):
    failures.append('SyncedSlab computes a slab end itself')
# A picture of the slab is written where the slab is: its position is moved
# from the image shown to the plane midway between the slab's ends, where the
# slice location written beside it is.
move = shared[shared.find('func moveToCentre('):]
if '(horosPlaneOrigin(nearEnd) + horosPlaneOrigin(farEnd)) / 2 - horosPlaneOrigin(shown)' not in move \
        or 'guard let nearEnd, let farEnd, let shown' not in move:
    failures.append('SyncedSlab does not move an origin from the image shown to the plane midway between the ends of the slab')
capture = (root / 'Horos/Sources/DCMView+Capture.swift').read_text()
written = capture[capture.find('self.getThickSlabThickness(&thickness, location: &location)'):]
moved, set_position = written.find('SyncedSlab(shownIn: self).moveToCentre(&imOrigin, from: self.curDCM)'), written.find('exportDCM?.setPosition(&imOrigin)')
if not 0 < written.find('exportDCM?.setSlicePosition(location)') < moved < set_position:
    failures.append('the exported picture of a slab says the location of the slab and the position of the image shown')
slices = swift_method(windowLevel, '@objc(computeSlice::)')
if slices is None or 'cut(oPix2 != nil ? SyncedSlab(of: oPix).nearEnd ?? oPix : oPix, self.horos_sliceFromTo)' not in slices \
        or 'cut(oPix2, self.horos_sliceFromTo2)' not in slices:
    failures.append('the reference lines of a slab are not its two ends')

# The receiver has to consume patient coordinates, and only inside the same-world
# guard -- otherwise the crosshair would cross frames of reference.
receiver = swift_method(windowLevel, '@objc(sync:)')
if receiver is None:
    failures.append('-[DCMView sync:] is gone')
else:
    text = receiver
    # The receiver reads the point through ViewerSyncMessage, which reads the three keys.
    reader = syncMessage[syncMessage.index('public init(entry:'):]
    reader = reader[:reader.index('\n    }\n')]
    for key in ('point3DX', 'point3DY', 'point3DZ'):
        if not any('Key.%s' % name in reader for name, value in keys.items() if value == key):
            failures.append('sync: no longer reads %s' % key)
    if 'let oPix = SyncedSlab(of: received.image).middle ?? received.image' not in text:
        failures.append('sync: does not follow the plane in the middle of the slab')
    if 'ReceivedSync(note)' not in text or 'message.patientPoint' not in text:
        failures.append('sync: no longer reads the patient point of the message')
    if 'findPlaneAndPoint(' not in text:
        failures.append('sync: no longer finds the plane for the patient point')
    if 'convertDICOMCoords(' not in text:
        failures.append('sync: no longer converts the patient point into its own slice')
    world = text.find('if same3DReferenceWorld || registeredViewer {')
    point = text.find('if let patientPoint = message.patientPoint {')
    if world < 0 or point < 0 or not world < point:
        failures.append('the patient-coordinate crosshair must stay inside the same-world guard')

if sender and '(slab.middle ?? curDCM).convertX(self.horos_mouseXPos, pixY: self.horos_mouseYPos, toDICOMCoords: &location' not in sender:
    failures.append('sync3DPosition no longer converts the mouse position to patient coordinates, on the plane in the middle of the slab')

# -convertDICOMCoords:toSliceCoords: answers in millimetres; the drawing turns
# that into pixels. Both halves have to stay, or the crosshair moves by the
# pixel spacing without anything looking wrong.
# The drawing is DCMView+Drawing.swift's, its arithmetic DrawingGeometry's.
drawing = (root / 'Horos/Sources/DCMView+Drawing.swift').read_text()
geometry = (root / 'Modules/IsiXImaging/Sources/ViewDrawing/DrawingGeometry.swift').read_text()
handed = re.search(r'DrawingGeometry\.slicePoint\(\(slicePoint3D\[0\], slicePoint3D\[1\]\),\s*'
                   r'pixelSpacingX: pix\?\.pixelSpacingX \?\? 0, pixelSpacingY: pix\?\.pixelSpacingY \?\? 0', drawing)
if not handed or 'var x = Float(Double(point.0) / pixelSpacingX)' not in geometry:
    failures.append('the crosshair is no longer divided by pixelSpacingX before being drawn')
if not handed or 'var y = Float(Double(point.1) / pixelSpacingY)' not in geometry:
    failures.append('the crosshair is no longer divided by pixelSpacingY before being drawn')

# ------------------------------------------------------ the coordinate round trip

PROBE = r'''
#import <Foundation/Foundation.h>
#import "DCMPix.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
// PIX_IVARS

@interface ProbePix : DCMPix
- (void) prepareOrientation:(const double*)o origin:(const double*)p;
@end
@implementation ProbePix
- (void) CheckLoad {}
- (float*) computefImage { return PIX_IVAR( self, float*, fImage); }
- (void) prepareOrientation:(const double*)o origin:(const double*)p
{
    PIX_IVAR( self, long, width) = 64; PIX_IVAR( self, long, height) = 64; PIX_IVAR( self, BOOL, isRGB) = NO;
    PIX_IVAR( self, double, pixelSpacingX) = PIX_IVAR( self, double, pixelSpacingY) = 2.0;      // 2 mm pixels, so a wrong factor shows
    double *orientation = PIX_ORIENTATION( self);
    for( int i = 0; i < 6; i++) orientation[ i] = o[ i];
    // The third vector is the slice normal; DCMPix fills it from the first two.
    orientation[ 6] = orientation[ 1]*orientation[ 5] - orientation[ 2]*orientation[ 4];
    orientation[ 7] = orientation[ 2]*orientation[ 3] - orientation[ 0]*orientation[ 5];
    orientation[ 8] = orientation[ 0]*orientation[ 4] - orientation[ 1]*orientation[ 3];
    PIX_IVAR( self, double, originX) = p[ 0]; PIX_IVAR( self, double, originY) = p[ 1]; PIX_IVAR( self, double, originZ) = p[ 2];
}
@end

static int failures = 0;
static void check( bool ok, const char *what)
{
    if( !ok) { fprintf( stderr, "FAIL: %s\n", what); failures++; }
}

int main(){ @autoreleasepool {
    // Axial: rows along +y, columns along +x, plane at z = 30.
    const double axialOrientation[ 6] = {1,0,0, 0,1,0};
    const double axialOrigin[ 3] = {-64, -64, 30};
    // Coronal: rows along +z, columns along +x, plane at y = -10.
    const double coronalOrientation[ 6] = {1,0,0, 0,0,1};
    const double coronalOrigin[ 3] = {-64, -10, -64};

    ProbePix *axial = [[ProbePix alloc] init];
    [axial prepareOrientation: axialOrientation origin: axialOrigin];
    ProbePix *coronal = [[ProbePix alloc] init];
    [coronal prepareOrientation: coronalOrientation origin: coronalOrigin];

    // A pixel picked in the axial view, as -sync3DPosition does.
    const float pickX = 40, pickY = 12;
    float patient[ 3];
    [axial convertPixX: pickX pixY: pickY toDICOMCoords: patient pixelCenter: YES];

    char message[ 256];
    // 2 mm pixels from (-64, -64, 30), pixel centres: x = -64 + (40 - 0.5)*2,
    // y = -64 + (12 - 0.5)*2, and the slice keeps its own z.
    snprintf( message, sizeof message, "the picked point in patient coordinates is (%g, %g, %g)",
              patient[ 0], patient[ 1], patient[ 2]);
    check( fabs( patient[ 0] - 15) < 0.001 && fabs( patient[ 1] + 41) < 0.001
           && fabs( patient[ 2] - 30) < 0.001, message);

    // -convertDICOMCoords:toSliceCoords: answers in MILLIMETRES along the row
    // and column vectors, not in pixels. The drawing divides by the pixel
    // spacing, which is what makes the trip lossless -- check that it is.
    float back[ 3];
    [axial convertDICOMCoords: patient toSliceCoords: back];
    const float backX = back[ 0] / axial.pixelSpacingX, backY = back[ 1] / axial.pixelSpacingY;
    snprintf( message, sizeof message,
              "the axial round trip gave %g mm, %g mm = pixel (%g, %g), from (%g, %g)",
              back[ 0], back[ 1], backX, backY, pickX, pickY);
    check( fabs( backX - pickX) < 0.001 && fabs( backY - pickY) < 0.001, message);
    snprintf( message, sizeof message,
              "slice coordinates must be millimetres, not pixels: got %g for pixel %g",
              back[ 0], pickX);
    check( fabs( back[ 0] - pickX) > 0.001, message);

    // The same patient point in the coronal view: x = 15 is column 40, z = 30
    // is row 47.5, and the point is 31 mm off that coronal plane in y.
    float other[ 3];
    [coronal convertDICOMCoords: patient toSliceCoords: other];
    const float otherX = other[ 0] / coronal.pixelSpacingX, otherY = other[ 1] / coronal.pixelSpacingY;
    snprintf( message, sizeof message,
              "the coronal view places the point at pixel (%g, %g), %g mm off plane; expected (40, 47.5) and 31",
              otherX, otherY, fabs( other[ 2]));
    check( fabs( otherX - 40) < 0.001 && fabs( otherY - 47.5) < 0.001
           && fabs( fabs( other[ 2]) - 31) < 0.001, message);

    // The off-plane distance is what -findPlaneAndPoint: uses to refuse a point
    // that is nowhere near this series; it must not come out as zero here.
    check( fabs( other[ 2]) > 0.001, "the coronal plane is not the axial plane; the distance must say so");

    if( failures) { fprintf( stderr, "FAIL: %d check%s\n", failures, failures == 1 ? "" : "s"); return 1; }
    printf( "pixel (%g, %g) -> patient (%g, %g, %g) -> coronal pixel (%g, %g), %g mm off plane",
            pickX, pickY, patient[0], patient[1], patient[2], otherX, otherY, fabs( other[2]));
    return 0;
}}
'''

roundTrip = ''
if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-crosshair-') as name:
        directory = Path(name)
        (directory / 'probe.mm').write_text(PROBE.replace('// PIX_IVARS\n', roi_harness.PIX_IVARS))
        # The probe's ROI stands in for the app's, which this object only names.
        run = app_object_probe.link_and_run(directory, [directory / 'probe.mm'], [obj], always_stub=('ROI',))
        if run.returncode:
            sys.stderr.write(run.stderr)
            failures.append('the patient-coordinate round trip does not land where the geometry says')
        else:
            roundTrip = run.stdout.strip()

if failures:
    print('FAIL:')
    for item in failures:
        print(' ', item)
    raise SystemExit(1)

print('PASS: %s; both senders and the receiver take the ends and the middle of a thick slab from one rule' % roundTrip)

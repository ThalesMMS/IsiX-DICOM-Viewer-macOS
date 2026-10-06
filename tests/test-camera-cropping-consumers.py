#!/usr/bin/env python3
"""Run the VR crop-capture block and flythrough import loop with controlled peers.

Actual Camera/Point3D/N3Geometry implementations are linked with ASan. Minimal
VTK peers distinguish applied planes from a stale editing box without a build
dependency. Native rendering/file-panel validation is recorded separately.

Camera and Point3D are Swift: they are compiled with the Swift
below, and the capture block reaches them through their compatibility headers
and the generated interface.

FlyThruStepsArrayController is Swift: the class itself, with the
FlyThruAdapter it calls, is compiled into the check with a stand-in
FlyThruController, and its import loop (-importSteps) and -addObject: run.
The import check is UI-bound and runs on MainActor, with the production callback
helper linked into the same module.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import is_swift, source_path  # noqa: E402

root = Path(__file__).resolve().parents[1]
assert is_swift("FlyThruStepsArrayController"), "FlyThruStepsArrayController is expected in Swift"
assert is_swift("Camera") and is_swift("Point3D"), "Camera and Point3D are expected in Swift"


def block(path, method, anchor):
    source = (root / path).read_bytes().decode("latin1")
    start = source.index(anchor, source.index(method))
    opening = source.index("{", start)
    depth = 0
    for end in range(opening, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError("unterminated source block")


capture = block("Horos/Sources/VRView.mm", "- (Camera*) cameraWithThumbnail:", "if( croppingBox)")
steps_source = source_path("FlyThruStepsArrayController").read_text(encoding="utf-8")
# The IMPORT case runs the loop the check calls.
if "self.importSteps(stepsXML)" not in steps_source[steps_source.index("case 3: // IMPORT"):]:
    raise AssertionError("the IMPORT case no longer goes through importSteps")

# Stand-ins for what FlyThruStepsArrayController reaches: the window controller
# (its FTAdapter, currentCamera, hide flags and flyThru) and an adapter that
# shows nothing. The adapter class is the application's own FlyThruAdapter.
STAND_INS = r'''
import Cocoa

@objc(FlyThruController) final class FlyThruController: NSObject {
    @objc(FTAdapter) var ftAdapter: FlyThruAdapter?
    @objc var currentCamera: Camera?
    @objc var hidePlayBox = false
    @objc var hideExportBox = false
    var flyThru: FlyThru?
}

final class FlyThru: NSObject {
    func exportToXML() -> NSMutableDictionary? { return nil }
}

final class QuietAdapter: FlyThruAdapter {
    override func setCurrentViewToCamera(_ aCamera: Camera?) { }
    override func getCurrentCameraImage(_ highQuality: Bool) -> NSImage? { return nil }
}

@MainActor @_cdecl("runImportChecks") public func runImportChecks(_ current: Camera, _ fallback: Camera) {
    let controller = FlyThruController()
    controller.ftAdapter = QuietAdapter(window3DController: nil)
    controller.currentCamera = fallback
    let importer = FlyThruStepsArrayController(content: NSMutableArray())
    importer.setValue(controller, forKey: "flyThruController")
    importer.importSteps([current.exportToXML()!, fallback.exportToXML()!] as NSArray)
    let steps = importer.arrangedObjects as! NSArray
    precondition(steps.count == 2)
    precondition((steps[0] as! Camera).exportToXML()!.isEqual(current.exportToXML()!))
    precondition((steps[1] as! Camera).exportToXML()!.isEqual(fallback.exportToXML()!))
    precondition((steps[0] as! Camera).index == 1 && (steps[1] as! Camera).index == 2)
    precondition(steps[0] as AnyObject !== current && steps[1] as AnyObject !== fallback)
    // The Add button must still capture the current view, not an empty object.
    importer.addObject(NSObject())
    precondition((importer.arrangedObjects as! NSArray).lastObject as AnyObject === fallback)
}
'''
BRIDGING = """#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "Camera.h"
@interface Window3DController : NSWindowController
- (id) view;
@end
"""
main = r'''
#import "Camera.h"
#include <vector>
#include <cassert>
struct vtkPlane {
    double point[3] = {}, normal[3] = {1,0,0};
    double *GetOrigin() { return point; }
    double *GetNormal() { return normal; }
};
struct vtkPlanes {
    std::vector<vtkPlane> data = std::vector<vtkPlane>(6);
    static vtkPlanes *New() { return new vtkPlanes; }
    void Delete() { delete this; }
    int GetNumberOfPlanes() { return (int)data.size(); }
    vtkPlane *GetPlane(int i) { return &data.at(i); }
};
struct vtkPlaneCollection : vtkPlanes {
    int GetNumberOfItems() { return GetNumberOfPlanes(); }
    vtkPlane *GetItem(int i) { return GetPlane(i); }
};
struct Box : vtkPlanes { void GetPlanes(vtkPlanes *p) { p->data = data; } };
struct Mapper {
    vtkPlaneCollection *planes = nullptr;
    vtkPlaneCollection *GetClippingPlanes() { return planes; }
};
struct Volume { Mapper mapper; Mapper *GetMapper() { return &mapper; } };
static Camera *capture(Box *croppingBox, Volume *volume) {
    Camera *cam = [[[Camera alloc] init] autorelease];
    CAPTURE_BLOCK
    return cam;
}
// Camera.h brings the generated interface, which imports the bridging header
// (Window3DController) and declares runImportChecks.
#import "bridging.h"
@implementation Window3DController
- (id) view { return nil; }
@end
int main() { @autoreleasepool {
    Box stale;
    Volume volume;
    vtkPlaneCollection applied;
    for (int i=0; i<6; ++i) {
        stale.data[i].point[0] = -100-i;
        applied.data[i].point[0] = 10+i*7;
        applied.data[i].normal[0] = i%2 ? -1 : 1;
    }
    volume.mapper.planes = &applied;
    Camera *current = capture(&stale, &volume);
    for (int i=0; i<6; ++i) {
        N3Plane p = [current.croppingPlanes[i] N3PlaneValue];
        assert(p.point.x == 10+i*7 && p.normal.x == (i%2 ? -1 : 1));
    }
    volume.mapper.planes = nullptr;
    Camera *fallback = capture(&stale, &volume);
    for (int i=0; i<6; ++i)
        assert([fallback.croppingPlanes[i] N3PlaneValue].point.x == -100-i);

    // main() executes on the main thread; the Swift entry point is MainActor.
    assert([NSThread isMainThread]);
    runImportChecks(current, fallback);
    puts("PASS: applied crop beats stale widget, fallback works, import keeps decoded cameras, Add still captures");
} }
'''.replace("CAPTURE_BLOCK", capture)

with tempfile.TemporaryDirectory(prefix="horos-camera-consumers-") as temp:
    folder = Path(temp)
    (folder / "main.mm").write_text(main)
    objects = []
    common = ["-fno-objc-arc", "-fsanitize=address", "-g", "-Wno-deprecated-declarations",
              "-include", "Cocoa/Cocoa.h", "-I", str(root / "Horos/Sources"),
              "-I", str(root / "Nitrogen/Sources")]
    for name in ("Nitrogen/Sources/N3Geometry.m",):
        obj = folder / (Path(name).stem + ".o")
        subprocess.run(["xcrun", "clang", *common, "-c", str(root / name), "-o", str(obj)], check=True)
        objects.append(str(obj))
    (folder / "StandIns.swift").write_text(STAND_INS)
    (folder / "bridging.h").write_text(BRIDGING)
    swift = folder / "swift.o"
    subprocess.run(["xcrun", "swiftc", "-module-name", "Horos", "-parse-as-library", "-wmo", "-sanitize=address", "-g",
                    "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
                    "-import-objc-header", str(folder / "bridging.h"),
                    "-Xcc", "-I" + str(root / "Horos/Sources"), "-Xcc", "-I" + str(root / "Nitrogen/Sources"),
                    "-emit-objc-header-path", str(folder / "Horos-Swift.h"),
                    "-c", str(source_path("FlyThruStepsArrayController")), str(source_path("FlyThruAdapter")),
                    str(source_path("Camera")), str(source_path("Point3D")),
                    str(root / "Horos/Sources/MainActorCallbacks.swift"),
                    str(folder / "StandIns.swift"), "-o", str(swift)], check=True)
    main_object = folder / "main.o"
    subprocess.run(["xcrun", "clang++", "-std=c++14", *common, "-I", str(folder), "-c", str(folder / "main.mm"),
                    "-o", str(main_object)], check=True)
    executable = folder / "test"
    subprocess.run(["xcrun", "swiftc", "-sanitize=address",
                    str(main_object), str(swift), *objects, "-lc++", "-framework", "Cocoa", "-framework", "QuartzCore",
                    "-framework", "Accelerate", "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

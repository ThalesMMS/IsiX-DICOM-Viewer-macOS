# IsiXPluginKit

IsiXPluginKit is the plugin API of IsiX DICOM Viewer, version 1: a small Swift
framework that a plugin compiles against, and that the application provides at
run time. A plugin is a `.isixplugin` bundle. It reaches viewers, images, ROIs
and the database through the kit's types only; no class or header of the
application is part of the API. Since IsiX DICOM Viewer 6.0 it is the only
plugin API: plugins made for Horos or OsiriX (`.horosplugin`, `.osirixplugin`)
are not loaded. The plugin template that builds against this SDK is at
[github.com/ThalesMMS/IsiXPluginTemplate](https://github.com/ThalesMMS/IsiXPluginTemplate).

## The bundle

| Item | Value |
| --- | --- |
| Extension | `.isixplugin` (`WRAPPER_EXTENSION = isixplugin`) |
| Package type | `CFBundlePackageType = BNDL` |
| Executable | a Mach-O bundle (`MACH_O_TYPE = mh_bundle`) or dynamic library, named by `CFBundleExecutable` |
| API version | `IsiXPluginAPIVersion`, an integer: `1` |
| Identity | `CFBundleIdentifier` (reverse DNS, yours), `CFBundleName`, `CFBundleShortVersionString` |
| Entry point | `NSPrincipalClass`: the class that adopts `IsiXPlugin`, qualified by its Swift module, `MyPlugin.MyPlugin` (in Xcode, `$(PRODUCT_MODULE_NAME).MyPlugin` in the Info.plist) |
| Capabilities | `IsiXPluginCapabilities`, an array of strings (below) |
| Minimum system | macOS 15.0 (`MACOSX_DEPLOYMENT_TARGET = 15.0`; `LSMinimumSystemVersion` if you set one) |
| Architectures | the application's: `arm64` for Apple silicon, `x86_64` for the Intel package; build both to serve both |
| Linking | link `IsiXPluginKit.framework` from the SDK; do not embed it, do not copy it into the bundle |

A Swift class without `@objc(Name)` is found only by its module-qualified
name: `NSPrincipalClass = MyPlugin` does not resolve. The class must be in the
bundle's own executable.

The application reads all of this before it loads any of the plugin's code,
and refuses the bundle, with the reason shown in the Plugins window, when:

- the Info.plist is missing or unreadable;
- `IsiXPluginAPIVersion` is missing, not an integer, zero or negative, or newer
  than the application supports;
- the identifier, the entry class or the executable is missing;
- a capability is unknown to the application;
- the executable has no slice for the architecture the application runs as, or
  needs a newer macOS;
- the bundle carries its own copy of IsiXPluginKit, or does not link it;
- the code for Apple silicon (`arm64`) is not signed: macOS runs it only
  signed, ad hoc at least (`codesign --sign - MyPlugin.isixplugin`);
- the bundle is a plugin of the former API: a `.horosplugin` or
  `.osirixplugin`, or a bundle with former Info.plist keys (`pluginType`,
  `MenuTitles`, ...) or a former SDK framework linked. Renaming such a bundle
  to `.isixplugin` does not make it a version 1 plugin.

After loading, the entry class must resolve in the plugin's executable and
adopt `IsiXPlugin`; otherwise the plugin is refused too.

## Capabilities

| String | Gives |
| --- | --- |
| `viewer.read` | viewers, their series, images, geometry and pixels; viewer events |
| `viewer.write` | committing pixels; setting the window level; opening a derived series in a new viewer |
| `roi` | reading, creating, measuring and removing ROIs; ROI events |
| `database.read` | studies, series, images (with their files) and albums of the local database; searching it; opening a series in a viewer |
| `database.write` | what the user edits: comments, state and report of studies and series, key images; creating albums and changing their studies |
| `database.import` | writing derived DICOM files of a study; importing files into the local database |
| `network.send` | the DICOM nodes of Locations with Send on; sending images of the database and DICOM files to them |
| `network.query` | the DICOM nodes of Locations with Query/Retrieve on; C-FIND of studies, series and the modality worklist |
| `xmlrpc` | XML-RPC methods of the plugin's own, answered through the application's XML-RPC interface |

A call that needs a capability the plugin did not declare throws
`IsiXPluginError.capabilityNotDeclared`.

## The entry point and its lifecycle

```swift
import IsiXPluginKit

public final class MyPlugin: IsiXPlugin {
    private var observation: IsiXObservation?

    public init() {}

    public func activate(with context: IsiXPluginContext) throws {
        try context.register(IsiXCommand(id: "measure", title: "Measure Slice",
                                         placement: .imageFilters, requirement: .viewer)) { invocation in
            guard let viewer = invocation.viewer else { return }
            let image = try viewer.image()                  // a copy, owned by the plugin
            try context.startTask(named: "Measure") { progress in
                let pixels = image.scalarPixels             // read off the main actor
                // ...
            }
        }
        observation = try context.observe([.sliceChanged, .viewerWillClose]) { event in
            // main actor
        }
    }

    public func deactivate() {}
}
```

- The application creates the plugin once, with `init()`, after the bundle
  passed its checks, and calls `activate(with:)` once. If `activate` throws,
  everything the plugin registered is removed and it is not called again.
- `deactivate()` is called once before the application quits, after the host
  has cancelled the plugin's tasks and removed its observations and commands.
- `IsiXPlugin`, `IsiXPluginContext`, `IsiXViewer`, `IsiXDatabase` and command
  handlers are on the main actor. Use `startTask(named:_:)` for long work.

## Commands

`register(_:handler:)` adds a menu item. The placement chooses the menu (the
viewer's image filters or ROI tools, the database window's plugins, or other
plugins); the command's `id` is what identifies it, the title is only shown. A
command with `requirement: .viewer` is disabled while no 2D viewer is open, and
is never called without one; its invocation carries the frontmost viewer. An
error the handler throws is shown to the user: its
`LocalizedError.errorDescription` when it has one (the kit's own
`IsiXPluginError` does), the localized description of a Cocoa error, or else
its description. Give your errors a sentence the user can act on.

An Objective-C or C++ exception that escapes a command is caught by the
application, shown to the user and recorded in the plugin's loading details;
the plugin stays loaded. One that escapes `activate(with:)` fails the
plugin, as a thrown error does: what it registered is removed, it is not
loaded, and the reason is in its loading details. Nothing between the throw and the application is
cleaned up: Swift `defer` blocks do not run and what those frames held leaks.
Catch the exceptions of the libraries you use inside your own code, and turn
them into a thrown Swift error.

## Viewers, images and geometry

`IsiXViewer` is a handle: it does not keep the viewer open. Once the user
closes the window, `isOpen` is false and every call throws
`IsiXPluginError.viewerClosed`.

`image(slice:phase:)` returns an `IsiXImage`, a copy of one image:

- `pixels`: `.float32` for grayscale, one Float32 sample per pixel in modality
  units (stored values after rescale slope and intercept, or SUV when
  `attributes.isSUV`), or `.rgba8` for colour images. Row-major,
  `width * height * channels` samples.
- `geometry`: rows, columns, `rowSpacing` and `columnSpacing` (Pixel Spacing),
  `imagePosition` (Image Position Patient), `rowDirection` and
  `columnDirection` (Image Orientation Patient), slice thickness, interval and
  location. The centre of the pixel at column `c`, row `r` is
  `imagePosition + rowDirection * (c * columnSpacing) + columnDirection * (r * rowSpacing)`;
  `patientPoint(of:)` and `pixelPoint(of:)` convert. Pixel coordinates put the
  centre of the first pixel at (0, 0).
- `attributes`: modality, UIDs, echo and repetition time, acquisition date,
  rescale, SUV.

`geometry(slice:phase:)` and `attributes(slice:phase:)` return the geometry
and the attributes of an image without copying its pixels: walking the slices
of a series to find where a point lies, or the acquisition time of each phase,
costs no pixel copies.

`setCurrentSlice(_:)` shows another slice of the phase shown;
`setCurrentPhase(_:)` another phase of a 4D series, at the same slice.

### Derived series

`openDerivedSeries(_:)` (needs `viewer.write`) opens a new viewer on a series
the plugin computed: each `IsiXDerivedImage` names the image of the viewer it
replaces (`sourceSlice`, `sourcePhase`) and carries Float32 pixels of that
image's size. The new images keep their sources' geometry, patient and study;
the series lives in memory and is not stored. The call returns the new
viewer's handle. A map computed in a task is opened from the main actor once
the task is done; look the source viewer up again with `viewer(withID:)` and
open nothing if it closed meanwhile.

```swift
let map = IsiXDerivedImage(sourceSlice: 0, sourcePhase: 0,
                           pixels: try IsiXPixelBuffer(width: w, height: h, samples: values))
let mapViewer = try viewer.openDerivedSeries(IsiXDerivedSeries(images: [map]))
```

### Ownership and lifetime

- Everything the kit returns is a value the plugin owns: images, geometry,
  ROIs, statistics, studies and series are `Sendable` copies. They stay valid
  after the viewer closes and can be read on any thread.
- No pointer into the application's memory reaches the plugin.
  `IsiXPixelBuffer.withUnsafeBufferPointer` and
  `withUnsafeMutableBufferPointer` lend the plugin's own samples for the
  duration of the closure only; do not let the pointer escape.
- To change pixels, change a copy and commit it:
  `try viewer.commit(.float32(changed), replacing: image)`. The commit is
  refused with `staleImage` if the image changed or was replaced since it was
  read (for example by another commit, or by the viewer loading another
  series), and with `dimensionMismatch` if the size or format differ. A commit
  changes the image in memory; source files are never written.

## ROIs

`rois(slice:phase:)` lists the ROIs of an image as `IsiXROI` values: kind,
name, comment, slice, phase, points in pixel coordinates and in patient
coordinates, whether it is selected and whether the viewer shows its text box
(name and measurements). `updateROI(_:_:)` changes a ROI in place, keeping its
identifier: an `IsiXROIUpdate` sets its points, name, comment, selection or
text box, and turns a rectangle or an oval into the polygon of the points it
is given, as the application does when it rotates one. `addROI(_:)` creates a point, line, rectangle, oval, polygon or
polyline from an `IsiXROIDraft`; rectangles and ovals take two opposite
corners. `IsiXROIDraft(mask:)` creates a brush ROI from an `IsiXROIMask`: the
values of a rectangle of the image, non-zero inside, from its top left pixel;
the pixels outside the image are left out, and a mask with nothing inside is
refused. A brush ROI's mask is not read back. `statistics(of:)` asks the application for mean, standard deviation,
minimum, maximum and sum, area in mm² for closed shapes and length in mm for
lines. A ROI's identifier stays the same while the ROI exists.
`statistics(of:slice:phase:)` measures the same outline on another image of
the viewer, for instance the same slice in every phase of a 4D series, as a
time-intensity curve needs.

## Events

`observe(_:_:)` delivers, on the main actor: `viewerOpened` (a viewer finished
loading its series, also when it replaced its series), `viewerWillClose`,
`sliceChanged` and `roiChanged` (added, modified, removed, selected), and, with
`database.read`, `imagesAdded`: images entered the local database (imported,
received, retrieved), one batch at a time and once more when the import ends
(`isComplete`, with every image it added), with the SOP Instance UIDs received
from the network by the AE title that sent them. Keep the
returned `IsiXObservation`: the handler is called until `invalidate()`, until
the observation is released, or until the plugin is deactivated, whichever
comes first.

## Mouse and keys on the image

`interceptInput(_:_:)` (needs `viewer.read`) gives the plugin the events of
the images of the open 2D viewers, on the main actor, before the viewer acts
on them: `mouseDown`, `mouseDragged` and `mouseUp` of the left button, and
`keyDown`. Each `IsiXViewerInput` names the viewer, the image shown, the
position on that image in pixel coordinates (the centre of the first pixel at
(0, 0)), the modifier keys, the click count, the characters of a key, and the
position in the viewer's window. Return true and the viewer does nothing else
with the event, as a tool that places a point with a click needs; return
false and the viewer goes on as usual. Every plugin that takes the event's
kind is asked. The token works as an observation's.

```swift
input = try context.interceptInput([.mouseDown]) { event in
    guard placingSeed else { return false }
    seed = (event.viewerID, event.position.slice, event.location)
    return true
}
```

## Drawing over the image

`addOverlay(_:)` on a viewer (needs `viewer.read`) draws over its image each
time the viewer draws it. The handler gets an `IsiXOverlayContext`: a
`CGContext` whose user space is the image's pixel coordinates (one unit per
pixel, x along the columns, y down the rows, the centre of the first pixel at
(0, 0)), with the viewer's zoom, panning, rotation and flips applied; the
image drawn (`position`); and `pointSize`, the length of one point of the
screen in pixels, for lines and marks that keep their size at any zoom. What
is drawn lies over the image and the ROIs, beneath the viewer's text. The
handler runs while the viewer draws, on the main actor, in a graphics state of
its own: keep it short, and call `setNeedsDisplay()` when what it draws
changes. Drawing stops when the returned token is invalidated or released,
the viewer closes or the plugin is deactivated. OpenGL is not available.

```swift
overlay = try viewer.addOverlay { overlay in
    let c = overlay.cgContext
    c.setStrokeColor(red: 0, green: 1, blue: 0.5, alpha: 1)
    c.setLineWidth(2 * overlay.pointSize)
    c.stroke(CGRect(x: seed.x - 5, y: seed.y - 5, width: 10, height: 10))
}
```

## Tasks and cancellation

`startTask(named:_:)` runs an `async` operation off the main actor and returns
an `IsiXTask`. The host cancels it when the plugin is deactivated; the plugin
can cancel it, for example when `viewerWillClose` arrives for the viewer it
works on. Check `Task.isCancelled` or `progress.isCancelled` and return. Work on
copies only; to show a result, hop to the main actor (`await MainActor.run`).

## Database

`context.database()` gives `selectedStudies()`, `study(withInstanceUID:)`,
`series(inStudy:)` (with `database.read`) and `importFiles(at:)` (with
`database.import`). Results are copies; database objects never reach the
plugin. Imported files are copied into the database, which owns the copies; the
plugin's files are only read. The result lists the studies and series created
and, per file, what could not be imported.

`writeDerivedSeries(_:)` (needs `database.import`) writes colour images
(`.rgba8`) as a new series of secondary capture DICOM files of a study of the
database: the application's DICOM writer copies the patient and the study from
an image of that study. The files are written to a new temporary folder and
returned in order; nothing is added to the database until the plugin imports
them with `importFiles(at:)`. The files are the plugin's: remove them once
imported.

```swift
let database = try context.database()
guard let study = try await database.selectedStudies().first else { return }
let files = try await database.writeDerivedSeries(
    IsiXDerivedSeriesRequest(studyInstanceUID: study.studyInstanceUID, seriesDescription: "Photos", images: [.rgba8(pixels)]))
let result = try await database.importFiles(at: files)
```

Grayscale images (`.float32`, in modality units) are written too, as signed
16-bit samples with a Rescale Slope: exactly when every value is whole and
from -32768 to 32767, otherwise scaled to that range (within half a step of
the slope). A request can name the image whose patient, study and modality the
files copy (`sourceSOPInstanceUID`), continue a series written before
(`seriesInstanceUID`, `firstInstanceNumber`), and give a series number, a
window and the geometry of each image.

Each of these calls has a synchronous form of the same name, for code on the
main actor that cannot wait (`try database.importFiles(at: files)`), and the
rest of the database is synchronous, on the main actor, as viewers are:

- `selection()` (the studies and the series selected in the database window),
  `studies(matching:)` with an `IsiXStudyQuery` (identifiers, patient name,
  description, modality, comment, dates, state, limit), `series(withInstanceUID:)`,
  `images(inSeries:)` and `images(withSOPInstanceUID:)`: `IsiXDatabaseImage`
  gives an image's attributes and its file, which the plugin reads and never
  changes; `albums()` and `studies(inAlbum:)`; `openViewer(forSeries:)` opens a
  series in a new 2D viewer (`database.read`).
- `updateStudy(_:_:)`, `updateSeries(_:_:)`, `updateImage(_:frame:_:)`
  (`database.write`) change the comment fields, the state (an index of
  `IsiXDatabase.stateNames`), the report (a web address or the path of a file)
  and the lock of a study, and the key image flag. The application checks the
  values, sets them as the user's edits set them, and saves; a value it does not
  accept throws `IsiXPluginError.invalidValue` and changes nothing.
- `createAlbum(named:)`, `addStudies(_:toAlbum:)`, `removeStudies(_:fromAlbum:)`
  (`database.write`): a smart album keeps the studies its rule selects, and
  changing them throws `invalidValue`; an unknown study throws `notFound` and
  nothing is added.

## Network

`context.network()` (with `network.send` or `network.query`) gives the DICOM
nodes the user configured in Locations, as `IsiXDICOMNode` copies, and works
only with them: a plugin names a node by its `id` (`AETITLE@host:port`), never
by an address, and a node that is not configured, is turned off, or does not
have Send (for `send`) or Query/Retrieve (for `find`) on throws
`IsiXPluginError.nodeNotConfigured`. A node Bonjour found or a DICOMweb node is
not one of them. The application opens the association itself, with the
node's transfer syntax and TLS settings, as it does for its own sends and
queries.

- `nodes()`: the nodes the plugin may use.
- `send(_:to:)`: an `IsiXSendRequest` of studies, series and images of the
  database (by UID) and DICOM files the plugin wrote; returns an
  `IsiXSendResult` (files sent, failed, and why). A send that cannot start
  throws `networkFailure`.
- `find(_:on:)`: an `IsiXNetworkQuery` at the `.study` or `.series` level
  (Study Root) or `.worklist` (Modality Worklist); each `IsiXQueryMatch` gives
  the attributes the node answered by DICOM keyword, the worklist's scheduled
  step attributes from its first step.

The forms without `async` wait for the node on the calling thread and may be
called from any thread; on the main actor use the `async` forms.

## XML-RPC

`context.registerXMLRPCMethod(named:handler:)` (with `xmlrpc`) answers a method
of the plugin's own through the application's XML-RPC interface, with its
access settings. The handler runs on the main actor with the call's parameters
as `IsiXXMLRPCValue`s and returns the answer; throwing answers the caller with
a fault. The application's own method names, and a name another plugin
registered, throw `invalidValue`. The methods go away with the plugin.

## The SDK

The SDK is `IsiXPluginKit.framework` with its Swift module interfaces
(`.swiftinterface`) for `arm64` and `x86_64`, the binary to link against, and
`SDK.json` with the API version, the kit version, the source revision, the
architectures and the compiler; `binarySHA256` and `interfaceSHA256` give
the SHA-256 of the binary and of each module interface, to check a copy of the
SDK against the one published. It does not contain the application's private
interface. Build it from the application's source with

    tools/export-isix-plugin-kit.py --xcode Release --output <folder>

The copy of the framework inside the application cannot be exported: Xcode
leaves its module interfaces out when it embeds it. `--framework` takes the
framework Xcode built, in `build/Build/Products/<configuration>`.

Point the plugin at the SDK: `FRAMEWORK_SEARCH_PATHS = <folder>`, link
`IsiXPluginKit.framework` with "Do Not Embed". Command line:

    swiftc -module-name MyPlugin -parse-as-library -target arm64-apple-macos15.0 \
        -F <folder> -framework IsiXPluginKit -Xlinker -bundle \
        -o MyPlugin.isixplugin/Contents/MacOS/MyPlugin Sources/*.swift

`Examples/IsiXPluginExample` in the application's source is a complete
plugin; `tools/build-isix-example-plugin.py --sdk <folder> --output <folder>`
builds it.

## Libraries of your own

The application links ITK, VTK and DCMTK statically; they are not part of the
API, and their versions change with the application. A plugin that needs ITK,
DCMTK, VTK, GSL or another C or C++ library carries its own copy, linked
statically into its executable, and keeps it apart from the application's,
which is loaded in the same process:

- **Export no symbol from the plugin**: link with an empty exported symbols
  list (`EXPORTED_SYMBOLS_FILE` naming a file without symbols, or
  `-Xlinker -exported_symbols_list -Xlinker <file>`). The application finds
  the entry class through the Objective-C runtime, not by symbol. The
  application exports the C++ templates and inline functions of its own
  libraries as weak definitions; if the plugin exported its copies too, macOS
  would bind the plugin's calls to the application's code when it loads the
  plugin.
- **Compile with hidden visibility**: `-fvisibility=hidden
  -fvisibility-inlines-hidden` for the library and for the plugin's own C++
  (`GCC_SYMBOLS_PRIVATE_EXTERN = YES`, `GCC_INLINES_ARE_PRIVATE_EXTERN = YES`);
  for ITK also `ITK_TEMPLATE_VISIBILITY_DEFAULT=OFF`.
- **Keep the two-level namespace**: never `-flat_namespace` or `-undefined
  dynamic_lookup`.
- **Build the library static** (`BUILD_SHARED_LIBS=OFF`), for macOS 15.0 and
  the plugin's architectures, and wrap it in Objective-C++ or C++ files behind
  a C or Objective-C interface that the plugin's Swift calls through a
  bridging header.
- Objective-C classes share one namespace in the process: a library with
  Objective-C classes must not reuse class names of the application or of
  other plugins.

The plugin template has this recipe: `script/build-library.py` builds ITK,
DCMTK or any CMake project that way (one archive, every symbol hidden, nothing
taken from a package manager), `Config/Exports.exp` and
`Config/MyIsiXPlugin.xcconfig` set the symbol settings for every plugin, and
`Config/Libraries.xcconfig.example` adds a library to the build. Only what the
plugin uses is linked: with ITK 5.4 (a 24 MB archive for `arm64`), a Release
`arm64` plugin that runs a region growing on a 3D image is 716 KB, against
196 KB without ITK. With DCMTK (`dcmdata` and what it needs,
with the data dictionary built in), the same plugin is 6.2 MB.

Command line, with ITK installed in `<itk>` by that script:

    clang++ -c -std=c++17 -fvisibility=hidden -fvisibility-inlines-hidden \
        -target arm64-apple-macos15.0 -isystem <itk>/include -o Wrapper.o Wrapper.cpp
    swiftc -module-name MyPlugin -parse-as-library -target arm64-apple-macos15.0 \
        -F <folder> -framework IsiXPluginKit -import-objc-header Wrapper.h \
        -Xlinker -bundle -Xlinker -exported_symbols_list -Xlinker Exports.exp \
        -o MyPlugin.isixplugin/Contents/MacOS/MyPlugin Sources/*.swift Wrapper.o \
        -L <itk>/lib -lITK -lz -lc++

## Compatibility

The kit is built with library evolution (`BUILD_LIBRARY_FOR_DISTRIBUTION`).
Within API version 1, later kits only add: a plugin built against an earlier
version 1 SDK keeps loading and running, without recompiling, in later
applications that support version 1. The framework's compatibility version
stays 1. Enumerations may gain cases: handle `@unknown default`. An
incompatible change would be a new API version, which the application
declares and checks before loading anything.

## Installing

Copy the bundle into the application's plugins folder for the current user,
`~/Library/Application Support/IsiX/Plugins/`, or for all users,
`/Library/Application Support/IsiX/Plugins/`, and restart the application. The
Plugins window lists each plugin with its state and, when it was refused, the
reason. The application distributed through the Mac App Store does not load
plugins.

## License

IsiXPluginKit is distributed under the GNU Lesser General Public License,
version 3. © 2026 Thales Matheus M Santos (ThalesMMS).

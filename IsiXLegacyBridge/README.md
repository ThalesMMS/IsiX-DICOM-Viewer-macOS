# IsiXLegacyBridge

IsiXLegacyBridge is the porting kit for plugins written for Horos or OsiriX.
It gives their source the classes it was written against — `PluginFilter`,
`ViewerController`, `DCMView`, `DCMPix`, `ROI` and `MyPoint`, and for the
database `BrowserController`, `DicomDatabase`, `DicomStudy`, `DicomSeries`,
`DicomImage`, `DicomAlbum`, `DICOMExport` and the `DCMObject` family, and for the
network `DCMNetServiceDelegate`, `SendController`, `DCMTKStoreSCU`, the query
nodes, `N2XMLRPC` and the legacy notifications — rebuilt on the
IsiX plugin API, version 1 ([IsiXPluginKit](../IsiXPluginKit/README.md)). The
kit is compiled into the plugin: a ported plugin is an ordinary `.isixplugin`
of API 1, which reaches the application through IsiXPluginKit only, and the
application knows nothing of the kit.

The converter, `tools/port-legacy-plugin.py`, does the port: it turns the
plugin's folder into a project of API 1 whose Info.plist has the keys of the
API, whose build settings point at the kit's headers instead of the copy of
the former SDK the plugin carried, and whose sources have the calls macOS
deprecated rewritten mechanically, the originals kept beside them. The rest of
the source compiles as it is.

## How it fits together

- **Names.** The legacy source keeps its class names. Each kit class is
  declared as `IsiXLegacy<Name>` and given the legacy name with
  `@compatibility_alias` (`@compatibility_alias ViewerController
  IsiXLegacyViewerController;`). In the Objective-C runtime each class is
  named after the plugin, `IsiXLegacy<Module>_<Name>`, from the build setting
  `ISIX_LEGACY_NAMESPACE`: the application's own `ViewerController`, `DCMPix`
  and `ROI` and another ported plugin's copy of the kit never share a name with
  them. The kit's Swift is compiled into the plugin's module, so its classes
  are the plugin's too.
- **Entry point.** `IsiXLegacyPluginEntry` (Swift) is the bundle's principal
  class. It reads the legacy filter class, type and menu titles from the
  Info.plist, creates the filter, calls `-initPlugin` and `-setMenus`, and
  registers one command per menu title. Running a command calls
  `-prepareFilter:` with the frontmost viewer and `-filterImage:` with the
  title; a result other than 0 is shown to the user as an error, and so is
  the first call into the application that failed while the command ran.
- **Pixels.** `-[DCMPix fImage]` points to a copy of the image that the plugin
  owns, read on first use: one Float32 sample per pixel in modality units, or
  ARGB bytes for colour images, every image of a phase one after the other in
  one buffer (`-[ViewerController volumePtr]`). `-[ViewerController
  needsDisplayUpdate]`, and the end of each command, commit the images whose
  pixels changed; a commit changes the viewer's image in memory, never the
  files. Each command reads the images again, so it sees the pixels as they
  are.
- **ROIs.** `-roiList` gives the legacy lists, one mutable array per image. A
  ROI the plugin creates joins the viewer when it is added to a list and the
  viewer is updated (or the command ends); a ROI taken out of its list is
  removed; a ROI read from the viewer stands for the application's ROI, and
  its setters, `-rotate::` and `-roiMove:` change it at once. The same ROI is
  the same object from one read to the next. Points have pixel centres at half
  coordinates, as the application keeps them. A plugin that works from a
  window of its own, outside a command, and announces a ROI it added with the
  `roiChange` notification, as the legacy application expected, has it in the
  viewer on the next turn of the run loop; `-[DCMView roiSet]` gives the
  lists to the viewer at once. A brush ROI made with `-initWithTexture:...`
  joins the viewer from its mask; its colour is kept but not shown.
- **Database.** `DicomStudy`, `DicomSeries`, `DicomImage` and `DicomAlbum`
  are plain objects over the database records of the plugin API: they answer
  the legacy attribute names by key-value coding (`name`, `patientID`,
  `studyInstanceUID`, `modality`, `series`, `images`, `completePath`...), and
  the same record is the same object from one read to the next. A plugin
  changes only what the user can edit in the application (comments, state,
  report, lock, key image); any other key is refused, and so is a value the
  application would not take, with the reason shown as the command's error and
  the database left as it was. `-[DicomDatabase managedObjectContext]` is a
  context of the kit: its fetch requests and predicates over `Study`,
  `Series`, `Image` and `Album` are evaluated on the records the plugin API
  returns, never on the application's Core Data objects. Files the plugin
  imports are copied in by the application; `DICOMExport` and
  `-[DCMObject writeToFile:...]` write into a folder of the kit, and the series
  is written into the study by the plugin API.
- **Lookups by name.** The kit's prefix header turns `NSClassFromString()`,
  `objc_getClass()` and `objc_lookUpClass()` in the plugin's Objective-C into
  the kit's own lookup: a legacy name the kit has gives the kit's class, the
  plugin's own classes and the system's are found as before, and a class of
  the application gives nil, with a message in the log, never the
  application's class. The kit's objects answer `performSelector:`,
  `objc_msgSend()` and key-value coding with the methods and properties the
  kit declares; a selector or a key the kit has no equivalent for gives nil
  (zero), with a message in the log, instead of an exception (the database
  objects keep their own answer to a key, above). A plugin that
  patched the application's classes with the Objective-C runtime (toolbar
  items, mostly) patches the kit's, which has no effect on the application.
- **Events of the viewers.** The notifications of `Notifications.h` reach the
  plugin with the kit's objects: a click on a viewer's image (`mouseDown`,
  with `X` and `Y` on the image and `stopMouseDown` to keep the viewer from
  the click), the viewer closing (`CloseViewerNotification`), another image
  shown (`DCMUpdateCurrentImage`), a ROI added, changed, selected or removed
  (`addROI`, `roiChange`, `roiSelected`, `removeROI`), by the user or by the
  plugin. A filter that answers `-handleEvent:forViewer:` gets the left
  button's down, drag and up and the keys of the viewers' images, before the
  viewer. They come from the plugin API's events and its input handlers
  (`IsiXPluginContext.interceptInput`); nothing is asked of the application
  until the plugin observes such a name or answers that method. A ROI event is
  delivered on the next turn of the run loop, once the change is complete; a
  click and a closing viewer at once.
- **The plugin's notification center.** The application posts notifications
  of the same names with its own viewers and ROIs. In the files that import
  the kit, `NSNotificationCenter` is the kit's center
  (`IsiXLegacyNotificationCenter.h`): the names of `Notifications.h` are
  observed and posted there, where only the kit posts them, and every other
  name goes to the default center as before. So each event arrives once, with
  objects the plugin can compare with its `viewerController`.
- **Drawing over the image.** A plugin that drew with OpenGL in the
  `PLUGINdrawObjects` notification draws with Core Graphics in the same
  notification: `userInfo[@"context"]` is a `CGContextRef` over the viewer's
  image in its pixels (the centre of the first pixel at (0.5, 0.5), y down
  the rows, as ROI points), with `pointSize`, the length of one point of the
  screen in pixels. It comes from an overlay of the plugin API
  (`IsiXViewer.addOverlay`), added to each viewer once the plugin observes the
  notification. There is no OpenGL context.
- **Windows of the plugin's own.** `DCMView` is an `NSView`. The one
  `[viewerController imageView]` gives stands for the viewer's pane; one the
  plugin makes (`-initWithFrame:imageRows:imageColumns:`, or a custom view of
  class `DCMView` in its nib) shows the images it is given
  (`-setPixels:files:rois:firstImage:level:reset:`), with a window level,
  flips and its ROIs' outlines, drawn with Core Graphics; a subclass draws
  over them in `-subDrawRect:` and takes the mouse as any view. In a nib, an
  object or view of a class of the kit (`DCMView`, `ViewerController`...) is
  made of the plugin's own copy: the build names the class by its runtime name.
- **Threads.** Calls from another thread are carried to the main thread, as
  the plugin API requires.
- **Memory.** The kit's Objective-C is compiled with ARC; the plugin's keeps
  its own setting, manual reference counting or ARC. `-newROI:`, `-newPoint::`
  and `-newWindow:::` return objects the caller does not own, as the legacy
  application did, whatever ARC infers from their names.

## Converting a plugin

From the application's source:

```sh
tools/port-legacy-plugin.py --source <legacy plugin folder> --output <folder> [--sdk <SDK folder>]
```

The legacy folder is only read. The converter reads the plugin's Xcode
project, when it has one, for the target that builds the plugin: the files it
compiled (each with its manual reference counting or ARC, as the project set
it) and copied, its prefix header, its Info.plist and its frameworks. It
writes `<folder>/<Module>`:

| In the project | What it is |
| --- | --- |
| `<Module>.xcodeproj`, `Config/<Module>.xcconfig` | One bundle target, `.isixplugin`, macOS 15, arm64 and x86_64 (Release; Debug builds the Mac's own), IsiXPluginKit linked from `ISIX_SDK_DIR` (`Config/SDK.xcconfig`, by default the project's `SDK` folder; `--sdk` writes `Config/SDK.local.xcconfig`), the settings of step 3 below |
| `Config/Info.plist` | The plugin's Info.plist with the keys of API 1 (step 1); the capabilities add `database.read`, `database.write` and `database.import` as the source reads, edits and imports into the database (step 1) |
| `Config/Prefix.pch` | The kit's prefix header (`IsiXLegacyPrefix.h`), then the plugin's own |
| `Config/port.json` | The same build, for `tools/build-isix-legacy-plugin.py --project`, which builds without Xcode |
| `Sources/` | The plugin's own files, without its copy of the former SDK and its build products, rewritten |
| `IsiXLegacyBridge/` | The copy of the kit the project builds with; none with `--shared-kit` (below) |
| `Porting/original/`, `Porting/rewrites.diff` | Each file as it was before a rewrite, and every change |
| `Porting/REPORT.md`, `Porting/report.json` | Each rewrite, the settings replaced, and what has no automatic equivalent, with its file and line |

Several converted plugins can share one copy of the kit: with
`--shared-kit <path>`, the kit's folder relative to the project (for example
`../IsiXLegacyBridge`, a copy of this folder's `Headers`, `Include`, `Sources`
and `README.md` next to the projects), the converter copies nothing and the
header search, the Xcode project's kit group, `Config/port.json` (its kit
sources and its `kit` key) and the report's pointer to this guide all use that
path. Each plugin still compiles the kit's sources into its own bundle, with
its own module name in the kit's runtime class names, so plugins on one copy
load side by side.

Then build it in Xcode, or with
`xcodebuild -project <Module>.xcodeproj -configuration Release ISIX_SDK_DIR=<SDK folder>`,
or, from the application's source, with
`tools/build-isix-legacy-plugin.py --sdk <SDK folder> --project <folder>/<Module> --output <folder>`.
`tools/build-isix-legacy-plugin.py --source` converts and builds in one step. Like Xcode, it fails on
an error in ibtool's report (ibtool may exit with 0 after one) and when a nib the project lists is not
in the bundle, and leaves no bundle then.

The converter also declares `network.send`, `network.query` and `xmlrpc` as
the source sends, queries or answers XML-RPC calls, and lists under
`IsiXLegacyXMLRPCMethods` the method names the source compares an XML-RPC
call's name with.

The rewrites change only calls in one exact legacy form, in code (never in
strings or comments), keep the line numbers, and keep the legacy behaviour:
the same return values, the same delegate callback with the same arguments.

| Legacy call | Rewritten as |
| --- | --- |
| `NSRunAlertPanel()`, `NSRunCriticalAlertPanel()`, `NSRunInformationalAlertPanel()`, `NSAlertDefaultReturn`... | `IsiXLegacyRunAlertPanel()`... and `IsiXLegacyAlertDefaultReturn`...: an `NSAlert` that returns the legacy codes |
| `NSBeginAlertSheet()` and its forms | `IsiXLegacyBeginAlertSheet()`...: the alert as a sheet, then `didEndSelector` and `didDismissSelector` |
| `+[NSAlert alertWithMessageText:defaultButton:alternateButton:otherButton:informativeTextWithFormat:]` | `IsiXLegacyAlertWithMessageText()`: buttons that return the legacy codes |
| `-[NSAlert beginSheetModalForWindow:modalDelegate:didEndSelector:contextInfo:]` | `IsiXLegacyAlertBeginSheet()`: `-beginSheetModalForWindow:completionHandler:`, then the delegate |
| `-[NSApplication beginSheet:modalForWindow:modalDelegate:didEndSelector:contextInfo:]` | `IsiXLegacyBeginSheet()`: `-[NSWindow beginSheet:completionHandler:]`; `-[NSApplication endSheet:returnCode:]` still ends it |
| `-beginSheetForDirectory:file:(types:)modalForWindow:...`, `-runModalForDirectory:file:(types:)`, `-runModalForTypes:`, `-setRequiredFileType:`, `-filenames`, `NSOKButton`... | `IsiXLegacyPanelBeginSheet()`, `IsiXLegacyPanelRunModal()`, `IsiXLegacyPanelSetRequiredFileType()`, `IsiXLegacyPanelFilenames()`, `NSModalResponseOK`... |
| `+[NSBundle loadNibNamed:owner:]` | `IsiXLegacyLoadNibNamed()`: the top-level objects retained for the owner, as before |
| `NSCalendarDate`, `-[NSDate dateWithCalendarFormat:timeZone:]`, `-descriptionWithCalendarFormat:timeZone:locale:` | `IsiXLegacyCalendarDate` (on `NSCalendar`, with the legacy `%` formats) |
| `-removeFileAtPath:handler:`, `-copyPath:toPath:handler:`, `-movePath:toPath:handler:`, `-createDirectoryAtPath:attributes:`, `-directoryContentsAtPath:`, `-fileAttributesAtPath:traverseLink:`, `+[NSString stringWithContentsOfFile:]` | Their `...Item...:error:` and `...error:` forms, when the handler is nil and the arguments allow |
| `objc_collectingEnabled()`, `objc_collect()`, `[NSGarbageCollector defaultCollector]`, `NSMakeCollectable()` (manual reference counting), `GCC_ENABLE_OBJC_GC` | What they amount to without the collector: `NO`, nothing, nil, the object itself; the setting is dropped |
| Former SDK, `ppc`/`i386`, `-undefined dynamic_lookup`, `libstdc++` | The project's settings |
| A xib set to build for a system before macOS 15 (`IBDocument.SystemTarget` and the Cocoa plugin's dependency in the IB 3 archive format, the `<deployment version>` of the document format); ibtool refuses one before 10.6 | The plugin's system (macOS 15); the document format's version is dropped, so it follows the project |

What the converter does not rewrite stays as it was and is listed in the
report: a call in another form (a handler that is not nil, a receiver that is
not the expected class), `-finalize`, Carbon, a framework the macOS SDK no
longer has (QuickTime and QTKit are out of the port), a library the plugin
carries (bring it as described in [Libraries of the plugin](#libraries-of-the-plugin-itk-dcmtk)),
a target or build phase besides the plugin's. `--collection <folder>
--report <file>` converts every plugin of a collection such as horosplugins
into one report (with `--output`, also the projects), which the compatibility
matrix of the application's source reads for the converter's stage.

## Porting a plugin, step by step

The converter does steps 1 to 3; they are what a port by hand would do.

1. **Info.plist.** Rename the former keys, which the application refuses:
   `pluginType` → `IsiXLegacyPluginType`, `MenuTitles` →
   `IsiXLegacyMenuTitles`, the old `NSPrincipalClass` → `IsiXLegacyFilterClass`.
   Remove `ToolbarNames`, `FileFormats`, `HorosCompatiblePlugin` and
   `Requirements`. Set `NSPrincipalClass` to
   `$(PRODUCT_MODULE_NAME).IsiXLegacyPluginEntry`, `IsiXPluginAPIVersion` to 1,
   `IsiXPluginCapabilities` to `viewer.read`, `viewer.write` and `roi`, with
   `database.read` when the plugin uses the database classes,
   `database.write` when it changes a study, series, image or album, and
   `database.import` when it imports files or writes DICOM; and give the
   bundle a `CFBundleIdentifier`, a `CFBundleName` and a
   `CFBundleShortVersionString`. When the old principal class names no class of
   the plugin, as in some legacy plugins, the plugin's only subclass of
   `PluginFilter` is used.
2. **Sources.** Leave the plugin's copy of the former SDK (`OsiriX Headers`,
   `OsiriXAPI.framework`, `Horos.framework`...) out of the target and of the
   header search, and add the kit: `IsiXLegacyBridge/Sources/*.swift` and
   `IsiXLegacyBridge/Sources/*.m`.
3. **Build settings.**

   | Setting | Value |
   | --- | --- |
   | `HEADER_SEARCH_PATHS` | `IsiXLegacyBridge/Headers`, `IsiXLegacyBridge/Include` (for `<OsiriXAPI/…>`, `<Horos/…>`, `<HorosAPI/…>`, `<OsiriX Headers/…>`) |
   | `USE_HEADERMAP` | `NO`, so that the old headers of the project are not found first |
   | `GCC_PREPROCESSOR_DEFINITIONS` | `ISIX_LEGACY_NAMESPACE=$(PRODUCT_MODULE_NAME)` |
   | `SWIFT_OBJC_INTERFACE_HEADER_NAME` | `IsiXLegacyBridge-Swift.h` |
   | `SWIFT_VERSION` | 5 |
   | Compiler flags of the kit's `.m` files | `-fobjc-arc` (the plugin's own files keep their setting) |
   | `MACOSX_DEPLOYMENT_TARGET` | 15.0 |
   | `EXPORTED_SYMBOLS_FILE` | a file listing `_OBJC_CLASS_$_*` and `_OBJC_METACLASS_$_*`: the plugin exports its Objective-C classes, which the kit looks up in the plugin's own image, and nothing else (see [Libraries of the plugin](#libraries-of-the-plugin-itk-dcmtk)) |
   | `GCC_INLINES_ARE_PRIVATE_EXTERN` | `YES` |
   | `WARNING_CFLAGS` | `-Wno-error=int-conversion`, `-Wno-error=implicit-function-declaration`, `-Wno-error=incompatible-pointer-types`, `-Wno-error=implicit-int`, `-Wno-error=incompatible-function-pointer-types`: what current compilers refuse and the legacy ones reported as warnings |
   | `ARCHS` | `arm64` (and `x86_64` for the Intel package) |
   | `WRAPPER_EXTENSION` | `isixplugin` |
   | Frameworks | `IsiXPluginKit.framework` from the SDK, linked, not embedded; `CoreData` for the kit's context; the system frameworks the plugin used |

   The bundle must be signed, ad hoc at least.
4. **Build and install** as any plugin of API 1 (see IsiXPluginKit). From the
   application's source, `tools/build-isix-legacy-plugin.py --sdk <SDK>
   --source <plugin folder> --output <folder>` converts the plugin and builds
   it without Xcode.
5. **A library the plugin used** (ITK, DCMTK, VTK, GSL): see
   [Libraries of the plugin](#libraries-of-the-plugin-itk-dcmtk).
6. **What the compiler still reports** is what the kit does not cover: a
   method of the former SDK the kit does not declare is a warning ("instance
   method not found") with manual reference counting and an error with ARC.
   Sent to one of the kit's objects, such a call gives nil (zero) at run time
   and writes "-[ViewerController <selector>] has no equivalent in the
   porting kit" to the log; rewrite it on IsiXPluginKit or leave the feature
   out.

## Libraries of the plugin (ITK, DCMTK)

The application's own ITK, VTK and DCMTK are not available to plugins. A
ported plugin that used one brings its own copy, built static with every
symbol hidden by the plugin template's `script/build-library.py` (see
IsiXPluginKit, "Libraries of your own"), and links it:

    tools/build-isix-legacy-plugin.py --sdk <SDK> --source <plugin folder> --output <folder> \
        --library <folder where build-library.py installed ITK> [--define NAME=VALUE ...]

`--library` adds the library's headers as system headers and its archive to
the link; the copy of the library's headers that the legacy plugin kept in
its folder (`ITK180`, `VTKHeaders`...) is left out, as the former SDK is. The
plugin exports its Objective-C classes only, so the application's copy of a
C++ template or inline function never replaces the plugin's.

Plugins written for ITK 3 compile against ITK 5 with these changes, all made
by the build:

| ITK 3 | Built as |
| --- | --- |
| `Filter::Pointer f = 0L;` | `= nullptr`, in a copy of the source (ITK 5 finds the integer ambiguous) |
| `ITK_TEMPLATE_TXX`, which made a header include its template code | defined to 1 |
| `#define id Id` around ITK's headers, against Objective-C's `id` | `Id` defined as `id`, so the definition does nothing: ITK 5 compiles in Objective-C++ as it is, and the standard library's own `id` keeps its name |
| `vnl_math_abs`, `vnl_math_sqr`... | `vnl_math::abs`, `vnl_math::sqr`... |
| `vcl_sqrt`, `vcl_vector`... | `std::sqrt`, `std::vector`... |
| C++98 narrowing in constant initialisers | accepted (`-Wno-c++11-narrowing`) |

A plugin that renamed ITK's namespace in its own copy maps it back with
`--define`, as NMSegmentation's `#define ITKNS nmITK` does with
`--define nmITK=itk`. Other changes of ITK's API between versions are the
port's to make in the source.

## Legacy call → equivalent

| Legacy | In the kit | Plugin API 1 underneath |
| --- | --- | --- |
| `PluginFilter` subclass, `pluginType`, `MenuTitles` | `IsiXLegacyPluginEntry` registers one command per title | `IsiXCommand`, placement by type: `imageFilter` and `fusionFilter` → `.imageFilters`, `roiTool` → `.roiTools`, `Database` → `.database`, other → `.other`; viewer types require a viewer |
| `-filterImage:`, `-prepareFilter:`, ivar `viewerController` | called for each run, with the frontmost viewer | `IsiXCommandInvocation.viewer` |
| `-initPlugin`, `-setMenus`, `-willUnload` | at activation, and before quitting | `IsiXPlugin.activate(with:)`, `deactivate()` |
| `-viewerControllersList`, `+[ViewerController getDisplayed2DViewers]`, `get2DViewers`, `frontMostDisplayed2DViewer` | the open 2D viewers, frontmost first | `IsiXPluginContext.openViewers()`, `frontmostViewer()` |
| `-pixList`, `-pixList:`, `-[DCMView dcmPixList]`, `-curDCM` | one `DCMPix` per image of the phase | `IsiXViewer.geometry(slice:phase:)`, `attributes(slice:phase:)` |
| `-[DCMPix fImage]`, `-volumePtr`, `-volumePtr:`, `-isRGB`, `-getPixelValueX:Y:` | the plugin's copy of the pixels | `IsiXViewer.image(slice:phase:)` |
| `-needsDisplayUpdate` | commits the changed images, pushes the ROI lists, redraws | `IsiXViewer.commit(_:replacing:)`, `setNeedsDisplay()` |
| `-[DCMPix setfImage:]`, `copy`, `setTot:`, `setFrameNo:`, `setID:` | images of a new series | — |
| `-newWindow:::` | a new viewer on images copied from this one with the plugin's pixels | `IsiXViewer.openDerivedSeries(_:)` |
| `-duplicateCurrent2DViewerWindow` | a new viewer with a copy of the phase shown | `IsiXViewer.openDerivedSeries(_:)` |
| `pwidth`, `pheight`, `pixelSpacingX/Y`, `pixelRatio`, `originX/Y/Z`, `origin:`, `orientation:`, `orientationDouble:`, `sliceLocation`, `sliceThickness`, `sliceInterval`, `slope`, `offset`, `echotime`, `repetitiontime`, `modalityString`, `SUVConverted` | from the geometry and the attributes | `IsiXImageGeometry`, `IsiXImageAttributes` |
| `-convertPixX:pixY:toDICOMCoords:` (`pixelCenter:`), `+originCorrectedAccordingToOrientation:` | pixel centres at half coordinates by default | `IsiXImageGeometry.patientPoint(of:)` |
| `-[DCMView curImage]`, `setIndex:`, `-setImageIndex:`, `-getNumberOfImages`, `-maxMovieIndex`, `-curMovieIndex` | image and phase shown | `IsiXViewer.currentPosition()`, `setCurrentSlice(_:)`, `series()` |
| `-[DCMView getWLWW::]`, `setWLWW::`, `-curWL`, `-curWW`, `-setWL:WW:`, `-[DCMPix ww]`, `wl`, `changeWLWW::` | the viewer's window level | `IsiXViewer.windowLevel()`, `setWindowLevel(_:)` |
| `-fullww`, `-fullwl` | from the image's pixels | — |
| `-roiList`, `-roiList:`, `-[DCMView dcmRoiList]`, `curRoiList` | the legacy lists, synchronised | `IsiXViewer.rois(slice:phase:)`, `addROI(_:)`, `removeROI(_:)`, `updateROI(_:_:)` |
| `-newROI:`, `-[ROI initWithType:::]`, `-newPoint::`, adding to a list | a ROI that joins the viewer when the lists are pushed | `IsiXViewer.addROI(_:)` (point, line, rectangle, oval, polygon, polyline) |
| `-deleteROI:`, `-deleteSeriesROIwithName:`, removing from a list | removed from the viewer | `IsiXViewer.removeROI(_:)` |
| `-[ROI setName:]`, `comments`, `ROImode`/`setROIMode:`, `displayTextualData`, `-selectROI:deselectingOther:`, `-deselectAllROIs`, `-renameSeriesROIwithName:newName:` | changed at once | `IsiXViewer.updateROI(_:_:)`: `name`, `comment`, `isSelected`, `showsTextBox` |
| `-[ROI points]`, `setPoints:`, `addPoint:`, `setPoint:atIndex:`, `pointAtIndex:`, `rect`/`setROIRect:`, `-roiMove:`, `-rotate::` | changed at once; a rotated rectangle or oval becomes a polygon | `IsiXViewer.updateROI(_:_:)`: `points`, `kind` |
| `-[ROI type]`, `name`, `centroid`, `MesureLength:`, `Length::`, `LengthFrom:to:inPixel:`, `roiArea`, `valid` | computed in the kit as the application does (lengths in cm, areas in cm²) | — |
| `-[ROI initWithTexture:textWidth:textHeight:textName:positionX:positionY:spacingX:spacingY:imageOrigin:]`, `-reduceTextureIfPossible`, `textureWidth`/`Height`/`Buffer`, `textureUpLeftCornerX`/`Y` | a brush ROI from the plugin's mask, which the kit keeps a copy of; cropped as the application does | `IsiXViewer.addROI(_:)` with `IsiXROIDraft(mask:)` |
| `-[ROI setColor:]`, `rgbcolor`, `sliceThickness` | kept, not shown | — |
| `-[DCMView roiSet]`, the `roiChange` notification of a ROI added to a list | the lists given to the viewer: at once, or on the next turn of the run loop | `IsiXViewer.addROI(_:)`, `updateROI(_:_:)`, `removeROI(_:)` |
| `-[DCMView ConvertFromGL2GL:toView:]` | through the patient coordinates of both images | `IsiXImageGeometry` |
| `-blendingController`, `-blendedWindow` | nil: no viewer is blended (fusion is not part of the kit) | — |
| `-[ROI mean]`, `min`, `max`, `-[DCMPix computeROI::::::]` | the application's statistics | `IsiXViewer.statistics(of:)`, `statistics(of:slice:phase:)` |
| `-fileList`, `-fileList:` | the `DicomImage` of each image; a dictionary (`slice`, `phase`, `sopInstanceUID`) when the database has no record of it | `IsiXDatabase.images(withSOPInstanceUID:)` |
| `+[BrowserController currentBrowser]`, `-database`, `-managedObjectContext`, `-databaseSelection`, `-filesForDatabaseOutlineSelection:` | the browser's selection, as studies and series | `IsiXDatabase.selection()` |
| `-[DicomDatabase managedObjectContext]`, `NSFetchRequest` + `NSPredicate` on `Study`, `Series`, `Image`, `Album`, `-executeFetchRequest:error:`, `-countForFetchRequest:error:`, `-objectsForEntity:predicate:` | evaluated on the records, with sort descriptors, offset and limit | `IsiXDatabase.studies(matching:)`, `series(inStudy:)`, `images(inSeries:)` |
| `DicomStudy`/`DicomSeries`/`DicomImage` attributes by name (`valueForKey:`, properties), `-series`, `-images`, `-study`, `-imageSeries`, `-keyImages`, `-completePath`, `+dicomImagesInObjects:` | read from the records | `IsiXStudy`, `IsiXSeries`, `IsiXDatabaseImage` |
| `setComment:` (`comment`…`comment4`), `setStateText:`, `setReportURL:`, `setLockedStudy:`, `-[DicomImage setIsKeyImage:]` | written at once; other keys and invalid values refused | `IsiXDatabase.updateStudy(_:_:)`, `updateSeries(_:_:)`, `updateImage(_:_:)` |
| `-albums`, `-[DicomDatabase newAlbumWithName:]`, `-[DicomAlbum addStudiesObject:]`, `removeStudiesObject:`, `-studies` | albums; a smart album cannot be changed | `IsiXDatabase.albums()`, `createAlbum(named:)`, `addStudies(_:toAlbum:)`, `removeStudies(_:fromAlbum:)` |
| `-addFilesAtPaths:…`, `+[BrowserController addFiles:toContext:…]`, `-addFilesToDatabase:…`, `-addFilesAndFolderToDatabase:`, `-getNewFileDatabasePath:` | copied into the database; folders expanded | `IsiXDatabase.importFiles(at:)` |
| `DICOMExport` (`setSourceFile:`, `setPixelData:…`, `setSlope:`, `setSigned:`, `setModalityAsSource:`, `writeDCMFile:`), `+[DCMObject secondaryCaptureObjectWithBitDepth:…]`, `-[DCMObject writeToFile:…]`, `DCMAttribute`, `DCMAttributeTag`, `DCMCalendarDate`, `DCMPixelDataAttribute` | a derived series of the source's study; float pixels as signed 16-bit with a slope | `IsiXDatabase.writeDerivedSeries(_:)` |
| `-[ViewerController exportDICOMFileInt:withName:allViewers:]` (`0`, the image in memory), `-adjustSlider` | the image shown, written as `DICOMExport` writes, one derived series per name; `@{@"file": path}` for `addFiles:`; a capture of the viewer as drawn (`1`, `2`, all viewers) gives nil | `IsiXDatabase.writeDerivedSeries(_:)` |
| `-[DCMObject objectWithContentsOfFile:…]`, `-attributeValueWithName:`, `-attributeWithName:` | the file read by the kit (explicit and implicit little endian; sequences skipped) | — |
| `-[DCMPix sourceFile]`, `srcFile`, `imageObj`, `seriesObj`, `-[ViewerController currentStudy]`, `currentSeries` | the image's records | `IsiXDatabase.images(withSOPInstanceUID:)`, `series(withInstanceUID:)` |
| `-[BrowserController loadSeries:…]`, `-findAndSelectFile:…`, `-newViewerDICOM:` | a viewer on the series | `IsiXDatabase.openViewer(forSeries:)` |
| `-startWaitWindow:`, `-endWaitWindow:`, `-waitIncrementBy::` | accepted, nothing shown | — |
| `-window` | the viewer's window while a command runs on it, for sheets | `IsiXCommandInvocation.parentWindow` |
| `OsirixAddToDBNotification`, `OsirixAddToDBCompleteNotification` (`...ImagesArray`, `...ImagesPerAETDictionary`) | posted in the plugin's center with the kit's `DicomImage` objects, once the plugin observes them | `IsiXEvent.imagesAdded` (`database.read`) |
| `OsirixXMLRPCMessageNotification` | posted in the plugin's center for the methods listed under `IsiXLegacyXMLRPCMethods` (the converter lists the names the source compares the method name with); `Response`, `NSXMLDocumentResponse` or `Processed` answer | `registerXMLRPCMethod(named:handler:)` (`xmlrpc`) |
| `N2XMLRPC` (`ParseElement:`, `FormatElement:`, `requestWithMethodName:arguments:`, `responseWithValue:`) | in the kit | — |
| `+[DCMNetServiceDelegate DICOMServersList]`, `DICOMServersListSendOnly:QROnly:` | the configured nodes, under the keys of Locations | `IsiXNetwork.nodes()` |
| `+[SendController sendFiles:toNode:]`, `sendFiles:toNode:usingSyntax:`, `sendFiles:` | in the background; `sendFiles:` asks which configured node | `IsiXNetwork.send(_:to:)` (`network.send`) |
| `DCMTKStoreSCU` (`initWithCallingAET:calledAET:hostname:port:filesToSend:...`, `-run:`) | waits for the node; raises as it did when the address is not a configured node or files were not sent | `IsiXNetwork.send(_:to:)` |
| `DCMTKRootQueryNode`, `DCMTKStudyQueryNode`, `DCMTKSeriesQueryNode` (`queryNodeWithDataset:...`, `-queryWithValues:`, `-children`, attributes) | studies, then the series of a study; `dataset` must be NULL | `IsiXNetwork.find(_:on:)` (`network.query`) |
| `NSClassFromString()`, `objc_getClass()`, `objc_lookUpClass()` | the kit's class for a legacy name it has; nil and a message for a class of the application | — |
| `performSelector:`, `objc_msgSend()`, `valueForKey:`, `valueForKeyPath:`, `setValue:forKey:` on the kit's objects | the kit's methods and properties; nil and a message for a selector or key without an equivalent | — |
| `-setMovieIndex:` | the phase shown, in a 4D series | `IsiXViewer.setCurrentPhase(_:)` |
| `mouseDown` notification (`X`, `Y`, `stopMouseDown`), `-[PluginFilter handleEvent:forViewer:]` | the clicks, drags and keys of the viewers' images, before the viewer; taken when the plugin says so | `IsiXPluginContext.interceptInput(_:_:)` |
| `CloseViewerNotification`, `DCMUpdateCurrentImage`, `addROI`, `roiChange`, `roiSelected`, `removeROI` | posted in the plugin's center with the kit's ViewerController, DCMView and ROI | `IsiXEvent` `.viewerWillClose`, `.sliceChanged`, `.roiChanged` |
| `PLUGINdrawObjects` (`OsirixDrawObjectsNotification`), drawn with OpenGL | drawn with Core Graphics in `userInfo[@"context"]`, in the image's pixels | `IsiXViewer.addOverlay(_:)` |
| `updateView`, posted by the plugin | redraws the viewers, with what the plugin changed | `IsiXViewer.setNeedsDisplay()` |
| `DCMView` in the plugin's own windows and nibs: `-initWithFrame:imageRows:imageColumns:`, `-setPixels:files:rois:firstImage:level:reset:`, `setDCM::::::`, `xFlipped`/`yFlipped`, `-ConvertFromNSView2GL:`, `-ConvertFromGL2NSView:`, `-nsimage`, `-subDrawRect:`, `-selectAll:` | an `NSView` drawing the images it is given with Core Graphics | — |
| `-[DCMPix getROIValue:::]` | the values of the pixels inside the ROI, from the plugin's copy | — |
| `-[ROI splinePoints]` | the outline smoothed by the application's cubic spline (polygons and pencil strokes of three points or more, while the viewer's `splineForROI` preference is on, its default); the points otherwise | — |

Not part of the kit: the views of the database window (`databaseOutline`,
`oMatrix`, `matrixViewArray`), deleting from the database, the application's
compression, anonymisation and DICOMDIR, the ROIs the application keeps per
image in the database (`roiForImage:inArray:`), `N2ManagedDatabase` beyond
the context above, OpenGL (drawing in an OpenGL context of the application or
of the plugin), the viewer's toolbars, zoom and panning (`origin`,
`scaleValue`), the right and other mouse buttons, fusion and other viewers (2D
only; no viewer is blended), synchronisation of viewers, the application's
other notifications (among them those of the viewer's contextual menu and of
drag operations), retrieving from a node (`move:`) and the image level of the
query nodes, and the libraries the application linked (ITK, VTK, DCMTK; a
plugin brings its own, above). ROI colours and layers are not either, nor
reading back a brush ROI's mask.

## License

IsiXLegacyBridge is distributed under the GNU Lesser General Public License,
version 3, as IsiXPluginKit is. Its headers keep the interfaces of the former
plugin SDK of Horos and OsiriX, with their notices: © the OsiriX Team and the
Horos Project, LGPL. The rest is © 2026 Thales Matheus M Santos (ThalesMMS).
A ported plugin keeps its own license and notices.

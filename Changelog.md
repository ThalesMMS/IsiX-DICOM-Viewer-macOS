# Release Notes

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).


## Unreleased

### Changed

- The application is named IsiX DICOM Viewer and has its own icon and bundle identifier, `thalesmms.isis.workstation`. On first launch it copies the preferences of an installation made as Horos, and opens that installation's database where it is.
- Objects the application writes carry IsiX DICOM Viewer as manufacturer; a new installation takes the computer's name as its AE title, or `ISIX` when the computer has none. An AE title already saved is kept.
- The About window describes the fork and shows its licenses; the Partners tab and the bundled Horos Cloud installer are gone. Help, support and bug report commands open this fork's page and issue tracker.

### Added

- DICOMweb nodes have their own list in Locations, "DICOMweb Nodes for DICOM Query/Retrieve and DICOM Send": address, separate WADO and QIDO paths, name, Q&R, retrieve transfer syntax, authentication (none, username and password, a header and API key, or a bearer token, kept in the Keychain), Send and send transfer syntax, with a Test button that tells network, TLS, timeout, rejected credentials and a wrong path apart. Nodes with Q&R appear in the Query/Retrieve window; nodes with Send appear in Send to and receive the images by STOW-RS, transcoded first when another transfer syntax is chosen, with a result per instance.
- The DICOMweb client is built on DICOM-Swift's (Apache 2.0), included with its license and listed in the notices.

### Changed

- The DICOM nodes' Retrieve pop-up no longer offers DICOMweb. Nodes set to it move to the DICOMweb list at the first launch, with their credential, and leave `SERVERS`, so plugins and DIMSE code never see an entry without an AE title.
- `HorosContentBounds.h`, `HorosFileCopy.h`, `HorosPluginInstall.h`, `HorosPluginLoadDiagnostics.h`, `HorosPluginSignature.h` and `HorosRasterSeriesFolder.h` define their functions `static inline`, so a plugin that includes `<Horos/Horos.h>` no longer compiles a copy of each.
- The 2D viewer, MPR, curved MPR, volume rendering, surface rendering, endoscopy and ROI volumes draw with Metal only. The application no longer links OpenGL, and VTK is built without its OpenGL rendering modules.
- `VRView`, `SRView` and `ROIVolumeView` are no longer `VTKView` subclasses; `SRView` and `ROIVolumeView` derive from `HorosSceneView`, `VRView` from `NSView`. Their `renderer`, `renderWindow` and `getVTKRenderWindow` still return VTK's objects, which hold the scene; VTK no longer draws it. `cocoaWindow` and `setVTKRenderWindow` are gone, and so is `VRView`'s `getInteractor`; `HorosSceneView`'s returns a `HorosVRInteractor`, not a `vtkCocoaRenderWindowInteractor`.
- `OSIROI`: `-drawSlab:inCGLContext:pixelFormat:dicomToPixTransform:` is now `-drawSlab:dicomToPixTransform:` and draws on the view's `HorosROICanvas`. A subclass that still implements the former selector is called through it, with the OpenGL arguments `NULL`.

- `DICOMTLS.h`: `TLS_SEED_FILE`, `TLS_WRITE_SEED_FILE`, `TLS_PRIVATE_KEY_FILE`, `TLS_CERTIFICATE_FILE` and `TLS_TRUSTED_CERTIFICATES_DIR` name files in a folder of the user's temporary folder (`+[DICOMTLS temporaryFolder]`), not in `/tmp`; `TLS_WRITE_SEED_FILE` is `+[DICOMTLS writeSeedFilePath]` and `+[DICOMTLS seedFilePath]` gives `TLS_SEED_FILE` as a C string. The DICOM listener's process files, the web portal's uploads, archives and structured report pages moved out of `/tmp` too.

### Fixed

- DICOM print objects written without DCMTK carry the Secondary Capture class and a UID of their own, a correct file meta group length, and rows and columns in pixels; the color conversion no longer reads past the bitmap of an image below 72 dpi.
- `OSIROIMask`, `OSIROIFloatPixelData` and `CPRVolumeData`: `-initWithSortedIndexes:` and `-initWithSortedIndexData:` build their runs from the indexes given, without reading past them; `-convexHull` has the right maximum depth; `-volumeDataForSliceAtIndex:` translates the slice by its depth and returns nil past the volume; `-getFloatRun:…` accepts a run that ends at the last column and refuses one that leaves the volume; `-getFloatData:floatCount:` copies at most `floatCount` floats; `-linearInterpolateVolumeVectors:…` interpolates the vectors given, with the out-of-bounds value outside the volume.
- Anonymization writes a date given for a DT tag as a DICOM date-time with its UTC offset, not as the date's description, and TM without a fraction; it reads and writes files in folders whose names are not Latin. The field of an SL tag accepts negative values.
- Reading a DICOMDIR no longer hangs, for this and every later read, when its helper does not start, and no longer loses files whose names are not ASCII.
- The MIP and MinIP of a colour series' thick slab take every slice into account, not the current and last ones only, and fill every pixel.
- A colour MPR drawn without Metal shows the mean of its slab in mean mode, not its MinIP.
- An email sent through Mail keeps all its recipients; a recipient list with an empty entry no longer hangs the application; an email sent over SMTP carries the sender that was chosen, and no longer fails when the notification sender is empty.
- Undo in the MPR and curved MPR keeps the frame of a 4D series; Endoscopy's Fly Assistant rotates by the angle it asks for.
- Fly Assistant scans its whole ±45° grid around the forward direction; it only covered a 30° corner beside it.
- A DICOM node entered in the preferences and the same node announced by Bonjour are one row that keeps the entered settings; nodes are compared without a DNS lookup.
- `invoke XMLRPC method` from AppleScript with parameters that are not a record gives a script error instead of ending the application; an empty list calls the method with no parameters.
- Email over SMTP no longer stalls when the server greets before both connections are open.
- The orthogonal PET-CT viewer's rows keep the height of the window and the columns of each other; they stayed at their initial size or collapsed.
- Fly Assistant traces every ray from the centerline point, in the resampled volume, one voxel a step, on axes at right angles; the direction it returns is in the viewer's coordinates.
- AppleScript records whose keys are AppleScript words (`name`, `id`, `path`, `URL`) reach `invoke XMLRPC method` under those names; `SelectAlbum` with `{name: "Today"}` works.
- Copying images from a shared Horos database to a DICOM node sends them to the node's own address, port and AE title; it sent them to no address unless the node was written as `AET@host`.
- Shaded volume rendering in Metal is lit like VTK's ray cast: no ambient term from the headlight, two-sided lighting, one-sided gradients at the volume's faces. It came out about 20 % brighter.
- A whole-study DICOMweb retrieve no longer holds the whole response in memory while it splits it into files.
- A DICOMweb query or retrieve that times out or is cancelled no longer leaves a `CFNetworkDownload_*.tmp` file in the temporary folder.
- The MPR of a colour volume reslices its three channels in one GPU submission, about 0.4 ms less per plane in Release; the curved MPR's operations no longer convert their sets and key paths on every request, about 7 % faster in Release.

### Security

- ROIs read from DICOM SR files, .roi and .rois files, the ROI pasteboard, the CLUT editor's pasted curves and colours, and saved curved-MPR paths no longer instantiate arbitrary classes: the old archives are checked for their class names before any object is decoded, and curved paths use secure coding. A ROI subclass defined by a plugin is no longer read back from an SR.
- The destination info a database-sharing peer sends before a copy is read without instantiating the classes it names; any class but a dictionary of strings is refused. It was read with `NSUnarchiver`, so whoever answered on the port chose the classes.
- A record parameter of an Apple Event no longer unarchives arbitrary classes: `'ObjC'` data is decoded with secure coding and only property-list classes, and anything else is refused.
- Nothing the application writes goes to a fixed or predictable name in `/tmp`, which every user of the machine can write to: DICOM SR pages, burn folders, anonymized burns, print jobs, plugin downloads, WADO recompression, 3D print folders, the unzip working folder and the privileged helper's error pipe use the user's temporary folder.
- The web portal's generated passwords draw from `arc4random`. They drew from `random()` seeded with the time of day, so a password could be found again from when it was made.

### Removed

- The choice between Metal and the original renderers: the `HorosMPRMetal` preference, the volume rendering engine setting (`MAPPERMODEVR`), the Engine toolbar items of the 3D viewers and their options in Settings → 3D. Earlier values of these preferences are ignored.
- The Compare in Metal item of the 2D viewer's contextual menu, Compare in Metal (3D) of the 3D viewer's, and the windows they opened. The viewers draw with Metal themselves, so these windows compared Metal with Metal and sent the user to an original viewer that no longer exists. `HorosPlanarComparison`, `HorosVolumeComparison`, the `HorosPlanarSource` and `HorosVolumeSource` protocols, `-[ViewerController openPlanarMetalComparison:]` and `-[VRController openVolumeMetalComparison:]` are gone with them.
- `VTKView`, `GLString`, `StringTexture`, the `NSFont (OpenGL)` category and `OpenGLScreenReader`.
- `ROI`: `-deleteTexture:` and `-loadLayerImageTexture`, deprecated since ROIs stopped keeping OpenGL textures.
- `ROICanvasGL.h` is no longer part of the plugin headers; draw on `HorosROICanvas`, which `Horos-Swift.h` declares.
- `HorosHTMLPrint.h` is no longer part of the plugin headers. It belongs to the Decompress helper, which alone implements it, and it compiled `HorosHTMLPrintSession`, `HorosPrintHTMLToPDF` and `HorosUpdateHTMLReportPDF` into every plugin that included `<Horos/Horos.h>`, a second copy of the class beside the helper's.
- OpenGL.framework from the application's link.
- The `NSNotificationCenter (AllObservers)` category: `-my_addObserver:selector:name:object:`, `-my_removeObserver:name:object:`, `-my_postNotificationName:object:userInfo:`, `-my_postNotification:`, `-my_observersForNotificationName:` and `-postExtraNotification:`. Nothing ever exchanged them with the notification center's own methods; `Horos-Swift.h` has declared them since the category moved to Swift. The plugin crash guards of `PluginManager` (`+startProtectForCrashWithFilter:`, `+startProtectForCrashWithPath:`, `+endProtectForCrash`) remain.

## 4.0.0 RC5 2022-08-01

### Added

- Support for Apple silicon (M1, M2) Macs

### Changed

- Updated ThirdParty components (e.g. DCMTK, OpenSSL, VTK, ITK)
- Improved rendering performance in 2D view
- Fixed rendering issue with StudyBox in 2D view
- Fixed rendering of tool selection popup button
- Fixed toolbar height & shadow

### Removed

- Removed support for 3Dconnexion input devices
- Removed Horos homephone

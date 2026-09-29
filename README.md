# Horos for Apple Silicon

This is an independently developed and maintained fork of the Horos DICOM
viewer by **Thales Matheus M Santos (ThalesMMS)**. It builds on
[Horos by the Horos Project](https://github.com/horosproject/horos), itself
derived from OsiriX, and incorporates selected modernizations adapted from
[Yves Starreveld's work in ystarrev/horos](https://github.com/ystarrev/horos).
Original authorship, copyright notices, and third-party licenses are preserved.

The fork targets **macOS 26 or later on Apple Silicon only**. Its main changes
are an extensive migration to Swift, Metal rendering throughout the viewers,
updated DICOM and networking components, new viewing and study-management
tools, and fixes to image processing, data handling, performance, and the
macOS interface. Objective-C, Objective-C++, C, and C++ remain where required
by the existing application and its dependencies.

[Download the latest release](https://github.com/ThalesMMS/horos/releases/latest)
or browse the [complete release notes](https://github.com/ThalesMMS/horos/releases).
The overview below reflects the releases through **29 September 2026**.

## Download and requirements

- An Apple Silicon Mac, with an `arm64` processor, running macOS 26 or later.
  Intel Macs and earlier macOS versions are outside this fork's support scope.
- Published application ZIPs are signed with Developer ID and notarized by
  Apple. Their runtime libraries are bundled; Homebrew is not needed to run
  the distributed application. That packaging is a separate release procedure,
  recorded in each release's `BUILD-INFO.txt`; the build scripts in this
  repository do not perform it yet (see *Build from source*).
- Each release includes `BUILD-INFO.txt` and `SHA256SUMS.txt` with the source
  revision, dependency and packaging details, validation scope, and checksum.
  Use the source tag and any accompanying patches when reproducing a release.

## Main changes in this fork

### Swift modernization

Large parts of the application now use Swift, including the application
controller, database models and browser workflows, metadata editor, preference
panes, network services, plugin management, and reporting and export helpers.
The migration also covers MPR, orthogonal MPR, PET-CT, endoscopy, and curved MPR
controllers and views. Swift extensions implement substantial parts of the 2D
viewer's ROI, fusion, printing, export, toolbar, and interaction workflows.

Compatibility headers, explicit Objective-C selectors, and C/Objective-C++
bridges connect migrated code to the remaining application and plugin SDK.
The migration is ongoing. Plugins that draw with OpenGL must adapt to the new
rendering interfaces; see the [notes for plugin authors](docs/plugin-author-notes.md).

### Metal rendering

Metal presents the 2D viewer, MPR, curved MPR/CPR, volume rendering, surface
rendering, endoscopy, and ROI volume views. The application no longer links
OpenGL, and its VTK build excludes OpenGL rendering modules. VTK still supplies
scene data and geometry. ROI graphics and text use Core Graphics and Core
Animation overlays.

The rendering work includes scalar and RGB images and volumes, image fusion,
MIP/MinIP/mean projections, thick slabs, convolution, shutters, crop planes,
surface transparency, and stereo presentation. MPR reslicing respects DICOM
patient geometry. Optional cubic interpolation is available for displaying
thin, non-fused MPR planes, while measurements and exports retain linear
interpolation.

Shared compute pipelines, reusable buffers and textures, cached transfer
functions, and fewer intermediate copies reduce repeated work. MPR and volume
rendering use Metal 4 compute submission on supported devices, with Metal 3
compute support retained.
Retina positioning, picking, clipping, volume shading, and pixel readback have
also been corrected. The old rendering-engine selectors and comparison
windows have been removed.

### Viewing, measurements, and study tools

- DICOM segmentation import, editing, and derived export, including binary
  segmentations and explicit thresholding of fractional data. Grayscale
  Softcopy Presentation State handling and ROI-to-image associations have
  also been revised.
- Two-click Length measurements between slices in DICOM patient coordinates,
  with persistence, undo/redo, and projected display across slices and slabs.
  [ROI JSON interchange](docs/roi-interchange-json.md) supports ordinary ROIs
  and patient-space Length endpoints.
- A shared patient-coordinate crosshair, linked-viewer synchronization,
  scroll-position previews, automatic content fitting when opening a series,
  reslice hotkeys, and Option-scroll control of thick-slab thickness. The 3D
  MPR toolbar adds series selection and synchronization with 2D viewers.
- T2 fitting, MRI motion correction, longitudinal registration, and
  patient-space centerline import for curved reconstructions.
- Persistent study notes with a dedicated editor, database display, search,
  and shared-database support.
- Album creation from an image of a patient list. Text recognition runs locally
  through Apple's Vision framework, and a review window lets the user verify
  patient matches before creating the album.
- Finder Quick Look previews and thumbnails for DICOM files, study metadata
  export to CSV, batch export by identifier list, and animated GIF export for
  registered comparisons.

### DICOM and network workflows

- Expanded handling of enhanced and legacy-converted CT, MR, and PET objects,
  multiframe geometry, 32-bit and floating-point pixels, palette color, VOI
  LUTs, character sets, and video objects. Fixes cover frame ordering,
  monochrome polarity, malformed sequences, and derived-image identifiers.
- DICOMweb nodes in **Settings > Locations**, integrated into Query/Retrieve
  through QIDO-RS and WADO-RS and into Send through STOW-RS. Basic, API key,
  and bearer-token authentication store secrets in the Keychain. Remote
  endpoints require HTTPS. Retrieval streams instances to staging files;
  sending supports transfer-syntax conversion and per-instance results.
- Revised DIMSE negotiation, TLS verification, timeouts, cancellation, and
  C-GET/C-MOVE completion tracking. Smart retrieval accounts for pending
  imports and instances a peer cannot send, while a forced retrieve can retry
  them. Network notices no longer block viewer interaction.
- A Network.framework listener for shared databases, with bounded workers,
  connection limits, cancellation, and validated requests. Fixes also cover
  Bonjour discovery, routing, send scheduling, and remote database clients.

See the [DICOMweb configuration and validation record](docs/dicomweb-nodes-validation.md)
for the implemented scope and interoperability limits.

### Reliability, performance, and macOS integration

The fork fixes database upgrade and recovery failures, album persistence,
premature imports from archive staging folders, report-to-study association,
and lost or misclassified non-image DICOM objects. It retains recoverable
indexes when replacement fails and uses the system Trash for file disposal.

Performance work reduces database refreshes and notification bursts during
imports, batches database writes, avoids loading all image identities for
routine report association, and removes disk access from report columns while
drawing the study list.
NIfTI loading reads the requested plane instead of retaining a full volume for
each frame. JPEG 2000 decoding uses the intended Release compiler optimization
and releases decoder resources on success and failure. Reconstruction windows
release their controllers and GPU resources when they close.

Other corrections cover ROI geometry and volumes, image arithmetic and buffer
bounds, fusion and crop state, curved-path editing, export ranges and failure
handling, DICOM printing, movie capture, Pages/Word reports, native RTF/RTFD to
PDF conversion, and Mail drafts. macOS interface updates address toolbar
customization, sliders, floating panels, full-screen behavior, keyboard focus,
and English, Spanish, Italian, and Japanese resources.

Security fixes include restricted archive decoding, shared-database path and
metadata validation, web-portal authorization, user-scoped temporary files,
and removal of patient names and identifiers from Query/Retrieve logs.

### Dependencies and build maintenance

The DCM compatibility framework now uses host-provided DCMTK services for
reading, writing, anonymization, and transfer-syntax conversion. The obsolete
DCMTK snapshot, Jasper sources, unused parser and codec implementations, and
unused build targets have been removed.

Current dependency work includes a pinned DCMTK 3.7.0+ development revision,
OpenSSL 3.5.8, corrected OpenJPEG 2.5.0 builds, and updated NIfTI-1 I/O 2.1.0
and znzlib 3.0.0 components. DICOM-Swift client sources provide DICOMweb
multipart and transfer support. ITK, VTK, and GDCM remain part of the imaging
stack, with build adjustments for the current Apple toolchain. CharLS is used
through DCMTK and GDCM rather than a separate build target.

Dependency revisions are recorded by Git and the build scripts. Vendored
components retain their provenance and license notices. Release assets record
the exact dependency revisions and any packaging patches.

## Build from source

Use an Apple Silicon Mac and Xcode with a macOS SDK that supports the product's
macOS 26 deployment target. The installed SDK version and the application's
minimum macOS version are separate requirements.

Local builds also need `cmake`, `pkg-config`, `git-lfs`, and the system PNG/TIFF
libraries used by the dependency scripts. With Homebrew:

```sh
brew install cmake pkg-config git-lfs libpng libtiff
```

An application built from source links the PNG and TIFF libraries, and their
dependencies, from the Homebrew prefix of the Mac that built it. Such a build
is not the self-contained bundle of the published ZIPs: it does not embed those
libraries and does not run on a Mac without them.

Clone the repository and its pinned submodules:

```sh
git clone --recurse-submodules https://github.com/ThalesMMS/horos.git
cd horos
```

For an existing checkout, initialize or update the submodules before building:

```sh
git submodule update --init --recursive
```

The current release also requires its `VTK-no-OpenGL-export.patch` to build
VTK's export module without OpenGL. The build scripts do not yet apply this
patch automatically. Download it from the
[29 September release](https://github.com/ThalesMMS/horos/releases/tag/v4.0.0-macos26-20260929),
verify its SHA-256 against that release's `BUILD-INFO.txt`, and apply it after
initializing the submodules:

```sh
git -C VTK apply --check /absolute/path/to/VTK-no-OpenGL-export.patch
git -C VTK apply /absolute/path/to/VTK-no-OpenGL-export.patch
```

Apply the patch only once to the matching VTK revision. Release build records
include this patch; they do not establish that an unpatched clean clone builds.

Build the `Horos` scheme in `Horos.xcodeproj`, or use:

```sh
make
make CONFIG=Release
```

The first build compiles the dependencies as well as the application. Some
bundled binaries are unpacked by the `Unzip Binaries` target.

### Local development

```sh
script/build_and_run.sh --verify
```

This builds Debug, prepares `build/Development/HorosDevelopment.app` with a
separate bundle identifier and ad-hoc signature, and launches it against the
isolated database in `local-validation/runtime-private`. It also isolates
plugins and web-portal accounts. The installed application and its database
are not used for this development launch.

For an optimized development build:

```sh
HOROS_DEV_CONFIGURATION=Release script/build_and_run.sh --verify
```

The script also accepts `--debug` for LLDB, `--logs` for unified logging, and
`--diagnostics` for the Main Thread Checker.

To prepare a local Release application without launching or installing it:

```sh
script/build_release.sh
```

The result is `build/Release/Horos.app`. The script preserves the previous
output, signs the app and its helpers ad hoc, and verifies the bundle. This
local build uses libraries installed on the build machine and is distinct
from the signed, notarized distribution available in Releases.

`Config.xcconfig` leaves `HOROS_DEVELOPMENT_TEAM` empty. For personal signing,
copy `Config.local.xcconfig.example` to the untracked `Config.local.xcconfig`
and set your own team there, or pass `HOROS_DEVELOPMENT_TEAM` to `xcodebuild`.

### Tests and validation records

Run the focused Python tests with:

```sh
python3 tools/run-tests.py
python3 tools/run-tests.py 'test-dicom-*.py' --verbose
```

Tests use Xcode's command-line tools. Some also require a compiled helper,
built application, synthetic fixture, or external plugin source. The runner
reports missing prerequisites as **skipped**, separately from failures.

The [validation records](docs/) describe specific builds, datasets, results,
and limits. Historical measurements, including the
[JPEG 2000 loading comparison](docs/openjpeg-performance-validation.md), apply
to their recorded workloads and revisions. Consult each release's
`BUILD-INFO.txt` for the checks performed on that distributed artifact.

## License and credits

Horos and the modifications in this fork are distributed under the
**GNU Lesser General Public License, version 3 (LGPLv3)**. See
[LICENSE](LICENSE), [COPYING.LESSER](COPYING.LESSER), and [NOTICE](NOTICE).

- The **Horos Project** created Horos from the original **OsiriX Team** work.
  Their copyright and license notices remain in the source and distribution.
- **Thales Matheus M Santos (ThalesMMS)** is the author of this fork's changes
  from commit `1a3d3236` onwards, except for the attributed adaptations listed
  in `NOTICE`. These changes were not made or endorsed by the Horos Project.
- **Yves Starreveld** is the author of the selected work adapted from
  [ystarrev/horos](https://github.com/ystarrev/horos). `NOTICE` identifies the
  adapted components and their source revisions; reused material retains its
  original attribution.
- The **Nimble Co LLC d/b/a Purview / HorosCloud** notice and other existing
  contributor credits are preserved.

Third-party components retain their own licenses. These include BSD-style
terms for DCMTK; Apache-2.0 for ITK, OpenSSL, and DICOM-Swift; BSD-3-Clause for
VTK, GDCM, and bundled CharLS; and BSD-2-Clause for OpenJPEG. This is not a
uniformly LGPL source tree. Consult `NOTICE`, each component's license, and
the [in-app license catalog](Binaries/Splash/licenses.html) for the applicable
notices.

Redistributions must preserve the applicable copyright and license notices
and provide the corresponding source required by the licenses. Horos is
distributed without warranty, as stated in `LICENSE`.

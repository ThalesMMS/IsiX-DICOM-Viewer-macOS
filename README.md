# Isis DICOM Viewer

Isis DICOM Viewer is an independently developed and maintained fork of the Horos DICOM
viewer by **Thales Matheus M Santos (ThalesMMS)**. It builds on
[Horos by the Horos Project](https://github.com/horosproject/horos), itself
derived from OsiriX, and incorporates selected modernizations adapted from
[Yves Starreveld's work in ystarrev/horos](https://github.com/ystarrev/horos).
Original authorship, copyright notices, and third-party licenses are preserved.

It was published as "Horos for Apple Silicon" until the name and icon changed:
Horos, HorosCloud and OsiriX are names and marks of their respective owners.
Isis DICOM Viewer is not made, sponsored or endorsed by the Horos Project,
Purview or Pixmeo, and its own name and icon are not covered by the LGPLv3
grant that covers the source code. Folders, classes and identifiers that still
say Horos or OsiriX are kept for compatibility with existing plugins, links
and data.

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
  the distributed application. Signing with Developer ID and notarization are a
  separate release procedure, recorded in each release's `BUILD-INFO.txt`; the
  build scripts in this repository embed the libraries but sign only ad hoc
  (see *Build from source*).
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
rendering interfaces in the application and plugin SDK.

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
  ROI JSON interchange supports ordinary ROIs
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
OpenSSL 3.5.9, corrected OpenJPEG 2.5.0 builds, and updated NIfTI-1 I/O 2.1.0
and znzlib 3.0.0 components. The public DICOM-Swift package provides DICOMweb
multipart and transfer support through its DicomWebClient and DicomData products. ITK and VTK remain part of the imaging
stack, with build adjustments for the current Apple toolchain. CharLS is used
through DCMTK rather than a separate build target.

Dependency revisions are recorded by Git and the build scripts. Vendored
components retain their provenance and license notices. Release assets record
the exact dependency revisions and any packaging patches.

## Build from source

Use an Apple Silicon Mac and Xcode with a macOS SDK that supports the product's
macOS 26 deployment target. The installed SDK version and the application's
minimum macOS version are separate requirements.

Local builds also need the build tools `cmake` (3.23 or later), `pkg-config`
(1.0 or later), Python 3, and the standard command-line tools supplied with
Xcode/macOS. OpenSSL preparation also uses Perl. With Homebrew:

```sh
brew install cmake pkg-config
```

The libraries the build takes from outside the repository (libtiff, libpng,
jpeg-turbo, and webp, zstd and xz, which libtiff links) are declared in
`Horos/Scripts/external-inputs.lock` with their version and SHA-256. On the
first build, `Horos/Scripts/external-inputs.sh` downloads those official
Homebrew bottles from `ghcr.io`, checks each digest, and stages them in the
build directory. It never uses the libraries of the Homebrew installed on the
Mac, and it stops the build if a file differs from the declaration. After that
first download the build works offline.

OpenJPEG 2.5.4 is acquired from its official upstream commit archive, declared
with its commit, SHA-256, layout and license in
`Horos/Scripts/external-sources.json`. It is extracted into the OpenJPEG target's
temporary `Source/source` directory; the original source is verified on reuse
and is never patched. The target installs `libopenjp2.a` and the public headers,
including the legacy `include/OpenJPEG` alias used by Horos and Decompress.

For offline builds, supply the exact declared archive in the directory selected
by `EXTERNAL_SOURCES_DOWNLOADS` (an absolute path), or in Xcode's
`$PROJECT_TEMP_DIR/ExternalSources.downloads` cache, and supply the bottles and
initialized submodules as above. Set `EXTERNAL_INPUTS_OFFLINE=1` to make a missing
or corrupt source archive fail immediately with its required filename and digest.
`EXTERNAL_SOURCES_MIRROR` can name an HTTPS or `file://` directory containing the
declared archive filenames; mirrors pass the same digest, layout and version
checks. They cannot substitute another release. Extracted files or installed
headers changed or removed locally are recovered from the verified cache.

To update OpenJPEG, change its declaration only after verifying the official
commit, archive SHA-256, version contract and untouched license digest; then
build both configurations and run the JPEG2000 codec and app checks. A changed
source digest at the same version or a changed build recipe invalidates the
configure and install caches. The consumed source record and license accompany
the app in `Contents/Resources/CompiledSources/OpenJPEG` and its release metadata.

VTK 9.7.1 is acquired from the official fixed release asset at
`https://vtk.org/files/release/9.7/VTK-9.7.1.tar.gz`, with its SHA-256, tag revision,
layout, version and untouched copyright pinned in `external-sources.json`.
Each configuration uses its own temporary `Source/source` directory. All source
files are read-only and verified before reusing a configure cache; compilation
outputs remain outside that tree. Offline archives and mirrors use the same
rules described above. No upstream source patches are applied, including to
MetaIO or documentation dependencies. Documentation is not built.
The consumed source record and original copyright accompany the app in
`Contents/Resources/CompiledSources/VTK`; update the declaration only after
checking the official asset, then validate both configurations and the app.

ITK 5.4.7 is acquired in the same way, from the official release asset
`InsightToolkit-5.4.7.tar.gz` of its GitHub release, pinned by SHA-256 and tag
revision in `external-sources.json`. It is extracted read-only for each
configuration and compiled with no source patch; diagnostics of its own code
are those of the upstream release. The consumed source record, license and
NOTICE accompany the app in `Contents/Resources/CompiledSources/ITK`.

VTK's FreeType source is checked against its original release archive.
Its installed static module retains the public `vtkfreetype_FT_MulFix` ABI through
a Mach-O symbol alias to the original function; the raw name is made local so
other FreeType providers cannot collide with it. The aggregate `libVTK.a` uses
this same adapted module. Arithmetic and upstream source remain unchanged.
The recipe, source identity and archive hashes accompany the app in
`Contents/Resources/CompiledSources/VTK/freetype-host-adaptation.json`.
Known upstream compiler diagnostics remain visible during this build.

The build copies the libraries the application loads into
`Contents/Frameworks`, with their licenses in `Contents/Resources/ExternalLibraries`,
so a built application no longer depends on its build directory or on
Homebrew and can be moved. It is signed ad hoc, which is not a Developer ID
signature: Gatekeeper on another Mac does not approve it.

Clone the repository and its pinned submodules:

```sh
git clone https://github.com/ThalesMMS/horos.git
cd horos
git submodule update --init -- DCMTK OpenSSL/upstream
```

For an existing checkout, initialize or update the submodules before building:

```sh
git submodule sync -- DCMTK OpenSSL/upstream
git submodule update --init -- DCMTK OpenSSL/upstream
```

The build initializes only these two production sources, without recursing
into OpenSSL's optional test dependencies. Existing optional checkouts are
left in place. OpenSSL reads its pinned source directly and writes generated
files into each configuration's separate build directory. Its external
cryptography tests are opt-in through `tools/test-openssl-cryptography.py`,
which acquires its own pinned test inputs.

The original acquired VTK release builds with the host recipe; the `VTK-no-OpenGL-export.patch` that
the 29 September release needed for VTK 8.2 no longer applies.

Build the `Horos` scheme in `Horos.xcodeproj`, or use:

```sh
make
make CONFIG=Release
```

The first build compiles the dependencies as well as the application. Some
bundled binaries are unpacked by the `Unzip Binaries` target.

### DICOMweb package resolution

`Horos.xcodeproj` requires the public
[DICOM-Swift package](https://github.com/ThalesMMS/DICOM-Swift) at exact version
`2.0.0-rc.1` (revision `95df9768de8c905e619e150d3fe887aff3935af2`). The app
links `DicomWebClient` and its `DicomData` dependency. Optional codecs, server,
UI and ZIP products are not linked. Resolver downloads of optional dependencies
do not imply that their code is part of the app.

The approved lock is
`Horos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Normal development and release scripts use `build/SourcePackages`, disable
automatic package updates, and require this lock. To deliberately update a pin,
change the project's exact version, resolve with the command below, review the
lock diff and public tag revision, then run the focused DICOMweb and release
packaging tests before committing both project and lock:

```sh
xcodebuild -resolvePackageDependencies -project Horos.xcodeproj -scheme Horos \
  -clonedSourcePackagesDirPath build/SourcePackages -derivedDataPath build
```

The existing DICOMweb drivers link the resolved module rather than compiling a
copy of the package sources. Prepare their disposable artifact cache from the
Debug products of an app build (or a verified public consumer of the same lock):

```sh
python3 tests/dicomweb_package.py --prepare \
  --products build/Build/Products/Debug --source-packages build/SourcePackages
python3 tools/run-tests.py 'test-dicomweb-*.py' --verbose
```

For local package edits, create an ignored `.xcworkspace` inside the checkout,
include `Horos.xcodeproj`, and add the local package override in Xcode. Pass its
relative path in `HOROS_DEV_WORKSPACE` to the development script. This explicitly
local flow uses `build/DevelopmentSourcePackages`. Keep the workspace and override
out of Git. Release builds use the canonical project and reject local package
references, workspace additions, altered checkouts and mismatched resolution.
The release script verifies the effective public revisions and bundled notice
hashes before signing, and records them in `BUILD-INFO.txt`.

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

From a clean clone, that command alone produces the self-contained package: it
builds the dependencies, downloads the pinned bottles once, and needs no file
from an earlier build. On the Apple Silicon Mac where this was checked, a clean
clone took about 11 minutes.

The result is `build/Release/Isis DICOM Viewer.app`. The script signs the app, its
libraries, frameworks, extensions and helpers ad hoc from the inside out, and
audits the bundle with `tools/audit-release-bundle.py --strict`: every binary
must be arm64 and signed and load only the macOS and the bundle itself. If the
build or the audit fails, the previous output is left in place; a replaced one
is kept as `Isis DICOM Viewer.previous-<date>.app`. This ad hoc, self-contained build is
distinct from the Developer ID signed, notarized distribution available in
Releases.

Beside the application the script writes `BUILD-INFO.txt`, which identifies the
artifact (commit and tree, toolchain and SDK, dependency versions, embedded
libraries, signature, audit and checksums), and `SHA256SUMS.txt`, which lists
every file of the bundle:

```sh
cd build/Release && shasum -a 256 -c SHA256SUMS.txt
python3 tools/audit-release-bundle.py "build/Release/Isis DICOM Viewer.app" --strict --notices
```

To go back to the previous artifact, move the current three files aside and
rename the `*.previous-<date>*` files of one date to `Isis DICOM Viewer.app`,
`BUILD-INFO.txt` and `SHA256SUMS.txt`.

Signing with a Developer ID certificate, notarizing with `notarytool` and
stapling the ticket need the maintainer's Apple credentials and are not done by
these scripts; they belong to a separate, authorized release step, as does
publishing.

`Config.xcconfig` leaves `HOROS_DEVELOPMENT_TEAM` empty. For personal signing,
copy `Config.local.xcconfig.example` to the untracked `Config.local.xcconfig`
and set your own team there, or pass `HOROS_DEVELOPMENT_TEAM` to `xcodebuild`.

### Tests

Run the focused Python tests with:

```sh
python3 tools/run-tests.py
python3 tools/run-tests.py 'test-dicom-*.py' --verbose
```

Tests use Xcode's command-line tools. Some also require a compiled helper,
built application, synthetic fixture, or external plugin source. The runner
reports missing prerequisites as **skipped**, separately from failures.

Internal audit reports and measurement records are not part of the public
source export. Consult each release's `BUILD-INFO.txt` for the checks performed
on that distributed artifact. Public license tests check distributed notices
directly; a missing required notice is a failure, not an optional fixture skip.

## License and credits

Horos and the modifications in this fork are distributed under the
**GNU Lesser General Public License, version 3 (LGPLv3)**. See
[LICENSE](LICENSE), [COPYING.LESSER](COPYING.LESSER), and [NOTICE](NOTICE).

- The **Horos Project** created Horos from the original **OsiriX Team** work.
  Their copyright and license notices remain in the source and distribution.
- **Thales Matheus M Santos (ThalesMMS)** maintains this fork. Its changes
  were not made or endorsed by the Horos Project.
- **Yves Starreveld** is the author of the selected work adapted from
  [ystarrev/horos](https://github.com/ystarrev/horos). `NOTICE` identifies the
  adapted components and their source revisions; reused material retains its
  original attribution.
- The **Nimble Co LLC d/b/a Purview / HorosCloud** notice and other existing
  contributor credits are preserved.

Third-party components retain their own licenses. These include BSD-style
terms for DCMTK; Apache-2.0 for ITK, OpenSSL, and DICOM-Swift; BSD-3-Clause for
VTK and bundled CharLS; and BSD-2-Clause for OpenJPEG. This is not a
uniformly LGPL source tree. Consult `NOTICE`, each component's license, and
the [in-app license catalog](Binaries/Splash/licenses.html) for the applicable
notices.

Redistributions must preserve the applicable copyright and license notices
and provide the corresponding source required by the licenses. Horos is
distributed without warranty, as stated in `LICENSE`.

### Reproducing the bundled DICOM validator

`Binaries/dciodvfy.lock.json` identifies the David Clunie source snapshot,
ImagingDataCommons build revision and arm64 artifact, their SHA-256 hashes,
and the exact helper shipped here. The existing helper is unchanged. Its
COPYRIGHT and clinical disclaimer travel in `Splash/ThirdParty/dicom3tools`;
the Python packaging license has separate terms.

The Unzip Binaries target runs `Horos/Scripts/Horos/stage-dciodvfy.py`, which
verifies the tracked ZIP and stages only the native validator. A clean clone
needs Python 3.9+ and the Xcode command line tools (`lipo` and `otool`); no
Python package installation is required. To reconstruct from the identified
upstream archives instead, run:

```sh
python3 Horos/Scripts/Horos/stage-dciodvfy.py --from-upstream --cache-dir build/dciodvfy-cache
```

Supply the two files named by `source.filename` and `artifact.filename` in
that cache and add `--offline` to reconstruct without network access. Both
archives, COPYRIGHT, snapshot, helper bytes, arm64 architecture and system
library dependencies are checked before the previous helper is replaced.
Downloads enter the cache only after their checksums pass. The recipe leaves
the tracked ZIP intact. The same manifest is copied into application Resources;
its helper hash identifies the acquired bytes before application signing.
Release `SHA256SUMS.txt` identifies the signed files.

The pinned build recipe in the manifest records how ImagingDataCommons built
the source (Xcode, imake, makedepend, gawk and XQuartz for the complete toolkit,
then `lipo -thin arm64`). The local recipe obtains those exact published bytes;
it does not claim a fresh compiler build is byte-identical across toolchains.

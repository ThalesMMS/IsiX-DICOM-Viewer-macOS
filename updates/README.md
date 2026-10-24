# Stable update channel

The application reads `https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases/latest/download/stable.plist` over HTTPS. Copies up to 5.2.1 read the same address under the repository's earlier name, `ThalesMMS/horos`, which GitHub redirects for as long as no other repository takes that name. GitHub redirects that address to the asset named `stable.plist` of the latest published release that is not a pre-release, so publishing a release with that asset is what announces it. Nothing in this folder has to be committed for a new release.

A release has two application zips, one per architecture: arm64 for Apple Silicon and x86_64 for the Intel Macs that run macOS 15 or later. Each holds a single slice. The plist is written from both final archives:

| Key | Meaning |
| --- | --- |
| `Horos` | The decimal `CFBundleVersion` of the released application, as a string. The only value the comparison uses. |
| `Version`, `ReleaseTag`, `ReleaseURL` | The marketing version and the release it belongs to. |
| `Architectures`, `MinimumSystemVersion` | The architectures the release has a zip for, and the macOS it needs. |
| `Archives` | One dictionary per architecture, `arm64` and `x86_64`, each with `Archive`, `ArchiveURL`, `ArchiveSize` and `ArchiveSHA256`: the zip asset, its address, its size in bytes and its SHA-256. `ArchiveURL` is written under `ThalesMMS/horos`: copies up to 5.2.1 accept only that prefix and are offered no download otherwise; later copies accept both names. |
| `Archive`, `ArchiveURL`, `ArchiveSize`, `ArchiveSHA256` | The arm64 zip again. Copies installed before there were two packages are all arm64 and read only these keys. |

## Build numbers

`script/build_release.sh` gives each release build its own number, `YYYYMMDDNN`: the local date and a two-digit sequence. `HOROS_RELEASE_SEQUENCE=1` makes the second release of a day; `HOROS_RELEASE_BUILD` replaces the whole number. Each release must carry a number larger than every release before it. A build made any other way keeps 20220801, which no release uses again, so a development copy never looks newer than a release.

## For each stable release

1. Run `script/build_release.sh` and `HOROS_RELEASE_ARCH=x86_64 script/build_release.sh` with the same `HOROS_RELEASE_SEQUENCE` (or `HOROS_RELEASE_BUILD`), so that both packages carry the same build number. They are written to `build/Release/arm64` and `build/Release/x86_64`. Sign each with the Developer ID, notarize, staple and zip it as before, with the architecture in the zip's name.
2. Prepare a new publication folder from the final application ZIPs, build reports and license/source archive. Use the tag the release will have and a destination that does not exist:

   ```sh
   python3 script/release-metadata.py --update-feed v5.2.7 \
       --release-assets build/github/v5.2.7 \
       --arm64-info build/Release/arm64/BUILD-INFO.txt \
       --intel-info build/Release/x86_64/BUILD-INFO.txt \
       --source-materials build/distribution/license-and-source-materials.zip . \
       build/distribution/IsiX-DICOM-Viewer-5.2.7-arm64.zip \
       build/distribution/IsiX-DICOM-Viewer-5.2.7-x86_64.zip
   ```

   The paths above are an example for the next release. Supply reports that describe the final signed and notarized artifacts. The script copies the application ZIPs with their existing filenames, publishes the reports and license/source archive under the names below, and generates `stable.plist` and `Verification.txt`. It leaves the inputs unchanged and refuses an existing destination. No upload occurs.

   It reads the architecture of each zip from the application inside, refuses two zips of one architecture, a universal application, a release without its arm64 zip, and zips whose build number, version, identifier or minimum macOS differ. A release without an Intel package needs only the arm64 ZIP and report; Intel copies then know of the release but are not offered a download. Without `--release-assets`, `--update-feed` retains its original behavior of writing only `stable.plist` beside the input ZIPs.
3. Verify the prepared publication files:

   ```sh
   cd build/github/v5.2.7
   shasum -a 256 -c Verification.txt
   ```

4. Publish the release with both application zips, the supporting assets and `stable.plist`, under that tag and not as a pre-release. The zips keep the names they had when the feed was written. Update both download buttons in `README.md` to the new release's tag and ZIP filenames. Keep all published asset names unchanged so existing download links continue to work.
5. From an installed older release, use Check for Updates.

## Supporting asset names

These publication names place both `IsiX-DICOM-Viewer-…zip` application downloads before the supporting assets in alphabetical order. They apply to releases after v5.2.6; existing releases keep their original names.

| File | Publication name |
| --- | --- |
| Final arm64 build report, generated locally as `BUILD-INFO.txt` | `Technical-Apple-Silicon.txt` |
| Final x86_64 build report, generated locally as `BUILD-INFO.txt` | `Technical-Intel.txt` |
| License and source materials archive | `Licenses-and-source.zip` |
| SHA-256 checksums of the published assets | `Verification.txt` |

`script/release-metadata.py --release-assets` defines these publication names. The local build outputs remain `BUILD-INFO.txt` and `SHA256SUMS.txt`. The updater reads `stable.plist` and verifies the application ZIP against its `ArchiveSize` and `ArchiveSHA256`. It does not fetch these supporting assets. Keep the feed's filename, schema and compatibility URLs unchanged.

## What the application does with it

A copy whose build number is lower is told about the release. The zip it may download is the one for the Mac's hardware (`hw.optional.arm64`), not for the running copy: an x86_64 copy opened under Rosetta on Apple Silicon is offered the arm64 zip, and an Intel Mac is offered the x86_64 zip and never the older top-level keys. When the copy is itself a notarized Developer ID release in a place it can replace (not a disk image, a read-only volume or an App Translocation path), it offers to download and install: the archive must be an asset of a release of this repository and have the size and SHA-256 of the feed; the application inside must have the same bundle identifier, the build number of the feed, and a valid notarized signature of the same Developer ID team as the running copy. Only then is the running copy moved aside and replaced, and the application reopened; the previous copy goes to the Trash. Any other copy, a development build included, is only shown the release page, and only when Check for Updates is chosen from the menu.

## `stable.plist` in this folder

Releases published before this channel read `https://raw.githubusercontent.com/ThalesMMS/horos/horos/updates/stable.plist`, compare only `Horos`, and send the user to the release list. Update that file once, with the build number of the first release that carries its own `stable.plist`, so that those copies learn of it; after that it no longer needs to change.

Only maintainers publish releases. API credentials and DICOM data are not needed for checks.

# Stable update channel

The application reads `https://github.com/ThalesMMS/horos/releases/latest/download/stable.plist` over HTTPS. GitHub redirects that address to the asset named `stable.plist` of the latest published release that is not a pre-release, so publishing a release with that asset is what announces it. Nothing in this folder has to be committed for a new release.

The plist is written from the final archive of the release:

| Key | Meaning |
| --- | --- |
| `Horos` | The decimal `CFBundleVersion` of the released application, as a string. The only value the comparison uses. |
| `Version`, `ReleaseTag`, `ReleaseURL` | The marketing version and the release it belongs to. |
| `Architectures`, `MinimumSystemVersion` | What the released application runs on. |
| `Archive`, `ArchiveURL`, `ArchiveSize`, `ArchiveSHA256` | The zip asset of that release, its size in bytes and its SHA-256. |

## Build numbers

`script/build_release.sh` gives each release build its own number, `YYYYMMDDNN`: the local date and a two-digit sequence. `HOROS_RELEASE_SEQUENCE=1` makes the second release of a day; `HOROS_RELEASE_BUILD` replaces the whole number. Each release must carry a number larger than every release before it. A build made any other way keeps 20220801, which no release uses again, so a development copy never looks newer than a release.

## For each stable release

1. Run `script/build_release.sh`, then sign with the Developer ID, notarize, staple and zip the application as before.
2. Write the feed from that final zip, with the tag the release will have:

   ```sh
   python3 script/release-metadata.py --update-feed v4.0.0-macos26-20261002 . Horos-4.0.0-macos26-arm64-20261002.zip
   ```

   It writes `stable.plist` beside the zip and prints the build number it read from the application inside.
3. Publish the release with the zip and `stable.plist` among its assets, under that tag and not as a pre-release. The zip keeps the name it had when the feed was written.
4. From an installed older release, use Check for Updates.

## What the application does with it

A copy whose build number is lower is told about the release. When the copy is itself a notarized Developer ID release in a place it can replace (not a disk image, a read-only volume or an App Translocation path), it offers to download and install: the archive must be an asset of a release of this repository and have the size and SHA-256 of the feed; the application inside must have the same bundle identifier, the build number of the feed, and a valid notarized signature of the same Developer ID team as the running copy. Only then is the running copy moved aside and replaced, and the application reopened; the previous copy goes to the Trash. Any other copy, a development build included, is only shown the release page, and only when Check for Updates is chosen from the menu.

## `stable.plist` in this folder

Releases published before this channel read `https://raw.githubusercontent.com/ThalesMMS/horos/horos/updates/stable.plist`, compare only `Horos`, and send the user to the release list. Update that file once, with the build number of the first release that carries its own `stable.plist`, so that those copies learn of it; after that it no longer needs to change.

Only maintainers publish releases. API credentials and DICOM data are not needed for checks.

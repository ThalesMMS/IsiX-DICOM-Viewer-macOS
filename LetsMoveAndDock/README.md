# Host installation policy

`PFMoveToApplicationsFolderIfNecessary` is the historical C entry point. Its
implementation now delegates to `HorosApplicationInstaller` in the host. The
bootstrap still calls it only in Release. The inherited Horos/OsiriX and Andy
Kim/Potion Factory public-domain notices remain in the bridge files; they do
not describe the authorship of the new Swift implementation. The Dock category
retains its Matt Brewer and inherited Horos/OsiriX notices.

LetsMove v1.25 at `70c5772c2ce84613ba539cb122e4065a9e33db5b` was inspected as a
candidate. Its public API exposes only the move entry point and progress flag,
not consent, Trash or relaunch hooks. Its relaunch clears quarantine; the Finder
Trash fallback interpolates an unescaped path. Therefore this implementation
uses a native host flow rather than shipping or claiming an intact v1.25
vendor. `UPSTREAM.json` identifies the candidate sources and their hashes.

The host retains the opt-out key `moveToApplicationsFolderAlertSuppress`, the
current consent wording, and preference for a populated user Applications
folder over local Applications. It stages and validates the bundle before
replacement, checks the destination's running state before and after copying,
and refuses destination symlinks. Data/database alias resolution stays in the
existing independent NSString category.

The copied application's executable, signing requirement and quarantine are
validated before replacement. Foundation may change quarantine flags while
copying; the host restores the source attribute rather than deleting it. The
privileged path uses AppleScript's administrator authorization and `ditto`,
then a rename transaction with rollback. Cancellation does not relaunch or add
to the Dock. The previous privileged destination is retained as a uniquely
named sibling backup if it cannot be moved to Trash. Failed unprivileged
replacement Trash stops installation. Failed source/staging Trash retains that
path. The original source is never deleted recursively; nested applications
and disk-image sources are preserved.

The relaunch helper waits for the current process to exit and submits `open`
with a quoted path; it never removes quarantine. A failed helper submission
keeps the source and does not write the Dock. Submission success is not proof
that LaunchServices later started the app; integrated functional validation
must confirm that launch. Disk-image detach is delayed and non-forcing. Dock
addition happens only after current consent, completed installation and
successful helper submission. Existing tiles are matched by exact file URL;
new tiles are property list objects. Failed Dock synchronization/restart is
reported as `dockAdded: false` without invalidating an installed bundle.

`tests/test-application-installation.py` compiles the actual Swift source and C
bridge, exercises policy failure/cancellation paths with injected operations,
and uses signed disposable bundles for copy, quarantine, signature and rename
checks. The exact privileged shell commands execute without elevation inside a
temporary directory, including rollback. Relaunch/open/detach use recording
command substitutes. Dock tile tests call only pure serialization/matching
functions. A generated read-only DMG exercises the production statfs/hdiutil
detection and detaches only its own device. `--trash-only`, reused by `test-feedback-runtime.py`, moves one
unique disposable file to Trash and removes only its own receipt. None of
these tests writes the actual Dock, launches an application or authenticates.
Administrator UI and the integrated app's LaunchServices behavior remain
functional validation scenarios.

# Feedback services selected by the host

The original provider remains in `../../FeedbackReporter`, pinned to commit
`92230feade69e1298cd5a8cbc0c8ddd2dc939934` from
<https://github.com/tcurdt/feedbackreporter>. Its 72 files, including the original
project and resources, are verified before each framework build. The build does
not update or patch that tree.

The public reporter delegate cannot replace the log provider or uploader. The
host therefore selects the existing modern implementations of `FRConsoleLog`,
`FRUploader`, `FRFeedbackController` and `FRCrashLogFinder` from this directory
instead of their original implementations. Each class is compiled exactly once. This retains the
public selectors, reporter bootstrap, crash discovery, UI, consent and preferences
without method replacement or runtime interposition. The Objective-C files are
relocated existing implementations; their translation is separate work.

`FRConsoleLog` queries only the current process's unified log. It cannot recover
console entries from the preceding process after a crash. Unavailable or denied
access returns an empty string. The existing newest-first selection, chronological
output and whole-line character budget are retained: the line that crosses the
budget is included. Crash files are discovered separately by the finder.

`FRCrashLogFinder` keeps the original search of the three `DiagnosticReports`
folders and its `<name>_*.crash` files, and adds the reports the system writes
today, `<name>-<date>.ips`. An `.ips` report is two JSON objects; its first line
names the process, so a report is taken only when it is a crash of this
application: the name, the bundle identifier when the report gives one, and the
crash bug type. The crash tab shows the readable lines of such a report first
(process, version, exception, the crashed thread) and the report as written after
them.

`FRFeedbackController` lays out the original window itself. The nibs, one per
localization, keep fixed frames and springs from an older system: hiding the
details shrank the tab view to no height and its pages were drawn over the
other rows, and longer translations were cut. When the nib loads, the controller
replaces those frames with constraints: the labels wrap within the window, the
window is wide enough for every tab, the details are hidden rather than shrunk,
and the window takes the height of the rows shown, keeping its top edge. The
email box offers "anonymous" and the address last used; the user's contact card
is no longer read, so the window never asks for Contacts access.

`FRUploader` retains URLSession, Unicode multipart bodies, synchronous `post:`,
main-queue async completion, response reset, reuse, cancel and actual transport
errors. The async POST byte limit remains configurable with the original key
and defaults to 100 MB. `FRFeedbackController` retains the current URL parsing and
error/retry flow, without the deprecated reachability preflight. No target URL,
account or credential is enabled by source selection.

The external framework project adds OSLog and a `BuildSource.json` resource. The
resource records the verified upstream revision/tree and the four selected host
source hashes; release metadata reads the record from the built framework.
The build removes only the obsolete deployment version from disposable XIB
copies. All other original resources and public headers remain selected.

The original Apache/BSD notices and source credits are preserved. This is an
original provider plus explicitly selected host adaptations, not a claim that the
resulting framework executes every upstream implementation unchanged.

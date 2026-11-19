#!/usr/bin/env python3
"""A series held in several multi-frame files counts, sorts and opens by its files.

The database keeps an image per frame. A series whose images are of several
multi-frame files, a volume each (an acquisition over time), is one row of the
database window; DicomSeries and the browser's ViewerOpener apply to it the
rules of the modules (IsiXDatabase's SeriesFiles, IsiXImaging's
SeriesSplitting.fileGroups), which have their own tests. This compiles, as
they are, with stand-ins for the model objects and the windows:

* DicomSeries' -rawNoFiles, -noFilesExcludingMultiFrames and -sortedImages
  (DicomSeries.swift): the number of files is the number of distinct files,
  and the images go file by file, the files by their time, whatever the
  preference of the order says, and so do some of them put back in order
  (what the sub-series sheet keeps); a series of single-frame files and a
  single multi-frame file count and sort as the sort descriptors alone do,
  for every value of the preference;
* the ViewerOpener's open(lists:movie:viewer:) (ViewerOpener.swift) and what a
  viewer's own lists and steps open a series with (ViewerOpener+Navigation.swift):
  such a series goes to the 4D player unasked, a file a time, up to the
  player's limit; above it, with files of different numbers of frames or
  with frames that share a slice location it opens as one stack, file by
  file; other series open as they did, and "Reparsed Series", Option and key
  images are not taken over;
* what -openViewerFromImages:… is sent (openChosenImages,
  ViewerOpener+Navigation.swift; the browser's method hands it the lists): one
  list that is every image of such a series opens as the database window opens
  it, which is how a retrieve shows its series, how the viewer reloads it
  while its files arrive and how a plugin handed the series opens it; some of
  its images, its key images, several lists and the lists of a movie open as
  they were asked;
* the two other places that put the images of a series in order: the plugin
  API's lists of images (sortedImages of IsiXDatabaseAdapter.swift), by
  instance number and frame, and the files a shared database fetches ahead of
  the one asked for (cacheData(for:maxFiles:) of RemoteDicomDatabase.swift),
  by the sort descriptors, go file by file for such a series and as before
  for any other.

    python3 tests/test-series-of-multi-frame-files.py
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402

root = Path(__file__).resolve().parents[1]
SERIES = 'Horos/Sources/DicomSeries.swift'
OPENER = 'Horos/Sources/ViewerOpener.swift'
NAVIGATION = 'Horos/Sources/ViewerOpener+Navigation.swift'
CHILDREN = 'Horos/Sources/DatabaseItemChildren.swift'
ADAPTER = 'Horos/Sources/IsiXDatabaseAdapter.swift'
REMOTE = 'Horos/Sources/RemoteDicomDatabase.swift'
BROWSER = 'Horos/Sources/BrowserController+ViewerOpening.swift'
RULES = [root / 'Modules/IsiXDatabase/Sources/SeriesFiles.swift',
         root / 'Modules/IsiXImaging/Sources/ViewerOpening/ViewerOpeningRules.swift']

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)


def read(path):
    return (root / path).read_text(encoding='utf-8')


def member(source, signature, path):
    """The declaration that starts with `signature`, up to its closing brace."""
    at = source.find(signature)
    if at < 0:
        sys.exit(f'FAIL: {signature.strip()!r} is no longer in {path}; this test needs a new look')
    depth, index = 0, source.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


series, opener, navigation = read(SERIES), read(OPENER), read(NAVIGATION)
series_members = '\n\n    '.join(member(series, signature, SERIES) for signature in (
    '@objc public func rawNoFiles() -> NSNumber! {',
    'private func fileCount() -> Int {',
    '@objc public func noFilesExcludingMultiFrames() -> NSNumber! {',
    '@objc public func sortDescriptorsForImages() -> [Any]! {',
    '@objc(sortedImages)\n    public func sortedImagesArray() -> NSArray! {',
    'static func fileByFile(_ sorted: [Any]?) -> [Any]? {'))
int_value = member(series, 'fileprivate func dicomSeriesIntValue(_ object: Any?) -> Int32 {', SERIES)
opener_members = '\n\n    '.join((
    member(opener, 'func open(lists toOpenArrayIn: [[Any]], movie movieViewerIn: Bool, viewer: ViewerController?) {', OPENER),
    member(navigation, 'func fileTimePoints(of images: [Any]) -> [[Any]]? {', NAVIGATION),
    member(navigation, 'private func openSeriesImages(', NAVIGATION),
    member(navigation, 'func openChosenImages(', NAVIGATION),
    member(navigation, 'private func isWholeSeries(', NAVIGATION)))
plugin_order = member(read(ADAPTER), 'private static func sortedImages(_ images: [DicomImage]) -> [DicomImage] {', ADAPTER).replace('private ', '')
cache_data = member(read(REMOTE), 'public func cacheData(for image: DicomImage?, maxFiles: Int) -> String? {', REMOTE)
content = read('Horos/Sources/StudyListContent.swift')
sorted_rows = member(content, 'static func sorted(_ items: [Any], by descriptors: [NSSortDescriptor]) -> [Any] {', 'StudyListContent.swift')

failures = []
# What the windows open is what the series sorts, and the viewer's own lists
# and steps open a series as the database window does.
if 'return series.sortedImages()' not in read(CHILDREN):
    failures.append(f'{CHILDREN}: the images of a series are no longer its sorted images')
for signature in ('func loadNextSeries(', 'func loadSeries('):
    if 'openSeriesImages(' not in member(navigation, signature, NAVIGATION):
        failures.append(f'{NAVIGATION}: {signature.strip("(")} no longer opens a series through openSeriesImages')
if 'DicomSeries.fileByFile(' not in member(opener, 'func keptImages(of toOpenArray: [Any]?) -> [Any] {', OPENER):
    failures.append(f'{OPENER}: the images the sub-series sheet keeps are no longer put file by file after the sort descriptors')
if 'viewerOpener.openChosenImages(' not in member(read(BROWSER), 'func openViewer(fromImages toOpenArray: [Any]!, movie movieViewer: Bool, '
                                                    'viewer: ViewerController!, keyImagesOnly keyImages: Bool,\n', BROWSER):
    failures.append(f'{BROWSER}: -openViewerFromImages:… no longer hands its lists to openChosenImages')
if 'Int(v) + 1' in series:
    failures.append(f'{SERIES}: a count of files still takes the frames of one file from the images')

HARNESS = r'''
import Foundation

let MAX4D: Int32 = 500

func N2ManagedObjectContextPerformAndWait(_ context: Any?, _ block: () -> Void) { block() }
func _N2LogExceptionImpl(_ e: NSException, _ stack: Bool, _ function: String) { print("exception:", e) }
enum HorosObjCException {
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
}

// "SERIESORDER", the order of the images of a series: 0 by instance number,
// 1 and -1 by location, 2 and -2 by date first.
var sortMode = 0
struct Preferences { subscript(key: String) -> Int { sortMode } }
struct ProcessSource { let preferences = Preferences() }
enum PreferencesSource { static let process = ProcessSource() }
enum DatabasePreferences { static let sortSeriesBySliceLocation = "SERIESORDER" }

INT_VALUE

/// An image of the database: a frame of a file.
final class DicomImage: NSObject {
    let file: String
    @objc let numberOfFrames: NSNumber!
    @objc let frameID: NSNumber!
    @objc let instanceNumber: NSNumber!
    @objc let sliceLocation: NSNumber!
    @objc let date: Date!
    let comment: String? = nil
    weak var series: DicomSeries?
    func width() -> NSNumber! { 512 }
    func height() -> NSNumber! { 512 }
    init(file: String, frames: Int, frame: Int, instance: Int, location: Float, time: TimeInterval) {
        self.file = file
        numberOfFrames = NSNumber(value: frames)
        frameID = NSNumber(value: frame)
        instanceNumber = NSNumber(value: instance)
        sliceLocation = NSNumber(value: location)
        date = Date(timeIntervalSinceReferenceDate: time)
    }
    func path() -> String! { file }
    var label: String { "\(file):\(frameID.intValue)" }
}

final class DicomSeries: NSObject {
    let rows: [DicomImage]
    /// "numberOfImages", as stored: negative for frames.
    var stored: NSNumber?
    var managedObjectContext: Any? { nil }
    init(_ rows: [DicomImage], stored: Int = 0) {
        self.rows = rows
        self.stored = NSNumber(value: stored)
        super.init()
        for row in rows where row.series == nil { row.series = self }
    }
    func horosImages() -> NSSet! { NSSet(array: rows) }
    var images: NSSet? { NSSet(array: rows) }
    func primitiveValue(forKey key: String) -> Any? { stored }
    /// Told apart from any count of files.
    func noFiles() -> NSNumber! { NSNumber(value: -7) }

    SERIES_MEMBERS
}

struct Flags: OptionSet {
    let rawValue: Int
    static let option = Flags(rawValue: 1)
}
final class Event { var modifierFlags: Flags = [] }
final class Application { var currentEvent: Event? }
enum NSApplication { static let shared = Application() }

var alerts: [String] = []
enum HorosAlertPanel {
    static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alerts.append(message)
        return 0
    }
}
enum StudyListItem {
    SORTED
}
enum SubSeriesChoice {
    case cancel, entire, opened
    case open([[Any]], movie: Bool)
}
final class ViewerController {}
final class BrowserController { var horos_openReparsedSeriesFlag = false }

struct Opening {
    var lists: [[Any]], movie: Bool, keyImagesOnly: Bool, flip: Bool
}

final class ViewerOpener {
    let browser = BrowserController()
    var openings: [Opening] = []
    var asked: [[Any]]?
    var waits = 0

    func showWaitWindow() { waits += 1 }
    func closeWaitWindow() {}
    func chooseSubSeries(_ splittedSeries: [[Any]], movie movieViewer: Bool, viewer: ViewerController?) -> SubSeriesChoice {
        asked = splittedSeries
        return .cancel
    }
    @discardableResult
    func openViewer(_ lists: [[Any]], movie: Bool, viewer: ViewerController?, keyImagesOnly: Bool, tryToFlipData: Bool = false) -> ViewerController? {
        openings.append(Opening(lists: lists, movie: movie, keyImagesOnly: keyImagesOnly, flip: tryToFlipData))
        return nil
    }
    /// What a viewer's own lists and steps open a series with.
    func step(_ images: [Any], keyImagesOnly: Bool) {
        _ = openSeriesImages(images, movie: false, viewer: nil, keyImagesOnly: keyImagesOnly, tryToFlipData: true)
    }

    OPENER_MEMBERS
}

/// The plugin API's lists of images.
enum PluginLists {
    PLUGIN_ORDER
}

/// A shared database: nothing is in its cache, and what it is asked to fetch
/// is kept.
func N2LogStackTraceMessage(_ message: String) {}
func remoteDicomDatabaseAdd(_ array: NSMutableArray, _ object: Any?) throws { array.add(object ?? NSNull()) }
final class RemoteDicomDatabase {
    var fetched: [String] = []
    func localPath(for image: DicomImage) -> String? { "/no such cache/" + image.file }
    func raisingForObjectiveC<T>(_ body: () throws -> T) -> T { try! body() }
    func download(_ remotePaths: [Any]?, to localPaths: [Any]?) throws -> Bool {
        fetched = (remotePaths ?? []).map { $0 as? String ?? "?" }
        return true
    }

    CACHE_DATA
}

var failed = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: " + message)
        failed += 1
    }
}

/// The frames of one multi-frame file: a volume when `spacing` is not 0, a
/// loop at one location otherwise. The acquisition numbers the frames from 1
/// in every file.
func file(_ path: String, frames: Int, time: TimeInterval, spacing: Float = 2.5) -> [DicomImage] {
    (0..<frames).map { DicomImage(file: path, frames: frames, frame: $0, instance: $0 + 1, location: Float($0) * spacing, time: time) }
}
func labels(_ images: [Any]?) -> [String] { (images ?? []).map { ($0 as? DicomImage)?.label ?? "?" } }
/// The order the sort descriptors alone give: what every series had.
func byDescriptors(_ series: DicomSeries) -> [String] {
    labels((series.horosImages().allObjects as NSArray).sortedArray(using: (series.sortDescriptorsForImages() as? [NSSortDescriptor]) ?? []))
}
func shuffled(_ rows: [DicomImage]) -> [DicomImage] {
    // The set hands its objects in no order: the rows come mixed.
    rows.enumerated().sorted { ($0.offset * 7919) % rows.count < ($1.offset * 7919) % rows.count }.map(\.element)
}

// Four volumes of 12 frames, a file each; the paths do not follow the time.
let times: [(String, TimeInterval)] = [("104.dcm", 1000), ("101.dcm", 4000), ("103.dcm", 2000), ("102.dcm", 3000)]
let volumesRows = times.flatMap { file($0.0, frames: 12, time: $0.1) }
let volumes = DicomSeries(shuffled(volumesRows), stored: -48)
let byTime = ["104.dcm", "103.dcm", "102.dcm", "101.dcm"]
// One multi-frame file; its frames run against the location.
let single = DicomSeries(shuffled(file("200.dcm", frames: 12, time: 500, spacing: -2.5)), stored: -12)
// Two loops of different sizes, merged by hand: every frame at one location.
let loops = DicomSeries(shuffled(file("301.dcm", frames: 8, time: 20, spacing: 0) + file("300.dcm", frames: 5, time: 10, spacing: 0)), stored: -13)
let evenLoops = DicomSeries(shuffled(file("311.dcm", frames: 6, time: 20, spacing: 0) + file("310.dcm", frames: 6, time: 10, spacing: 0)), stored: -12)
// Twelve single-frame files, numbered against their location and their time.
let classic = DicomSeries(shuffled((0..<12).map {
    DicomImage(file: "\(400 + $0).dcm", frames: 1, frame: 0, instance: $0 + 1, location: Float(11 - $0) * 3, time: TimeInterval(100 - ($0 % 3)))
}), stored: 12)
// More volumes than the 4D player takes.
let many = DicomSeries(shuffled((0..<501).flatMap { file("\(1000 + $0).dcm", frames: 2, time: TimeInterval(5000 - $0)) }), stored: -1002)
// Three passes over four locations, a single-frame file an image.
let passes = DicomSeries((0..<12).map {
    DicomImage(file: "\(500 + $0).dcm", frames: 1, frame: 0, instance: $0 + 1, location: Float($0 % 4), time: TimeInterval($0))
}, stored: 12)

// MARK: The number of files

check(volumes.rawNoFiles().intValue == 4, "four files of 12 frames are \(volumes.rawNoFiles()!) files, not 4")
check(single.rawNoFiles().intValue == 1, "one multi-frame file is \(single.rawNoFiles()!) files")
check(loops.rawNoFiles().intValue == 2, "two files of 8 and 5 frames are \(loops.rawNoFiles()!) files")
check(classic.rawNoFiles().intValue == 12, "twelve single-frame files are \(classic.rawNoFiles()!) files")
check(many.rawNoFiles().intValue == 501, "501 files of 2 frames are \(many.rawNoFiles()!) files")
check(DicomSeries([]).rawNoFiles().intValue == 0, "a series without images has files")
check(volumes.noFilesExcludingMultiFrames().intValue == 4, "without the frames, four files of 12 frames are \(volumes.noFilesExcludingMultiFrames()!)")
check(single.noFilesExcludingMultiFrames().intValue == 1, "without the frames, one multi-frame file is \(single.noFilesExcludingMultiFrames()!)")
check(classic.noFilesExcludingMultiFrames().intValue == -7, "single-frame files no longer answer by -noFiles")
check(DicomSeries(classic.rows, stored: 0).noFilesExcludingMultiFrames().intValue == -7, "single-frame files not yet counted no longer answer by -noFiles")

// MARK: The order

for mode in [0, 1, -1, 2, -2] {
    sortMode = mode
    check(labels(volumes.sortedImagesArray() as? [Any]) == byTime.flatMap { path in (0..<12).map { "\(path):\($0)" } },
          "order \(mode): the files of a series do not go by their time, a file after the other: \(labels(volumes.sortedImagesArray() as? [Any]).prefix(14))")
    check(labels(loops.sortedImagesArray() as? [Any]) == (0..<5).map { "300.dcm:\($0)" } + (0..<8).map { "301.dcm:\($0)" },
          "order \(mode): files of different sizes do not go a file after the other")
    for (name, ordinary) in [("single-frame files", classic), ("a single multi-frame file", single), ("passes", passes)] {
        check(labels(ordinary.sortedImagesArray() as? [Any]) == byDescriptors(ordinary), "order \(mode): \(name) no longer sort by the sort descriptors alone")
    }
    check((DicomSeries([]).sortedImagesArray()?.count ?? -1) == 0, "order \(mode): a series without images has no empty list")
}
// Some of the images, as the sub-series sheet keeps them: no more than the
// frames of one file, of several files all the same.
sortMode = 0
let kept = (volumes.sortedImagesArray() as? [Any] ?? []).enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
let keptByDescriptors = (kept as NSArray).sortedArray(using: (volumes.sortDescriptorsForImages() as? [NSSortDescriptor]) ?? [])
check(kept.count == 12 && labels(keptByDescriptors) != labels(kept) && labels(DicomSeries.fileByFile(keptByDescriptors)) == labels(kept),
      "one image in four of four volumes, sorted by the descriptors, is not put back file by file: \(labels(DicomSeries.fileByFile(keptByDescriptors)))")
// The descriptors do tell the orders apart: the test above compares something.
let forward = byDescriptors(single), numbered = byDescriptors(classic)
sortMode = 1
check(forward != byDescriptors(single) && numbered != byDescriptors(classic), "the preference of the order no longer changes the order of these series")
sortMode = 0

// MARK: Opening

func opened(_ series: DicomSeries, movie: Bool = false, reparse: Bool = false, option: Bool = false) -> (ViewerOpener, [Opening]) {
    let opener = ViewerOpener()
    alerts = []
    opener.browser.horos_openReparsedSeriesFlag = reparse
    NSApplication.shared.currentEvent = option ? Event() : nil
    NSApplication.shared.currentEvent?.modifierFlags = [.option]
    opener.open(lists: [series.sortedImagesArray() as? [Any] ?? []], movie: movie, viewer: nil)
    NSApplication.shared.currentEvent = nil
    return (opener, opener.openings)
}
func isOneStack(_ openings: [Opening], of series: DicomSeries, _ what: String) {
    check(openings.count == 1 && openings[0].lists.count == 1 && !openings[0].movie && openings[0].flip && !openings[0].keyImagesOnly
            && labels(openings.first?.lists.first) == labels(series.sortedImagesArray() as? [Any]) && alerts.isEmpty,
          "\(what) does not open as one stack of its sorted images: \(openings.map { ($0.lists.map(\.count), $0.movie, $0.flip) }) \(alerts)")
}
func isTimes(_ openings: [Opening], _ what: String) {
    check(openings.count == 1 && openings[0].movie && !openings[0].keyImagesOnly && alerts.isEmpty
            && openings[0].lists.map { labels($0) } == byTime.map { path in (0..<12).map { "\(path):\($0)" } },
          "\(what) does not open in the 4D player, a file a time, by the files' time: \(openings.map { ($0.lists.map(\.count), $0.movie) }) \(alerts)")
}

var (opener, openings) = opened(volumes)
isTimes(openings, "a double-click on four volumes")
check(opener.waits == 0 && openings.first?.flip == false, "four volumes open as several viewers do, or with their slices turned")
isTimes(opened(volumes, movie: true).1, "the 4D player asked for four volumes")
isOneStack(opened(single).1, of: single, "a single multi-frame file")
isOneStack(opened(classic).1, of: classic, "a series of single-frame files")
isOneStack(opened(passes).1, of: passes, "a series of passes in single-frame files")
isOneStack(opened(loops).1, of: loops, "files of different numbers of frames")
isOneStack(opened(evenLoops).1, of: evenLoops, "loops of as many frames, at one location")
(opener, openings) = opened(many)
isOneStack(openings, of: many, "more volumes than the 4D player takes")
check(Array(labels(openings.first?.lists.first).prefix(4)) == ["1500.dcm:0", "1500.dcm:1", "1499.dcm:0", "1499.dcm:1"], "501 volumes do not open volume by volume, by their time")

// The 4D player asked for: what it did with other series, and its limit said.
(opener, openings) = opened(passes, movie: true)
check(openings.count == 1 && openings[0].movie && openings[0].lists.map { labels($0) }
        == SeriesSplitting.movieGroups(sliceLocations: passes.rows.map { $0.sliceLocation.floatValue }).map { $0.map { passes.rows[$0].label } }
        && openings[0].lists.count == 3, "the 4D player no longer cuts a series of passes where the location repeats")
(opener, openings) = opened(many, movie: true)
check(openings.isEmpty && alerts.count == 1, "the 4D player asked for 501 volumes opens them, or says nothing: \(alerts)")
(opener, openings) = opened(single, movie: true)
check(openings.isEmpty && alerts.count == 1, "the 4D player asked for one volume no longer says it needs several: \(alerts)")

// "Reparsed Series" and Option keep the sheet of the sub-series.
for (reparse, option) in [(true, false), (false, true)] {
    (opener, openings) = opened(volumes, reparse: reparse, option: option)
    check(openings.isEmpty && opener.asked?.map(\.count) == [12, 12, 12, 12], "a reparse of four volumes is taken to the 4D player: \(String(describing: opener.asked?.map(\.count)))")
}

// A viewer's own lists and steps.
opener = ViewerOpener()
alerts = []
opener.step(volumes.sortedImagesArray() as? [Any] ?? [], keyImagesOnly: false)
isTimes(opener.openings, "a series of four volumes taken from a viewer")
opener = ViewerOpener()
opener.step(volumes.sortedImagesArray() as? [Any] ?? [], keyImagesOnly: true)
check(opener.openings.count == 1 && opener.openings[0].lists.count == 1 && !opener.openings[0].movie && opener.openings[0].keyImagesOnly,
      "the key images of four volumes are taken to the 4D player")
for ordinary in [single, classic, many, loops] {
    opener = ViewerOpener()
    opener.step(ordinary.sortedImagesArray() as? [Any] ?? [], keyImagesOnly: false)
    isOneStack(opener.openings, of: ordinary, "a series of \(ordinary.rows.count) images taken from a viewer")
}
check(opener.fileTimePoints(of: []) == nil && opener.fileTimePoints(of: ["not an image"]) == nil, "images that are none have times")

// MARK: What -openViewerFromImages:… is sent

func chosen(_ lists: [[Any]], movie: Bool = false, in viewer: ViewerController? = nil, keyImagesOnly: Bool = false, flip: Bool = false) -> [Opening] {
    let opener = ViewerOpener()
    alerts = []
    _ = opener.openChosenImages(lists, movie: movie, viewer: viewer, keyImagesOnly: keyImagesOnly, tryToFlipData: flip)
    return opener.openings
}
func isAsAsked(_ openings: [Opening], _ lists: [[Any]], movie: Bool = false, keyImagesOnly: Bool = false, flip: Bool = false, _ what: String) {
    check(openings.count == 1 && openings[0].lists.map { labels($0) } == lists.map { labels($0) } && openings[0].movie == movie
            && openings[0].keyImagesOnly == keyImagesOnly && openings[0].flip == flip && alerts.isEmpty,
          "\(what) do not open as they were asked: \(openings.map { ($0.lists.map(\.count), $0.movie, $0.keyImagesOnly, $0.flip) })")
}
let everyVolume = volumes.sortedImagesArray() as? [Any] ?? []
// The whole series: a retrieve that shows it, a reload in its viewer while
// its files arrive, a plugin handed it; in any order of its images.
isTimes(chosen([everyVolume]), "every image of four volumes, sent to the browser")
isTimes(chosen([everyVolume], in: ViewerController(), flip: true), "every image of four volumes, sent to the browser for a viewer")
check(Set(chosen([volumes.rows]).first?.lists.map { Set(labels($0)) } ?? []) == Set(byTime.map { path in Set((0..<12).map { "\(path):\($0)" }) })
        && chosen([volumes.rows]).first?.movie == true, "every image of four volumes in another order does not open with a file a time")
// Not the whole series, or not one list: what the sender chose.
let twoVolumes = Array(everyVolume.prefix(24))
isAsAsked(chosen([twoVolumes], flip: true), [twoVolumes], flip: true, "two of the four volumes of a series")
isAsAsked(chosen([twoVolumes + twoVolumes]), [twoVolumes + twoVolumes], "two volumes of four, each image twice,")
isAsAsked(chosen([everyVolume], keyImagesOnly: true), [everyVolume], keyImagesOnly: true, "the key images of four volumes")
isAsAsked(chosen([everyVolume, everyVolume]), [everyVolume, everyVolume], "two lists of four volumes")
isAsAsked(chosen([twoVolumes, Array(everyVolume.suffix(24))], movie: true), [twoVolumes, Array(everyVolume.suffix(24))], movie: true, "the lists of a movie")
isAsAsked(chosen([everyVolume], movie: true), [everyVolume], movie: true, "one list sent as a movie")
check(chosen([]).count == 1 && chosen([]).first?.lists.isEmpty == true, "no list at all is no longer handed on as it is")
for ordinary in [single, classic, many, loops, evenLoops, passes] {
    let images = ordinary.sortedImagesArray() as? [Any] ?? []
    for flip in [false, true] {
        isAsAsked(chosen([images], flip: flip), [images], flip: flip, "the \(ordinary.rows.count) images of an ordinary series")
    }
}

// MARK: The plugin API's order, and the files fetched ahead from a shared database

func byNumber(_ rows: [DicomImage]) -> [String] {
    rows.enumerated().sorted { a, b in
        let x = (a.element.instanceNumber.intValue, a.element.frameID.intValue), y = (b.element.instanceNumber.intValue, b.element.frameID.intValue)
        return x != y ? x < y : a.offset < b.offset
    }.map(\.element.label)
}
check(labels(PluginLists.sortedImages(volumes.rows)) == byTime.flatMap { path in (0..<12).map { "\(path):\($0)" } },
      "the plugin API lists four volumes with their frames mixed: \(labels(PluginLists.sortedImages(volumes.rows)).prefix(6))")
check(labels(PluginLists.sortedImages(loops.rows)) == (0..<5).map { "300.dcm:\($0)" } + (0..<8).map { "301.dcm:\($0)" },
      "the plugin API lists two loops of one series with their frames mixed")
for (name, ordinary) in [("single-frame files", classic), ("a single multi-frame file", single), ("passes", passes)] {
    check(labels(PluginLists.sortedImages(ordinary.rows)) == byNumber(ordinary.rows),
          "the plugin API no longer lists \(name) by instance number and frame")
}
check(PluginLists.sortedImages([]).isEmpty, "the plugin API lists images of none")

/// The files a shared database fetches for `image` and those after it, to
/// the size of `maxFiles` images of 512 x 512.
func fetched(_ image: DicomImage?, maxFiles: Int) -> [String] {
    let database = RemoteDicomDatabase()
    let path = database.cacheData(for: image, maxFiles: maxFiles)
    check((path == nil) == (image == nil) && (image == nil || path == "/no such cache/" + (image?.file ?? "")), "the file fetched is not the one of the image asked")
    return database.fetched
}
for mode in [0, 1, -1, 2, -2] {
    sortMode = mode
    let ordered = volumes.sortedImagesArray() as? [DicomImage] ?? []
    // A volume of 12 frames of 512 x 512 is 12 images: 20 let two files in, 30 three.
    check(fetched(ordered[0], maxFiles: 20) == ["104.dcm", "103.dcm"] && fetched(ordered[0], maxFiles: 30) == ["104.dcm", "103.dcm", "102.dcm"],
          "order \(mode): the files fetched after the first volume are not the next by their time: \(fetched(ordered[0], maxFiles: 30))")
    check(fetched(ordered[17], maxFiles: 20) == ["103.dcm", "102.dcm"] && fetched(ordered[47], maxFiles: 50) == ["101.dcm"]
            && fetched(ordered[30], maxFiles: 1) == ["102.dcm"],
          "order \(mode): the files fetched from a frame inside a volume are not its own and the next: \(fetched(ordered[17], maxFiles: 20))")
    // Single-frame files: those after the image as the sort descriptors put them, as before.
    let rows = (classic.horosImages().allObjects as NSArray).sortedArray(using: (classic.sortDescriptorsForImages() as? [NSSortDescriptor]) ?? []) as? [DicomImage] ?? []
    check(fetched(rows[4], maxFiles: 3) == rows[4..<7].map(\.file) && fetched(rows[10], maxFiles: 50) == rows[10...].map(\.file),
          "order \(mode): the single-frame files fetched ahead are no longer the next by the sort descriptors: \(fetched(rows[4], maxFiles: 3))")
    check(fetched(single.rows[3], maxFiles: 50) == ["200.dcm"], "order \(mode): a single multi-frame file is not fetched once")
}
sortMode = 0
check(fetched(nil, maxFiles: 5).isEmpty, "no image fetches files")

if failed != 0 { exit(1) }
print("ok")
'''

source = (HARNESS.replace('INT_VALUE', int_value.replace('fileprivate ', '')).replace('SERIES_MEMBERS', series_members)
          .replace('OPENER_MEMBERS', opener_members).replace('PLUGIN_ORDER', plugin_order).replace('CACHE_DATA', cache_data)
          .replace('SORTED', sorted_rows))

with tempfile.TemporaryDirectory(prefix='horos-multi-frame-files-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(source, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', *map(str, RULES), str(folder / 'main.swift'),
                            '-o', str(folder / 'test')], capture_output=True, text=True, timeout=280)
    if built.returncode:
        sys.exit('FAIL: does not compile:\n' + built.stderr[-4000:])
    run = subprocess.run([str(folder / 'test')], capture_output=True, text=True, timeout=60)
    failures += [line for line in run.stdout.splitlines() if line.startswith('FAIL: ')]
    if run.returncode and not failures:
        failures.append('the harness stopped: ' + (run.stderr or run.stdout)[-1500:])

if failures:
    for failure in failures:
        print(failure if failure.startswith('FAIL: ') else 'FAIL: ' + failure)
    sys.exit(1)
print('PASS: a series of several multi-frame files counts its distinct files, sorts file by file by the files\' time and opens in the '
      '4D player, a file a time, up to the player\'s limit, also when the browser is sent every image of it; the plugin API lists it '
      'and a shared database fetches it file by file; single-frame files, a single multi-frame file, files of different sizes, '
      'loops, a reparse, key images, part of a series and several lists count, sort and open as before')

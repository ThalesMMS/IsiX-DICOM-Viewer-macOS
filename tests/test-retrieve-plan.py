#!/usr/bin/env python3
"""A retrieve asks for its series in a planned order, the operator's first.

RetrievePlan, compiled alone:
- as listed keeps the node's order; by series number orders by number, then
  UID; fewest instances first orders by the node's instance count, an
  estimate (a multiframe instance counts as one), then number, then UID;
- a series without a number or count goes after those that have one, and
  equal keys give the same order on every run, whatever the listing order;
- a series given priority goes first among what has not started, a new
  priority replaces it, and every series stays in the plan;
- URLs are deduplicated keeping the first of each in order, and ordered by
  the plan stably, a request of no series before the others;
- a running plan is found by node and study, and no longer once it has ended;
- a stored order outside the known ones reads as "as listed".

And in the sources: DICOMweb asks for the study in one request when the order
is the node's own and for each series in the plan's order otherwise, and its
request pool starts the first pending request of the plan's order; WADO-URI
keeps its list's order when deduplicating and reorders what has not started
when a priority arrives; the query window gives a series of a study being
retrieved to that retrieve instead of a second one; the viewer's frame order
is not touched; both node editors offer the order, localized in every catalog.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


driver = r'''
import Foundation
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }
func plan(_ order: RetrieveOrder, _ series: [(String, Int?, Int?)]) -> RetrievePlan {
    let plan = RetrievePlan(order: order)
    for (uid, number, count) in series { plan.add(series: uid, number: number.map { NSNumber(value: $0) }, instances: count.map { NSNumber(value: $0) }) }
    return plan
}
// Series: (UID, number, instance count). "1.4" is one multiframe instance of
// 300 frames: its count is 1, an estimate, not its size.
let listed: [(String, Int?, Int?)] = [("1.3", 3, 12), ("1.1", 1, 12), ("1.4", 4, 1), ("1.2", 2, nil), ("1.5", nil, 2), ("1.0", nil, nil)]
check(plan(.asListed, listed).orderedSeries == ["1.3", "1.1", "1.4", "1.2", "1.5", "1.0"], "as listed")
check(plan(.seriesNumber, listed).orderedSeries == ["1.1", "1.2", "1.3", "1.4", "1.0", "1.5"], "by number: \(plan(.seriesNumber, listed).orderedSeries)")
check(plan(.fewestInstances, listed).orderedSeries == ["1.4", "1.5", "1.1", "1.3", "1.2", "1.0"], "fewest: \(plan(.fewestInstances, listed).orderedSeries)")
check(plan(.fewestInstances, listed).isEstimate && !plan(.seriesNumber, listed).isEstimate, "fewest instances is an estimate")
// Equal keys: the same order whatever the listing order.
let ties: [(String, Int?, Int?)] = [("2.9", 1, 5), ("2.1", 1, 5), ("2.5", nil, 5)]
for order in [RetrieveOrder.seriesNumber, .fewestInstances] {
    check(plan(order, ties).orderedSeries == plan(order, ties.reversed()).orderedSeries, "stable tie-break \(order)")
}
check(plan(.fewestInstances, ties).orderedSeries == ["2.1", "2.9", "2.5"], "ties by number then UID")
// Priority: first among the rest, replaced by a new one, nothing dropped.
let p = plan(.fewestInstances, listed)
let before = p.revision
p.prioritize(series: "1.3")
check(p.orderedSeries.first == "1.3" && p.revision != before && Set(p.orderedSeries) == Set(listed.map { $0.0 }), "the chosen series first, all kept")
p.prioritize(series: "1.0")
check(p.orderedSeries == ["1.0", "1.4", "1.5", "1.1", "1.3", "1.2"], "a new choice: \(p.orderedSeries)")
check(p.rank(of: "1.0") == 0 && p.rank(of: "9.9") == listed.count, "ranks")
p.add(series: "1.0", number: 9, instances: 9)
check(p.orderedSeries.count == listed.count, "a series added twice is one")
// URLs: unique in order, then the plan's order, stable within a series.
func url(_ series: String, _ object: String) -> URL { URL(string: "http://h/wado?requestType=WADO&studyUID=9&seriesUID=\(series)&objectUID=\(object)")! }
let urls = [url("1.1", "a"), url("1.4", "b"), url("1.1", "a"), url("1.1", "c"), url("1.5", "d"), URL(string: "http://h/other")!]
let unique = RetrievePlan.unique(urls)
check(unique == [url("1.1", "a"), url("1.4", "b"), url("1.1", "c"), url("1.5", "d"), URL(string: "http://h/other")!], "unique keeps the first, in order")
let q = plan(.fewestInstances, listed)
check(q.order(urls: unique) == [URL(string: "http://h/other")!, url("1.4", "b"), url("1.5", "d"), url("1.1", "a"), url("1.1", "c")], "the plan's order, stable")
q.prioritize(series: "1.1")
check(q.order(urls: unique).dropFirst().first == url("1.1", "a"), "a priority reorders what has not started")
// A running retrieve is found by node and study until it ends.
check(!RetrievePlan.prioritize(series: "1.1", study: "9", endpoint: "node"), "nothing running")
q.begin(endpoint: "node", study: "9")
check(RetrievePlan.prioritize(series: "1.5", study: "9", endpoint: "node") && q.prioritySeries == "1.5", "the running retrieve takes the choice")
check(!RetrievePlan.prioritize(series: "1.5", study: "9", endpoint: "other"), "another node's retrieve is apart")
q.end(endpoint: "node", study: "9")
check(!RetrievePlan.prioritize(series: "1.5", study: "9", endpoint: "node"), "ended")
check(RetrievePlan.order(forStoredValue: nil) == .asListed && RetrievePlan.order(forStoredValue: NSNumber(value: 7)) == .asListed &&
      RetrievePlan.order(forStoredValue: "2") == .fewestInstances, "stored values")
check(!RetrievePlan(order: .asListed).controlsSeries && RetrievePlan(order: .seriesNumber).controlsSeries, "only a planned order controls the series")
print("PASS: orders, estimate, missing keys, stable ties, priority, all series kept, ordered dedup, running retrieves")
'''

with tempfile.TemporaryDirectory(prefix='horos-retrieve-plan-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(root / 'Horos/Sources/RetrievePlan.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True, timeout=300)
    run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip())
    check(run.returncode == 0, 'the plan check failed')

node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()


def block(name):
    start = node.index(name)
    return node[start:node.index('\n}\n', start)]


retrieve = block('- (BOOL)retrieveDICOMweb')
check('BOOL perSeries = whole && plan.controlsSeries;' in retrieve and 'if (whole && !perSeries) enqueue(base, nil, nil);' in retrieve,
      'one request for the study unless the order is planned')
check('else for (NSString *seriesUID in ordered) enqueue([NSString stringWithFormat:@"studies/%@/series/%@", study, seriesUID], nil, seriesUID);' in retrieve,
      'each series in one multipart request, in the plan order')
check('(!ordered.count && !plan.excludesEverything)) enqueue(base, nil, nil);' in retrieve, 'no series listed: the whole study')
check('NSArray *ordered = pending.count > 1 ? plan.orderedSeries : nil;' in retrieve and 'if (rank < best) { best = rank; next = i; }' in retrieve,
      'the pool starts the first pending request of the plan')
check('(!expectedSeries || actualSeries == [expectedSeries UTF8String])' in retrieve, 'a series request accepts only its series')
check(retrieve.index('[plan beginForEndpoint:endpoint study:study];') < retrieve.index('[listing start];') and
      '[plan endForEndpoint:endpoint study:study];' in retrieve, 'the plan runs for the retrieve')
hierarchy = block('- (BOOL) queryImagesHierarchicallyForStudy:(NSString*) studyInstanceUID')
check('seriesDataset.insertEmptyElement( DCM_SeriesNumber, OFTrue);' in hierarchy and
      '[_retrievePlan addSeries: uid number: [_seriesNumbers objectForKey: uid] instances: [_seriesInstanceCounts objectForKey: uid]' in hierarchy,
      'the series listing gives the plan numbers and counts, before any pixel')
check(hierarchy.count('[_retrievePlan markSeriesListed];') == 2, 'the plan learns the listing ended, failed or not')
wado = block('- (void) WADORetrieve: (DCMTKStudyQueryNode*) study listing: (NSDictionary*) listing')
check(wado.count('downloader.retrievePlan = plan;') == 2 and wado.count('[plan orderURLs: urlToDownload]') == 2,
      'WADO-URI study retrieves follow the plan')
download = (root / 'Horos/Sources/WADODownload.swift').read_text()
check('NSSet(array:' not in download and download.count('RetrievePlan.unique(') == 2, 'deduplicated in order')
check('if let plan = self.retrievePlan, plan.revision != revision {' in download and 'remaining = plan.order(urls: remaining)' in download,
      'a priority reorders what has not started')
query = (root / 'Horos/Sources/QueryController.mm').read_text(encoding='latin-1')
check('if( retryEverything == NO && HorosGiveSeriesToRunningRetrieve( item))' in query and
      '[unstarted removeObjectsInArray: takenItems];' in query and 'HorosSeriesTakenByRetrieveOf( item)' in query,
      'a series of a running retrieve goes first in it, and its viewing ends with it')
viewer = ''.join((root / 'Horos/Sources' / name).read_text(errors='ignore') for name in
                 ('ViewerController+RetrieveAndView.swift', 'RetrieveViewing.swift'))
check('RetrievePlan' not in viewer, 'the viewer frame order is not the network order')
pane = (root / 'Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift').read_text()
check('key: "WADOSeriesOrder"' in pane and 'forKey: RetrievePlan.wadoKey as NSString' in pane, 'the WADO sheet edits and saves the order')
editor = (root / 'Horos/Sources/DICOMwebNodeEditor.swift').read_text()
check('cell.addItems(withTitles: RetrievePlan.orderTitles)' in editor and 'node.seriesOrder = index' in editor, 'the DICOMweb table edits the order')
dicomweb_node = (root / 'Horos/Sources/DICOMwebNode.swift').read_text()
check('node[Key.seriesOrder] = seriesOrder' in dicomweb_node, 'a DICOMweb node keeps its order')
keys = ['Series Order', 'Series Order:', 'As Listed', 'Series Number', 'Fewest Instances First (estimate)']
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    data = catalog.read_bytes()
    text = data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8')
    missing = [key for key in keys if f'"{key}" =' not in text]
    check(not missing and "The order this node's series are asked for in." in text, f'{catalog.parent.name}: {missing}')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)

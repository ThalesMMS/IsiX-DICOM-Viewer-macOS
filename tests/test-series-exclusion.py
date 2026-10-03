#!/usr/bin/env python3
"""A node's rules leave series out of a retrieve by their description.

RetrievePlan and RetrieveInventory, compiled together:
- a rule is a literal substring of the description, whatever the case and
  accents of either; nothing is read into it (no synonym, no translation); an
  empty description matches no rule; rules are trimmed, without empty ones or
  repeats, read from a list or from text separated by commas or lines;
- a plan with rules leaves out the series a rule matches, keeps those without
  a description, asks for each series on its own, falls back to one request
  for the study when nothing is left out and the order is the node's own,
  knows when everything is left out, and drops their WADO-URI URLs; without
  rules nothing changes; a running retrieve does not take a series it leaves
  out as a priority, so that series is retrieved on its own;
- the inventory records what was left out and why: a second pass does not ask
  for it, it is no failure, the scope counts leave it out, and the summary
  names each series and rule without calling the study complete.

And in the sources: the series listing asks for SeriesDescription; WADO-RS
asks only for the eligible series (or the whole study when that suffices, or
nothing), skips their instances, records the exclusion before the second pass
and tells the operator; WADO-URI drops their URLs and tells the operator; a
series asked for by itself is retrieved and the operator told why; Option
(asking for everything again) ignores the rules; the viewing state settles on
the scope; both editors offer the rules, localized in every catalog.
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
let directory = CommandLine.arguments[1]
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }
typealias P = RetrievePlan
// Matching.
check(P.exclusionRule(for: "SCOUT 3-plane", rules: ["scout"]) == "scout", "case")
check(P.exclusionRule(for: "Córonal MPR", rules: ["coronal"]) == "coronal", "accents in the description")
check(P.exclusionRule(for: "Coronal MPR", rules: ["córonal"]) == "córonal", "accents in the rule")
check(P.exclusionRule(for: "Sagital", rules: ["sagittal"]) == nil, "no synonym or translation")
check(P.exclusionRule(for: "Localizer", rules: ["scout"]) == nil, "nothing read into a rule")
check(P.exclusionRule(for: "", rules: ["scout"]) == nil, "an empty description is retrieved")
check(P.exclusionRule(for: "Axial", rules: ["", "  "]) == nil, "empty rules match nothing")
check(P.exclusionRules(forStoredValue: " scout , Localizer\ncoronal,,SCOUT") == ["scout", "Localizer", "coronal"], "text: \(P.exclusionRules(forStoredValue: " scout , Localizer\ncoronal,,SCOUT"))")
check(P.exclusionRules(forStoredValue: ["scout", 3, " "]) == ["scout"] && P.exclusionRules(forStoredValue: nil).isEmpty, "list, nothing")
check(P.text(forExclusionRules: ["scout", "localizer"]) == "scout, localizer", "as the editors show them")
// A plan with rules.
let plan = RetrievePlan(order: .asListed)
check(!plan.controlsSeries, "no rules: one request")
plan.exclude(matching: ["scout"])
check(plan.controlsSeries && plan.hasExclusionRules, "rules: each series on its own")
plan.add(series: "1.1", number: 1, instances: 12, description: "Axial")
plan.add(series: "1.2", number: 2, instances: 3, description: "Scout")
plan.add(series: "1.3", number: 3, instances: 5, description: nil)
check(plan.orderedSeries == ["1.1", "1.3"] && plan.isExcluded(series: "1.2"), "the scout left out, the undescribed kept")
check(plan.excludedSeries == ["1.2": ["Scout", "scout"]], "what and why: \(plan.excludedSeries)")
check(!plan.wholeStudySuffices && !plan.excludesEverything, "not the whole study, not nothing")
func url(_ series: String) -> URL { URL(string: "http://h/wado?requestType=WADO&studyUID=9&seriesUID=\(series)&objectUID=1")! }
check(plan.eligible(urls: [url("1.1"), url("1.2"), url("1.3")]) == [url("1.1"), url("1.3")], "WADO-URI drops the scout")
plan.begin(endpoint: "node", study: "9")
check(!RetrievePlan.prioritize(series: "1.2", study: "9", endpoint: "node"), "a left-out series is retrieved on its own")
check(RetrievePlan.prioritize(series: "1.3", study: "9", endpoint: "node"), "an eligible one goes first")
plan.end(endpoint: "node", study: "9")
let none = RetrievePlan(order: .asListed)
none.exclude(matching: ["scout"])
none.add(series: "2.1", number: 1, instances: 1, description: "Axial")
check(none.wholeStudySuffices, "nothing left out, the node's order: the whole study")
let all = RetrievePlan(order: .seriesNumber)
all.exclude(matching: ["scout", "loc"])
all.add(series: "3.1", number: 1, instances: 1, description: "SCOUT")
all.add(series: "3.2", number: 2, instances: 1, description: "Localizer")
check(all.excludesEverything && all.orderedSeries.isEmpty, "everything left out")
check(!RetrievePlan(order: .asListed).excludesEverything, "an empty plan leaves out nothing")
// The inventory.
let m = RetrieveInventory.begin(study: "9", series: "", endpoint: "node", database: directory, instances: [], confirmed: false, reported: 6, seriesReported: [:])
m.updateImportedUIDs([])
for uid in ["a1", "a2"] { m.record(uid: uid, status: 0) }
m.confirm(instances: [["uid": "a1", "series": "1.1"], ["uid": "a2", "series": "1.1"], ["uid": "a3", "series": "1.1"],
                      ["uid": "s1", "series": "1.2"], ["uid": "s2", "series": "1.2"], ["uid": "u1", "series": "1.3"]],
          confirmed: true, reported: 6, seriesReported: [:], discovery: "confirmed")
m.exclude(series: plan.excludedSeries)
check(m.unreceivedSeries == ["1.1": ["a3"], "1.3": ["u1"]], "the second pass skips the scout: \(m.unreceivedSeries)")
m.updateImportedUIDs(["a1", "a2", "a3", "u1"])
check(!m.needsAttention, "a left-out series is no failure")
check(m.scopeExpectedCount == 4 && m.scopeImportedCount == 4 && m.expectedCount == 6, "the scope")
check(!m.isComplete && m.summary.contains("the study is not complete") && m.summary.contains("\"Scout\" (rule \"scout\")"), m.summary)
check(m.excludedSeries == ["1.2": ["Scout", "scout"]], "recorded")
m.exclude(series: [:])
check(m.excludedSeries.isEmpty && m.needsAttention && m.scopeExpectedCount == 6, "an attempt without rules misses the scout")
m.finish()
let e = RetrieveInventory.begin(study: "8", series: "", endpoint: "node", database: directory, instances: [], confirmed: false, reported: 2, seriesReported: [:])
e.updateImportedUIDs([])
e.confirm(instances: [["uid": "x1", "series": "3.1"], ["uid": "x2", "series": "3.2"]], confirmed: true, reported: 2, seriesReported: [:], discovery: "confirmed")
e.exclude(series: all.excludedSeries)
check(e.summary.hasPrefix("Not retrieved: the node's rules leave out every series") && e.scopeExpectedCount == 0 && !e.needsAttention, e.summary)
e.finish()
print("PASS: matching, rules, plan exclusion, whole study or nothing, URLs, explicit series, inventory scope and summary")
'''

with tempfile.TemporaryDirectory(prefix='horos-series-exclusion-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(driver)
    (p / 'db').mkdir()
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(root / 'Horos/Sources/RetrievePlan.swift'),
                    str(root / 'Horos/Sources/RetrieveInventory.swift'), str(p / 'main.swift'), '-o', str(p / 'test')],
                   check=True, timeout=300)
    run = subprocess.run([str(p / 'test'), str(p / 'db')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip())
    check(run.returncode == 0, 'the exclusion check failed')

node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()


def block(name):
    start = node.index(name)
    return node[start:node.index('\n}\n', start)]


hierarchy = block('- (BOOL) queryImagesHierarchicallyForStudy:(NSString*) studyInstanceUID')
check('seriesDataset.insertEmptyElement( DCM_SeriesDescription, OFTrue);' in hierarchy and
      'description: [_seriesDescriptions objectForKey: uid]];' in hierarchy, 'the series listing gives the plan each description')
retrieve = block('- (BOOL)retrieveDICOMweb')
check('if (!_noSmartMode) [plan excludeSeriesMatching:node.excludedSeries ?: @[]];' in retrieve, 'Option ignores the rules')
check('if (plan.wholeStudySuffices || (!ordered.count && !plan.excludesEverything)) enqueue(base, nil, nil);' in retrieve,
      'the whole study only when nothing is left out; nothing when everything is')
check('![plan isExcludedSeries:image.seriesInstanceUID]' in retrieve, 'no instance of a left-out series')
check(retrieve.index('[_retrieveInventory excludeSeries:excluded];') < retrieve.index('_retrieveInventory.unreceivedSeries'),
      'the exclusion is recorded before the second pass')
check('if (!succeeded && !whole && !excluded.count) enqueue(base, nil, nil);' in retrieve, 'a failed listing does not bring back what the rules leave out')
check('[self noteExcludedSeries:excluded everything:plan.excludesEverything];' in retrieve and
      '[self noteExplicitRetrieveOfSeriesExcludedByRule:rule];' in retrieve, 'the operator is told')
check('_retrieveInventory.scopeExpectedCount' in retrieve, 'what was asked for, not what was left out')
wado = block('- (void) WADORetrieve: (DCMTKStudyQueryNode*) study listing: (NSDictionary*) listing')
check(wado.count('[plan eligibleURLs: [plan orderURLs: urlToDownload]]') == 2, 'WADO-URI drops left-out URLs')
check('_noSmartMode ? @[] : [HorosRetrievePlan exclusionRulesForStoredValue:' in wado and
      'if( plan.excludesEverything)' in wado and wado.count('noteExcludedSeries:') == 3, 'WADO-URI rules, nothing to ask, told')
query = (root / 'Horos/Sources/QueryController.mm').read_text(encoding='latin-1')
check('expected = inventory.scopeExpectedCount;' in query and 'inventory.scopeImportedCount' in query, 'the viewing state settles on the scope')
editor = (root / 'Horos/Sources/DICOMwebNodeEditor.swift').read_text()
check('node.excludedSeries = RetrievePlan.exclusionRules(forStoredValue: text)' in editor, 'the DICOMweb table edits the rules')
pane = (root / 'Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift').read_text()
check('field.bind(.value, to: self, withKeyPath: "WADOExcludeSeries"' in pane and 'forKey: RetrievePlan.wadoExclusionKey as NSString' in pane,
      'the WADO sheet edits and saves the rules')
dicomweb_node = (root / 'Horos/Sources/DICOMwebNode.swift').read_text()
check('node[Key.excludeSeries] = excludedSeries' in dicomweb_node and 'public var excludedSeries: [String] = []' in dicomweb_node,
      'a DICOMweb node keeps its rules, none by default')
keys = ['Exclude Series', 'Exclude Series:', 'e.g. scout, localizer', 'Nothing Retrieved', 'Series Left Out', 'Series Retrieved Despite a Rule']
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    data = catalog.read_bytes()
    text = data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8')
    missing = [key for key in keys if f'"{key}" =' not in text]
    check(not missing and 'Series whose description contains one of these words or phrases' in text, f'{catalog.parent.name}: {missing}')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)

#!/usr/bin/env python3
"""The study retrieved from the patient's history is found once it arrives.

When a study of the history is retrieved to be selected or opened, the browser
waits for it: every second PatientHistoryList.selectWaitedStudy fetches the
local Study whose studyInstanceUID is the waited query node's, then selects and
opens it. The query node answers its UID through a method,
`@objc func studyInstanceUID() -> String!`; a predicate built from the method
itself, rather than from what it returns, never matches, and the study arrives
but is never selected nor opened.

This compiles the fetch as selectWaitedStudy builds it (its entity and its
predicate line, pasted as they are) with the app's own `comparison` helper,
over a stand-in query node with the real node's accessor, and runs it on
SQLite and in-memory stores holding the waited study among others.

An optional argument is the PatientHistoryList.swift to read instead of the
checkout's, so the same check can be run against another revision.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
history = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Horos/Sources/PatientHistoryList.swift'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def member(source, signature):
    """The member that starts with `signature`, through its closing brace."""
    start = source.index(signature)
    depth, index = 0, source.index('{', start)
    while True:
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1


source = history.read_text(encoding='utf-8')
waiting = member(source, 'private func selectWaitedStudy()')
binding = re.search(r'guard let (\w+) = browser\.horos_comparativeStudyWaited else', waiting)
entity = re.search(r'let request = NSFetchRequest<NSFetchRequestResult>\(entityName: "(\w+)"\)', waiting)
predicate = re.search(r'^\s*request\.predicate = (.+)$', waiting, re.MULTILINE)
if not (binding and entity and predicate):
    print('FAIL: selectWaitedStudy no longer builds its fetch as this test reads it')
    sys.exit(1)

# The waited study is a DCMTKStudyQueryNode (BrowserController+StateAccess.swift);
# the stand-in keeps the accessor exactly as the real node declares it.
node = (root / 'Horos/Sources/DCMTKStudyQueryNode.swift').read_text(encoding='utf-8')
accessor = re.search(r'^\s*(@objc func studyInstanceUID\(\) -> String!) \{', node, re.MULTILINE)
state = (root / 'Horos/Sources/BrowserController+StateAccess.swift').read_text(encoding='utf-8')
check(re.search(r'var horos_comparativeStudyWaited: DCMTKStudyQueryNode\?', state),
      'the waited study is no longer a DCMTKStudyQueryNode; the stand-in no longer matches it')
if not accessor:
    print('FAIL: DCMTKStudyQueryNode no longer declares studyInstanceUID() as this test expects')
    sys.exit(1)

helpers = (root / 'Horos/Sources/StudyListContent.swift').read_text(encoding='utf-8')
comparison = member(helpers, 'nonisolated func comparison(')

DRIVER = r'''
import CoreData
import Foundation

final class DCMTKStudyQueryNode: NSObject {
    let uidValue: String?
    init(uid: String?) { uidValue = uid }
    @ACCESSOR@ { uidValue ?? "" }
}

@COMPARISON@

func waitedFetch(_ @BINDING@: DCMTKStudyQueryNode, in context: NSManagedObjectContext) -> String {
    let request = NSFetchRequest<NSFetchRequestResult>(entityName: "@ENTITY@")
    request.predicate = @PREDICATE@
    do {
        let found = try context.fetch(request) as! [NSManagedObject]
        return "\(found.count) " + found.map { ($0.value(forKey: "studyInstanceUID") as? String) ?? "-" }.joined(separator: ",")
    } catch {
        return "error \(error)"
    }
}

let attribute = NSAttributeDescription()
attribute.name = "studyInstanceUID"
attribute.attributeType = .stringAttributeType
attribute.isOptional = true
let study = NSEntityDescription()
study.name = "Study"
study.managedObjectClassName = "NSManagedObject"
study.properties = [attribute]
let model = NSManagedObjectModel()
model.entities = [study]

for type in [NSSQLiteStoreType, NSInMemoryStoreType] {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let url = type == NSSQLiteStoreType ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
    _ = try! coordinator.addPersistentStore(ofType: type, configurationName: nil, at: url, options: nil)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    for uid in ["1.2.826.0.1.3680043.2.1125.100", "1.2.826.0.1.3680043.2.1125.200", "1.2.826.0.1.3680043.2.1125.2001"] {
        let row = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        row.setValue(uid, forKey: "studyInstanceUID")
    }
    try! context.save()
    let store = type == NSSQLiteStoreType ? "sqlite" : "memory"
    print("\(store) waited: " + waitedFetch(DCMTKStudyQueryNode(uid: "1.2.826.0.1.3680043.2.1125.200"), in: context))
    print("\(store) absent: " + waitedFetch(DCMTKStudyQueryNode(uid: "1.2.826.0.1.3680043.2.1125.300"), in: context))
}
'''
driver = (DRIVER.replace('@ACCESSOR@', accessor.group(1)).replace('@COMPARISON@', comparison)
          .replace('@BINDING@', binding.group(1)).replace('@ENTITY@', entity.group(1))
          .replace('@PREDICATE@', predicate.group(1).strip()))

with tempfile.TemporaryDirectory(prefix='horos-history-waited-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(folder / 'main.swift'),
                            '-framework', 'CoreData', '-o', str(folder / 'driver')], capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL: the fetch did not compile:\n' + built.stderr[-3000:])
        sys.exit(1)
    ran = subprocess.run([str(folder / 'driver'), str(folder / 'studies.sqlite')], capture_output=True, text=True, timeout=60)
    print(ran.stdout, end='')
    lines = dict(line.split(': ', 1) for line in ran.stdout.splitlines() if ': ' in line)
    check(ran.returncode == 0, 'the fetch driver stopped (%s): %s' % (ran.returncode, ran.stderr[-1000:]))
    for store in ('sqlite', 'memory'):
        check(lines.get(store + ' waited') == '1 1.2.826.0.1.3680043.2.1125.200',
              'on the %s store the fetch does not find the waited study alone: %s' % (store, lines.get(store + ' waited')))
        check(lines.get(store + ' absent') == '0 ',
              'on the %s store the fetch finds a study that has not arrived: %s' % (store, lines.get(store + ' absent')))

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print('PASS: the waited study is fetched by its UID on SQLite and in-memory stores, and only once it has arrived')

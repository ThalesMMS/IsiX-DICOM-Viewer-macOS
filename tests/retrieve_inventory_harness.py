"""Compile a driver of the retrieve inventory, which lives in IsiXDICOMNetwork.

The tests of the inventory drive it the way the retrieve does, with the rows
of a listing written as dictionaries ("uid", "series", "sopClass", "number",
"offered" "NO") and the peer's counts per series as numbers, and they post
the notifications the app's store observes. `swiftc_arguments(folder)` builds
the module into `folder` and returns the swiftc arguments that link it with a
prelude that gives those drivers:

- `RetrieveInventory.begin(...)`, `.load(...)` and `confirm(instances:...)`
  over one store of the process, as the app's;
- that store observing "HorosDICOMStoreCompleted" and Core Data's saves and
  changes on the default notification center, as the app's does.

The prelude re-exports IsiXDICOMNetwork, so a driver needs no import of it.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

PRELUDE = r'''
import CoreData
import Foundation
@_exported import IsiXDICOMNetwork

/// The store of the process, observing what the app's observes.
let retrieveInventories: RetrieveInventoryStore = {
    let store = RetrieveInventoryStore()
    store.observe(.default, storesCompleted: Notification.Name("HorosDICOMStoreCompleted"),
                  databaseChanges: [.NSManagedObjectContextDidSave, .NSManagedObjectContextObjectsDidChange])
    return store
}()

/// A listing's rows, as the drivers write them.
func listedInstances(_ rows: [[String: String]]) -> [RetrieveListedInstance] {
    rows.map { RetrieveListedInstance(sopInstanceUID: $0["uid"] ?? "", seriesInstanceUID: $0["series"] ?? "",
                                      sopClassUID: $0["sopClass"], instanceNumber: $0["number"], offered: $0["offered"] != "NO") }
}

extension RetrieveInventory {
    static func begin(study: String, series: String, endpoint: String, database: String, instances: [[String: String]],
                      confirmed: Bool, reported: Int = 0, seriesReported: [String: NSNumber] = [:]) -> RetrieveInventory {
        retrieveInventories.begin(study: study, series: series, endpoint: endpoint, database: database,
                                  instances: listedInstances(instances), confirmed: confirmed, reported: reported,
                                  seriesReported: seriesReported.mapValues { $0.intValue })
    }

    static func load(study: String, series: String, endpoint: String, database: String) -> RetrieveInventory? {
        retrieveInventories.load(study: study, series: series, endpoint: endpoint, database: database)
    }

    func confirm(instances: [[String: String]], confirmed: Bool, reported: Int, seriesReported: [String: NSNumber],
                 discovery: String) {
        confirm(instances: listedInstances(instances), confirmed: confirmed, reported: reported,
                seriesReported: seriesReported.mapValues { $0.intValue }, discovery: discovery)
    }
}
'''


def swiftc_arguments(folder, link=True):
    """The prelude and the flags that link IsiXDICOMNetwork, built into `folder`.
    `link` False gives the prelude alone, for a test whose other flags already
    link the module (tests/dicomweb_package.py does)."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    prelude = folder / 'RetrieveInventoryHarness.swift'
    prelude.write_text(PRELUDE)
    return [str(prelude)] + (isix_modules.module_flags('IsiXDICOMNetwork', folder / 'modules') if link else [])

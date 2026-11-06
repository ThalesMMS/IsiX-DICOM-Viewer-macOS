"""The process graph, for a test that compiles an app source which reads the
preferences through `ProcessGraph.process.preferences` or
`PreferencesSource.process.preferences` without the rest of the application.

`source(folder)` writes the stand-in into `folder`: a graph that hands out the
standard preferences, as the graph does, followed by the app's own
Horos/Sources/PreferencesSource.swift as it is, so the source of the objects
the graph does not reach is the real one over the stand-in graph.
`swift_flags(folder)` also builds the IsiXPreferences module there and returns
the swiftc arguments to add: the stand-in and the flags that import and link
the module.
"""
from pathlib import Path

import isix_modules

PREFERENCES_SOURCE = Path(__file__).resolve().parents[1] / 'Horos/Sources/PreferencesSource.swift'

SOURCE = '''import Foundation

/// The process graph of the application, for the preferences only.
final class ProcessGraph: Sendable {
    static let process = ProcessGraph()
    private init() {}
    var preferences: UserDefaults { UserDefaults.standard }
}
'''


def source(folder):
    """The stand-in and PreferencesSource.swift, written in `folder`."""
    path = Path(folder) / 'ProcessGraphStandIn.swift'
    path.write_text(SOURCE + '\n' + PREFERENCES_SOURCE.read_text(encoding='utf-8'))
    return path


def swift_flags(folder, extra=()):
    """The stand-in source and the flags of IsiXPreferences, built in `folder`."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    return [str(source(folder)), *isix_modules.module_flags('IsiXPreferences', folder, extra)]

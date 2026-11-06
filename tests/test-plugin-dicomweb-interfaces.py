#!/usr/bin/env python3
"""The plugin entry points, notifications and DICOMweb source interfaces remain available.

Legacy Horos/OsiriX plugins no longer compile against the application's own
headers: they build against the IsiXLegacyBridge kit, whose PluginFilter keeps
the entry points its loader calls (-initPlugin once, -filterImage: for each
menu title) and whose Notifications.h names the notifications it relays from
the application. -processFiles: is not part of the kit: no plugin type the
loader accepts is run through it.

- the kit's PluginFilter declares -filterImage:, -initPlugin and -prepareFilter:;
- every notification the kit defines under a name the application also
  declares carries the application's value, so a legacy plugin observes what
  the application posts (among them the ROI change and the database import);
- the application still declares the notifications plugins and its own
  windows listen to, and keeps its plugin manager and DICOMweb sources.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tests"))
from sources import source_path  # noqa: E402

failures = []

kit_filter = (root / "IsiXLegacyBridge/Headers/PluginFilter.h").read_text(encoding="latin1")
for selector in ("- (long) filterImage: (NSString*) menuName;", "- (void) initPlugin;",
                 "- (long) prepareFilter: (IsiXLegacyViewerController*) vC;"):
    if selector not in kit_filter:
        failures.append(f"the legacy kit's PluginFilter lost {selector}")

kit_names = dict(re.findall(r'^#define\s+(\w+Notification\w*)\s+@"([^"]*)"',
                            (root / "IsiXLegacyBridge/Headers/Notifications.h").read_text(encoding="latin1"), re.M))
app_names = dict(re.findall(r'NSString\s*\*\s*const\s+(\w+)\s*=\s*@"([^"]*)"',
                            (root / "Horos/Sources/Notifications.m").read_text(encoding="latin1")))
shared = sorted(set(kit_names) & set(app_names))
for name in ("OsirixROIChangeNotification", "OsirixAddToDBNotification"):
    if name not in shared:
        failures.append(f"{name} is not both relayed by the legacy kit and declared by the application")
for name in shared:
    if kit_names[name] != app_names[name]:
        failures.append(f"{name} is {kit_names[name]!r} in the legacy kit and {app_names[name]!r} in the application")

notifications = (root / "Horos/Sources/Notifications.h").read_text(encoding="latin1")
for name in ("OsirixROIChangeNotification", "OsirixAddToDBNotification",
             "OsirixPopulatedContextualMenuNotification",
             "OsirixViewerControllerDidLoadImagesNotification",
             "AppPluginDownloadInstallDidFinishNotification"):
    if name not in notifications:
        failures.append(f"the application no longer declares {name}")
if not source_path("PluginManager").is_file():
    failures.append("PluginManager is gone")
for name in ("DICOMwebClient", "DICOMwebCredentials", "DICOMwebMultipart", "DICOMwebNodeEditor"):
    if not list((root / "Horos/Sources").glob(f"*{name}*")):
        failures.append(f"no {name} source")

for failure in failures:
    print("FAIL:", failure)
if failures:
    sys.exit(1)
print(f"PASS: legacy plugin entry points, {len(shared)} relayed notifications with the application's values, "
      "the application's notifications and DICOMweb sources")

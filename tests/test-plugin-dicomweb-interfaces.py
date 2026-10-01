#!/usr/bin/env python3
"""The plugin entry points, notifications and DICOMweb source interfaces remain available."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tests"))
from sources import source_path  # noqa: E402

header = (root / "Horos/Sources/PluginFilter.h").read_text(encoding="latin1")
for selector in ("filterImage", "processFiles", "initPlugin"):
    assert selector in header, selector
notifications = (root / "Horos/Sources/Notifications.h").read_text(encoding="latin1")
for name in ("OsirixROIChangeNotification", "OsirixAddToDBNotification",
             "OsirixPopulatedContextualMenuNotification",
             "OsirixViewerControllerDidLoadImagesNotification",
             "AppPluginDownloadInstallDidFinishNotification"):
    assert name in notifications, name
assert source_path("PluginManager").is_file()
for name in ("DICOMwebClient", "DICOMwebCredentials", "DICOMwebMultipart", "DICOMwebNodeEditor"):
    assert list((root / "Horos/Sources").glob(f"*{name}*")), name
print("PASS: plugin entry points, notifications and DICOMweb source interfaces")

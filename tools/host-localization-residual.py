#!/usr/bin/env python3
"""English values that stay English on purpose in the host catalogs.

Technical names, product names, units, hanging-protocol anatomy codes, format
tokens and the abbreviations written over the image are not translations.
Everything else in the Italian and Spanish catalogs must differ from the
English value.

The texts written over the image follow the language of the interface:
tests/test-image-overlay-translations.py lists them and requires each one in
every catalog. What stays here of them is what no language translates (WL, WW,
Im, SUV, the letters of a measurement, the units) and, in OVERLAY_SAME_WORD,
the readouts a language writes as English does because its word is the same.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Readouts over the image whose word a language shares with English: Zoom in
# Spanish, Area, Min, Max and Pixel in Italian. The test of the texts over the
# image says which language may write each one as English does.
OVERLAY_SAME_WORD = {
    "Zoom: %0.0f%%",
    "Min: %0.3f%@", "Max: %0.3f%@",
    "Area: %0.1f %cm²", "Area: %0.3f cm²", "Area: %0.3f mm²", "Area: %0.3f pix2",
    "   Pixel: %@    %@ %@",
    "Area (ROI statistic)", "Min (ROI statistic)", "Max (ROI statistic)",
}

# Product, platform, format and protocol names that are the same in every UI.
PRODUCT = {
    "IsiX DICOM Viewer", "IsiX DICOM Viewer 64-bit", "IsiX DICOM Viewer Light",
    "IsiX DICOM Viewer Lite", "IsiX DICOM Viewer MD",
    "IsiX DICOM Viewer bundle", "IsiX DICOM Viewer CD/DVD",
    "Horos", "OsiriX", "OsiriXDB.plist",
    "iPhoto", "Photos", "iChat", "QuickTime", "QuickTime VR", "Quicktime Export",
    "Microsoft Word", "Mac OS X", "macOS", "macOS Version", "MacOS Version",
    "Mac OS Version",
    "Pages", "LibreOffice",
}

TECHNICAL = {
    "DICOM", "DICOMDIR", "DICOMDIR:", "URL:", "Host", "Soundex", "PACS", "ROI", "ROIs", "ROI ", "CLUT", "WLWW",
    "WL / WW", "WL & WW", "WL/WW & CLUT",
    "MIP", "MinIP", "MPR", "CPR", "PET", "SUV", "RGB", "JPEG", "TIFF", "LOD",
    "WADO", "QIDO", "C-MOVE", "C-GET", "RTSTRUCT",
    "16-bit CLUT",
    "No CLUT",
    "3DCut", "3DRotate", "3DRotateCamera", "2D/3D", "3D", "32-bit", "64-bit",
    "BW", "B/W Inverse", "Cobb", "Repulsor", "FlyThru", "Fly Thru",
    "AccessionNumber",
    "DICOMNodes.plist", "DICOMPrinters.plist", "DatabaseAlbums.albums",
    "N/A", "n/a", "OK", "OK !", "OPENGL ERROR",
    "Plugin", "Preset", "Password", "Password:", "Password:<br><br>", "Server:",
    "Routing", "Routing...", "Query", "Zoom", "Frame",
    "On-Demand", "Stereo", "CD/DVD", "Database",
        "File", "file", "N2Connection timeout.",
        "%d series", "%@ (%d series)", "%i bytes", "bytes",
        "series", "Album: %@", "Axial", "CD-Rom", "CD/DVD",
        "Color", "Coronal", "Error", "Error: %@", "File: %@",
        "General", "Horizontal", "Vertical", "Local", "Local %", "Total", "Zoom",
        "Incompatible", "N2Connection timeout.", "Routing...",
        "Perpendicular", "Rendering...", "Reslicing...", "Report PDF",
        "Database: %@", "Name: %@", "Projection: %@",
    "Q&R Auto-Query", "Q&R Auto-Retrieve",
    "Ortho", "Endo",
    "%ld ROIs", "Color:", "Inspector",
}

MODALITY = {
    "CR", "CT", "MR", "US", "XA", "PT", "NM", "MG", "DX", "RF", "SC", "OT",
    "ES", "PR", "KO", "ECG",
}

# Hanging-protocol / laterality codes kept as the stored English tokens.
ANATOMY = {
    "A", "I", "L", "P", "R", "S",
    "ABD", "ABDOMEN", "AC JOINT", "ACROMIAL", "ADRENAL", "ANKLE", "APPENDIX",
    "BICEPS", "BLADDER", "BRACHIAL", "BRAIN",
    "C SPINE", "CALCANEUS", "CARDIAC", "CAROTID", "CARPAL", "CERVICAL",
    "CHEST", "CLAVICLE", "ELBOW", "FACE", "FEMUR", "FIBULA", "FINGER",
    "FOOT", "FOREARM", "HALLUX", "HAND", "HEAD", "HEART", "HEEL", "HIP",
    "HIPS", "HUMERUS", "IAC", "IVP", "KIDNEY", "KNEE", "L SPINE", "LIVER",
    "LOWER LEG", "LUNG", "MANDIBLE", "MAXILLOFACIAL", "MEDIASTINUM",
    "NAVICULAR", "NECK", "ORBIT", "ORBITS", "OS CALCIS", "OVARIES", "OVARY",
    "PANCREAS", "PELVIC", "PELVIS", "PITUITARY", "PROSTATE", "PULMONARY",
    "RADIUS", "RENAL", "ROTATOR CUFF", "SCAPHOID", "SCAPULA", "SHOULDER",
    "SINUS", "STERNUM", "T SPINE", "TALUS", "TEMPORAL BONE", "THIGH",
    "THORACIC", "THORAX", "THUMB", "THYROID", "TIBIA", "TOE", "TOES",
    "ULNA", "UPPER ARM", "UTERUS", "WRIST",
}

UNITS = {
    "cm", "mm", "px", "dB", "sec", "hertz",
    "cm/sec", "cm²", "cm²/sec", "cm³", "cm³/sec", "m/sec", "dB/sec",
    " DB", " m", " y",
    # A diffusion b-value with its unit, the same in every language.
    "b = %@ s/mm²",
}

# Album names that embed a modality code; the token is the search key.
TODAY_YESTERDAY = {
    "Today CR", "Today CT", "Today MG", "Today MR", "Today RF", "Today US",
    "Today XA",
    "Yesterday CR", "Yesterday CT", "Yesterday MG", "Yesterday MR",
    "Yesterday RF", "Yesterday US", "Yesterday XA",
}

# Readouts that stay as English writes them: the abbreviations, letters and
# units written over the image (WL, WW, Im, SUV, the points of a measurement,
# W and H), the texts of other windows, and entries no source reads any more.
OVERLAY = {
    "Im: %ld-%ld/%ld %@",
    "Im: %ld/%ld %@",
    "SUV: %.2f",
    "\n - the same location for each image",
    "\n - the same number of images",
    "\n - the same pixels spacing",
    "\rMean: %2.4f SDev: %2.4f Total: %2.4f",
    "\rMin: %2.4f Max: %2.4f ",
    "\rSkewness: %2.4f Kurtosis: %2.4f ",
    "%0.0f im/s",
    "%0.1f im/s",
    "A-B : %2.2f cm",
    "A-C : %2.2f cm",
    "A: %@",
    "B-C : %2.2f cm",
    "B-C: %@",
    "B: %@",
    "C: %@",
    "Area: %0.1f %cm² (W: %0.1f %cm H: %0.1f %cm)",
    "Area: %0.3f cm² (W: %0.3f cm H: %0.3f cm)",
    "Area: %0.3f mm² (W: %0.3f mm H: %0.3f mm)",
    "Area: %0.3f pix2 (W: %0.3f pix H: %0.3f pix)",
    "Fused Image Mean: %0.3f%@ SDev: %0.3f%@ Sum: %0.0f%@",
    "Fused Image Mean: %0.3f%@ SDev: %0.3f%@ Sum: %0.0f%@ Median: %@%@",
    "Fused Image Min: %0.3f%@ Max: %0.3f%@",
    "Fused Image Min: %0.3f%@ Max: %0.3f%@ Skewness: %0.3f Kurtosis: %0.3f",
    "Mean: %0.3f%@ SDev: %0.3f%@ Sum: %0.0f%@",
    "Mean: %0.3f%@ SDev: %0.3f%@ Sum: %0.0f%@ Median: %@%@",
    "Min: %0.3f%@ Max: %0.3f%@",
    "Min: %0.3f%@ Max: %0.3f%@ Skewness: %0.3f Kurtosis: %0.3f",
    # The width and the height of an ROI keep their letters, as the name the
    # Viewers pane's check gives them does where a catalog writes W/H.
    "(W: %@ H: %@)", "W/H (ROI statistic)",
    "Volume : %2.4f cm³",
    "Volume : %2.4f mm³",
    "WL: %.0f WW: %.0f",
    "WL: %0.4f WW: %0.4f",
    "WL: %d WW: %d",
    "value : %.0f",
    "value : %.0f\nalpha : %1.3f",
    "value:\t%2.2f",
    "alpha : %1.3f",
    "mm:\t\tx:%2.2f y:%2.2f z:%2.2f",
    "px:\t\tx:%d y:%d",
    "r:%.0f%%, g:%.0f%%, b:%.0f%%",
    "zoom x %.1f",
    "Elapsed Time:\r%2.2d:%2.2d:%2.2d",
    "Last Duration:\r%2.2d:%2.2d:%2.2d",
    "Estimated remaining time: %2.2d:%2.2d:%2.2d",
    "(~/Library/Application Support/Horos App/)",
    "%@-Report.pdf",
}

EXACT = (
    OVERLAY_SAME_WORD | PRODUCT | TECHNICAL | MODALITY | ANATOMY | UNITS
    | TODAY_YESTERDAY | OVERLAY | {
        " (TLS)", " (SUV Converted)", " (retired)",
        "Horos Screen Captures", "IsiX Screen Captures",
        "iChat Theatre shared view",
        "MPEG-2 File",
        "Uncompressed BigEndian",
        # Names stored in a database, a 3D state or the preferences, which stay as English writes them.
        "Linear Table", "Logarithmic Inverse Table", "No Filter",
        # The predefined values of a surface: one is the name of a window level preset, and the two
        # beside it in the menu are written the same way.
        "CT - Bone", "CT - Skin", "CT - Metal",
    }
)

WORD = re.compile(r"[A-Za-zÀ-ÿ]{3,}")
FORMAT = re.compile(
    r"%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztLq])?"
    r"[@diuoxXfFeEgGaAcCsSpn%]"
)


def is_format_or_token(text):
    """True when the string has no translatable word of three letters or more."""
    stripped = FORMAT.sub("", text)
    stripped = re.sub(r"[\d\s\.\,:;_\-–—/\\|()\[\]<>•·×xX%#\+\*=\"'`~]+", "", stripped)
    return not WORD.search(stripped)


def is_residual(key, english_value=None):
    value = english_value if english_value is not None else key
    if key in EXACT or value in EXACT:
        return True
    if is_format_or_token(key) and is_format_or_token(value):
        return True
    return False

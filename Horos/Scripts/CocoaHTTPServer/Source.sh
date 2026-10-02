#!/bin/sh
#
# The Horos target compiles six original CocoaHTTPServer implementations
# through the wrappers in cocoahttpserver/, each of which includes its original
# from "upstream/". This puts the originals where that include finds them: the
# pinned archive is resolved and verified by external-inputs.sh, and the files
# named in cocoahttpserver/UPSTREAM.json are selected out of it, unchanged, into
# the derived sources, which the target's user header search paths name.

set -e

recipes="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$(sh "$recipes/external-inputs.sh" --source CocoaHTTPServer "$TARGET_TEMP_DIR/CocoaHTTPServer.source" \
    "${EXTERNAL_SOURCES_DOWNLOADS:-$PROJECT_TEMP_DIR/ExternalSources.downloads}")"
python3 "$recipes/CocoaHTTPServer/select.py" "$source_dir" "$PROJECT_DIR/cocoahttpserver/UPSTREAM.json" \
    "$DERIVED_FILE_DIR/CocoaHTTPServer"

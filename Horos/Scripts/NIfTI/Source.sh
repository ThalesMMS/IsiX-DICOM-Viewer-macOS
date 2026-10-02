#!/bin/sh
#
# The Horos target compiles the NIfTI-1 I/O library and znzlib itself, with its
# own settings. This puts their files where it finds them: the pinned nifti_clib
# archive is resolved and verified by external-inputs.sh, and the files named in
# UPSTREAM.json are selected out of it, unchanged, into the derived sources.

set -e

recipes="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$(sh "$recipes/external-inputs.sh" --source NIfTI "$TARGET_TEMP_DIR/NIfTI.source" \
    "${EXTERNAL_SOURCES_DOWNLOADS:-$PROJECT_TEMP_DIR/ExternalSources.downloads}")"
python3 "$recipes/NIfTI/select.py" "$source_dir" "$recipes/NIfTI/UPSTREAM.json" "$DERIVED_FILE_DIR/NIfTI"

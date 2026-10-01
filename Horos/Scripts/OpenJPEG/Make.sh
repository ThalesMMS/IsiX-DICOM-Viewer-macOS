#!/bin/sh

set -e; set -o xtrace

source_prefix="$TARGET_TEMP_DIR/Source"
cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"

product_manifest() {
    python3 - "$install_dir" "$source_prefix/share/source.json" "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys

root, record = Path(sys.argv[1]), Path(sys.argv[2])
try:
    required = ('lib/libopenjp2.a', 'include/OpenJPEG/openjpeg.h',
                'include/OpenJPEG/opj_config.h', 'share/source.json', 'share/licenses/OpenJPEG/LICENSE')
    if any(not (root / path).is_file() or not (root / path).stat().st_size for path in required):
        raise ValueError('missing or empty OpenJPEG install product')
    if (root / 'share/source.json').read_bytes() != record.read_bytes():
        raise ValueError('installed source record differs from resolved source')
    pin = json.loads(record.read_text())
    if hashlib.sha256((root / 'share/licenses/OpenJPEG/LICENSE').read_bytes()).hexdigest() != pin['licenseSha256']:
        raise ValueError('installed license differs from source declaration')
    products = {}
    for part in ('include', 'lib', 'share'):
        base = root / part
        if base.is_symlink() or not base.is_dir():
            raise ValueError('invalid install directory: ' + part)
        for parent, directories, files in os.walk(base, followlinks=False):
            for entry in sorted(directories + files):
                path = Path(parent) / entry
                relative = path.relative_to(root).as_posix()
                if path.is_symlink():
                    if not path.resolve(strict=True).is_relative_to(root.resolve()):
                        raise ValueError('installed link escapes prefix')
                    products[relative] = ['link', os.readlink(path)]
                elif path.is_file():
                    products[relative] = ['sha256', hashlib.sha256(path.read_bytes()).hexdigest()]
                elif path.is_dir():
                    products[relative] = ['directory']
                else:
                    raise ValueError('invalid install product: ' + relative)
    saved = root / '.products.json'
    if sys.argv[3] == 'write':
        saved.write_text(json.dumps(products, sort_keys=True) + '\n')
    elif saved.is_symlink() or json.loads(saved.read_text()) != products:
        raise ValueError('installed products differ from their recorded identity')
except (OSError, ValueError, KeyError, RuntimeError) as error:
    print('OpenJPEG: invalid install: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

if [ -d "$install_dir" ] && [ ! -f "$install_dir/.incomplete" ] && product_manifest check; then
    exit 0
fi

# A partial or altered installation must not keep headers from an older build.
rm -rf "$install_dir"

mkdir -p "$install_dir"
touch "$install_dir/.incomplete"

args=()
export MAKEFLAGS="-j $(sysctl -n hw.ncpu)"
export CC=clang
export CXX=clang

cd "$cmake_dir"
make "${args[@]}"
make install

# Upstream installs the static library and public headers. Keep the legacy
# include spelling as an alias, without copying internal codec headers.
ln -s openjpeg-2.5 "$install_dir/include/OpenJPEG"
mkdir -p "$install_dir/share/licenses/OpenJPEG"
cp "$source_prefix/share/source.json" "$install_dir/share/source.json"
cp "$source_prefix/source/LICENSE" "$install_dir/share/licenses/OpenJPEG/LICENSE"
product_manifest write

rm -f "$install_dir/.incomplete"

exit 0

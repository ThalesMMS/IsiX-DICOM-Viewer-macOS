#!/bin/sh
#
# Resolves the external inputs declared in external-inputs.lock into a directory
# the build controls, and refuses anything that is not exactly what the lock says.
#
#     sh external-inputs.sh PREFIX DOWNLOADS [LOCK]
#
# PREFIX     where the inputs are staged: PREFIX/include, PREFIX/lib and
#            PREFIX/share. ITK and VTK configure against it and the app links it.
# DOWNLOADS  where the verified bottles are kept between builds.
# LOCK       the declaration; external-inputs.lock beside this script by default.
#
# PNG, TIFF and JPEG used to come from whatever the Homebrew of the building Mac
# had installed, found by CMake under /opt/homebrew, so the same commit consumed
# different versions on different Macs and nothing noticed an upgrade. Here each
# library is an official bottle fetched by its SHA-256. The installed Homebrew is
# never consulted. A bottle with another digest, a library that links something
# the lock does not declare, or one built for a newer macOS than the deployment
# target stops the build with the reason.
#
# The staged libraries are renamed to their place in PREFIX and signed ad hoc, so
# the app links and loads these files and not the Homebrew ones. Libraries of the
# macOS itself (/usr/lib, /System) are left as they are: they are not inputs this
# file fixes. The work happens beside PREFIX and replaces it in one rename, under
# a lock, because ITK and VTK both call this and Xcode may run them together.

set -e

# Source archives use the same resolver entry point and per-prefix lock as the
# bottles. Their pristine tree and provenance are managed separately from the
# relocated dynamic libraries.
if [ "$1" = --source ]; then
    name="$2"
    prefix="$3"
    downloads="$4"
    declaration="${5:-$(cd "$(dirname "$0")" && pwd)/external-sources.json}"
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    case "$prefix" in /*) ;; *) echo >&2 'error: external source: PREFIX must be absolute'; exit 1;; esac
    [ -n "$name" ] && [ -n "$downloads" ] || { echo >&2 'error: usage: external-inputs.sh --source NAME PREFIX DOWNLOADS [DECLARATION]'; exit 1; }
    mkdir -p "$(dirname "$prefix")"
    if [ -z "$EXTERNAL_INPUTS_LOCKED" ]; then
        export EXTERNAL_INPUTS_LOCKED=1
        exec /usr/bin/lockf -k "$prefix.lock" /bin/sh "$script" --source "$name" "$prefix" "$downloads" "$declaration"
    fi
    exec python3 - "$name" "$prefix" "$downloads" "$declaration" "$script" <<'PY'
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit

name, prefix, downloads, declaration, script = sys.argv[1:]
prefix, downloads = Path(prefix), Path(downloads)
work = prefix.with_name(prefix.name + '.partial')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or '..' in path.parts or '\\' in value:
        raise ValueError('unsafe archive layout: ' + value)
    return path


def manifest(folder):
    products = {}
    for part in ('source', 'share'):
        base = folder / part
        if base.is_symlink() or not base.is_dir():
            raise ValueError('missing source products: ' + part)
        for parent, directories, files in os.walk(base, followlinks=False):
            for entry in sorted(directories + files):
                path = Path(parent) / entry
                if path.is_symlink():
                    raise ValueError('unexpected source link: ' + str(path))
                relative = path.relative_to(folder).as_posix()
                if path.is_dir():
                    products[relative] = ['directory']
                elif path.is_file():
                    products[relative] = ['sha256', digest(path), path.stat().st_mode & 0o777]
                else:
                    raise ValueError('invalid source product: ' + relative)
    return products


try:
    pin = json.loads(Path(declaration).read_text())[name]
    for field in ('name', 'version', 'upstream', 'revision', 'archive', 'sha256',
                  'url', 'root', 'license', 'licenseSha256', 'versionFile', 'versionPatterns'):
        if not pin.get(field):
            raise ValueError('source declaration lacks ' + field)
    if pin['name'] != name or not re.fullmatch(r'[A-Za-z0-9._-]+', name):
        raise ValueError('invalid source name')
    if not re.fullmatch(r'[0-9a-f]{40}', pin['revision']):
        raise ValueError('source revision must be an immutable commit')
    for field in ('sha256', 'licenseSha256'):
        if not re.fullmatch(r'[0-9a-f]{64}', pin[field]):
            raise ValueError(field + ' must be a SHA-256')
    kind = pin.get('archiveKind', 'commit')
    url = urlsplit(pin['url'])
    if kind == 'commit':
        if not pin['url'].startswith('https://') or pin['revision'] not in pin['url'].split('/'):
            raise ValueError('source URL must contain the immutable commit')
    elif kind == 'release':
        # A release asset's bytes are fixed by SHA-256, rather than a fabricated
        # commit in its URL. Keep the existing commit-archive contract unchanged.
        if (url.scheme != 'https' or not url.netloc or url.username or url.password or
                url.query or url.fragment or
                any(part.lower() in ('latest', 'main', 'master', 'head') for part in url.path.split('/')) or
                '/refs/heads/' in url.path or url.path.rsplit('/', 1)[-1] != pin['archive'] or
                not re.fullmatch(r'[0-9]+[.][0-9]+[.][0-9]+', pin['version']) or
                not re.search(r'(^|[-_])' + re.escape(pin['version']) + r'([._-]|$)', pin['archive'])):
            raise ValueError('release source URL/archive must name the fixed versioned asset')
    else:
        raise ValueError('unsupported source archive kind')
    for field in ('root', 'archive'):
        if len(safe_path(pin[field]).parts) != 1:
            raise ValueError('invalid ' + field)
    for field in ('license', 'versionFile'):
        safe_path(pin[field])
    record = json.dumps(pin, sort_keys=True, indent=2) + '\n'
    stamp = hashlib.sha256((record + digest(Path(script))).encode()).hexdigest()
    if (prefix / '.resolved').is_file() and (prefix / '.resolved').read_text() == stamp + '\n':
        try:
            saved = prefix / '.products.json'
            if saved.is_symlink() or json.loads(saved.read_text()) != manifest(prefix):
                raise ValueError('source products differ from their recorded identity')
            if (prefix / 'share/source.json').read_text() != record:
                raise ValueError('source record differs from the declaration')
            print(prefix / 'source')
            sys.exit(0)
        except (OSError, ValueError):
            print('external source: recovering modified or missing products of ' + name, file=sys.stderr)
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / pin['archive']
    if not archive.is_file() or archive.is_symlink() or digest(archive) != pin['sha256']:
        instruction = 'Place %s (SHA-256 %s) in the archive cache to build offline.' % (archive, pin['sha256'])
        if os.environ.get('EXTERNAL_INPUTS_OFFLINE') == '1':
            raise ValueError('missing or corrupt archive for %s. %s' % (name, instruction))
        mirror = os.environ.get('EXTERNAL_SOURCES_MIRROR')
        url = mirror.rstrip('/') + '/' + pin['archive'] if mirror else pin['url']
        # Different configurations may share downloads while locking their own
        # source prefixes. Never let concurrent downloads write one partial file.
        descriptor, temporary = tempfile.mkstemp(prefix=archive.name + '.', suffix='.part', dir=downloads)
        os.close(descriptor)
        part = Path(temporary)
        print('external source: fetching %s from %s' % (name, url), file=sys.stderr)
        try:
            try:
                subprocess.run(['/usr/bin/curl', '-fsSL', '--retry', '3', '--retry-all-errors',
                                '--connect-timeout', '30', '--max-time', '300', url, '-o', str(part)], check=True)
            except subprocess.CalledProcessError:
                raise ValueError('could not download %s. %s' % (name, instruction)) from None
            found = digest(part)
            if found != pin['sha256']:
                raise ValueError('downloaded SHA-256 %s, declared %s' % (found, pin['sha256']))
            part.replace(archive)
        finally:
            part.unlink(missing_ok=True)
    shutil.rmtree(work, ignore_errors=True)
    (work / 'source').mkdir(parents=True)
    (work / 'share').mkdir()
    with tarfile.open(archive, 'r:gz') as tar:
        seen = set()
        for member in tar:
            path = safe_path(member.name)
            if path.parts[0] != pin['root'] or not (member.isdir() or member.isfile()):
                raise ValueError('archive has unexpected layout or member: ' + member.name)
            if member.name in seen:
                raise ValueError('duplicate archive member: ' + member.name)
            seen.add(member.name)
            relative = Path(*path.parts[1:])
            destination = work / 'source' / relative
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                if len(path.parts) < 2:
                    raise ValueError('archive root is not a directory')
                destination.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, destination.open('xb') as output:
                    shutil.copyfileobj(source, output)
                destination.chmod(member.mode & (0o555 if pin.get('readOnly') else 0o777))
    source = work / 'source'
    version_text = (source / pin['versionFile']).read_text()
    matches = [re.search(pattern, version_text) for pattern in pin['versionPatterns']]
    version = '.'.join(match.group(1) for match in matches if match)
    if not all(matches) or version != pin['version']:
        raise ValueError('archive version %s does not match declared %s' % (version, pin['version']))
    if digest(source / pin['license']) != pin['licenseSha256']:
        raise ValueError('archive license differs from the declaration')
    (work / 'share/source.json').write_text(record)
    (work / '.products.json').write_text(json.dumps(manifest(work), sort_keys=True) + '\n')
    (work / '.resolved').write_text(stamp + '\n')
    previous = prefix.with_name(prefix.name + '.previous')
    if previous.exists():
        raise ValueError('previous source preserved at ' + str(previous))
    if prefix.exists():
        prefix.rename(previous)
    try:
        work.rename(prefix)
    except OSError:
        if previous.exists():
            previous.rename(prefix)
        raise
    shutil.rmtree(previous, ignore_errors=True)
    print(prefix / 'source')
except (OSError, ValueError, KeyError, TypeError, re.error, tarfile.TarError, subprocess.CalledProcessError) as error:
    print('error: external source %s: %s' % (name, error), file=sys.stderr)
    sys.exit(1)
finally:
    shutil.rmtree(work, ignore_errors=True)
PY
fi

prefix="$1"
downloads="$2"
lock="${3:-$(cd "$(dirname "$0")" && pwd)/external-inputs.lock}"
script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

fail() {
    printf 'error: external inputs: %s\n' "$*" >&2
    exit 1
}

[ -n "$prefix" ] && [ -n "$downloads" ] || fail "usage: $0 PREFIX DOWNLOADS [LOCK]"
[ -f "$lock" ] || fail "no declaration at $lock"
case "$prefix" in /*) ;; *) fail "PREFIX must be absolute: $prefix" ;; esac

mkdir -p "$(dirname "$prefix")"
if [ -z "$EXTERNAL_INPUTS_LOCKED" ]; then
    export EXTERNAL_INPUTS_LOCKED=1
    exec /usr/bin/lockf -k "$prefix.lock" /bin/sh "$script" "$prefix" "$downloads" "$lock"
fi

sha256() { /usr/bin/shasum -a 256 "$1" | cut -d' ' -f1; }

# "a >= b" for dotted versions.
version_at_least() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

# --- tools and SDK: checked on every build, since they can change under a stamp
entries() { sed -e 's/#.*//' "$lock" | awk -v kind="$1" '$1 == kind'; }

entries tool | while read -r _ name minimum _; do
    command -v "$name" >/dev/null 2>&1 || fail "$name is required (at least $minimum) and is not on PATH"
    found="$("$name" --version 2>/dev/null | head -1 | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1)"
    version_at_least "${found:-0}" "$minimum" || fail "$name $found is older than the declared minimum $minimum"
done

entries sdk | while read -r _ name minimum _; do
    found="${SDK_VERSION:-$(xcrun --sdk "$name" --show-sdk-version 2>/dev/null)}"
    version_at_least "${found:-0}" "$minimum" || fail "the $name SDK is ${found:-missing}; at least $minimum is required"
done

# Only the products managed by this resolver are recorded. Timestamps are not
# identity: headers, signed libraries, links and provenance must still match.
product_manifest() {
    python3 - "$1" "$2" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
manifest = root / '.products.json'
try:
    products = {}
    for name in ('include', 'lib', 'share'):
        directory = root / name
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError('missing product directory: ' + name)
        for parent, directories, files in os.walk(directory, followlinks=False):
            for entry in sorted(directories + files):
                path = Path(parent) / entry
                relative = str(path.relative_to(root))
                if path.is_symlink():
                    target = path.resolve(strict=True)
                    if not any(target.is_relative_to(root / tree) for tree in ('include', 'lib', 'share')):
                        raise ValueError('link outside the managed products: ' + relative)
                    products[relative] = ['link', os.readlink(path)]
                elif path.is_file():
                    products[relative] = ['sha256', hashlib.sha256(path.read_bytes()).hexdigest()]
                elif path.is_dir():
                    products[relative] = ['directory']
                else:
                    raise ValueError('invalid product: ' + relative)
    if not any(key.startswith('lib/') and key.endswith('.dylib') for key in products):
        raise ValueError('no staged libraries')
    if 'share/external-inputs.txt' not in products:
        raise ValueError('missing provenance record')
    if sys.argv[2] == 'write':
        manifest.write_text(json.dumps(products, sort_keys=True) + '\n')
    elif manifest.is_symlink() or json.loads(manifest.read_text()) != products:
        raise ValueError('staged products differ from the recorded identity')
except (OSError, ValueError, RuntimeError) as error:
    print('external inputs: invalid cache: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

# --- reuse only when both inputs and staged products still match
stamp="$( { cat "$lock" "$script"; printf '%s\n' "$prefix" "$ARCHS" "$MACOSX_DEPLOYMENT_TARGET"; } | /usr/bin/shasum -a 256 | cut -d' ' -f1)"
if [ -f "$prefix/.resolved" ] && [ "$(cat "$prefix/.resolved")" = "$stamp" ]; then
    if product_manifest "$prefix" check; then
        exit 0
    fi
    echo "external inputs: recovering staged products from verified bottles"
fi

work="$prefix.partial"
rm -rf "$work"
mkdir -p "$work/lib" "$work/include" "$work/share/licenses" "$downloads"
trap 'rm -rf "$work"' 0
bottles="$(entries bottle)"
[ -n "$bottles" ] || fail "$lock declares no bottle"

printf '%s\n' "$bottles" | while read -r _ name version tag digest use _; do
    printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$' || fail "$name: '$digest' is not a SHA-256"
    case "$use" in link|configure|runtime) ;; *) fail "$name: unknown use '$use'" ;; esac

    bottle="$downloads/$name--$version.$tag.bottle.tar.gz"
    if [ ! -f "$bottle" ] || [ "$(sha256 "$bottle")" != "$digest" ]; then
        rm -f "$bottle"
        # The public bottles need no account; this is the token Homebrew itself
        # sends. EXTERNAL_INPUTS_MIRROR can point at a copy with the same layout
        # (file:// works); the digest is checked the same way.
        repository="$(printf '%s' "$name" | sed 's|@|/|g')"
        url="${EXTERNAL_INPUTS_MIRROR:-https://ghcr.io/v2/homebrew/core}/$repository/blobs/sha256:$digest"
        echo "external inputs: fetching $name $version ($tag) from $url"
        /usr/bin/curl -fsSL --retry 3 --retry-all-errors --connect-timeout 30 --max-time 300 \
            -H 'Authorization: Bearer QQ==' "$url" -o "$bottle.part" || {
            rm -f "$bottle.part"
            fail "could not download $name $version. Place the bottle at $bottle (SHA-256 $digest) to build offline."
        }
        found="$(sha256 "$bottle.part")"
        if [ "$found" != "$digest" ]; then
            rm -f "$bottle.part"
            fail "$name $version: downloaded SHA-256 $found, declared $digest"
        fi
        mv "$bottle.part" "$bottle"
    fi

    extract="$work/.extract/$name"
    mkdir -p "$extract"
    tar -xzf "$bottle" -C "$extract"
    keg="$extract/$name/$version"
    [ -d "$keg/lib" ] || fail "$name: the bottle has no $name/$version/lib"
    [ -n "$(find "$keg/lib" -maxdepth 1 -type f -name '*.dylib' -print)" ] ||
        fail "$name: the bottle has no library products"

    # Symbolic links (libtiff.dylib -> libtiff.6.dylib) are kept as links.
    (cd "$keg/lib" && find . -maxdepth 1 -name '*.dylib' -exec cp -P {} "$work/lib/" \;)
    if [ "$use" != runtime ]; then
        [ -d "$keg/include" ] || fail "$name is declared '$use' but its bottle has no headers"
        [ -n "$(find "$keg/include" -type f -name '*.h' -print)" ] ||
            fail "$name: the bottle has no header products"
        cp -R "$keg/include/." "$work/include/"
    fi
    mkdir -p "$work/share/licenses/$name"
    find "$keg" -maxdepth 1 -type f \( -name 'LICENSE*' -o -name 'COPYING*' -o -name 'COPYRIGHT*' \) \
        -exec cp {} "$work/share/licenses/$name/" \;
    printf '%s %s %s %s %s\n' "$name" "$version" "$tag" "$digest" "$use" >> "$work/share/external-inputs.txt"
done
rm -rf "$work/.extract"

# --- rename, check and sign every staged library ------------------------------
for library in "$work"/lib/*.dylib; do
    [ -L "$library" ] && continue
    base="$(basename "$library")"
    chmod u+w "$library"
    # Keep the name the library is known by (libwebp.7.dylib), not the file's
    # (libwebp.7.2.0.dylib); the other libraries refer to it by that name.
    name="$(basename "$(/usr/bin/otool -D "$library" | tail -n 1)")"
    [ -e "$work/lib/$name" ] || fail "$base calls itself $name, which its bottle does not contain"
    /usr/bin/install_name_tool -id "$prefix/lib/$name" "$library" 2>/dev/null ||
        fail "could not rename $base"
    # The first line names the file, the second its own id.
    /usr/bin/otool -L "$library" | tail -n +3 | awk '{print $1}' | while read -r reference; do
        case "$reference" in
            /usr/lib/*|/System/*) ;;
            @@HOMEBREW_PREFIX@@/*|@@HOMEBREW_CELLAR@@/*|@rpath/*|@loader_path/*)
                target="$(basename "$reference")"
                [ -e "$work/lib/$target" ] || fail "$base links $reference, which external-inputs.lock does not declare"
                case "$reference" in @@*)
                    /usr/bin/install_name_tool -change "$reference" "$prefix/lib/$target" "$library" 2>/dev/null ||
                        fail "could not point $base at $target" ;;
                esac ;;
            *) fail "$base links $reference, outside the declared inputs and the macOS" ;;
        esac
    done
    for arch in ${ARCHS:-arm64}; do
        /usr/bin/lipo -archs "$library" | tr ' ' '\n' | grep -qx "$arch" || fail "$base has no $arch slice"
    done
    minos="$(/usr/bin/otool -l "$library" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
    if [ -n "$MACOSX_DEPLOYMENT_TARGET" ] && [ -n "$minos" ] && ! version_at_least "$MACOSX_DEPLOYMENT_TARGET" "$minos"; then
        fail "$base requires macOS $minos, above the deployment target $MACOSX_DEPLOYMENT_TARGET; pick a bottle tag for macOS $MACOSX_DEPLOYMENT_TARGET"
    fi
    /usr/bin/codesign --force --sign - "$library" 2>/dev/null || fail "could not sign $base"
done

product_manifest "$work" write || fail "could not validate staged products"
printf '%s\n' "$stamp" > "$work/.resolved"
# Keep the previous installation until the complete replacement can be moved.
previous="$prefix.previous"
[ ! -e "$previous" ] || fail "previous installation preserved at $previous; restore or remove it before retrying"
if [ -e "$prefix" ]; then
    mv "$prefix" "$previous"
fi
if ! mv "$work" "$prefix"; then
    [ ! -e "$previous" ] || mv "$previous" "$prefix"
    fail "could not publish staged products"
fi
rm -rf "$previous"
echo "external inputs: resolved into $prefix"

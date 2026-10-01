#!/bin/sh

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/Config"
install_dir="$TARGET_TEMP_DIR/Install"

installed_products_present() {
    for product in lib/libcrypto.a lib/libssl.a \
        include/openssl/ssl.h include/openssl/crypto.h include/openssl/opensslv.h \
        include/openssl/opensslconf.h include/openssl/configuration.h \
        include/openssl/bio.h include/openssl/err.h include/openssl/x509.h; do
        [ -s "$install_dir/$product" ] || return 1
    done
}

[ ! -e "$install_dir/.incomplete" ] && installed_products_present && exit 0

mkdir -p "$install_dir"
touch "$install_dir/.incomplete"

args=()
export MAKEFLAGS="-j $(sysctl -n hw.ncpu)"
export CC=clang
export CXX=clang
export COMMAND_MODE=unix2003

cd "$cmake_dir"
make "${args[@]}"
make install_sw

if ! installed_products_present; then
    echo "error: OpenSSL installation is missing required libraries or headers at $install_dir" >&2
    exit 1
fi
rm -f "$install_dir/.incomplete"

exit 0

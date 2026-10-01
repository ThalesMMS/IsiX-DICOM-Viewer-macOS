#!/bin/bash
# Build the host-owned file-print helper against the installed public DCMTK APIs.
set -euo pipefail
install_dir="$1"
openssl_dir="$2"
object_dir="$3"
output="$4"
architecture="$5"
deployment="$6"
configuration="$7"
root="$(cd "$(dirname "$0")/../../.." && pwd)"
sources="$root/DICOMPrint/Helper"
mkdir -p "$object_dir" "$(dirname "$output")"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
optimization=(-O)
cpp_optimization=(-O2)
if [ "$configuration" = Debug ]; then
    optimization=(-Onone -g)
    cpp_optimization=(-O0 -g)
fi
xcrun clang++ -std=c++11 -arch "$architecture" -isysroot "$sdk" \
    "-mmacosx-version-min=$deployment" "${cpp_optimization[@]}" \
    -I "$install_dir/include" -I "$openssl_dir/include" \
    -c "$sources/HorosStoredPrintBridge.mm" -o "$object_dir/StoredPrintBridge.o"
archives=()
for library in dcmpstat dcmdsig dcmsr dcmimage dcmimgle dcmqrdb dcmtls dcmiod dcmnet dcmdata oflog ofstd oficonv; do
    archives+=("$install_dir/lib/lib$library.a")
done
xcrun swiftc -sdk "$sdk" -target "$architecture-apple-macosx$deployment" \
    "${optimization[@]}" -import-objc-header "$sources/HorosStoredPrintBridge.h" \
    "$sources/main.swift" "$object_dir/StoredPrintBridge.o" "${archives[@]}" \
    "$openssl_dir/lib/libssl.a" "$openssl_dir/lib/libcrypto.a" \
    -Xlinker -lc++ -Xlinker -lxml2 -Xlinker -lz -Xlinker -liconv -o "$output"

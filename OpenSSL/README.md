# OpenSSL used by the Horos build

The build compiles OpenSSL **3.5.9 LTS** from the official release archive
`openssl-3.5.9.tar.gz`, declared in `Horos/Scripts/external-sources.json` with
its SHA-256 and the release commit `45e844fa2a14ec92d146bd8f5778ac130b6625fb`.
`Horos/Scripts/OpenSSL/Config.sh` obtains it through
`Horos/Scripts/external-inputs.sh --source OpenSSL`, which verifies the archive
and extracts it read-only beside the configuration's outputs.

The recipe builds in the configuration's disposable directory, with static
libraries and providers, without dynamic modules or engines. The ordinary app
build does not enable OpenSSL tests. The selected source record is part of the
OpenSSL and DCMTK configuration hashes, so upgrades invalidate both builds.

Verify the release archive signature (`openssl-3.5.9.tar.gz.asc`) using the
signing certificate published by OpenSSL, primary fingerprint
`B146647E45A7B33947AB226B2A2C87D161692D40`. The upstream Apache-2.0 license is
copied unchanged into `Binaries/Splash/OpenSSL-LICENSE.txt` and, with the
source record, into `Resources/CompiledSources/OpenSSL` of the application bundle.

The old flattened 1.1.1 source and unrelated external-test payloads have been
removed. Existing `.github` files are retained verbatim because GitHub
workflows are outside the current work's scope; they are not build inputs.
Original notices for those historical files remain in `LEGACY-LICENSE.txt`.
The obsolete root `pyca-cryptography/` implementation is also removed; that
directory retains only historical GitHub files, original licenses and a notice.

Run the replacement external test against the actual installed archives:

```sh
python3 tools/test-openssl-cryptography.py --configuration Debug
python3 tools/test-openssl-cryptography.py --configuration Release
```

The runner pins current pyca/Wycheproof sources, builds the Python binding
locally, checks static linkage and its OpenSSL runtime version, then executes
the upstream pytest suite. Use `--help` to inspect its options. OpenSSL's own
optional pyca external test, a submodule of the upstream repository that the
release archive omits, skips static builds. Use this runner for the static
configuration.

Provenance: [release and support lifecycle](https://www.openssl-library.org/source/),
[release tag](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9),
[signing certificates](https://www.openssl-library.org/source/pubkeys.asc).

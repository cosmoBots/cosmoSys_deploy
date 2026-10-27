# Retained LibreDWG toolchain

LibreDWG 0.14 is built **outside** the production Dockerfile, locally in a
Debian 13 amd64 container based on the same pinned Redmine image. The laptop
only needs Docker, curl, tar and sha256sum. No compiler installation on the
laptop and no LibreDWG compilation during an instance update are necessary.

From the deploy checkout:

```sh
sh scripts/build-libredwg.sh
# After reviewing the build and upstream test results, prepare the bundle:
sh scripts/build-libredwg.sh --package
```

The script retains all of the following (it never uses `docker run --rm`):

- image `cosmosys-toolchain-libredwg:0.14-debian13`;
- exited container `cosmosys-toolchain-libredwg-0.14`;
- archive, extracted sources, incremental build, output and logs under
  `../.local/toolchains/libredwg/0.14/` (relative to this repository);
- superseded builder containers, renamed with `-previous-<UTC timestamp>`.

Override `LIBREDWG_WORKSPACE` with an absolute path for a standalone deploy
checkout. Reusing a container mounted on a different workspace is refused.
Restarting the script reuses configure/make results; it does not remove the
sources or clean the build. Keep the workspace and Docker images when doing
general cache housekeeping if you want the exact toolchain preserved.

Only the official release tarball is accepted, with its SHA-256 pinned in the
recipe. The checksum is the recorded HTTPS download checksum, not a claim of
an independently verified upstream signature. Autotools regeneration is not
needed for this release archive. The separate builder installs build-essential,
binutils, file, pkg-config and xz-utils. Bindings and documentation are disabled;
the library is static, but the executable uses system libc/libm. `make check`
must succeed before packaging. Logs include configure, make, tests and exact
builder packages. `BUILDINFO` records the base/builder image and compiler.
The recipe links the source test-data directory into the out-of-tree build;
upstream's unit harness otherwise reports passes without finding its drawings.
Missing-fixture warnings are treated as a packaging failure.

`--package` copies the generated runtime binary, checksums, license, build
metadata and **complete unmodified corresponding source archive** into
`docker/tool-bundles/libredwg/`. These are release artifacts: review and commit
them together. Only amd64 has been built; CAD builds on other architectures
fail explicitly rather than installing an incompatible executable.

The production Dockerfile mounts the bundles read-only from its build context.
Only selected bundles are copied into the final image. For `cad`, the installer
checks hashes, installs `/usr/local/bin/dwg2dxf`, checks runtime linking, and
places license/metadata/source in `/usr/local/share/doc/libredwg/`. No compiler
or builder container is copied. Images without CAD receive none of these files.
Upstream copyright and GPLv3-or-later terms remain unchanged; this is a
separately packaged external tool, not code added to the CAD viewer fork.

## Updating the tool

1. Select and inspect a new official release. Update the version, URL and
   checksum in the scripts, and use a **new** workspace/image/container name.
   Keep the previous version until the replacement is validated.
2. Rebuild on the target distribution/architecture; inspect `file`, `ldd`,
   `readelf`, test logs and actual DWG conversions. Do not copy a binary built
   directly on the laptop's Ubuntu installation into the Debian image.
3. Review `BUILDINFO`, `COPYING`, complete source and `SHA256SUMS` together.
   If patches become necessary, include them and the complete build recipe as
   corresponding source; do not silently retain the unmodified-source claim.
4. Stage the generated bundle **before** regenerating image tags (the image
   hash uses tracked files). Follow `scripts/update-pins.sh`,
   `scripts/check-config.sh`, `scripts/validate-deployment.sh all` and
   `scripts/validate-update.sh`, then the normal publication/update procedure.

The bundle also contains `sample_2000.dwg`, copied unchanged from the source
archive's `test/test-data/` directory. This lets the deploy check convert a real
DWG through the plugin's own `DwgConverter` without adding an xz runtime tool
merely to unpack a fixture. A successful
fixture does not guarantee support for every DWG revision/entity: LibreDWG's
format limitations, conversion timeout and the viewer's 2D-only DXF rendering
still apply. Saved report figures still require an explicitly saved view.

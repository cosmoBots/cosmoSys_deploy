#!/bin/sh
set -eu
bundle_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
case "$(dpkg --print-architecture)" in
  amd64) ;;
  *) echo 'The CAD LibreDWG bundle currently supports Debian 13 amd64 only.' >&2; exit 1 ;;
esac
cd "$bundle_dir"
sha256sum -c SHA256SUMS
install -m 755 dwg2dxf /usr/local/bin/dwg2dxf
install -d /usr/local/share/doc/libredwg
install -m 644 COPYING BUILDINFO libredwg-0.14.tar.xz sample_2000.dwg /usr/local/share/doc/libredwg/
dwg2dxf --version
# Static libredwg, system libc/libm only. Fail on a missing runtime library.
ldd /usr/local/bin/dwg2dxf
if ldd /usr/local/bin/dwg2dxf | grep -q 'not found'; then
  echo 'LibreDWG has unresolved runtime dependencies' >&2; exit 1
fi

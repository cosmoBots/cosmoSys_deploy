#!/bin/sh
set -eu
cd /work
mkdir -p build output logs
source_archive=downloads/libredwg-0.14.tar.xz
echo "62ebb73b984f865960f20ed26619ea5f8789d5e3fd088fa40a2598384da81275  $source_archive" | sha256sum -c -
[ -d libredwg-0.14 ] || tar -xf "$source_archive"
cd build
if [ ! -f Makefile ]; then
  ../libredwg-0.14/configure --prefix=/usr/local --enable-release \
    --disable-bindings --disable-python --disable-docs \
    --disable-shared --enable-static CFLAGS='-O2 -g0' >../logs/configure.log 2>&1
fi
make -j2 >../logs/make.log 2>&1
# Upstream's unit harness uses ../test-data rather than top_srcdir when
# building out-of-tree. Without this link it reports PASS without reading DWG.
[ -e test/test-data ] || ln -s /work/libredwg-0.14/test/test-data test/test-data
make check -j2 >../logs/check.log 2>&1
if grep -q 'Env var INPUT not defined, .* not found' ../logs/check.log; then
  echo 'Upstream tests did not find their DWG fixtures; refusing to package.' >&2
  exit 1
fi
cp programs/dwg2dxf ../output/dwg2dxf
strip ../output/dwg2dxf
../output/dwg2dxf --version
file ../output/dwg2dxf
ldd ../output/dwg2dxf
cp ../libredwg-0.14/COPYING ../output/COPYING
cp "../$source_archive" ../output/libredwg-0.14.tar.xz
cp ../libredwg-0.14/test/test-data/sample_2000.dwg ../output/sample_2000.dwg
{
  printf 'Tool: LibreDWG\nVersion: 0.14\nSource: https://ftp.gnu.org/gnu/libredwg/libredwg-0.14.tar.xz\n'
  printf 'Source SHA256: 62ebb73b984f865960f20ed26619ea5f8789d5e3fd088fa40a2598384da81275\n'
  printf 'Base: %s\nBuilder image: %s\n' "$LIBREDWG_BASE_IMAGE" "$LIBREDWG_BUILDER_IMAGE"
  printf 'Architecture: %s\n' "$(dpkg --print-architecture)"
  cc --version | head -n 1
  printf 'Configure: --prefix=/usr/local --enable-release --disable-bindings --disable-python --disable-docs --disable-shared --enable-static CFLAGS=-O2,-g0\n'
  printf 'Unmodified upstream source; static libredwg, dynamic system libc/libm.\n'
  printf 'Separate retained builder; no LibreDWG compilation in production Dockerfile.\n'
} >../output/BUILDINFO
(cd ../output && sha256sum dwg2dxf COPYING BUILDINFO libredwg-0.14.tar.xz sample_2000.dwg >SHA256SUMS)
cp config.log ../logs/config.log
dpkg-query -W >../logs/builder-packages.tsv
sha256sum ../output/dwg2dxf

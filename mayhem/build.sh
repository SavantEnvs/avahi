#!/usr/bin/env bash
#
# mayhem/build.sh — build avahi's sanitized fuzz harnesses (+ standalone reproducers) and the
# upstream unit tests (normal flags). Runs in /mayhem as `mayhem`; idempotent and offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

CONFIGURE_ARGS=(
  --disable-stack-protector --disable-qt3 --disable-qt4 --disable-qt5 --disable-gtk
  --disable-gtk3 --disable-dbus --disable-gdbm --disable-libdaemon --disable-python
  --disable-manpages --disable-mono --disable-monodoc --disable-glib --disable-gobject
  --disable-libevent --disable-libsystemd --with-distro=none
  --disable-shared --enable-static
)

# Generated files (configure, Makefile.in, ...) are gitignored upstream, so regenerate them every run.
autoreconf -ivf >/dev/null 2>&1
# acx_pthread's GCC pthread/shared "inconsistency" probe rejects sanitizer flags; upstream's own
# oss-fuzz build disables it the same way (here in the generated, untracked configure).
sed -i 's/check_inconsistencies=yes/check_inconsistencies=no/' configure

# 1) Sanitized project build (libavahi-core.a / libavahi-common.a) for the fuzz harnesses.
#    fuzzer-no-link gives the project objects libFuzzer coverage instrumentation.
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
BF="$SRC/mayhem/build-fuzz"
rm -rf "$BF"; mkdir -p "$BF"
( cd "$BF" && "$SRC/configure" "${CONFIGURE_ARGS[@]}" CC="$CC" CXX="$CXX" CFLAGS="$FUZZ_CFLAGS" CXXFLAGS="$FUZZ_CFLAGS" LDFLAGS="$SANITIZER_FLAGS" >/dev/null \
  && make -j"$MAYHEM_JOBS" -C avahi-common libavahi-common.la V=0 \
  && make -j"$MAYHEM_JOBS" -C avahi-core libavahi-core.la V=0 )

# 2) Harnesses: each linked twice (libFuzzer + run-once standalone driver), LSan off.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
LIBS=("$BF/avahi-core/.libs/libavahi-core.a" "$BF/avahi-common/.libs/libavahi-common.a")
for f in fuzz/fuzz-*.c; do
  t=$(basename "$f" .c)
  extra=()
  $CC -c $FUZZ_CFLAGS -I"$SRC" -I"$BF" "$f" -o "/tmp/$t.o"
  if [ "$t" = fuzz-ini-file-parser ]; then
    $CC -c $FUZZ_CFLAGS -I"$SRC" -I"$BF" -DHAVE_CONFIG_H avahi-daemon/ini-file-parser.c -o /tmp/ini-file-parser.o
    extra=(/tmp/ini-file-parser.o)
  fi
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "/tmp/$t.o" "${extra[@]}" /tmp/lsan_off.o $LIB_FUZZING_ENGINE "${LIBS[@]}" -o "$SRC/$t"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "/tmp/$t.o" "${extra[@]}" /tmp/lsan_off.o /tmp/standalone_main.o "${LIBS[@]}" -o "$SRC/$t-standalone"
done

# 3) Upstream unit tests with the project's NORMAL flags (independent build; test.sh only runs them).
BT="$SRC/mayhem/build-test"
rm -rf "$BT"; mkdir -p "$BT"
( cd "$BT" && env -u CFLAGS -u LDFLAGS -u CXXFLAGS "$SRC/configure" "${CONFIGURE_ARGS[@]}" --enable-tests CC="$CC" CXX="$CXX" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" >/dev/null \
  && make -j"$MAYHEM_JOBS" -C avahi-common V=0 \
  && make -j"$MAYHEM_JOBS" -C avahi-core V=0 )

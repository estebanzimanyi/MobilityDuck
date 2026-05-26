vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO estebanzimanyi/MobilityDB
    # MobilityDB accumulate/parity-1.4 tip (PR #22) — carries the h3indexset
    # static-geometry API (geo_to_h3index_set, ever_eq_anyof_h3indexset_th3index)
    # and the extended-type C API (tcbuffer_from_mfjson, …) that the older
    # dfdd2554 pin lacked.
    REF bb659c69381a1d44ea6c9cfd32207cdae8f80f3a
    SHA512 15e635cef54845a3b2f1d03c568cbbafa26cf8b27a4f47ec1a5d6f61597ff83f3485dc12a0dd61dcb56afd924889f2e8ac0f02e0dc19bf8609d2e89dbaa9aae9
)

vcpkg_replace_string(
    "${SOURCE_PATH}/postgres/utils/CMakeLists.txt"
    "set_property(TARGET utils PROPERTY POSITION_INDEPENDENT_CODE ON)"
    [=[
set_property(TARGET utils PROPERTY POSITION_INDEPENDENT_CODE ON)

if(MEOS)
  target_include_directories(utils PRIVATE "${CMAKE_SOURCE_DIR}/meos/include")
endif()
]=]
)

# Upstream gap at commit beddae670: `meos/include/h3/th3index_internal.h`
# does `#include <fmgr.h>` unconditionally.  `fmgr.h` is a PG-internal
# header and is not bundled in MEOS's `postgres/` subtree, so the
# standalone MEOS build of `meos/src/h3/h3index.c` fails with
# `fatal error: fmgr.h: No such file or directory`.  Guard the
# include with `#if !MEOS`, mirroring the same idiom already used by
# `meos/include/temporal/temporal.h`.
vcpkg_replace_string(
    "${SOURCE_PATH}/meos/include/h3/th3index_internal.h"
    [=[
#include <postgres.h>
#include <fmgr.h>
]=]
    [=[
#include <postgres.h>
#if ! MEOS
#include <fmgr.h>
#endif
]=]
)

# Upstream gap at commit beddae670: `meos/CMakeLists.txt` builds the
# `h3` OBJECT library (via `add_subdirectory(h3)` + `add_library`)
# but the `PROJECT_OBJECTS` list that feeds the final
# `add_library(meos ${PROJECT_OBJECTS})` lists every other optional
# family (cbuffer / npoint / pose / rgeo) and silently omits `h3`.
# Without this injection libmeos ships without H3 symbols, so any
# consumer linking against `meos` sees ~120 `undefined reference to
# 'th3index_*'` link errors.
vcpkg_replace_string(
    "${SOURCE_PATH}/meos/CMakeLists.txt"
    [=[if(RGEO)
  message(STATUS "Including rigid geometries")
  set(PROJECT_OBJECTS ${PROJECT_OBJECTS} "$<TARGET_OBJECTS:rgeo>")
endif()]=]
    [=[if(RGEO)
  message(STATUS "Including rigid geometries")
  set(PROJECT_OBJECTS ${PROJECT_OBJECTS} "$<TARGET_OBJECTS:rgeo>")
endif()
if(H3)
  message(STATUS "Including temporal H3 index (th3index)")
  set(PROJECT_OBJECTS ${PROJECT_OBJECTS} "$<TARGET_OBJECTS:h3>")
endif()]=]
)

# Upstream gap at commit beddae670: `meos/CMakeLists.txt` carries
# `install()` rules for `meos_npoint.h` / `meos_pose.h` /
# `meos_rgeo.h` / `meos_cbuffer.h` but no rule for `meos_h3.h`.
# Without it the H3 public header is missing from the installed
# `include/` directory, so any consumer of `#include <meos_h3.h>`
# fails to compile.
vcpkg_replace_string(
    "${SOURCE_PATH}/meos/CMakeLists.txt"
    [=[if(RGEO)
  install(
    FILES "${CMAKE_SOURCE_DIR}/meos/include/meos_rgeo.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
endif()]=]
    [=[if(RGEO)
  install(
    FILES "${CMAKE_SOURCE_DIR}/meos/include/meos_rgeo.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
endif()
if(H3)
  install(
    FILES "${CMAKE_SOURCE_DIR}/meos/include/meos_h3.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
endif()]=]
)

# Upstream gap at commit beddae670: the h3-side source files call
# `ensure_srid_is_latlong()` (declared in
# `meos/include/geo/tgeo_spatialfuncs.h`) without including that
# header, yielding implicit-declaration errors under `MEOS=1`.
foreach(_h3_src
        meos/src/h3/h3_geo.c
        meos/src/h3/th3index_latlng.c
        meos/src/h3/th3index_metrics.c)
    if(EXISTS "${SOURCE_PATH}/${_h3_src}")
        vcpkg_replace_string(
            "${SOURCE_PATH}/${_h3_src}"
            "#include <meos_internal_geo.h>"
            [=[
#include <meos_internal_geo.h>

#include "geo/tgeo_spatialfuncs.h"
]=]
        )
    endif()
endforeach()

# vcpkg installs h3 at the per-triplet
# `installed/<triplet>/{lib,include/h3}` layout, but MEOS's own
# `find_library(NAMES h3)` / `find_path(NAMES h3api.h PATH_SUFFIXES h3)`
# does not consult vcpkg's CMAKE_PREFIX_PATH on every triplet
# (notably `arm64-linux-release`).  Pass the resolved paths explicitly.
set(_meos_h3_lib_candidates
    "${CURRENT_INSTALLED_DIR}/lib/libh3.a"
    "${CURRENT_INSTALLED_DIR}/lib/libh3.so"
    "${CURRENT_INSTALLED_DIR}/lib/libh3${CMAKE_STATIC_LIBRARY_SUFFIX}"
    "${CURRENT_INSTALLED_DIR}/lib/libh3${CMAKE_SHARED_LIBRARY_SUFFIX}")
set(_MEOS_H3_LIB "")
foreach(_cand IN LISTS _meos_h3_lib_candidates)
    if(EXISTS "${_cand}")
        set(_MEOS_H3_LIB "${_cand}")
        break()
    endif()
endforeach()
if(NOT _MEOS_H3_LIB)
    message(FATAL_ERROR "MEOS port: cannot locate vcpkg-installed libh3 under ${CURRENT_INSTALLED_DIR}/lib")
endif()
# h3's header lands at `include/h3/h3api.h` (subdirectory).  MEOS
# source uses `#include <h3api.h>` so the include path must point
# at `include/h3`.
set(_MEOS_H3_INC_CANDIDATES
    "${CURRENT_INSTALLED_DIR}/include/h3"
    "${CURRENT_INSTALLED_DIR}/include")
set(_MEOS_H3_INC "")
foreach(_cand IN LISTS _MEOS_H3_INC_CANDIDATES)
    if(EXISTS "${_cand}/h3api.h")
        set(_MEOS_H3_INC "${_cand}")
        break()
    endif()
endforeach()
if(NOT _MEOS_H3_INC)
    message(FATAL_ERROR "MEOS port: cannot locate vcpkg-installed h3api.h under ${CURRENT_INSTALLED_DIR}/include or ${CURRENT_INSTALLED_DIR}/include/h3")
endif()

# Upstream MEOS-standalone gap: meos/include/pointcloud/{pcpoint,pcpatch}.h
# define DatumGetPcpointP / DatumGetPcpatchP via PG_DETOAST_DATUM
# UNCONDITIONALLY, unlike every other type header (temporal.h etc.) which
# uses `((T *) DatumGetPointer(X))` under `#if MEOS`. PG_DETOAST_DATUM lives
# only in PostgreSQL's fmgr.h (not bundled for MEOS), so libmeos built with
# -DPOINTCLOUD=ON has unresolved `PG_DETOAST_DATUM` at link. Mirror the MEOS
# branch (MEOS values are never TOASTed). FIX UPSTREAM: add the #if MEOS guard.
vcpkg_replace_string(
    "${SOURCE_PATH}/meos/include/pointcloud/pcpoint.h"
    "((Pcpoint *) PG_DETOAST_DATUM(X))"
    "((Pcpoint *) DatumGetPointer(X))"
)
vcpkg_replace_string(
    "${SOURCE_PATH}/meos/include/pointcloud/pcpatch.h"
    "((Pcpatch *) PG_DETOAST_DATUM(X))"
    "((Pcpatch *) DatumGetPointer(X))"
)

# pgPointCloud enabler. -DPOINTCLOUD=ON makes meos/src/pointcloud/
# CMakeLists.txt FATAL_ERROR unless pointcloud-pg/lib/libpc.a exists; it is
# built as a side effect of pgPointCloud's `./autogen.sh && ./configure &&
# make`, which cannot run here (no autotools-usable PostgreSQL, no pg_config).
# The vendored pointcloud-pg/lib sources need only libxml2 and zlib (no
# PostgreSQL headers), and pointcloud-pg/lib/Makefile builds libpc.a directly
# via `ar rs` with the XML2/ZLIB CPPFLAGS from config.mk. So we generate
# config.mk + lib/pc_config.h the way pgPointCloud's autotools would (filling
# only the @VARS@ the lib OBJS consume, with vcpkg's libxml2/zlib paths), then
# build the libpc.a archive target directly. CUnit/LazPerf stay disabled.
set(POINTCLOUD_DIR "${SOURCE_PATH}/pointcloud-pg")

file(WRITE "${POINTCLOUD_DIR}/config.mk"
"CC = cc
CFLAGS = -O2 -fPIC
CXXFLAGS += -fPIC -std=c++0x
SQLPP =

XML2_CPPFLAGS = -I${CURRENT_INSTALLED_DIR}/include/libxml2
XML2_LDFLAGS = -L${CURRENT_INSTALLED_DIR}/lib -lxml2

ZLIB_CPPFLAGS = -I${CURRENT_INSTALLED_DIR}/include
ZLIB_LDFLAGS = -L${CURRENT_INSTALLED_DIR}/lib -lz

CUNIT_CPPFLAGS =
CUNIT_LDFLAGS =

PG_CONFIG =
PGXS =

LIB_A = libpc.a
LIB_A_LAZPERF = liblazperf.a

LAZPERF_STATUS = disabled
LAZPERF_CPPFLAGS =

PGSQL_MAJOR_VERSION =
")

# lib/pc_config.h: pc_api.h does `#include \"pc_config.h\"`, normally emitted
# by config.status. Mirror the no-lazperf / no-cunit autotools output (leave
# HAVE_LAZPERF / HAVE_CUNIT undefined). POINTCLOUD_VERSION = Version.config.
file(WRITE "${POINTCLOUD_DIR}/lib/pc_config.h"
"/* #undef LIBXML2_VERSION */

/* #undef PGSQL_VERSION */

/* #undef HAVE_LAZPERF */

/* #undef HAVE_CUNIT */

#define PROJECT_SOURCE_DIR \"${POINTCLOUD_DIR}\"

#define POINTCLOUD_VERSION \"1.2.5\"
")

# Build the libpc.a archive target directly (NOT `all`, which recurses into
# cunit/ and needs CUnit). config.mk is included by lib/Makefile.
vcpkg_execute_required_process(
    COMMAND make -C "${POINTCLOUD_DIR}/lib" libpc.a
    WORKING_DIRECTORY "${POINTCLOUD_DIR}/lib"
    LOGNAME "build-libpc-${TARGET_TRIPLET}"
)

# pgPointCloud's lib/stringbuffer.c is a verbatim fork of PostGIS
# liblwgeom/stringbuffer.c. MEOS already bundles liblwgeom (incl. its
# stringbuffer.c) into libmeos, so carrying pgPointCloud's copy makes the
# final static link fail with `multiple definition of stringbuffer_*`.
# Rename every stringbuffer_* symbol in libpc.a (definitions and the
# cross-object references) into a private pc_stringbuffer_* namespace so
# libpc.a resolves them against its own copy and never collides.
vcpkg_execute_required_process(
    COMMAND ${CMAKE_COMMAND} -E env bash -c
        "set -e
         cd '${POINTCLOUD_DIR}/lib'
         : > redefine.map
         for s in $(nm libpc.a 2>/dev/null | awk '$NF ~ /^stringbuffer_/ {print $NF}' | sort -u); do
           echo \"$s pc_$s\" >> redefine.map
         done
         tmp=$(mktemp -d)
         cd \"$tmp\"
         ar x '${POINTCLOUD_DIR}/lib/libpc.a'
         for o in *.o; do
           objcopy --redefine-syms='${POINTCLOUD_DIR}/lib/redefine.map' \"$o\"
         done
         rm -f '${POINTCLOUD_DIR}/lib/libpc.a'
         ar rcs '${POINTCLOUD_DIR}/lib/libpc.a' *.o
         cd /
         rm -rf \"$tmp\" '${POINTCLOUD_DIR}/lib/redefine.map'"
    WORKING_DIRECTORY "${POINTCLOUD_DIR}/lib"
    LOGNAME "namespace-libpc-stringbuffer-${TARGET_TRIPLET}"
)

# meos/src/pointcloud/CMakeLists.txt checks exactly this path.
if(NOT EXISTS "${POINTCLOUD_DIR}/lib/libpc.a")
    message(FATAL_ERROR
        "pgPointCloud enabler failed: ${POINTCLOUD_DIR}/lib/libpc.a "
        "was not produced by the libpc.a make target.")
endif()

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DMEOS=ON
        # Opt-in MEOS modules required to port the extended temporal types
        # (tcbuffer, tnpoint, tpose, trgeometry) into MobilityDuck. RGEO is a
        # dependent option that requires POSE.
        -DCBUFFER=ON
        -DNPOINT=ON
        -DPOSE=ON
        -DRGEO=ON
        -DPOINTCLOUD=ON
        -DH3=ON
        "-DH3_LIBRARY=${_MEOS_H3_LIB}"
        "-DH3_INCLUDE_DIR=${_MEOS_H3_INC}"
        -DBUILD_SHARED_LIBS=ON
        -DCMAKE_C_FLAGS="-Dsession_timezone=meos_session_timezone"
        -DCMAKE_CXX_FLAGS="-Dsession_timezone=meos_session_timezone"
)

vcpkg_cmake_build(TARGET all)
vcpkg_cmake_install()

# meos/src/pointcloud/CMakeLists.txt links libpc.a into the `pointcloud`
# OBJECT library as a usage requirement only: the static libmeos.a does not
# absorb libpc.a's objects nor carry a link interface, so a consumer linking
# libmeos.a sees unresolved pc_point_get_x/y/z/... . Install libpc.a alongside
# libmeos.a and propagate it (+ libxml2 / zlib) through MEOS::meos's
# INTERFACE_LINK_LIBRARIES so the extension link resolves the pgPointCloud
# symbols.
file(INSTALL "${SOURCE_PATH}/pointcloud-pg/lib/libpc.a"
     DESTINATION "${CURRENT_PACKAGES_DIR}/lib")

file(MAKE_DIRECTORY "${CURRENT_PACKAGES_DIR}/share/meos")
file(WRITE "${CURRENT_PACKAGES_DIR}/share/meos/MEOSConfig.cmake" [=[
# Minimal imported target for MEOS
if (NOT TARGET MEOS::meos)
  add_library(MEOS::meos UNKNOWN IMPORTED)
  # Look for the library in vcpkg's lib folders
  foreach(_cand meos libmeos)
    if (EXISTS "${CMAKE_CURRENT_LIST_DIR}/../../lib/${_cand}.lib")
      set(_meos_lib "${CMAKE_CURRENT_LIST_DIR}/../../lib/${_cand}.lib")
    elseif (EXISTS "${CMAKE_CURRENT_LIST_DIR}/../../lib/${_cand}.a")
      set(_meos_lib "${CMAKE_CURRENT_LIST_DIR}/../../lib/${_cand}.a")
    elseif (EXISTS "${CMAKE_CURRENT_LIST_DIR}/../../lib/${_cand}.so")
      set(_meos_lib "${CMAKE_CURRENT_LIST_DIR}/../../lib/${_cand}.so")
    elseif (EXISTS "${CMAKE_CURRENT_LIST_DIR}/../../lib/${_cand}.dylib")
      set(_meos_lib "${CMAKE_CURRENT_LIST_DIR}/../../lib/${_cand}.dylib")
    endif()
  endforeach()
  if (NOT _meos_lib)
    message(FATAL_ERROR "MEOS library not found in vcpkg package layout.")
  endif()
  set_target_properties(MEOS::meos PROPERTIES
    IMPORTED_LOCATION "${_meos_lib}"
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/../../include"
  )
  # When MEOS was built with -DPOINTCLOUD=ON, libmeos.a calls into the
  # pgPointCloud archive libpc.a (and libxml2 / zlib). The static libmeos.a
  # does not carry that link interface, so propagate it here.
  set(_meos_libdir "${CMAKE_CURRENT_LIST_DIR}/../../lib")
  if (EXISTS "${_meos_libdir}/libpc.a")
    set(_meos_pc_iface "${_meos_libdir}/libpc.a")
    file(GLOB _meos_xml2 "${_meos_libdir}/libxml2.a" "${_meos_libdir}/libxml2.lib")
    file(GLOB _meos_zlib "${_meos_libdir}/libz.a" "${_meos_libdir}/libzlib.a" "${_meos_libdir}/zlib.lib")
    if (_meos_xml2)
      list(APPEND _meos_pc_iface ${_meos_xml2})
    endif()
    if (_meos_zlib)
      list(APPEND _meos_pc_iface ${_meos_zlib})
    endif()
    set_target_properties(MEOS::meos PROPERTIES
      INTERFACE_LINK_LIBRARIES "${_meos_pc_iface}"
    )
  endif()
endif()
]=])

file(WRITE "${CURRENT_PACKAGES_DIR}/share/meos/usage" [=[
MEOS installed.

CMake:
  find_package(MEOS CONFIG REQUIRED)
  target_link_libraries(your_target PRIVATE MEOS::meos)
]=])

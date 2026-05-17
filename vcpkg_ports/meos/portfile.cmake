# TEMPORARY PROVISIONAL PIN. The extended-type ports are clean clones
# that bind the per-type I/O: the tcbuffer / tnpoint MF-JSON support
# (MobilityDB PRs #1051 and #951), the tpose surface, and the renamed
# trgeometry_* C API (the MobilityDB API-uniformization PRs #1066 /
# #1067 / #1069 that promote trgeo_in / trgeo_from_mfjson / trgeo_out
# to exported trgeometry_in / trgeometry_from_mfjson / trgeometry_out)
# are not all on MobilityDB/MobilityDB master yet, so the pin points at
# the verified integration branch on the contributor fork that composes
# them on top of MobilityDB master: estebanzimanyi/MobilityDB
# meos-provisional-6type-base-session @
# 3af4cb895c92446fa052c90a4ab22cf2c9e96c4a ("Rename the trgeometry
# distance and comparison functions for cross-type API uniformity").
# This base exposes all six extended types' MEOS surface (tcbuffer and
# tnpoint MF-JSON, tpose, the renamed trgeometry_*, and the tpcpoint /
# tpcpatch base). This is provisional pending the #134 -> #145
# MobilityDuck chain plus the MF-JSON and trgeometry-rename PRs merging
# into MobilityDB master.
#
# Flip-to-merged-master recipe (apply once the MF-JSON and the
# trgeometry-rename PRs are merged AND #145 has landed): set REPO back
# to MobilityDB/MobilityDB, set REF to the merged master commit that
# includes all of those changes, and recompute
#   curl -sL https://github.com/MobilityDB/MobilityDB/archive/<sha>.tar.gz | sha512sum
# for SHA512. Then delete this comment block. The OPTIONS below (the #145
# CBUFFER/NPOINT/POSE/RGEO enablers) are unchanged by this pin and compose
# with any REPO/REF/SHA512.
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO estebanzimanyi/MobilityDB
    REF 3af4cb895c92446fa052c90a4ab22cf2c9e96c4a
    SHA512 381a7a50f587d66bb8b2dc19253cf78ca3b975ab23285a953b4367f118719a3b679a7a53a6f821ee1d1f5d2cb849d8aef822edfc69e8331ebfe5fb1685b6d6fc
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
        -DBUILD_SHARED_LIBS=ON
        -DCMAKE_C_FLAGS="-Dsession_timezone=meos_session_timezone"
        -DCMAKE_CXX_FLAGS="-Dsession_timezone=meos_session_timezone"

)

vcpkg_cmake_build(TARGET all)
vcpkg_cmake_install()

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
endif()
]=])

file(WRITE "${CURRENT_PACKAGES_DIR}/share/meos/usage" [=[
MEOS installed.

CMake:
  find_package(MEOS CONFIG REQUIRED)
  target_link_libraries(your_target PRIVATE MEOS::meos)
]=])

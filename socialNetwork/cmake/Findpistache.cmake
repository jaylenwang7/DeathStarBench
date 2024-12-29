# cmake/FindPistache.cmake
find_path(PISTACHE_INCLUDE_DIR
    NAMES pistache/endpoint.h
    PATHS /usr/include
          /usr/local/include
)

find_library(PISTACHE_LIBRARY
    NAMES libpistache.a pistache
    PATHS /usr/lib
          /usr/local/lib
)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(Pistache
    DEFAULT_MSG
    PISTACHE_INCLUDE_DIR
    PISTACHE_LIBRARY
)

if(PISTACHE_FOUND)
    set(PISTACHE_LIBRARIES ${PISTACHE_LIBRARY})
    set(PISTACHE_INCLUDE_DIRS ${PISTACHE_INCLUDE_DIR})
endif()

mark_as_advanced(PISTACHE_INCLUDE_DIR PISTACHE_LIBRARY)
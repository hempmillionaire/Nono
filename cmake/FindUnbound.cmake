# Copyright (c) 2014-2024, The Monero Project
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without modification, are
# permitted provided that the following conditions are met:
# 
# 1. Redistributions of source code must retain the above copyright notice, this list of
#    conditions and the following disclaimer.
# 
# 2. Redistributions in binary form must reproduce the above copyright notice, this list
#    of conditions and the following disclaimer in the documentation and/or other
#    materials provided with the distribution.
# 
# 3. Neither the name of the copyright holder nor the names of its contributors may be
#    used to endorse or promote products derived from this software without specific
#    prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
# THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
# THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

FIND_PATH(UNBOUND_INCLUDE_DIR
  NAMES unbound.h
  PATH_SUFFIXES include/ include/unbound/
  PATHS "${PROJECT_SOURCE_DIR}"
  ${UNBOUND_ROOT}
  $ENV{UNBOUND_ROOT}
  /usr/local/
  /usr/
)

find_library(UNBOUND_LIBRARIES unbound)

find_package_handle_standard_args(Unbound
        REQUIRED_VARS
        UNBOUND_LIBRARIES
        UNBOUND_INCLUDE_DIR
)

add_library(unbound UNKNOWN IMPORTED)

set_target_properties(unbound PROPERTIES
        IMPORTED_LOCATION ${UNBOUND_LIBRARIES}
        INTERFACE_INCLUDE_DIRECTORIES ${UNBOUND_INCLUDE_DIR}
        IMPORTED_LINK_INTERFACE_LANGUAGES "C"
)

# When libunbound is a static archive it does NOT carry its own transitive
# deps, so consumers that link it must also link libevent (libunbound's
# ub_event_pluggable.o references event_set / event_base_*). Distros that
# ship libunbound built against libevent (Debian/Ubuntu's libunbound-dev)
# need this even though the .so case is fine without it.
get_filename_component(_unbound_ext "${UNBOUND_LIBRARIES}" EXT)
if(_unbound_ext STREQUAL ".a" OR STATIC)
    find_library(EVENT_LIBRARY event)
    if(EVENT_LIBRARY)
        message(STATUS "Linking libevent (${EVENT_LIBRARY}) into static unbound target")
        # INTERFACE_LINK_LIBRARIES is appended after IMPORTED_LOCATION on the
        # link line, so order is `unbound event` -- exactly what the static
        # archive needs.
        set_property(TARGET unbound APPEND PROPERTY
            INTERFACE_LINK_LIBRARIES "${EVENT_LIBRARY}")
    else()
        message(WARNING "libunbound looks static but libevent was not found; expect undefined event_* symbols at link time. Install libevent-dev.")
    endif()
endif()
unset(_unbound_ext)

if(MINGW)
    target_link_libraries(unbound INTERFACE "iphlpapi;ws2_32;crypt32")
endif()

# VTK is linked statically into the host, whose plugins use its C++ interfaces.
# Apply visibility after upstream has created the targets, without changing its
# defaults for other builds or introducing a second rendering backend.
if (CMAKE_VERSION VERSION_LESS 3.19)
  message(FATAL_ERROR "The VTK host hook requires CMake 3.19 or newer (DEFER).")
endif ()

function(horos_vtk_configure_targets directory)
  get_property(targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach (target IN LISTS targets)
    get_target_property(kind "${target}" TYPE)
    if (NOT kind STREQUAL "INTERFACE_LIBRARY" AND NOT kind STREQUAL "UTILITY")
      set_target_properties("${target}" PROPERTIES
        CXX_VISIBILITY_PRESET default
        VISIBILITY_INLINES_HIDDEN OFF)
    endif ()
  endforeach ()
  get_property(children DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
  foreach (child IN LISTS children)
    horos_vtk_configure_targets("${child}")
  endforeach ()
endfunction()

function(horos_vtk_finalize)
  if (NOT TARGET VTK::CommonCore)
    message(FATAL_ERROR "The VTK host hook requires VTK::CommonCore.")
  endif ()
  get_target_property(core VTK::CommonCore ALIASED_TARGET)
  if (NOT core)
    set(core VTK::CommonCore)
  endif ()
  get_target_property(kind "${core}" TYPE)
  horos_vtk_configure_targets("${VTK_SOURCE_DIR}")

  # This interface has only inline methods. Keep its header/file set intact;
  # omit its translation unit only in the host's existing Apple static build.
  # Other CommonCore units retain the reference-counted SystemTools manager.
  if (APPLE AND NOT BUILD_SHARED_LIBS AND NOT VTK_ENABLE_WRAPPING)
    if (NOT kind STREQUAL "STATIC_LIBRARY")
      message(FATAL_ERROR "Expected static VTK::CommonCore for the host build.")
    endif ()
    get_target_property(sources "${core}" SOURCES)
    set(filtered "${sources}")
    list(FILTER filtered EXCLUDE REGEX "(^|/)vtkAbstractBuffer[.]cxx$")
    list(LENGTH sources before)
    list(LENGTH filtered after)
    math(EXPR removed "${before} - ${after}")
    if (NOT removed EQUAL 1 OR NOT EXISTS "${VTK_SOURCE_DIR}/Common/Core/vtkAbstractBuffer.h")
      message(FATAL_ERROR "Unexpected VTK abstract buffer source/header layout.")
    endif ()
    set_property(TARGET "${core}" PROPERTY SOURCES "${filtered}")
  endif ()
endfunction()

cmake_language(DEFER CALL horos_vtk_finalize)

# =============================================================================
# dependencies/FetchDependencies.cmake — C++ dependencies pulled at configure
# time with FetchContent, for libraries apt and vcstool do not cover.
#
# Use this file by including it in your project's main CMakeLists.txt.
# Example: include(dependencies/FetchDependencies.cmake)
# =============================================================================

include(FetchContent)

# <Example: Fetching the nlohmann/json library>
# FetchContent_Declare(
#     json
#     GIT_REPOSITORY https://github.com/nlohmann/json.git
#     GIT_TAG v3.11.2
# )
# FetchContent_MakeAvailable(json)

# The web page and the desktop app.
#
# Nothing here builds unless a target is asked for or FYAI_WEB is ON: npm
# installs a large dependency tree, and a C change never needs it.
#
#   fyai-web-install     npm ci, when node_modules is missing or stale
#   fyai-web             the built page in web/dist
#   fyai-web-dev         the bridge and Vite, for editing (not a build)
#   fyai-web-test        the unit tests of the page
#   fyai-web-turn        the bridge and mock provider: one turn and its frames
#   fyai-desktop         the desktop window, from the built page
#   fyai-desktop-package dist-app/fyai-linux-<arch>/, with fyai when bundled
#
# With FYAI_WEB=ON the page is built with the rest and its unit tests are
# registered with CTest; they are not registered by default, so the C suite
# stays independent of node. The built page and its bridge are then installed
# with a fyai-web launcher; a node that is too old to build the page leaves
# the page out of the build and the install with a message, not an error. The end-to-end target needs a provider key and
# runs fyai's mock provider, so it is never part of CTest.

set(FYAI_WEB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/web")
set(FYAI_WEB_STAMP "${CMAKE_CURRENT_BINARY_DIR}/web-test.stamp")

find_program(FYAI_NPM_EXECUTABLE npm)
find_program(FYAI_NODE_EXECUTABLE node)

if(NOT FYAI_NPM_EXECUTABLE)
    message(STATUS "npm not found; the web page and its tests cannot build")
endif()

# The tools of the page need node 20; the bridge itself runs on 18.
set(FYAI_WEB_NODE_MIN 20)
set(FYAI_WEB_CAN_BUILD OFF)

if(FYAI_NPM_EXECUTABLE AND FYAI_NODE_EXECUTABLE)
    execute_process(COMMAND "${FYAI_NODE_EXECUTABLE}" --version
        OUTPUT_VARIABLE FYAI_NODE_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE FYAI_NODE_RESULT)
    string(REGEX REPLACE "^v" "" FYAI_NODE_VERSION "${FYAI_NODE_VERSION}")

    if(FYAI_NODE_RESULT EQUAL 0 AND FYAI_NODE_VERSION VERSION_GREATER_EQUAL FYAI_WEB_NODE_MIN)
        set(FYAI_WEB_CAN_BUILD ON)
    else()
        message(STATUS
            "node ${FYAI_NODE_VERSION} is older than ${FYAI_WEB_NODE_MIN}; "
            "the web page is not part of the build")
    endif()
endif()

# The dependencies of the page. The lock file is the stamp: a change of it
# needs an install again, and the directory itself is what an install makes.
add_custom_target(fyai-web-install
    COMMAND "${FYAI_NPM_EXECUTABLE}" ci
    COMMENT "installing the page's dependencies"
    WORKING_DIRECTORY "${FYAI_WEB_DIR}"
    USES_TERMINAL
    VERBATIM)

# The page, from every source file that builds it.
file(GLOB_RECURSE FYAI_WEB_SOURCES CONFIGURE_DEPENDS
    "${FYAI_WEB_DIR}/src/*"
    "${FYAI_WEB_DIR}/static/*")
list(APPEND FYAI_WEB_SOURCES
    "${FYAI_WEB_DIR}/package.json"
    "${FYAI_WEB_DIR}/svelte.config.js"
    "${FYAI_WEB_DIR}/vite.config.ts")
list(FILTER FYAI_WEB_SOURCES EXCLUDE REGEX "/node_modules/")

add_custom_target(fyai-web
    COMMAND "${CMAKE_COMMAND}" -E remove_directory "${FYAI_WEB_DIR}/dist"
    COMMAND "${FYAI_NPM_EXECUTABLE}" run build
    COMMENT "building the web page"
    DEPENDS ${FYAI_WEB_SOURCES} fyai-web-install
    WORKING_DIRECTORY "${FYAI_WEB_DIR}"
    USES_TERMINAL
    VERBATIM)

# The page in development: the bridge and Vite. It does not end, so it is not
# a build step.
add_custom_target(fyai-web-dev
    COMMAND "${CMAKE_COMMAND}" -E env
        "FYAI_BIN=$<TARGET_FILE:fyai>" "FYAI_BRIDGE_CWD=${CMAKE_CURRENT_SOURCE_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/web/scripts/dev.sh"
    COMMENT "serving the page in development"
    DEPENDS fyai
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)

# The unit tests. The stamp makes a pass of them a step that can be depended
# on; the test of fyai/web-test runs them again under CTest.
add_custom_command(OUTPUT "${FYAI_WEB_STAMP}"
    COMMAND "${FYAI_NPM_EXECUTABLE}" run test:unit -- --run
    COMMAND "${CMAKE_COMMAND}" -E touch "${FYAI_WEB_STAMP}"
    COMMENT "running the page's unit tests"
    DEPENDS ${FYAI_WEB_SOURCES} fyai-web-install
    WORKING_DIRECTORY "${FYAI_WEB_DIR}"
    VERBATIM)

add_custom_target(fyai-web-test
    COMMAND "${CMAKE_COMMAND}" -E remove -f "${FYAI_WEB_STAMP}"
    COMMAND "${FYAI_NPM_EXECUTABLE}" run test:unit -- --run
    COMMENT "running the page's unit tests"
    DEPENDS ${FYAI_WEB_SOURCES} fyai-web-install
    WORKING_DIRECTORY "${FYAI_WEB_DIR}"
    USES_TERMINAL
    VERBATIM)

# One turn of the page against fyai's mock provider: the bridge's frames.
add_custom_target(fyai-web-turn
    COMMAND "${CMAKE_COMMAND}" -E env "FYAI_BIN=$<TARGET_FILE:fyai>"
        "TD=${CMAKE_CURRENT_BINARY_DIR}/web-turn"
        bash "${FYAI_WEB_DIR}/server/test-turn.sh" chat_stream.json hello conv-1
    COMMENT "running one turn of the page against the mock provider"
    DEPENDS fyai fyai-web-install
    USES_TERMINAL
    VERBATIM)

# The desktop app.
add_custom_target(fyai-desktop
    COMMAND "${CMAKE_COMMAND}" -E env
        "FYAI_BIN=$<TARGET_FILE:fyai>" "FYAI_BRIDGE_CWD=${CMAKE_CURRENT_SOURCE_DIR}"
        "${FYAI_WEB_DIR}/scripts/desktop.sh"
    COMMENT "opening the desktop window"
    DEPENDS fyai-web
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)

add_custom_target(fyai-desktop-package
    COMMAND "${CMAKE_COMMAND}" -E env
        "FYAI_BIN=$<TARGET_FILE:fyai>" "FYAI_SRC=${CMAKE_CURRENT_SOURCE_DIR}"
        "${FYAI_WEB_DIR}/scripts/package.sh" --bundle-fyai
    COMMENT "packaging the desktop app with fyai"
    DEPENDS fyai-web
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)

if(FYAI_WEB AND FYAI_WEB_CAN_BUILD)
    add_custom_target(fyai-web-all ALL DEPENDS fyai-web)

    # The built page, the bridge that serves it, and a launcher. The bridge
    # uses only the modules of node, so no node_modules is installed.
    set(FYAI_WEB_SHARE "${CMAKE_INSTALL_DATAROOTDIR}/fyai/web")
    file(RELATIVE_PATH FYAI_WEB_SHARE_RELATIVE
        "/${CMAKE_INSTALL_BINDIR}" "/${FYAI_WEB_SHARE}")
    configure_file("${FYAI_WEB_DIR}/scripts/fyai-web.in"
        "${CMAKE_CURRENT_BINARY_DIR}/fyai-web" @ONLY)
    install(DIRECTORY "${FYAI_WEB_DIR}/dist"
        DESTINATION "${FYAI_WEB_SHARE}")
    install(FILES "${FYAI_WEB_DIR}/server/bridge.mjs"
        "${FYAI_WEB_DIR}/server/protocol.mjs"
        DESTINATION "${FYAI_WEB_SHARE}/server")
    install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/fyai-web"
        DESTINATION "${CMAKE_INSTALL_BINDIR}")
endif()

# The unit tests under CTest, only when the page is part of the build.
if(BUILD_TESTING AND FYAI_WEB AND FYAI_WEB_CAN_BUILD)
    add_test(NAME fyai/web-test
        COMMAND "${FYAI_NPM_EXECUTABLE}" run test:unit -- --run
        WORKING_DIRECTORY "${FYAI_WEB_DIR}")
    set_tests_properties(fyai/web-test PROPERTIES
        LABELS web
        TIMEOUT 900)
endif()

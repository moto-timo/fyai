# The web page and the desktop app.
#
# Nothing here builds unless a target is asked for or FYAI_WEB is ON: npm
# installs a large dependency tree, and a C change never needs it.
#
#   fyai-web-install     npm ci, when node_modules is missing or stale
#   fyai-web             the built page in web/dist, when a source is newer
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
#
# FYAI_DESKTOP=ON, on Linux, also packages the Electron app (about 350 MB,
# and a download of Electron) and installs it under share/fyai/desktop with a
# fyai-desktop launcher, a menu entry and an icon. The installed app uses the
# fyai installed beside it.
#
# FYAI_DESKTOP=ON, on Linux, also packages the Electron app (about 350 MB,
# and a download of Electron) and installs it under share/fyai/desktop with a
# fyai-desktop launcher, a menu entry and an icon. The installed app uses the
# fyai installed beside it.

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

# npm starts `node` through the PATH. A root shell has another PATH than the
# one that configured the build, and its node can be too old, so every npm
# command runs with the directory of the node that was checked in front.
get_filename_component(FYAI_NODE_DIR "${FYAI_NODE_EXECUTABLE}" DIRECTORY)
set(FYAI_WEB_NPM "${CMAKE_COMMAND}" -E env "PATH=${FYAI_NODE_DIR}:$ENV{PATH}"
    "${FYAI_NPM_EXECUTABLE}")

# The dependencies of the page. npm ci writes node_modules/.package-lock.json,
# so that file is the stamp: a newer lock file makes an install again and an
# installed tree is left alone. A build that is up to date then runs no npm,
# which is what lets `make && sudo make install` leave npm out of root's hands.
set(FYAI_WEB_MODULES "${FYAI_WEB_DIR}/node_modules/.package-lock.json")

add_custom_command(OUTPUT "${FYAI_WEB_MODULES}"
    COMMAND ${FYAI_WEB_NPM} ci
    COMMENT "installing the page's dependencies"
    DEPENDS "${FYAI_WEB_DIR}/package-lock.json"
    WORKING_DIRECTORY "${FYAI_WEB_DIR}"
    USES_TERMINAL
    VERBATIM)

add_custom_target(fyai-web-install DEPENDS "${FYAI_WEB_MODULES}")

# The page, from every source file that builds it.
file(GLOB_RECURSE FYAI_WEB_SOURCES CONFIGURE_DEPENDS
    "${FYAI_WEB_DIR}/src/*"
    "${FYAI_WEB_DIR}/static/*")
list(APPEND FYAI_WEB_SOURCES
    "${FYAI_WEB_DIR}/package.json"
    "${FYAI_WEB_DIR}/svelte.config.js"
    "${FYAI_WEB_DIR}/vite.config.ts")
list(FILTER FYAI_WEB_SOURCES EXCLUDE REGEX "/node_modules/")

set(FYAI_WEB_PAGE "${FYAI_WEB_DIR}/dist/index.html")

add_custom_command(OUTPUT "${FYAI_WEB_PAGE}"
    COMMAND "${CMAKE_COMMAND}" -E remove_directory "${FYAI_WEB_DIR}/dist"
    COMMAND ${FYAI_WEB_NPM} run build
    COMMENT "building the web page"
    DEPENDS ${FYAI_WEB_SOURCES}
    WORKING_DIRECTORY "${FYAI_WEB_DIR}"
    USES_TERMINAL
    VERBATIM)

# Ordered by target, not by file: two targets that name the same output file
# can each run its command in a parallel build.
add_custom_target(fyai-web DEPENDS "${FYAI_WEB_PAGE}")
add_dependencies(fyai-web fyai-web-install)

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
    COMMAND ${FYAI_WEB_NPM} run test:unit -- --run
    COMMAND "${CMAKE_COMMAND}" -E touch "${FYAI_WEB_STAMP}"
    COMMENT "running the page's unit tests"
    DEPENDS ${FYAI_WEB_SOURCES} fyai-web-install
    WORKING_DIRECTORY "${FYAI_WEB_DIR}"
    VERBATIM)

add_custom_target(fyai-web-test
    COMMAND "${CMAKE_COMMAND}" -E remove -f "${FYAI_WEB_STAMP}"
    COMMAND ${FYAI_WEB_NPM} run test:unit -- --run
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

    if(FYAI_DESKTOP AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
            set(FYAI_DESKTOP_ARCH arm64)
        else()
            set(FYAI_DESKTOP_ARCH x64)
        endif()
        set(FYAI_DESKTOP_DIR "${FYAI_WEB_DIR}/dist-app/fyai-linux-${FYAI_DESKTOP_ARCH}")
        set(FYAI_DESKTOP_SHARE "${CMAKE_INSTALL_DATAROOTDIR}/fyai/desktop")

        # The page is already built by fyai-web; the app carries no fyai.
        add_custom_target(fyai-desktop-app ALL
            COMMAND "${FYAI_WEB_DIR}/scripts/package.sh" --skip-build --no-fyai
            COMMENT "packaging the desktop app"
            DEPENDS fyai-web
            WORKING_DIRECTORY "${FYAI_WEB_DIR}"
            USES_TERMINAL
            VERBATIM)

        file(RELATIVE_PATH FYAI_DESKTOP_SHARE_RELATIVE
            "/${CMAKE_INSTALL_BINDIR}" "/${FYAI_DESKTOP_SHARE}")
        configure_file("${FYAI_WEB_DIR}/scripts/fyai-desktop.in"
            "${CMAKE_CURRENT_BINARY_DIR}/fyai-desktop" @ONLY)
        install(DIRECTORY "${FYAI_DESKTOP_DIR}/"
            DESTINATION "${FYAI_DESKTOP_SHARE}"
            USE_SOURCE_PERMISSIONS
            PATTERN "chrome-sandbox" EXCLUDE)
        # The sandbox helper of Chromium runs setuid root where the kernel
        # does not give a user a namespace of its own.
        install(PROGRAMS "${FYAI_DESKTOP_DIR}/chrome-sandbox"
            DESTINATION "${FYAI_DESKTOP_SHARE}"
            PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE SETUID)
        install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/fyai-desktop"
            DESTINATION "${CMAKE_INSTALL_BINDIR}")
        install(FILES "${FYAI_WEB_DIR}/scripts/fyai.desktop.in"
            DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/applications"
            RENAME fyai.desktop)
        install(FILES "${FYAI_WEB_DIR}/static/pwa-512x512.png"
            DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor/512x512/apps"
            RENAME fyai.png)
    elseif(FYAI_DESKTOP)
        message(STATUS "FYAI_DESKTOP packages the Linux app only; nothing to install here")
    endif()
endif()

# The unit tests under CTest, only when the page is part of the build.
if(BUILD_TESTING AND FYAI_WEB AND FYAI_WEB_CAN_BUILD)
    add_test(NAME fyai/web-test
        COMMAND ${FYAI_WEB_NPM} run test:unit -- --run
        WORKING_DIRECTORY "${FYAI_WEB_DIR}")
    set_tests_properties(fyai/web-test PROPERTIES
        LABELS web
        TIMEOUT 900)
endif()

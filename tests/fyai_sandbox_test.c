/*
 * fyai_sandbox_test.c - PATH visibility of a sandbox spec
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>

#include "fyai_sandbox.h"
#include "fyai_test_registry.h"

#ifdef __linux__
int sandbox_path_visible(void)
{
	static const struct fyai_sandbox_path allow[] = {
		{ "/home/u/.cargo/bin", FYAI_SB_RO },
	};
	static const char *const deny[] = { "/home/u/proj/secret" };
	static const char *const hide[] = { "/home/u/proj/.fyai" };
	struct fyai_sandbox_spec spec = {
		.hide = hide, .hide_n = 1,
		.project_root = "/home/u/proj",
		.allow = allow, .allow_n = 1,
		.deny = deny, .deny_n = 1, .deny_global_n = 1,
	};
	int fail = 0;

#define CHECK(expr) do { if (!(expr)) { \
	fprintf(stderr, "FAIL: %s\n", #expr); fail = 1; } } while (0)
	CHECK(fyai_sandbox_path_visible(&spec, "/usr/bin"));
	CHECK(fyai_sandbox_path_visible(&spec, "/usr/local/bin"));
	CHECK(fyai_sandbox_path_visible(&spec, "/tmp/x"));
	CHECK(fyai_sandbox_path_visible(&spec, "/home/u/proj/node_modules/.bin"));
	CHECK(fyai_sandbox_path_visible(&spec, "/home/u/.cargo/bin"));
	CHECK(!fyai_sandbox_path_visible(&spec, "/home/u/bin"));
	CHECK(!fyai_sandbox_path_visible(&spec, "/home/u/.cargo"));
	CHECK(!fyai_sandbox_path_visible(&spec, "/home/u/proj/secret/bin"));
	CHECK(!fyai_sandbox_path_visible(&spec, "/home/u/proj/.fyai/bin"));
	CHECK(!fyai_sandbox_path_visible(&spec, "/home/u/proj-other/bin"));
	CHECK(!fyai_sandbox_path_visible(&spec, "bin"));
	CHECK(!fyai_sandbox_path_visible(&spec, ""));
	CHECK(!fyai_sandbox_path_visible(&spec, "/usr/../home/u/bin"));
#undef CHECK
	return fail;
}
#else
/* The PATH filter belongs to the Landlock confinement of Linux. */
int sandbox_path_visible(void)
{
	return 0;
}
#endif

FYAI_TEST_ENTRY(sandbox, path_visible, sandbox_path_visible)

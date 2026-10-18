/*
 * fyai_ptydrv.h - scripted PTY driver for the test suite
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef FYAI_PTYDRV_H
#define FYAI_PTYDRV_H

#include <libfyaml.h>

struct fyai_ctx;

/*
 * Run the program @argv (a NULL-terminated vector, @argv[0] the path) with the
 * variables @env ("NAME=VALUE" strings, NULL-terminated) added, on a
 * pseudo-terminal, as the YAML @script says (doc/pty-driver.md). Write every
 * byte the program sent to the file @output, also when a step fails. Parsed
 * values live in @gb, which must outlive the call. Return 0 when each step
 * passed and the program ended as the script expects; else report the cause
 * and return -1.
 */
int fyai_ptydrv_run(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
		    const char *script, const char *output,
		    char *const *argv, char *const *env);

#endif

/*
 * fyai_image_test.c - unit tests for the prebuilt images of the embedded YAML
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 * SPDX-License-Identifier: MIT
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fyai.h"
#include "fyai_config.h"
#include "fyai_image.h"

#include "embedded_catalog.inc"
#include "embedded_catalog_image.inc"
#include "embedded_commands.inc"
#include "embedded_commands_image.inc"

#include "fyai_test_registry.h"

FYAI_TEST_ENTRY(image, equals_parse, image_equals_parse)
FYAI_TEST_ENTRY(image, honours_no_image, image_honours_no_image)

static int failures;

#define check(_cond, _msg) \
	do { \
		if (!(_cond)) { \
			fprintf(stderr, "FAIL: %s\n", (_msg)); \
			failures++; \
		} \
	} while (0)

/* An image loads, and it holds the document that the text parses to. */
static void check_equal(const unsigned char *text, size_t text_len,
			void *image, size_t image_len, const char *name)
{
	struct fy_generic_builder_cfg cfg = {
		.flags = FYGBCF_SCOPE_LEADER | FYGBCF_DEDUP_ENABLED,
	};
	struct fy_generic_builder *gb;
	fy_generic_sized_string sz = { (const char *)text, text_len };
	fy_generic expect, loaded = fy_invalid, again = fy_invalid;

	gb = fy_generic_builder_create(&cfg);
	check(gb, "a builder");
	if (!gb)
		return;
	expect = fy_parse(gb, sz, FYAI_YAML_PARSE_FLAGS |
			  FYOPPF_INPUT_TYPE_STRING, NULL);
	check(fy_is_mapping(expect), name);
	check(!fyai_image_load(image, image_len, &loaded), name);
	check(fy_is_mapping(loaded), name);
	check(fy_equal(expect, loaded), name);
	/* A second load of the same image finds it moved and changes nothing. */
	check(!fyai_image_load(image, image_len, &again), name);
	check(fy_equal(expect, again), name);
	fy_generic_builder_destroy(gb);
}

int image_equals_parse(void)
{
	failures = 0;
	check_equal(FYAI_EMBEDDED_COMMANDS, FYAI_EMBEDDED_COMMANDS_LEN,
		    FYAI_IMAGE_COMMANDS, FYAI_IMAGE_COMMANDS_LEN,
		    "the image of the commands equals the parse");
	check_equal(FYAI_EMBEDDED_CATALOG, FYAI_EMBEDDED_CATALOG_LEN,
		    FYAI_IMAGE_CATALOG, FYAI_IMAGE_CATALOG_LEN,
		    "the image of the catalogue equals the parse");
	return failures ? 1 : 0;
}

/* FYAI_NO_IMAGE forces the caller to the text. */
int image_honours_no_image(void)
{
	size_t len = FYAI_IMAGE_COMMANDS_LEN;
	unsigned char *image;
	fy_generic root = fy_invalid;

	failures = 0;
	if (!len)
		return 0;	/* a cross build has no image */
	/* A copy aligned as the binary has it: each test has its own process. */
	image = aligned_alloc(FY_GENERIC_IMAGE_ALIGN,
			      (len + FY_GENERIC_IMAGE_ALIGN - 1) &
			      ~((size_t)FY_GENERIC_IMAGE_ALIGN - 1));
	check(image, "an image");
	if (!image)
		return 1;
	memcpy(image, FYAI_IMAGE_COMMANDS, len);
	setenv("FYAI_NO_IMAGE", "1", 1);
	check(fyai_image_load(image, len, &root),
	      "the variable refuses the image");
	check(!fy_is_valid(root), "a refusal leaves the root alone");
	unsetenv("FYAI_NO_IMAGE");
	check(!fyai_image_load(image, len, &root),
	      "without it the image loads");
	free(image);
	return failures ? 1 : 0;
}

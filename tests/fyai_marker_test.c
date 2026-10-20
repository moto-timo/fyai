/*
 * fyai_marker_test.c - unit tests for the prompt marker and its busy form
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 * SPDX-License-Identifier: MIT
 */

#define FYAI_MODULE FYAIEM_DISPLAY

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fyai.h"
#include "fyai_marker.h"

#include "fyai_test_registry.h"

FYAI_TEST_ENTRY(marker, columns_skip_sgr, marker_columns)
FYAI_TEST_ENTRY(marker, busy_marker_keeps_the_columns, marker_busy_columns)
FYAI_TEST_ENTRY(marker, busy_marker_keeps_the_colour, marker_busy_colour)
FYAI_TEST_ENTRY(marker, busy_marker_has_no_length_limit, marker_busy_long)
FYAI_TEST_ENTRY(marker, busy_marker_takes_a_glyph, marker_busy_glyph)

static int failures;

/* Two columns for the wide glyph U+2728, none known for the rest. */
static int wide_width(unsigned int cp)
{
	return cp == 0x2728 ? 2 : 0;
}

static void expect_int(const char *what, int got, int want)
{
	if (got == want)
		return;
	fprintf(stderr, "FAIL %s\n  got:  %d\n  want: %d\n", what, got, want);
	failures++;
}

static void expect_str(const char *what, const char *got, const char *want)
{
	if (got && !strcmp(got, want))
		return;
	fprintf(stderr, "FAIL %s\n  got:  \"%s\"\n  want: \"%s\"\n", what,
		got ? got : "(null)", want);
	failures++;
}

int marker_columns(void)
{
	failures = 0;
	expect_int("plain", fyai_marker_cols("> ", NULL), 2);
	expect_int("arrow", fyai_marker_cols("\xe2\x9d\xaf ", NULL), 2);
	expect_int("sgr", fyai_marker_cols("\x1b[1;36m\xe2\x9d\xaf \x1b[0m",
					   NULL), 2);
	expect_int("wide", fyai_marker_cols("\xe2\x9c\xa8 ", wide_width), 3);
	expect_int("wide, no width", fyai_marker_cols("\xe2\x9c\xa8 ", NULL), 2);
	expect_int("empty", fyai_marker_cols("", NULL), 0);
	expect_int("control", fyai_marker_cols("a\tb", NULL), 2);
	return failures;
}

/* The busy marker has the columns of the marker it replaces. */
int marker_busy_columns(void)
{
	static const char *const markers[] = {
		"> ", "\xe2\x9d\xaf ", "  > ", "\x1b[36m\xe2\x9d\xaf \x1b[0m",
		"\xe2\x9c\xa8 ", "\xe2\x9c\xa8\xe2\x9c\xa8  ",
	};
	size_t i;
	char *busy;

	failures = 0;
	for (i = 0; i < sizeof(markers) / sizeof(markers[0]); i++) {
		busy = fyai_marker_busy(markers[i], NULL, wide_width);
		if (!busy) {
			failures++;
			continue;
		}
		expect_int(markers[i], fyai_marker_cols(busy, wide_width),
			   fyai_marker_cols(markers[i], wide_width));
		free(busy);
	}
	return failures;
}

int marker_busy_colour(void)
{
	char *busy;

	failures = 0;
	busy = fyai_marker_busy("\xe2\x9d\xaf ", NULL, NULL);
	expect_str("plain", busy, "\xe2\x80\xa6 ");
	free(busy);
	busy = fyai_marker_busy("\x1b[36m\xe2\x9d\xaf \x1b[0m", NULL, NULL);
	expect_str("sgr", busy, "\x1b[36m\xe2\x80\xa6\x1b[0m ");
	free(busy);
	busy = fyai_marker_busy("\x1b[1m\x1b[36m>\x1b[0m ", NULL, NULL);
	expect_str("two sequences", busy, "\x1b[1m\x1b[36m\xe2\x80\xa6\x1b[0m ");
	free(busy);
	/* a marker with no glyph still has one column */
	busy = fyai_marker_busy("", NULL, NULL);
	expect_str("empty", busy, "\xe2\x80\xa6");
	free(busy);
	return failures;
}

/* A given glyph replaces the ellipsis and keeps the columns of the marker. */
int marker_busy_glyph(void)
{
	char *busy;

	failures = 0;
	busy = fyai_marker_busy("\x1b[36m\xe2\x9d\xaf \x1b[0m", "*", NULL);
	expect_str("glyph", busy, "\x1b[36m*\x1b[0m ");
	free(busy);
	busy = fyai_marker_busy("> ", "", NULL);
	expect_str("empty glyph", busy, "\xe2\x80\xa6 ");
	free(busy);
	/* a wide glyph takes the columns of the marker */
	busy = fyai_marker_busy("  > ", "\xe2\x9c\xa8", wide_width);
	expect_int("wide", fyai_marker_cols(busy, wide_width), 4);
	free(busy);
	return failures;
}

/* A marker of 100 columns keeps them: the input does not move. */
int marker_busy_long(void)
{
	char marker[128];
	char *busy;

	failures = 0;
	memset(marker, '>', 100);
	marker[100] = '\0';
	busy = fyai_marker_busy(marker, NULL, NULL);
	if (!busy) {
		failures++;
		return failures;
	}
	expect_int("long", fyai_marker_cols(busy, NULL), 100);
	free(busy);
	return failures;
}

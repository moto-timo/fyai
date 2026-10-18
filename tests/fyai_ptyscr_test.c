/*
 * fyai_ptyscr_test.c - tests for the screen model of the PTY driver
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 * SPDX-License-Identifier: MIT
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fyai_ptyscr.h"
#include "fyai_test.h"
#include "fyai_test_registry.h"

FYAI_TEST_ENTRY(ptyscr, text_and_cursor, ptyscr_text_and_cursor)
FYAI_TEST_ENTRY(ptyscr, scrollback, ptyscr_scrollback)
FYAI_TEST_ENTRY(ptyscr, erase_of_display, ptyscr_erase_of_display)
FYAI_TEST_ENTRY(ptyscr, split_sequence, ptyscr_split_sequence)
FYAI_TEST_ENTRY(ptyscr, copy, ptyscr_copy)
FYAI_TEST_ENTRY(ptyscr, search, ptyscr_search)
FYAI_TEST_ENTRY(ptyscr, resize_keeps_copies, ptyscr_resize_keeps_copies)

#define FEED(_s, _text) fyai_ptyscr_feed((_s), (_text), strlen(_text))

/* The text of row @r, without the blanks at its end. */
static const char *row_of(const struct fyai_ptyscr *s, int r)
{
	static char buf[1024];

	FYAI_TCHECK(fyai_ptyscr_row_size(s) <= sizeof(buf));
	fyai_ptyscr_row(s, r, buf);
	return buf;
}

int ptyscr_text_and_cursor(void)
{
	struct fyai_ptyscr s;
	int row, col;

	FYAI_TCHECK(!fyai_ptyscr_init(&s, 5, 20, false));
	FEED(&s, "hello\r\nworld");
	FYAI_TCHECK(!strcmp(row_of(&s, 0), "hello"));
	FYAI_TCHECK(!strcmp(row_of(&s, 1), "world"));
	fyai_ptyscr_cursor(&s, &row, &col);
	FYAI_TCHECK(row == 1 && col == 5);
	/* A cursor motion, and an overwrite of a cell. */
	FEED(&s, "\x1b[1;2HE");
	FYAI_TCHECK(!strcmp(row_of(&s, 0), "hEllo"));
	fyai_ptyscr_destroy(&s);
	return 0;
}

int ptyscr_scrollback(void)
{
	struct fyai_ptyscr s;

	FYAI_TCHECK(!fyai_ptyscr_init(&s, 3, 20, false));
	FEED(&s, "one\r\ntwo\r\nthree\r\nfour\r\nfive");
	FYAI_TCHECK(s.scrollback.n == 2);
	FYAI_TCHECK(!strcmp(s.scrollback.v[0], "one"));
	FYAI_TCHECK(!strcmp(s.scrollback.v[1], "two"));
	FYAI_TCHECK(!strcmp(row_of(&s, 0), "three"));
	FYAI_TCHECK(!strcmp(row_of(&s, 2), "five"));
	/* A row that scrolled off is searched from the index asked for. */
	FYAI_TCHECK(fyai_ptyscr_has(&s, "one", 0, SIZE_MAX, false));
	FYAI_TCHECK(!fyai_ptyscr_has(&s, "one", 1, SIZE_MAX, false));
	fyai_ptyscr_destroy(&s);
	return 0;
}

int ptyscr_erase_of_display(void)
{
	struct fyai_ptyscr s;

	FYAI_TCHECK(!fyai_ptyscr_init(&s, 4, 20, false));
	FEED(&s, "kept\r\nrow");
	/* An erase of a line does not remove the rows of the display. */
	FEED(&s, "\x1b[2K");
	FYAI_TCHECK(s.display_erases == 0 && s.erased.n == 0);
	FEED(&s, "\x1b[2J");
	FYAI_TCHECK(s.display_erases == 1);
	FYAI_TCHECK(s.erased.n == 1 && !strcmp(s.erased.v[0], "kept"));
	FYAI_TCHECK(!row_of(&s, 0)[0]);
	FYAI_TCHECK(fyai_ptyscr_has(&s, "kept", SIZE_MAX, 0, false));
	FYAI_TCHECK(!fyai_ptyscr_has(&s, "kept", SIZE_MAX, 1, false));
	fyai_ptyscr_destroy(&s);
	return 0;
}

int ptyscr_split_sequence(void)
{
	struct fyai_ptyscr s;

	FYAI_TCHECK(!fyai_ptyscr_init(&s, 4, 20, false));
	/* The sequence and the character arrive in pieces. */
	FEED(&s, "\x1b");
	FEED(&s, "[2;3");
	FEED(&s, "Hab\xe2\x96");
	FEED(&s, "\x8c");
	FYAI_TCHECK(!strcmp(row_of(&s, 1), "  ab\xe2\x96\x8c"));
	fyai_ptyscr_destroy(&s);
	return 0;
}

int ptyscr_copy(void)
{
	struct fyai_ptyscr s;

	FYAI_TCHECK(!fyai_ptyscr_init(&s, 4, 20, false));
	/* "Hello", ended by BEL and by ST, the second in two pieces. */
	FEED(&s, "\x1b]52;c;SGVsbG8=\x07");
	FEED(&s, "\x1b]52;c;V29y");
	FEED(&s, "bGQ=\x1b\\");
	FYAI_TCHECK(s.clipboard.n == 2);
	FYAI_TCHECK(!strcmp(s.clipboard.v[0], "Hello"));
	FYAI_TCHECK(!strcmp(s.clipboard.v[1], "World"));
	fyai_ptyscr_destroy(&s);
	return 0;
}

int ptyscr_search(void)
{
	struct fyai_ptyscr s;
	int row, col;

	FYAI_TCHECK(!fyai_ptyscr_init(&s, 4, 20, false));
	FEED(&s, "\r\n  \xe2\x97\x8f shell [x]\r\n   x");
	FYAI_TCHECK(fyai_ptyscr_has(&s, "shell [x]", SIZE_MAX, SIZE_MAX, false));
	/* A row that is the text alone, with the blanks at both ends removed. */
	FYAI_TCHECK(fyai_ptyscr_has(&s, "x", SIZE_MAX, SIZE_MAX, true));
	FYAI_TCHECK(!fyai_ptyscr_has(&s, "shell", SIZE_MAX, SIZE_MAX, true));
	/* The column is a cell and not a byte. */
	FYAI_TCHECK(fyai_ptyscr_locate(&s, "shell", &row, &col));
	FYAI_TCHECK(row == 1 && col == 4);
	FYAI_TCHECK(!fyai_ptyscr_locate(&s, "absent", &row, &col));
	fyai_ptyscr_destroy(&s);
	return 0;
}

int ptyscr_resize_keeps_copies(void)
{
	struct fyai_ptyscr s;

	FYAI_TCHECK(!fyai_ptyscr_init(&s, 4, 20, false));
	FEED(&s, "text\x1b]52;c;SGVsbG8=\x07");
	FYAI_TCHECK(!fyai_ptyscr_resize(&s, 6, 30));
	FYAI_TCHECK(s.rows == 6 && s.cols == 30);
	FYAI_TCHECK(!row_of(&s, 0)[0]);
	FYAI_TCHECK(s.clipboard.n == 1 && !strcmp(s.clipboard.v[0], "Hello"));
	fyai_ptyscr_destroy(&s);
	return 0;
}

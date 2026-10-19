/*
 * fyai_cast.c - asciicast v2 recording
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 *
 * SPDX-License-Identifier: MIT
 *
 * A recording is one JSON header line and one JSON array for each event:
 * [seconds, "o" | "i" | "r" | "m", data]. The lines are the documents of one
 * stream of a libfyaml emitter in JSON mode. Each value is a generic, which
 * the generic iterator turns into events for the emitter; the events of the
 * containers are made here. The format needs valid UTF-8 text, thus the writer
 * repairs the bytes it gets before the emitter escapes them.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <errno.h>
#include <math.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libfyaml.h>

#include "fyai.h"
#include "fyai_cast.h"
#include "utils.h"

#define FYAI_MODULE FYAIEM_UNKNOWN

/* The longest UTF-8 character. */
#define CAST_UTF8_MAX 4

#define CAST_REPLACEMENT "\xEF\xBF\xBD"

struct fyai_cast {
	struct fyai_ctx *ctx;
	FILE *fp;
	struct fy_emitter *emit;
	struct fy_generic_iterator *gi;
	double t0;
	bool failed;
	/* The repaired text of the event that is made. */
	struct response_buffer text;
	/* The start of a character that a write cut: per kind of event. */
	unsigned char hold[2][CAST_UTF8_MAX];
	size_t nhold[2];
};

/* Add the repaired text of @in to the text of the event; keep a cut character. */
static int put_text(struct fyai_cast *c, int kind, const void *in, size_t n)
{
	unsigned char buf[CAST_UTF8_MAX];
	const unsigned char *p = in;
	size_t i = 0, used, len;
	ssize_t take;
	int rc = 0;

	/* The held start joins the bytes that follow. */
	if (c->nhold[kind]) {
		len = c->nhold[kind];
		memcpy(buf, c->hold[kind], len);
		used = n < CAST_UTF8_MAX - len ? n : CAST_UTF8_MAX - len;
		memcpy(buf + len, p, used);
		take = fyai_utf8_scan(buf, len + used);
		if (take < 0) {
			memcpy(c->hold[kind], buf, len + used);
			c->nhold[kind] = len + used;
			return 0;
		}
		c->nhold[kind] = 0;
		if (take > 0) {
			rc |= response_buffer_append_data(&c->text, buf, take);
			i = (size_t)take - len;
		} else {
			/* The bytes after the lead start again. */
			rc |= response_buffer_append_data(&c->text,
							  CAST_REPLACEMENT, 3);
		}
	}
	while (i < n && !rc) {
		take = fyai_utf8_scan(p + i, n - i);
		if (take < 0) {
			/* A prefix that can still become a character is held. */
			c->nhold[kind] = n - i;
			memcpy(c->hold[kind], p + i, n - i);
			return rc;
		}
		if (take > 0) {
			rc |= response_buffer_append_data(&c->text, p + i, take);
			i += take;
		} else {
			rc |= response_buffer_append_data(&c->text,
							  CAST_REPLACEMENT, 3);
			i++;
		}
	}
	return rc;
}

static int emitter_output(struct fy_emitter *emit, enum fy_emitter_write_type type,
			  const char *str, int len, void *user)
{
	struct fyai_cast *c = user;

	(void)emit;
	(void)type;
	return fwrite(str, 1, (size_t)len, c->fp) == (size_t)len ? len : -1;
}

/* Write @v as one document, and the line with it. */
static void line_write(struct fyai_cast *c, fy_generic v)
{
	struct fy_event *fye;
	int rc = 0;

	rc = fy_emit_eventf(c->emit, FYET_DOCUMENT_START, 1, NULL, NULL);
	fy_generic_iterator_generic_start(c->gi, v);
	while (!rc && (fye = fy_generic_iterator_body_next(c->gi)))
		rc = fy_emit_event(c->emit, fye);
	if (!rc && fy_generic_iterator_get_error(c->gi))
		rc = -1;
	if (!rc)
		rc = fy_emit_eventf(c->emit, FYET_DOCUMENT_END, 1);
	if (!rc && fflush(c->fp))
		rc = -1;
	if (rc && !c->failed) {
		c->failed = true;
		fyai_warning(c->ctx, "cast: cannot write the recording: %s",
			     errno ? strerror(errno) : "emitter error");
	}
}

/* One event: [time, kind, text]; @text is the repaired bytes of the event. */
static void event(struct fyai_cast *c, const char *kind, int hold,
		  const void *data, size_t len)
{
	const char *text;
	size_t ntext;
	double t;
	int rc;

	if (!c || c->failed)
		return;
	/* Microseconds: the digits of a double below that are noise. */
	t = round((fyai_monotonic_sec() - c->t0) * 1e6) / 1e6;
	c->text.len = 0;
	rc = put_text(c, hold, data, len);
	if (rc) {
		fyai_warning(c->ctx, "cast: out of memory");
		c->failed = true;
		return;
	}
	text = c->text.data ? c->text.data : "";
	ntext = c->text.len;
	line_write(c, fy_sequence(t, kind, fy_string_size(text, ntext)));
}

void fyai_cast_output(struct fyai_cast *c, const void *data, size_t len)
{
	event(c, "o", 0, data, len);
}

void fyai_cast_input(struct fyai_cast *c, const void *data, size_t len)
{
	event(c, "i", 1, data, len);
}

void fyai_cast_resize(struct fyai_cast *c, int cols, int rows)
{
	const char *size = fy_sprintfa("%dx%d", cols, rows);

	event(c, "r", 0, size, strlen(size));
}

void fyai_cast_marker(struct fyai_cast *c, const char *label)
{
	event(c, "m", 0, label, strlen(label));
}

/* The header: {version, width, height, timestamp, command}. */
static int header_write(struct fyai_cast *c, int cols, int rows,
			const char *command)
{
	long long now = (long long)time(NULL);

	if (command)
		line_write(c, fy_mapping("version", 2, "width", cols,
					 "height", rows, "timestamp", now,
					 "command", command));
	else
		line_write(c, fy_mapping("version", 2, "width", cols,
					 "height", rows, "timestamp", now));
	return c->failed ? -1 : 0;
}

void fyai_cast_close(struct fyai_cast *c)
{
	if (!c)
		return;
	/* A character that was never finished is a replacement. */
	if (c->nhold[0] && !c->failed) {
		c->nhold[0] = 0;
		event(c, "o", 0, CAST_REPLACEMENT, 3);
	}
	if (c->emit) {
		if (!c->failed)
			(void)fy_emit_eventf(c->emit, FYET_STREAM_END);
		fy_emitter_destroy(c->emit);
	}
	fy_generic_iterator_destroy(c->gi);
	if (c->fp)
		fclose(c->fp);
	free(c->text.data);
	free(c);
}

struct fyai_cast *fyai_cast_open(struct fyai_ctx *ctx, const char *path,
				 int cols, int rows, const char *command)
{
	struct fy_emitter_cfg ecfg;
	struct fyai_cast *c = calloc(1, sizeof(*c));
	int fd = -1;

	fyai_error_check(ctx, c, err, "cast: out of memory");
	c->ctx = ctx;
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	fyai_error_check(ctx, fd >= 0, err, "cast: cannot create %s: %s", path,
			 strerror(errno));
	c->fp = fdopen(fd, "w");
	fyai_error_check(ctx, c->fp, err, "cast: cannot open %s: %s", path,
			 strerror(errno));
	fd = -1;
	c->gi = fy_generic_iterator_create();
	fyai_error_check(ctx, c->gi, err,
			 "cast: cannot make the generic iterator");
	memset(&ecfg, 0, sizeof(ecfg));
	ecfg.flags = FYECF_MODE_JSON_ONELINE | FYECF_WIDTH_INF;
	ecfg.output = emitter_output;
	ecfg.userdata = c;
	c->emit = fy_emitter_create(&ecfg);
	fyai_error_check(ctx, c->emit, err, "cast: cannot make the emitter");
	fyai_error_check(ctx, !fy_emit_eventf(c->emit, FYET_STREAM_START), err,
			 "cast: cannot start the stream");
	c->t0 = fyai_monotonic_sec();
	fyai_error_check(ctx, !header_write(c, cols, rows, command), err,
			 "cast: cannot write %s", path);
	return c;
err:
	if (fd >= 0)
		close(fd);
	c = c ? (fyai_cast_close(c), NULL) : NULL;
	return c;
}

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

#define FYAI_MODULE FYAIEM_UNKNOWN

/* The longest UTF-8 character. */
#define CAST_UTF8_MAX 4

#define CAST_REPLACEMENT "\xEF\xBF\xBD"

struct fyai_cast {
	struct fyai_ctx *ctx;
	FILE *fp;
	struct fy_emitter *emit;
	struct fy_generic_builder *gb;
	struct fy_generic_iterator *gi;
	double t0;
	bool failed;
	/* The repaired text of the event that is made. */
	char *text;
	size_t ntext;
	size_t ctext;
	/* The start of a character that a write cut: per kind of event. */
	unsigned char hold[2][CAST_UTF8_MAX];
	size_t nhold[2];
};

static double now_sec(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Bytes of the character that starts with @lead, or 0 when it is not one. */
static size_t utf8_len(unsigned char lead)
{
	if (lead < 0x80)
		return 1;
	if (lead >= 0xC2 && lead <= 0xDF)
		return 2;
	if (lead >= 0xE0 && lead <= 0xEF)
		return 3;
	if (lead >= 0xF0 && lead <= 0xF4)
		return 4;
	return 0;
}

static bool utf8_valid(const unsigned char *p, size_t n)
{
	size_t i;

	for (i = 1; i < n; i++)
		if ((p[i] & 0xC0) != 0x80)
			return false;
	if (n == 3 && p[0] == 0xE0 && p[1] < 0xA0)
		return false;
	if (n == 3 && p[0] == 0xED && p[1] >= 0xA0)
		return false;
	if (n == 4 && p[0] == 0xF0 && p[1] < 0x90)
		return false;
	if (n == 4 && p[0] == 0xF4 && p[1] >= 0x90)
		return false;
	return true;
}

static int text_add(struct fyai_cast *c, const void *p, size_t n)
{
	char *grown;
	size_t cap;

	if (c->ntext + n > c->ctext) {
		cap = c->ctext ? c->ctext : 4096;
		while (cap < c->ntext + n)
			cap *= 2;
		grown = realloc(c->text, cap);
		if (!grown)
			return -1;
		c->text = grown;
		c->ctext = cap;
	}
	memcpy(c->text + c->ntext, p, n);
	c->ntext += n;
	return 0;
}

/* Add the repaired text of @in to the text of the event; keep a cut character. */
static int put_text(struct fyai_cast *c, int kind, const void *in, size_t n)
{
	unsigned char buf[CAST_UTF8_MAX];
	const unsigned char *p = in;
	size_t i = 0, len, take, used;
	int rc = 0;

	/* The held start joins the bytes that follow. */
	if (c->nhold[kind]) {
		memcpy(buf, c->hold[kind], c->nhold[kind]);
		take = utf8_len(buf[0]);
		len = c->nhold[kind];
		used = 0;
		while (len < take && used < n && (p[used] & 0xC0) == 0x80)
			buf[len++] = p[used++];
		if (len < take && used == n) {
			memcpy(c->hold[kind], buf, len);
			c->nhold[kind] = len;
			return 0;
		}
		c->nhold[kind] = 0;
		if (len == take && utf8_valid(buf, len)) {
			rc |= text_add(c, buf, len);
			i = used;
		} else {
			/* The bytes after the lead start again. */
			rc |= text_add(c, CAST_REPLACEMENT, 3);
		}
	}
	while (i < n && !rc) {
		take = utf8_len(p[i]);
		if (!take) {
			rc |= text_add(c, CAST_REPLACEMENT, 3);
			i++;
			continue;
		}
		if (i + take > n) {
			/* A prefix that can still become a character is held. */
			c->nhold[kind] = n - i;
			memcpy(c->hold[kind], p + i, n - i);
			return rc;
		}
		if (take == 1 || utf8_valid(p + i, take)) {
			rc |= text_add(c, p + i, take);
			i += take;
		} else {
			rc |= text_add(c, CAST_REPLACEMENT, 3);
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

/* Emit the events of one value: a scalar here, as the iterator makes them. */
static int emit_value(struct fyai_cast *c, fy_generic v)
{
	struct fy_event *fye;

	if (!fy_is_valid(v))
		return -1;
	fy_generic_iterator_generic_start(c->gi, v);
	while ((fye = fy_generic_iterator_body_next(c->gi)))
		if (fy_emit_event(c->emit, fye))
			return -1;
	return fy_generic_iterator_get_error(c->gi) ? -1 : 0;
}

static int line_begin(struct fyai_cast *c, enum fy_event_type container)
{
	if (fy_emit_eventf(c->emit, FYET_DOCUMENT_START, 1, NULL, NULL))
		return -1;
	if (container == FYET_SEQUENCE_START)
		return fy_emit_eventf(c->emit, FYET_SEQUENCE_START, FYNS_FLOW,
				      NULL, NULL);
	return fy_emit_eventf(c->emit, FYET_MAPPING_START, FYNS_FLOW, NULL,
			      NULL);
}

/* End the document, and the line with it. */
static void line_end(struct fyai_cast *c, enum fy_event_type container, int rc)
{
	if (!rc)
		rc = fy_emit_eventf(c->emit, container == FYET_SEQUENCE_START ?
				    FYET_SEQUENCE_END : FYET_MAPPING_END);
	if (!rc)
		rc = fy_emit_eventf(c->emit, FYET_DOCUMENT_END, 1);
	if (!rc && fflush(c->fp))
		rc = -1;
	/* The events of the line are gone: the builder takes the next one. */
	fy_generic_builder_reset(c->gb);
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
	double t;
	int rc;

	if (!c || c->failed)
		return;
	/* Microseconds: the digits of a double below that are noise. */
	t = round((now_sec() - c->t0) * 1e6) / 1e6;
	c->ntext = 0;
	rc = put_text(c, hold, data, len);
	if (!rc)
		rc = line_begin(c, FYET_SEQUENCE_START);
	if (!rc)
		rc = emit_value(c, fy_value(c->gb, t));
	if (!rc)
		rc = emit_value(c, fy_value(c->gb, kind));
	if (!rc)
		rc = emit_value(c, fy_gb_string_size_create(c->gb, c->text ?
							  c->text : "", c->ntext));
	line_end(c, FYET_SEQUENCE_START, rc);
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
	char size[48];

	snprintf(size, sizeof(size), "%dx%d", cols, rows);
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
	int rc = line_begin(c, FYET_MAPPING_START);

	if (!rc)
		rc = emit_value(c, fy_value(c->gb, "version")) ||
		     emit_value(c, fy_value(c->gb, 2));
	if (!rc)
		rc = emit_value(c, fy_value(c->gb, "width")) ||
		     emit_value(c, fy_value(c->gb, cols));
	if (!rc)
		rc = emit_value(c, fy_value(c->gb, "height")) ||
		     emit_value(c, fy_value(c->gb, rows));
	if (!rc)
		rc = emit_value(c, fy_value(c->gb, "timestamp")) ||
		     emit_value(c, fy_value(c->gb, (long long)time(NULL)));
	if (!rc && command)
		rc = emit_value(c, fy_value(c->gb, "command")) ||
		     emit_value(c, fy_value(c->gb, command));
	line_end(c, FYET_MAPPING_START, rc);
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
	fy_generic_builder_destroy(c->gb);
	if (c->fp)
		fclose(c->fp);
	free(c->text);
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
	c->gb = fy_generic_builder_create(NULL);
	c->gi = fy_generic_iterator_create();
	fyai_error_check(ctx, c->gb && c->gi, err,
			 "cast: cannot make the generic builder");
	memset(&ecfg, 0, sizeof(ecfg));
	ecfg.flags = FYECF_MODE_JSON_ONELINE | FYECF_WIDTH_INF;
	ecfg.output = emitter_output;
	ecfg.userdata = c;
	c->emit = fy_emitter_create(&ecfg);
	fyai_error_check(ctx, c->emit, err, "cast: cannot make the emitter");
	fyai_error_check(ctx, !fy_emit_eventf(c->emit, FYET_STREAM_START), err,
			 "cast: cannot start the stream");
	c->t0 = now_sec();
	fyai_error_check(ctx, !header_write(c, cols, rows, command), err,
			 "cast: cannot write %s", path);
	return c;
err:
	if (fd >= 0)
		close(fd);
	c = c ? (fyai_cast_close(c), NULL) : NULL;
	return c;
}

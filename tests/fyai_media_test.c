/*
 * fyai_media_test.c - unit tests for message attachments
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 * SPDX-License-Identifier: MIT
 */
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "fyai_media.h"
#include "fyai.h"
#include "fyai_turn.h"
#include "fyai_test.h"
#include "fyai_test_registry.h"
#include "fyai_test_scratch.h"

FYAI_TEST_ENTRY(media, sniff_types, media_sniff_types)
FYAI_TEST_ENTRY(media, dimensions, media_dimensions)
FYAI_TEST_ENTRY(media, type_names, media_type_names)
FYAI_TEST_ENTRY(media, content_parts, media_content_parts)
FYAI_TEST_ENTRY(media, image_roundtrip, media_image_roundtrip)
FYAI_TEST_ENTRY(media, image_limits, media_image_limits)
FYAI_TEST_ENTRY(media, pending_message, media_pending_message)
FYAI_TEST_ENTRY(media, pinned_root, media_pinned_root)

/*
 * Headers of each type, with the size in them: PNG 1024x768, JPEG 640x480,
 * GIF 32x16, WebP 800x600. Only the header is needed to type and size an
 * image, so no decoder runs.
 */
static const unsigned char png_head[] = {
	0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
	0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R',
	0x00, 0x00, 0x04, 0x00,	/* width 1024 */
	0x00, 0x00, 0x03, 0x00,	/* height 768 */
	0x08, 0x06, 0x00, 0x00, 0x00,
};

static const unsigned char jpeg_head[] = {
	0xff, 0xd8,			/* SOI */
	0xff, 0xe0, 0x00, 0x04, 0x00, 0x00,	/* APP0, 4 bytes */
	0xff, 0xc0, 0x00, 0x11, 0x08,		/* SOF0, 17 bytes, precision */
	0x01, 0xe0,			/* height 480 */
	0x02, 0x80,			/* width 640 */
	0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
	0xff, 0xd9,			/* EOI */
};

static const unsigned char gif_head[] = {
	'G', 'I', 'F', '8', '9', 'a',
	0x20, 0x00,			/* width 32 */
	0x10, 0x00,			/* height 16 */
	0x00, 0x00, 0x00,
};

static const unsigned char webp_head[] = {
	'R', 'I', 'F', 'F',
	0x2a, 0x00, 0x00, 0x00,		/* file size */
	'W', 'E', 'B', 'P',
	'V', 'P', '8', 'X',
	0x0a, 0x00, 0x00, 0x00,		/* chunk size */
	0x00, 0x00, 0x00, 0x00,		/* flags and reserved */
	0x1f, 0x03, 0x00,		/* canvas width - 1 = 799 */
	0x57, 0x02, 0x00,		/* canvas height - 1 = 599 */
};

int media_sniff_types(void)
{
	enum fyai_media_type type;
	int rc;

	type = FYAI_MEDIA_TYPE_UNKNOWN;
	rc = fyai_media_sniff(png_head, sizeof(png_head), &type);
	FYAI_TCHECK(!rc && type == FYAI_MEDIA_TYPE_PNG);
	rc = fyai_media_sniff(jpeg_head, sizeof(jpeg_head), &type);
	FYAI_TCHECK(!rc && type == FYAI_MEDIA_TYPE_JPEG);
	rc = fyai_media_sniff(gif_head, sizeof(gif_head), &type);
	FYAI_TCHECK(!rc && type == FYAI_MEDIA_TYPE_GIF);
	rc = fyai_media_sniff(webp_head, sizeof(webp_head), &type);
	FYAI_TCHECK(!rc && type == FYAI_MEDIA_TYPE_WEBP);

	/* Text, a truncated signature, and nothing at all are not images. */
	rc = fyai_media_sniff("hello", 5, &type);
	FYAI_TCHECK(rc < 0 && errno == ENOTSUP);
	rc = fyai_media_sniff(png_head, 4, &type);
	FYAI_TCHECK(rc < 0 && errno == ENOTSUP);
	rc = fyai_media_sniff(NULL, 0, &type);
	FYAI_TCHECK(rc < 0 && errno == ENOTSUP);
	return 0;
}

int media_dimensions(void)
{
	unsigned int width, height;
	int rc;

	rc = fyai_media_dimensions(png_head, sizeof(png_head),
				   FYAI_MEDIA_TYPE_PNG, &width, &height);
	FYAI_TCHECK(!rc && width == 1024 && height == 768);
	rc = fyai_media_dimensions(jpeg_head, sizeof(jpeg_head),
				   FYAI_MEDIA_TYPE_JPEG, &width, &height);
	FYAI_TCHECK(!rc && width == 640 && height == 480);
	rc = fyai_media_dimensions(gif_head, sizeof(gif_head),
				   FYAI_MEDIA_TYPE_GIF, &width, &height);
	FYAI_TCHECK(!rc && width == 32 && height == 16);
	rc = fyai_media_dimensions(webp_head, sizeof(webp_head),
				   FYAI_MEDIA_TYPE_WEBP, &width, &height);
	FYAI_TCHECK(!rc && width == 800 && height == 600);

	/* A header that stops before the size is not a size. */
	rc = fyai_media_dimensions(png_head, 20, FYAI_MEDIA_TYPE_PNG,
				   &width, &height);
	FYAI_TCHECK(rc < 0 && errno == EINVAL);
	rc = fyai_media_dimensions(gif_head, 8, FYAI_MEDIA_TYPE_GIF,
				   &width, &height);
	FYAI_TCHECK(rc < 0 && errno == EINVAL);
	rc = fyai_media_dimensions(webp_head, 24, FYAI_MEDIA_TYPE_WEBP,
				   &width, &height);
	FYAI_TCHECK(rc < 0 && errno == EINVAL);
	return 0;
}

int media_type_names(void)
{
	FYAI_TCHECK(!strcmp(fyai_media_type_name(FYAI_MEDIA_TYPE_PNG),
			    "image/png"));
	FYAI_TCHECK(!fyai_media_type_name(FYAI_MEDIA_TYPE_UNKNOWN));
	FYAI_TCHECK(fyai_media_type_parse("image/png") == FYAI_MEDIA_TYPE_PNG);
	FYAI_TCHECK(fyai_media_type_parse("PNG") == FYAI_MEDIA_TYPE_PNG);
	FYAI_TCHECK(fyai_media_type_parse("image/jpeg") == FYAI_MEDIA_TYPE_JPEG);
	FYAI_TCHECK(fyai_media_type_parse("jpg") == FYAI_MEDIA_TYPE_JPEG);
	FYAI_TCHECK(fyai_media_type_parse("image/webp") == FYAI_MEDIA_TYPE_WEBP);
	FYAI_TCHECK(fyai_media_type_parse("image/tiff") ==
		    FYAI_MEDIA_TYPE_UNKNOWN);
	FYAI_TCHECK(fyai_media_type_parse("") == FYAI_MEDIA_TYPE_UNKNOWN);
	FYAI_TCHECK(fyai_media_type_parse(NULL) == FYAI_MEDIA_TYPE_UNKNOWN);
	FYAI_TCHECK(fyai_media_type_is_image(FYAI_MEDIA_TYPE_GIF));
	FYAI_TCHECK(!fyai_media_type_is_image(FYAI_MEDIA_TYPE_UNKNOWN));
	return 0;
}

/* A canonical image part keeps the reference and the numbers a reader shows. */
int media_content_parts(void)
{
	struct fy_generic_builder_cfg gb_cfg = {
		.flags = FYGBCF_SCOPE_LEADER,
	};
	struct fyai_media_image image;
	struct fy_generic_builder *gb;
	fy_generic content, part, text, images;
	const char *s;

	gb = fy_generic_builder_create(&gb_cfg);
	FYAI_TCHECK(gb);

	memset(&image, 0, sizeof(image));
	image.type = FYAI_MEDIA_TYPE_PNG;
	image.width = 1024;
	image.height = 768;
	image.bytes = 98304;
	strcpy(image.digest, "0123456789abcdef0123456789abcdef"
			     "0123456789abcdef0123456789abcdef");
	image.name = strdup("screenshot");
	FYAI_TCHECK(image.name);

	part = fyai_media_image_part(gb, &image);
	FYAI_TCHECK(fy_is_mapping(part));
	FYAI_TCHECK(fyai_media_part_is_image(part));
	s = fy_get(part, "media_type", "");
	FYAI_TCHECK(!strcmp(s, "image/png"));
	s = fy_get(part, "digest", "");
	FYAI_TCHECK(!strcmp(s, image.digest));
	FYAI_TCHECK(fy_get(part, "width", 0LL) == 1024);
	FYAI_TCHECK(fy_get(part, "height", 0LL) == 768);
	FYAI_TCHECK(fy_get(part, "bytes", 0LL) == 98304);
	s = fy_get(part, "name", "");
	FYAI_TCHECK(!strcmp(s, "screenshot"));

	/* A text run and a foreign part are not images. */
	FYAI_TCHECK(!fyai_media_part_is_image(
			fy_mapping(gb, "type", "text", "text", "hello")));
	FYAI_TCHECK(!fyai_media_part_is_image(
			fy_mapping(gb, "type", "tool_result")));
	FYAI_TCHECK(!fyai_media_part_is_image(fy_invalid));
	FYAI_TCHECK(!fyai_media_part_is_image(fy_value("hi")));

	/* A string content is its own text, and carries no image. */
	content = fy_value("plain words");
	text = fyai_media_text(gb, content);
	s = fy_castp(&text, "");
	FYAI_TCHECK(!strcmp(s, "plain words"));
	FYAI_TCHECK(!fyai_media_content_has_images(content));
	FYAI_TCHECK(fy_empty(fyai_media_parts(gb, content)));

	/* A sequence gives its text runs joined, and its image parts in order. */
	content = fy_sequence(gb,
		fy_mapping(gb, "type", "text", "text", "look at this"),
		part,
		fy_mapping(gb, "type", "text", "text", ": done"));
	FYAI_TCHECK(fyai_media_content_has_images(content));
	text = fyai_media_text(gb, content);
	s = fy_castp(&text, "");
	FYAI_TCHECK(!strcmp(s, "look at this: done"));
	images = fyai_media_parts(gb, content);
	FYAI_TCHECK(fy_is_sequence(images) && fy_len(images) == 1);
	FYAI_TCHECK(fy_equal(fy_get_at(images, 0), part));

	/* A null content has no text and no image. */
	text = fyai_media_text(gb, fy_null);
	FYAI_TCHECK(fy_is_string(text) && fy_empty(text));
	FYAI_TCHECK(!fyai_media_content_has_images(fy_null));

	free(image.name);
	fy_generic_builder_destroy(gb);
	return 0;
}

#ifdef __linux__
/* Write the bytes of @data to a scratch file and return its descriptor. */
static int media_scratch_image(const char *tag, const void *data, size_t len)
{
	const char *path;
	int fd;

	path = fyai_test_scratch_file(tag, ".bin");
	FYAI_TCHECK(path);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	FYAI_TCHECK(fd >= 0);
	FYAI_TCHECK(write(fd, data, len) == (ssize_t)len);
	FYAI_TCHECK(lseek(fd, 0, SEEK_SET) == 0);
	return fd;
}

/* Write the bytes of @data to the scratch file @path. */
static int media_scratch_write(const char *path, const void *data, size_t len)
{
	ssize_t wrote;
	int fd, rc;

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	FYAI_TCHECK(fd >= 0);
	wrote = write(fd, data, len);
	rc = wrote == (ssize_t)len ? 0 : -1;
	close(fd);
	return rc;
}

int media_image_roundtrip(void)
{
	struct fy_generic_builder *gb;
	struct fyai_media_image image;
	fy_generic data;
	fy_generic_sized_string raw;
	int fd, rc;

	gb = fy_generic_builder_create(NULL);
	FYAI_TCHECK(gb);
	fd = media_scratch_image("media-arena-png", png_head, sizeof(png_head));
	rc = fyai_media_image_read(NULL, gb, fd, 0, NULL, "clipboard", &image);
	FYAI_TCHECK(!rc);
	FYAI_TCHECK(image.type == FYAI_MEDIA_TYPE_PNG);
	FYAI_TCHECK(image.width == 1024 && image.height == 768);
	FYAI_TCHECK(image.bytes == sizeof(png_head));
	FYAI_TCHECK(strlen(image.digest) == FYAI_MEDIA_DIGEST_SIZE - 1);
	FYAI_TCHECK(image.name && !strcmp(image.name, "clipboard"));
	data = image.data;
	raw = fy_castp(&data, fy_szstr_empty);
	FYAI_TCHECK(raw.size == sizeof(png_head));
	FYAI_TCHECK(!memcmp(raw.data, png_head, sizeof(png_head)));
	fyai_media_image_release(&image);

	rc = fyai_media_image_read(NULL, gb, fd, 0, "image/png", NULL, &image);
	FYAI_TCHECK(!rc && fy_equal(data, image.data));
	rc = fyai_media_image_read(NULL, gb, fd, 0, "image/jpeg", NULL, &image);
	FYAI_TCHECK(rc < 0);
	close(fd);
	fy_generic_builder_destroy(gb);
	return 0;
}

int media_image_limits(void)
{
	struct fy_generic_builder *gb;
	struct fyai_media_image image;
	unsigned char zero_width[sizeof(png_head)];
	int fd, rc;

	gb = fy_generic_builder_create(NULL);
	FYAI_TCHECK(gb);
	fd = media_scratch_image("media-limits-png", png_head, sizeof(png_head));
	rc = fyai_media_image_read(NULL, gb, fd, 8, NULL, NULL, &image);
	FYAI_TCHECK(rc < 0);
	close(fd);
	fd = media_scratch_image("media-limits-text", "hello", 5);
	rc = fyai_media_image_read(NULL, gb, fd, 0, NULL, NULL, &image);
	FYAI_TCHECK(rc < 0);
	close(fd);
	fd = media_scratch_image("media-limits-empty", "", 0);
	rc = fyai_media_image_read(NULL, gb, fd, 0, NULL, NULL, &image);
	FYAI_TCHECK(rc < 0 && !image.digest[0] && !image.name);
	close(fd);
	fd = open(fyai_test_scratch_dir("media-limits-dir"),
		  O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	FYAI_TCHECK(fd >= 0);
	rc = fyai_media_image_read(NULL, gb, fd, 0, NULL, NULL, &image);
	FYAI_TCHECK(rc < 0 && !image.digest[0] && !image.name);
	close(fd);
	memcpy(zero_width, png_head, sizeof(zero_width));
	memset(zero_width + 16, 0, 4);
	fd = media_scratch_image("media-limits-zero-width", zero_width, sizeof(zero_width));
	rc = fyai_media_image_read(NULL, gb, fd, 0, NULL, NULL, &image);
	FYAI_TCHECK(rc < 0 && !image.digest[0] && !image.name);
	close(fd);
	fy_generic_builder_destroy(gb);
	return 0;
}
/*
 * An attachment waits in the context and the next user message carries it, as
 * a text run and an image part. The message after it is text only, because an
 * attachment travels with one message.
 */
int media_pending_message(void)
{
	struct fy_generic_builder_cfg gb_cfg = {
		.flags = FYGBCF_SCOPE_LEADER,
	};
	struct fyai_cfg cfg;
	struct fyai_ctx ctx;
	fy_generic msg, content, text, part;
	const char *path;
	int rc;

	path = fyai_test_scratch_file("media-pending-png", ".png");
	FYAI_TCHECK(path);
	rc = media_scratch_write(path, png_head, sizeof(png_head));
	FYAI_TCHECK(!rc);

	memset(&cfg, 0, sizeof(cfg));
	memset(&ctx, 0, sizeof(ctx));
	ctx.cfg = &cfg;
	ctx.gb = ctx.transient_gb = ctx.durable_gb =
		fy_generic_builder_create(&gb_cfg);
	FYAI_TCHECK(ctx.gb);
	cfg.gb = ctx.gb;
	cfg.media_max_bytes = 1024 * 1024;
	cfg.media_max_per_message = 2;
	ctx.media_pending = fy_seq_empty;

	rc = fyai_media_attach_path(&ctx, path, NULL, "shot");
	FYAI_TCHECK(!rc);
	FYAI_TCHECK(fyai_media_pending_any(&ctx));

	msg = fyai_make_user_message(&ctx, "what is wrong here?");
	FYAI_TCHECK(fy_is_mapping(msg));
	FYAI_TCHECK(fy_equal(fy_get(msg, "role"), "user"));
	content = fy_get(msg, "content");
	FYAI_TCHECK(fy_is_sequence(content) && fy_len(content) == 2);
	FYAI_TCHECK(fy_equal(fy_get_at_path(content, 0, "type"), "text"));
	FYAI_TCHECK(fy_equal(fy_get_at_path(content, 0, "text"),
			     "what is wrong here?"));
	FYAI_TCHECK(fyai_media_part_is_image(fy_get_at(content, 1)));
	FYAI_TCHECK(fy_equal(fy_get_at_path(content, 1, "media_type"),
			     "image/png"));
	part = fy_get_at(content, 1);
	FYAI_TCHECK(fy_get(part, "width", 0LL) == 1024);
	FYAI_TCHECK(fy_equal(fy_get_at_path(content, 1, "name"), "shot"));

	/* The readers in the rest of the program still see the words. */
	text = fyai_media_text(ctx.gb, content);
	FYAI_TCHECK(fy_equal(text, "what is wrong here?"));
	FYAI_TCHECK(fyai_media_content_has_images(content));
	FYAI_TCHECK(!fyai_media_pending_any(&ctx));

	/* The next message carries no attachment. */
	msg = fyai_make_user_message(&ctx, "and now?");
	FYAI_TCHECK(fy_is_string(fy_get(msg, "content")));

	/* An image with no words makes one part, not an empty text run. */
	rc = fyai_media_attach_path(&ctx, path, "image/png", "again");
	FYAI_TCHECK(!rc);
	msg = fyai_make_user_message(&ctx, "");
	content = fy_get(msg, "content");
	FYAI_TCHECK(fy_is_sequence(content) && fy_len(content) == 1);
	FYAI_TCHECK(fyai_media_part_is_image(fy_get_at(content, 0)));

	/* Two are allowed, a third is refused with a cause. */
	rc = fyai_media_attach_path(&ctx, path, NULL, NULL);
	FYAI_TCHECK(!rc);
	rc = fyai_media_attach_path(&ctx, path, NULL, NULL);
	FYAI_TCHECK(!rc);
	rc = fyai_media_attach_path(&ctx, path, NULL, NULL);
	FYAI_TCHECK(rc < 0);
	FYAI_TCHECK(fy_len(ctx.media_pending) == 2);
	fyai_diag_reset(fyai_ctx_diag(&ctx));
	fyai_media_pending_clear(&ctx);

	fy_generic_builder_destroy(ctx.gb);
	return 0;
}

/*
 * A pinned root reads one published state, so a message that takes an
 * attachment would be a write. The attachment is refused before it is read.
 */
int media_pinned_root(void)
{
	struct fy_generic_builder_cfg gb_cfg = {
		.flags = FYGBCF_SCOPE_LEADER,
	};
	struct fyai_cfg cfg;
	struct fyai_ctx ctx;
	const char *path;
	int rc;

	path = fyai_test_scratch_file("media-pinned-png", ".png");
	FYAI_TCHECK(path);
	rc = media_scratch_write(path, png_head, sizeof(png_head));
	FYAI_TCHECK(!rc);

	memset(&cfg, 0, sizeof(cfg));
	memset(&ctx, 0, sizeof(ctx));
	ctx.gb = ctx.transient_gb = ctx.durable_gb =
		fy_generic_builder_create(&gb_cfg);
	FYAI_TCHECK(ctx.gb);
	cfg.gb = ctx.gb;
	cfg.root_pinned = true;
	cfg.media_max_bytes = 1024 * 1024;
	cfg.media_max_per_message = 4;
	ctx.cfg = &cfg;
	ctx.media_pending = fy_seq_empty;

	rc = fyai_media_attach_path(&ctx, path, NULL, "shot");
	FYAI_TCHECK(rc < 0);
	FYAI_TCHECK(!fyai_media_pending_any(&ctx));

	fyai_diag_reset(fyai_ctx_diag(&ctx));
	fy_generic_builder_destroy(ctx.gb);
	return 0;
}

#else
int media_image_roundtrip(void)
{
	return 0;
}

int media_image_limits(void)
{
	return 0;
}

int media_pending_message(void)
{
	return 0;
}

int media_pinned_root(void)
{
	return 0;
}
#endif

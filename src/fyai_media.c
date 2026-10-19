/*
 * fyai_media.c - the attachments that travel with a message
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 *
 * SPDX-License-Identifier: MIT
 */

#define FYAI_MODULE FYAIEM_MEDIA

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include <libfyaml/libfyaml-blake3.h>

#include "fyai_media.h"
#include "fyai_diag.h"
#include "utils.h"

/*
 * A unit test reads an image with no context: report only when there is one
 * to report to, and take the cleanup label either way.
 */
#define media_check(_ctx, _cond, _label, _fmt, ...) \
	do { \
		if (!(_cond)) { \
			if (_ctx) \
				fyai_error((_ctx), (_fmt), ## __VA_ARGS__); \
			goto _label; \
		} \
	} while (0)

static uint32_t media_be32(const unsigned char *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
	       (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

static uint32_t media_le24(const unsigned char *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16;
}

static uint32_t media_le32(const unsigned char *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
	       (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint32_t media_le16(const unsigned char *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8;
}

static uint32_t media_be16(const unsigned char *p)
{
	return (uint32_t)p[0] << 8 | (uint32_t)p[1];
}

const char *fyai_media_type_name(enum fyai_media_type type)
{
	switch (type) {
	case FYAI_MEDIA_TYPE_PNG:
		return "image/png";
	case FYAI_MEDIA_TYPE_JPEG:
		return "image/jpeg";
	case FYAI_MEDIA_TYPE_GIF:
		return "image/gif";
	case FYAI_MEDIA_TYPE_WEBP:
		return "image/webp";
	case FYAI_MEDIA_TYPE_UNKNOWN:
		break;
	}
	return NULL;
}

enum fyai_media_type fyai_media_type_parse(const char *name)
{
	static const struct {
		const char *name;
		enum fyai_media_type type;
	} names[] = {
		{ "image/png",		FYAI_MEDIA_TYPE_PNG },
		{ "png",		FYAI_MEDIA_TYPE_PNG },
		{ "image/jpeg",		FYAI_MEDIA_TYPE_JPEG },
		{ "image/jpg",		FYAI_MEDIA_TYPE_JPEG },
		{ "jpeg",		FYAI_MEDIA_TYPE_JPEG },
		{ "jpg",		FYAI_MEDIA_TYPE_JPEG },
		{ "image/gif",		FYAI_MEDIA_TYPE_GIF },
		{ "gif",		FYAI_MEDIA_TYPE_GIF },
		{ "image/webp",		FYAI_MEDIA_TYPE_WEBP },
		{ "webp",		FYAI_MEDIA_TYPE_WEBP },
	};
	size_t i;

	if (!name || !*name)
		return FYAI_MEDIA_TYPE_UNKNOWN;
	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		if (!strcasecmp(name, names[i].name))
			return names[i].type;
	}
	return FYAI_MEDIA_TYPE_UNKNOWN;
}

bool fyai_media_type_is_image(enum fyai_media_type type)
{
	return type != FYAI_MEDIA_TYPE_UNKNOWN;
}

void fyai_media_image_release(struct fyai_media_image *image)
{
	if (!image)
		return;
	free(image->name);
	image->name = NULL;
}

int fyai_media_sniff(const void *data, size_t len, enum fyai_media_type *typep)
{
	const unsigned char *p = data;

	if (p && len >= 8 && !memcmp(p, "\x89PNG\r\n\x1a\n", 8)) {
		*typep = FYAI_MEDIA_TYPE_PNG;
		return 0;
	}
	if (p && len >= 3 && p[0] == 0xff && p[1] == 0xd8 && p[2] == 0xff) {
		*typep = FYAI_MEDIA_TYPE_JPEG;
		return 0;
	}
	if (p && len >= 6 &&
	    (!memcmp(p, "GIF87a", 6) || !memcmp(p, "GIF89a", 6))) {
		*typep = FYAI_MEDIA_TYPE_GIF;
		return 0;
	}
	if (p && len >= 12 && !memcmp(p, "RIFF", 4) &&
	    !memcmp(p + 8, "WEBP", 4)) {
		*typep = FYAI_MEDIA_TYPE_WEBP;
		return 0;
	}
	errno = ENOTSUP;
	return -1;
}

/*
 * Walk the segment headers of a JPEG stream to its frame header, which holds
 * the size. A segment with no length field is skipped; a file whose frame
 * header lies beyond @len is not sized.
 */
static int media_dimensions_jpeg(const unsigned char *p, size_t len,
				 unsigned int *widthp, unsigned int *heightp,
				 size_t *walkp)
{
	size_t pos = 2;
	unsigned int marker;
	size_t segment;

	while (pos + 1 < len) {
		if (p[pos] != 0xff) {
			errno = EINVAL;
			return -1;
		}
		marker = p[pos + 1];
		pos += 2;
		/* Fill bytes of a marker: 0xff 0xff ... marker. */
		while (marker == 0xff && pos < len) {
			marker = p[pos];
			pos++;
		}
		/* A marker with no segment: TEM, RSTn, SOI. */
		if (marker == 0x01 || marker == 0xd8 ||
		    (marker >= 0xd0 && marker <= 0xd7))
			continue;
		/* EOI, or the start of the scan that follows the frame. */
		if (marker == 0xd9 || marker == 0xda)
			break;
		if (pos + 1 >= len)
			break;
		segment = (size_t)p[pos] << 8 | p[pos + 1];
		if (segment < 2) {
			errno = EINVAL;
			return -1;
		}
		/*
		 * SOF0-SOF15, less the markers of that range that are not a
		 * frame header: DHT, JPG, DAC.
		 */
		if (marker >= 0xc0 && marker <= 0xcf &&
		    marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
			if (pos + 7 > len)
				break;
			/* A JPEG segment states its values in network order. */
			*heightp = media_be16(p + pos + 3);
			*widthp = media_be16(p + pos + 5);
			return 0;
		}
		pos += segment;
	}
	if (walkp)
		*walkp = pos;
	errno = EINVAL;
	return -1;
}

/* The canvas of a WebP file, from its first chunk. */
static int media_dimensions_webp(const unsigned char *p, size_t len,
				 unsigned int *widthp, unsigned int *heightp)
{
	uint32_t bits;

	if (len < 20) {
		errno = EINVAL;
		return -1;
	}
	if (!memcmp(p + 12, "VP8X", 4)) {
		if (len < 30) {
			errno = EINVAL;
			return -1;
		}
		*widthp = media_le24(p + 24) + 1;
		*heightp = media_le24(p + 27) + 1;
		return 0;
	}
	if (!memcmp(p + 12, "VP8L", 4)) {
		if (len < 25 || p[20] != 0x2f) {
			errno = EINVAL;
			return -1;
		}
		bits = media_le32(p + 21);
		*widthp = (bits & 0x3fff) + 1;
		*heightp = ((bits >> 14) & 0x3fff) + 1;
		return 0;
	}
	if (!memcmp(p + 12, "VP8 ", 4)) {
		if (len < 30 || p[23] != 0x9d || p[24] != 0x01 || p[25] != 0x2a) {
			errno = EINVAL;
			return -1;
		}
		*widthp = media_le16(p + 26) & 0x3fff;
		*heightp = media_le16(p + 28) & 0x3fff;
		return 0;
	}
	errno = EINVAL;
	return -1;
}

int fyai_media_dimensions(const void *data, size_t len,
			  enum fyai_media_type type,
			  unsigned int *widthp, unsigned int *heightp)
{
	const unsigned char *p = data;

	if (!p) {
		errno = EINVAL;
		return -1;
	}
	switch (type) {
	case FYAI_MEDIA_TYPE_PNG:
		/* The signature, the IHDR length, then its type and size. */
		if (len < 26 || memcmp(p + 12, "IHDR", 4)) {
			errno = EINVAL;
			return -1;
		}
		*widthp = media_be32(p + 16);
		*heightp = media_be32(p + 20);
		return 0;
	case FYAI_MEDIA_TYPE_JPEG:
		return media_dimensions_jpeg(p, len, widthp, heightp, NULL);
	case FYAI_MEDIA_TYPE_GIF:
		/* The logical screen descriptor follows the version. */
		if (len < 10) {
			errno = EINVAL;
			return -1;
		}
		*widthp = media_le16(p + 6);
		*heightp = media_le16(p + 8);
		return 0;
	case FYAI_MEDIA_TYPE_WEBP:
		return media_dimensions_webp(p, len, widthp, heightp);
	case FYAI_MEDIA_TYPE_UNKNOWN:
		break;
	}
	errno = EINVAL;
	return -1;
}

/* Write the lowercase hex form of the BLAKE3-256 digest of @data. */
static int media_digest(char out[FYAI_MEDIA_DIGEST_SIZE], const void *data,
			size_t len)
{
	static const char hex[] = "0123456789abcdef";
	struct fy_blake3_hasher_cfg hcfg = { .num_threads = -1 };
	struct fy_blake3_hasher *hasher;
	const uint8_t *hash;
	size_t i;

	hasher = fy_blake3_hasher_create(&hcfg);
	if (!hasher)
		return -1;
	hash = fy_blake3_hash(hasher, data, len);
	for (i = 0; hash && i < (FYAI_MEDIA_DIGEST_SIZE - 1) / 2; i++) {
		out[i * 2] = hex[hash[i] >> 4];
		out[i * 2 + 1] = hex[hash[i] & 15];
	}
	out[i * 2] = '\0';
	fy_blake3_hasher_destroy(hasher);
	return hash ? 0 : -1;
}

int fyai_media_image_bytes(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			   const void *data, size_t len, const char *declared,
			   const char *name, struct fyai_media_image *image)
{
	fy_generic_sized_string bytes = { .data = data, .size = len };
	enum fyai_media_type type, want;
	unsigned int width = 0, height = 0;
	int rc;

	if (!gb || !image || (!data && len)) {
		errno = EINVAL;
		return -1;
	}
	memset(image, 0, sizeof(*image));
	image->data = fy_invalid;
	media_check(ctx, len, out, "an attachment holds no bytes");
	rc = fyai_media_sniff(data, len, &type);
	media_check(ctx, !rc, out, "the attachment is not a PNG, JPEG, GIF or "
		    "WebP image");

	/* A stated type must name a supported type and match the bytes. */
	if (declared && *declared) {
		want = fyai_media_type_parse(declared);
		media_check(ctx, want != FYAI_MEDIA_TYPE_UNKNOWN, out,
			    "the media type '%s' is not supported", declared);
		media_check(ctx, want == type, out,
			    "the media type '%s' does not match the attachment, "
			    "which is %s", declared, fyai_media_type_name(type));
	}

	rc = fyai_media_dimensions(data, len < FYAI_MEDIA_HEAD_MAX ?
				   len : FYAI_MEDIA_HEAD_MAX,
				   type, &width, &height);
	media_check(ctx, !rc, out, "could not read the size of the %s "
		    "attachment", fyai_media_type_name(type));
	media_check(ctx, width && height, out, "the %s attachment reports no "
		    "pixel size", fyai_media_type_name(type));

	rc = media_digest(image->digest, data, len);
	media_check(ctx, !rc, out, "could not hash the attachment");
	image->data = fy_value(gb, bytes);
	media_check(ctx, fy_is_string(image->data), out,
		    "could not copy %zu bytes of the attachment", len);
	image->type = type;
	image->width = width;
	image->height = height;
	image->bytes = len;
	if (name && *name) {
		image->name = strdup(name);
		media_check(ctx, image->name, out,
			    "could not copy the attachment name");
	}
	return 0;

out:
	fyai_media_image_release(image);
	memset(image, 0, sizeof(*image));
	image->data = fy_invalid;
	return -1;
}

/* Read @len bytes of @fd from its start, owned by the caller, or NULL. */
static unsigned char *media_read_all(struct fyai_ctx *ctx, int fd, size_t len)
{
	unsigned char *buf;
	size_t done = 0;
	ssize_t got;

	buf = malloc(len);
	media_check(ctx, buf, err, "could not allocate %zu bytes for an "
		    "attachment", len);
	while (done < len) {
		got = pread(fd, buf + done, len - done, (off_t)done);
		if (got < 0 && errno == EINTR)
			continue;
		media_check(ctx, got >= 0, err_free,
			    "could not read the attachment: %s",
			    strerror(errno));
		media_check(ctx, got, err_free, "the attachment ended early");
		done += (size_t)got;
	}
	return buf;

err_free:
	free(buf);
err:
	return NULL;
}

int fyai_media_image_read(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			  int fd, uint64_t max_bytes, const char *declared,
			  const char *name, struct fyai_media_image *image)
{
	unsigned char *data;
	struct stat st;
	int rc;

	if (!gb || !image || fd < 0) {
		errno = EINVAL;
		return -1;
	}
	memset(image, 0, sizeof(*image));
	image->data = fy_invalid;
	rc = fstat(fd, &st);
	media_check(ctx, !rc, err, "could not stat the attachment: %s",
		    strerror(errno));
	media_check(ctx, S_ISREG(st.st_mode), err,
		    "an attachment must be a regular file");
	media_check(ctx, st.st_size > 0, err, "an attachment holds no bytes");
	media_check(ctx, !max_bytes || (uint64_t)st.st_size <= max_bytes, err,
		    "the attachment holds %lld bytes, more than the %llu byte "
		    "limit", (long long)st.st_size,
		    (unsigned long long)max_bytes);
	media_check(ctx, (uint64_t)st.st_size <= SIZE_MAX, err,
		    "the attachment holds %lld bytes, more than fits in memory",
		    (long long)st.st_size);
	data = media_read_all(ctx, fd, (size_t)st.st_size);
	if (!data)
		goto err;
	rc = fyai_media_image_bytes(ctx, gb, data, (size_t)st.st_size,
				    declared, name, image);
	free(data);
	return rc;

err:
	return -1;
}

/*
 * fyai_media.h - the attachments that travel with a message
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 *
 * SPDX-License-Identifier: MIT
 *
 * The bytes of an image are a binary string in the image part of the message
 * that carries it, so they live in the arena with the conversation (see
 * doc/media.md). This interface defines media types and canonical parts.
 * Provider code derives the wire form at the request boundary.
 */

#ifndef FYAI_MEDIA_H
#define FYAI_MEDIA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <libfyaml/libfyaml-generic.h>

struct fyai_ctx;

/* The media types fyai recognises, from the bytes themselves. */
enum fyai_media_type {
	FYAI_MEDIA_TYPE_UNKNOWN,
	FYAI_MEDIA_TYPE_PNG,
	FYAI_MEDIA_TYPE_JPEG,
	FYAI_MEDIA_TYPE_GIF,
	FYAI_MEDIA_TYPE_WEBP,
};

/* The wire name of @type ("image/png"), or NULL for unknown. */
const char *fyai_media_type_name(enum fyai_media_type type);
/* The type that @name names, or FYAI_MEDIA_TYPE_UNKNOWN. */
enum fyai_media_type fyai_media_type_parse(const char *name);
/* Whether a model can take @type as an image part. */
bool fyai_media_type_is_image(enum fyai_media_type type);

/* The size of the hex digest of an image, with its NUL. */
#define FYAI_MEDIA_DIGEST_SIZE (32 * 2 + 1)

/* One image, as a message carries it. */
struct fyai_media_image {
	enum fyai_media_type type;
	unsigned int width;
	unsigned int height;
	uint64_t bytes;
	/* The bytes, a string in the builder that read them. */
	fy_generic data;
	/* The lowercase hex BLAKE3-256 digest of the bytes, with its NUL. */
	char digest[FYAI_MEDIA_DIGEST_SIZE];
	/* The name the caller gave it, owned here, or NULL. */
	char *name;
};

void fyai_media_image_release(struct fyai_media_image *image);

/*
 * Read the type of an image from its leading bytes. Return 0 and set @typep,
 * or -1 with errno set to ENOTSUP for bytes of no recognised type.
 */
int fyai_media_sniff(const void *data, size_t len, enum fyai_media_type *typep);

/*
 * Read the pixel size of an image from its leading bytes, which must hold its
 * header. Return 0 and set @widthp and @heightp, or -1 with errno set to
 * EINVAL when the bytes are truncated or hold no size.
 */
int fyai_media_dimensions(const void *data, size_t len,
			  enum fyai_media_type type,
			  unsigned int *widthp, unsigned int *heightp);

/*
 * Copy @len bytes at @data into @gb and fill @image. @declared is the media
 * type the caller states, or NULL to take the type of the bytes; a stated
 * type that names no supported type, or does not match the bytes, is an
 * error. @name is stored with the image, or NULL. A diagnostic names what
 * failed; @ctx may be NULL when there is nothing to report to.
 */
int fyai_media_image_bytes(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			   const void *data, size_t len, const char *declared,
			   const char *name, struct fyai_media_image *image);

/*
 * The same for the bytes of @fd, a regular file, read from its start. A file
 * larger than @max_bytes is refused; 0 removes the bound.
 */
int fyai_media_image_read(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			  int fd, uint64_t max_bytes, const char *declared,
			  const char *name, struct fyai_media_image *image);

/* How many bytes of the head of a file are read to type it and size it. */
#define FYAI_MEDIA_HEAD_MAX (256 * 1024)

/* The part type of an image, and of a text run of a content sequence. */
#define FYAI_MEDIA_PART_IMAGE	"image"
#define FYAI_MEDIA_PART_TEXT	"text"

/*
 * A canonical message carries one image as a part of its content sequence
 * (doc/media.md). Content readers use these helpers to extract text and image
 * parts.
 */

/* The canonical part of @image, built in @gb; it holds @image->data. */
fy_generic fyai_media_image_part(struct fy_generic_builder *gb,
				 const struct fyai_media_image *image);

/* Whether @part is an image part of a content sequence. */
bool fyai_media_part_is_image(fy_generic part);

/* Whether @content carries at least one image part. */
bool fyai_media_content_has_images(fy_generic content);

/*
 * The image parts of @content, in order, built in @gb. A string content and
 * a content with no image part give an empty sequence.
 */
fy_generic fyai_media_parts(struct fy_generic_builder *gb, fy_generic content);

/*
 * The text of @content, built in @gb: a string content itself, borrowed, or
 * the joined text parts of a sequence. An image part and a provider-specific
 * part contribute no text. Every reader that wants the words of a message and
 * not its media uses this function.
 */
fy_generic fyai_media_text(struct fy_generic_builder *gb, fy_generic content);

#endif

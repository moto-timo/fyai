/* SPDX-License-Identifier: MIT */
#ifndef FYAI_SETTINGS_H
#define FYAI_SETTINGS_H

#include "fyai.h"
#include "fyai_ask.h"

/*
 * The log @member of the store of this branch: `config_changes`, the
 * changes of the model that fyai applied, or `config_proposals`, those that
 * wait for the user. A sequence of entries named `cN` and `pN`; the empty
 * sequence when the branch has none. Borrowed from the arena.
 */
fy_generic fyai_settings_log(struct fyai_ctx *ctx, const char *member);

/*
 * The pending proposal @id with its explanation and the diff it makes over
 * the configuration in force, built in @gb: {id, explanation, diff}. Reports
 * the cause and returns fy_invalid when there is no such pending proposal or
 * it cannot be applied now.
 */
fy_generic fyai_settings_proposal_show(struct fyai_ctx *ctx,
				       struct fy_generic_builder *gb,
				       const char *id);

/*
 * Approve or reject the pending proposal @id, which the user named.
 * *@resultp is {id, status, change, diff}, built in @gb. Returns 0, or -1
 * with the cause reported. A session shows the review panel first, through
 * fyai_settings_review_open().
 */
int fyai_settings_proposal_decide(struct fyai_ctx *ctx,
				  struct fy_generic_builder *gb,
				  const char *id, bool approve,
				  fy_generic *resultp);

/*
 * The review of the pending proposal @id in the review panel. Open checks the
 * proposal over the configuration in force and makes its diff; the questions
 * go to fyai_ui_ask(), whose callback gives the replies to apply. Apply
 * applies the proposal when the user accepts it, or when @replies is NULL
 * because no panel asked; otherwise the proposal stays pending. The review
 * borrows @gb, which must live until free. Open reports the cause and
 * returns NULL on failure.
 */
struct fyai_settings_review;

struct fyai_settings_review *
fyai_settings_review_open(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			  const char *id);
fy_generic fyai_settings_review_questions(struct fyai_settings_review *r);
int fyai_settings_review_apply(struct fyai_settings_review *r,
			       const struct fyai_ask_reply *replies, size_t n,
			       fy_generic *resultp);
void fyai_settings_review_free(struct fyai_settings_review *r);

#endif

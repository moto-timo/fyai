/* SPDX-License-Identifier: MIT */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fyai.h"
#include "fyai_panel.h"
#include "fyai_test.h"
#include "fyai_test_registry.h"

FYAI_TEST_ENTRY(panel, diff_scrolls_and_resizes, panel_diff_scrolls_and_resizes)

int panel_diff_scrolls_and_resizes(void)
{
	struct fyai_cfg cfg = { .color = "off", .render_width = 80 };
	struct fyai_ctx ctx = { .cfg = &cfg };
	struct fyai_panel *p;
	char source[2048];
	size_t used;
	int i, total, top, rows;

	used = (size_t)snprintf(source, sizeof(source),
		"--- a/models.yaml\n+++ b/models.yaml\n@@ -0,0 +1,50 @@\n");
	for (i = 1; i <= 50; i++)
		used += (size_t)snprintf(source + used, sizeof(source) - used,
					"+model_%02d: true\n", i);
	p = fyai_panel_create(&ctx, FYAI_PANEL_DIFF);
	FYAI_TCHECK(p != NULL);
	if (!p)
		return 1;
	FYAI_TCHECK(!fyai_panel_update(p, source, 50, 5));
	FYAI_TCHECK(cfg.render_width == 80);
	fyai_panel_extent(p, &total, &top, &rows);
	FYAI_TCHECK(total > 50 && top == 0 && rows == 5);
	fyai_panel_scroll(p, 1, true);
	fyai_panel_extent(p, &total, &top, &rows);
	FYAI_TCHECK(top == 4);
	FYAI_TCHECK(!fyai_panel_update(p, source, 50, 5));
	fyai_panel_extent(p, &total, &top, &rows);
	FYAI_TCHECK(top == 4);
	for (i = 0; i < 20; i++)
		fyai_panel_scroll(p, 1, true);
	fyai_panel_extent(p, &total, &top, &rows);
	FYAI_TCHECK(top == total - rows);
	FYAI_TCHECK(strstr(fyai_panel_text(p), "model_50"));
	FYAI_TCHECK(!fyai_panel_update(p, source, 30, 8));
	fyai_panel_extent(p, &total, &top, &rows);
	FYAI_TCHECK(top > 0 && top <= total - rows && rows == 8);
	FYAI_TCHECK(!fyai_panel_update(p,
		"--- a/a.yaml\n+++ b/a.yaml\n@@ -1 +1 @@\n-a: 1\n+a: 2\n", 30, 8));
	fyai_panel_extent(p, &total, &top, &rows);
	FYAI_TCHECK(top == 0);
	fyai_panel_scroll(p, -1, true);
	fyai_panel_extent(p, &total, &top, &rows);
	FYAI_TCHECK(top == 0);
	fyai_panel_destroy(p);
	return 0;
}

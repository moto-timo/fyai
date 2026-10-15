# Page panels

A page can put a scrollable panel in any part of its body. The `panel` node
binds a named view to a string in the page state. Its type selects the renderer:
`diff` reads a unified diff, and `markdown` reads Markdown.

```yaml
page:
  - keys:
      PageUp: panel.scroll:changes/page-up
      PageDown: panel.scroll:changes/page-down
  - panel:
      id: changes
      type: diff
      source: ask.diff
      rows: {fraction: 0.5, min: 3, max: 24}
```

The panel ID is unique among the panels shown in a frame. `source` names a
string in the state; it can name any string supplied by the page producer.
The panel uses the width of its assigned region, with one column for its
scroll bar. `rows` is a number, a state binding such as `"{note.rows}"`, or a
fraction of the terminal height with optional `min` and `max` bounds.
`rows: {content: true, min, max}` takes the rows that the text renders to in
its cell. In the right cell of `columns`, `rows: {beside: N, min}` takes the
rows of the left cell, less the `N` rows above the panel in its own cell.

The scroll bar shows the position in all rendered rows. Its arrows move one
row, and its track moves one page. The mouse wheel moves the panel under the
pointer. A `keys` node binds keys while its part of the page is shown.
`panel.scroll:ID/up` and `panel.scroll:ID/down` move one row;
`panel.scroll:ID/page-up` and `panel.scroll:ID/page-down` move one page with
one row of overlap. Scrolling stops at either end.

A panel keeps its position across repaints and resizes. A new source starts
at the top. Removing a panel from the page releases its view.

The `columns` node places two page bodies beside each other. `left_cols`
accepts a column count, a state binding, or a fraction of the terminal width.
The right body takes the remaining columns. The row fits the taller body. The left body flows to its content, and a
panel with `beside` rows ends level with it.

```yaml
page:
  - columns:
      left_cols: {fraction: 0.4}
      left:
        - page: explanation
      right:
        - page: changes
```

The default review page is `pages.ask_permissions` in `data/page.yaml`.
It places the choices and a Markdown proposal panel on the left, and a diff
panel on the right. The review producer supplies `ask.proposal` and
`ask.diff`; the page defines their position, size, and key bindings.

## Input box

`pages.input_box` is the reusable native editor component. Include it with
`page: input_box` wherever the active reply belongs. Its `prompt` slot carries
the editor; the component supplies the configured card or rule framing. Keep
one instance visible per page so the editor has one region and one cursor.

The permission review is rendered above the main input box. Its explanation and choices share
the left column, its diff occupies the right column, and the input box spans
the width beneath both. Typing a reply sends that reply to the model and
rejects the proposed change.

## Focus

`page.focus:NAME` selects a component and exposes its name as `input.focus`.
`input.focused.NAME` is true for that component. A page uses these state values
to show its focus indicator and select its key bindings. The native editor
uses the name `prompt`. Typing returns focus to it; clicking a panel focuses
that panel's focus target. The layout defines the focus targets and their
neighbors. The choices show their selection bar only while they hold the focus. Panels use the
existing focus ground and edge settings, shared with Ctrl-T tile focus.
An optional panel `focus` names a shared focus target instead of its panel ID.

In a permission review, Right moves from the choices to the diff. Down from
the last choice moves to the input box; Up from that box returns to the
choices. Left from the diff returns to the choices. Up and Down scroll the
focused diff, while Page Up and Page Down scroll it from any review component.
Tab cycles through choices, diff, and input; Shift-Tab reverses the cycle.
Left and Right keep their editing behavior in the input box.

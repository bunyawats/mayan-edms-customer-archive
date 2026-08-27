"""Server-side bulk-selection state, keyed by an opaque per-browser session
id (see main.py's SessionCookieMiddleware — not a login, just a cookie so
two different browsers don't share a selection).

In-process dict: fine for a single-instance POC deployment (see
list-pagination-bulk-actions skill, Part 2) — would need Redis or similar
if this ever ran as more than one replica.

Why this exists at all: checkbox state living only in the DOM (this app's
original design) is destroyed every time #results gets swapped — including
by Prev/Next, which is exactly the failure mode a paginated multi-select
needs to survive. See docs/webapp-implementation-plan.md's "Cross-page bulk
selection" section for the bug report and full writeup.
"""

_selection: dict[str, set[int]] = {}


def get_selected(session_id: str) -> set[int]:
    return _selection.get(session_id, set())


def update_selected(session_id: str, ids: set[int], checked: bool) -> None:
    current = _selection.setdefault(session_id, set())
    if checked:
        current.update(ids)
    else:
        current.difference_update(ids)


def clear_selected(session_id: str) -> None:
    _selection.pop(session_id, None)

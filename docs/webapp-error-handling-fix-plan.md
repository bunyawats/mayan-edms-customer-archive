# webapp error-handling fix plan

Fixes for three correctness bugs found in a 2026-08-27 review of
`webapp/app/routers/documents.py`. All three are error-handling gaps, not
data-hierarchy issues — the gotchas in `docs/document-hierarchy-setup.md`
are unaffected. No schema, template, or route-signature changes required;
each fix is local to `documents.py`.

## 1. Preview/download don't forward Mayan's response status code

**Where:** `document_preview` (lines 318-333) and `document_download`
(lines 336-354).

**Bug:** `mayan_client.stream()` returns whatever `httpx` got back without
calling `raise_for_status()`, and both routes build their
`StreamingResponse` without a `status_code=` argument, so it defaults to
200 regardless of what Mayan actually returned. A transient 502/503 from
the `app` container, or a 403/404 if the file was trashed by a concurrent
delete, gets served to the browser as a "successful" image or download.

**Fix:** forward the upstream status code explicitly in both routes:

```python
response = await mayan_client.stream(path)
return StreamingResponse(
    _iter_and_close(response),
    status_code=response.status_code,
    media_type=response.headers.get("content-type", "image/jpeg"),
)
```

(same change in `document_download`, keeping its existing
`Content-Disposition` header handling). No change needed to
`mayan_client.stream()` itself — it should keep not raising, since the
whole point here is to pass the real status through rather than turn it
into an exception.

**Test:** stop the `app` container mid-request (or point `MAYAN_URL` at a
closed port temporarily) and confirm `/documents/{id}/preview` and
`/documents/{id}/download` now return a non-200 status instead of a fake
200 with empty/error body.

## 2. `create_document`'s post-upload refresh is unguarded

**Where:** `webapp/app/routers/documents.py:132-139`.

**Bug:** the upload call is wrapped in `try/except httpx.HTTPError`, but
the `search_documents` call right after it (to refresh the results table)
is not — inconsistent with every other route in this file (`index`,
`list_documents`, `bulk_delete_confirm`, `bulk_delete_documents`), all of
which guard their `search_documents` call and return `render_error` on
failure.

**Fix:** wrap the refresh call the same way the other routes do:

```python
filters = _filters("", "", "", "", "")
try:
    documents, total = await service.search_documents(filters, page=1, page_size=settings.page_size)
except httpx.HTTPError as exc:
    return render_error(request, f"Upload succeeded, but refresh failed: {exc}")
```

Note the message should make clear the upload itself succeeded — don't
reuse the generic "Search failed" wording, since the user's action did
work.

**Test:** manually raise inside `service.search_documents` (or simulate a
blip) right after a successful upload and confirm the user sees the
`error.html` partial instead of an unhandled 500/traceback.

## 3. `bulk_delete_documents`'s corrected-page refetch is unguarded

**Where:** `webapp/app/routers/documents.py:293-300`.

**Bug:** the first `search_documents` call (line 294) is wrapped in
`try/except`; the second one three lines later (line 300, which reruns
the search after clamping `page` down to `total_pages` when the delete
emptied the last page) is not.

**Fix:** extract the guarded call into a small local helper so both call
sites share the same error handling instead of duplicating (and
potentially re-forgetting) the try/except:

```python
async def _search_or_error(filters, page):
    try:
        return await service.search_documents(filters, page=page, page_size=settings.page_size), None
    except httpx.HTTPError as exc:
        return None, render_error(request, f"Refresh failed after delete: {exc}")

result, error_response = await _search_or_error(filters, page)
if error_response:
    return error_response
documents, total = result
total_pages = max(1, math.ceil(total / settings.page_size))
if page > total_pages:
    page = total_pages
    result, error_response = await _search_or_error(filters, page)
    if error_response:
        return error_response
    documents, total = result
```

(Naming/shape above is illustrative — inline `try/except` duplicating the
existing block is also acceptable if a helper feels like overkill for two
call sites.)

**Test:** same approach as #2, but trigger the failure on the *second*
call specifically — e.g. delete every item on a non-first page so the
clamp-and-refetch path executes, and simulate a blip only on that second
call.

## Suggested order

Fix #1 first (clearest, most self-contained, easiest to verify by hand).
Fixes #2 and #3 are the same root pattern (a `search_documents` call
added without the file's established try/except convention) and can be
done together in one pass over the file.

## Out of scope

Not addressed here (raised in the original review as lower-priority /
by-design, not bugs):

- `selection_store.py`'s in-process dict has no TTL/eviction — documented
  as an accepted POC-scale tradeoff (single instance, cleared on
  `clear_selected`), not a bug.
- The edit-metadata form can't add a metadata field that wasn't already
  attached at upload time (e.g. promote a customer-level doc to
  account-level) — a scope limitation of the current UI, not a
  correctness bug.

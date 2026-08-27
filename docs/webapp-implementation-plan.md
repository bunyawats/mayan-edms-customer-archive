# FastAPI + HTMX POC for Mayan EDMS document management

## Context

The repo originally only had shell scripts (`scripts/*.sh`) that drive Mayan's
REST API to set up the Customer Archive hierarchy and file documents into
it. The goal was an actual web UI on top of that: a small FastAPI + HTMX
app that gives a non-technical user CRUD over customer documents living in
Mayan — upload with preview, metadata-criteria search with pagination, and
delete (single + bulk) — without needing curl/scripts or the Mayan admin UI.

Decided with the user up front:
- Runs as a **`webapp` service in `docker-compose.yml`**, alongside
  `db`/`redis`/`app`, sharing the same `.env`.
- **No login screen** — the webapp holds one shared Mayan API token
  (obtained from `MAYAN_AUTOADMIN_USERNAME`/`PASSWORD`, same as the
  scripts) and every visitor uses it. Single internal tool, POC scope.

This reuses the API call sequences and gotchas already documented in
`docs/document-hierarchy-setup.md` (index rebuild race, `action_name=replace`,
real-vs-fake file validation) rather than rediscovering them.

## Layout

```
webapp/
  app/
    main.py                 FastAPI app + route registration
    config.py                Settings via pydantic-settings (MAYAN_URL, MAYAN_USER, MAYAN_PASSWORD, page size, bulk-delete cap)
    mayan_client.py           Async httpx wrapper: token auth (fetch+cache, refetch on 401), lookup-by-name
                               caching for metadata_type/document_type ids, documents/metadata/files/index calls
    documents_service.py      Search (exact-match filtering), upload orchestration, metadata update, bulk delete fan-out
    templating.py             HX-Request-aware fragment vs. full-page rendering helper
    routers/documents.py      All document routes (below)
    templates/
      base.html               Page shell, htmx CDN tag
      index.html               Search form + results container (full page)
      partials/
        results_table.html     Bulk-delete form + table + pagination
        upload_form.html / upload_result.html
        document_detail.html   Metadata + preview image + download/edit/delete actions
        edit_metadata_form.html
        error.html              Small alert fragment for failed htmx requests
    static/style.css           Minimal custom CSS (no build step)
  requirements.txt             fastapi, uvicorn[standard], httpx, jinja2, python-multipart, pydantic-settings
  Dockerfile                   python:3.12-slim, pip install, uvicorn app.main:app --host 0.0.0.0 --port 8080
```

`docker-compose.yml` has a `webapp` service: `build: ./webapp`, port
`8080:8080`, env `MAYAN_URL=http://app:8000`,
`MAYAN_USER=${MAYAN_AUTOADMIN_USERNAME}`, `MAYAN_PASSWORD=${MAYAN_AUTOADMIN_PASSWORD}`,
`depends_on: [app]`. No new `.env` keys — reuses the existing ones.

## Routes (`webapp/app/routers/documents.py`)

| Method/Path | Purpose |
|---|---|
| `GET /` | Full page: search form + initial results |
| `GET /documents` | HTMX partial: results table, filtered by query params (`customer_id`, `account_id`, `application_id`, `category`, `label`, `page`) |
| `GET /documents/new` | HTMX partial: upload form |
| `POST /documents` | Handle upload (multipart: file + metadata fields). Mirrors `upload_document.sh`: create document with type derived from which IDs are set → upload file (`action_name=replace`) → attach metadata fields sequentially → rebuild index. Returns a success fragment plus an OOB-refreshed results table. |
| `GET /documents/{id}` | HTMX partial: detail view (metadata, preview `<img>`, download/edit/delete buttons) |
| `GET /documents/{id}/edit` | HTMX partial: edit-metadata form |
| `PATCH /documents/{id}` | Update metadata values (only entries that changed; triggers an index rebuild if any did), returns refreshed detail partial |
| `DELETE /documents/{id}` | Delete one document (`DELETE /api/v4/documents/{id}/` — moves it to Mayan's trash, confirmed via the endpoint's own OPTIONS description, not a hard delete), row removed via `hx-swap` |
| `POST /documents/bulk-delete/confirm` | Checked document IDs + current filters/page. De-dupes and caps (`_dedupe_and_cap`, shared with the execute route below), re-fetches each selected id's *current* label/type/metadata from Mayan, and renders a confirm dialog listing them into `#modal` — see "Bulk-delete confirm dialog" below |
| `POST /documents/bulk-delete` | Same de-dupe/cap, fans out over the same single-delete call per id via `asyncio.gather`, returns refreshed results table + a summary line ("N deleted, M failed") plus an OOB swap that clears `#modal` |
| `GET /documents/{id}/preview` | Proxies the document's first-page image from Mayan (adds `Authorization: Token`, streams bytes) so the token never reaches the browser |
| `GET /documents/{id}/download` | Proxies the latest file's download bytes the same way, passing through Mayan's own `Content-Disposition`/`Content-Type` |

### Search: what the live API actually supports

Probed directly against the running instance before writing this (rather
than guessing): Mayan's advanced search endpoint
(`/api/v4/search/advanced/documents.documentsearchresult/`) exposes
`metadata__metadata_type__name` and `metadata__value` as separate query
params, but **combining them does not AND against the same metadata row** —
verified live: `?metadata__metadata_type__name=customer_id&metadata__value=Cust-1001`
matched every document in the instance, not just ones with that value under
that specific field (each param fans out over the document's metadata set
independently). So search instead: fetches the full document list
(POC-scale, capped at `MAX_SEARCH_CANDIDATES=1000`), fetches each
candidate's real metadata, and filters exactly in Python
(`documents_service.search_documents`). Pagination is computed on the
filtered list ourselves, not delegated to Mayan's own `page`/`page_size`
(which only applies to the pre-filter list). This would need real
server-side filtering at production data volumes — noted as a POC
limitation, not an oversight.

Also confirmed live and relied on directly: the download endpoint is
`GET /documents/{id}/files/{file_id}/download/` (returns a correct
`Content-Disposition: attachment; filename="..."` already, so the proxy
just passes it through); the preview image is
`file_latest.pages_first.image_url`; `DELETE /documents/{id}/` moves to
trash, not a hard delete.

### Header select-all + bulk-delete confirm dialog

Added after looking at a heavier reference implementation
(`bunyawats/review-approval-temporal`, a Temporal + FastAPI + Keycloak
review/approval app — the real project the `list-pagination-bulk-actions`
skill's guidance was distilled from) for how it does the same "select
rows, then act on them" flow, and adapting the *pattern*, not the
machinery — that project's selection is server-side (Redis, because its
list self-polls every 5s across a multi-user, multi-role login), which
this app deliberately doesn't need (see scope decisions below).

- **Header `<th>` checkbox** (`.select-all` in `results_table.html`) toggles
  every `input[name="document_id"]` checkbox on the current page. Pure
  client-side JS (`base.html`, delegated on `document.body` so it survives
  every `#results` swap without rebinding) — no request round-trip, since
  nothing here needs a server-authoritative selection (see below).
- **"Delete selected" opens a confirm dialog** (`POST
  /documents/bulk-delete/confirm` → `partials/bulk_delete_confirm.html` in
  `#modal`) listing the label/type/customer/category of every selected
  document — re-fetched fresh from Mayan at dialog-render time, not read
  from the client's cached table rows, so a stale or since-changed row
  can't misrepresent what's about to be deleted. Confirming submits a form
  (embedded in the dialog, carrying the same id list + filters/page as
  hidden inputs) to the real `POST /documents/bulk-delete`; Cancel just
  clears `#modal` client-side, no request. Same idiom as the reference
  project's `_bulk_confirm_dialog.html`, minus the shared-comment field
  (no analogous use for it here) and the role-conditional columns (this
  app has one role).
- Execute (`POST /documents/bulk-delete`) now also emits an OOB
  `<div id="modal" hx-swap-oob="innerHTML"></div>` to close the dialog on
  completion, alongside the refreshed results table — same OOB idiom
  `upload_result.html` already used for the opposite case (primary target
  `#modal`, OOB-refresh `#results`).

### Pagination & bulk-delete: scope decisions

Informed by the `list-pagination-bulk-actions` skill, deliberately
simplified given single shared-account POC scope and small data volume:

- **No server-side count cache** — Mayan's own list endpoint (or our own
  Python-side filtered list) is cheap at this scale, and the results table
  doesn't self-poll.
- **No server-side selection store** — checkbox state lives in the DOM only
  (an HTML `<form>` wrapping the results table). Safe because nothing here
  polls or swaps the table out from under the user; would need revisiting
  if a live-refresh feature were added later. This also means the
  bulk-delete confirm route trusts the client-submitted id list as *which*
  ids to act on (there's no store to re-derive it from) — the skill was
  updated with an explicit exception for this tier, since its rule as
  originally written assumed a server-side store always exists. What still
  holds regardless of tier: the confirm dialog re-fetches each id's
  *display* fields from Mayan rather than trusting client-cached text, and
  the execute route still runs Mayan's own delete (with its own
  existence/permission checks) per id rather than assuming the batch
  succeeds.
- **Bulk delete fans out over the single-delete call**
  (`asyncio.gather(mayan_client.delete_document(id) for id in ids)`),
  collecting per-id success/failure rather than all-or-nothing. Input is
  de-duped and capped (`bulk_delete_max`, default 100) and rejected up
  front if empty — shared between the confirm and execute routes
  (`_dedupe_and_cap`) so the cap can't be bypassed by skipping the dialog.

### htmx version

Used **htmx 2.0.4** (stable), not the v4 pre-release — the `htmx4` skill's
own guidance is to re-verify pre-release status before adopting it in a new
project, and there's no reason for a POC to take on beta churn. Patterns
still borrowed from that skill regardless of version: branching response
shape on the `HX-Request` header (`templating.py`), OOB swap for
refreshing the results table after an upload while the modal shows a
separate success message, and returning htmx error fragments as HTTP 200
so htmx 2.x's default (only 2xx responses auto-swap) doesn't just discard
them.

## Bugs found and fixed during implementation

1. **Missing `Accept: application/json` on the shared httpx client.**
   Mayan's DRF-based auth endpoint returns its HTML browsable-API page
   instead of a JSON token — even on a *successful* login — if the request
   doesn't explicitly ask for JSON. Fixed by setting `Accept:
   application/json` as a default header on `MayanClient`'s
   `httpx.AsyncClient`. (The shell scripts in `scripts/` already did this
   with an explicit `-H "Accept: application/json"` per curl call; the
   webapp needed the equivalent set once, client-wide.)
2. **Bulk-delete refresh could 404 on a just-deleted document.** Right
   after deleting document(s), the immediate re-search sometimes still saw
   the deleted id in the candidate list for a moment (Mayan's list
   endpoint briefly lagging the trash operation), so the per-document
   metadata fetch 404'd and the whole refresh errored — masking a
   successful delete behind an error banner. Fixed by making
   `documents_service._attach_metadata` tolerate a 404 per document
   (drop it from the result set) instead of failing the batch.

## Verification performed

- `docker compose up -d --build` brings up `db`, `redis`, `app`, `webapp` cleanly.
- `GET /` renders the full page with the live document count.
- Search verified by exact metadata match (`customer_id`, `account_id`) against the real seeded dataset, including that application/account-level documents correctly show up under a broader `account_id` filter.
- Upload verified end-to-end: created a real document, confirmed a real (non-placeholder) JPEG preview via the proxy route, confirmed download proxy returns the correct bytes with the right filename.
- Edit metadata (PATCH) verified round-trip.
- Pagination verified across 2 pages with the real seeded dataset (11 documents, page size 10).
- Bulk delete verified both with and without an active filter context (the race in bug #2 above only reproduced in the no-filter path — fixed and reverified in both).
- Not yet done: a full browser click-through (all testing above was via curl against the running containers) and a check of the document actually appearing in the Mayan index tree post-upload via the Mayan UI itself.

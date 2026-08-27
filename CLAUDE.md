# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker Compose stack running [Mayan EDMS](https://www.mayan-edms.com/) (an
off-the-shelf document management app, not application code we maintain),
configured via its REST API into a metadata-driven document hierarchy:

```
Customer Archive
└── <customer_id>
       ├── Photo ID/                     (customer-level docs)
       └── <account_id>
              ├── Welcome Letter/         (account-level docs)
              └── <application_id>
                     ├── Financial Records/
                     └── Agreements/
```

There is no Mayan source in this repo — `docker-compose.yml` pulls
`mayanedms/mayanedms:latest`. The real content here is (a) the setup/upload
scripts and docs that configure a running instance and file documents into
it via `/api/v4/`, and (b) `webapp/`, a FastAPI + HTMX app (its own
`docker-compose.yml` service) giving a non-technical user CRUD over
documents in that hierarchy — upload with preview, metadata-criteria
search with pagination, single/bulk delete — without touching curl or the
Mayan admin UI.

## Commands

```bash
# Start the stack (Postgres 15, Redis, Mayan app on :8000, webapp on :8080)
docker compose up -d --build

# One-time, against a fresh instance: creates metadata types, document
# types, and the "Customer Archive" index template. NOT idempotent — see
# docs/document-hierarchy-setup.md before re-running against a non-fresh DB.
MAYAN_URL=http://localhost:8000 MAYAN_USER=admin MAYAN_PASSWORD=<pw> \
  ./scripts/setup_document_hierarchy.sh

# Generate a full 4-document sample set for one customer (dummy PDFs)
MAYAN_PASSWORD=<pw> ./scripts/create_test_documents.sh Cust-1002 Acc-99001 App-12345

# File one real file into the hierarchy at a given level
MAYAN_PASSWORD=<pw> ./scripts/upload_document.sh <file> <customer_id> <category> [account_id] [application_id]

# One-time, after setup_document_hierarchy.sh: adds the three flat
# Customer/Account/Application index templates. Idempotent.
MAYAN_PASSWORD=<pw> ./scripts/add_flat_indexes.sh
```

All four scripts read `MAYAN_URL` / `MAYAN_USER` / `MAYAN_PASSWORD` from
the environment (defaults: `http://localhost:8000`, `admin`) and require
`bash`, `curl`, `python3`. They look up metadata/document type IDs by name
at runtime rather than hardcoding them, so they keep working after a fresh
`setup_document_hierarchy.sh` run even though IDs differ between instances.

There is no test suite, linter, or build step — this is infra/ops
scripting, not an application.

## Architecture

**The hierarchy is virtual, computed per-document from metadata — there are
no real folders.** One Index Template ("Customer Archive") with a nested
node tree, driven by four metadata fields (`customer_id`, `account_id`,
`application_id`, `category`) and three document types (Customer / Account
/ Application Document, each requiring the metadata subset appropriate to
its level). Mayan re-evaluates every document's position in the tree
whenever its metadata changes.

Three more index templates — **Customer**, **Account**, **Application**
(built by `scripts/add_flat_indexes.sh`, not `setup_document_hierarchy.sh`)
— sit alongside "Customer Archive". Each is a single flat level (no
nesting by category): every document carrying that one metadata field,
grouped by its value, document types mixed together. E.g. the Account
index's bucket for one `account_id` shows an Account-level document
(Welcome Letter) next to that account's Application-level ones (Financial
Records, Agreements) side by side. See "Flat indexes" in
`docs/document-hierarchy-setup.md`.

Read `docs/document-hierarchy-setup.md` before touching the index template
or any script — it documents five non-obvious gotchas that are easy to
reintroduce:

1. **Empty index-node expressions don't prune the branch.** An ancestor
   node evaluating empty does *not* stop Mayan from evaluating descendant
   nodes — every leaf's condition must repeat the *full* set of ancestor
   requirements (e.g. the account-level leaf must check
   `account_id and not application_id`, not just `not application_id`), or
   documents file into bogus `None` branches as well as the correct one.
2. **Index updates are asynchronous** (queued Celery tasks). Attaching
   metadata field-by-field can trigger out-of-order re-index runs mid-way
   through. Always call `POST /index_templates/<id>/rebuild/` after
   attaching all metadata, and wait ~10-15s before reading the tree.
3. **`action_name` on `POST /documents/<id>/files/` is a string ID**
   (`replace` / `append` / `keep`), not an integer. An invalid value is
   accepted with HTTP 200 (validated only inside the async
   `task_document_file_version_create` task), so the failure is silent at
   upload time and only shows up later as "No Pages to display" in the UI.
4. **A file that passes magic-byte sniffing isn't necessarily a valid file
   for its format.** `make_dummy_pdf()` in `create_test_documents.sh`
   builds a genuinely valid one-page PDF (real object structure, xref
   table) for this reason — a hand-typed `%PDF...%%EOF` stub passes upload
   and mimetype checks but has zero extractable pages. Verify with
   `file <path>` (should report a real page count), and for anything
   uploaded through these scripts, spot-check the actual rendered page
   image at least once — not just the API response status.
5. **`GET /index_templates/<id>/nodes/` doesn't return a wrapped root** —
   `results` *is* the root's children directly, not one item with those
   children nested inside it. Checking `results[0]['children']` for an
   idempotency check (rather than `results` itself) silently creates
   duplicate leaf nodes on every re-run — hit this building
   `add_flat_indexes.sh`, only caught by actually re-running it and
   inspecting the tree.

`docs/rca-2026-08-25-document-preview-and-app-outage.md` is the incident
record for how all of the above were originally found (plus an unrelated
container-permissions outage from running a Mayan management command
without `-u mayan`, which corrupted `config.yml` ownership and caused a
crash-loop under load). It's a point-in-time writeup — update
`document-hierarchy-setup.md`, not the RCA, if the underlying guidance
changes.

`document-heiracry.txt` is the original design plan the hierarchy was
built from; `docs/document-hierarchy-setup.md` is the corrected,
authoritative version — prefer the latter when they disagree.

## `webapp/` — the FastAPI + HTMX UI

Runs as the `webapp` service in `docker-compose.yml` (port 8080), talking
to Mayan's REST API with **one shared service-account token** (from
`MAYAN_AUTOADMIN_USERNAME`/`PASSWORD`, same credentials the scripts use) —
there's no per-user login, by design, for this POC. See
`docs/webapp-implementation-plan.md` for the full design writeup
(route table, why search works the way it does, decisions inherited from
the `list-pagination-bulk-actions` skill), and its "Bugs found and fixed"
section for two non-obvious things worth knowing before touching this code:

- **`mayan_client.py`'s httpx client sets `Accept: application/json` as a
  default header.** Without it, Mayan's DRF auth endpoint returns its HTML
  browsable-API page instead of a JSON token — even on a *successful*
  login — so don't remove it or add a new httpx client that skips it.
- **`documents_service._attach_metadata` tolerates a 404 per document**
  (drops it from the result set rather than failing the batch), because
  the results-table refresh right after a delete can still momentarily see
  the just-deleted document in Mayan's list endpoint.

It reimplements the same upload sequence as `scripts/upload_document.sh`
(create document → upload file with `action_name=replace` → attach
metadata fields → rebuild index), so **gotchas #1-4 in
`docs/document-hierarchy-setup.md` apply here too** — don't relearn them,
read that doc first.

**Metadata search is exact-match, computed in Python, not delegated to
Mayan's advanced search API.** Verified live that Mayan's
`metadata__metadata_type__name` + `metadata__value` query params don't AND
against the same metadata row (each fans out independently), so
`documents_service.search_documents` fetches the full document list
(capped at `MAX_SEARCH_CANDIDATES = 1000` — a POC-scale limitation, not an
oversight) and filters exactly per document. This means our own pagination
is computed on the filtered list, not Mayan's `page`/`page_size`.

`DELETE /api/v4/documents/{id}/` moves a document to Mayan's **trash**, not
a hard delete (confirmed via the endpoint's own OPTIONS description) — so
single/bulk delete in this app are recoverable through Mayan directly, not
destructive.

**Bulk selection is server-side (`selection_store.py`), not DOM state —
this is load-bearing, don't revert it.** It was originally plain
client-side checkboxes and broke the moment a user selected across more
than one page (Prev/Next replaces `#results`' entire `innerHTML`,
destroying checkbox state along with it — see
`docs/webapp-implementation-plan.md`'s "Cross-page bulk selection" section
for the bug report and full fix writeup). Selection is now keyed by an
opaque per-browser cookie (`SessionCookieMiddleware` in `main.py` — not
auth, just enough to stop two browsers sharing a selection) and stored in
an in-process `dict[str, set[int]]`. Every checkbox (`POST
/documents/select`) persists itself there; `bulk-delete/confirm` and
`bulk-delete` **read the selection from the store, not from any
client-submitted id list** — don't reintroduce a `document_id` form
param on those two routes, that was exactly the bug.

**Bulk delete goes through a confirm dialog, not a plain `hx-confirm`.**
"Delete selected" opens `POST /documents/bulk-delete/confirm`, which
re-fetches each selected document's *current* label/type/metadata from
Mayan and renders them in `#modal` before the user commits — see
`docs/webapp-implementation-plan.md`'s "Header select-all + bulk-delete
confirm dialog" section (adapted from a heavier reference project,
`bunyawats/review-approval-temporal`).

## Working with credentials

`.env` (gitignored) holds `POSTGRES_PASSWORD`, `MAYAN_AUTOADMIN_USERNAME`,
`MAYAN_AUTOADMIN_PASSWORD` — copy from `.env.example`. Never commit `.env`.

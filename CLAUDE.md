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
`mayanedms/mayanedms:latest`. All the real content here is the setup/upload
scripts and docs that configure a running instance and file documents into
it via `/api/v4/`.

## Commands

```bash
# Start the stack (Postgres 15, Redis, Mayan app on :8000)
docker compose up -d

# One-time, against a fresh instance: creates metadata types, document
# types, and the "Customer Archive" index template. NOT idempotent — see
# docs/document-hierarchy-setup.md before re-running against a non-fresh DB.
MAYAN_URL=http://localhost:8000 MAYAN_USER=admin MAYAN_PASSWORD=<pw> \
  ./scripts/setup_document_hierarchy.sh

# Generate a full 4-document sample set for one customer (dummy PDFs)
MAYAN_PASSWORD=<pw> ./scripts/create_test_documents.sh Cust-1002 Acc-99001 App-12345

# File one real file into the hierarchy at a given level
MAYAN_PASSWORD=<pw> ./scripts/upload_document.sh <file> <customer_id> <category> [account_id] [application_id]
```

All three scripts read `MAYAN_URL` / `MAYAN_USER` / `MAYAN_PASSWORD` from
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

Read `docs/document-hierarchy-setup.md` before touching the index template
or any script — it documents four non-obvious gotchas that are easy to
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

## Working with credentials

`.env` (gitignored) holds `POSTGRES_PASSWORD`, `MAYAN_AUTOADMIN_USERNAME`,
`MAYAN_AUTOADMIN_PASSWORD` — copy from `.env.example`. Never commit `.env`.

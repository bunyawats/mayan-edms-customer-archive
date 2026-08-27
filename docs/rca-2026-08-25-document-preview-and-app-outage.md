# RCA: document previews broken + app outage (2026-08-25)

**Status:** Resolved
**Severity:** Medium — no data loss; app was briefly fully unresponsive; all
document previews were broken since first upload
**Duration:** ~64 minutes from first affected upload (13:01 config
corruption) to full resolution (14:05)

## Summary

Three separate bugs, discovered in sequence because each one masked the
next until fixed:

1. A management command run as the wrong container user corrupted file
   ownership, which later caused the whole app to crash-loop under load and
   become fully unresponsive.
2. Every document-upload script used an invalid API parameter, which
   silently prevented Mayan from ever generating viewable pages for any
   uploaded document ("No Pages to display" for all 10 documents).
3. Fixing #2 revealed that 8 of those 10 documents were never valid PDFs to
   begin with — a hand-typed test stub, not a real PDF structure — so even
   with a working pipeline, they still rendered zero pages. Only the two
   documents backed by a real downloaded file were fully fixed by #2 alone.

All three are fixed. See [`docs/document-hierarchy-setup.md`](document-hierarchy-setup.md)
("Gotcha #3" and "Gotcha #4") for the ongoing-reference versions of bugs 2
and 3, and `scripts/setup_document_hierarchy.sh` / `create_test_documents.sh`
/ `upload_document.sh` for the current, corrected code.

## Timeline

| Time (UTC) | Event |
|---|---|
| 13:01 | Postgres upgraded 13→15 for a prior, unrelated issue (Django version requirement); DB volume reset as part of that fix |
| 13:01 | Fresh Postgres cluster came up with no admin user (initial setup had raced a Postgres restart and partially failed) |
| ~13:06 | Ran `mayan-edms.py common_initial_setup --force` via `docker compose exec` **without `-u mayan`**, i.e. as root, to create the missing admin account. This succeeded (admin user created) but also rewrote `/var/lib/mayan/config.yml`, `config_backup.yml`, and the `whoosh/` search index directory as `root:root` instead of `mayan:mayan` |
| 13:18–13:53 | Uploaded 10 documents across two customers via curl/scripts, all using `action_name=1` (invalid). Each upload's page-rendering task failed silently in the background; all 10 documents ended up with a stored file but zero document versions |
| ~13:54 | Under the load of processing those uploads (OCR, converter, whoosh indexing), gunicorn began recycling workers. New worker processes could not read the root-owned `config.yml` → immediate crash on spawn → supervisor kept retrying → crash-loop |
| 13:54–13:55 | App became fully unresponsive (plain `GET /` timed out) |
| 13:55 | Found `Permission denied: '/var/lib/mayan/config.yml'` in logs; `chown`'d `config.yml`, `config_backup.yml`, `whoosh/` back to `mayan:mayan`; restarted the `app` container |
| 13:56 | App responsive again (HTTP 302, ~2ms) |
| ~13:56 | User reported `test-doc.pdf` showed "No Pages to display" in the UI despite appearing correctly in the index tree |
| 13:56–13:58 | Traced to `task_document_file_version_create` raising `KeyError('1')` — `action_name=1` is not a valid `DocumentFileAction` ID (valid values: `replace`, `append`, `keep`) |
| 13:58 | Fixed `action_name` in both scripts; repaired all 10 existing documents in place via Django shell (`file_latest.versions_new(action_name='replace')`), no re-upload needed |
| 13:58 | Verified: downloaded `test-doc.pdf` page 1 directly, confirmed a real rendered JPEG (not a blank placeholder) |
| — | User confirmed `test-doc.pdf`'s preview now displays correctly |
| — | User reported `Welcome_Letter.pdf` (doc 2) still showed "No Pages to display" |
| 14:00 | Checked `versions/` for doc 2: a version now existed (bug 2 fix worked) but `pages_first: null` — zero pages, not a rendering delay. Checked all 8 documents from `create_test_documents.sh`/the original manual test upload: all had a version with zero pages. Only the two `test-doc.pdf`-backed documents (9, 10) had real pages |
| 14:01 | Root cause: `make_dummy_pdf()`'s stub (`%PDF-1.4\n%%test dummy pdf...\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF`) is not a structurally valid PDF — no `/Catalog`, no `/Pages` tree, no xref table — so it passed upload/mimetype checks but had no extractable pages, regardless of the `action_name` fix |
| 14:01–14:04 | Rewrote `make_dummy_pdf()` to emit a genuinely valid one-page PDF (proper object structure and xref table); generated real replacement PDFs for all 8 affected documents; re-uploaded each with `action_name=replace` |
| 14:05 | Verified all 10 documents have `pages_first` populated; downloaded and inspected doc 1's new page image directly (real JPEG, 2550×3300); confirmed the index tree was unaffected by the file replacements |

## Root causes

### 1. Wrong exec user for a management command

`docker compose exec -T app /opt/mayan-edms/bin/mayan-edms.py common_initial_setup --force`
was run without `-u mayan`. Docker's default exec user for this image's
`app` service is root, but the application's own processes (gunicorn
workers, celery workers) run as `mayan` (uid 1000) per the image's
supervisor config. The management command wrote `config.yml` with whatever
user ran it — root — leaving a permission mismatch that only bit once a
process needed to *restart* and re-read that file, which is why the outage
didn't happen immediately at 13:06 but ~48 minutes later, once load caused
worker recycling.

### 2. Invalid `action_name` value, unvalidated at write time

`action_name` on `POST /documents/<id>/files/` is a string key into a
`DocumentFileAction` registry (`replace` / `append` / `keep`), not an
integer index. `action_name=1` was used throughout (originating from an
early exploratory `curl` call that was never corrected before being copied
into both reusable scripts). The API accepted the upload and returned
success — validation of `action_name` happens later, inside the
asynchronous Celery task, not synchronously in the request — so the failure
was invisible at upload time and only surfaced as a UI symptom ("No Pages
to display") much later, disconnected in time and interface from its cause.

### 3. Test fixture PDFs weren't real PDFs

`create_test_documents.sh`'s `make_dummy_pdf()` wrote a hand-typed byte
sequence starting with `%PDF-1.4` and ending `%%EOF`, with no real PDF
object graph in between. Every check that doesn't try to actually render
the file passes: `%PDF` header present, `application/pdf` mimetype sniffing
succeeds, file upload API returns 200, checksum computed fine. But with no
`/Catalog`, `/Pages` tree, or xref table, there is nothing for a PDF
renderer to extract a page from — this was never a rendering bug, the file
was simply invalid. Because it produced the *identical symptom* as bug 2
("No Pages to display"), fixing bug 2 and then finding this same symptom on
a different document looked at first like a leftover instance of the same
bug rather than a distinct, unrelated one. The one document backed by a
real file (`test-doc.pdf`, uploaded via `upload_document.sh`) never hit
this, which is exactly why it was the only one confirmed fixed before this
was caught.

## Impact

- App fully unresponsive for roughly 1–2 minutes (13:54–13:56)
- All 10 documents uploaded before the fix (both test customers, 4 docs
  each, plus 2 real-file test uploads) had no viewable pages until repaired
  — 2 by the bug 2 fix alone, the other 8 also needed bug 3's fix
- No data loss: uploaded file bytes and all metadata were intact throughout;
  only the derived page-image artifacts were missing

## Fixes applied

- `chown mayan:mayan` on `config.yml`, `config_backup.yml`, `whoosh/`;
  `docker compose restart app`
- `scripts/create_test_documents.sh` and `scripts/upload_document.sh`:
  `action_name=1` → `action_name=replace`
- One-off repair script run inside the container for the 10 already-affected
  documents (see `docs/document-hierarchy-setup.md`, Gotcha #3, for the
  exact snippet)
- `create_test_documents.sh`'s `make_dummy_pdf()` rewritten to emit a
  structurally valid one-page PDF (correct xref table and object offsets,
  computed in Python) instead of a hand-typed stub; see Gotcha #4
- Generated valid replacement PDFs for the 8 documents affected by bug 3 and
  re-uploaded each with `action_name=replace`; verified via `file <pdf>`
  locally (reports real page count) and by downloading + inspecting a
  rendered page image from the API

## Follow-ups / lessons

- **Always pass `-u mayan`** (or whatever the image's app user is) when
  running Mayan management commands via `docker compose exec` against this
  image — never rely on the exec default.
- API calls that accept a value validated only inside an async task can
  return 200 while silently failing. When scripting against this API,
  spot-check the *actual artifact* (downloaded page image, not just the API
  response shape) at least once per new script, not just the response
  status code — this is what caught bug 2, three uploads' worth of scripts
  later.
- `docs/document-hierarchy-setup.md` now carries the durable/reference
  version of the `action_name` gotcha for anyone extending these scripts;
  this file is the incident record — update the doc, not this file, if the
  underlying guidance changes.
- Identical symptoms don't imply identical causes: bug 3 presented exactly
  like a leftover instance of bug 2 ("No Pages to display" on a document
  created by the same family of scripts), which is why it read initially as
  "the fix didn't fully take" rather than "there's a second, independent
  bug." When a fix is verified on one instance, verify on a second,
  differently-sourced instance before declaring the class of problem
  resolved — a fake-PDF-generation bug will never surface if the only
  check is against a real downloaded file, and vice versa.
- Test fixtures used to validate a document pipeline should be real,
  minimal, valid files for the format under test, not hand-typed stubs that
  merely resemble one. A stub that passes `file <path>`'s magic-byte
  sniffing is not evidence it's usable by the actual thing that consumes it.

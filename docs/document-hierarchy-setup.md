# Customer Archive document hierarchy

Implements the multi-level hierarchy from `document-heiracry.txt`:

```
Customer Archive
└── Cust-1001                                    (customer_id)
       ├── Photo ID/                              (customer-level docs)
       │      └── National_ID_Card.pdf
       └── Acc-88210                              (account_id)
              ├── Welcome Letter/                  (account-level docs)
              │      └── Welcome_Letter.pdf
              └── App-90042                        (application_id)
                     ├── Financial Records/
                     │      └── Bank_Statement.pdf
                     └── Agreements/
                            └── Loan_Contract.pdf
```

Mayan builds this as a virtual tree from **document metadata**, via one Index
Template with conditional node expressions. No folders or files are
duplicated — the tree is computed per document.

## How it's built

Run `scripts/setup_document_hierarchy.sh` against a running Mayan instance.
It drives the REST API (`/api/v4/`) to create, in order:

1. **Metadata types** — `customer_id`, `account_id`, `application_id`, `category`
2. **Document types** — Customer Document, Account Document, Application
   Document, each with the subset of metadata fields required for that level
3. **One Index Template** ("Customer Archive") with a nested node tree
   (below), enabled for all three document types

```bash
MAYAN_URL=http://localhost:8000 \
MAYAN_USER=admin \
MAYAN_PASSWORD=<your-admin-password> \
./scripts/setup_document_hierarchy.sh
```

The script is not idempotent — re-running it creates duplicate metadata
types / document types / index templates. If you need to re-run it, delete
the "Customer Archive" index template and the three document types first
(via the web UI, under System ▸ Setup), or drop and reset the database.

## Scripts

All three live in `scripts/`, take `MAYAN_URL` / `MAYAN_USER` /
`MAYAN_PASSWORD` as env vars (defaults: `http://localhost:8000`, `admin`),
and look up metadata/document type IDs by name at runtime rather than
hardcoding them — so they keep working after a fresh `setup_document_hierarchy.sh`
run even though the IDs come out different each time.

| Script | Purpose |
|---|---|
| `setup_document_hierarchy.sh` | One-time: creates the metadata types, document types, and index template tree. Run once per instance. |
| `create_test_documents.sh <customer_id> <account_id> <application_id>` | Generates a full 4-document sample set for one customer (dummy PDFs), matching the original plan's ingestion mapping. Good for smoke-testing a fresh customer branch end to end. |
| `upload_document.sh <file> <customer_id> <category> [account_id] [application_id]` | Files one **real** file into the hierarchy at whatever level you specify — customer, account, or application — inferring the document type from which IDs you pass. |

```bash
# Full sample set for a new customer
MAYAN_PASSWORD=... ./scripts/create_test_documents.sh Cust-1002 Acc-99001 App-12345

# One real file, account-level
MAYAN_PASSWORD=... ./scripts/upload_document.sh test-docs/test-doc.pdf Cust-1001 "Welcome Letter" Acc-88210

# One real file, customer-level only (no account_id/application_id)
MAYAN_PASSWORD=... ./scripts/upload_document.sh test-docs/id-scan.pdf Cust-1003 "Photo ID"
```

## Adding a document via the Web UI

The hierarchy is computed from metadata, not real folders — there's no
"upload into this folder" option. You upload a document normally and give
it the right document type + metadata; the index places it automatically.

To file a document under e.g. `Cust-1001 → Acc-88210 → Welcome Letter`:

1. Left sidebar ▸ **Documents ▸ New document**. This opens a document-type
   picker — choose **`Account Document`** here (this is what determines
   whether `account_id` is available/required, not a field on the upload
   form itself). Customer-level docs use `Customer Document`;
   application-level docs use `Application Document`.
2. You land on an upload form titled *"Upload a document of type 'Account
   Document' from source: Default"* — Language and Decompression fields
   default to sensible values (English / "Do not expand"; only change
   Decompression if you're uploading a zip/container to split into multiple
   documents). Drop the file or click to browse, then submit.
3. Open the uploaded document's **Metadata** tab (you may be prompted for
   required fields immediately after upload instead) and set:
   - `customer_id` → `Cust-1001`
   - `account_id` → `Acc-88210`
   - `category` → `Welcome Letter` — free text, must match the existing
     value exactly to land in the same leaf rather than create a new one
   Save.
4. **Indexes ▸ Customer Archive**, drill into
   `Cust-1001 → Acc-88210 → Welcome Letter` to confirm it appears there.
   Indexing runs asynchronously (see Gotcha #2) — if it hasn't shown up
   after ~15–20s, refresh, or trigger **System ▸ Setup ▸ Indexes ▸ Customer
   Archive ▸ Rebuild**.

Use a real, valid file — an empty or malformed one will file into the
correct place but show "No Pages to display" (Gotcha #4).

## Node tree

Each node has a single Django-template **expression**. Mayan renders it per
document: a non-empty result becomes that document's value at this level of
the tree.

```
customer_id                                                     [group]
├── category                                                    [LEAF]
│     if: no account_id and no application_id
├── account_id                                                  [group]
│     ├── category                                              [LEAF]
│     │     if: account_id set, no application_id
│     └── application_id                                        [group]
│           └── category                                        [LEAF]
│                 if: account_id set and application_id set
```

`[LEAF]` nodes have `link_documents: true` — they're where documents
actually attach. `[group]` nodes exist only to branch the tree further.

## The gotcha: empty expressions don't prune the branch

The original plan (`document-heiracry.txt`) assumed each node needed just
its *own* condition, on the assumption that Mayan stops descending into a
branch once a node's expression comes back empty — e.g. the account-level
leaf only needed to check "no application_id", trusting that it would never
even be evaluated for a document with no `account_id`, because its parent
(the `account_id` group node) would already have been empty and skipped.

That assumption is wrong for this Mayan version. An empty expression still
creates an index node (labeled "None" in the API/UI) and Mayan **still
evaluates every descendant** against every document, regardless of what the
ancestor rendered. Verified directly: a customer-level-only test document
(`customer_id` and `category` set, no `account_id`/`application_id`) filed
correctly under `Cust-1001 → Photo ID`, but — before the fix below — *also*
filed under the bogus `Cust-1001 → None → Photo ID` branch, because the
account-level leaf's condition only checked "no `application_id`" and didn't
care that `account_id` itself was missing.

**Fix:** every leaf node's condition repeats the full set of ancestor
requirements instead of relying on an ancestor's emptiness to gate it:

| Leaf | Condition |
|---|---|
| Customer docs | `not account_id and not application_id` |
| Account docs | `account_id and not application_id` (not just `not application_id`) |
| Application docs | `account_id and application_id` (not just always-true) |

Group nodes (`customer_id`, `account_id`, `application_id`) are left as
plain value expressions — their occasional "None" bucket is cosmetic (an
empty branch in the tree) and doesn't affect where documents actually file,
since they don't have `link_documents: true`. Mayan's own periodic index
maintenance eventually prunes branches that end up with zero documents
anywhere in their subtree, so leftover "None" nodes from earlier states
tend to disappear on their own after a while.

## Gotcha #2: index updates are asynchronous

Each `POST /documents/<id>/metadata/` call (attaching one metadata field)
triggers Mayan to re-evaluate that document's position in every enabled
index — as a queued Celery task, not inline with the request. When a
document's metadata is attached field-by-field (customer_id, then
account_id, then application_id, then category, as all three scripts here
do), each intermediate POST can trigger a re-index using only the fields
set *so far*, and these can be processed out of order under load.

Observed directly: after scripting a full 4-document upload for a second
customer, one document showed up filed under a stale top-level `None → None`
branch despite having complete, correct metadata — a transient artifact of
this race, not a bug in the metadata or the node expressions.

**It resolves itself** — an explicit `POST /index_templates/<id>/rebuild/`
after all metadata is attached (which all three scripts already call) plus
a short wait (10–15s) before reading the tree is enough. If you're
scripting a check right after upload, retry once after a `rebuild/` call
rather than trusting the first read.

## Gotcha #3: `action_name` in the file-upload API is a string ID, not `1`

`POST /documents/<id>/files/` (used by every script here to upload a file)
takes an `action_name` field that must be one of the registered
`DocumentFileAction` backend IDs — **`replace`**, `append`, or `keep` — not
an arbitrary index. All three scripts originally sent `action_name=1`
(copied from an early exploratory `curl` call, never corrected). The upload
itself still "succeeded" — the file bytes were stored and the API call
returned normally — but the background task that turns a stored file into a
viewable **document version** (`task_document_file_version_create`) failed
immediately with `KeyError('1')`, silently, once per upload. Net effect:
every document uploaded through these scripts had a file but **zero
versions**, and the web UI showed "No Pages to display" for all of them.

Fixed in both scripts (`action_name=replace`). Existing affected documents
didn't need re-uploading — their stored files were fine; only version
creation had failed. They were repaired in place via Django shell:

```python
for document in Document.objects.all():
    file_latest = document.file_latest
    if file_latest and document.versions.count() == 0:
        file_latest.versions_new(action_name='replace')
```

**If a document ever shows "No Pages to display" again**, check
`GET /documents/<id>/versions/` — `count: 0` means this. Confirming a page
is real (vs. a blank placeholder) requires actually downloading it, not just
reading the API response: the placeholder and a real page both return a
`pages_first.image_url`, but only downloading and inspecting the image
(`file <downloaded>.png` — a real page renders as `JPEG image data`, sized
close to the source page dimensions) tells them apart.

## Gotcha #4: the original dummy test PDFs weren't real PDFs

Fixing Gotcha #3 (`action_name`) made the version-creation pipeline *run*,
but for the 8 documents generated by `create_test_documents.sh` it still
produced versions with **zero pages** — `pages_first: null` even after a
successful, error-free version creation. Cause: `make_dummy_pdf()`
originally wrote a fake stub —

```
%PDF-1.4
%test dummy pdf ...
1 0 obj<<>>endobj
trailer<<>>
%%EOF
```

— which passes every check that doesn't actually try to render it: it has
a valid `%PDF` header, `application/pdf` mimetype detection succeeds, the
upload API accepts it and returns 200. But it has no real object structure
(no `/Catalog`, no `/Pages` tree, no xref table), so nothing can extract a
page from it — not a bug in Mayan, the file was simply never a valid PDF.
`test-doc.pdf` (a real downloaded file) never hit this, which is why it was
the only one that worked after the Gotcha #3 fix and made the dummy files'
failure look like a leftover instance of the same bug.

**Fix:** `make_dummy_pdf()` now builds a genuinely valid one-page PDF in
Python (correct object offsets and xref table, real `/Catalog`/`/Pages`/
`/Contents` structure) instead of a hand-typed stub. All 8 previously
affected documents were repaired by re-uploading a real minimal PDF
(`action_name=replace`) to each.

**Verifying a PDF is real, without touching Mayan at all:** `file
some.pdf` — a real PDF reports `PDF document, version X.Y, N pages`; the
old stub reported nothing useful (mimetype sniffing alone, no page count).
Worth checking before uploading anything through these scripts.

## Verifying after setup (or after any node edit)

```bash
TOKEN=...  # from /api/v4/auth/token/obtain/

# 1. Create a document, upload a file, attach metadata
curl -sX POST $BASE/documents/ -H "Authorization: Token $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"document_type_id": <id>, "label": "test.pdf"}'
curl -sX POST $BASE/documents/<doc_id>/files/ -H "Authorization: Token $TOKEN" \
  -F "action_name=1" -F "file_new=@test.pdf"
curl -sX POST $BASE/documents/<doc_id>/metadata/ -H "Authorization: Token $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"metadata_type_id": <id>, "value": "..."}'

# 2. Rebuild and inspect where it landed
curl -sX POST $BASE/index_templates/<index_id>/rebuild/ -H "Authorization: Token $TOKEN"
curl -s $BASE/index_instances/<index_id>/nodes/ -H "Authorization: Token $TOKEN"
# then walk each node's children_url / documents_url to confirm the
# document appears in exactly the leaf(ves) you expect and nowhere else
```

## Ingestion mapping (from the original plan)

| File | customer_id | account_id | application_id | category |
|---|---|---|---|---|
| National_ID_Card.pdf | Cust-1001 | — | — | Photo ID |
| Welcome_Letter.pdf | Cust-1001 | Acc-88210 | — | Welcome Letter |
| Bank_Statement.pdf | Cust-1001 | Acc-88210 | App-90042 | Financial Records |
| Loan_Contract.pdf | Cust-1001 | Acc-88210 | App-90042 | Agreements |

## Test data currently loaded (snapshot)

Generated via the scripts above — a point-in-time record, not authoritative;
check the running instance (`documents/` and `index_instances/` endpoints,
or the web UI) for current state.

| File | customer_id | account_id | application_id | category | Source |
|---|---|---|---|---|---|
| National_ID_Card.pdf | Cust-1001 | — | — | Photo ID | manual (initial setup test) |
| Welcome_Letter.pdf | Cust-1001 | Acc-88210 | — | Welcome Letter | manual |
| Bank_Statement.pdf | Cust-1001 | Acc-88210 | App-90042 | Financial Records | manual |
| Loan_Contract.pdf | Cust-1001 | Acc-88210 | App-90042 | Agreements | manual |
| Cust-1002_National_ID_Card.pdf | Cust-1002 | — | — | Photo ID | `create_test_documents.sh Cust-1002 Acc-99001 App-12345` |
| Cust-1002_Welcome_Letter.pdf | Cust-1002 | Acc-99001 | — | Welcome Letter | same |
| Cust-1002_Bank_Statement.pdf | Cust-1002 | Acc-99001 | App-12345 | Financial Records | same |
| Cust-1002_Loan_Contract.pdf | Cust-1002 | Acc-99001 | App-12345 | Agreements | same |
| test-doc.pdf (real file, 15pp/1.4MB) | Cust-1001 | Acc-88210 | — | Welcome Letter | `upload_document.sh test-docs/test-doc.pdf Cust-1001 "Welcome Letter" Acc-88210` |
| test-doc.pdf (real file, re-uploaded) | Cust-1002 | — | — | Script Test Upload | `upload_document.sh test-docs/test-doc.pdf Cust-1002 "Script Test Upload"` (script smoke test — safe to delete) |

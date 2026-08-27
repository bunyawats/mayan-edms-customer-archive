# Mayan EDMS — Customer Archive

A Docker Compose stack running [Mayan EDMS](https://www.mayan-edms.com/),
configured with a metadata-driven document hierarchy:

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

Documents aren't stored in real folders — the tree is computed from
document metadata (`customer_id`, `account_id`, `application_id`,
`category`) via a Mayan Index Template. See
[`docs/document-hierarchy-setup.md`](docs/document-hierarchy-setup.md) for
the full design, including four gotchas hit and fixed while building it.

## Prerequisites

- Docker and Docker Compose
- `bash`, `curl`, `python3` (for the setup/upload scripts)

## Setup

1. **Configure credentials**

   ```bash
   cp .env.example .env
   ```

   Edit `.env` and set real values for `POSTGRES_PASSWORD`,
   `MAYAN_AUTOADMIN_USERNAME`, and `MAYAN_AUTOADMIN_PASSWORD`. `.env` is
   gitignored — never commit it.

2. **Start the stack**

   ```bash
   docker compose up -d
   ```

   This brings up Postgres 15, Redis, and the Mayan EDMS app. First boot
   runs Mayan's initial setup (migrations + admin account creation), which
   can take a minute or two.

   > **Known issue:** on first boot, Postgres's own init-then-restart cycle
   > can race Mayan's initial setup and leave it without an admin account
   > (no error shown, just no working login). If you can't log in after a
   > minute, check:
   > ```bash
   > docker compose logs app | grep -i "initial setup"
   > ```
   > If it says setup didn't complete, re-run it as the `mayan` user
   > (not root — see the RCA for why that matters):
   > ```bash
   > docker compose exec -u mayan -T app /opt/mayan-edms/bin/mayan-edms.py common_initial_setup --force
   > ```

3. **Log in**

   Visit http://localhost:8000 with the username/password from your `.env`.

## Building the Customer Archive hierarchy

One-time, against a fresh instance — creates the metadata types, document
types, and index template:

```bash
MAYAN_URL=http://localhost:8000 \
MAYAN_USER=admin \
MAYAN_PASSWORD=<your-admin-password> \
./scripts/setup_document_hierarchy.sh
```

Not idempotent — see the doc if you need to re-run it.

## Adding documents

```bash
# Full 4-document sample set for one customer (dummy PDFs)
MAYAN_PASSWORD=<your-admin-password> ./scripts/create_test_documents.sh Cust-1002 Acc-99001 App-12345

# One real file, filed at a specific level
MAYAN_PASSWORD=<your-admin-password> ./scripts/upload_document.sh path/to/file.pdf Cust-1001 "Welcome Letter" Acc-88210
```

Or via the web UI — see "Adding a document via the Web UI" in
[`docs/document-hierarchy-setup.md`](docs/document-hierarchy-setup.md).

## Project structure

```
docker-compose.yml                              Stack definition (Postgres, Redis, Mayan)
.env.example                                     Credential template — copy to .env
scripts/
  setup_document_hierarchy.sh                    One-time hierarchy setup
  create_test_documents.sh                        Generate a sample document set
  upload_document.sh                              File one real document into the hierarchy
docs/
  document-hierarchy-setup.md                     Design, build process, gotchas, UI guide
  rca-2026-08-25-document-preview-and-app-outage.md   Incident writeup from initial setup
document-heiracry.txt                             Original hierarchy design plan
```

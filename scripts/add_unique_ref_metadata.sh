#!/usr/bin/env bash
#
# Adds a "unique_ref" metadata type to the Customer Archive hierarchy:
#   1. Creates the metadata_type (idempotent -- reuses it if it already exists)
#   2. Attaches it to the three hierarchy document types (Customer Document,
#      Account Document, Application Document), initially as optional --
#      required=true would otherwise block creating any new document of
#      these types before step 3 has backfilled every existing one
#   3. Backfills a fresh UUIDv4 value onto every existing document of those
#      types that doesn't already have one -- existing values are left alone
#   4. Flips the field to required=true on all three document types now that
#      every existing document satisfies it
#
# unique_ref is NOT part of any index_template node expression, so unlike
# setup_document_hierarchy.sh this does not need an index rebuild afterwards
# (see docs/document-hierarchy-setup.md gotcha #2 -- that gotcha only applies
# to metadata the index tree actually branches on).
#
# Assumes setup_document_hierarchy.sh has already been run against this
# instance (the three document types must already exist).
#
# Usage:
#   MAYAN_URL=http://localhost:8000 MAYAN_USER=admin MAYAN_PASSWORD=... ./add_unique_ref_metadata.sh
#
# Requires: curl, python3

set -euo pipefail

MAYAN_URL="${MAYAN_URL:-http://localhost:8000}"
MAYAN_USER="${MAYAN_USER:-admin}"
MAYAN_PASSWORD="${MAYAN_PASSWORD:?Set MAYAN_PASSWORD}"
BASE="$MAYAN_URL/api/v4"

log() { echo "==> $*" >&2; }

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
log "Obtaining auth token for $MAYAN_USER"
TOKEN=$(curl -sf -X POST "$BASE/auth/token/obtain/" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -d "{\"username\":\"$MAYAN_USER\",\"password\":\"$MAYAN_PASSWORD\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

api() {
  # api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sf -X "$method" "$BASE$path" \
      -H "Authorization: Token $TOKEN" -H "Accept: application/json" -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -sf -X "$method" "$BASE$path" \
      -H "Authorization: Token $TOKEN" -H "Accept: application/json"
  fi
}

json_get() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

api_all_results() {
  # api_all_results PATH -- follows "next" pagination, prints a JSON array
  local path="$1"
  python3 -c "
import json, subprocess, sys

base, token = sys.argv[1], sys.argv[2]
path = sys.argv[3]
results = []
while path:
    out = subprocess.run(
        ['curl', '-sf', base + path, '-H', f'Authorization: Token {token}', '-H', 'Accept: application/json'],
        capture_output=True, check=True, text=True,
    ).stdout
    data = json.loads(out)
    results.extend(data['results'])
    nxt = data.get('next')
    path = nxt[len(base):] if nxt else None
print(json.dumps(results))
" "$BASE" "$TOKEN" "$path"
}

# ---------------------------------------------------------------------------
# 1. Metadata type "unique_ref" (find-or-create)
# ---------------------------------------------------------------------------
log "Looking up existing metadata type 'unique_ref'"
UNIQUE_REF_ID=$(api_all_results "/metadata_types/?page_size=100" | python3 -c "
import json, sys
types = json.load(sys.stdin)
match = next((t for t in types if t['name'] == 'unique_ref'), None)
print(match['id'] if match else '')
")

if [[ -z "$UNIQUE_REF_ID" ]]; then
  log "Creating metadata type 'unique_ref'"
  UNIQUE_REF_ID=$(api POST "/metadata_types/" '{"name":"unique_ref","label":"Unique Reference"}' | json_get "['id']")
fi
log "  unique_ref -> id=$UNIQUE_REF_ID"

# ---------------------------------------------------------------------------
# 2. Attach to the three hierarchy document types (optional, idempotent)
# ---------------------------------------------------------------------------
log "Looking up hierarchy document type ids"
DOC_TYPES_JSON=$(api_all_results "/document_types/?page_size=100")

lookup_doc_type_id() {
  local label="$1"
  echo "$DOC_TYPES_JSON" | python3 -c "
import json, sys
label = sys.argv[1]
types = json.load(sys.stdin)
match = next((t for t in types if t['label'] == label), None)
print(match['id'] if match else '')
" "$label"
}

CUSTOMER_DOC_TYPE_ID=$(lookup_doc_type_id "Customer Document")
ACCOUNT_DOC_TYPE_ID=$(lookup_doc_type_id "Account Document")
APPLICATION_DOC_TYPE_ID=$(lookup_doc_type_id "Application Document")

for pair in "Customer Document:$CUSTOMER_DOC_TYPE_ID" "Account Document:$ACCOUNT_DOC_TYPE_ID" "Application Document:$APPLICATION_DOC_TYPE_ID"; do
  label="${pair%%:*}"
  id="${pair#*:}"
  if [[ -z "$id" ]]; then
    echo "ERROR: document type '$label' not found -- run setup_document_hierarchy.sh first" >&2
    exit 1
  fi
  log "  $label -> id=$id"
done

log "Attaching 'unique_ref' to hierarchy document types (optional for now)"
for pair in "Customer Document:$CUSTOMER_DOC_TYPE_ID" "Account Document:$ACCOUNT_DOC_TYPE_ID" "Application Document:$APPLICATION_DOC_TYPE_ID"; do
  label="${pair%%:*}"
  doc_type_id="${pair#*:}"
  already_attached=$(api_all_results "/document_types/$doc_type_id/metadata_types/?page_size=100" | python3 -c "
import json, sys
target = int(sys.argv[1])
rels = json.load(sys.stdin)
print('yes' if any(r['metadata_type']['id'] == target for r in rels) else '')
" "$UNIQUE_REF_ID")
  if [[ -n "$already_attached" ]]; then
    log "  $label: already attached, skipping"
  else
    api POST "/document_types/$doc_type_id/metadata_types/" \
      "{\"metadata_type_id\":$UNIQUE_REF_ID,\"required\":false}" > /dev/null
    log "  $label: attached unique_ref (optional)"
  fi
done

# ---------------------------------------------------------------------------
# 3. Backfill a UUID onto every hierarchy document missing one
# ---------------------------------------------------------------------------
log "Fetching all documents"
ALL_DOCS_JSON=$(api_all_results "/documents/?page_size=100")

HIERARCHY_TYPE_IDS="$CUSTOMER_DOC_TYPE_ID,$ACCOUNT_DOC_TYPE_ID,$APPLICATION_DOC_TYPE_ID"
DOC_IDS=$(echo "$ALL_DOCS_JSON" | python3 -c "
import json, sys
hierarchy_ids = {int(x) for x in sys.argv[1].split(',')}
docs = json.load(sys.stdin)
for d in docs:
    if d['document_type']['id'] in hierarchy_ids:
        print(d['id'])
" "$HIERARCHY_TYPE_IDS")

log "Backfilling unique_ref values"
for doc_id in $DOC_IDS; do
  existing=$(api "GET" "/documents/$doc_id/metadata/?page_size=100" | python3 -c "
import json, sys
entries = json.load(sys.stdin)['results']
match = next((e for e in entries if e['metadata_type']['name'] == 'unique_ref'), None)
print(match['value'] if match else '')
")
  if [[ -n "$existing" ]]; then
    log "  document $doc_id: already has unique_ref=$existing, skipping"
  else
    value=$(python3 -c "import uuid; print(uuid.uuid4())")
    api POST "/documents/$doc_id/metadata/" \
      "{\"metadata_type_id\":$UNIQUE_REF_ID,\"value\":\"$value\"}" > /dev/null
    log "  document $doc_id: assigned unique_ref=$value"
  fi
done

# ---------------------------------------------------------------------------
# 4. Now that every document has a value, make the field required
# ---------------------------------------------------------------------------
log "Marking 'unique_ref' required on hierarchy document types"
for pair in "Customer Document:$CUSTOMER_DOC_TYPE_ID" "Account Document:$ACCOUNT_DOC_TYPE_ID" "Application Document:$APPLICATION_DOC_TYPE_ID"; do
  label="${pair%%:*}"
  doc_type_id="${pair#*:}"
  relation=$(api_all_results "/document_types/$doc_type_id/metadata_types/?page_size=100" | python3 -c "
import json, sys
target = int(sys.argv[1])
rels = json.load(sys.stdin)
match = next((r for r in rels if r['metadata_type']['id'] == target), None)
print(json.dumps({'id': match['id'], 'required': match['required']}) if match else '')
" "$UNIQUE_REF_ID")
  relation_id=$(echo "$relation" | json_get "['id']")
  is_required=$(echo "$relation" | json_get "['required']")
  if [[ "$is_required" == "True" ]]; then
    log "  $label: already required, skipping"
  else
    api PATCH "/document_types/$doc_type_id/metadata_types/$relation_id/" '{"required": true}' > /dev/null
    log "  $label: now required"
  fi
done

log "Done."

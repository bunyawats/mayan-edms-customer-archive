#!/usr/bin/env bash
#
# Adds three flat, single-level index templates alongside the existing
# nested "Customer Archive" index:
#   - Customer    -- every document with a customer_id, grouped by value
#   - Account     -- every document with an account_id, grouped by value
#   - Application -- every document with an application_id, grouped by value
#
# Unlike "Customer Archive" these don't nest by category or drill down --
# each is a single group-and-attach level, so e.g. the Account index shows
# every document (Welcome Letter, Financial Records, Agreements, ...) that
# belongs to a given account_id side by side in one flat list.
#
# Each index is scoped to only the document types that actually carry that
# metadata field (Customer Document has no account_id, so it's left off the
# Account index, etc.) -- this avoids ever creating an empty/"None" bucket,
# unlike the nested index where that's a real concern (see
# docs/document-hierarchy-setup.md's Gotcha #1).
#
# Idempotent: safe to re-run against an instance it's already been applied
# to (finds existing index templates by slug, existing document-type
# attachments, and existing leaf nodes by expression, and skips whatever's
# already there).
#
# Assumes setup_document_hierarchy.sh has already been run (the three
# document types must already exist).
#
# Usage:
#   MAYAN_URL=http://localhost:8000 MAYAN_USER=admin MAYAN_PASSWORD=... ./add_flat_indexes.sh
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

log "Looking up document type ids"
DOC_TYPES_JSON=$(api_all_results "/document_types/?page_size=100")

lookup_doc_type_id() {
  local label="$1"
  local id
  id=$(echo "$DOC_TYPES_JSON" | python3 -c "
import json, sys
label = sys.argv[1]
types = json.load(sys.stdin)
match = next((t for t in types if t['label'] == label), None)
print(match['id'] if match else '')
" "$label")
  if [[ -z "$id" ]]; then
    echo "ERROR: document type '$label' not found -- run setup_document_hierarchy.sh first" >&2
    exit 1
  fi
  echo "$id"
}

DT_CUSTOMER=$(lookup_doc_type_id "Customer Document")
DT_ACCOUNT=$(lookup_doc_type_id "Account Document")
DT_APPLICATION=$(lookup_doc_type_id "Application Document")

# ---------------------------------------------------------------------------
# setup_flat_index SLUG LABEL METADATA_FIELD DOC_TYPE_ID [DOC_TYPE_ID ...]
# ---------------------------------------------------------------------------
setup_flat_index() {
  local slug="$1" label="$2" field="$3"
  shift 3

  log "Index '$label' (slug=$slug)"

  local existing index_id root_node_id
  existing=$(api_all_results "/index_templates/?page_size=100" | python3 -c "
import json, sys
slug = sys.argv[1]
data = json.load(sys.stdin)
match = next((t for t in data if t['slug'] == slug), None)
print(json.dumps(match) if match else '')
" "$slug")

  if [[ -n "$existing" ]]; then
    index_id=$(echo "$existing" | json_get "['id']")
    root_node_id=$(echo "$existing" | json_get "['index_template_root_node_id']")
    log "  already exists -> id=$index_id"
  else
    local resp
    resp=$(api POST "/index_templates/" "{\"label\":\"$label\",\"slug\":\"$slug\",\"enabled\":true}")
    index_id=$(echo "$resp" | json_get "['id']")
    root_node_id=$(echo "$resp" | json_get "['index_template_root_node_id']")
    log "  created -> id=$index_id"
  fi

  local attached_ids
  attached_ids=$(api_all_results "/index_templates/$index_id/document_types/?page_size=100" | python3 -c "
import json, sys
print(json.dumps([t['id'] for t in json.load(sys.stdin)]))
")

  local doc_type_id
  for doc_type_id in "$@"; do
    local already
    already=$(echo "$attached_ids" | python3 -c "
import json, sys
ids = json.load(sys.stdin)
print('yes' if int(sys.argv[1]) in ids else '')
" "$doc_type_id")
    if [[ -n "$already" ]]; then
      log "  document_type $doc_type_id already attached"
    else
      api POST "/index_templates/$index_id/document_types/add/" "{\"document_type\":$doc_type_id}" > /dev/null
      log "  attached document_type $doc_type_id"
    fi
  done

  local target_expr="{{ document.metadata_value_of.$field }}"
  local node_exists
  # /nodes/ returns the root's immediate children directly in `results`
  # (each with its own nested "children" for deeper levels) -- there's no
  # separate wrapper item for the root itself.
  node_exists=$(api "GET" "/index_templates/$index_id/nodes/" | python3 -c "
import json, sys
target = sys.argv[1]
data = json.load(sys.stdin)
print('yes' if any(n['expression'] == target for n in data['results']) else '')
" "$target_expr")

  if [[ -n "$node_exists" ]]; then
    log "  leaf node already exists"
  else
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({'parent': int(sys.argv[1]), 'expression': sys.argv[2], 'link_documents': True, 'enabled': True}))
" "$root_node_id" "$target_expr")
    api POST "/index_templates/$index_id/nodes/" "$payload" > /dev/null
    log "  created leaf node"
  fi

  log "  rebuilding index"
  api POST "/index_templates/$index_id/rebuild/" > /dev/null
}

setup_flat_index "customer" "Customer" "customer_id" "$DT_CUSTOMER" "$DT_ACCOUNT" "$DT_APPLICATION"
setup_flat_index "account" "Account" "account_id" "$DT_ACCOUNT" "$DT_APPLICATION"
setup_flat_index "application" "Application" "application_id" "$DT_APPLICATION"

log "Done."

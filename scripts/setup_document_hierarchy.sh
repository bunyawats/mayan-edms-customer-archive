#!/usr/bin/env bash
#
# Builds the "Customer Archive" document hierarchy in Mayan EDMS via the REST API:
#   Metadata Types -> Document Types -> Index Template (with nested node tree)
#
# See docs/document-hierarchy-setup.md for the full design writeup, including
# the "None" node gotcha this script's leaf expressions work around.
#
# Usage:
#   MAYAN_URL=http://localhost:8000 MAYAN_USER=admin MAYAN_PASSWORD=... ./setup_document_hierarchy.sh
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

# ---------------------------------------------------------------------------
# 1. Metadata types
# ---------------------------------------------------------------------------
log "Creating metadata types"
declare -A METADATA_TYPE_ID
for entry in "customer_id:Customer ID" "account_id:Account ID" "application_id:Application ID" "category:Category"; do
  name="${entry%%:*}"
  label="${entry#*:}"
  id=$(api POST "/metadata_types/" "{\"name\":\"$name\",\"label\":\"$label\"}" | json_get "['id']")
  METADATA_TYPE_ID["$name"]="$id"
  log "  $name -> id=$id"
done

# ---------------------------------------------------------------------------
# 2. Document types + required metadata associations
# ---------------------------------------------------------------------------
log "Creating document types"
declare -A DOCUMENT_TYPE_ID
for label in "Customer Document" "Account Document" "Application Document"; do
  id=$(api POST "/document_types/" "{\"label\":\"$label\"}" | json_get "['id']")
  DOCUMENT_TYPE_ID["$label"]="$id"
  log "  $label -> id=$id"
done

attach_metadata() {
  local doc_type_id="$1" metadata_name="$2"
  local metadata_type_id="${METADATA_TYPE_ID[$metadata_name]}"
  api POST "/document_types/$doc_type_id/metadata_types/" \
    "{\"metadata_type_id\":$metadata_type_id,\"required\":true}" > /dev/null
}

log "Attaching required metadata to document types"
for m in customer_id category; do attach_metadata "${DOCUMENT_TYPE_ID['Customer Document']}" "$m"; done
for m in customer_id account_id category; do attach_metadata "${DOCUMENT_TYPE_ID['Account Document']}" "$m"; done
for m in customer_id account_id application_id category; do attach_metadata "${DOCUMENT_TYPE_ID['Application Document']}" "$m"; done

# ---------------------------------------------------------------------------
# 3. Index template
# ---------------------------------------------------------------------------
log "Creating index template 'Customer Archive'"
INDEX_RESPONSE=$(api POST "/index_templates/" '{"label":"Customer Archive","slug":"customer-archive","enabled":true}')
INDEX_ID=$(echo "$INDEX_RESPONSE" | json_get "['id']")
ROOT_NODE_ID=$(echo "$INDEX_RESPONSE" | json_get "['index_template_root_node_id']")
log "  index id=$INDEX_ID root_node_id=$ROOT_NODE_ID"

log "Attaching document types to the index"
for label in "Customer Document" "Account Document" "Application Document"; do
  api POST "/index_templates/$INDEX_ID/document_types/add/" \
    "{\"document_type\":${DOCUMENT_TYPE_ID[$label]}}" > /dev/null
done

post_node() {
  # post_node PARENT_ID EXPRESSION LINK_DOCUMENTS(true|false)
  local parent="$1" expr="$2" link_docs="$3"
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'parent': int(sys.argv[1]),
    'expression': sys.argv[2],
    'link_documents': sys.argv[3] == 'true',
    'enabled': True,
}))
" "$parent" "$expr" "$link_docs")
  api POST "/index_templates/$INDEX_ID/nodes/" "$payload" | json_get "['id']"
}

log "Building node hierarchy"

# Level 1: group by customer_id. Empty when a document has no customer_id.
NODE_CUSTOMER=$(post_node "$ROOT_NODE_ID" \
  '{{ document.metadata_value_of.customer_id }}' \
  "false")
log "  customer_id node -> id=$NODE_CUSTOMER"

# Branch A (leaf): customer-level docs -- no account_id and no application_id.
NODE_BRANCH_A=$(post_node "$NODE_CUSTOMER" \
  '{% if not document.metadata_value_of.account_id and not document.metadata_value_of.application_id %}{{ document.metadata_value_of.category }}{% endif %}' \
  "true")
log "  branch A (customer docs, leaf) -> id=$NODE_BRANCH_A"

# Branch B: group by account_id.
NODE_ACCOUNT=$(post_node "$NODE_CUSTOMER" \
  '{{ document.metadata_value_of.account_id }}' \
  "false")
log "  account_id node -> id=$NODE_ACCOUNT"

# Branch B1 (leaf): account-level docs -- account_id present, no application_id.
# NOTE: condition repeats "account_id present" rather than relying on the
# parent node being non-empty -- see docs/document-hierarchy-setup.md for why.
NODE_BRANCH_B1=$(post_node "$NODE_ACCOUNT" \
  '{% if document.metadata_value_of.account_id and not document.metadata_value_of.application_id %}{{ document.metadata_value_of.category }}{% endif %}' \
  "true")
log "  branch B1 (account docs, leaf) -> id=$NODE_BRANCH_B1"

# Branch B2: group by application_id.
NODE_APPLICATION=$(post_node "$NODE_ACCOUNT" \
  '{{ document.metadata_value_of.application_id }}' \
  "false")
log "  application_id node -> id=$NODE_APPLICATION"

# Leaf: application-level docs -- account_id AND application_id both present.
NODE_LEAF_CATEGORY=$(post_node "$NODE_APPLICATION" \
  '{% if document.metadata_value_of.account_id and document.metadata_value_of.application_id %}{{ document.metadata_value_of.category }}{% endif %}' \
  "true")
log "  category node (application docs, leaf) -> id=$NODE_LEAF_CATEGORY"

log "Rebuilding index"
api POST "/index_templates/$INDEX_ID/rebuild/" > /dev/null

log "Done. Index template id=$INDEX_ID, slug=customer-archive"

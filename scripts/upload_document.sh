#!/usr/bin/env bash
#
# Uploads one existing file into the "Customer Archive" hierarchy (see
# docs/document-hierarchy-setup.md), tagging it with the metadata needed
# to file it at the customer, account, or application level.
#
# The document type (Customer / Account / Application Document) and the
# index leaf it lands in are both derived from which IDs you pass:
#   customer_id only               -> Customer Document  (customer-level leaf)
#   customer_id + account_id       -> Account Document    (account-level leaf)
#   customer_id + account_id + application_id
#                                   -> Application Document (application-level leaf)
#
# Usage:
#   MAYAN_URL=http://localhost:8000 MAYAN_USER=admin MAYAN_PASSWORD=... \
#     ./upload_document.sh <file> <customer_id> <category> [account_id] [application_id]
#
# Examples:
#   ./upload_document.sh test-docs/test-doc.pdf Cust-1001 "Welcome Letter" Acc-88210
#   ./upload_document.sh test-docs/id-scan.pdf Cust-1003 "Photo ID"
#   ./upload_document.sh test-docs/contract.pdf Cust-1001 Agreements Acc-88210 App-90042
#
# Requires: curl, python3

set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
  echo "Usage: $0 <file> <customer_id> <category> [account_id] [application_id]" >&2
  exit 1
fi

FILE_PATH="$1"
CUSTOMER_ID="$2"
CATEGORY="$3"
ACCOUNT_ID="${4:-}"
APPLICATION_ID="${5:-}"

if [[ -n "$APPLICATION_ID" && -z "$ACCOUNT_ID" ]]; then
  echo "application_id requires account_id to also be set" >&2
  exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
  echo "File not found: $FILE_PATH" >&2
  exit 1
fi

MAYAN_URL="${MAYAN_URL:-http://localhost:8000}"
MAYAN_USER="${MAYAN_USER:-admin}"
MAYAN_PASSWORD="${MAYAN_PASSWORD:?Set MAYAN_PASSWORD}"
BASE="$MAYAN_URL/api/v4"

log() { echo "==> $*" >&2; }

log "Obtaining auth token for $MAYAN_USER"
TOKEN=$(curl -sf -X POST "$BASE/auth/token/obtain/" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -d "{\"username\":\"$MAYAN_USER\",\"password\":\"$MAYAN_PASSWORD\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

api_get() {
  curl -sf "$BASE$1" -H "Authorization: Token $TOKEN" -H "Accept: application/json"
}

lookup_id() {
  # lookup_id ENDPOINT FIELD VALUE
  api_get "$1" | python3 -c "
import json, sys
field, value = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
for r in data['results']:
    if r[field] == value:
        print(r['id'])
        sys.exit(0)
sys.exit('not found: ' + value)
" "$2" "$3"
}

log "Looking up metadata type and document type IDs"
MT_CUSTOMER=$(lookup_id "/metadata_types/" name customer_id)
MT_ACCOUNT=$(lookup_id "/metadata_types/" name account_id)
MT_APPLICATION=$(lookup_id "/metadata_types/" name application_id)
MT_CATEGORY=$(lookup_id "/metadata_types/" name category)

if [[ -n "$APPLICATION_ID" ]]; then
  DOC_TYPE_ID=$(lookup_id "/document_types/" label "Application Document")
elif [[ -n "$ACCOUNT_ID" ]]; then
  DOC_TYPE_ID=$(lookup_id "/document_types/" label "Account Document")
else
  DOC_TYPE_ID=$(lookup_id "/document_types/" label "Customer Document")
fi

FILENAME=$(basename "$FILE_PATH")

log "Creating document ($FILENAME, document_type_id=$DOC_TYPE_ID)"
DOC_ID=$(curl -sf -X POST "$BASE/documents/" \
  -H "Authorization: Token $TOKEN" -H "Accept: application/json" -H "Content-Type: application/json" \
  -d "{\"document_type_id\":$DOC_TYPE_ID,\"label\":\"$FILENAME\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
log "  doc_id=$DOC_ID"

log "Uploading file"
curl -sf -X POST "$BASE/documents/$DOC_ID/files/" \
  -H "Authorization: Token $TOKEN" -H "Accept: application/json" \
  -F "action_name=replace" -F "file_new=@$FILE_PATH" > /dev/null

attach_metadata() {
  local mt_id="$1" value="$2"
  curl -sf -X POST "$BASE/documents/$DOC_ID/metadata/" \
    -H "Authorization: Token $TOKEN" -H "Accept: application/json" -H "Content-Type: application/json" \
    -d "{\"metadata_type_id\":$mt_id,\"value\":\"$value\"}" > /dev/null
}

log "Attaching metadata"
attach_metadata "$MT_CUSTOMER" "$CUSTOMER_ID"
[[ -n "$ACCOUNT_ID" ]] && attach_metadata "$MT_ACCOUNT" "$ACCOUNT_ID"
[[ -n "$APPLICATION_ID" ]] && attach_metadata "$MT_APPLICATION" "$APPLICATION_ID"
attach_metadata "$MT_CATEGORY" "$CATEGORY"

log "Rebuilding the Customer Archive index"
INDEX_ID=$(api_get "/index_templates/" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data['results']:
    if r['slug'] == 'customer-archive':
        print(r['id'])
        sys.exit(0)
sys.exit('index template not found: customer-archive')
")
curl -sf -X POST "$BASE/index_templates/$INDEX_ID/rebuild/" \
  -H "Authorization: Token $TOKEN" -H "Accept: application/json" > /dev/null

# The index update triggered by each metadata POST above runs asynchronously
# (via Celery) and can momentarily misfile a document that was just tagged
# field-by-field. The explicit rebuild above resolves it, but give the
# workers a moment to finish processing it before you check the index.
log "Done. doc_id=$DOC_ID. Give the index a few seconds to settle before checking it."

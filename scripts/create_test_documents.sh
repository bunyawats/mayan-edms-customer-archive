#!/usr/bin/env bash
#
# Uploads a standard set of 4 test documents for one customer into the
# "Customer Archive" hierarchy (see docs/document-hierarchy-setup.md):
#
#   <customer_id>
#   ├── Photo ID/            National_ID_Card.pdf        (Customer Document)
#   └── <account_id>
#       ├── Welcome Letter/  Welcome_Letter.pdf           (Account Document)
#       └── <application_id>
#           ├── Financial Records/  Bank_Statement.pdf     (Application Document)
#           └── Agreements/         Loan_Contract.pdf       (Application Document)
#
# Looks up metadata type / document type IDs by name at runtime, so it
# works against any instance that already has the hierarchy's metadata
# types and document types set up (via setup_document_hierarchy.sh).
#
# Usage:
#   MAYAN_URL=http://localhost:8000 MAYAN_USER=admin MAYAN_PASSWORD=... \
#     ./create_test_documents.sh Cust-1002 Acc-99001 App-12345
#
# Requires: curl, python3

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <customer_id> <account_id> <application_id>" >&2
  exit 1
fi

CUSTOMER_ID="$1"
ACCOUNT_ID="$2"
APPLICATION_ID="$3"

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

# Look up metadata type / document type IDs by name/label so this works
# regardless of what order they were created in on a given instance.
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
MT_UNIQUE_REF=$(lookup_id "/metadata_types/" name unique_ref)

new_uuid() { python3 -c "import uuid; print(uuid.uuid4())"; }

DT_CUSTOMER=$(lookup_id "/document_types/" label "Customer Document")
DT_ACCOUNT=$(lookup_id "/document_types/" label "Account Document")
DT_APPLICATION=$(lookup_id "/document_types/" label "Application Document")

SCRATCH_DIR=$(mktemp -d)
trap 'rm -rf "$SCRATCH_DIR"' EXIT

make_dummy_pdf() {
  # Writes a genuinely valid, parseable one-page PDF to "$SCRATCH_DIR/$1"
  # (correct xref table and byte offsets, computed in Python). A raw
  # "%PDF-1.4 ... %%EOF" stub with no real object/xref structure LOOKS like
  # a PDF (mimetype detection, checksum, upload all succeed) but has no
  # pages Mayan's converter can extract -- see docs/document-hierarchy-setup.md,
  # "Gotcha #3", for how this bit every document created by an earlier
  # version of this script.
  python3 - "$1" "$SCRATCH_DIR/$1" << 'PYEOF'
import sys

def make_pdf(title: str) -> bytes:
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    stream_content = f"BT /F1 24 Tf 72 700 Td ({title}) Tj ET".encode("latin-1")
    objects.append(
        f"<< /Length {len(stream_content)} >>\nstream\n".encode("latin-1")
        + stream_content
        + b"\nendstream"
    )

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode("latin-1") + body + b"\nendobj\n"

    xref_offset = len(out)
    n = len(objects) + 1
    out += f"xref\n0 {n}\n".encode("latin-1")
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode("latin-1")
    out += b"trailer\n" + f"<< /Size {n} /Root 1 0 R >>\n".encode("latin-1")
    out += b"startxref\n" + f"{xref_offset}\n".encode("latin-1") + b"%%EOF"
    return bytes(out)

title, out_path = sys.argv[1], sys.argv[2]
with open(out_path, "wb") as f:
    f.write(make_pdf(title))
PYEOF
}

create_doc() {
  # create_doc FILENAME DOCUMENT_TYPE_ID "metadata_type_id:value" ...
  local filename="$1" doc_type_id="$2"
  shift 2
  make_dummy_pdf "$filename"

  local doc_id
  doc_id=$(curl -sf -X POST "$BASE/documents/" \
    -H "Authorization: Token $TOKEN" -H "Accept: application/json" -H "Content-Type: application/json" \
    -d "{\"document_type_id\":$doc_type_id,\"label\":\"$filename\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

  curl -sf -X POST "$BASE/documents/$doc_id/files/" \
    -H "Authorization: Token $TOKEN" -H "Accept: application/json" \
    -F "action_name=replace" -F "file_new=@$SCRATCH_DIR/$filename" > /dev/null

  for pair in "$@"; do
    local mt_id="${pair%%:*}"
    local val="${pair#*:}"
    curl -sf -X POST "$BASE/documents/$doc_id/metadata/" \
      -H "Authorization: Token $TOKEN" -H "Accept: application/json" -H "Content-Type: application/json" \
      -d "{\"metadata_type_id\":$mt_id,\"value\":\"$val\"}" > /dev/null
  done
  log "  created doc_id=$doc_id ($filename)"
}

FILE_PREFIX="${CUSTOMER_ID}_"

log "Creating documents for $CUSTOMER_ID / $ACCOUNT_ID / $APPLICATION_ID"

create_doc "${FILE_PREFIX}National_ID_Card.pdf" "$DT_CUSTOMER" \
  "$MT_CUSTOMER:$CUSTOMER_ID" "$MT_CATEGORY:Photo ID" "$MT_UNIQUE_REF:$(new_uuid)"

create_doc "${FILE_PREFIX}Welcome_Letter.pdf" "$DT_ACCOUNT" \
  "$MT_CUSTOMER:$CUSTOMER_ID" "$MT_ACCOUNT:$ACCOUNT_ID" "$MT_CATEGORY:Welcome Letter" "$MT_UNIQUE_REF:$(new_uuid)"

create_doc "${FILE_PREFIX}Bank_Statement.pdf" "$DT_APPLICATION" \
  "$MT_CUSTOMER:$CUSTOMER_ID" "$MT_ACCOUNT:$ACCOUNT_ID" "$MT_APPLICATION:$APPLICATION_ID" "$MT_CATEGORY:Financial Records" "$MT_UNIQUE_REF:$(new_uuid)"

create_doc "${FILE_PREFIX}Loan_Contract.pdf" "$DT_APPLICATION" \
  "$MT_CUSTOMER:$CUSTOMER_ID" "$MT_ACCOUNT:$ACCOUNT_ID" "$MT_APPLICATION:$APPLICATION_ID" "$MT_CATEGORY:Agreements" "$MT_UNIQUE_REF:$(new_uuid)"

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

log "Done."

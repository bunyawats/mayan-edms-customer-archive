import asyncio
import uuid
from typing import Any

import httpx

from .mayan_client import (
    DOCUMENT_TYPE_BY_LEVEL,
    METADATA_FIELDS,
    document_level,
    mayan_client,
)

# POC-scale safety bound: beyond this many documents, metadata search would
# need real server-side filtering (see docs/document-hierarchy-setup.md /
# webapp CLAUDE.md section for why the advanced search API can't do this
# precisely) rather than fetch-all-then-filter.
MAX_SEARCH_CANDIDATES = 1000


async def _fetch_all_documents(cap: int = MAX_SEARCH_CANDIDATES) -> list[dict[str, Any]]:
    documents: list[dict[str, Any]] = []
    page = 1
    while len(documents) < cap:
        data = await mayan_client.list_documents(page=page, page_size=100)
        documents.extend(data["results"])
        if not data.get("next"):
            break
        page += 1
    return documents[:cap]


async def _fetch_metadata_or_none(document: dict[str, Any]) -> dict[str, Any] | None:
    try:
        entries = await mayan_client.get_document_metadata(document["id"])
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code == 404:
            # Deleted concurrently with this request (e.g. the results
            # refresh right after a bulk-delete can still see the document
            # in the list for a moment before Mayan's trash takes effect)
            # — drop it rather than failing the whole search.
            return None
        raise
    document["_metadata"] = {entry["metadata_type"]["name"]: entry["value"] for entry in entries}
    return document


async def _attach_metadata(documents: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Fetch metadata for each document, dropping any that 404. Returns the
    (possibly shorter) list — callers must use the return value, not assume
    in-place mutation preserves every item."""
    if not documents:
        return documents
    results = await asyncio.gather(*(_fetch_metadata_or_none(doc) for doc in documents))
    return [doc for doc in results if doc is not None]


async def search_documents(filters: dict[str, str], page: int, page_size: int) -> tuple[list[dict], int]:
    """Exact-match metadata search + our own pagination.

    Mayan's advanced search API (/api/v4/search/advanced/documents.documentsearchresult/)
    accepts metadata__metadata_type__name and metadata__value as separate
    query params, but combining them does NOT AND against the same metadata
    row — verified live: querying for customer_id=Cust-1001 that way matched
    every document in the instance, not just the ones with that value under
    that specific field. So instead: fetch the (POC-scale) full document
    list, fetch each candidate's real metadata, and filter exactly in
    Python. Acceptable at this data volume; would need a different approach
    (real server-side filtering) at production scale.
    """
    label = (filters.get("label") or "").strip()
    metadata_filters = {k: v.strip() for k, v in filters.items() if k != "label" and v and v.strip()}

    if metadata_filters or label:
        candidates = await _fetch_all_documents()
        if label:
            candidates = [d for d in candidates if label.lower() in d["label"].lower()]
        if metadata_filters:
            candidates = await _attach_metadata(candidates)
            candidates = [
                d for d in candidates if all(d["_metadata"].get(k) == v for k, v in metadata_filters.items())
            ]
        total = len(candidates)
        start = (page - 1) * page_size
        page_items = candidates[start : start + page_size]
    else:
        data = await mayan_client.list_documents(page=page, page_size=page_size)
        page_items = data["results"]
        total = data["count"]

    # Items that already have _metadata came from the exact-match branch
    # above (already survived _attach_metadata there); the rest need it
    # fetched now. Either way, drop anything that 404'd (deleted
    # concurrently) rather than crash the page — a very small, self-healing
    # inconsistency with `total` is an acceptable tradeoff at POC scale.
    need_metadata = [d for d in page_items if "_metadata" not in d]
    fetched_ids = {d["id"] for d in await _attach_metadata(need_metadata)}
    dropped_ids = {d["id"] for d in need_metadata} - fetched_ids
    if dropped_ids:
        page_items = [d for d in page_items if d["id"] not in dropped_ids]
        total = max(0, total - len(dropped_ids))
    return page_items, total


async def get_category_options() -> list[str]:
    """Distinct category values currently in use across documents, for the
    search filter's dropdown. Reflects what's actually in Mayan (as of this
    call) rather than a hardcoded list, so a category only shows up once a
    document uses it. Fetches the same POC-scale-capped document set
    search_documents does — see MAX_SEARCH_CANDIDATES above."""
    documents = await _attach_metadata(await _fetch_all_documents())
    categories = {d["_metadata"].get("category") for d in documents}
    categories.discard(None)
    categories.discard("")
    return sorted(categories)


async def get_metadata_map(document_id: int) -> dict[str, str]:
    entries = await mayan_client.get_document_metadata(document_id)
    return {entry["metadata_type"]["name"]: entry["value"] for entry in entries}


async def upload_document(
    customer_id: str, account_id: str, application_id: str, category: str, filename: str, content: bytes
) -> dict[str, Any]:
    level = document_level(customer_id, account_id, application_id)
    doc_type_ids, metadata_type_ids = await asyncio.gather(
        mayan_client.document_type_ids(), mayan_client.metadata_type_ids()
    )

    document = await mayan_client.create_document(doc_type_ids[DOCUMENT_TYPE_BY_LEVEL[level]], filename)
    document_id = document["id"]

    await mayan_client.upload_file(document_id, filename, content)

    values = {
        "customer_id": customer_id,
        "account_id": account_id,
        "application_id": application_id,
        "category": category,
    }
    # Sequential, not concurrent: each attach call re-triggers async index
    # evaluation server-side (Gotcha #2 in docs/document-hierarchy-setup.md)
    # and firing them concurrently would make the race worse, not better.
    for field in METADATA_FIELDS:
        value = values[field]
        if value:
            await mayan_client.attach_metadata(document_id, metadata_type_ids[field], value)

    # unique_ref is assigned here, not user-entered -- it's not in
    # METADATA_FIELDS (that list drives the index-relevant, user-editable
    # fields) so it's never exposed on the edit-metadata form.
    if "unique_ref" in metadata_type_ids:
        await mayan_client.attach_metadata(document_id, metadata_type_ids["unique_ref"], str(uuid.uuid4()))

    await mayan_client.rebuild_index()
    return document


async def update_document_metadata(document_id: int, updates: dict[str, str]) -> None:
    entries = await mayan_client.get_document_metadata(document_id)
    by_name = {entry["metadata_type"]["name"]: entry for entry in entries}
    changed = False
    for field, value in updates.items():
        entry = by_name.get(field)
        if entry and entry["value"] != value:
            await mayan_client.update_metadata_entry(document_id, entry["id"], value)
            changed = True
    if changed:
        await mayan_client.rebuild_index()


async def get_documents_summary(document_ids: list[int]) -> list[dict[str, Any]]:
    """Fetch current label/type/metadata for the given ids, for the
    bulk-delete confirm dialog. Re-fetches from Mayan rather than trusting
    whatever the client's DOM last showed (that table row could be stale),
    and silently drops any id that 404s (deleted concurrently) rather than
    failing the whole dialog — same reasoning as _attach_metadata."""

    async def fetch(document_id: int) -> dict[str, Any] | None:
        try:
            document = await mayan_client.get_document(document_id)
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 404:
                return None
            raise
        metadata = await get_metadata_map(document_id)
        return {
            "id": document_id,
            "label": document["label"],
            "document_type": document["document_type"]["label"],
            "metadata": metadata,
        }

    results = await asyncio.gather(*(fetch(doc_id) for doc_id in document_ids))
    return [r for r in results if r is not None]


async def bulk_delete(document_ids: list[int]) -> tuple[int, int]:
    results = await asyncio.gather(*(mayan_client.delete_document(doc_id) for doc_id in document_ids))
    succeeded = sum(1 for ok, _ in results if ok)
    return succeeded, len(results) - succeeded

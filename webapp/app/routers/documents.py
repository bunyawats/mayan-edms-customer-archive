import math

import httpx
from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import StreamingResponse
from starlette.datastructures import UploadFile as StarletteUploadFile

from .. import documents_service as service
from ..config import settings
from ..mayan_client import mayan_client
from ..templating import render, render_error

router = APIRouter()


def _filters(customer_id: str, account_id: str, application_id: str, category: str, label: str) -> dict[str, str]:
    return {
        "customer_id": customer_id,
        "account_id": account_id,
        "application_id": application_id,
        "category": category,
        "label": label,
    }


async def _iter_and_close(response: httpx.Response):
    try:
        async for chunk in response.aiter_bytes():
            yield chunk
    finally:
        await response.aclose()


@router.get("/")
async def index(request: Request):
    filters = _filters("", "", "", "", "")
    try:
        documents, total = await service.search_documents(filters, page=1, page_size=settings.page_size)
    except httpx.HTTPError as exc:
        return render_error(request, f"Could not reach Mayan: {exc}")
    total_pages = max(1, math.ceil(total / settings.page_size))
    return render(
        request,
        "index.html",
        {
            "filters": filters,
            "documents": documents,
            "page": 1,
            "total": total,
            "total_pages": total_pages,
        },
    )


@router.get("/documents")
async def list_documents(
    request: Request,
    customer_id: str = "",
    account_id: str = "",
    application_id: str = "",
    category: str = "",
    label: str = "",
    page: int = 1,
):
    filters = _filters(customer_id, account_id, application_id, category, label)
    page = max(1, page)
    try:
        documents, total = await service.search_documents(filters, page=page, page_size=settings.page_size)
    except httpx.HTTPError as exc:
        return render_error(request, f"Search failed: {exc}")
    total_pages = max(1, math.ceil(total / settings.page_size))
    return render(
        request,
        "partials/results_table.html",
        {"filters": filters, "documents": documents, "page": page, "total": total, "total_pages": total_pages},
    )


@router.get("/documents/new")
async def new_document_form(request: Request):
    return render(request, "partials/upload_form.html", {})


@router.post("/documents")
async def create_document(
    request: Request,
    customer_id: str = Form(...),
    account_id: str = Form(""),
    application_id: str = Form(""),
    category: str = Form(...),
    file: UploadFile = File(...),
):
    customer_id, account_id, application_id, category = (
        customer_id.strip(),
        account_id.strip(),
        application_id.strip(),
        category.strip(),
    )
    if application_id and not account_id:
        return render_error(request, "Application ID requires an Account ID to also be set.")
    if not isinstance(file, StarletteUploadFile) or not file.filename:
        return render_error(request, "A file is required.")

    content = await file.read()
    try:
        await service.upload_document(customer_id, account_id, application_id, category, file.filename, content)
    except httpx.HTTPError as exc:
        return render_error(request, f"Upload failed: {exc}")

    filters = _filters("", "", "", "", "")
    documents, total = await service.search_documents(filters, page=1, page_size=settings.page_size)
    total_pages = max(1, math.ceil(total / settings.page_size))
    return render(
        request,
        "partials/upload_result.html",
        {
            "label": file.filename,
            "filters": filters,
            "documents": documents,
            "page": 1,
            "total": total,
            "total_pages": total_pages,
        },
    )


@router.get("/documents/{document_id}")
async def document_detail(request: Request, document_id: int):
    try:
        document = await mayan_client.get_document(document_id)
        metadata = await service.get_metadata_map(document_id)
    except httpx.HTTPStatusError as exc:
        return render_error(request, f"Could not load document: HTTP {exc.response.status_code}")
    file_latest = document.get("file_latest") or {}
    preview_available = bool(file_latest.get("pages_first"))
    return render(
        request,
        "partials/document_detail.html",
        {"document": document, "metadata": metadata, "preview_available": preview_available},
    )


@router.get("/documents/{document_id}/edit")
async def edit_document_form(request: Request, document_id: int):
    try:
        document = await mayan_client.get_document(document_id)
        metadata = await service.get_metadata_map(document_id)
    except httpx.HTTPStatusError as exc:
        return render_error(request, f"Could not load document: HTTP {exc.response.status_code}")
    return render(request, "partials/edit_metadata_form.html", {"document": document, "metadata": metadata})


@router.patch("/documents/{document_id}")
async def update_document(
    request: Request,
    document_id: int,
    customer_id: str = Form(""),
    account_id: str = Form(""),
    application_id: str = Form(""),
    category: str = Form(""),
):
    updates = {
        k: v.strip()
        for k, v in {
            "customer_id": customer_id,
            "account_id": account_id,
            "application_id": application_id,
            "category": category,
        }.items()
        if v.strip()
    }
    try:
        await service.update_document_metadata(document_id, updates)
        document = await mayan_client.get_document(document_id)
        metadata = await service.get_metadata_map(document_id)
    except httpx.HTTPStatusError as exc:
        return render_error(request, f"Update failed: HTTP {exc.response.status_code}")
    file_latest = document.get("file_latest") or {}
    preview_available = bool(file_latest.get("pages_first"))
    return render(
        request,
        "partials/document_detail.html",
        {"document": document, "metadata": metadata, "preview_available": preview_available},
    )


@router.delete("/documents/{document_id}")
async def delete_document(request: Request, document_id: int):
    ok, error = await mayan_client.delete_document(document_id)
    if not ok:
        return render_error(request, f"Delete failed: {error}")
    return ""


def _dedupe_and_cap(document_id: list[int]) -> tuple[list[int], str | None]:
    """De-dupe (preserve nothing in particular — order doesn't matter for a
    delete batch) and reject an over-large batch up front, before any Mayan
    call. Shared by the confirm-dialog route and the execute route so a
    request can't bypass the cap by skipping the dialog."""
    unique_ids = sorted(set(document_id))
    if len(unique_ids) > settings.bulk_delete_max:
        return [], f"Select at most {settings.bulk_delete_max} documents at once (got {len(unique_ids)})."
    return unique_ids, None


@router.post("/documents/bulk-delete/confirm")
async def bulk_delete_confirm(
    request: Request,
    document_id: list[int] = Form(default=[]),
    customer_id: str = Form(""),
    account_id: str = Form(""),
    application_id: str = Form(""),
    category: str = Form(""),
    label: str = Form(""),
    page: int = Form(1),
):
    filters = _filters(customer_id, account_id, application_id, category, label)
    unique_ids, error = _dedupe_and_cap(document_id)
    items: list = []
    if unique_ids and not error:
        try:
            items = await service.get_documents_summary(unique_ids)
        except httpx.HTTPError as exc:
            return render_error(request, f"Could not load selected documents: {exc}")
    return render(
        request,
        "partials/bulk_delete_confirm.html",
        {"items": items, "document_ids": unique_ids, "filters": filters, "page": page, "error": error},
    )


@router.post("/documents/bulk-delete")
async def bulk_delete_documents(
    request: Request,
    document_id: list[int] = Form(default=[]),
    customer_id: str = Form(""),
    account_id: str = Form(""),
    application_id: str = Form(""),
    category: str = Form(""),
    label: str = Form(""),
    page: int = Form(1),
):
    filters = _filters(customer_id, account_id, application_id, category, label)
    unique_ids, error = _dedupe_and_cap(document_id)
    status_message, status_class = None, "alert-info"

    if error:
        status_message, status_class = error, "alert-error"
    elif not unique_ids:
        status_message, status_class = "No documents selected.", "alert-error"
    else:
        succeeded, failed = await service.bulk_delete(unique_ids)
        status_message = f"{succeeded} deleted" + (f", {failed} failed" if failed else "")
        status_class = "alert-error" if failed else "alert-success"

    try:
        documents, total = await service.search_documents(filters, page=page, page_size=settings.page_size)
    except httpx.HTTPError as exc:
        return render_error(request, f"Refresh failed after delete: {exc}")
    total_pages = max(1, math.ceil(total / settings.page_size))
    if page > total_pages:
        page = total_pages
        documents, total = await service.search_documents(filters, page=page, page_size=settings.page_size)

    return render(
        request,
        "partials/bulk_delete_result.html",
        {
            "filters": filters,
            "documents": documents,
            "page": page,
            "total": total,
            "total_pages": total_pages,
            "status_message": status_message,
            "status_class": status_class,
        },
    )


@router.get("/documents/{document_id}/preview")
async def document_preview(document_id: int):
    try:
        document = await mayan_client.get_document(document_id)
    except httpx.HTTPStatusError:
        return StreamingResponse(iter([b""]), status_code=404, media_type="text/plain")
    file_latest = document.get("file_latest") or {}
    pages_first = file_latest.get("pages_first")
    if not pages_first:
        return StreamingResponse(iter([b""]), status_code=404, media_type="text/plain")
    path = mayan_client.relative_path(pages_first["image_url"])
    response = await mayan_client.stream(path)
    return StreamingResponse(
        _iter_and_close(response),
        media_type=response.headers.get("content-type", "image/jpeg"),
    )


@router.get("/documents/{document_id}/download")
async def document_download(document_id: int):
    try:
        document = await mayan_client.get_document(document_id)
    except httpx.HTTPStatusError:
        return StreamingResponse(iter([b""]), status_code=404, media_type="text/plain")
    file_latest = document.get("file_latest") or {}
    if not file_latest.get("id"):
        return StreamingResponse(iter([b""]), status_code=404, media_type="text/plain")
    path = f"/documents/{document_id}/files/{file_latest['id']}/download/"
    response = await mayan_client.stream(path)
    headers = {}
    if content_disposition := response.headers.get("content-disposition"):
        headers["Content-Disposition"] = content_disposition
    return StreamingResponse(
        _iter_and_close(response),
        media_type=response.headers.get("content-type", "application/octet-stream"),
        headers=headers,
    )

import asyncio
from typing import Any

import httpx

from .config import settings

DOCUMENT_TYPE_BY_LEVEL = {
    "customer": "Customer Document",
    "account": "Account Document",
    "application": "Application Document",
}

METADATA_FIELDS = ["customer_id", "account_id", "application_id", "category"]


def document_level(customer_id: str, account_id: str, application_id: str) -> str:
    if application_id:
        return "application"
    if account_id:
        return "account"
    return "customer"


class MayanClient:
    """Thin async wrapper around the Mayan EDMS REST API (/api/v4/).

    Holds one shared auth token (service-account model, see CLAUDE.md) and
    caches metadata-type / document-type ids by name, since those ids
    differ per Mayan instance and aren't safe to hardcode (same convention
    the shell scripts in scripts/ use).
    """

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(
            base_url=f"{settings.mayan_url}/api/v4",
            timeout=30.0,
            headers={"Accept": "application/json"},
        )
        self._token: str | None = None
        self._token_lock = asyncio.Lock()
        self._metadata_type_ids: dict[str, int] | None = None
        self._document_type_ids: dict[str, int] | None = None
        self._ids_lock = asyncio.Lock()

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _obtain_token(self) -> str:
        response = await self._client.post(
            "/auth/token/obtain/",
            json={"username": settings.mayan_user, "password": settings.mayan_password},
        )
        response.raise_for_status()
        return response.json()["token"]

    async def _ensure_token(self) -> str:
        if self._token is None:
            async with self._token_lock:
                if self._token is None:
                    self._token = await self._obtain_token()
        return self._token

    async def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        token = await self._ensure_token()
        headers = kwargs.pop("headers", {})
        headers["Authorization"] = f"Token {token}"
        response = await self._client.request(method, path, headers=headers, **kwargs)
        if response.status_code == 401:
            async with self._token_lock:
                self._token = await self._obtain_token()
            headers["Authorization"] = f"Token {self._token}"
            response = await self._client.request(method, path, headers=headers, **kwargs)
        return response

    async def get(self, path: str, **kwargs: Any) -> httpx.Response:
        return await self._request("GET", path, **kwargs)

    async def post(self, path: str, **kwargs: Any) -> httpx.Response:
        return await self._request("POST", path, **kwargs)

    async def patch(self, path: str, **kwargs: Any) -> httpx.Response:
        return await self._request("PATCH", path, **kwargs)

    async def delete(self, path: str, **kwargs: Any) -> httpx.Response:
        return await self._request("DELETE", path, **kwargs)

    async def stream(self, path: str):
        token = await self._ensure_token()
        request = self._client.build_request("GET", path, headers={"Authorization": f"Token {token}"})
        return await self._client.send(request, stream=True)

    @staticmethod
    def relative_path(url: str) -> str:
        """Strip the '<mayan_url>/api/v4' prefix Mayan includes in absolute
        URLs (pagination 'next', pages_first.image_url, etc.) so the path
        can be re-issued through this client's own base_url."""
        return url.removeprefix(f"{settings.mayan_url}/api/v4")

    # ------------------------------------------------------------------
    # Id lookups (cached for the process lifetime — set up once per
    # instance by scripts/setup_document_hierarchy.sh, not expected to
    # change while this service runs)
    # ------------------------------------------------------------------

    async def _load_id_map(self, path: str, key: str) -> dict[str, int]:
        ids: dict[str, int] = {}
        next_path: str | None = f"{path}?page_size=100"
        while next_path:
            response = await self.get(self.relative_path(next_path))
            response.raise_for_status()
            data = response.json()
            for result in data["results"]:
                ids[result[key]] = result["id"]
            next_path = data.get("next")
        return ids

    async def metadata_type_ids(self) -> dict[str, int]:
        if self._metadata_type_ids is None:
            async with self._ids_lock:
                if self._metadata_type_ids is None:
                    self._metadata_type_ids = await self._load_id_map("/metadata_types/", "name")
        return self._metadata_type_ids

    async def document_type_ids(self) -> dict[str, int]:
        if self._document_type_ids is None:
            async with self._ids_lock:
                if self._document_type_ids is None:
                    self._document_type_ids = await self._load_id_map("/document_types/", "label")
        return self._document_type_ids

    async def index_template_id(self) -> int:
        response = await self.get("/index_templates/?page_size=100")
        response.raise_for_status()
        for result in response.json()["results"]:
            if result["slug"] == "customer-archive":
                return result["id"]
        raise RuntimeError("index template not found: customer-archive")

    # ------------------------------------------------------------------
    # Documents
    # ------------------------------------------------------------------

    async def list_documents(self, page: int, page_size: int) -> dict[str, Any]:
        response = await self.get(f"/documents/?page={page}&page_size={page_size}")
        response.raise_for_status()
        return response.json()

    async def get_document(self, document_id: int) -> dict[str, Any]:
        response = await self.get(f"/documents/{document_id}/")
        response.raise_for_status()
        return response.json()

    async def get_document_metadata(self, document_id: int) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        path: str | None = f"/documents/{document_id}/metadata/?page_size=100"
        while path:
            response = await self.get(self.relative_path(path))
            response.raise_for_status()
            data = response.json()
            entries.extend(data["results"])
            path = data.get("next")
        return entries

    async def create_document(self, document_type_id: int, label: str) -> dict[str, Any]:
        response = await self.post(
            "/documents/",
            json={"document_type_id": document_type_id, "label": label},
        )
        response.raise_for_status()
        return response.json()

    async def upload_file(self, document_id: int, filename: str, content: bytes) -> None:
        response = await self.post(
            f"/documents/{document_id}/files/",
            data={"action_name": "replace"},
            files={"file_new": (filename, content)},
        )
        response.raise_for_status()

    async def attach_metadata(self, document_id: int, metadata_type_id: int, value: str) -> None:
        response = await self.post(
            f"/documents/{document_id}/metadata/",
            json={"metadata_type_id": metadata_type_id, "value": value},
        )
        response.raise_for_status()

    async def update_metadata_entry(self, document_id: int, metadata_entry_id: int, value: str) -> None:
        response = await self.patch(
            f"/documents/{document_id}/metadata/{metadata_entry_id}/",
            json={"value": value},
        )
        response.raise_for_status()

    async def find_document_by_uuid(self, uuid: str) -> dict[str, Any] | None:
        """Looks up a document by its Mayan-assigned UUID (a document field,
        not any of our metadata types). Uses Mayan's real search backend,
        not the plain /documents/ list endpoint -- verified directly that a
        `?uuid=` query param there is silently ignored (count unchanged
        with/without it), while this search-model endpoint's `uuid` field
        is a genuine exact-match filter."""
        response = await self.get("/search/documents.documentsearchresult/", params={"uuid": uuid})
        response.raise_for_status()
        results = response.json()["results"]
        return results[0] if results else None

    async def delete_document(self, document_id: int) -> tuple[bool, str | None]:
        try:
            response = await self.delete(f"/documents/{document_id}/")
            response.raise_for_status()
            return True, None
        except httpx.HTTPStatusError as exc:
            return False, f"HTTP {exc.response.status_code}"

    async def rebuild_index(self) -> None:
        index_id = await self.index_template_id()
        response = await self.post(f"/index_templates/{index_id}/rebuild/")
        response.raise_for_status()


mayan_client = MayanClient()

import secrets
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

from .mayan_client import mayan_client
from .routers.documents import router as documents_router

SESSION_COOKIE = "webapp_session"


class SessionCookieMiddleware(BaseHTTPMiddleware):
    """Stamps every request with an opaque per-browser session id
    (request.state.session_id), used only to key bulk-selection state
    (selection_store.py) — not an auth token, no login involved. Setting
    the cookie has to happen here rather than via a route dependency
    because our routes return their own TemplateResponse/StreamingResponse
    objects rather than the FastAPI-managed one a dependency would see."""

    async def dispatch(self, request: Request, call_next):
        session_id = request.cookies.get(SESSION_COOKIE)
        is_new = session_id is None
        if is_new:
            session_id = secrets.token_urlsafe(16)
        request.state.session_id = session_id
        response = await call_next(request)
        if is_new:
            response.set_cookie(SESSION_COOKIE, session_id, httponly=True, samesite="lax", max_age=60 * 60 * 24 * 30)
        return response


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    await mayan_client.aclose()


app = FastAPI(title="Customer Archive", lifespan=lifespan)
app.add_middleware(SessionCookieMiddleware)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
app.include_router(documents_router)

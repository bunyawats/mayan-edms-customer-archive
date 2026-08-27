from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from .mayan_client import mayan_client
from .routers.documents import router as documents_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    await mayan_client.aclose()


app = FastAPI(title="Customer Archive", lifespan=lifespan)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
app.include_router(documents_router)

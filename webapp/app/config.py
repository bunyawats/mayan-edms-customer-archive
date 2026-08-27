from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    mayan_url: str = "http://localhost:8000"
    mayan_user: str = "admin"
    mayan_password: str = "changeme"
    page_size: int = 10
    bulk_delete_max: int = 100


settings = Settings()

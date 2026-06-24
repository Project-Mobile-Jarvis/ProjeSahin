"""SQLAlchemy engine + session. DATABASE_URL config'ten (env) gelir."""
from collections.abc import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, declarative_base, sessionmaker

from core.config import settings

# pool_pre_ping: kopmuş bağlantıları otomatik tespit edip yeniler (Railway/uzak DB için iyi)
engine = create_engine(settings.DATABASE_URL, pool_pre_ping=True, future=True)

SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)

# Tüm ORM modellerinin ortak temel sınıfı (db/models.py bunu kullanır)
Base = declarative_base()


def get_db() -> Generator[Session, None, None]:
    """FastAPI dependency: istek başına DB oturumu açar/kapatır."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

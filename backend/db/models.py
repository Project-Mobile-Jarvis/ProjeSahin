"""ORM modelleri (SPEC 4.1). Tek kullanıcılık asistan → sabit user_id, auth yok."""
from datetime import datetime

from sqlalchemy import DateTime, Float, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from db.database import Base

DEFAULT_USER = "furkan"


class Conversation(Base):
    """Session bazlı konuşma geçmişi (oturumlar/restart arası kalıcı)."""

    __tablename__ = "conversations"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[str] = mapped_column(String(64), default=DEFAULT_USER, index=True)
    session_id: Mapped[str] = mapped_column(String(128), index=True)
    role: Mapped[str] = mapped_column(String(16))  # "user" | "model"
    content: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class SavedLocation(Base):
    """Kalıcı kişisel konumlar (ev, iş, ...). Faz 4'te doldurulur."""

    __tablename__ = "saved_locations"
    __table_args__ = (
        UniqueConstraint("user_id", "label", name="uq_saved_locations_user_label"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[str] = mapped_column(String(64), default=DEFAULT_USER, index=True)
    label: Mapped[str] = mapped_column(String(64))
    lat: Mapped[float] = mapped_column(Float)
    lng: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class Preference(Base):
    """Kalıcı tercihler (key/value). Faz 4'te doldurulur."""

    __tablename__ = "preferences"
    __table_args__ = (
        UniqueConstraint("user_id", "key", name="uq_preferences_user_key"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[str] = mapped_column(String(64), default=DEFAULT_USER, index=True)
    key: Mapped[str] = mapped_column(String(128))
    value: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

"""Konuşma hafızası — kalıcı DB (SPEC 4.1). Oturumlar/restart arası kalıcı."""
from sqlalchemy import select
from sqlalchemy.orm import Session

from db.models import DEFAULT_USER, Conversation

# Gemini'ye gönderilecek son kaç tur (kullanıcı+model) tutulsun.
# Token tasarrufu: 20→8 (son ~4 konuşma; sesli asistanda derin geri-referans nadir).
HISTORY_LIMIT = 8


def load_history(
    db: Session, session_id: str, user_id: str = DEFAULT_USER, limit: int = HISTORY_LIMIT
) -> list[dict[str, str]]:
    """Bir session'ın son turlarını kronolojik sırada döner: [{role, content}, ...]."""
    stmt = (
        select(Conversation)
        .where(Conversation.session_id == session_id, Conversation.user_id == user_id)
        .order_by(Conversation.id.desc())
        .limit(limit)
    )
    rows = list(db.execute(stmt).scalars().all())
    rows.reverse()  # en eskiden en yeniye
    return [{"role": r.role, "content": r.content} for r in rows]


def save_turn(
    db: Session, session_id: str, role: str, content: str, user_id: str = DEFAULT_USER
) -> None:
    """Tek bir konuşma turunu DB'ye yazar (role: 'user' | 'model')."""
    db.add(
        Conversation(
            session_id=session_id, role=role, content=content, user_id=user_id
        )
    )
    db.commit()

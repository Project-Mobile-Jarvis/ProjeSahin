"""Faz 0 dumanı testi: /health 200 döner ve beklenen alanları içerir.

DB ayakta olmasa bile geçer (status 'degraded' olabilir) — bu test yapıyı doğrular,
canlı DB doğrulaması ayrı adımda (docker compose + curl) yapılır.
"""
from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_health_returns_200():
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] in ("ok", "degraded")
    assert "db" in body

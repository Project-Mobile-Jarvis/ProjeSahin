"""Faz 0 dumanı testi: /health.

DB ayaktayken 200 + {status:ok, db:ok}; DB yokken 503 (Railway 'hazır değil' saysın).
Test her iki durumu da kabul eder, böylece DB'siz ortamda flaky olmaz.
"""
from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_health():
    resp = client.get("/health")
    assert resp.status_code in (200, 503)
    if resp.status_code == 200:
        body = resp.json()
        assert body["status"] == "ok"
        assert body["db"] == "ok"

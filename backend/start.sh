#!/usr/bin/env bash
# Railway başlangıç betiği: DB hazır olana kadar migration'ı dener, sonra uvicorn'u çalıştırır.
# (Cold-start'ta Managed Postgres birkaç saniye gecikebilir → restart loop'a girmeyelim.)
set -u

ok=0
for i in $(seq 1 30); do
  if alembic upgrade head; then
    ok=1
    break
  fi
  echo "DB henüz hazır değil, 2 sn sonra tekrar denenecek ($i/30)..."
  sleep 2
done

if [ "$ok" != "1" ]; then
  echo "HATA: 'alembic upgrade head' başarısız (DB'ye ulaşılamadı)." >&2
  exit 1
fi

exec uvicorn main:app --host 0.0.0.0 --port "${PORT:-8000}"

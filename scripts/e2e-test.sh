#!/usr/bin/env bash
# Uji end-to-end CompreFace melalui compreface-fe (TEST_PLAN TC-E2E-*).
#
#   scripts/e2e-test.sh [BASE_URL]        (default http://127.0.0.1:8000)
#
# Alur: UI terbuka → register & login admin → buat aplikasi → buat face collection
# (model RECOGNITION) → upload wajah via /api/v1 → recognition → uji latensi (N request).
# Gambar uji: fixture publik upstream embedding-calculator/sample_images (007_B & 008_B = orang
# yang sama, 009_C = orang berbeda). JANGAN gunakan data wajah nasabah untuk uji ini.
#
# Env: E2E_EMAIL, E2E_PASSWORD — akun yang boleh membuat aplikasi (OWNER = user pertama yang
#      register pada DB kosong, atau global ADMIN). Default: akun baru acak → hanya berhasil pada
#      DB kosong. LATENCY_N (default 20), CLEANUP=true (hapus subject uji di akhir).
set -euo pipefail

BASE="${1:-http://127.0.0.1:8000}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="$ROOT/embedding-calculator/sample_images"
EMAIL="${E2E_EMAIL:-e2e.$(date +%s)@example.internal}"
PASSWORD="${E2E_PASSWORD:-E2e-$(openssl rand -hex 8)}"
LATENCY_N="${LATENCY_N:-20}"
# OAuth client publik SPA (di-compile di ui/src/environments/environment.prod.ts) — bukan secret.
CLIENT_BASIC="CommonClientId:password"
PASS=0; FAIL=0

step() { printf '\n=== %s\n' "$*"; }
ok()   { echo "PASS: $*"; PASS=$((PASS + 1)); }
ko()   { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

step "TC-E2E-01 UI terbuka"
code=$(curl -s -o /tmp/e2e-index.$$ -w '%{http_code}' "$BASE/")
if [[ "$code" == 200 ]] && grep -qi '<app-root' /tmp/e2e-index.$$; then ok "GET / = 200 (Angular SPA)"; else ko "GET / = $code"; fi
rm -f /tmp/e2e-index.$$

step "TC-E2E-02 Register & login admin"
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"firstName\":\"E2E\",\"lastName\":\"Test\",\"isAllowStatistics\":false}" \
  "$BASE/admin/user/register")
if [[ "$code" == 201 || "$code" == 200 ]]; then ok "register $EMAIL ($code)"
elif [[ -n "${E2E_EMAIL:-}" ]]; then echo "INFO: register $code — akun $EMAIL sudah ada, lanjut login"
else ko "register = $code"; fi
# admin mengembalikan token sebagai cookie (CustomTokenEndpoint) — dipakai lewat cookie jar,
# sama seperti browser.
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
TOKEN=$(curl -s -c "$JAR" -u "$CLIENT_BASIC" -d "grant_type=password&username=$EMAIL&password=$PASSWORD" \
  "$BASE/admin/oauth/token" | json "d['access_token']")
[[ -n "$TOKEN" ]] && ok "login → access_token (cookie) diterima" || { ko "login"; exit 1; }
AUTH=(-b "$JAR" -H 'Content-Type: application/json')

step "TC-E2E-03 Buat aplikasi & face collection"
SUFFIX="$(date +%s)"
resp=$(curl -s "${AUTH[@]}" -d "{\"name\":\"e2e-app-$SUFFIX\"}" "$BASE/admin/app")
APP_ID=$(echo "$resp" | json "d.get('id','')")
[[ -n "$APP_ID" ]] && ok "aplikasi dibuat id=$APP_ID" || { ko "buat aplikasi: $resp (akun harus OWNER/ADMIN)"; exit 1; }
API_KEY=$(curl -s "${AUTH[@]}" -d "{\"name\":\"e2e-collection-$SUFFIX\",\"type\":\"RECOGNITION\"}" \
  "$BASE/admin/app/$APP_ID/model" | json "d['apiKey']")
[[ -n "$API_KEY" ]] && ok "face collection dibuat (api key diterima)" || { ko "buat collection"; exit 1; }

step "TC-E2E-04 Upload wajah via API"
resp=$(curl -s -H "x-api-key: $API_KEY" -F "file=@$IMG/007_B.jpg" "$BASE/api/v1/recognition/faces?subject=person_b")
echo "$resp"
echo "$resp" | json "d['subject']" | grep -q person_b && ok "wajah person_b tersimpan" || ko "upload wajah"

step "TC-E2E-05 Recognition (orang sama, foto berbeda)"
resp=$(curl -s -H "x-api-key: $API_KEY" -F "file=@$IMG/008_B.jpg" "$BASE/api/v1/recognition/recognize?limit=1&prediction_count=1")
echo "$resp" | python3 -m json.tool | head -30
sim=$(echo "$resp" | json "d['result'][0]['subjects'][0]['similarity'] if d['result'][0]['subjects'][0]['subject']=='person_b' else 0")
python3 -c "import sys; sys.exit(0 if float('$sim') >= 0.8 else 1)" \
  && ok "person_b dikenali, similarity=$sim (≥ 0.8)" || ko "similarity person_b=$sim (< 0.8)"

step "TC-E2E-06 Recognition orang berbeda (negatif)"
sim_c=$(curl -s -H "x-api-key: $API_KEY" -F "file=@$IMG/009_C.jpg" "$BASE/api/v1/recognition/recognize?limit=1&prediction_count=1" \
  | json "d['result'][0]['subjects'][0]['similarity']")
python3 -c "import sys; sys.exit(0 if float('$sim_c') < float('$sim') else 1)" \
  && ok "orang berbeda similarity=$sim_c (< $sim)" || ko "negatif similarity=$sim_c"

step "TC-E2E-07 Plugin & versi core (dilaporkan api)"
curl -s -H "x-api-key: $API_KEY" -F "file=@$IMG/008_B.jpg" \
  "$BASE/api/v1/recognition/recognize?limit=1&prediction_count=1&face_plugins=age,gender&status=true" \
  | json "d.get('plugins_versions')"

step "NFR-04 Latensi recognition ($LATENCY_N request setelah warm-up, 1 wajah)"
times=()
for _ in $(seq 1 "$LATENCY_N"); do
  t=$(curl -s -o /dev/null -w '%{time_total}' -H "x-api-key: $API_KEY" -F "file=@$IMG/008_B.jpg" \
    "$BASE/api/v1/recognition/recognize?limit=1&prediction_count=1")
  times+=("$t")
done
printf '%s\n' "${times[@]}" | python3 -c "
import sys, statistics as s
t = sorted(float(x) for x in sys.stdin)
p95 = t[max(0, int(round(0.95 * len(t))) - 1)]
print(f'n={len(t)} min={t[0]:.3f}s median={s.median(t):.3f}s p95={p95:.3f}s max={t[-1]:.3f}s')"

if [[ "${CLEANUP:-true}" == true ]]; then
  # Catatan: API upstream meninggalkan baris img (gambar uji) — bersihkan dengan
  # scripts/db-purge-orphan-images.sql (docs/RUNBOOK.md §5.5).
  curl -s -o /dev/null -X DELETE -H "x-api-key: $API_KEY" "$BASE/api/v1/recognition/subjects/person_b" || true
fi

printf '\nRINGKASAN: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

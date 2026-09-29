#!/usr/bin/env bash
# Pemeriksaan konsistensi dokumentasi (TEST_PLAN TC-20, SPEC FR-19/NFR-13).
#   1. Setiap FR/NFR di SPEC.md punya ≥ 1 test case di traceability matrix docs/TEST_PLAN.md
#   2. Setiap env var di k8s (configmap.env, secretKeyRef, literal overlay), docker-compose*.yml
#      dan .env.example tercantum di docs/CONFIGURATION.md
#   3. Setiap link relatif markdown (file + anchor) valid
#   4. Setiap dokumen SDLC memiliki blok metadata + riwayat revisi
# Exit code 0 = semua lulus.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import glob, os, re, sys, unicodedata

root = sys.argv[1]
os.chdir(root)
errors = []

def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

# ---------------------------------------------------------------- 1. FR/NFR ↔ TC
spec = read("SPEC.md")
reqs = sorted(set(re.findall(r"^\| ((?:N?FR)-\d+) \|", spec, re.M)),
              key=lambda r: (r.startswith("NFR"), int(r.split("-")[1])))
tp = read("docs/TEST_PLAN.md")
matrix = dict(re.findall(r"^\| ((?:N?FR)-\d+) \| (TC-[^|]+)\|", tp, re.M))
tcs_defined = set(re.findall(r"^\| (TC-\d+) \|", tp, re.M))
print(f"[1] Requirement di SPEC: {len(reqs)}  |  baris traceability: {len(matrix)}  |  TC terdefinisi: {len(tcs_defined)}")
for r in reqs:
    if r not in matrix:
        errors.append(f"[1] {r} tidak punya test case di traceability matrix")
        continue
    for tc in re.findall(r"TC-\d+", matrix[r]):
        if tc not in tcs_defined:
            errors.append(f"[1] {r} merujuk {tc} yang tidak terdefinisi di tabel test case")
for r in matrix:
    if r not in reqs:
        errors.append(f"[1] {r} ada di matriks tetapi tidak ada di SPEC")

# ---------------------------------------------------------------- 2. env var ↔ CONFIGURATION
env = {}
def add(name, src):
    env.setdefault(name, set()).add(src)
for f in glob.glob("k8s/**/configmap.env", recursive=True):
    for line in read(f).splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*)=", line)
        if m: add(m.group(1), f)
for f in glob.glob("k8s/**/*.yaml", recursive=True):
    txt = read(f)
    for m in re.finditer(r"^\s+- name: ([A-Z][A-Z0-9_]*)\s*$", txt, re.M): add(m.group(1), f)
    for m in re.finditer(r"^\s+key: ([A-Z][A-Z0-9_]*)\s*$", txt, re.M): add(m.group(1), f)
    for m in re.finditer(r"^\s+- ([A-Z][A-Z0-9_]*)=", txt, re.M): add(m.group(1), f)
for f in glob.glob("docker-compose*.yml"):
    for m in re.finditer(r"^\s{6}([A-Z][A-Z0-9_]*):", read(f), re.M): add(m.group(1), f)
    for m in re.finditer(r"\$\{([A-Z][A-Z0-9_]*)", read(f)): add(m.group(1), f)
for line in read(".env.example").splitlines():
    m = re.match(r"^([A-Z][A-Z0-9_]*)=", line)
    if m: add(m.group(1), ".env.example")
conf = read("docs/CONFIGURATION.md")
missing = sorted(n for n in env if not re.search(r"(?<![A-Z0-9_])" + n + r"(?![A-Z0-9_])", conf))
print(f"[2] Env var unik di manifest/compose/.env.example: {len(env)}  |  tidak terdokumentasi: {len(missing)}")
for n in missing:
    errors.append(f"[2] env var {n} ({', '.join(sorted(env[n]))}) tidak ada di docs/CONFIGURATION.md")

# ---------------------------------------------------------------- 3. link relatif
def slugify(h):
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", h)          # link → teks
    h = h.strip().lower()
    out = []
    for ch in h:
        cat = unicodedata.category(ch)
        if ch in "-_ " or cat[0] in "LN":
            out.append(ch)
    return "".join(out).replace(" ", "-")

def anchors(path):
    txt = re.sub(r"```.*?```", "", read(path), flags=re.S)
    seen, res = {}, set()
    for m in re.finditer(r"^#{1,6}\s+(.+?)\s*#*\s*$", txt, re.M):
        s = slugify(m.group(1))
        n = seen.get(s, 0)
        res.add(s if n == 0 else f"{s}-{n}")
        seen[s] = n + 1
    return res

md_files = [p for p in glob.glob("**/*.md", recursive=True)
            if not p.startswith(("ui/node_modules", "java/", "ui/", "embedding-calculator/", "load-tests/", ".github/"))]
nlinks = 0
cache = {}
for f in sorted(md_files):
    txt = re.sub(r"```.*?```", "", read(f), flags=re.S)
    txt = re.sub(r"`[^`\n]*`", "", txt)
    for m in re.finditer(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)", txt):
        target = m.group(1)
        if re.match(r"^[a-z]+:", target) or target.startswith("//"):
            continue
        nlinks += 1
        path, _, frag = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        if path.startswith("/"):
            dest = os.path.normpath(path.lstrip("/"))
        if not os.path.exists(dest):
            errors.append(f"[3] {f}: link rusak → {target}")
            continue
        if frag and dest.endswith(".md"):
            if dest not in cache: cache[dest] = anchors(dest)
            if frag not in cache[dest]:
                errors.append(f"[3] {f}: anchor tidak ada → {target}")
print(f"[3] File markdown diperiksa: {len(md_files)}  |  link relatif: {nlinks}")

# ---------------------------------------------------------------- 4. metadata
sdlc = ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SPEC.md"] + sorted(glob.glob("docs/*.md")) \
     + sorted(glob.glob("docs/adr/*.md")) + sorted(glob.glob("services/*/README.md"))
need = [r"\| Judul \|", r"\| Versi", r"\| Tanggal \|", r"\| Owner \|", r"\| Status \|",
        r"\| Versi \| Tanggal \| Penulis \| Perubahan \|"]
for f in sdlc:
    head = "\n".join(read(f).splitlines()[:30])
    for pat in need:
        if not re.search(pat, head):
            errors.append(f"[4] {f}: metadata/riwayat revisi tidak lengkap ({pat})")
print(f"[4] Dokumen SDLC diperiksa metadata: {len(sdlc)}")

print()
if errors:
    print(f"GAGAL: {len(errors)} masalah")
    for e in errors: print("  -", e)
    sys.exit(1)
print("LULUS: semua pemeriksaan konsistensi dokumentasi")
PY

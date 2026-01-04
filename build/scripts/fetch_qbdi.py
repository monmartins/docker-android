#!/usr/bin/env python3
import json
import os
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

# Usage: fetch_qbdi.py <tag> <out_dir>
# Ex: fetch_qbdi.py v0.12.0 /opt/qbdi

TAG = sys.argv[1] if len(sys.argv) > 1 else "v0.12.0"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/opt/qbdi")

api = f"https://api.github.com/repos/QBDI/QBDI/releases/tags/{TAG}"

# default pattern assets
rx = re.compile(r"(android).*?(x86_64|X86_64).*?\.(tar\.gz|tgz|tar\.xz|zip)$")

def download(url: str, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as r, open(dst, "wb") as f:
        f.write(r.read())

def main():
    OUT.mkdir(parents=True, exist_ok=True)

    with urllib.request.urlopen(api) as r:
        data = json.loads(r.read().decode("utf-8"))

    assets = data.get("assets", [])
    pick = None
    for a in assets:
        name = a.get("name", "")
        if rx.search(name):
            pick = a
            break

    if not pick:
        # fallback: find "android" and "x86_64"
        for a in assets:
            name = a.get("name", "").lower()
            if "android" in name and "x86_64" in name:
                pick = a
                break

    if not pick:
        raise SystemExit(f"Não achei asset android x86_64 no release {TAG}. Assets: {len(assets)}")

    url = pick["browser_download_url"]
    name = pick["name"]
    tmp = Path("/tmp") / name
    print(f"[fetch_qbdi] baixando {name}")
    download(url, tmp)

    # extrai
    print(f"[fetch_qbdi] extraindo para {OUT}")
    if name.endswith((".tar.gz", ".tgz")):
        with tarfile.open(tmp, "r:gz") as t:
            t.extractall(OUT)
    elif name.endswith(".tar.xz"):
        with tarfile.open(tmp, "r:xz") as t:
            t.extractall(OUT)
    elif name.endswith(".zip"):
        import zipfile
        with zipfile.ZipFile(tmp) as z:
            z.extractall(OUT)
    else:
        raise SystemExit(f"Formato não suportado: {name}")

    tmp.unlink(missing_ok=True)

if __name__ == "__main__":
    main()

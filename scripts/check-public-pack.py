#!/usr/bin/env python3
"""Checks the published packs the way the app reads them (ADR-017): anonymous HTTPS GETs of the public bucket.

    python3 scripts/check-public-pack.py <base-url> [--max-age-min 360]

<base-url> is the bucket root the app uses (STARINDEX_PACK_BASE_URL), e.g.
https://br-xxx.storage.c-1.ap-southeast-1.aws.neon.tech/starindex-packs. Exit 0 when the manifest and the index pack
it points at are readable without credentials, the pack's sha256 and size match the manifest, the gzip holds a schema
2 index pack, the manifest keeps the short Cache-Control and no Content-Encoding is set on the pack (the app hashes
the compressed bytes), and the pack's issue is younger than --max-age-min (two missed 단기예보 issues = 360).
"""
import argparse
import datetime as dt
import gzip
import hashlib
import json
import sys
import urllib.request


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "starindex-check/1", "Accept-Encoding": "identity"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read(), {k.lower(): v for k, v in r.headers.items()}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("base")
    p.add_argument("--max-age-min", type=float, default=360)
    a = p.parse_args()
    base = a.base.rstrip("/")
    problems = []

    raw, h = get(base + "/packs/manifest/latest.json")
    manifest = json.loads(raw)
    cc = h.get("cache-control", "")
    if "max-age=60" not in cc:
        problems.append(f"manifest Cache-Control is {cc!r}, expected max-age=60")
    entry = (manifest.get("packs") or {}).get("index")
    if not entry:
        print("manifest has no index pack yet", file=sys.stderr)
        return 1
    path = entry["path"]
    if path.startswith("/") or ".." in path or not path.startswith("packs/index/"):
        problems.append(f"unexpected pack path {path!r}")
    gz, ph = get(base + "/" + path)
    if ph.get("content-encoding"):
        problems.append(f"pack has Content-Encoding {ph['content-encoding']!r}: clients would get different bytes")
    if hashlib.sha256(gz).hexdigest() != entry["sha256"]:
        problems.append("pack sha256 differs from the manifest")
    if len(gz) != entry["bytes"]:
        problems.append(f"pack is {len(gz)} B, manifest says {entry['bytes']}")
    pack = json.loads(gzip.decompress(gz))
    if pack.get("schema") != 2 or pack.get("version") != entry["version"]:
        problems.append(f"pack schema/version {pack.get('schema')}/{pack.get('version')} vs manifest {entry['version']}")
    regions = pack.get("regions") or []
    scored = sum(1 for r in regions if r.get("score") is not None)

    issued = entry.get("issuedAt") or manifest.get("generatedAt")
    age = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(issued)).total_seconds() / 60
    if age > a.max_age_min:
        problems.append(f"index issued {age:.0f} min ago (> {a.max_age_min:.0f}): the ETL has missed issues")

    print(f"manifest {manifest.get('generatedAt')} → {entry['version']} night {entry.get('nightDate')}, issued {issued} "
          f"({age:.0f} min ago), {len(gz)} B, {len(regions)} regions, {scored} scored")
    for x in problems:
        print("PROBLEM:", x, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

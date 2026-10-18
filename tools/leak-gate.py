#!/usr/bin/env python3
"""
leak-gate.py — fail-closed depersonalization gate for the vendored Nomad source.

Runs at BUILD time (fetch-vendor-mac.sh / fetch-vendor.ps1) AFTER the export-filter
has stripped internal dev artifacts. Scans the tree for HARD deanonymizing markers
that must never ship inside the installer dmg/exe: the maintainer's identity, private
infra (server IPs, internal domains, local machine paths), internal project IDs, and
plaintext secret shapes.

Deliberately NARROW (unlike the full ~248-pattern leak_scan): it must NOT flag
legitimate upstream content (RTX-4090 in ML docs, "Ceresit"/"Zapier" in design
templates, "Moscow"/"Bitrix"/"amoCRM" as platform integrations, generic docker/gateway
terms). A gate that cries wolf on upstream text would make every build fail and get
disabled — so it only matches identity/infra/secret leaks that are unambiguously ours.

Usage:  python leak-gate.py <dir> [--allow SUBSTR ...]
Exit:   0 = clean, 1 = hard-deanon markers found (build MUST stop).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Windows consoles default to cp1251 → printing a snippet with '→'/Cyrillic crashes the
# gate mid-report (UnicodeEncodeError) and it silently looks "clean-ish". Force UTF-8.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ap = argparse.ArgumentParser(description="Fail-closed deanon gate for vendored Nomad source")
ap.add_argument("target", help="directory to scan")
ap.add_argument("--allow", action="append", default=[], help="extra allowlist substring (repeatable, case-insensitive)")
ap.add_argument("--max-bytes", type=int, default=6_000_000, help="skip files larger than this (built minified blobs are handled separately)")
args = ap.parse_args()
ROOT = Path(args.target)

# Intended-to-ship tokens that must NEVER be treated as a leak.
ALLOW = [a.lower() for a in (args.allow + [
    "cp.nomadnet.ai", "nomadnet.ai", "nomadnet",   # the friend-facing cloud endpoint
    "203.0.113.",                                   # RFC 5737 TEST-NET example IPs (scrubbed placeholders)
    "example.com", "alice",
])]

# HARD deanon only. (name, compiled-regex). Case-insensitive except where identity
# demands exactness. Keep this list tight and auditable.
PATTERNS: list[tuple[str, re.Pattern]] = [
    # ── Maintainer identity ──
    # NOTE: the plain product/plugin name "hamidun" (memory provider `hamidun`,
    # `hamidun-billing`, plugins/memory/hamidun/, license headers "hamidun-agent",
    # the product site hamidun.com) is the Nomad product's own brand lineage baked
    # into functional identifiers — renaming it is a SOURCE refactor, not an install
    # concern, and it isn't private data. We gate on PERSONAL identity + private infra,
    # not the product name. (Owner may still choose to rebrand hamidun→nomad upstream.)
    ("name:zhemal",      re.compile(r"\bzhemal\b", re.I)),
    ("name:khamidun",    re.compile(r"\bkhamidun\b", re.I)),
    ("name:жемал",       re.compile(r"жемал", re.I)),
    ("name:хамидун",     re.compile(r"хамидун", re.I)),
    ("handle:jhamidun",  re.compile(r"\bjhamidun\b", re.I)),   # @JHamidun handle / login
    ("email:hamidunjemal", re.compile(r"hamidunjemal", re.I)),
    ("email:j.hamidun",  re.compile(r"j\.hamidun@", re.I)),
    # ── Private infra ──
    ("ip:vertex",        re.compile(r"\b95\.179\.242\.167\b")),
    ("ip:server2",       re.compile(r"\b45\.76\.89\.111\b")),
    ("domain:transform-ai", re.compile(r"transform-ai\.online", re.I)),
    ("domain:telohudelo", re.compile(r"telohudelo", re.I)),
    ("domain:alpinadigital", re.compile(r"alpinadigital", re.I)),
    ("domain:alpinabook", re.compile(r"alpinabook", re.I)),
    # ── Local machine paths (leak the OS username / build box) ──
    ("path:win_hamid",   re.compile(r"[cC]:[\\/]+Users[\\/]+hamid", re.I)),
    ("path:nix_hamid",   re.compile(r"/(?:home|c/Users)/hamid\b", re.I)),
    # ── Internal project IDs ──
    ("proj:vibecode",    re.compile(r"\bvibecode\b", re.I)),
    ("proj:alpinagpt",   re.compile(r"\balpinagpt\b", re.I)),
    ("proj:ai-news-bot", re.compile(r"\bai-news-bot\b", re.I)),
    ("proj:ideara",      re.compile(r"\bideara\b", re.I)),
    ("brand:готовим-ии", re.compile(r"Готовим\s+ИИшницу", re.I)),
    # ── Personal Brazil documents ──
    ("doc:crnm",         re.compile(r"\bB429318I\b")),
    ("doc:cpf1",         re.compile(r"006\.?379\.?684")),
    ("doc:cpf2",         re.compile(r"006\.?379\.?604")),
    # ── Plaintext secret shapes ──
    # min length tuned to skip obvious doctest placeholders (e.g. "sk-proj-abcdef1234567890")
    ("secret:anthropic", re.compile(r"sk-ant-[0-9A-Za-z_-]{24,}")),
    ("secret:openai",    re.compile(r"sk-proj-[0-9A-Za-z_-]{24,}")),
    ("secret:github",    re.compile(r"ghp_[0-9A-Za-z]{30,}")),
    ("secret:slack",     re.compile(r"xox[bap]-[0-9A-Za-z-]{10,}")),
    ("secret:notion",    re.compile(r"\bntn_[0-9A-Za-z]{20,}")),
    ("secret:perplexity", re.compile(r"\bpplx-[0-9A-Za-z]{20,}")),
    ("secret:figma",     re.compile(r"\bfigd_[0-9A-Za-z_-]{20,}")),
    ("secret:google",    re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("secret:tg-bot",    re.compile(r"\b\d{8,10}:AA[0-9A-Za-z_-]{33}\b")),
]

# Never scan these (binary / vendored blobs where a match is meaningless or huge).
SKIP_SUFFIX = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".icns", ".webp", ".svg",
    ".woff", ".woff2", ".ttf", ".otf", ".eot",
    ".zip", ".gz", ".tar", ".whl", ".so", ".dylib", ".dll", ".pyc",
    ".mp3", ".mp4", ".wav", ".pdf", ".lock",
}

def scrub_allowed(line: str) -> str:
    low = line.lower()
    for a in ALLOW:
        idx = low.find(a)
        while idx != -1:
            line = line[:idx] + (" " * len(a)) + line[idx + len(a):]
            low = line.lower()
            idx = low.find(a, idx + len(a))
    return line

hits: list[str] = []
scanned = 0
for p in ROOT.rglob("*"):
    if not p.is_file():
        continue
    if p.suffix.lower() in SKIP_SUFFIX:
        continue
    try:
        if p.stat().st_size > args.max_bytes:
            print(f"  [leak-gate] SKIP (too big, scan separately): {p.relative_to(ROOT)}", file=sys.stderr)
            continue
        text = p.read_text(encoding="utf-8", errors="ignore")
    except (OSError, ValueError):
        continue
    scanned += 1
    for i, raw in enumerate(text.splitlines(), 1):
        line = scrub_allowed(raw)
        for name, pat in PATTERNS:
            if pat.search(line):
                rel = p.relative_to(ROOT)
                snippet = raw.strip()[:160]
                hits.append(f"{rel}:{i}: [{name}] {snippet}")
                break  # one hit per line is enough

if hits:
    print(f"[leak-gate] FAIL — {len(hits)} hard-deanon marker(s) across the vendored source ({scanned} files scanned):")
    for h in hits[:400]:
        print("  " + h)
    if len(hits) > 400:
        print(f"  … and {len(hits) - 400} more")
    print("[leak-gate] The dmg/exe would ship maintainer identity / private infra. Extend the export-filter denylist or scrub these before building.")
    sys.exit(1)

print(f"[leak-gate] OK — no hard-deanon markers in the vendored source ({scanned} files scanned).")
sys.exit(0)

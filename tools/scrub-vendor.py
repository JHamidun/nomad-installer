#!/usr/bin/env python3
"""
scrub-vendor.py — idempotent depersonalization transform for the vendored Nomad source.

Pipeline position (fetch-vendor-mac.sh / fetch-vendor.ps1), right after the
`git archive` extraction and BEFORE checksums/completeness:

  1. --denylist FILE : remove internal dev/test paths (glob per line, `#` = comment)
  2. rewrite PERSONAL-identity tokens to neutral product-facing values
  3. (caller) tools/leak-gate.py — fail-closed verification; build stops on residue

Scope: PERSONAL identity + private infra ONLY (maintainer name/handle/emails,
local machine paths, internal project IDs, private server IPs/domains, doc
placeholder secret-shapes). The product/plugin name "hamidun" (hamidun.com,
hamidun-agent headers, memory provider `hamidun`, hamidun-billing) is the
product's own brand lineage baked into functional identifiers — deliberately
UNTOUCHED here (renaming it is a source refactor, not an install concern, and
leak-gate ignores it too).

Idempotent: every replacement produces text that no rule (and no leak-gate
pattern) matches again, so a second run reports 0 changes.

Usage:  python scrub-vendor.py <dir> [--denylist FILE] [--dry-run]
Exit:   0 = ok (including "nothing to change"), 2 = usage/I-O error.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
from pathlib import Path

# Windows consoles default to cp1251 → Cyrillic in the change-report would crash.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ap = argparse.ArgumentParser(description="Idempotent depersonalization transform for vendor/nomad-src")
ap.add_argument("target", help="directory to transform (vendor/nomad-src)")
ap.add_argument("--denylist", help="glob-per-line file of paths to delete first (export filter)")
ap.add_argument("--dry-run", action="store_true", help="report without writing/deleting")
ap.add_argument("--max-bytes", type=int, default=6_000_000, help="skip files larger than this")
args = ap.parse_args()
ROOT = Path(args.target)
if not ROOT.is_dir():
    print(f"[scrub-vendor] ERROR: not a directory: {ROOT}", file=sys.stderr)
    sys.exit(2)

# ── Replacement rules ──────────────────────────────────────────────────────────
# Ordered: phrase-level rules first (keep prose grammatical), single tokens last.
# (label, compiled-pattern, replacement)
RULES: list[tuple[str, re.Pattern, str]] = [
    # "per Zhemal's 2026-07-05 decision" → the decision stands, the person doesn't ship.
    ("decision-clause",  re.compile(r"per Zhemal'?s\s+\d{4}-\d{2}-\d{2}\s+decision", re.I), "by design"),
    ("decision-paren",   re.compile(r"\(Zhemal(?:'s)?\s+decision\s+\d{4}-\d{2}-\d{2}\)", re.I), "(by design)"),
    ("decision-colon",   re.compile(r"\(Zhemal\s+\d{4}-\d{2}-\d{2}:", re.I), "(By design:"),
    # branding/SOUL.md — maker identity becomes the publishing company (already public product-facing).
    ("soul-created-by",  re.compile(r"created by \*\*Zhemal Khamidun\*\* and published by\s+his company \*\*NomadNet\*\*"), "created and published by **NomadNet**"),
    ("soul-made-by",     re.compile(r"made by Zhemal Khamidun"), "made by NomadNet"),
    ("soul-maker",       re.compile(r"Zhemal\s+Khamidun / NomadNet"), "NomadNet"),
    # nomad_cli/default_soul.py — "created by Zhemal Khamidun and published by NomadNet"
    ("default-soul",     re.compile(r"created by Zhemal Khamidun and "), "created and "),
    # claude2hermes author strings
    ("author-pair",      re.compile(r"Zhemal Khamidun / @JHamidun"), "Nomad Maintainers"),
    # Residual full names, then residual single tokens (incl. Cyrillic inflections).
    ("fullname-lat",     re.compile(r"Zhemal\s+Khamidun", re.I), "NomadNet"),
    ("fullname-cyr",     re.compile(r"Жемал\s+Хамидун[а-яё]*", re.I), "NomadNet"),
    ("name-zhemal",      re.compile(r"\bZhemal\b", re.I), "Nomad"),
    ("name-khamidun",    re.compile(r"\bKhamidun\b", re.I), "Nomad"),
    ("name-жемал",       re.compile(r"Жемал[а-яё]*", re.I), "Nomad"),
    ("name-хамидун",     re.compile(r"Хамидун[а-яё]*", re.I), "Nomad"),
    # GitHub handle / login (repo URLs in banner.py update-check, converter allowlists).
    ("handle-jhamidun",  re.compile(r"\bJHamidun\b", re.I), "nomadnet-ai"),
    # Personal / work emails → neutral maintainer contact.
    ("email-personal",   re.compile(r"hamidunjemal@[A-Za-z0-9.-]+", re.I), "team@nomadnet.ai"),
    ("email-personal2",  re.compile(r"hamidunjemal", re.I), "nomadnet"),
    ("email-work",       re.compile(r"j\.hamidun@[A-Za-z0-9.-]+", re.I), "team@nomadnet.ai"),
    # Local machine paths (leak the OS username / build box). Paths first, then the bare project word.
    ("path-win-home",    re.compile(r"[A-Za-z]:[\\/]{1,2}Users[\\/]{1,2}hamid[^\s\"'\)\]\},;]*", re.I), "~"),
    ("path-win-vibecode", re.compile(r"[A-Za-z]:[\\/]{1,2}Vibecode[^\s\"'\)\]\},;]*", re.I), "<internal>"),
    ("path-nix-home",    re.compile(r"/(?:home|c/Users)/hamid[^\s\"'\)\]\},;]*", re.I), "~"),
    ("proj-vibecode",    re.compile(r"\bVibecode\b", re.I), "internal"),
    # Personal TG channel brand used as a blueprint default → neutral default.
    ("brand-channel",    re.compile(r"Готовим\s+ИИшницу", re.I), "Мой канал"),
    # Private infra → RFC 5737 TEST-NET / example.com (leak-gate allowlists these).
    ("ip-vertex",        re.compile(r"\b95\.179\.242\.167\b"), "203.0.113.10"),
    ("ip-server2",       re.compile(r"\b45\.76\.89\.111\b"), "203.0.113.11"),
    ("domain-transform", re.compile(r"transform-ai\.online", re.I), "example.com"),
    ("domain-telohudelo", re.compile(r"telohudelo", re.I), "example-app"),
    ("domain-alpinadigital", re.compile(r"alpinadigital", re.I), "example-corp"),
    ("domain-alpinabook", re.compile(r"alpinabook", re.I), "example-books"),
    ("proj-alpinagpt",   re.compile(r"\balpinagpt\b", re.I), "corp-assistant"),
    ("proj-ai-news-bot", re.compile(r"\bai-news-bot\b", re.I), "news-pipeline-bot"),
    ("proj-ideara",      re.compile(r"\bideara\b", re.I), "idea-studio"),
    ("doc-crnm",         re.compile(r"\bB429318I\b"), "DOC-EXAMPLE"),
    ("doc-cpf1",         re.compile(r"006\.?379\.?684"), "000.000.000"),
    ("doc-cpf2",         re.compile(r"006\.?379\.?604"), "000.000.000"),
    # Slack doc placeholders (xoxb-your-bot-token-here etc.) — real-token SHAPED,
    # so leak-gate flags them. Shorten to a form no scanner mistakes for a secret.
    # (If a HIGH-ENTROPY token ever lands here, this still neutralizes the shape,
    # but the leak-gate history/README tells the owner to rotate — see P0-2 notes.)
    ("slack-placeholder", re.compile(r"xox([bap])-[0-9A-Za-z-]{10,}"), r"xox\1-EXAMPLE"),
]

# Binary / vendored blobs — never rewrite.
SKIP_SUFFIX = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".icns", ".webp", ".svg",
    ".woff", ".woff2", ".ttf", ".otf", ".eot",
    ".zip", ".gz", ".tar", ".whl", ".so", ".dylib", ".dll", ".pyc",
    ".mp3", ".mp4", ".wav", ".pdf", ".lock",
}


def _rmtree(path: Path) -> None:
    def _onerr(fn, p, exc):  # Windows: clear read-only and retry
        try:
            os.chmod(p, stat.S_IWRITE)
            fn(p)
        except Exception:
            raise
    shutil.rmtree(path, onerror=_onerr)


def apply_denylist(root: Path, denylist_file: Path, dry: bool) -> int:
    """Delete every glob listed in the denylist. Missing matches = fine (idempotent)."""
    if not denylist_file.is_file():
        print(f"[scrub-vendor] ERROR: denylist not found: {denylist_file}", file=sys.stderr)
        sys.exit(2)
    removed = 0
    for raw in denylist_file.read_text(encoding="utf-8").splitlines():
        pat = raw.split("#", 1)[0].strip().rstrip("/")
        if not pat:
            continue
        for hit in sorted(root.glob(pat)):
            if not hit.exists():
                continue  # parent already removed by an earlier glob
            rel = hit.relative_to(root)
            if dry:
                print(f"  [denylist] would remove {rel}")
            else:
                if hit.is_dir() and not hit.is_symlink():
                    _rmtree(hit)
                else:
                    hit.unlink()
                print(f"  [denylist] removed {rel}")
            removed += 1
    print(f"[scrub-vendor] denylist: {removed} path(s) removed")
    return removed


def scrub_tree(root: Path, dry: bool) -> tuple[int, int]:
    files_changed = 0
    total_subs = 0
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.suffix.lower() in SKIP_SUFFIX:
            continue
        try:
            if p.stat().st_size > args.max_bytes:
                continue
            raw = p.read_bytes()
        except OSError:
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue  # binary — leave alone (leak-gate reads errors=ignore and still verifies)
        new = text
        per_file: list[str] = []
        for label, pat, repl in RULES:
            new, n = pat.subn(repl, new)
            if n:
                per_file.append(f"{label}×{n}")
                total_subs += n
        if new != text:
            files_changed += 1
            rel = p.relative_to(root)
            print(f"  [scrub] {rel}: {', '.join(per_file)}")
            if not dry:
                p.write_bytes(new.encode("utf-8"))
    return files_changed, total_subs


if args.denylist:
    apply_denylist(ROOT, Path(args.denylist), args.dry_run)

changed, subs = scrub_tree(ROOT, args.dry_run)
mode = "DRY-RUN — would change" if args.dry_run else "changed"
print(f"[scrub-vendor] OK — {mode} {changed} file(s), {subs} replacement(s).")
sys.exit(0)

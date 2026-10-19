#!/usr/bin/env python3
"""Cross-check a producer's call sites against a consumer's declared routes/commands.

Both ends of a contract are usually written in different shapes:

    producer:  authFetch(`/api/routes/${id}/stats`)     template literal
    consumer:  get "/routes/:route_id/stats"            declared inside scope "/api"

Extract, normalize (``${x}`` and ``:param`` -> ``{id}``), tolerate a prefix that the
consumer's declaration omits, and print what each side has that the other does not.

A diff that claims EVERYTHING is missing means the extractor is wrong (a prefix not
applied, or a pattern that matched nothing) - fix the normalization before reporting a gap.

Usage:
  boundary_crosscheck.py \
    --producer web_app/src/utils/api.js --producer-regex '`(/api[^`]*)`' \
    --consumer lib/app/router.ex \
    --consumer-regex '(get|post|put|patch|delete)\s+"([^"]+)"' \
    --consumer-prefix /api

Repeat --producer/--producer-regex/--consumer/--consumer-regex to check several pairs.
"""
from __future__ import annotations

import argparse
import re
import sys

PARAM = re.compile(r"(\$\{[^}]+\}|:[a-z_][a-z0-9_]*)")


def normalize(text: str) -> str:
    """Path -> comparable key: drop query strings, collapse parameters."""
    text = text.split("?")[0].strip()
    text = PARAM.sub("{id}", text)
    return text.rstrip("/") or "/"


def extract(path: str, pattern: str, group: int = 1) -> set[str]:
    with open(path, encoding="utf-8", errors="replace") as handle:
        blob = handle.read()
    found = set()
    for match in re.finditer(pattern, blob):
        try:
            value = match.group(group)
        except IndexError:
            value = match.group(0)
        if value:
            found.add(normalize(value))
    if not found:
        print(f"WARNING: pattern matched nothing in {path}: {pattern!r}", file=sys.stderr)
    return found


def variants(key: str, prefixes: list[str]) -> set[str]:
    """A declaration inside a scope may omit the prefix the call site carries."""
    out = {key}
    for prefix in prefixes:
        prefix = prefix.rstrip("/")
        if not prefix:
            continue
        out.add(prefix + key if key.startswith("/") else f"{prefix}/{key}")
        if key.startswith(prefix):
            out.add(key[len(prefix):] or "/")
    return out


def report(producer_path, producer_regex, consumer_path, consumer_regex, prefixes):
    calls = extract(producer_path, producer_regex)
    routes = extract(consumer_path, consumer_regex)
    matched = {c for c in calls if variants(c, prefixes) & routes}
    missing = sorted(calls - matched)
    unused = sorted(r for r in routes if not any(variants(c, prefixes) & {r} for c in calls))

    print(f"=== {producer_path} -> {consumer_path}")
    print(f"call sites: {len(calls)}   declared: {len(routes)}   matched: {len(matched)}")
    if calls and len(missing) > len(calls) / 2:
        print("!! most call sites look unmatched: suspect the extractor/prefix, not the code")
    for item in missing:
        print(f"  call with no declaration : {item}")
    for item in unused:
        print(f"  declared but uncalled    : {item}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--producer", action="append", required=True)
    parser.add_argument("--producer-regex", action="append", required=True)
    parser.add_argument("--consumer", action="append", required=True)
    parser.add_argument("--consumer-regex", action="append", required=True)
    parser.add_argument("--consumer-prefix", action="append", default=[])
    parser.add_argument("--consumer-group", type=int, default=1)
    args = parser.parse_args()

    pairs = zip(args.producer, args.producer_regex, args.consumer, args.consumer_regex)
    for producer, producer_re, consumer, consumer_re in pairs:
        report(producer, producer_re, consumer, consumer_re, args.consumer_prefix)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

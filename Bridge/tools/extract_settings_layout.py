#!/usr/bin/env python3
"""Extract desktop OrcaSlicer's settings layout (page -> optgroup -> options)
from the pinned upstream GUI source (src/slic3r/GUI/Tab.cpp) into a committed
client resource, so the Prepare tab mirrors desktop clustering without
hand-maintained page tables.

Inputs : upstream Tab.cpp, the generated config-schema.json (validation).
Output : Sources/OrcaPad/Resources/settings-layout.json

The parser understands the constructs Tab.cpp actually uses:
  add_options_page(L("Title") ...)          -> new page
  page->new_optgroup(L("Title") ...)        -> new group
  append_single_option_line("key" ...)      -> option
  get_option("key")                         -> option (Line/append_option)
  append_option_line(optgroup, "key" ...)   -> option
  std::vector<std::string> NAME{ "k", ...}  + for (... VAR : NAME) -> options
  "prefix_" + axis                          -> schema keys prefix + 1 char
Keys missing from print_config_def (GUI-only legends) are dropped and
reported. Options a preset defines but the layout omits are surfaced by the
client under a trailing "Other" page, so nothing is ever hidden.

--check: extract into memory and fail (exit 1) when the committed output
differs, without writing (used by Bridge/tools/parity-check.py).
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TAB = ROOT / "upstream/orcaslicer/src/slic3r/GUI/Tab.cpp"
SCHEMA = ROOT / "Sources/OrcaPad/Resources/config-schema.json"
OUT = ROOT / "Sources/OrcaPad/Resources/settings-layout.json"

CLASS_TO_KIND = {"TabPrint": "process", "TabFilament": "filament", "TabPrinter": "machine"}

FUNC_DEF = re.compile(r"^[A-Za-z_][\w:<>,\s\*&]*\b(Tab\w+)::(\w+)\s*\(")
PAGE = re.compile(r'add_options_page\(\s*(?:L\("([^"]*)"\)|(\w+))')
GROUP = re.compile(r'new_optgroup\(\s*(?:L\("([^"]*)"\)|"([^"]*)")')
SINGLE = re.compile(r'append_single_option_line\(\s*"([A-Za-z0-9_]+)"')
GET = re.compile(r'get_option\(\s*"([A-Za-z0-9_]+)"')
APPEND_LINE = re.compile(r'append_option_line\(\s*\w+\s*,\s*"([A-Za-z0-9_]+)"\s*[,)]')
PREFIX = re.compile(r'"([A-Za-z0-9_]+_)"\s*\+\s*\w+')
VECTOR_START = re.compile(r'std::vector<std::string>\s+(\w+)\s*=?\s*\{')
QUOTED = re.compile(r'"([A-Za-z0-9_]+)"')
FOR_LOOP = re.compile(r'for\s*\(\s*(?:const\s+)?(?:std::string|auto)\s*&?\s*(\w+)\s*:\s*(\w+)\s*\)')
INLINE_FOR = re.compile(r'for\s*\(.*:\s*\{')
VAR_CALL = re.compile(r'(?:append_option_line\(\s*\w+\s*,\s*|get_option\(\s*|append_retraction_option\(\s*)(\w+)\s*[,)]')


def strip_comment(line: str) -> str:
    in_string = False
    for i, ch in enumerate(line):
        if ch == '"' and (i == 0 or line[i - 1] != "\\"):
            in_string = not in_string
        if not in_string and line.startswith("//", i):
            return line[:i]
    return line


def main() -> int:
    schema = json.loads(SCHEMA.read_text())
    known = {option["key"] for option in schema}

    layout = {kind: [] for kind in CLASS_TO_KIND.values()}
    dropped = set()
    kind = None
    page = None
    group = None
    vectors: dict[str, list[str]] = {}
    loop_vars: dict[str, list[str]] = {}
    collecting_vector = None
    collecting_inline = False

    def ensure_group():
        nonlocal group
        if page is None:
            return None
        if group is None:
            group = {"title": "", "options": []}
            page["groups"].append(group)
        return group

    def add(key: str):
        target = ensure_group()
        if target is None:
            return
        if key not in known:
            dropped.add(key)
            return
        if key not in target["options"]:
            target["options"].append(key)

    for raw in TAB.read_text().splitlines():
        definition = FUNC_DEF.match(raw)
        if definition:
            cls = definition.group(1)
            kind = CLASS_TO_KIND.get(cls)
            page = None
            group = None
            vectors.clear()
            loop_vars.clear()
            collecting_vector = None
            collecting_inline = False
            continue
        if kind is None:
            continue
        line = strip_comment(raw)
        if not line.strip():
            continue

        # for (const std::string key : { "a", "b", ... }) call(key, ...);
        if collecting_inline:
            for key in QUOTED.findall(line):
                add(key)
            if "}" in line:
                collecting_inline = False
            continue
        inline_for = INLINE_FOR.search(line)
        if inline_for:
            rest = line[inline_for.end():]
            for key in QUOTED.findall(rest):
                add(key)
            if "}" not in rest:
                collecting_inline = True
            continue

        if collecting_vector is not None:
            vectors[collecting_vector].extend(QUOTED.findall(line))
            if "}" in line:
                collecting_vector = None
            continue
        vector = VECTOR_START.search(line)
        if vector:
            name = vector.group(1)
            rest = line[vector.end():]
            vectors[name] = QUOTED.findall(rest)
            if "}" not in rest:
                collecting_vector = name
            continue

        page_match = PAGE.search(line)
        if page_match:
            title = page_match.group(1) or "Extruder"
            page = {"page": title, "groups": []}
            layout[kind].append(page)
            group = None
            continue
        group_match = GROUP.search(line)
        if group_match:
            title = group_match.group(1) if group_match.group(1) is not None else group_match.group(2)
            group = {"title": title or "", "options": []}
            if page is not None:
                page["groups"].append(group)
            continue

        loop = FOR_LOOP.search(line)
        if loop and loop.group(2) in vectors:
            loop_vars[loop.group(1)] = vectors[loop.group(2)]

        for key in SINGLE.findall(line) + GET.findall(line) + APPEND_LINE.findall(line):
            add(key)
        for prefix in PREFIX.findall(line):
            for key in sorted(k for k in known if k.startswith(prefix) and len(k) == len(prefix) + 1):
                add(key)
        for var in VAR_CALL.findall(line):
            for key in loop_vars.get(var, []):
                add(key)

    # Drop empty groups/pages; collapse duplicate page titles per kind.
    for kind_name, pages in layout.items():
        merged = []
        for page_entry in pages:
            page_entry["groups"] = [g for g in page_entry["groups"] if g["options"]]
            if not page_entry["groups"]:
                continue
            existing = next((p for p in merged if p["page"] == page_entry["page"]), None)
            if existing:
                existing["groups"].extend(page_entry["groups"])
            else:
                merged.append(page_entry)
        layout[kind_name] = merged

    # Call-site ordering: pages built in helper functions appear in the file
    # before/after their call sites. Mirror the desktop build() call order:
    # TabFilament::build calls add_filament_overrides_page() after Cooling
    # (Tab.cpp ~4125); metadata pages (Dependencies, Notes) close each tab.
    def move_after(pages, title, anchor):
        page_entry = next((p for p in pages if p["page"] == title), None)
        anchor_entry = next((p for p in pages if p["page"] == anchor), None)
        if page_entry and anchor_entry:
            pages.remove(page_entry)
            pages.insert(pages.index(anchor_entry) + 1, page_entry)

    move_after(layout["filament"], "Setting Overrides", "Cooling")
    for pages in layout.values():
        for title in ("Dependencies", "Notes"):
            page_entry = next((p for p in pages if p["page"] == title), None)
            if page_entry:
                pages.remove(page_entry)
                pages.append(page_entry)

    counts = {k: sum(len(g["options"]) for p in v for g in p["groups"]) for k, v in layout.items()}
    if min(counts.values()) < 20:
        print(f"FATAL: layout extraction looks broken: {counts}", file=sys.stderr)
        return 1

    rendered = json.dumps({
        "source": "upstream/orcaslicer/src/slic3r/GUI/Tab.cpp (pinned v2.4.2)",
        "layout": layout,
    }, indent=1) + "\n"
    if "--check" in sys.argv[1:]:
        if not OUT.exists() or OUT.read_text() != rendered:
            print(f"FATAL: {OUT.relative_to(ROOT)} is stale vs Tab.cpp; rerun "
                  "Bridge/tools/extract_settings_layout.py", file=sys.stderr)
            return 1
        print(f"layout current: {counts}")
        return 0
    OUT.write_text(rendered)
    print(f"layout ok: {counts}; dropped GUI-only keys: {sorted(dropped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

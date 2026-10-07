#!/usr/bin/env python3
"""OrcaPad desktop-parity checker.

Compares desktop OrcaSlicer's feature surface -- EXTRACTED from the pinned
upstream sources, never hand-listed -- with what OrcaPad implements, as
recorded in Bridge/tools/parity-manifest.toml. Every "implemented" claim in
the manifest carries evidence that is verified against OrcaPad's code on
every run, and PARITY.md is generated from the result.

Desktop surfaces (see EXTRACTORS):
  gizmo     GLGizmosManager::EType               3D editor tools
  toolbar   GLCanvas3D::_init_*toolbar items      canvas toolbars
  menu      MainFrame menu-bar items
  context   GUI_Factories right-click items
  kb        KBShortcutsDialog actions
  slider    IMSlider layer-slider menu items
  plate     PartPlate per-plate icons
  view      libvgcode EViewType                   preview color schemes
  option    libvgcode EOptionType                 preview visibility options
  host      PrintHostType                         print-host integrations
  format    GUI_App FileType                      file types
  pref      PreferencesDialog items
  dialog    GUI dialog/frame classes              backstop for dialog-only features
  settings  Tab.cpp settings pages                via settings-layout.json

Checks (any failure exits 1, nothing is skipped silently):
  * every extractor finds its anchor and at least its minimum item count
  * every desktop item is claimed by exactly one manifest feature
  * every claim names an item that still exists upstream (no orphans)
  * feature records are well-formed for their status
  * every evidence item of a done/partial feature resolves in OrcaPad code
  * manual (non-extracted) features are anchored to an upstream source match
  * the committed settings layout equals a fresh Tab.cpp extraction
  * --check: PARITY.md equals the rendered report

Usage:
  Bridge/tools/parity-check.py              verify, print summary
  Bridge/tools/parity-check.py --write      verify, regenerate PARITY.md
  Bridge/tools/parity-check.py --check      verify, require PARITY.md current
  Bridge/tools/parity-check.py --dump       list extracted desktop items
  Bridge/tools/parity-check.py --unclaimed  print TOML claim stubs for unclaimed items
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = ROOT / "upstream/orcaslicer"
MANIFEST = ROOT / "Bridge/tools/parity-manifest.toml"
REPORT = ROOT / "PARITY.md"
LAYOUT = ROOT / "Sources/OrcaPad/Resources/settings-layout.json"
LAYOUT_TOOL = ROOT / "Bridge/tools/extract_settings_layout.py"
HEADER = ROOT / "Bridge/engine-cxx/orca_bridge.h"


class ExtractionError(Exception):
    """An upstream anchor moved or vanished: the extractor needs updating."""


# --------------------------------------------------------------------------
# C++ source helpers (comment stripping, constant-#if pruning, balanced scans)
# --------------------------------------------------------------------------

def _ident(ch: str) -> bool:
    return ch.isalnum() or ch == "_"


def _literal_end(text: str, i: int) -> int | None:
    """If a string/char literal starts at i, return the index after it."""
    n = len(text)
    ch = text[i]
    if ch == '"':
        # raw string R"delim( ... )delim" (optionally u8R/LR/uR/UR)
        if i > 0 and text[i - 1] == "R" and (i < 2 or not _ident(text[i - 2]) or text[i - 2] in "uUL8"):
            m = re.match(r'"([^()\\\s]{0,16})\(', text[i:])
            if m:
                close = ")" + m.group(1) + '"'
                j = text.find(close, i + m.end())
                if j < 0:
                    raise ExtractionError("unterminated raw string literal")
                return j + len(close)
        j = i + 1
        while j < n and text[j] != '"':
            if text[j] == "\\":
                j += 2
                continue
            if text[j] == "\n":
                return j  # unterminated on this line: tolerate
            j += 1
        return j + 1
    if ch == "'":
        if i > 0 and text[i - 1].isdigit() and i + 1 < n and text[i + 1].isdigit():
            return None  # C++14 digit separator
        j = i + 1
        while j < n and text[j] != "'":
            if text[j] == "\\":
                j += 2
                continue
            if text[j] == "\n":
                return j
            j += 1
        return j + 1
    return None


def strip_comments(text: str) -> str:
    """Remove // and /* */ comments; keep literals and every newline."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            if j < 0:
                break
            i = j
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            if j < 0:
                raise ExtractionError("unterminated block comment")
            out.append("\n" * text.count("\n", i, j))
            i = j + 2
            continue
        end = _literal_end(text, i) if ch in "\"'" else None
        if end is not None:
            out.append(text[i:end])
            i = end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _const_condition(expr: str, defines: dict[str, bool]) -> bool | None:
    expr = expr.strip()
    negate = False
    while expr.startswith("!"):
        negate = not negate
        expr = expr[1:].strip()
    if expr.startswith("(") and expr.endswith(")"):
        expr = expr[1:-1].strip()
    value: bool | None
    if expr in ("0", "1"):
        value = expr == "1"
    elif re.fullmatch(r"\w+", expr) and expr in defines:
        value = defines[expr]
    else:
        return None
    return (not value) if negate else value


def preprocess(text: str) -> str:
    """Strip comments, then blank out #if branches whose condition is a known
    constant (0/1 literals or macros #define'd to 0/1 in the same file).
    Unknown conditions (platform macros) keep every branch: the union of the
    platform variants is the desktop surface. Line numbers are preserved."""
    lines = strip_comments(text).split("\n")
    defines: dict[str, bool] = {}
    for line in lines:
        m = re.match(r"\s*#\s*define\s+(\w+)\s+([01])\s*$", line)
        if m:
            defines[m.group(1)] = m.group(2) == "1"
    out: list[str] = []
    stack: list[dict] = []
    active = True
    for line in lines:
        stripped = line.strip()
        directive = re.match(r"#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)$", stripped)
        if directive:
            kind, rest = directive.group(1), directive.group(2)
            if kind in ("if", "ifdef", "ifndef"):
                value = _const_condition(rest, defines) if kind == "if" else None
                stack.append({"parent": active, "taken": value is True})
                active = active and value is not False
            elif kind == "elif":
                if not stack:
                    raise ExtractionError("#elif without #if")
                frame = stack[-1]
                if frame["taken"]:
                    active = False
                else:
                    value = _const_condition(rest, defines)
                    frame["taken"] = value is True
                    active = frame["parent"] and value is not False
            elif kind == "else":
                if not stack:
                    raise ExtractionError("#else without #if")
                frame = stack[-1]
                active = frame["parent"] and not frame["taken"]
            else:  # endif
                if not stack:
                    raise ExtractionError("#endif without #if")
                active = stack.pop()["parent"]
            out.append("")
            continue
        out.append(line if active else "")
    if stack:
        raise ExtractionError("unbalanced #if")
    return "\n".join(out)


_PAIRS = {"(": ")", "[": "]", "{": "}"}


def balanced_end(text: str, open_index: int) -> int:
    """Index of the bracket matching text[open_index], skipping literals."""
    opener = text[open_index]
    closer = _PAIRS[opener]
    depth = 0
    i = open_index
    n = len(text)
    while i < n:
        ch = text[i]
        end = _literal_end(text, i) if ch in "\"'" else None
        if end is not None:
            i = end
            continue
        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ExtractionError(f"unbalanced {opener!r} at offset {open_index}")


def split_args(text: str, open_paren: int) -> list[str]:
    """Top-level comma-separated arguments of the call opened at open_paren."""
    close = balanced_end(text, open_paren)
    args: list[str] = []
    depth = 0
    start = open_paren + 1
    i = start
    while i < close:
        ch = text[i]
        end = _literal_end(text, i) if ch in "\"'" else None
        if end is not None:
            i = end
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(text[start:i])
            start = i + 1
        i += 1
    tail = text[start:close]
    if tail.strip() or args:
        args.append(tail)
    return args


def function_body(text: str, signature: str) -> tuple[str, int]:
    """Body text and start offset of the first function matching signature."""
    m = re.search(signature, text)
    if not m:
        raise ExtractionError(f"function anchor not found: {signature}")
    brace = text.find("{", m.end())
    if brace < 0:
        raise ExtractionError(f"function body not found: {signature}")
    return text[brace:balanced_end(text, brace) + 1], brace


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


_STRING = r'(?:u8|L|u|U)?"((?:[^"\\\n]|\\.)*)"'
_LABEL_CALL = re.compile(
    r"\b(?:_L|_u8L|L|_CTX|_CTX_utf8|L_CONTEXT)\s*\(\s*(?:L_CONTEXT\s*\(\s*)?" + _STRING
)
_BARE_STRING = re.compile(_STRING)


def _unescape(raw: str) -> str:
    return raw.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", " ").replace("\\t", " ")


def normalize_label(label: str) -> str:
    label = label.replace("&&", "\0").replace("&", "").replace("\0", "&")
    return " ".join(label.split())


def label_of(arg: str, fallback_prefix: str = "") -> str:
    """User-facing label of a call argument: the first localized literal,
    else a bare literal, else the expression itself in braces (so computed
    labels are still surfaced, never dropped)."""
    m = _LABEL_CALL.search(arg)
    if m:
        return normalize_label(_unescape(m.group(1)))
    m = _BARE_STRING.search(arg)
    if m:
        literal = normalize_label(_unescape(m.group(1)))
        return f"{{{fallback_prefix}{literal}}}" if fallback_prefix else literal
    return "{" + fallback_prefix + " ".join(arg.split()) + "}"


_LOCAL_REF = re.compile(r"^\s*(\w+)(?:\s*\[\s*(\d+)\s*\])?\s*$")


def resolve_local_label(text: str, offset: int, arg: str) -> str | None:
    """Resolve `name` / `names[i]` arguments initialised from localized
    literals shortly before the call (`wxString name = _L("...")`,
    `std::vector<wxString> names = {_L("a"), _L("b")}`). Anything else
    (loop variables, ternaries) stays unresolved."""
    ref = _LOCAL_REF.match(arg)
    if not ref:
        return None
    name, index = ref.group(1), int(ref.group(2) or 0)
    window = text[max(0, offset - 4000):offset]
    last = None
    for decl in re.finditer(r"\b" + re.escape(name) + r"\s*(?:=(?!=)\s*\{?|\{)\s*", window):
        last = decl
    if last is None:
        return None
    initializer = window[last.end():last.end() + 600]
    statement = initializer.split(";", 1)[0]
    ternary = re.match(r"[^?:]*\?\s*([^:]+?)\s*:", statement)
    if ternary and not _LABEL_CALL.match(initializer):
        # `x = cond ? names[0] : names[1]` -> resolve the first branch
        return resolve_local_label(text, offset - (len(window) - last.start()), ternary.group(1))
    labels = []
    cursor = 0
    while True:
        m = _LABEL_CALL.match(initializer, cursor)
        if not m:
            break
        labels.append(normalize_label(_unescape(m.group(1))))
        rest = initializer[balanced_end(initializer, initializer.index("(", m.start())) + 1:]
        sep = re.match(r"\s*,\s*", rest)
        if not sep:
            break
        cursor = len(initializer) - len(rest) + sep.end()
    return labels[index] if index < len(labels) else None


def enum_members(text: str, anchor: str, exclude: set[str]) -> list[tuple[str, int]]:
    m = re.search(anchor, text)
    if not m:
        raise ExtractionError(f"enum anchor not found: {anchor}")
    brace = text.find("{", m.end() - 1)
    end = balanced_end(text, brace)
    body = text[brace + 1:end]
    members = []
    offset = brace + 1
    for part in body.split(","):
        name_match = re.match(r"\s*([A-Za-z_]\w*)", part)
        if name_match and name_match.group(1) not in exclude:
            members.append((name_match.group(1), line_of(text, offset + name_match.start(1))))
        offset += len(part) + 1
    return members


# --------------------------------------------------------------------------
# Extractors
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class DesktopItem:
    surface: str
    label: str
    where: str  # upstream-relative "path:line"

    @property
    def id(self) -> str:
        return f"{self.surface}:{self.label}"


def _read(rel: str) -> str:
    path = UPSTREAM / rel
    if not path.is_file():
        raise ExtractionError(f"{rel}: missing (upstream layout changed?)")
    return path.read_text(encoding="utf-8")


def _items(surface: str, rel: str, pairs) -> list[DesktopItem]:
    seen: dict[str, DesktopItem] = {}
    for label, line in pairs:
        if label and label not in seen:
            seen[label] = DesktopItem(surface, label, f"{rel}:{line}")
    return list(seen.values())


def extract_gizmos() -> list[DesktopItem]:
    rel = "src/slic3r/GUI/Gizmos/GLGizmosManager.hpp"
    text = preprocess(_read(rel))
    return _items("gizmo", rel, enum_members(
        text, r"enum\s+EType\s*:\s*unsigned\s+char\s*\{", {"Undefined"}))


def extract_toolbars() -> list[DesktopItem]:
    rel = "src/slic3r/GUI/GLCanvas3D.cpp"
    text = preprocess(_read(rel))
    pairs = []
    functions = list(re.finditer(r"\bbool\s+GLCanvas3D::(_init_\w*toolbar)\s*\(\s*\)\s*\{", text))
    if not functions:
        raise ExtractionError("no GLCanvas3D::_init_*toolbar definitions")
    for fn in functions:
        brace = fn.end() - 1
        body = text[brace:balanced_end(text, brace)]
        for m in re.finditer(r'\b\w*item\.name\s*=\s*"([^"]+)"', body):
            name = m.group(1)
            if "seperator" in name or "separator" in name:
                continue
            pairs.append((name, line_of(text, brace + m.start())))
    return _items("toolbar", rel, pairs)


_MENU_CALL = re.compile(
    r"\b(append_menu_item|append_menu_check_item|append_menu_radio_item|append_submenu|AppendSubMenu)\s*\("
    r"|(?:->|\.)(Append)\s*\(\s*wxID_ANY\s*,")
_LABEL_INDEX = {"append_submenu": 3, "AppendSubMenu": 1, "Append": 1}
_FUNCTION_START = re.compile(
    r"^(?![ \t#])(?:[\w:<>,*&~]+[ \t*&]+)*(?:\w+::)*(~?\w+)\s*\([^;{]*\)\s*(?:const\s*)?(?:override\s*)?\{",
    re.MULTILINE)


def enclosing_function(text: str, offset: int) -> str:
    name = ""
    for m in _FUNCTION_START.finditer(text, 0, offset):
        name = m.group(1)
    return name


def _menu_items(surface: str, rel: str) -> list[DesktopItem]:
    text = preprocess(_read(rel))
    pairs = []
    for m in _MENU_CALL.finditer(text):
        kind = m.group(1) or m.group(2)
        open_paren = text.index("(", m.start())
        args = split_args(text, open_paren)
        index = _LABEL_INDEX.get(kind, 2)
        if len(args) <= index:
            continue  # a declaration/definition, not a call site
        label = label_of(args[index])
        if label.startswith("{"):
            label = resolve_local_label(text, m.start(), args[index].strip()) or label
        if label.startswith("{"):
            # computed label: qualify by the enclosing function so unrelated
            # call sites that share a variable name stay distinct items
            label = f"{label}@{enclosing_function(text, m.start())}"
        pairs.append((label, line_of(text, m.start())))
    return _items(surface, rel, pairs)


def extract_menus() -> list[DesktopItem]:
    return _menu_items("menu", "src/slic3r/GUI/MainFrame.cpp")


def extract_context_menus() -> list[DesktopItem]:
    return _menu_items("context", "src/slic3r/GUI/GUI_Factories.cpp")


def extract_shortcuts() -> list[DesktopItem]:
    rel = "src/slic3r/GUI/KBShortcutsDialog.cpp"
    text = preprocess(_read(rel))
    body, start = function_body(text, r"void\s+KBShortcutsDialog::fill_shortcuts\s*\(")
    pairs = []
    for table in re.finditer(r"\bShortcuts\s+\w+\s*=\s*\{", body):
        brace = table.end() - 1
        end = balanced_end(body, brace)
        i = brace + 1
        while i < end:
            if body[i] == "{":
                row_end = balanced_end(body, i)
                row = body[i + 1:row_end]
                parts = split_args("(" + row + ")", 0)
                if len(parts) == 2:
                    desc = parts[1]
                    label = label_of(desc) if _LABEL_CALL.search(desc) else "{key " + label_of(parts[0]) + "}"
                    pairs.append((label, line_of(text, start + i)))
                i = row_end + 1
                continue
            end_literal = _literal_end(body, i) if body[i] in "\"'" else None
            i = end_literal if end_literal is not None else i + 1
    return _items("kb", rel, pairs)


def extract_slider() -> list[DesktopItem]:
    rel = "src/slic3r/GUI/IMSlider.cpp"
    text = preprocess(_read(rel))
    pairs = [
        (normalize_label(_unescape(m.group(1))), line_of(text, m.start()))
        for m in re.finditer(r"\b(?:menu_item_with_icon|begin_menu)\s*\(\s*\(?\s*_u8L\(\s*" + _STRING, text)
    ]
    return _items("slider", rel, pairs)


def extract_plate_icons() -> list[DesktopItem]:
    rel = "src/slic3r/GUI/PartPlate.cpp"
    text = preprocess(_read(rel))
    body, start = function_body(text, r"void\s+PartPlate::render_icons\s*\(")
    pairs = [
        (normalize_label(_unescape(m.group(1))), line_of(text, start + m.start()))
        for m in re.finditer(r"\bshow_tooltip\s*\(\s*_u8L\(\s*" + _STRING, body)
    ]
    return _items("plate", rel, pairs)


def extract_view_types() -> list[DesktopItem]:
    rel = "src/libvgcode/include/Types.hpp"
    text = preprocess(_read(rel))
    return _items("view", rel, enum_members(text, r"enum\s+class\s+EViewType\b[^{]*\{", {"COUNT"}))


def extract_option_types() -> list[DesktopItem]:
    rel = "src/libvgcode/include/Types.hpp"
    text = preprocess(_read(rel))
    return _items("option", rel, enum_members(text, r"enum\s+class\s+EOptionType\b[^{]*\{", {"COUNT"}))


def extract_hosts() -> list[DesktopItem]:
    rel = "src/libslic3r/PrintConfig.hpp"
    text = preprocess(_read(rel))
    return _items("host", rel, enum_members(text, r"enum\s+PrintHostType\s*\{", set()))


def extract_formats() -> list[DesktopItem]:
    rel = "src/slic3r/GUI/GUI_App.hpp"
    text = preprocess(_read(rel))
    return _items("format", rel, enum_members(text, r"enum\s+FileType\s*\{", {"FT_SIZE"}))


_PREF_SKIP = {"title", "label", "combobox_base"}


def extract_preferences() -> list[DesktopItem]:
    rel = "src/slic3r/GUI/Preferences.cpp"
    text = preprocess(_read(rel))
    pairs = []
    for m in re.finditer(r"(?<!::)\bcreate_item_(\w+)\s*\(", text):
        kind = m.group(1)
        if kind in _PREF_SKIP:
            continue
        before = text[max(0, m.start() - 40):m.start()]
        if re.search(r"\*\s*$|\bPreferencesDialog::\s*$", before):
            continue  # definition / declaration
        args = split_args(text, m.end() - 1)
        joined = ",".join(args)
        if _LABEL_CALL.search(joined):
            label = label_of(joined)
        else:
            label = label_of(joined, fallback_prefix=f"{kind}:")
        pairs.append((label, line_of(text, m.start())))
    return _items("pref", rel, pairs)


_DIALOG_BASES = r"(?:GUI::)?(?:DPIDialog|wxDialog|DPIFrame|MsgDialog|wxFrame|wxMessageDialog)"


def extract_dialogs() -> list[DesktopItem]:
    base = UPSTREAM / "src/slic3r/GUI"
    if not base.is_dir():
        raise ExtractionError("src/slic3r/GUI missing")
    pairs: dict[str, str] = {}
    pattern = re.compile(r"\bclass\s+(\w+)\s*(?:final\s*)?:\s*public\s+" + _DIALOG_BASES + r"\b")
    for path in sorted(base.rglob("*.hpp")):
        text = preprocess(path.read_text(encoding="utf-8"))
        for m in pattern.finditer(text):
            rel = path.relative_to(UPSTREAM).as_posix()
            pairs.setdefault(m.group(1), f"{rel}:{line_of(text, m.start())}")
    return [DesktopItem("dialog", name, where) for name, where in sorted(pairs.items())]


def extract_settings_pages() -> list[DesktopItem]:
    data = json.loads(LAYOUT.read_text())
    items = []
    for kind, pages in data["layout"].items():
        for page in pages:
            options = sum(len(group["options"]) for group in page["groups"])
            items.append(DesktopItem(
                "settings", f"{kind}/{page['page']}",
                f"src/slic3r/GUI/Tab.cpp ({options} options)"))
    return items


@dataclass(frozen=True)
class Surface:
    name: str
    title: str
    source: str
    extract: object
    minimum: int


EXTRACTORS = [
    Surface("gizmo", "3D editor gizmos", "Gizmos/GLGizmosManager.hpp EType", extract_gizmos, 12),
    Surface("toolbar", "Canvas toolbars", "GLCanvas3D.cpp _init_*toolbar", extract_toolbars, 8),
    Surface("menu", "Menu bar", "MainFrame.cpp", extract_menus, 60),
    Surface("context", "Right-click menus", "GUI_Factories.cpp", extract_context_menus, 40),
    Surface("kb", "Keyboard/mouse actions", "KBShortcutsDialog.cpp", extract_shortcuts, 40),
    Surface("slider", "Layer slider menu", "IMSlider.cpp", extract_slider, 6),
    Surface("plate", "Plate icons", "PartPlate.cpp render_icons", extract_plate_icons, 5),
    Surface("view", "Preview color schemes", "libvgcode Types.hpp EViewType", extract_view_types, 12),
    Surface("option", "Preview visibility options", "libvgcode Types.hpp EOptionType", extract_option_types, 6),
    Surface("host", "Print hosts", "PrintConfig.hpp PrintHostType", extract_hosts, 10),
    Surface("format", "File types", "GUI_App.hpp FileType", extract_formats, 10),
    Surface("pref", "Preferences", "Preferences.cpp", extract_preferences, 40),
    Surface("dialog", "Dialogs and windows", "src/slic3r/GUI/**/*.hpp", extract_dialogs, 60),
    Surface("settings", "Settings pages", "Tab.cpp via settings-layout.json", extract_settings_pages, 15),
]


def extract_all() -> tuple[dict[str, DesktopItem], list[str]]:
    items: dict[str, DesktopItem] = {}
    errors: list[str] = []
    for surface in EXTRACTORS:
        try:
            found = surface.extract()
        except (ExtractionError, OSError, UnicodeDecodeError, KeyError, json.JSONDecodeError) as error:
            errors.append(f"extract {surface.name}: {error}")
            continue
        if len(found) < surface.minimum:
            errors.append(
                f"extract {surface.name}: {len(found)} items < minimum {surface.minimum} "
                f"(anchor drift in {surface.source}?)")
        for item in found:
            items[item.id] = item
    return items, errors


def check_layout_fresh() -> list[str]:
    """The committed settings layout must equal a fresh Tab.cpp extraction."""
    run = subprocess.run(
        [sys.executable, str(LAYOUT_TOOL), "--check"],
        capture_output=True, text=True, cwd=ROOT)
    if run.returncode != 0:
        detail = (run.stderr or run.stdout).strip().splitlines()
        return ["settings layout: " + (detail[-1] if detail else f"exit {run.returncode}")]
    return []


# --------------------------------------------------------------------------
# Manifest + OrcaPad evidence
# --------------------------------------------------------------------------

AREAS = {
    "plate": "Plate / 3D editor",
    "prepare": "Prepare / presets / settings",
    "preview": "Preview / G-code",
    "device": "Device / printing",
    "files": "Files / projects / app integration",
    "app": "App / preferences / help",
}
STATUSES = {
    "done": "\u2705",
    "partial": "\U0001F7E1",
    "missing": "\u274C",
    "deferred": "\u23F8\uFE0F",
    "na": "\u2796",
}
WORK_KINDS = {"UI", "Bridge", "Closure", "Client-reimpl"}
FEATURE_KEYS = {"id", "area", "title", "status", "desktop", "source", "evidence",
                "gap", "work", "priority", "reason", "note"}


@dataclass
class Feature:
    id: str
    area: str
    title: str
    status: str
    desktop: list[str] = field(default_factory=list)
    source: str = ""
    evidence: list[str] = field(default_factory=list)
    gap: str = ""
    work: str = ""
    priority: int | None = None
    reason: str = ""
    note: str = ""


class Codebase:
    """OrcaPad sources searched by evidence specs (`scope:regex`)."""

    SCOPES = {
        "client": ("Sources/OrcaPad", "**/*.swift"),
        "facade": ("Sources/OrcaBridge", "*.swift"),
        "bridge": ("Bridge/engine-cxx", "*.*"),
        "tests": ("Bridge/tools", "contract_tests.cpp"),
        "plist": (".", "App-Info.plist"),
    }

    def __init__(self) -> None:
        self._files: dict[str, list[tuple[str, str]]] = {}

    def files(self, scope: str) -> list[tuple[str, str]]:
        if scope not in self._files:
            base, pattern = self.SCOPES[scope]
            paths = sorted((ROOT / base).glob(pattern))
            if not paths:
                raise ValueError(f"evidence scope {scope!r} matched no files")
            self._files[scope] = [
                (p.relative_to(ROOT).as_posix(), p.read_text(encoding="utf-8"))
                for p in paths if p.is_file()
            ]
        return self._files[scope]

    def search(self, scope: str, pattern: str) -> str | None:
        regex = re.compile(pattern, re.MULTILINE)
        for rel, text in self.files(scope):
            if regex.search(text):
                return rel
        return None

    def resolve(self, spec: str) -> str | None:
        """None when the evidence holds, else a reason."""
        scope, sep, value = spec.partition(":")
        if not sep or not value:
            return "malformed evidence (want scope:value)"
        if scope == "abi":
            if not re.fullmatch(r"orca_\w+", value):
                return "abi evidence must name an orca_* function"
            missing = []
            if not re.search(r"\b" + value + r"\s*\(", HEADER.read_text()):
                missing.append("declaration in orca_bridge.h")
            if not self.search("bridge", r"\b" + value + r"\s*\("):
                missing.append("definition in Bridge/engine-cxx")
            if not self.search("facade", r"\b" + value + r"\b"):
                missing.append("use in the Swift facade")
            if not self.search("tests", r"\b" + value + r"\b"):
                missing.append("contract test")
            return ("missing " + ", ".join(missing)) if missing else None
        if scope == "resource":
            path = ROOT / "Sources/OrcaPad/Resources" / value
            return None if path.exists() else f"missing resource {value}"
        if scope not in self.SCOPES:
            return f"unknown evidence scope {scope!r}"
        try:
            found = self.search(scope, value)
        except re.error as error:
            return f"bad regex: {error}"
        return None if found else f"no match in {self.SCOPES[scope][0]}"


def load_manifest() -> tuple[dict, list[Feature], list[str]]:
    errors: list[str] = []
    try:
        data = tomllib.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        return {}, [], [f"manifest: {error}"]
    features: list[Feature] = []
    seen: set[str] = set()
    for index, raw in enumerate(data.get("feature", [])):
        where = f"manifest feature #{index + 1} ({raw.get('id', '?')})"
        unknown = set(raw) - FEATURE_KEYS
        if unknown:
            errors.append(f"{where}: unknown keys {sorted(unknown)}")
        try:
            feature = Feature(**{k: v for k, v in raw.items() if k in FEATURE_KEYS})
        except TypeError as error:
            errors.append(f"{where}: {error}")
            continue
        if feature.id in seen:
            errors.append(f"{where}: duplicate id")
        seen.add(feature.id)
        if not re.fullmatch(r"[a-z]+\.[a-z0-9-]+", feature.id):
            errors.append(f"{where}: id must look like area.slug")
        elif feature.id.split(".")[0] != feature.area:
            errors.append(f"{where}: id prefix must equal area {feature.area!r}")
        if feature.area not in AREAS:
            errors.append(f"{where}: unknown area {feature.area!r}")
        if feature.status not in STATUSES:
            errors.append(f"{where}: unknown status {feature.status!r}")
        if not feature.title:
            errors.append(f"{where}: title is required")
        if not feature.desktop and not feature.source:
            errors.append(f"{where}: needs desktop items or an upstream source anchor")
        if feature.status in ("done", "partial") and not feature.evidence:
            errors.append(f"{where}: {feature.status} needs OrcaPad evidence")
        if feature.status == "partial" and not feature.gap:
            errors.append(f"{where}: partial needs a gap")
        if feature.status in ("missing", "partial", "deferred"):
            parts = [p.strip() for p in feature.work.split("+")] if feature.work else []
            if not parts or any(p not in WORK_KINDS for p in parts):
                errors.append(f"{where}: work must be {'/'.join(sorted(WORK_KINDS))} (joined by +)")
        if feature.status in ("na", "deferred") and not feature.reason:
            errors.append(f"{where}: {feature.status} needs a reason")
        if feature.priority is not None and feature.status not in ("missing", "partial"):
            errors.append(f"{where}: priority only applies to missing/partial")
        features.append(feature)
    return data.get("meta", {}), features, errors


def check_source_anchor(feature: Feature) -> str | None:
    rel, sep, pattern = feature.source.partition(":")
    if not sep:
        return "source must be 'upstream-path:regex'"
    path = UPSTREAM / rel
    if not path.is_file():
        return f"source file {rel} missing"
    try:
        if not re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE):
            return f"source pattern not found in {rel}"
    except re.error as error:
        return f"bad source regex: {error}"
    return None


def verify(items: dict[str, DesktopItem], features: list[Feature]) -> tuple[dict[str, Feature], list[str]]:
    errors: list[str] = []
    owner: dict[str, Feature] = {}
    codebase = Codebase()
    for feature in features:
        for item_id in feature.desktop:
            if item_id not in items:
                errors.append(f"{feature.id}: claims {item_id!r}, which upstream no longer has (orphan)")
            elif item_id in owner:
                errors.append(f"{item_id!r} claimed by both {owner[item_id].id} and {feature.id}")
            else:
                owner[item_id] = feature
        if feature.source:
            problem = check_source_anchor(feature)
            if problem:
                errors.append(f"{feature.id}: {problem}")
        for spec in feature.evidence:
            problem = codebase.resolve(spec)
            if problem:
                errors.append(f"{feature.id}: evidence {spec!r}: {problem}")
    for item_id in sorted(set(items) - set(owner)):
        errors.append(f"unclaimed desktop item {item_id!r} ({items[item_id].where})")
    return owner, errors


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

def _cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def _desktop_cell(feature: Feature, items: dict[str, DesktopItem], limit: int = 8) -> str:
    if not feature.desktop:
        return f"`{_cell(feature.source.split(':', 1)[0])}`"
    by_surface: dict[str, list[str]] = {}
    for item_id in feature.desktop:
        surface, _, label = item_id.partition(":")
        by_surface.setdefault(surface, []).append(label)
    parts = []
    shown = 0
    for surface, labels in by_surface.items():
        room = max(1, limit - shown)
        head = labels[:room]
        shown += len(head)
        extra = f" +{len(labels) - len(head)}" if len(labels) > len(head) else ""
        parts.append(f"**{surface}**: " + ", ".join(_cell(label) for label in head) + extra)
    return "; ".join(parts)


def _parity(counts: dict[str, int]) -> str:
    scope = counts["done"] + counts["partial"] + counts["missing"] + counts["deferred"]
    if scope == 0:
        return "\u2014"
    return f"{100 * (counts['done'] + 0.5 * counts['partial']) / scope:.0f}%"


def upstream_pin() -> str:
    run = subprocess.run(["git", "-C", str(UPSTREAM), "describe", "--tags", "--always"],
                         capture_output=True, text=True)
    if run.returncode != 0:
        raise RuntimeError(f"git describe failed: {run.stderr.strip()}")
    return run.stdout.strip()


def abi_version() -> str:
    m = re.search(r"#define\s+ORCA_BRIDGE_ABI_VERSION\s+\(\(uint32_t\)(\d+)\)", HEADER.read_text())
    if not m:
        raise RuntimeError("ORCA_BRIDGE_ABI_VERSION not found in orca_bridge.h")
    return m.group(1)


def render(meta: dict, items: dict[str, DesktopItem], features: list[Feature],
           owner: dict[str, Feature]) -> str:
    out: list[str] = []
    w = out.append
    w(f"# {meta.get('title', 'OrcaPad desktop parity')}")
    w("")
    w("<!-- GENERATED by Bridge/tools/parity-check.py --write from "
      "Bridge/tools/parity-manifest.toml. Do not edit by hand. -->")
    w("")
    w(f"Desktop surface extracted from `upstream/orcaslicer` {upstream_pin()} (pinned, unmodified); "
      f"OrcaPad at Bridge ABI v{abi_version()}. Every \u2705/\U0001F7E1 claim's evidence is "
      "verified against OrcaPad's code on each run; `parity-check.py --check` is a commit gate.")
    w("")
    intro = meta.get("intro", "").strip()
    if intro:
        w(intro)
        w("")
    legend = " \u00b7 ".join(f"{icon} {name}" for name, icon in STATUSES.items())
    w(f"Status: {legend}. Parity = (\u2705 + \u00bd\U0001F7E1) / (\u2705 + \U0001F7E1 + \u274C + \u23F8\uFE0F); "
      "\u2796 (not applicable on iOS) is excluded.")
    w("")

    # Summary by area
    w("## Summary")
    w("")
    w("| Area | Features | " + " | ".join(STATUSES.values()) + " | Parity |")
    w("|---|---|" + "---|" * len(STATUSES) + "---|")
    totals = {s: 0 for s in STATUSES}
    for area, title in AREAS.items():
        counts = {s: 0 for s in STATUSES}
        for feature in features:
            if feature.area == area:
                counts[feature.status] += 1
        for s in STATUSES:
            totals[s] += counts[s]
        w(f"| {title} | {sum(counts.values())} | " + " | ".join(str(counts[s]) for s in STATUSES)
          + f" | {_parity(counts)} |")
    w(f"| **Total** | **{sum(totals.values())}** | " + " | ".join(f"**{totals[s]}**" for s in STATUSES)
      + f" | **{_parity(totals)}** |")
    w("")

    # Surface coverage
    w("### Desktop surface coverage (items)")
    w("")
    w("| Surface | Upstream source | Items | " + " | ".join(STATUSES.values()) + " | Parity |")
    w("|---|---|---|" + "---|" * len(STATUSES) + "---|")
    for surface in EXTRACTORS:
        counts = {s: 0 for s in STATUSES}
        for item in items.values():
            if item.surface == surface.name:
                counts[owner[item.id].status] += 1
        w(f"| {surface.title} (`{surface.name}`) | {_cell(surface.source)} | {sum(counts.values())} | "
          + " | ".join(str(counts[s]) for s in STATUSES) + f" | {_parity(counts)} |")
    w("")

    # Remaining work
    area_order = list(AREAS)
    remaining = [f for f in features if f.status in ("missing", "partial")]
    remaining.sort(key=lambda f: (f.priority if f.priority is not None else 10_000,
                                  area_order.index(f.area), f.title.lower()))
    w("## Remaining work (priority order)")
    w("")
    for number, feature in enumerate(remaining, 1):
        detail = feature.gap or feature.note
        w(f"{number}. {STATUSES[feature.status]} **{feature.title}** \u00b7 {AREAS[feature.area]} "
          f"\u00b7 {feature.work}" + (f" \u2014 {detail}" if detail else ""))
    deferred = [f for f in features if f.status == "deferred"]
    if deferred:
        w("")
        w("**Deferred:** " + "; ".join(f"{f.title} ({f.reason})" for f in deferred))
    w("")

    # Per-area tables
    status_order = list(STATUSES)
    for area, title in AREAS.items():
        area_features = [f for f in features if f.area == area]
        if not area_features:
            continue
        area_features.sort(key=lambda f: (status_order.index(f.status), f.title.lower()))
        w(f"## {title}")
        w("")
        w("| Feature | Status | Desktop | OrcaPad evidence | Notes |")
        w("|---|---|---|---|---|")
        for feature in area_features:
            evidence = ", ".join(f"`{_cell(spec)}`" for spec in feature.evidence) or "\u2014"
            notes = []
            if feature.gap:
                notes.append(f"Gap: {feature.gap}")
            if feature.work and feature.status != "done":
                notes.append(f"Work: {feature.work}")
            if feature.reason:
                notes.append(feature.reason)
            if feature.note:
                notes.append(feature.note)
            w(f"| {_cell(feature.title)} | {STATUSES[feature.status]} | {_desktop_cell(feature, items)} | "
              f"{evidence} | {_cell(' \u00b7 '.join(notes)) or '\u2014'} |")
        w("")

    # Item index
    w("## Desktop item index")
    w("")
    w(f"<details><summary>All {len(items)} extracted desktop items and the feature that claims each</summary>")
    w("")
    w("| Item | Upstream | Feature | Status |")
    w("|---|---|---|---|")
    for item in sorted(items.values(), key=lambda it: ([s.name for s in EXTRACTORS].index(it.surface),
                                                       it.label.lower())):
        feature = owner[item.id]
        w(f"| `{_cell(item.id)}` | {_cell(item.where)} | {feature.id} | {STATUSES[feature.status]} |")
    w("")
    w("</details>")
    return "\n".join(out) + "\n"


def print_unclaimed(items: dict[str, DesktopItem], owner: dict[str, Feature]) -> None:
    unclaimed = sorted((i for i in items.values() if i.id not in owner),
                       key=lambda it: (it.surface, it.label.lower()))
    current = None
    for item in unclaimed:
        if item.surface != current:
            current = item.surface
            print(f"\n# --- {current}")
        print(f'  "{item.id}",  # {item.where}')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dump", action="store_true", help="list extracted desktop items")
    mode.add_argument("--unclaimed", action="store_true", help="print claim stubs for unclaimed items")
    mode.add_argument("--write", action="store_true", help="regenerate PARITY.md")
    mode.add_argument("--check", action="store_true", help="require PARITY.md to be current")
    args = parser.parse_args()

    items, errors = extract_all()
    if args.dump:
        for item in sorted(items.values(), key=lambda it: (it.surface, it.label.lower())):
            print(f"{item.id}\t{item.where}")
        for error in errors:
            print(f"FAIL  {error}", file=sys.stderr)
        return 1 if errors else 0

    errors += check_layout_fresh()
    meta, features, manifest_errors = load_manifest()
    errors += manifest_errors
    owner, verify_errors = verify(items, features)
    errors += verify_errors

    if args.unclaimed:
        print_unclaimed(items, owner)
        return 0

    counts = {s: sum(1 for f in features if f.status == s) for s in STATUSES}
    summary = ", ".join(f"{counts[s]} {s}" for s in STATUSES)
    if errors:
        for error in errors:
            print(f"FAIL  {error}", file=sys.stderr)
        print(f"parity check: FAIL ({len(errors)} problems; {len(items)} desktop items, "
              f"{len(features)} features: {summary})", file=sys.stderr)
        return 1

    report = render(meta, items, features, owner)
    if args.write:
        REPORT.write_text(report, encoding="utf-8")
    elif args.check:
        current = REPORT.read_text(encoding="utf-8") if REPORT.exists() else ""
        if current != report:
            print("FAIL  PARITY.md is stale: run Bridge/tools/parity-check.py --write", file=sys.stderr)
            return 1
    print(f"parity check: PASS ({len(items)} desktop items, {len(features)} features: {summary}; "
          f"parity {_parity(counts)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

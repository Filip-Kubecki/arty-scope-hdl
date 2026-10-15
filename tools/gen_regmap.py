#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/gen_regmap.py - generuje pliki na podstawie regmap.yaml.

Wyjścia:
  rtl/regmap_pkg.vhd               pakiet VHDL dla RTL i testbenchy (cały plik)
  tb/regmap_status.g.vhd           tablica adresów, na które płytka odpowiada inaczej niż ERROR_BAD_ADDRESS
  docs/protocol.md                 tylko tabela między znacznikami REGMAP

Wymagania: python3, pyyaml (sudo apt install python3-yaml).
Użycie:
  python3 tools/gen_regmap.py           generuje wszystkie pliki
  python3 tools/gen_regmap.py --check   kończy kodem 1, gdy któryś plik jest nieaktualny
"""

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "regmap.yaml"
VHDL_PKG = ROOT / "rtl" / "regmap_pkg.vhd"
VHDL_STATUS = ROOT / "tb" / "regmap_status.g.vhd"
DOC = ROOT / "docs" / "protocol.md"

BEGIN = "<!-- REGMAP:REGISTERS:BEGIN -->"
END = "<!-- REGMAP:REGISTERS:END -->"

STATUSES = {"implemented", "accepted", "planned", "reserved"}
ACCESS = {"ro", "wo", "rw"}
RESPONDING = {"implemented", "accepted"}  # odpowiadają inaczej niż ERROR_BAD_ADDRESS
DOCUMENTED = {"implemented"}  # trafiają do tabeli w protocol.md

VHDL_TYPE = {"byte": "byte_t", "word": "word_t", "natural": "natural"}


def validate(d):
    problems = []

    seen_names = set()
    seen_addrs = {}
    for r in d["registers"]:
        name = r["name"]
        if name in seen_names:
            problems.append(f"zduplikowana nazwa rejestru: {name}")
        seen_names.add(name)

        if r["status"] not in STATUSES:
            problems.append(f"{name}: nieznany status '{r['status']}'")
        if r["access"] not in ACCESS:
            problems.append(f"{name}: nieznany dostęp '{r['access']}'")

        addr = r["address"]
        if not 0x00 <= addr <= 0xFF:
            problems.append(f"{name}: adres poza zakresem 0x00-0xFF")
        if addr in seen_addrs:
            problems.append(
                f"{name} i {seen_addrs[addr]} mają ten sam adres 0x{addr:02X}"
            )
        seen_addrs[addr] = name

    seen_errors = set()
    for e in d["errors"]:
        if e["name"] in seen_errors:
            problems.append(f"zduplikowany kod błędu: {e['name']}")
        seen_errors.add(e["name"])

    if problems:
        raise SystemExit("Błędy w regmap.yaml:\n  " + "\n  ".join(problems))


def vhdl_value(c):
    if c["type"] == "byte":
        return f'x"{c["value"]:02X}"'
    if c["type"] == "word":
        return f'x"{c["value"]:08X}"'
    return str(c["value"])


def gen_vhdl_pkg(d):
    lines = [
        "-- GENEROWANE z regmap.yaml. Nie edytuj ręcznie.",
        "library ieee;",
        "use ieee.std_logic_1164.all;",
        "",
        "package regmap_pkg is",
        "",
        "    subtype byte_t is std_logic_vector(7 downto 0);",
        "    subtype word_t is std_logic_vector(31 downto 0);",
        "",
        "    -- Stałe protokołu",
    ]
    for c in d["protocol_constants"]:
        lines.append(
            f"    constant {c['name']} : {VHDL_TYPE[c['type']]} := {vhdl_value(c)};  -- {c['desc']}"
        )

    lines += ["", "    -- Kody błędów"]
    for e in d["errors"]:
        lines.append(
            f'    constant {e["name"]} : byte_t := x"{e["code"]:02X}";  -- {e["desc"]}'
        )

    lines += ["", "    -- Adresy rejestrów i komend (wszystkie statusy)"]
    for r in d["registers"]:
        lines.append(
            f'    constant ADDR_{r["name"]} : byte_t := x"{r["address"]:02X}";'
            f"  -- {r['status']}: {r['desc']}"
        )
        if "reset" in r:
            lines.append(
                f'    constant VAL_{r["name"]} : word_t := x"{r["reset"]:08X}";'
            )

    lines += ["", "end package regmap_pkg;", ""]
    return "\n".join(lines)


def gen_vhdl_status(d):
    responding = sorted(
        r["address"] for r in d["registers"] if r["status"] in RESPONDING
    )
    choices = [f"        {a} => true" for a in responding]
    choices.append("        others => false")
    lines = [
        "-- GENEROWANE z regmap.yaml. Nie edytuj ręcznie.",
        "package regmap_status is",
        "",
        "    type status_t is array (0 to 255) of boolean;",
        "",
        "    -- true: adres odpowiada inaczej niż ERROR_BAD_ADDRESS",
        "    constant ADDRESS_RESPONDS : status_t := (",
        ",\n".join(choices),
        "    );",
        "",
        "end package regmap_status;",
        "",
    ]
    return "\n".join(lines)


def parse_block(block):
    """Zwraca {ADDR_NAZWA: (komórka_adresu, opis)} z wierszy tabeli."""
    rows = {}
    for line in block.splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 3 and cells[1].startswith("`ADDR_"):
            rows[cells[1].strip("`")] = (cells[0], cells[2])
    return rows


def render_doc(text, registers):
    if BEGIN not in text or END not in text:
        raise SystemExit(f"Brak znaczników {BEGIN} / {END} w {DOC.name}")

    head, rest = text.split(BEGIN, 1)
    block, tail = rest.split(END, 1)
    old = parse_block(block)

    wanted = sorted(
        (r for r in registers if r["status"] in DOCUMENTED),
        key=lambda r: r["address"],
    )
    wanted_names = {f"ADDR_{r['name']}" for r in wanted}

    table = ["| Adres | Nazwa | Opis |", "|-------|-------|------|"]
    for r in wanted:
        name = f"ADDR_{r['name']}"
        desc = old[name][1] if name in old and old[name][1] else "---"
        table.append(f"| `0x{r['address']:02X}` | `{name}` | {desc} |")

    warnings = []
    for name, (addr_cell, desc) in old.items():
        if name not in wanted_names:
            table.append(f"| {addr_cell} | `{name}` | {desc} |")
            warnings.append(f"{name} jest w {DOC.name}, ale nie ma statusu implemented")

    body = "\n" + "\n".join(table) + "\n"
    return head + BEGIN + body + END + tail, warnings


def main():
    check = "--check" in sys.argv
    data = yaml.safe_load(SOURCE.read_text(encoding="utf-8"))
    validate(data)

    doc_text, warnings = render_doc(DOC.read_text(encoding="utf-8"), data["registers"])
    outputs = {
        VHDL_PKG: gen_vhdl_pkg(data),
        VHDL_STATUS: gen_vhdl_status(data),
        DOC: doc_text,
    }

    for w in warnings:
        print(f"UWAGA: {w}")

    stale = []
    for path, text in outputs.items():
        rel = path.relative_to(ROOT)
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(rel)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"zapisano {rel}")

    for rel in stale:
        print(f"NIEAKTUALNE: {rel}")
    return 1 if (check and stale) else 0


if __name__ == "__main__":
    sys.exit(main())

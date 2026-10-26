"""Build RaidWishlist's fixed WotLK raid-loot catalogue from AzerothCore SQL.

Usage:
  py -3.11 tools/generate_raidwishlist_catalogue.py PATH-TO-azerothcore-wotlk

The source checkout is the GPL-2.0 AzerothCore WotLK world database.  This
generator intentionally reads only the base world SQL so the shipped catalogue
is reproducible and does not depend on a running realm.
"""
# SPDX-License-Identifier: GPL-2.0-only

from __future__ import annotations

import csv
import sys
from collections import defaultdict
from pathlib import Path


RAIDS = {
    533: "NAXX",
    615: "OS",
    616: "EOE",
    603: "ULD",
    649: "TOC",
    718: "ONY",
    631: "ICC",
    724: "RS",
}
# Some encounter creatures are spawned by instance scripts rather than a
# creature table row.  Keep their primary entries here so their AzerothCore
# loot templates are included alongside every map-spawned creature and chest.
SCRIPTED_ENCOUNTERS = {
    "NAXX": {15928, 15930, 15931, 15932, 15936, 15952, 15953, 15954, 15956, 15989, 15990, 16011, 16028, 16060, 16061, 16062, 16063},
    "OS": {28860, 30449, 30451, 30452},
    "EOE": {28859},
    "ULD": {32845, 32857, 32865, 32867, 32871, 32906, 32927, 32930, 33113, 33118, 33186, 33271, 33288, 33515},
    "TOC": {34441, 34444, 34445, 34447, 34448, 34449, 34450, 34453, 34454, 34455, 34456, 34458, 34459, 34460, 34461, 34463, 34465, 34466, 34467, 34468, 34469, 34470, 34471, 34472, 34473, 34474, 34475, 34476, 34477, 34478, 34479, 34497, 34510, 34564, 34780, 34796, 34797, 34799, 35144},
    "ONY": {10184},
    "ICC": {36597, 36612, 36626, 36627, 36678, 36789, 36853, 36855, 37813, 37955, 37970},
    "RS": {39746, 39747, 39751, 39863},
}
WORLD = Path("data/sql/base/db_world")
# Raiders wish only for epic or better loot; poor to rare trash and world
# drops are left out (user decision 2026-10-26).
MIN_QUALITY = 4


def columns(path: Path) -> list[str]:
    result = []
    reading = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("CREATE TABLE"):
            reading = True
        elif reading and line.startswith(")"):
            return result
        elif reading and line.lstrip().startswith("`"):
            result.append(line.split("`", 2)[1])
    raise ValueError(f"no columns in {path}")


def rows(path: Path):
    """Read mysqldump INSERT rows without accepting SQL as code."""
    names = columns(path)
    in_insert = False
    with path.open(encoding="utf-8") as source:
        for line in source:
            if line.startswith("INSERT INTO"):
                in_insert = True
                continue
            if not in_insert:
                continue
            value = line.strip()
            if not value:
                continue
            if value == ";":
                in_insert = False
                continue
            if not (value.startswith("(") and value.endswith((",", ";"))):
                raise ValueError(f"unexpected dump row in {path}: {value[:80]}")
            fields = next(csv.reader([value[1:-2]], delimiter=",", quotechar="'", escapechar="\\"))
            if len(fields) != len(names):
                raise ValueError(f"wrong field count in {path}: {len(fields)} != {len(names)}")
            yield dict(zip(names, fields, strict=True))
            if value.endswith(";"):
                in_insert = False


def number(row: dict[str, str], key: str) -> int:
    value = row[key]
    return 0 if value == "NULL" else int(value)


def lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "") + '"'


def main(source_root: Path) -> None:
    world = source_root / WORLD
    creature_rows = list(rows(world / "creature.sql"))
    raid_creatures = {
        number(row, key)
        for row in creature_rows
        if number(row, "map") in RAIDS
        for key in ("id1", "id2", "id3")
        if number(row, key)
    }
    for entries in SCRIPTED_ENCOUNTERS.values():
        raid_creatures.update(entries)
    templates = {number(row, "entry"): row for row in rows(world / "creature_template.sql")}
    expanded_creatures = set(raid_creatures)
    todo = list(raid_creatures)
    while todo:
        entry = todo.pop()
        template = templates.get(entry)
        if not template:
            continue
        for key in ("difficulty_entry_1", "difficulty_entry_2", "difficulty_entry_3"):
            related = number(template, key)
            if related and related not in expanded_creatures:
                expanded_creatures.add(related)
                todo.append(related)

    creature_raids = defaultdict(set)
    for row in creature_rows:
        raid = RAIDS.get(number(row, "map"))
        if raid:
            for key in ("id1", "id2", "id3"):
                entry = number(row, key)
                if entry:
                    creature_raids[entry].add(raid)
    for raid, entries in SCRIPTED_ENCOUNTERS.items():
        for entry in entries:
            creature_raids[entry].add(raid)
    # Difficulty variants are a graph, not a one-way list: every member of a
    # connected encounter family belongs to every raid of its spawned form.
    neighbours = defaultdict(set)
    for entry in expanded_creatures:
        template = templates.get(entry)
        if template:
            for key in ("difficulty_entry_1", "difficulty_entry_2", "difficulty_entry_3"):
                related = number(template, key)
                if related:
                    neighbours[entry].add(related)
                    neighbours[related].add(entry)
    for entry in expanded_creatures:
        pending, component, raids = [entry], set(), set()
        while pending:
            current = pending.pop()
            if current in component:
                continue
            component.add(current)
            raids.update(creature_raids[current])
            pending.extend(neighbours[current])
        for related in component:
            creature_raids[related].update(raids)

    creature_loot = defaultdict(list)
    for row in rows(world / "creature_loot_template.sql"):
        creature_loot[number(row, "Entry")].append((number(row, "Item"), number(row, "Reference")))
    reference_loot = defaultdict(list)
    for row in rows(world / "reference_loot_template.sql"):
        reference_loot[number(row, "Entry")].append((number(row, "Item"), number(row, "Reference")))
    gameobject_loot = defaultdict(list)
    for row in rows(world / "gameobject_loot_template.sql"):
        gameobject_loot[number(row, "Entry")].append((number(row, "Item"), number(row, "Reference")))

    loot_sources = defaultdict(set)

    def add_loot(table, entry: int, raids: set[str], seen: set[tuple[str, int]]) -> None:
        marker = ("reference" if table is reference_loot else "loot", entry)
        if marker in seen:
            return
        seen.add(marker)
        for item, reference in table[entry]:
            if item:
                loot_sources[item].update(raids)
            if reference:
                add_loot(reference_loot, abs(reference), raids, seen)

    for entry in expanded_creatures:
        template = templates.get(entry)
        if template and creature_raids[entry]:
            add_loot(creature_loot, number(template, "lootid") or entry, creature_raids[entry], set())

    raid_gameobjects = {
        number(row, "id"): RAIDS[number(row, "map")]
        for row in rows(world / "gameobject.sql")
        if number(row, "map") in RAIDS
    }
    gameobjects = {number(row, "entry"): row for row in rows(world / "gameobject_template.sql")}
    for entry, raid in raid_gameobjects.items():
        template = gameobjects.get(entry)
        # GameObject type 3 is a chest, whose Data1 is its loot template.
        if template and number(template, "type") == 3 and number(template, "Data1"):
            add_loot(gameobject_loot, number(template, "Data1"), {raid}, set())

    items = {
        number(row, "entry"): (row["name"], number(row, "Quality"))
        for row in rows(world / "item_template.sql")
    }
    german = {
        number(row, "ID"): row["Name"]
        for row in rows(world / "item_template_locale.sql")
        if row["locale"] == "deDE" and row["Name"]
    }
    records = []
    for item, raids in loot_sources.items():
        details = items.get(item)
        if details and details[1] >= MIN_QUALITY:
            english, quality = details
            records.append((item, ",".join(sorted(raids)), english, german.get(item, english), quality))
    records.sort(key=lambda record: (record[2].casefold(), record[0]))

    output = Path(__file__).parents[1] / "examples/RaidWishlist/Catalogue.lua"
    lines = [
        "-- SPDX-License-Identifier: GPL-2.0-only",
        "-- Generated by tools/generate_raidwishlist_catalogue.py; do not edit by hand.",
        "-- Source: AzerothCore WotLK GPL-2.0 world database commit a34acdc9fce76de45986aed09677c79bdef2aa5d.",
        "local _, ns = ...",
        "ns.catalogue = {",
    ]
    for item, raids, english, german_name, quality in records:
        lines.append(f"    {{{item}, {lua_string(raids)}, {lua_string(english)}, {lua_string(german_name)}, {quality}}},")
    lines.extend(["}", ""])
    output.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f"wrote {len(records)} catalogue items to {output}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_raidwishlist_catalogue.py PATH-TO-azerothcore-wotlk")
    main(Path(sys.argv[1]))

"""Extract BigWigs' curated, phase-grouped ability lists from its boss modules.

Same mod:GetOptions() shape in both BigWigs (current raid/dungeon tier) and
LittleWigs (every past-expansion dungeon, including whichever ones the live
Mythic+ pool draws from this season) -- both projects, same team, same dialect.
Pass module directories from either: an own-line comment that reads as a
heading ("-- Stage One: ...", "-- Mythic", "-- Kula the Butcher") marks a
phase group, and every live spellID entry that follows belongs to that group
until the next heading. Entries can be a bare number, a quoted string key
("stages" -- not a real ability, skipped), or a {spellID, "ROLE"} table. A
line that is entirely commented out (a `--` line whose first token is itself
a digit or "{") is dead code in the module, not a heading, and is skipped.

This reads only spellIDs, phase groupings and BigWigs'/LittleWigs' own inline
ability names -- structure, not their prose. Ability descriptions in the
shipped addon come from Blizzard's own C_EncounterJournal data, not from here.

Which dungeons to pass: BigWigs' OWN Loader.lua names them, in
`public.currentExpansion.currentSeason` (a `[journalInstanceID] = addonName`
table for the "Retail" -- non-beta -- branch). That is the authoritative list,
not our own TANK_FINGERPRINTS sheet: the pool rotates across expansions, a
dungeon's addonName there does not always match the folder its modules
actually ship in on disk (currentSeason can point at a bundled
LittleWigs_CurrentSeason/LittleWigs_Midnight package that reuses per-expansion
files), and cross-checking against our own sheet instead once silently missed
5 of 8 current dungeons whose encounterIDs had simply never been added to it.
Resolve each journalInstanceID to its real files with
`grep -rl 'NewBoss([^,]*, <journalInstanceID>,' .../LittleWigs*` (that id is
mod:NewBoss's second argument) rather than trusting the addonName string.

Usage: python extract_curated_abilities.py <module_dir> [<module_dir> ...] > out.lua
"""

import re
import sys
from pathlib import Path

HEADING_RE = re.compile(r"^--\s*([A-Za-z].*)$")
ENTRY_NUM_RE = re.compile(r"^\{?\s*(\d{3,9})\b")
STRING_KEY_RE = re.compile(r'^"')
STAGE_WORD_RE = re.compile(r"^Stage(\s+(?:One|Two|Three|Four|Five|Six|\d+))\b")


def rename_phase(phase):
    return STAGE_WORD_RE.sub(lambda m: "Phase" + m.group(1), phase)


def reorder_mythic_last(groups):
    # BigWigs lists Mythic-only abilities wherever they happen to fall in the fight
    # timeline; we want them called out separately, at the end, regardless of source order.
    normal = [g for g in groups if g["phase"] != "Mythic"]
    mythic = [g for g in groups if g["phase"] == "Mythic"]
    return normal + mythic


def find_options_block(text):
    m = re.search(r"function mod:GetOptions\(\)\s*\n\s*return\s*\{", text)
    if not m:
        return None
    start = m.end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return text[start:i - 1]


def parse_block(block):
    groups = []
    current = None
    for raw in block.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("--"):
            hm = HEADING_RE.match(line)
            if hm:
                current = {"phase": hm.group(1).strip(), "abilities": []}
                groups.append(current)
            continue
        if STRING_KEY_RE.match(line):
            continue
        nm = ENTRY_NUM_RE.match(line)
        if not nm:
            continue
        spellID = int(nm.group(1))
        if current is None:
            current = {"phase": None, "abilities": []}
            groups.append(current)
        if spellID not in current["abilities"]:
            current["abilities"].append(spellID)
    return [g for g in groups if g["abilities"]]


def parse_file(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    nb = re.search(r'NewBoss\("([^"]+)"', text)
    enc = re.search(r"SetEncounterID\((\d+)\)", text)
    if not (nb and enc):
        return None
    block = find_options_block(text)
    if block is None:
        return None
    groups = parse_block(block)
    if not groups:
        return None
    for g in groups:
        g["phase"] = rename_phase(g["phase"] or "General")
    groups = reorder_mythic_last(groups)
    return nb.group(1), int(enc.group(1)), groups


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    results = []
    for arg in sys.argv[1:]:
        for f in sorted(Path(arg).rglob("*.lua")):
            if f.name.startswith("!"):
                continue
            r = parse_file(f)
            if r:
                results.append(r)

    print("-------------------------------------------------------------------------------")
    print("--  NaowhUI_TankReminder_CuratedAbilities.lua -- which journal abilities")
    print("--  BigWigs/LittleWigs itself tracks per boss, grouped by fight phase.")
    print("--")
    print("--  GENERATED by Tools/extract_curated_abilities.py. Regenerate rather than")
    print("--  hand-editing.")
    print("--")
    print("--  Names, icons and descriptions still come from the player's own Dungeon Journal")
    print("--  at runtime (NaowhUI_SmartReminders_Bosses.lua) -- this file supplies only which")
    print("--  spellIDs matter and how BigWigs/LittleWigs itself groups them by phase, read")
    print("--  from their own boss modules (raid and current-tier dungeons from BigWigs,")
    print("--  older Mythic+ pool dungeons from LittleWigs -- same project, same team). Used")
    print("--  with permission (Funkeh, BigWigs developer).")
    print("--")
    print("--  Bosses with no entry here fall back to the full journal listing.")
    print("-------------------------------------------------------------------------------")
    print("local ns = _G.NaowhUITankReminder")
    print("if not ns then return end")
    print()
    print("ns.CURATED_ABILITIES = {")
    for name, enc, groups in results:
        print("\t[%d] = { -- %s" % (enc, name))
        for g in groups:
            phase = g["phase"] or "General"
            ids = ", ".join(str(i) for i in g["abilities"])
            print("\t\t{ phase = %s, abilities = { %s } }," % (lua_str(phase), ids))
        print("\t},")
    print("}")


if __name__ == "__main__":
    main()

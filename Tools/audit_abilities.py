"""Cross-check the damage sheet against community boss-module names, per boss.

Three kinds of finding, and what each means:
  * "sheet ability NOT in module names": the sheet and the modules spell the
    ability differently, or the sheet row is a passive the modules do not
    track. Either way the name-join is blind there, so fingerprint extraction
    and the reference filter may both miss it -- these rows are the manual
    verification list for /nutank tank runs.
  * "sheet has NO rows": the sheet does not cover that boss at all (off-pool
    dungeon, delve or raid). Coverage limit, not an error.
  * Boss-name near-misses (printed alongside) catch the "Nalorakk Den" vs
    "Nalorakk" class of mismatch that would break any future per-boss scoping.

Usage: python audit_abilities.py <nboss_abilities_lua> <module_dir> [<module_dir> ...]
"""

import re
import sys
from pathlib import Path


def main():
    body = Path(sys.argv[1]).read_text(encoding="ascii")
    block = re.search(r"NB\.ABILITIES = \{(.*?)\n\}", body, re.S).group(1)
    sheet = {}
    for m in re.finditer(r"\[(\d+)\] = \{ (.*?) \},\s*--\s*([^:]+):\s*(.+)$", block, re.M):
        boss, ability = m.group(3).strip(), m.group(4).strip()
        kind = "tank" if "tank =" in m.group(2) else "party"
        if "tank =" in m.group(2) and "party = true" in m.group(2):
            kind = "both"
        sheet.setdefault(boss.lower(), {})[ability.lower()] = kind

    mods = []
    for arg in sys.argv[2:]:
        for f in sorted(Path(arg).rglob("*.lua")):
            if f.name.startswith("!") or f.name == "Trash.lua":
                continue
            t = f.read_text(encoding="utf-8", errors="replace")
            mb = re.search(r'NewBoss\("([^"]+)"', t)
            me = re.search(r"SetEncounterID\((\d+)\)", t)
            if not (mb and me):
                continue
            names = set()
            for mm in re.finditer(r"\d{6,9}[,}\]].*?--\s*([^\r\n(]+)", t):
                names.add(mm.group(1).strip().lower())
            mods.append((mb.group(1), int(me.group(1)), names))

    print("%-28s %-6s %s" % ("BOSS", "ENC", "FINDING"))
    for bossname, enc, modnames in mods:
        srows = sheet.get(bossname.lower())
        if not srows:
            near = [k for k in sheet if k[:6] == bossname.lower()[:6]]
            print("%-28s %-6d sheet has NO rows%s" % (bossname, enc,
                (" (nearest sheet name: %s)" % near[0]) if near else ""))
            continue
        for ability, kind in sorted(srows.items()):
            hit = ability in modnames or any(ability in n or n in ability for n in modnames)
            if not hit:
                print("%-28s %-6d sheet %s ability '%s' NOT in module names"
                      % (bossname, enc, kind, ability))


if __name__ == "__main__":
    main()

"""Extract tank fingerprints and event names from community boss modules.

Two module dialects exist and both are handled:

  A. `if duration == 8 or duration == 24 then -- Triple Shot`
     One-decimal durations, ability named in a trailing comment.
  B. `elseif durationRounded == 17 or durationRounded == 29 then -- Mythic
          barInfo = self:WaterJet()`
     Whole-second durations, ability named by the method called on the next
     line(s). The runtime filter matches whole seconds tolerantly, so both
     dialects are emitted in "%.1f" form.

Tank classification, in priority order:
  1. Our curated sheet-derived list, by spell id and then by boss plus ability
     name, since a module often carries the applied aura where we carry the cast.
  2. `[id] = {CL.tank_hit...` renames and `note = CL.tank_hit` entries.
  3. `{id, "TANK"}` / `{id, "TANK_HEALER"}` flags in GetOptions.
  4. `(Tank Hit)` comments beside an id.

Facts only: encounter ids, durations, ability names, spell ids. No source
expression is copied; the output is our own format.

Usage:
  python extract_fingerprints.py <our_abilities_lua> <module_dir> [<module_dir> ...]
Prints stats plus three Lua sections (fingerprints, event names, tank spell
additions) for splicing into the data file.
"""

import re
import sys
from pathlib import Path


DUR_RE = re.compile(r"(?:durationRounded\w*|duration|rounded) == ([\d.]+)")
# `durationRounded == (self:Easy() and 23 or 20)` -- the same ability on two timers, one
# per difficulty. Both are real durations; reading neither is how a tank hit goes missing
# on half the difficulties without anything looking wrong.
EITHER_RE = re.compile(
    r"(?:durationRounded\w*|duration|rounded) ==\s*\(\s*self:\w+\(\)"
    r"\s+and\s+([\d.]+)\s+or\s+([\d.]+)\s*\)")
# Every rotation-counter test on a line, wherever it sits relative to the duration it
# qualifies. Read separately from the duration because a branch can carry more than one
# turn -- Rak'tul takes turns 1 and 3 of a three-way rotation in a single branch --
# and because the two are written in either order.
REM_RE = re.compile(r"(\w+)\s*%\s*(\d+)\s*(==|~=)\s*(\d+)")

# `count40 = count40 + 1` and, one or two lines above it, the duration that gates it.
# A counter is only usable if it advances on exactly one duration: Ziekket runs both its
# 45 and its 50 rotations off a single counter incremented by either, so counting one
# duration's own events would answer for the wrong turn.
INC_RE = re.compile(r"^\s*(\w+) = \1 \+ 1\s*$")
GUARD_RE = re.compile(r"^\s*if (?:durationRounded\w*|duration|rounded) == ([\d.]+) then\s*$")
ONELINE_RE = re.compile(
    r"^\s*if (?:durationRounded\w*|duration|rounded) == ([\d.]+) then (\w+) = \2 \+ 1 end\s*$")


def counter_durations(lines):
    owned = {}
    for i, line in enumerate(lines):
        one = ONELINE_RE.match(line)
        if one:
            owned.setdefault(one.group(2), set()).add("%.1f" % float(one.group(1)))
            continue
        m = INC_RE.match(line)
        if not m:
            continue
        for j in range(i - 1, max(i - 3, -1), -1):
            g = GUARD_RE.match(lines[j])
            if g:
                owned.setdefault(m.group(1), set()).add("%.1f" % float(g.group(1)))
                break
            if "duration" in lines[j]:
                owned.setdefault(m.group(1), set()).add(None)
                break
    return owned


# A trailing comment is usually the ability's name, but it is just as often a note to
# the module's own author: "Stone Breaker timer is 22.5 exactly, dips round down to 22".
# Taking those as ability names hides the real one behind them, and a duration whose only
# name is a sentence can never be classified as a tank hit.
def looks_like_prose(text):
    if len(text.split()) > 5 or "," in text:
        return True
    return not text[:1].isupper()


def norm(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def parse_curated(abilities_lua):
    body = Path(abilities_lua).read_text(encoding="ascii")
    m = re.search(r"ns\.TANK_ABILITIES = \{(.*?)\n\}", body, re.S)
    ids = set()
    for mm in re.finditer(r"\[(\d+)\]", m.group(1)):
        ids.add(int(mm.group(1)))
    # (boss, ability) out of the trailing comments, for the name fallback below.
    pairs = set()
    for boss, name in re.findall(
            r"\[\d+\] = \"[^\"]*\",\s*--\s*([^:\r\n]+):\s*([^\r\n(]+)", m.group(1)):
        pairs.add((norm(boss), norm(name)))
    return ids, pairs


def parse_module(path, curated, curated_pairs):
    text = path.read_text(encoding="utf-8", errors="replace")
    me = re.search(r"SetEncounterID\((\d+)\)", text)
    mb = re.search(r'NewBoss\("([^"]+)"', text)
    if not (me and mb):
        return None
    enc, bossname = int(me.group(1)), mb.group(1)

    # id -> proper name, from any id with a trailing comment. Loose on purpose:
    # a name only has to resolve once somewhere in the file.
    id_name = {}
    for sid, name in re.findall(r"(\d{6,9})[,}\]].*?--\s*([^\r\n(]+)", text):
        nm = name.strip()
        if nm and int(sid) not in id_name:
            id_name[int(sid)] = nm

    # Tank-marked spell ids from the module's own markers.
    tank_ids = set()
    for sid in re.findall(r"\[(\d+)\] = \{CL\.tank_hit", text):
        tank_ids.add(int(sid))
    for sid in re.findall(r"\{(\d+),[^}]*note = CL\.tank_hit", text):
        tank_ids.add(int(sid))
    for sid in re.findall(r'\{(\d+),\s*"TANK(?:_HEALER)?"', text):
        tank_ids.add(int(sid))
    for sid in re.findall(r"(\d{6,9})[,}\]].*?--.*?\(Tank Hit\)", text):
        tank_ids.add(int(sid))

    # The other dialect's tank markers, neither of which is flagged on the ability itself,
    # so nothing above sees them. Missing these is how five bosses -- all three of Den of
    # Nalorakk's among them -- shipped with zero marks and called nothing for a whole
    # dungeon.
    warn_spell = {}
    for local_name, sid in re.findall(
            r"local\s+(\w+)\s*=\s*mod:New\w*Warning\w*\(\s*(\d{5,9})", text):
        warn_spell[local_name] = int(sid)

    # 1. The dedicated "press a defensive" warning type. Unambiguous by construction.
    for sid in re.findall(r"mod:NewSpecialWarningDefensive\(\s*(\d{5,9})", text):
        tank_ids.add(int(sid))

    # 2. A warning raised only behind a tank-role check. An `else` on that check means the
    #    branch is picking per-role INSTRUCTIONS for one shared mechanic, not naming a tank
    #    hit -- Galvazzt splits "stay off the line" from "soak the beam" that way, and
    #    counting it marked a boss that has no tank buster at all. Only a gate with no else
    #    counts.
    for m in re.finditer(r"if\s+self:IsTank\(\)\s+then(.*?)\n(\s*)(else\b|end\b)", text, re.S):
        if m.group(3).startswith("else"):
            continue
        for local_name in re.findall(r"(\w+)\s*:", m.group(1)):
            if local_name in warn_spell:
                tank_ids.add(warn_spell[local_name])

    # Which normalized ability names count as tank hits on this boss.
    tank_names = set()
    for sid in tank_ids | (curated & set(id_name)):
        nm = id_name.get(sid)
        if nm:
            tank_names.add(norm(nm))
    # Names whose id resolves to curated even without a module marker.
    for sid, nm in id_name.items():
        if sid in curated:
            tank_names.add(norm(nm))
    # The curated list carries the CAST spell id while a module routinely carries the
    # applied aura instead, so an id-only join drops real tank busters -- Hunting Leap
    # and Savage Maul on the very boss whose branch comments name both. Boss plus
    # ability name is the fallback key, the same one DAMAGE_NAMES settled on.
    bkey = norm(bossname)
    for cboss, cname in curated_pairs:
        if cboss == bkey:
            tank_names.add(cname)

    # Branches, both dialects. A duration can carry a rotation counter as well --
    # `duration == 40 and count40 % 2 == 1` -- which is the module saying two abilities
    # share one duration and take turns. Captured as (duration, modulus, remainders) so
    # the turns can be told apart later; a bare duration carries no cycle.
    branches = []  # (durations, display_name)
    lines = text.splitlines()
    owned = counter_durations(lines)
    for i, line in enumerate(lines):
        # counter -> (modulus, remainders it claims on this line)
        turns_here = {}
        for counter, mod_n, op, rem in REM_RE.findall(line):
            n, r = int(mod_n), int(rem)
            got = frozenset(range(n)) - {r} if op == "~=" else frozenset({r})
            prev = turns_here.get(counter)
            if prev is None:
                turns_here[counter] = (n, got)
            elif prev[0] == n:
                turns_here[counter] = (n, prev[1] | got)
            else:
                turns_here[counter] = (None, None)

        durs = []
        for a, b in EITHER_RE.findall(line):
            durs.append((float(a), None, None))
            durs.append((float(b), None, None))
        for d in DUR_RE.findall(line):
            fp = "%.1f" % float(d)
            cycle = None
            for counter, (n, rems) in turns_here.items():
                if n and owned.get(counter) == {fp}:
                    cycle = (n, rems)
                    break
            if cycle:
                durs.append((float(d), cycle[0], cycle[1]))
            else:
                durs.append((float(d), None, None))
        if not durs:
            continue
        name = None
        cm = re.search(r"--\s*([^\r\n(]+)$", line.strip())
        if cm:
            cand = cm.group(1).strip()
            # A branch that exists to SUPPRESS an event names nothing; its comment
            # describes the filter, not an ability.
            if cand.lower().startswith("filter"):
                continue
            # A trailing comment that is just numbers or a difficulty tag names nothing,
            # and neither does one that reads as a sentence.
            if re.search(r"[A-Za-z]", cand) and not looks_like_prose(cand) and not re.fullmatch(
                    r"(?:[\d/ .]+)?(?:Mythic|Heroic|Normal)?", cand):
                name = cand
        if not name:
            for j in range(i + 1, min(i + 4, len(lines))):
                # Only the call whose result becomes the bar names the ability; a bare
                # self:EncounterEvent() inside a branch is stage plumbing.
                mcall = re.search(r"barInfo = self:(\w+)\(", lines[j])
                if mcall:
                    method = re.sub(r"Timeline$", "", mcall.group(1))
                    # Prefer the proper name whose normalization matches the method.
                    for sid, nm in id_name.items():
                        if norm(nm) == norm(method):
                            name = nm
                            break
                    if not name:
                        # CamelCase -> spaced words as the fallback display.
                        name = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", method)
                    break
        if name:
            branches.append((durs, name))

    return {
        "enc": enc, "boss": bossname, "id_name": id_name,
        "tank_ids": tank_ids, "tank_names": tank_names, "branches": branches,
    }


def main():
    curated, curated_pairs = parse_curated(sys.argv[1])
    mods = []
    for arg in sys.argv[2:]:
        for f in sorted(Path(arg).rglob("*.lua")):
            if f.name.startswith("!") or f.name == "Trash.lua":
                continue
            parsed = parse_module(f, curated, curated_pairs)
            if parsed:
                mods.append(parsed)

    fingerprints = {}   # enc -> { fp: set(names) }
    event_names = {}    # enc -> { fp: set(names) }
    new_tank = {}       # sid -> (boss, name)
    # enc -> dur -> modulus -> remainder -> set(names), before it is decided whether the
    # cycle survives, plus the durations seen with no counter at all, which veto one.
    turns = {}
    plain_durs = {}
    tank_by_enc = {}

    for m in mods:
        enc = m["enc"]
        tank_by_enc.setdefault(enc, set()).update(m["tank_names"])
        for sid in m["tank_ids"]:
            if sid not in curated:
                new_tank[sid] = (m["boss"], m["id_name"].get(sid, "?"))
        for durs, name in m["branches"]:
            for d, mod_n, rems in durs:
                fp = "%.1f" % d
                event_names.setdefault(enc, {}).setdefault(fp, set()).add(name)
                if norm(name) in m["tank_names"]:
                    fingerprints.setdefault(enc, {}).setdefault(fp, set()).add(name)
                if mod_n is None:
                    plain_durs.setdefault(enc, set()).add(fp)
                else:
                    slot = turns.setdefault(enc, {}).setdefault(fp, {}).setdefault(mod_n, {})
                    for r in rems:
                        slot.setdefault(r, set()).add(name)

    # A cycle survives only when the module tells the whole story about that duration:
    # one counter, every turn accounted for, and no other branch claiming the duration
    # without consulting it. Anything else stays one ambiguous fingerprint, as before.
    cycles = {}
    for enc in sorted(turns):
        for fp in sorted(turns[enc]):
            by_mod = turns[enc][fp]
            if len(by_mod) != 1 or fp in plain_durs.get(enc, ()):
                continue
            n, slots = next(iter(by_mod.items()))
            if len(slots) < 2:
                continue
            # Occurrence i of the duration is the branch for remainder i % n, so the turn
            # order is 1, 2, ... n-1, 0.
            order = [slots.get(r) for r in list(range(1, n)) + [0]]
            if any(t is None for t in order):
                continue
            cycles.setdefault(enc, {})[fp] = [" / ".join(sorted(t)) for t in order]

    # Split each cycled duration into its per-turn keys, in both tables.
    for enc in cycles:
        for fp, order in cycles[enc].items():
            event_names[enc].pop(fp, None)
            if enc in fingerprints:
                fingerprints[enc].pop(fp, None)
            for i, name in enumerate(order, 1):
                key = "%s#%d" % (fp, i)
                event_names[enc][key] = {name}
                if any(norm(x) in tank_by_enc.get(enc, ()) for x in name.split(" / ")):
                    fingerprints.setdefault(enc, {})[key] = {name}
        if enc in fingerprints and not fingerprints[enc]:
            del fingerprints[enc]

    print("-- modules: %d | encounters with events: %d | with tank fingerprints: %d"
          % (len(mods), len(event_names), len(fingerprints)))
    for m in mods:
        if m["enc"] not in fingerprints:
            has = "no tank branch resolved"
            if not (m["tank_ids"] or any(norm(n) in map(norm, m["id_name"].values())
                                         for n in m["tank_names"])):
                has = "module marks no tank hit"
            print("--   uncovered: %s (%d): %s" % (m["boss"], m["enc"], has))

    def esc(x):
        return x.replace("\\", "").replace('"', "'")

    def fpsort(fp):
        base, _, turn = fp.partition("#")
        return (float(base), int(turn) if turn else 0)

    print("\n--8<-- TANK_FINGERPRINTS")
    for enc in sorted(fingerprints):
        fps = fingerprints[enc]
        parts = ", ".join('["%s"] = true' % fp for fp in sorted(fps, key=fpsort))
        names = ", ".join(sorted({esc(n) for s in fps.values() for n in s}))
        print("    [%d] = { %s },   -- %s" % (enc, parts, names))

    print("\n--8<-- EVENT_NAMES")
    for enc in sorted(event_names):
        fps = event_names[enc]
        parts = ", ".join('["%s"] = "%s"' % (fp, esc(" / ".join(sorted(fps[fp]))))
                          for fp in sorted(fps, key=fpsort))
        print("    [%d] = { %s }," % (enc, parts))

    print("\n--8<-- EVENT_CYCLES")
    for enc in sorted(cycles):
        parts = ", ".join('["%s"] = { %s }'
                          % (fp, ", ".join('"%s"' % esc(n) for n in cycles[enc][fp]))
                          for fp in sorted(cycles[enc], key=fpsort))
        print("    [%d] = { %s }," % (enc, parts))

    print("\n--8<-- NEW_TANK_ABILITIES")
    for sid in sorted(new_tank):
        boss, name = new_tank[sid]
        print('    [%d] = "Unknown",   -- %s: %s' % (sid, esc(boss), esc(name)))


if __name__ == "__main__":
    main()

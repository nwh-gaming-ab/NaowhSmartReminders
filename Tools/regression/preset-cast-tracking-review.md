# Preset cast tracking audit

Base: main 1.3.2 (e83f515). Branch: fix/readiness-evidence.
No release, commit, or installation performed for this audit.

Confirmed production-code defects:
- RebuildCastMap watched only activeSlots, while boss/custom reminders select other presets.
- The display/encounter gate unregistered player cast and cooldown inputs between eligible encounters.
- ResyncModel updated only displayed spells.
- ENCOUNTER_END erased known single-cooldown deadlines despite not resetting player cooldowns.

Changes:
- Deduplicated watch list includes current-spec presets, legacy boss/ability lists, and displayed spells.
- Retain existing override mapping and prime charge states when rebuilding the watch list.
- Keep unit-filtered cast and existing cooldown/regen subscriptions while enabled with configured spells.
- Resync the configured watch list and retain cooldown deadlines across boss boundaries.
- Automatic callout logs now include whether the selected spell was tracked and time since its last seen cast.

Verification:
- Six new production-code regressions fail on 1.3.2 and pass after the change.
- The hidden-preset tests simulate Blood DK Death's Advance (48265) and Vengeance DH Fiery Brand (204021),
  spending two charges with another preset displayed. Baseline incorrectly returns one charge; fixed returns zero.
- Includes empty display/boss gate, master off, overrides, legacy spec filtering, and unique resync coverage.
- Existing 13 charge cases and display regressions pass under Lua 5.1.
- All top-level runtime files compile under Lua 5.1. Changed-line style and whitespace checks pass.
- No in-game testing. Fiery Brand remains a suspected live report; its two-charge test is a controlled simulation.

Review and limitations:
- No new frame, OnUpdate, or combat-log subscription. Existing cooldown resync remains coalesced once per frame.
- Cost expands from displayed slots to U unique configured spells for the current spec; cast dispatch is a table lookup.
- Cast tracking deliberately continues between bosses while enabled. Master off still unregisters these inputs.
- This does not rewrite the existing readiness estimates. The audit also found optimistic cold-start, ambiguous
  inactive flags, and cooldown-as-recharge fallback behavior; these remain possible sources of false readiness.
- The fix demonstrates a missing-input failure matching the symptom; without a trace of the failing first-boss
  call, it does not establish that every reported occurrence has this cause.

API contract consulted: Blizzard generated UnitDocumentation (UNIT_SPELLCAST_SUCCEEDED payload),
SpellBookDocumentation (SPELL_UPDATE_COOLDOWN), SpellDocumentation (GetOverrideSpell), and SpellChargeInfo.
Current exported docs mark generic cast events SecretWhenUnitSpellCastRestricted; do not assume that arbitrary
unit spell IDs are readable just because the player-only cast route commonly supplies usable IDs.

## Follow-up: base/replacement IDs (tracking-test2)

Resolved the review finding by discovering aliases before initializing any counters.
Readiness, charge reads, resync, coverage, and diagnostic lookups resolve through one
canonical cooldown key. Existing conflicting counts merge conservatively; cooldown
and last-cast timestamps retain their latest values. Canonical keys are sampled once.

All 10 tracking/alias cases, 13 charge cases, and existing display regressions pass.
The additional cases cover either ID displayed first, repeated map rebuilds, shared
recharge, existing spent counters, and a shared single-cooldown deadline.
Lua 5.1 compilation and changed-line style checks passed.

User supplied an in-game first-boss pass for tracking-test: pre-pull Death's Advance
casts at 07:56:39 and 07:56:41 were recorded, the first Gust produced no callout,
and subsequent callouts had reported available charges. This is evidence for the
original tracking fix. The alias follow-up has automated coverage only so far.
The installed junction now exposes tracking-test2 on reload. Not published.

## Follow-up: partial recharge promoted to full (tracking-test3)

The second user trace records a false call at 08:09:18: running=true, model 1/2,
45s recharge, last cast 38.7s ago. Unlike the missing-cast failure, both casts
were recorded. The remaining inactive-flag shortcut could fill both missing
charges after just one interval, then leave a phantom charge after the next cast.

Removed that full-stack shortcut and its measurement from an ambiguous inactive
flag. Only a readable charge count can replace the count outright; elapsed-time
recovery credits the number of completed intervals, not the maximum stack.

Two added regressions fail on test2 and pass on test3, including the trace's cast
timing with a simulated inactive recharge read at the boundary. That intermediate
read is not present in the trace, so this is a reproduced explanation, not proof
of the exact client's intermediate results. All 15 charge cases, 10 tracking
cases, and display regressions pass. Lua 5.1 compile and style checks pass.
In-game test3 remains unverified. Installed junction loads it after /reload.

## Follow-up: bounded late readiness (tracking-test4)

An early boss-mod warning that finds no ready cooldown now remains pending until
the bar deadline. It rechecks the current binding's eligible spells every 0.1s;
when one is ready, the ordinary aggro, coverage, display and audio path runs again.
Muted winners, repeat suppression and external requests finish the warning.
Errors and disabled voice do not arm retries. Stops (including approximate bars
already waiting), replacement timers and encounter reset cancel through existing
bar aliases. The shared raid scheduler does not gain late retries.

This deadline is the bar's expected cast time, not a detected boss cast end. A
charge returning after bar expiry stays silent. The test3 export ends before the
reported missed warning, so its suggested early-check/recharge ordering is an
inference from earlier timestamps rather than a captured readiness decision.
Readiness still uses the existing conservative model and its documented limits.

Validation: 18 late-ready cases, 15 charge cases, 10 tracking/alias cases and the
existing display regression suite pass. All top-level Lua files compile under
Lua 5.1; the changed-line style gate and whitespace check pass. No live test4
test has been performed. TOC and code stamps agree; the existing game junction
points here. No release has been published.

Cost: no new events, frames or permanent OnUpdate. Each empty warning performs at
most ten candidate-list checks per second while its bar window remains open and
allocates a timer per check. Empty retries do not rebuild slots or refresh the
display timer. Normal successful warnings never retry.

In-game checklist (Blood DK, spec 250):
1. Reload; verify both header stamps read 1.3.2-tracking-test4.
2. Death's Advance unavailable at the early Gust warning, ready before the bar
   expires: expect one call when ready, within about 0.1s plus frame latency.
3. No charge before expiry: expect no Death's Advance call, with trace showing
   the waiting decision and expiry. No call should appear after expiry.
4. Already ready at the early warning: expect the usual single early call.
5. Disable Smart Reminders/voice, stop the bar, or end the encounter while
   waiting: expect no later call. A new pull must not inherit the old warning.
6. With an external fallback enabled, expect that request to finish the warning;
   it must not later issue a personal cooldown call for the same warning.
7. Repeat with Fiery Brand on Vengeance when available; only local simulations
   cover that class so far. Also verify aggro and covered-skip still suppress calls.

Release preparation: user subsequently confirmed in-game testing and requested
a regular 1.3.3 release. Earlier test-status notes above are historical. No
separate live Fiery Brand result was supplied.

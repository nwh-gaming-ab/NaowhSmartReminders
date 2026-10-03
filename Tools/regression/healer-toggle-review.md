# Healer reminder toggle: local test

Branch: `feature/healer-reminder-toggle`, based on released 1.3.5.

- Setup: **Enable Healer Reminders** defaults on. Its account setting is outside
  profiles and shared packs.
- Ability row `...` > Defensive Preset: **Healer Reminder** tags that configured
  preset callout. Tagged rows display **[Healer Reminder]** in the boss list.
- Both reminder editors: **Healer Reminder** marks the authored reminder.
  Untagged reminders remain unchanged; no existing pack was automatically tagged.
- Switching off suppresses tagged displays, sounds and TTS before firing, cancels
  queued tagged callbacks, and clears tagged active regions/glows/defensive callouts.
  Already delivered chat text or one-shot speech/audio is not retracted.
- Switching on permits subsequent triggers; cancelled callbacks are not replayed.
- No new polling, combat API reads, event registrations, or release version changes.

## In-game checks

1. Fully restart WoW after changing the addon junction. Confirm the new switch
   appears beside Smart Reminders on Setup and starts enabled.
2. Create two reminders on the same trigger: mark one Healer Reminder and leave
   the other unmarked. Test once with the switch on, then off. Check visual,
   sound and TTS output. Repeat with an authored preset/defensive reminder.
3. Schedule a delayed tagged reminder, turn the switch off, then on before it
   would fire. The cancelled reminder must stay silent; the untagged one fires.
   Repeat with BigWigs timer, pull and stage reminders where available.
4. While a tagged raid display or glow is visible, turn the switch off. It should
   disappear while an untagged display on the same anchor remains visible.
5. Disable healer reminders, switch profiles and back, reload, and import a
   pack into a separate profile. The account switch stays off.
6. Export/import a reminder pack and reopen both reminder editors. The Healer
   Reminder tag must survive. Confirm that clearing the checkbox restores the
   reminder even when the master healer switch is off.
7. Repeat relevant triggers during an encounter and check for Lua errors.

## Offline evidence

All 13 regression suites passed. Runtime modules compile under Lua 5.1.
Tests cover preference defaults/persistence, pack validation/round-trip, editor
save, callback validity, cancellation, selective cleanup, and existing profile,
charge, countdown, preset, and setup behavior. Two legacy harnesses use Lua 5.4;
all production code and the new healer suite were checked with Lua 5.1.
Client rendering, restricted combat and multi-addon behavior still need the
in-game checks above. No in-game results or screenshots are claimed yet.

## Curator workflow for Robin's packs

1. Review each configured callout, not just the boss mechanic. Mark a callout
   when its instructions/preset are specifically for healer cooldowns.
2. Leave personal defensives and mechanics useful to everyone untagged.
   A boss spell can legitimately have both kinds of callout on different specs.
3. Review the tagged ability rows and the authored reminders before exporting.
   A linked authored reminder is independent of the ability's preset callout:
   tag it separately when its own instructions are healer-specific.
4. Test the same encounter setup with the account switch on and off. Tagged
   prompts should stop; ordinary prompts should continue.
5. Export the reviewed pack. Tags travel with bindings and reminders; the
   receiver's account preference does not. Repeat the review for newly added
   callouts; no automatic role/spell-name classifier is used.

Additional test: mark Frost Overload through its ability row's ... menu, Save,
and confirm the list label. With the healer master switch off, Test and live
boss-mod triggers should stay silent for that configured preset callout.
Verify another encounter/spec's untagged callout still works. If using Blizzard
Timeline audio, check tagged sound suppression across encounter and profile
changes as well.

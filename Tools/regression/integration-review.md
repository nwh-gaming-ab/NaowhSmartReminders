# Exboss trash and debuff sound test build

Based on released 1.3.6. Branch: feature/exboss-trash-aura-alerts.
Not released. Existing healer/message fixes are included through main.

## Implemented

- Trash & Debuffs page, with profile/spec rules, explicit healer tags and pack sharing.
- Exboss trash predictions: spell/instance filters, 0-30 second warning lead,
  custom icon/text/sound/TTS or an existing defensive preset's available spell.
- Preset rules remain silent when no configured spell is available.
- Native aura sound registration for the player or four party slots, supporting
  application, stack increase and removal. Uses configured file sounds, not TTS.
- Limit 32 rules per spec. No default rules or automatically classified mechanics.

## Exboss compatibility contract

Read-only source inspection matched local EXBoss/ExBossEngine/Scheduler.lua to
the installed file by SHA256. The adapter post-hooks RegisterTrashLocalTimer and
_RemoveActiveTimerByID and reads GetActiveTimers. The underscore removal method
is an internal compatibility dependency; this is not a documented stable Exboss
extension API. Capability checks cannot guarantee compatibility with future builds.

No Exboss source was copied or modified. No polling or enemy aura/cast inspection
was added. The simpler five-seconds broadcast lacked full update/stop coverage.
Instead, provider timer identities own scheduling and cancellation. Data must be
accessible/nonsecret. A timer is revalidated at fire time. A prediction already
delivered is not replayed by updates/settings refresh; removal and a new timer
permit a new notification. Handles use Smart Reminders' existing tracked timers.

Exboss timers predict ability readiness. They do not prove a cast will start,
that the inferred spell identification is correct, or that the player is targeted.

## Aura API contract and limits

C_UnitAuras.AddAuraSound(trigger, info) and RemoveAuraSound(id), documented in
Blizzard_APIDocumentationGenerated/UnitAuraDocumentation.lua. UnitAuraSoundInfo
contains unitToken, spellID, soundFileName/soundFileID, outputChannel; the runtime
uses soundFileName. UnitAuraSoundTrigger supplies Added/ApplicationsIncreased/Removed.
Registration IDs have no Lua fire callback. Do not convert these to arbitrary
reminder triggers or use rendered output to recover protected aura information.

This build conservatively defers registration/removal while InCombatLockdown or
an encounter is active. Previous sounds can remain active while a change is pending,
including a healer opt-out or profile change. The options page explicitly reports
this. Specific client registration restrictions and each chosen debuff still need
live verification; offline mocks cannot establish WoW security behavior.

## Remaining targeted-cast investigation

PlayerIsSpellTarget returns a secret boolean. No universal targeted audio trigger
is implemented. The previous isolated visual prototype and Exboss targeting trace
remain separate. Mechanics using readable encounter-warning metadata plus predicted
windows need individual live evidence, including overlapping warnings and false
positives, before becoming supported triggers.

## Test procedure

Fully restart WoW after loading this checkout: two TOC files were added.
Open Trash & Debuffs. Select a dungeon, then an ability. Configure Cast Settings,
Text & Test Settings and Voice Settings, then Save. Existing rules, including
all-instance filters, remain available under Saved reminders.
Preview validates output only, not provider delivery. During a pull, verify lead,
resync, cancellation, multiple mobs, repeat casts and toggling/profile/spec changes.

For a debuff rule, choose a known aura ID, application/removal/stack event, unit,
and installed sound file. Save before combat. Verify registration status then test
the actual aura. Disable during combat: expect pending status and old sounds until
combat/encounter exit. Confirm removal afterward and persistence after reload.

Export/import to a fresh profile; confirm rules, tags, preset references and sounds.
Confirm a missing optional Exboss addon is reported without breaking other reminders.
Check BugSack and taint logs on the actual Retail client. No client results or
before/after screenshots are claimed by this build.

## Offline evidence

15 regression suites pass, including the new integration lifecycle/security-boundary
mock tests, pack validation and options-save tests. Runtime syntax checked with Lua
5.1. Two legacy harnesses use Lua 5.4. Released 1.3.6 libraries were staged locally;
the tracked embeds.xml was preserved. Final client rendering and API restrictions
cannot be proved with these mocks.

## Dungeon and ability layout (local test1)

Code build: 1.3.6-trash-layout-test1. The interface uses Naowh colors and contains
no Exboss branding; the optional Exboss scheduler/data dependency remains. This
is a configuration redesign, not a replacement prediction engine. Catalogue data
is read from the installed provider without copying or modifying it. Challenge
dungeon IDs are mapped to instance IDs through unambiguous static map names.
Unmapped/ambiguous entries are omitted rather than creating all-instance rules.
The installed data resolved all 8 dungeons and 136 unique dungeon/spell entries.

Preset labels sit above 268px dropdowns. Dungeon selection and a scrollable
ability list sit left of the three settings panels. Existing rules are preserved;
saving selects the resulting rule, so repeated saves update it. Debuffs retain
explicit aura IDs because a cast ID is not necessarily its debuff ID.

All 15 offline regression suites pass after the redesign, plus Lua 5.1 syntax.
Catalogue tests cover challenge/instance IDs, deduplication, read-only access,
missing providers and ambiguous mapping. UI mocks cover selection, save, repeat
save, preview, deletion, wide preset controls and stale profile/spec rejection.
These are not rendered-client tests. No new after screenshot or in-game result
is available yet. Reload the linked checkout and verify layout, full preset
labels, ability selection, sound preview, save/reopen and live timer delivery.

## Bundled debuff voices (local test1)

Code build: 1.3.6-debuff-voices-test1. Sound choices now include Voice: Dispel me,
Voice: Move out and Voice: Use a defensive (English). These are bundled synthetic
speech files, not live text input. Existing sound keys and imports are preserved.
Built-in paths resolve without LibSharedMedia; external sounds retain their
existing lookup and cache behavior. Media/Voice is not excluded by .pkgmeta.
Tools/generate-voice-clips.ps1 records the reproducible generation procedure.

Focused verification: Lua 5.1 syntax, all 15 integration cases, including actual
bundled file paths/native aura registration with no SharedMedia, and decoding all
three mono Vorbis files (1.21-1.50 seconds, about 26 KB total). In-game audio and
volume remain unverified. Restart WoW to ensure the new files are discovered,
choose a Voice sound in Debuff Sound, use Test Reminder, then Save outside combat.

## Preview TTS volume correction

Build 1.3.6-preview-tts-test1: reminder TTS now uses the addon's Voice Volume,
matching its main spoken callouts, instead of Blizzard chat TTS volume. This fixes
an inconsistent setting source; the exact cause of the user's silence is not yet
confirmed in game. Keep Blizzard's documented speech rate and five-argument API.
Preview reports missing voices, zero addon volume and synchronous playback errors
in chat. The editor explains when a test has neither speech nor sound enabled.

All 15 suites pass, including new custom-text/preset TTS argument tests with muted
chat volume, addon mute preservation, no voices and playback exceptions. Updated
the old sound-cache fixture to include the bundled-voice locals introduced earlier.
Live audio still needs verification after /reload.


## Final PR validation (2026-09-15)

All 15 regression scripts passed. Most run with Lua 5.1; the display/minimap harnesses use Lua 5.4 load syntax. Top-level runtime files compile with Lua 5.1. Stoneform voice was user-tested in combat and in a dungeon. New message-row tests, spacing and trash-cycle fixes still need live client verification; no after screenshots are available.

The scheduler adapter now also post-hooks _AdvanceTrashFixedCombatTimeline. Delivery records use per-spell nextSpellAnchorAt when available, fixed-timeline deadlines for recurring schedules, and a deadline fallback when no anchor is exposed. Corrections inside an already-announced cycle remain suppressed; later cycles can notify again. Invalid edited aura IDs reach validation as nil and cannot replace existing saved rules.

The previous sections document intermediate test builds and their then-current verification, not additional current compatibility guarantees.

# Changelog

## 1.4.26

### Changed
- **Skip When Already Covered is now on by default.** If a defensive of yours is already
  running when a callout fires, it stays quiet instead of calling for a second one on top.
  This includes profiles you already have: the setting is switched on once when you load
  this version. If you had turned it off on purpose, turn it off again under Smart Reminders
  and it will stay off.
- Skip When Already Covered now covers trash callouts too. Pulling a second pack while a
  defensive from the first is still running no longer calls for another one.
- Importing an older shared profile no longer switches Skip When Already Covered back off.
  Profiles shared from this version on keep whatever the sharer chose.

### Fixed
- Callouts bound to their own cooldown preset no longer go silent for a whole fight when the
  preset selected for the spec, or for that boss, has nothing this character can cast. This
  is what stopped Triple Shot on Rav'i calling anything on a Protection Paladin.
- `/nutank` no longer blames a preset that works. It now checks the selected preset itself,
  and says so plainly when a spec has no preset at all.
- A BigWigs message reminder set up while DBM was running (or the other way round) now fires.
  It was silencing the normal callout for that ability and then calling nothing.
- Callouts are spoken at your own text-to-speech rate instead of a fixed one.
- Bosses that become targetable partway through a fight are recognised straight away.

### Performance
- Less work per combat event and per callout, and a smaller hitch on the pull while boss
  sounds are registered.
- `/nutank speaktime` reports how long callouts take to pick and to speak, for stutter reports.

## 1.4.25

### Fixed
- The Trash tab now says outright that trash cooldown alerts need ExBoss. Without it the
  tab showed an empty dungeon list and "No enabled trash rules for this instance and
  spec", which reads as nothing being set up rather than the timer engine being absent.
  Both the ability list and the timings behind every alert come from ExBoss, so nothing
  on the tab can fire without it.
- The ability list on the Trash tab now says why it is empty when it has nothing to show.
  The line written for that case could not be reached, so the list sat blank instead.

## 1.4.24

### Changed
- When a personalized profile is refused because it belongs to another account, the message
  now names both BattleTags: the one the pack is signed to and the one you are logged in to
  Battle.net as. Reading them side by side shows you whether the tag saved on naowh.gg has a
  typo in it, which the old wording gave you no way to tell.

## 1.4.23

### Fixed
- A personalized profile from naowh.gg no longer refuses to import when your BattleTag is
  saved on the site with different capitals than Battle.net holds. `Silkytouch#1976` and
  `SilkyTouch#1976` are the same account, and the check now treats them that way. It was
  reporting "this pack is licensed to a different Battle.net account", which pointed at the
  wrong problem entirely, and the 30 day change lock meant you could not correct it yourself.

## 1.4.22

### Added
- A pack shared with `/nutank share` is now named **Naowh** by default, and
  `/nutank share <name>` names it whatever you type. That name is what the profile ends up
  called when someone imports it.
- Importing a pack whose name you already have offers to **replace** that profile instead of
  landing another copy beside it. Off by default, and only offered when the name is actually
  taken, so nothing is replaced without choosing it. Replacing clears the profile first, so
  none of the old contents survive underneath. "Default" is never replaced.

### Changed
- A personalized profile from naowh.gg can no longer be exported or shared onward, including
  through `/nutank share`, and merging one marks the profile it was merged into. Packs that
  did not come with a licence are unaffected, so handing work back to a curator still works
  exactly as before.
- The refusal you get when exporting a profile built on someone else's pack no longer names
  the command that bypasses it.

## 1.4.21

Housekeeping only. No gameplay or behaviour changes from 1.4.20.

### Added
- LICENSE.md, covering this addon and the libraries it embeds.

## 1.4.20

Built on 1.4.18. The 1.4.19 alpha is not included: that work is still being fixed.

### Added
- naowh.gg can hand out a personalized, signed copy of a curator's Reminder Pack, bound
  to the recipient's own BattleTag so it cannot be freely redistributed. The signature is
  checked with a real RSA-2048 verification on import. Ordinary friend-to-friend and
  self-export packs are completely unaffected.
- Russian and German locale foundations, with the English strings split into
  Locales/enUS.lua. Anything untranslated falls back to English.

### Note
- Personalized packs from naowh.gg need this version or newer. Earlier builds do not know
  about the licence appended to the string and report it as damaged on import.
- **If you ran the 1.4.19 alpha**, it rewrote your saved trash alerts one way and this
  build does not carry the code that reads them back. Those alerts will stop firing, with
  no icon and no sound. Restore the NaowhUI_SmartRemindersDB.lua backup you took, or set
  a defensive preset on the affected alerts again.

## 1.4.19

**Never released. Superseded by 1.4.20, which is built on 1.4.18.**

**Alpha. Please test this before relying on it in a key.**

This build converts your saved trash alerts when it loads: any alert still carrying the
old generic "Use a defensive" line is rewritten to a blank one. Nothing is deleted, but
the conversion is one way. If you install this and then go back to 1.4.18 or earlier,
every converted alert stops firing, with no icon, no sound and no error to tell you. Back
up NaowhUI_SmartRemindersDB.lua before you load it if you want a way back.

### Changed
- A trash alert with no defensive preset chosen now calls out whichever preset the spec
  has active, instead of saying a generic "Use a defensive". That phrase was never typed
  by anyone: the page has had no text box since these moved from free text to presets, so
  every alert switched on from the dungeon list carried it.
- An alert whose preset belongs to another spec now falls back to the active preset as
  well. It used to go silent. Copy From Spec and shared packs both produce this.
- The Defensive preset dropdown reads "This spec's active preset" where it read "None".
## 1.4.18

### Fixed
- A trash alert or boss reminder bound to a defensive preset now stays quiet when nothing
  on that preset is ready. It was still playing its sound and speaking its line -- "Use a
  defensive", on a rule that had never been given one of its own -- over icons that had
  already gone dark for the same reason. A reminder carrying only custom text is
  unchanged and still fires every time.

## 1.4.17

### Fixed
- Picking a dungeon by name while the Instance ID field was showing saved the id last
  typed in that field instead of the dungeon chosen, then snapped back to it.
- Choosing a dungeon no longer redraws the page. On an alert too incomplete to have saved
  yet, that redraw threw away the spell id, name and switches already typed into it.
- The Instance ID field no longer pushes the Unit dropdown past the bottom of its panel.

## 1.4.16

### Changed
- A debuff alert names the instance it belongs to. "Every dungeon or raid" is gone from
  the list, and a new alert starts on the first dungeon instead of everywhere. An alert
  already saved for everywhere keeps firing everywhere and shows as "Instance 0" until you
  rescope it; "Another instance (by ID)" still accepts 0 if that is what you want.

## 1.4.15

### Fixed
- A debuff alert can be scoped to an instance the dungeon list does not carry again. That
  list comes from ExBoss and holds only dungeons it has trash data for, so without ExBoss
  it is empty and nothing could be scoped at all, and a raid was never in it. The list
  gains "Another instance (by ID)", which brings the id field back.
- A second boss callout arriving while the first is still on screen no longer keeps the
  earlier cast's target name under it.
- The target name no longer overlaps the callout at small Text Size settings. It is drawn
  at a fixed size while the row spacing follows Text Size, so the two could collide.

## 1.4.14

### Fixed
- The target name on a boss cast sat a full row clear of the callout, with an empty row
  between them, because the row it used belongs to a reminder's own text and that text is
  not shown for a boss-mod callout. It could be drawn and still be impossible to find. It
  now takes the row directly beside the callout, and moves out one only when a reminder is
  actually using that row.

## 1.4.13

### Removed
- Show What Is Incoming. Its spoken half went in 1.4.11 as a second voice over BigWigs, and
  the line on its own did not earn a row on the alert. The label no longer travels from the
  boss mod to the display at all, and the rows that moved to make space have moved back.

## 1.4.12

### Removed
- Show Target on Trash Casts, and everything behind it. A trash cast was matched to the
  rule that predicted it by spell id, and the client keeps that id secret for every unit
  that is not you or your pet, so the match never succeeded and the repeat never once fired
  in a dungeon. The per-rule Show target on cast and Sound on cast switches go with it.
  Rules and packs already carrying those fields keep them untouched.

### Changed
- The diagnostic trace says when a boss cast names somebody even with no alert on screen to
  put the name on. One traced dungeon now answers which abilities carry a target name at
  all, which previously took a pull per guess.

## 1.4.11

### Changed
- Debuff Alerts pick the instance they apply to by name, from the same dungeon list the
  Trash tab uses, instead of a typed Instance ID. An id the list does not carry keeps an
  entry of its own, so an alert set for a raid is not quietly moved to everywhere.

### Removed
- Say What Is Incoming, one release after it arrived. BigWigs already announces its own
  warnings, so this was a second voice saying the same thing a beat earlier.

## 1.4.10

### Added
- Say What Is Incoming, on Setup. Speaks the boss mod's own name for the ability just
  before the callout: "Frontal", then "Vampiric Blood". Said on its own rather than folded
  into the callout, so it still works when your callout is a sound file instead of speech.
  The bar's count is left off what is spoken -- "Frontal", not "Frontal one".

### Fixed
- The diagnostic trace said "no name, asked if it is on you" for a cast carrying no target
  name, describing a marker that was removed in 1.4.7. It reads "cast names nobody" again.

## 1.4.9

### Fixed
- Show What Is Incoming showed nothing on DBM. DBM identifies a timer by a numeric id
  rather than by its text, and the line was using that id; the message DBM sends alongside
  it is the label now. BigWigs was unaffected, since its identity is the bar text.
- The alert no longer leaves an empty row between the callout and the target name when the
  incoming line is switched off.
- Show Target on Boss Casts takes effect the moment you tick it, instead of waiting for the
  next pull. Its trash counterpart already did.

## 1.4.8

### Added
- Show What Is Incoming, on Setup. The alert gains a line naming the ability the boss mod is
  timing -- "Frontal", "Debuffs", "Boss Buff" -- so it says what is coming as well as what
  to press. The name is the boss mod's own bar text, which arrives as ordinary text beside
  the timer, so nothing is guessed and nothing restricted is read. Only for reminders driven
  by a BigWigs or DBM timer, since that is where the name comes from. Off until you ask.

## 1.4.7

### Removed
- Mark Me When I Am Targeted. It could never have worked. The game answers "is this cast on
  you" as a protected value, and the only way to put that on screen is a call the game
  refuses from addons, so it failed silently from the day it shipped in 1.4.1. Nothing is
  really lost: when a cast does carry a target name, that name is yours when it is on you.

### Changed
- The diagnostic trace now says why a boss cast did or did not put a name up: the switch is
  off, nothing was on screen to write on, or the cast names nobody.

## 1.4.6

### Fixed
- The rule editor no longer reads Enabled for a trash ability nothing is saved for. It was
  showing a would-be rule's defaults while that ability's own switch in the list correctly
  read off, and the missing Remove button was the only sign nothing was there. Editing a
  field on an ability you have not switched on now creates it disabled, which is what the
  editor in front of you says it will do.

## 1.4.5

### Added
- A boss cast puts the target's name on the reminder that is already on screen. The client
  will not say what a boss is casting, so a reminder could never be matched to the cast it
  warned about; whether a cast names somebody is the one thing it does answer plainly, so
  the warning already showing picks the name up when the ability goes out. Needs Show
  Target on Boss Casts, on the Dungeon Bosses or Raid Bosses tab. Boss units only: the name
  belongs to whatever is casting at that moment, which on a boss is the mechanic you were
  warned about and in a trash pack would be a guess.

### Changed
- The Trash dungeon list only offers Every dungeon when there is a saved rule no dungeon in
  the catalogue accounts for, instead of always carrying an entry that opens an empty list.

## 1.4.4

### Changed
- Show Who Is Targeted is now two switches, each on the page that owns the reminders it
  affects. Show Target on Boss Casts sits on the Dungeon Bosses and Raid Bosses tabs,
  Show Target on Trash Casts on the Trash tab, and both start off. Mark Me When I Am
  Targeted stays on Setup, since it applies wherever a name shows. The old setting is not
  carried over, so if you had it on, tick the one you want.
- Debuff Alerts are grouped by the instance each one is set for, under headers that fold
  shut. Alerts set for every dungeon or raid get their own group at the bottom. Folding a
  group leaves whatever is selected inside it open in the editor.

### Fixed
- A trash callout bound to a preset names every cooldown in the set, not just the one that
  won the pick. With Call Together ticked on Anti-Magic Shell and Death's Advance it said
  "AMS"; it now says "AMS and Death's Advance", the same line the boss callout has always
  spoken for a set.
- The Trash and Debuff Alerts lists stay where you left them. Picking a rule rebuilds the
  page, which sent the list back to the top, so anything below the fold scrolled away the
  moment you clicked it.

## 1.4.3

### Changed
- The spec list in Merge a Profile In now matches the one in Import: rows grouped by
  class and coloured by it, read as "Protection (Tank)" rather than "Protection
  Warrior", with Select All and Deselect All beside the heading.

## 1.4.2

### Changed
- Show Who Is Targeted and Mark Me When I Am Targeted now start off rather than on. Both
  are in Setup, and the trash callout repeat is behind them too, so no part of the cast
  target display shows up until one of them is ticked.

### Fixed
- The Merge a Profile In window sizes itself to the string you paste. A profile covering
  a lot of specs pushed the last rows and both "Also take their..." switches out past the
  bottom of the window, with Merge and Cancel sitting over the middle of the spec list.

## 1.4.1

### Added
- Boss casts that name a player now show that player's name on the alert in class colour,
  with YOU beside it when the cast is on you. Two switches in Setup to turn either off.
  Display only; the game does not let an addon read who was named, so the voice cannot
  follow it.
- Trash callouts get the same treatment. A trash rule warns ahead of the cast, so there is
  nobody to name yet when it fires; it now comes back at the cast itself carrying the
  name. Only for abilities that name a target, and silent unless you ask for it. Show
  target on cast and Sound on cast, per rule, on the Trash tab.
- Copy From Spec on the Debuff Alerts tab, for moving debuff alerts between specs.
- `/nutank share` exports your profile even when it came from someone else's pack, for
  handing changes back to whoever maintains it. The pack is marked so they can see it is
  theirs coming back.

### Changed
- Trash Alerts and Debuff Alerts, renamed from Trash & Debuff Alerts and Debuff Sounds.
- Each Copy From Spec now moves only its own kind. The trash one used to drag debuff
  alerts across with it.
- No more 32 rules per spec limit on trash and debuff rules.
- Trash and debuff rules save as you change them. The Save button is gone.
- The rule editor is one page in two columns instead of three tabs.
- Dropped the custom text field. A preset writes the callout line.
- The Trash list no longer repeats the dungeon name under the dropdown that names it.
- BIGWIGS/DBM MESSAGES is now BOSS REMINDERS, with an Add Reminder button. Cast triggers
  live in that editor too, so naming it after messages hid half of what it does.

### Fixed
- Remove no longer overlaps Test in the rule editor.

## 1.4.0

### Added
- Merge a Profile In, on the Profiles tab. Paste a string somebody else maintains, tick
  the specs you are accepting, pick which of your profiles it goes into, and it merges
  rather than landing beside them. A ticked spec is taken whole, lists, bindings and
  trash rules together. Nothing outside the ticked specs can move, which matters because
  a contributor usually works in a copy of the whole profile they were given. Per-boss
  reminders come across only for the specs they record. Raid reminders, callout lines and
  their display and sound settings record no spec and are left behind unless asked for.
- Shadowmeld joins Stoneform as a cooldown-gated debuff voice. Pick it as the sound on
  a debuff rule and it stays silent while Shadowmeld is on cooldown, unknown, unusable
  or you are dead. The two gate independently, so one being down does not quiet the
  other.
- New voice clips for both racials, supplied by Naowh, listed as "Stoneform - Naowh" and
  "Shadowmeld - Naowh" to match his other sound files.

### Fixed
- A spoken callout uses the name you gave the spell. Renaming Vampiric Blood to Vamp
  renamed the label beside the icon but not what was said, so the two channels
  disagreed about the same spell.

### Changed
- The options window is two levels: Smart Reminders, Custom Notes and Profiles across the
  top, with Setup, Cooldown Presets, Dungeon Bosses, Raid Bosses, Trash and Debuffs under
  Smart Reminders. Custom Notes is dimmed and says what it will do.
- The Trash page shows one dungeon at a time as a collapsible section, with the spell icon
  and a switch on every ability. Rows are half their old height, so a dungeon's abilities
  fit without scrolling the list.
- Debuff sounds have their own tab beside Trash. They answer to an aura rather than a
  dungeon, and were previously reachable only through a bucket at the foot of the trash
  list. Each page keeps its own selection.
- Copy From Spec sits beside the page heading, since it acts on the whole spec rather
  than on the selected dungeon.
- Trash and debuff callouts draw on the defensive alert itself, replacing what is in it,
  instead of putting a second icon and line on screen beside it. A rule with a preset
  rebuilds the alert's slots from that preset; a rule with only custom text takes the
  alert's own text row and puts the slots away, so a defensive left there by the spec's
  preset no longer shows beside the line. Each rule keeps its own sound and Speak
  Callout setting.
- The separate Ability Reminder display is gone. Every reminder now draws on the
  defensive alert, so there is one placeable display instead of two showing the same
  kind of callout in two different styles. Its Reset Ability Reminder Position button
  and its own text colour setting go with it; the alert's Defensive Text Color now
  covers both the slot labels and the authored line.
- Every trash ability row carries a switch, reading off until a reminder exists behind
  it. Turning one on writes the rule the editor would have written and opens it.
- Reminder icons carry the 1px black edge the priority slots already had.
- Callout text is now Custom text, and it greys out while a preset is supplying the line.
  What is typed there is kept and returns when the preset is cleared.
- Text in the trash editor's input boxes is inset rather than sitting on the border.
- The Trash and Debuffs pages fit the options window, so the page itself no longer
  scrolls. The editor's Cast, Text & Test and Voice settings sit behind tabs instead of
  stacked panels, Save and Remove moved onto that row, and the page reports the height
  it actually draws rather than a fixed guess. The ability list keeps its own scrollbar.
  Switching tab shows a different panel and nothing else, so a preset chosen or text
  typed and not yet saved survives the switch. Save, Test and Remove sit above the tabs,
  since they act on the whole rule rather than on one group of its settings.

### Validation and limits
- All 18 offline regression suites pass; runtime Lua syntax checked.
- This is a large UI rework and none of it has been verified in the client. The window
  layout, the split Trash and Debuffs pages, the single reminder display and both new
  dialogs are offline-tested only.
- The two racial voice clips are installed and wired but have not been heard, and their
  encoding is unverified.
- Showing who a boss cast is aimed at is not in this build. It is display only and
  cannot be meaningfully tested outside an instanced pull, so it ships on alpha first.

## 1.3.9

### Added
- Importing a single-profile pack can point every character on the account at it, including
  characters logged into later, instead of leaving each alt to be switched by hand. The
  toggle names how many characters it will move and is on by default.
- Copy From Spec on the Trash & Debuff page brings another spec's trash and debuff rules
  across, leaving anything already saved here alone and saying what did not fit the
  32-rule limit.

### Fixed
- Setting an account-wide profile now turns per-spec profile switching off, instead of
  every alt being moved back to the previous profile on its next login. Spec choices are
  kept and come back if switching is turned on again.

### Validation and limits
- All 17 offline regression suites pass; runtime Lua syntax checked.
- User confirmed the account-wide import in game, which is how the per-spec switching
  conflict was found. That fix and the trash rule copy are not yet client verified.
- Copied trash rules name the spells the source spec casts. Copying across classes is
  allowed and warned about rather than blocked.

## 1.3.8

### Added
- Bar callouts and BigWigs/DBM message reminders run side by side on the same ability:
  bars keep the ability's own preset and warning time, messages fire the message
  reminder's preset.
- Copy From Spec brings BigWigs/DBM message reminders across with the abilities, remaps
  their preset to one this spec owns, and counts them in the spec picker.

### Fixed
- The ability Test button tests the bar callout instead of refusing when the ability also
  has a message reminder, and points at that reminder's own Test.
- A message reminder is no longer muted by the repeat window when the bar callout for the
  same ability just named the same defensive.
- A reminder saved under DBM's own spell id is matched against the BigWigs key it is
  normalised to, instead of both callouts firing for one message.
- The Setup page counts message reminders when deciding whether this spec has anything
  set up, so a spec whose whole setup is reminders no longer reads as empty.

### Validation and limits
- All 16 offline regression suites pass; runtime Lua syntax checked.
- User confirmed in game. Both callouts share one reminder frame, so when a bar callout
  and a message land close together the later one replaces the display.

## 1.3.7

### Added
- Trash & Debuffs setup with profile/spec rules, EXBoss readiness predictions, preset selection, and pack sharing.
- Native player/party aura sounds and bundled English voices, including Stoneform calls gated by racial readiness.
- Test buttons for individual BigWigs/DBM message reminders.

### Fixed
- Reused and recurring trash timers can notify on later cooldown cycles without replaying same-cycle corrections.
- Invalid debuff spell and instance IDs are rejected instead of silently retaining previous values.
- Message-only abilities direct tests to their message rows instead of reporting missing talents.
- Improved ability-picker spacing, moved external-call help above its toggle, and colored the Healer label green.
- Reminder TTS uses the addon voice volume and reports preview failures.

### Validation and limits
- All 15 offline regression suites pass; runtime Lua syntax checked with Lua 5.1.
- User confirmed Stoneform voice in combat and a dungeon. New repeat-cycle fixes, message tests, and UI layout still need client verification; after screenshots are unavailable.
- EXBoss integration predicts readiness, not confirmed casts or targets, and depends on inspected internal scheduler methods.
- Native aura registration changes defer during combat/encounter restrictions. No specific-bleed icon or personal-target Shadowmeld voice is implemented.

## 1.3.6

### Added
- Account-wide Enable Healer Reminders switch in Setup, enabled by default.
- Healer Reminder tagging for ability preset callouts and authored reminders.
  Tags travel with shared packs; each player's opt-out stays personal.
- Turning healer reminders off cancels their pending alerts and hides their
  active displays. Existing reminders remain untagged until a curator marks them.

### Fixed
- BigWigs messages containing protected target text can trigger reminders using
  their readable spell key, including Thunder and Lightning on Adderis and Aspix.
  Protected text is discarded; this does not add player-target detection.

### Validation
- All 13 offline regression suites pass; runtime syntax checked with Lua 5.1.
- Boss-message audit passed 1,980 synthetic dispatch checks across 990 numeric
  module/key pairs. New message regression cases cover cancellation and counters.
- Live encounter validation and screenshots for these changes are outstanding.

## 1.3.5

### Fixed
- Restore the settings preview after switching profiles, including switching back
  from profiles with the icon or master switch disabled.
- Cancel stale raid reminders after deletion, replacement, disable, profile changes,
  or encounter changes. Two reminders sharing a boss bar can both fire.
- Handle early boss-mod broadcasts, exact bar cancellation, and delayed callouts
  when a bar identity is reused.
- Recover sound lookup when SharedMedia loads late, invalidate cached sounds on
  registration, and clear timeline sounds when their settings change.
- Validate nested imported settings before modifying profiles, preserve supported
  legacy shapes, and correct account-default fallback when deleting profiles.
- Keep the alert frame from overwriting the addon's global namespace.

### Performance
- Cache sound lookups, coalesce settings and spell refreshes, reuse dialog controls,
  and prune observations outside encounters.
- Reuse the main Setup page's controls and rebind their profile callbacks. Dynamic
  boss/profile editor frame growth is not fully addressed by this change.

### Validation
- All 12 offline regression suites pass under Lua 5.1, including 38 recovery cases,
  profile-preview restoration, real serializer round trips, and Setup control reuse.
- The tester reported all requested in-game checks passed after loading recovery.2.
  No exact client build, screenshots, profiler capture, or taint log was supplied.
- Combat CPU improvement and universal taint-free behavior are not claimed.

## 1.3.4

### Fixed
- Preserve charge counters across temporary API changes and avoid crediting a
  completed recharge twice, preventing false ready calls for charge abilities.
- Restore Feint charges when recharge data is unavailable and disregard its old
  inferred recharge estimate that could leave reminders silent for minutes.
- Keep delayed message reminders through unrelated settings refreshes and cancel
  them when their reminder is disabled, deleted, or replaced.
- Handle boss messages emitted at encounter start before setup finishes.

### Added
- Opt-in BigWigs/DBM message triggers with a delay and defensive preset selection.
  Existing timer-bar bindings remain for abilities without an enabled message reminder.
- BigWigs ability selection and a single-page reminder editor. Time-in-combat
  trigger creation is removed.
- Bounded charge-model diagnostics included in exports even when trace is off.

### Validation
- 106 automated regression checks pass under Lua 5.1.
- User verified Death's Advance behavior, boss-message triggers, and Feint recovery
  with icons and sound in game. Fiery Brand has automated coverage only.
- A newly reported Windwalker issue is under investigation and is not claimed fixed.

## 1.3.3

### Fixed
- Track charge spells across configured presets, including casts before a boss pull,
  and share readiness between base and replacement spell IDs.
- Restore only completed charge recharges instead of prematurely filling the stack.
- Retry an empty early warning until its boss timer expires, allowing a cooldown
  that becomes ready during that window to be called once.
- Exclude BigWigs cast bars from timer reminders, including Chillstorm uptime.
- Exclude the verified Demonic Rage uptime bar and message on Xathuux.

### Validation
- The reporter confirmed in-game testing of the fixes.
- Fiery Brand has automated coverage; no separate live Fiery Brand result was supplied.
- Unknown ordinary uptime bars retain the existing filtering behavior.

## 1.3.2

### Fixed
- Removed a charge-tracking fallback that could mark an empty defensive as ready
  before its recharge finished, causing callouts for unavailable abilities such
  as Death's Advance.

## 1.3.1

### Fixed
- Exclude developer tools and regression scripts from release packages.

## 1.3.0

### Added
- Dedicated Profiles tab for profile management and import/export.
- Minimap launcher with the NaowhUI logo and a saved, draggable position.
- Reminder Font selector shared by defensive, ability, and raid reminder text.
- Hide After Casting toggle, off by default. Dismissal uses the displayed icon
  independently of speech; protected visibility falls back to the display timer.

### Changed
- Icon Display Duration defaults to 3 seconds, adjustable from 1 to 15 seconds.
  Existing profiles retain their saved duration.
- Removed Where It Runs and its global dungeon/raid gates. The main enable
  switch and per-boss choices remain in control.
- Bundled the NaowhUI logo for the addon-list icon and colored Naowh blue in the title.

### Fixed
- Charge tracking could spend a charge twice, invent one after a failed read,
  or credit the same recharge twice. Death's Advance recovery and callouts were
  verified in Ruby Life Pools on the test build.
- Skipped warnings and warnings with empty or unusable presets no longer erase
  the previous icon before its display timer expires.

## 1.2.0

### Changed
- Importing a pack names each row by its spec rather than its class. A Warrior's
  three rows all read "Warrior (DPS)" and "Warrior (Tank)" before, with no way
  to tell Arms from Fury; they now read "Protection (Tank)", "Arms (DPS)",
  "Fury (DPS)". Class colouring is unchanged, and it is what tells apart the
  four spec names that belong to two classes each.

### Added
- Select All and Deselect All on the pack import, beside the name field. A pack
  can carry all forty specs, so bringing in one or two of them meant thirty
  eight clicks of turning the rest off.

## 1.1.2

### Fixed
- A defensive with charges could be called while you had none of them. At zero
  charges the spell's cooldown is not running, and the charge tracker read that
  idle cooldown as proof a charge was in hand, so it handed itself one. Death's
  Advance was named at 0 of 2 on Rav'i because of it. The tracker now believes
  the client when it says a charge is still recharging.
- Where the game will state your real charge count, which is everywhere outside
  a dungeon or raid, that count is now used instead of the tracked estimate. The
  estimate could only drift, and had nothing to correct itself against for the
  rest of the session once it had.

## 1.1.1

### Fixed
- A flood of "table index is nil" errors while BigWigs' options or Edit Mode
  were open. The preview bars BigWigs raises there are not real boss timers and
  carry no ability, and filing one under the ability it does not have was the
  error. Those bars are now ignored, which is what should have happened anyway:
  there is nothing to remind anyone about.

## 1.1.0

### Added
- Window Scale, on the setup page under Options Window. Sets the size of the
  options window and every editor it opens, from 50% to 100%, for people whose
  screen the config UI did not fit on. Saved for the computer rather than in
  the profile, so switching profile leaves it alone and an exported pack never
  carries it to someone on a different monitor.

## 1.0.1

### Fixed
- Reminder Packs could not be imported or exported on the CurseForge and Wago
  builds, which reported "The serializer libraries are missing from this
  build." Those builds pulled an unrelated library that shares the LibSerialize
  name, so nothing registered the serializer the pack code reads. Local
  installs were never affected.

### Changed
- The version moves on every release now, so the number in the TOC and beside
  the build stamp identifies which files a report came from. Three separate
  1.0.0 files were published while this was not the case.

## 1.0.0

First release.

### Added
- Boss ability reminders driven by BigWigs or DBM. Pick the boss addon under
  Hook Into; every reminder rides its bars and messages rather than a timeline
  of our own.
- Dungeon Bosses and Raid Bosses tabs: this season's pool read from your own
  Dungeon Journal, with an ability picker per boss. Boss pages start blank and
  abilities are added deliberately.
- Cooldown Presets: named lists of defensives, stored per spec. A preset binds
  to an ability, with its own warning time.
- Callout display: icon and text with independent anchors, sizes and colours,
  placed from the Customize Anchors toolbar.
- Ability Reminders, assignable to a role, class, spec, name or subgroup with
  AND/OR combinations. Text, icon, bar, ring, timer, chat line, text-to-speech,
  nameplate glow and raid-frame glow displays.
- Triggers: a boss mod bar or message, a cast starting or finishing, a phase
  starting, time after pull, time in combat, and an aura applied at a stack
  threshold.
- Skip When Already Covered, which drops a call when a big defensive or
  external is already up, for as long as you set Your Own Cast Covers You For.
  On a tank spec, boss callouts fire only for the tank the boss is actually on;
  DPS and healer specs are never gated.
- Call Together: tick two or more cooldowns on a preset and they are called as
  one -- "Vampiric Blood and Icebound Fortitude" -- showing as a single row
  named for the call. One on cooldown is left out rather than holding the
  callout back.
- Equipped on-use trinkets sit in the cooldown preset picker beside the spec's
  own defensives, and the list follows a gear swap without a reload.
- Announce in Chat, including calling for an external by name.
- Observed timings: what the boss actually did on your own pulls, recorded per
  difficulty, with a reminder built from one click.
- Reminder Packs: a whole profile as one string, with preview before apply.
- Standalone options window at `/smartreminders`, `/nsr` or `/naowh`. Own
  theme, widget kit, profiles and SavedVariables, with no EllesmereUI
  dependency.
- Diagnostics under `/nutank`: `status`, `cds`, `keys`, and a trace recorder
  with a copyable export. Pretend Tank lets a DPS reproduce a tank-buster
  report.
- Every option ships off by default.
- Callouts on any spec, not only ones with a tank role. A raid-wide hit a DPS
  answers with a personal is the same question a tank buster asks, put to
  somebody else. Adding an ability for a spec is the opt-in, and abilities are
  stored per spec, so a spec nobody has set up still calls nothing.
- Call for an External is decided per ability as well as per spec, from that
  ability's own cog, for hits the raid was never going to answer.
- Warning Time takes a negative number, calling a defensive that many seconds
  AFTER a mechanic lands rather than before it, for a hit whose useful moment
  is once it is over.
- Copy All Dungeons / All Raids From a Spec, at the top of the boss lists:
  another spec's whole setup in one press, instead of repeating the per-boss
  copy on every boss. Raids and dungeons stay on their own side, and anything
  the target spec already has is kept.
- Saving a profile under a name already taken offers to overwrite it, naming
  the profile and what replacing it costs, rather than refusing.
- A boss page with nothing on this spec says whether the profile has work under
  other specs, since an empty page otherwise reads as lost data.
- `/nutank tanksheet` cross-checks the curated tank-ability list against the
  Dungeon Journal, separating entries the journal contradicts from ones it
  simply has no role flag for.

### Changed

- Ability Reminders is marked coming soon: the tab is dimmed and opens a note.
  The same reminders are authored per boss in the meantime, which is where that
  page reads them from.
- Importing a pack never overwrites anything. It lands as a new profile under a
  name you choose, so going back to your own profile finds it as you left it,
  and a pack that does not mention a spec no longer drops the one you had.
- A whole profile exports in one string, every spec it holds, with the display,
  sound and behaviour settings alongside it for the importer to take or leave.

### Fixed before release

Found by testers on live keys and raid nights between the release branch being
cut and 1.0.0 going out.

- Tank callouts fired for both tanks on abilities the addon could not attribute
  to a boss unit. Every ability in the pool was checked against its BigWigs or
  LittleWigs module and given the slot that casts it, so a call now goes to the
  tank holding that boss. Abilities whose module never settles a slot keep the
  old behaviour rather than risk silencing a real one.
- A tank holding an add that occupied a boss frame was called for the boss's
  own ability, most visibly on Ula'tek.
- Threat momentarily reading low -- mid-cast, across a stage change, while a
  boss was untargetable -- refused callouts for the tank who had the boss the
  whole time.
- Charge defensives could read ready while on cooldown: a spell's cooldown was
  being stored as its recharge, and for Guardian of Ancient Kings those differ
  by nearly three minutes.
- A repeating ability called on some casts and not others. A boss mod's bar for
  the next cast replaced the callout already due for the current one, and a
  second announcement of the same cast could cancel the next one outright at
  short warning times.
- A debuff bar sharing an ability's spell id could take that ability's callout
  with it when it expired.
- A defensive was named over one still running.
- Rav'i's Triple Shot was treated as a tank hit. Blizzard's own Journal calls it
  a healer mechanic and it is not threat-driven, so it no longer carries the
  tank-hit sound or the tank tag in the ability picker.
- Two boss abilities landing within a second of each other, as Entombed
  Sentinels' do, announced the same defensive twice. A repeat of the same pick
  is now muted for three seconds across different abilities, while a genuine
  repeat of the same ability seconds later still gets its own line.
- Raid-frame glow did nothing for anyone using EllesmereUI raid frames, with no
  error. The library it asks first returns nothing for those frames, so the
  buttons are now looked up directly when it comes up empty.
- The options window opened with every tab blank. One file had passed Lua's
  200-local ceiling and stopped compiling, taking every page builder with it.
- A dropdown could open behind the row below it, a colour swatch could go
  unreachable, and the ability editor's layout could overlap at some sizes.

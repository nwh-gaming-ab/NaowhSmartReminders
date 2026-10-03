# Countdown-only boss-mod adapter

Separate branch fix/bigwigs-castbar-reminders, created from main. Includes the
uncommitted test4 prerequisite files copied from readiness-audit; that worktree
is preserved. The focused change relative to test4 is the BigWigs callback route.

Installed LittleWigs MelidrussaChillworn.lua emits a CDBar for Chillstorm 1307308,
then a CastBar lasting 11.5 seconds (cast plus debuff). Installed BigWigs
BossPrototype.lua publishes BigWigs_Timer for Bar/CDBar regardless of visual bar
settings; CastBar publishes BigWigs_CastTimer. All three publish StartBar.
Reminders now consume BigWigs_Timer once and do not subscribe to StartBar.
No third-party code was copied. No Blizzard API or SavedVariables schema changed.

The old timing heuristic rejected an immediate cast bar in some circumstances;
the regression explicitly reproduces a cast bar arriving outside its 1.5-second
window. Robin supplied the symptom and boss, not the exact event trace.

All four adapter regression cases fail/pass as appropriate (the duplicate case
fails on test4), and the existing 18 late-ready, 15 charge, 10 cast-tracking and
display regression cases pass. Lua 5.1 compilation, style and whitespace pass.
Review covered tank, raid, observed counters and custom timer dispatch. Normal
messages and cancellation callbacks remain active. No new timer, polling or
allocation loop; one fewer boss-mod event registration.

Scope: this reliably excludes CastBar, including Chillstorm's uptime. Plain Bar
uptimes still use the existing heuristic. Older BigWigs versions or third-party
senders that only publish StartBar are not supported by this route. The installed
current version publishes the required Timer callback. No in-game test claimed.

Live checklist after /reload (1.3.2-countdown-test1):
1. Chillstorm countdown: one configured reminder at the selected warning time.
2. Subsequent cast/uptime bar: no second timer reminder or observed cast count.
3. Repeat with BigWigs visual bars off: countdown reminders still work.
4. Stop the timer or end the pull: no outstanding warning fires afterward.
5. Recheck Death's Advance late readiness: the previously tested behavior remains.

Not published or committed.

## Verified ordinary uptime rule (countdown-test2)

Added an encounter-scoped registry with one verified current Midnight case:
Xathuux the Annihilator, encounter 3103, Demonic Rage 474197. Installed
LittleWigs/Midnight/MurderRow/XathuuxTheAnnihilator.lua lines 210-224 emits the
countdown as CDBar, then a 4s CastBar and a 15s ordinary Bar using GetRename slot 3.
The same slot identifies its uptime message. Both are excluded before observed
counters, catalogue entries, custom reminders, raid or priority dispatch.

The timer rule requires the exact duration, non-approximate flag, encounter and
module encounter identity, and the live configurable label. The message rule
requires the same identity and label. A rename collision with countdown slot 1,
missing metadata, or a failed rename accessor preserves prior behavior. Other
bosses and unmatched timers retain the existing heuristic. No English matching,
no blanket duration blacklist and no third-party code copied.

14 adapter tests pass, including the 10 added cases; 18 late-ready, 15 charge,
10 cast-tracking and display tests still pass. Lua 5.1 compile, style and whitespace
checks pass. Cost is two table lookups on ordinary callbacks and two protected
rename calls only for the matching rule; no new frame, timer or polling.

Live test still required: on Xathuux, expect the normal Demonic Rage countdown
reminder, then no uptime message or end-of-buff timer reminder. Repeat with a
customized uptime label. Chillstorm's global CastBar exclusion remains in place.
Build 1.3.2-countdown-test2 is available through the existing game junction.
No release or commit performed. This is verified coverage, not universal inference.

Release preparation: user subsequently confirmed in-game testing and requested
a regular 1.3.3 release. Earlier test-status notes above are historical. No
separate live Fiery Brand result was supplied.

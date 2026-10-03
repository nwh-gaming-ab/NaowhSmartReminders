local root = arg[1] or "."
local function Read(suffix)
    local f = assert(io.open(root .. "/NaowhUI_SmartReminders" .. suffix .. ".lua", "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n"); f:close(); return s
end
local function Slice(s, a, b)
    local first = assert(s:find(a, 1, true), a)
    return s:sub(first, assert(s:find(b, first + #a, true), b) - 1)
end
local function Eval(code, env)
    setmetatable(env, { __index = _G })
    local f = assert(loadstring(code)); setfenv(f, env); return f()
end
local core, main, raid = Read("_Core"), Read(""), Read("_RaidReminders")
local saved = { profiles = { One = {}, Two = {} }, charActive = {}, account = {} }
local ns = {}
local env = { ns = ns, _G = { NaowhUI_SmartRemindersDB = saved },
    UnitName = function() return "Tester" end, GetRealmName = function() return "Realm" end }
Eval(Slice(core, "local activeRoot", "-- Stored as a percent"), env)
local healer, ordinary = { healerReminder = true }, {}
assert(ns.HealerRemindersEnabled())
assert(ns.IsReminderEnabled(healer) and ns.IsReminderEnabled(ordinary))
assert(not ns.IsReminderEnabled(nil) and not ns.IsReminderEnabled({ enabled = false }))
ns.SetHealerRemindersEnabled(false)
assert(not ns.IsReminderEnabled(healer) and ns.IsReminderEnabled(ordinary))
assert(ns.IsReminderEnabled({ healerReminder = false }))
-- Profiles cannot carry or override the account preference.
saved.charActive["Tester-Realm"] = "Two"
saved.profiles.Two.healerRemindersEnabled = true
ns.SettingsRoot()
assert(not ns.HealerRemindersEnabled())
local reload = { ns = {}, _G = env._G, UnitName = env.UnitName, GetRealmName = env.GetRealmName }
Eval(Slice(core, "local activeRoot", "-- Stored as a percent"), reload)
assert(not reload.ns.HealerRemindersEnabled())

-- Block the entire display dispatch, before any sound, TTS, or defensive work.
local displayed, sounds, speech, scheduled = 0, 0, 0, 0
env.FireCustomReminder = function() displayed = displayed + 1; sounds = sounds + 1 end
env.specID = 250
env.CustomRemindersAllowed = function() return true end
ns.FireMessageDefensive = function() displayed = displayed + 1 end
Eval(Slice(main, "function ns.DisplayReminder(r)", "-- The editor's Preview"), env)
ns.DisplayReminder(healer); assert(displayed == 0 and sounds == 0)
ns.DisplayReminder(ordinary); assert(displayed == 1 and sounds == 1)
healer.defensive = true; ns.DisplayReminder(healer); assert(displayed == 1)

env.FormatReminderMsg = function(text) return text end
ns.Print = function() displayed = displayed + 1 end
ns.PlayReminderSound = function() sounds = sounds + 1 end
ns.SpeakReminderTTS = function() speech = speech + 1 end
Eval(Slice(raid, "function ns.DisplayRaidReminder(entry, preview)", "function ns.PreviewRaidReminder"), env)
healer.display = { type = "chat", text = "Healer" }
ordinary.display = { type = "chat", text = "Everyone" }
ns.DisplayRaidReminder(healer); assert(displayed == 1 and sounds == 1 and speech == 0)
ns.DisplayRaidReminder(ordinary); assert(displayed == 2 and sounds == 2 and speech == 1)
ordinary.enabled = false
ns.DisplayRaidReminder(ordinary, true); assert(displayed == 3)
ns.DisplayRaidReminder(healer, true); assert(displayed == 3)
ordinary.enabled = nil

env.ParseDelayList = function() return { 1, 3 } end
ns.TrackReminderTimer = function() scheduled = scheduled + 1 end
local activate = Eval(Slice(main, "local function ActivateCustomReminder", "-- Boss cast triggers")
    .. "\nreturn ActivateCustomReminder", env)
activate(healer); assert(scheduled == 0)
activate(ordinary); assert(scheduled == 2)

-- Pending custom bar callbacks and active displays are removed selectively.
local function Timer() return { Cancel = function(t) t.cancelled = true end } end
local h, o = Timer(), Timer()
env.bwPendingTimers = { h = h, o = o }
ns.pendingCustomReminderOwners = { h = healer, o = ordinary }
-- One display now: the authored-reminder frame is gone and everything draws on the
-- defensive alert, so the filter has one callout to pull rather than two.
local defensiveHidden, raidCleared = 0, 0
ns.activeAuthoredReminder = healer
env.HideReminder = function() defensiveHidden = defensiveHidden + 1 end
ns.HideFilteredRaidReminders = function() raidCleared = raidCleared + 1 end
ns.PruneCustomReminderTimers = function() end
ns.PrunePendingBWFires = function() end
Eval(Slice(main, "function ns.ApplyReminderFilter()", "function ns.HandleBigWigsAbility"), env)
ns.SetHealerRemindersEnabled(false)
assert(h.cancelled and not o.cancelled and env.bwPendingTimers.h == nil)
assert(defensiveHidden == 1 and raidCleared == 1)
ns.activeAuthoredReminder = ordinary
ns.SetHealerRemindersEnabled(true)
assert(defensiveHidden == 1 and env.bwPendingTimers.h == nil)

-- Raid regions and glows keep their owners even when several share an anchor.
local a = { active = { { reminderEntry = healer }, { reminderEntry = ordinary } } }
env.anchors = { text = a }
env.activeGlows = { { reminderEntry = healer }, { reminderEntry = ordinary } }
env.ReleaseRegion = function(anchor, region)
    for i, r in ipairs(anchor.active) do if r == region then table.remove(anchor.active, i); break end end
end
env.ReleaseGlowWrapper = function(w)
    for i, r in ipairs(env.activeGlows) do if r == w then table.remove(env.activeGlows, i); break end end
end
Eval(Slice(raid, "function ns.HideFilteredRaidReminders()", "-- MRT's event-13"), env)
ns.SetHealerRemindersEnabled(false)
assert(#a.active == 1 and a.active[1].reminderEntry == ordinary)
assert(#env.activeGlows == 1 and env.activeGlows[1].reminderEntry == ordinary)
print("PASS healer preference, reload/profile isolation, dispatch/audio, scheduling, selective cleanup")

-- Ability bindings use the same account filter but retain their enabled checkbox.
local binding = { enabled = true, healerReminder = true }
local normalBinding = { enabled = true }
ns.BindingForBossModKey = function(enc, sid)
    if enc ~= 1 then return normalBinding end
    return (sid == 123 or sid == 456) and binding or normalBinding
end
Eval(Slice(main, "function ns.IsAbilityHealerFiltered", "-- Has the player added"), env)
assert(not ns.AbilityEnabledForBinding(1, 123))
assert(not ns.AbilityEnabledForBinding(1, 456)) -- resolved alias
assert(ns.AbilityEnabledForBinding(1, 123, true)) -- UI still shows the saved enabled state
assert(ns.AbilityEnabledForBinding(2, 123)) -- another encounter's ordinary callout
assert(ns.AbilityEnabledForBinding(1, 789))
assert(ns.IsAbilityHealerFiltered(1, 123) and not ns.IsAbilityHealerFiltered(2, 123))
ns.SetHealerRemindersEnabled(true)
assert(ns.AbilityEnabledForBinding(1, 123))
binding.enabled = false
assert(not ns.AbilityEnabledForBinding(1, 123) and not ns.AbilityEnabledForBinding(1, 123, true))
binding.enabled = true

-- Static timeline audio is filtered before registration and can be restored.
local registered = {}
ns.BossSource = function() return "timeline" end
ns.soundEvents, ns.soundGeneration = {}, 0
ns.ClearEventSounds = function() registered = {}; ns.soundEvents = {}; ns.soundGeneration = ns.soundGeneration + 1 end
ns.TANK_ABILITIES = { [123] = true, [789] = true }
env.TRDB = function() return { enabled = true, soundOn = true } end
env.canSound = true; env.currentEncounter = 1
env.ResolveSoundFile = function() return "test.ogg" end
env.Enum = { EncounterEventSoundTrigger = { OnTimelineEventHighlight = 1 }, EncounterEventIconmask = { TankRole = 1 } }
env.bit = { band = function() return 0 end }
env.C_EncounterEvents = {
    GetEventList = function() return { 123, 789 } end,
    GetEventInfo = function(id) return { spellID = id } end,
    SetEventSound = function(id, _, sound) registered[id] = sound end,
}
env.RegisterEventSounds = Eval(Slice(main, "local function RegisterEventSounds()", "--  Self-tracked cooldowns")
    .. "\nreturn RegisterEventSounds", env)
ns.SetHealerRemindersEnabled(false)
assert(registered[123] == nil and registered[789] ~= nil)
ns.SetHealerRemindersEnabled(true)
assert(registered[123] ~= nil and registered[789] ~= nil)
print("PASS ability filtering, saved checkbox state, alias/encounter isolation and timeline sound registration")

-- The actual boss-mod entry point skips scheduling filtered bindings and supplies
-- a live validity predicate for the existing scheduler's cancellation sweep.
local scheduledAbility
ns.BossSource = function() return "bigwigs" end
ns.HasMessageDefensive = function() return false end
ns.SampleTanking = function() end
ns.LeadTimeFor = function() return 3 end
ns.ScheduleBWFire = function(_, _, _, _, _, fire, _, valid)
    scheduledAbility = { fire = fire, valid = valid }
end
env.frame = {}; env.ShouldRun = function() return true end
env.InEncounter = function() return true end
env.AppendLog = function() end
env.GetTime = function() return 0 end
env.currentEncounter = 1
Eval(Slice(main, "function ns.HandleBigWigsAbility(", "local function CancelPendingBWFire("), env)
ns.SetHealerRemindersEnabled(false)
ns.HandleBigWigsAbility(123, 20, "bar")
assert(scheduledAbility == nil)
ns.SetHealerRemindersEnabled(true)
ns.HandleBigWigsAbility(123, 20, "bar")
assert(scheduledAbility and scheduledAbility.valid())
saved.account.healerRemindersEnabled = false
assert(not scheduledAbility.valid())
local timer = Timer()
env.pendingBWFires = { tank = { [123] = { test = { timer = timer, valid = scheduledAbility.valid } } } }
Eval(Slice(main, "function ns.PrunePendingBWFires()", "-- Called only when the account toggle"), env)
ns.PrunePendingBWFires()
saved.account.healerRemindersEnabled = true
assert(timer.cancelled and env.pendingBWFires.tank[123].test == nil)
print("PASS ability scheduling and opt-out cancellation")

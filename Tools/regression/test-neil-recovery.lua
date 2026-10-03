local root = arg[1] or "."
local function Read(suffix)
    local f = assert(io.open(root .. "/NaowhUI_SmartReminders" .. suffix .. ".lua", "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n"); f:close(); return s
end
local function Slice(s, first, last)
    local a = assert(s:find(first, 1, true), first)
    return s:sub(a, assert(s:find(last, a, true), last) - 1)
end
local function Eval(code, env)
    setmetatable(env, { __index = _G })
    local f = assert(loadstring(code)); setfenv(f, env); return f()
end
local cases = 0
local function Case(name, fn)
    fn(); cases = cases + 1; print("PASS " .. name)
end
local main, raid, widgets = Read(""), Read("_RaidReminders"), Read("_Widgets")

Case("late LSM, negative cache, and later sound registration", function()
    local ui, builds, callback = {}, 0
    local media = { later = "later.ogg" }
    local provider = {
        HashTable = function() builds = builds + 1; return media end,
        RegisterCallback = function(_, event, fn) assert(event == "LibSharedMedia_Registered"); callback = fn end,
        UnregisterCallback = function() end,
    }
    local env = { UI = ui, LibStub = false }
    Eval(widgets:sub((assert(widgets:find("local bundledVoices =", 1, true)))), env)
    assert(ui.SoundPathFor("sm:later") == nil)
    env.LibStub = function() return provider end
    assert(ui.SoundPathFor("sm:later") == "later.ogg")
    for i = 1, 100 do assert(ui.SoundPathFor("sm:missing") == nil) end
    assert(builds == 1, "negative lookup rebuilt cache")
    media.added = "added.ogg"; callback("LibSharedMedia_Registered", "sound", "added")
    assert(ui.SoundPathFor("sm:added") == "added.ogg" and builds == 2)
end)

local validate = Eval(Slice(Read("_Packs"), "local SECTIONS =", "-- LibSerialize's Deserialize")
    .. "\nreturn ValidData", {})
local function Data()
    return { bindingsBySpec = true,
        presets = { ["250"] = { p1 = { name = "Tank", list = { 123 }, together = { ["123"] = true } } } },
        abilityBindings = { ["250"] = { ["1"] = { ["123"] = { enabled = false, preset = "p1" } } } },
        raidReminders = { ["1"] = { r = { enabled = true,
            trigger = { type = "bwtimer", spellID = 123, leadTime = 3 },
            target = { roles = { TANK = true } }, display = { type = "text", text = "Use it" } } } } }
end
Case("current pack schema preserves false switches", function() assert(validate(Data())) end)
Case("healer tags accept booleans only", function()
    local data = Data()
    data.raidReminders["1"].r.healerReminder = "false"; assert(not validate(data))
    data.raidReminders["1"].r.healerReminder = false; assert(validate(data))
end)

Case("legacy binding and target shapes remain supported", function()
    local d = Data(); d.bindingsBySpec = false; d.abilityBindings = d.abilityBindings["250"]
    d.raidReminders["1"].r.target = { kind = "role", value = "TANK" }; assert(validate(d))
end)
local mutations = {
    roles = function(d) d.raidReminders["1"].r.target.roles = 7 end,
    flag = function(d) d.raidReminders["1"].r.target.roles.TANK = {} end,
    color = function(d) d.raidReminders["1"].r.display.color = { r = "red" } end,
    trigger = function(d) d.raidReminders["1"].r.trigger.spellID = {} end,
    binding = function(d) d.abilityBindings["250"]["1"]["123"] = 4 end,
    list = function(d) d.presets["250"].p1.list[1] = {} end,
    position = function(d) d.settings = { pos = { x = {} } } end,
    cycle = function(d) d.self = d end,
    nonfinite = function(d) d.leadTime = math.huge end,
}
for name, mutate in pairs(mutations) do
    Case("reject malformed " .. name, function() local d = Data(); mutate(d); assert(not validate(d)) end)
end

local scheduler = Slice(main, "local pendingBWFires =", "function ns.HandleBigWigsAbility(")
local tracking = Slice(main, "function ns.PruneCustomReminderTimers()", "-- The match decided")
local firing = Slice(raid, "local function FireRaidReminder(entry)", '-- "aura" triggers')
local queue = Read("_Core"):sub((assert(Read("_Core"):find("local reapplyPending", 1, true))))
local function Fixture(kind)
    local state = { now = 0, start = 0, encounter = 1, displayed = 0, timers = {}, queue = {} }
    local entry = { enabled = true, trigger = { type = kind, spellID = 123, leadTime = 3, delay = 20, stage = 2 } }
    state.set = { r = entry }; state.profile = { enabled = true }; state.account = {}
    local ns = { trackedReminderTimers = {},
        AccountSettings = function() return state.account end,
        DB = function() return state.profile end,
        CurrentEncounter = function() return state.encounter end,
        PullContext = function() return state.start end,
        InEncounter = function() return state.encounter ~= nil end,
        BossAllowed = function() return true end,
        RaidReminderTargetsMe = function() return true end,
        DisplayRaidReminder = function() state.displayed = state.displayed + 1 end,
    }
    local env = { ns = ns, GetTime = function() return state.now end,
        TRDB = function() return state.profile end,
        RaidRemindersTable = function() return state.set end,
        C_Timer = {
            NewTimer = function(delay, cb)
                local t = { fn = cb, Cancel = function(self) self.cancelled = true end }
                state.timers[#state.timers + 1] = t; return t
            end,
            After = function(_, cb) state.queue[#state.queue + 1] = cb end,
        },
    }
    Eval(Slice(Read("_Core"), "function ns.HealerRemindersEnabled()", "-- Stored as a percent"), env)
    Eval(tracking .. scheduler .. firing .. queue, env)
    if kind == "bwtimer" then ns.HandleRaidReminderAbility(123, 20, "bar")
    elseif kind == "pull" then ns.CheckRaidReminderPullTriggers()
    else ns.CheckRaidReminderStageTriggers(2) end
    assert(#state.timers == 1)
    state.ns, state.entry = ns, entry
    function state:Fire()
        self.now = 17
        for _, t in ipairs(self.timers) do if not t.cancelled then t.fn() end end
    end
    return state
end
for _, kind in ipairs({ "bwtimer", "pull", "stage" }) do
    Case(kind .. " current reminder fires", function() local s = Fixture(kind); s:Fire(); assert(s.displayed == 1) end)
    Case(kind .. " healer opt-out cancels queued work without reviving it", function()
        local s = Fixture(kind); s.entry.healerReminder = true
        s.account.healerRemindersEnabled = false
        s.ns.PruneCustomReminderTimers(); s.ns.PrunePendingBWFires()
        s.account.healerRemindersEnabled = true
        assert(s.timers[1].cancelled); s:Fire(); assert(s.displayed == 0)
    end)
    Case(kind .. " callback rechecks healer opt-out", function()
        local s = Fixture(kind); s.entry.healerReminder = true
        s.account.healerRemindersEnabled = false
        s:Fire(); assert(s.displayed == 0)
    end)
    local changes = {
        delete = function(s) s.set.r = nil end,
        replace = function(s) s.set.r = {} end,
        disable = function(s) s.profile.enabled = false end,
        profile = function(s) s.profile = { enabled = true } end,
        encounter = function(s) s.encounter = 2 end,
        repull = function(s) s.start = 10 end,
    }
    for name, change in pairs(changes) do
        Case(kind .. " rejects " .. name, function()
            local s = Fixture(kind); change(s); s:Fire(); assert(s.displayed == 0)
        end)
    end
    Case(kind .. " switch away and back cancels before queued apply", function()
        local s = Fixture(kind); local old = s.profile
        s.profile = { enabled = true }; s.ns.QueueReapply(); s.profile = old
        assert(s.timers[1].cancelled); s:Fire(); assert(s.displayed == 0)
    end)
end
Case("Neil's two reminders sharing a bar still both fire", function()
    local s = Fixture("bwtimer")
    s.set.other = { enabled = true, trigger = s.entry.trigger }
    s.ns.HandleRaidReminderAbility(123, 20, "bar")
    s:Fire(); assert(s.displayed == 2)
end)
Case("bundled serializers round-trip real profile strings and reject malformed input", function()
    strmatch = string.match -- WoW's standard-library alias used by LibStub.
    assert(loadfile(root .. "/Libs/LibStub/LibStub.lua"))()
    assert(loadfile(root .. "/Libs/LibSerialize/LibSerialize.lua"))()
    assert(loadfile(root .. "/Libs/LibDeflate/LibDeflate.lua"))()
    local db = Data()
    db.raidReminders["1"].r.healerReminder = true
    db.abilityBindings["250"]["1"]["123"].healerReminder = true
    local writes = 0
    local ns = { DB = function() return db end,
        EnsureProfile = function() writes = writes + 1; return {} end }
    local env = { _G = { NaowhUITankReminder = ns }, LibStub = LibStub }
    Eval(Read("_Packs"), env)
    local encoded, err = ns.ExportPack("Recovery test", "Tester")
    assert(encoded, err)
    local decoded, why = ns.DecodePack(encoded)
    assert(decoded, why)
    assert(decoded.data.raidReminders["1"].r.healerReminder == true)
    assert(decoded.data.abilityBindings["250"]["1"]["123"].healerReminder == true)
    assert(decoded.data.account == nil)
    assert(decoded.data.abilityBindings["250"]["1"]["123"].enabled == false)
    local malformed = Data(); malformed.raidReminders["1"].r.target.roles = 7
    assert(ns.ImportPackAsProfile({ data = malformed }) == false and writes == 0)
    assert(ns.ApplyProfiles({ profiles = { Good = Data(), Bad = malformed } }) == false and writes == 0)
    local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")
    local bad = "NSRPACK2:" .. LD:EncodeForPrint(LD:CompressDeflate(LS:Serialize({ format = 1, data = malformed })))
    assert(ns.DecodePack(bad) == nil)
end)
print(cases .. " recovery regression cases passed")

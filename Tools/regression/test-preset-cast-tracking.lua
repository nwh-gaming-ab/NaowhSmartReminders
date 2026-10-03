local path = arg[1] or "NaowhUI_SmartReminders.lua"
local f = assert(io.open(path, "rb"))
local source = f:read("*a"):gsub("\r\n", "\n"); f:close()
local function Slice(first, last)
    local a = assert(source:find(first, 1, true))
    local b = assert(source:find(last, a + #first, true))
    return source:sub(a, b - 1)
end
local charge = Slice("local KNOWN_BASE_COOLDOWN = {", "-- Every actual cast or callout")
local cast = Slice("local function NoteOwnCast(castSpellID)", "-- These three hang off ns")
local registration = Slice("local function UpdateEventRegistration()", "local function WarnIfMuted")
local function Fixture(sid)
    local spec = sid == 204021 and 581 or 250
    local e = { time = 0, active = false, remaining = nil, casts = 0, enabled = true }
    local db = { enabled = true, clientRecharge = { [tostring(sid)] = 45 },
        presets = { [tostring(spec)] = { p1 = { list = { 48707 } }, p2 = { list = { sid } } } } }
    local ns = {}
    local registered = {}
    local env = { ns = ns, specID = spec, activeSlots = 1, slots = { { spellID = 48707 } },
        GetTime = function() return e.time end, TRDB = function() return db end,
        wipe = function(t) for k in pairs(t) do t[k] = nil end end,
        PresetsTable = function() return db.presets[tostring(spec)] end,
        IsSpellAvailable = function() return true end,
        CanNameSpellAloud = function() return false end,
        AppendLog = function() e.casts = e.casts + 1 end,
        ownCastAt = {}, readyAt = {},
        C_CombatLog = { IsCombatLogRestricted = function() return true end },
        ShouldRun = function() return false end, HideReminder = function() end,
        watcher = {
            RegisterUnitEvent = function(_, event, unit) assert(unit == "player"); registered[event] = true end,
            RegisterEvent = function(_, event) registered[event] = true end,
            UnregisterEvent = function(_, event) registered[event] = nil end,
        },
        C_Spell = {
            GetOverrideSpell = function(id) return id end,
            GetSpellCharges = function(id)
                if id == sid then return { maxCharges = 2, isActive = e.active } end
            end,
            GetSpellChargeDuration = function(id)
                if id == sid and e.remaining then return {
                    GetTotalDuration = function() return 45 end,
                    GetRemainingDuration = function() return e.remaining end,
                } end
            end,
            GetSpellCooldownDuration = function() return nil end,
        },
    }
    setmetatable(env, { __index = _G })
    local chunk = assert(loadstring(charge .. "\nCooldownRunning = function() return false end\n"
        .. cast .. "\n" .. registration .. "\nreturn EnsureChargeState, ChargesAvailable, "
        .. "NoteOwnCast, RebuildCastMap, UpdateEventRegistration, chargeState, castToBase"))
    setfenv(chunk, env)
    e.ensure, e.available, e.cast, e.rebuild, e.register, e.states, e.map = chunk()
    e.db, e.env, e.registered, e.ns = db, env, registered, ns
    e.ensure(sid)
    e.rebuild()
    return e
end
local failures, cases = 0, 0
local function Eq(a,b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function Case(name, fn)
    cases = cases + 1
    local ok, err = pcall(fn)
    if ok then print("PASS " .. name) else failures = failures + 1; print("FAIL " .. name .. ": " .. err) end
end
for _, sid in ipairs({ 48265, 204021 }) do
    Case("two casts from a non-displayed preset deplete " .. sid, function()
        local e = Fixture(sid)
        e.active, e.remaining = true, 45
        e.cast(sid)
        e.time, e.remaining = 5, 40
        e.cast(sid)
        Eq(e.available(sid), 0)
        Eq(e.casts, 2)
        e.env.slots[1].spellID = sid
        e.rebuild()
        Eq(e.available(sid), 0)
        e.time, e.remaining = 45, 45
        Eq(e.available(sid), 1)
    end)
end
Case("cast watching survives an inactive boss/display gate", function()
    local e = Fixture(48265)
    e.register()
    Eq(e.registered.UNIT_SPELLCAST_SUCCEEDED, true)
    Eq(e.registered.SPELL_UPDATE_COOLDOWN, true)
    e.env.activeSlots = 0
    e.rebuild()
    e.register()
    Eq(e.registered.UNIT_SPELLCAST_SUCCEEDED, true)
    e.db.enabled = false
    e.register()
    Eq(e.registered.UNIT_SPELLCAST_SUCCEEDED, nil)
end)
Case("legacy boss lists are watched without watching another spec", function()
    local e = Fixture(48265)
    e.db.bossLists = { ["250:2139"] = { 99 }, ["581:2139"] = { 100 } }
    e.rebuild()
    Eq(e.map[99], 99)
    Eq(e.map[100], nil)
end)
Case("override casts map to their configured spell", function()
    local e = Fixture(48265)
    e.env.C_Spell.GetOverrideSpell = function(id) return id == 48265 and 999 or id end
    e.rebuild()
    e.active, e.remaining = true, 45
    e.cast(999)
    Eq(e.casts, 1)
    Eq(e.available(48265), 1)
end)
Case("cooldown resync covers hidden presets once per configured spell", function()
    local e = Fixture(48265)
    e.db.presets["250"].p3 = { list = { 48265, 48707 } }
    e.rebuild()
    local seen = {}
    e.env.ResyncSpell = function(sid) seen[sid] = (seen[sid] or 0) + 1 end
    local chunk = assert(loadstring(Slice("local function ResyncModel()", "-- SPELL_UPDATE_COOLDOWN arrives")
        .. "\nreturn ResyncModel"))
    setfenv(chunk, e.env)
    chunk()()
    Eq(seen[48265], 1)
    Eq(seen[48707], 1)
end)
for _, first in ipairs({ 48265, 999 }) do
    Case("base/replacement share charges with displayed ID " .. first, function()
        local e = Fixture(48265)
        local original = e.env.C_Spell.GetSpellCharges
        local duration = e.env.C_Spell.GetSpellChargeDuration
        e.env.C_Spell.GetSpellCharges = function(id) return original(id == 999 and 48265 or id) end
        e.env.C_Spell.GetSpellChargeDuration = function(id) return duration(id == 999 and 48265 or id) end
        e.env.C_Spell.GetOverrideSpell = function(id) return id == 48265 and 999 or id end
        e.db.presets["250"].p3 = { list = { 999 } }
        e.env.slots[1].spellID = first
        e.ensure(999)
        e.rebuild()
        Eq(e.ns.CooldownKey(48265), e.ns.CooldownKey(999))
        e.active, e.remaining = true, 45
        e.cast(999)
        Eq(e.available(48265), 1)
        Eq(e.available(999), 1)
        e.time, e.remaining = 5, 40
        e.cast(999)
        Eq(e.available(48265), 0)
        Eq(e.available(999), 0)
        e.rebuild()
        Eq(e.available(999), 0)
        e.time, e.remaining = 45, 45
        Eq(e.available(999), 1)
        Eq(e.available(48265), 1)
        Eq(e.casts, 2)
    end)
end
Case("merging existing aliases keeps the spent counter", function()
    local e = Fixture(48265)
    e.states[48265].count = 0
    e.env.C_Spell.GetOverrideSpell = function(id) return id == 48265 and 999 or id end
    e.rebuild()
    Eq(e.available(999), 0)
    e.env.readyAt[48265] = 70
    e.rebuild()
    Eq(e.env.readyAt[e.ns.CooldownKey(999)], 70)
end)
Case("single-cooldown readiness resolves the same deadline for both IDs", function()
    local e = Fixture(48265)
    e.env.C_Spell.GetOverrideSpell = function(id) return id == 48265 and 999 or id end
    e.env.C_Spell.GetSpellCharges = function() return { maxCharges = 1, isActive = false } end
    e.rebuild()
    e.env.C_Spell.GetSpellCooldownDuration = function() return {} end
    e.env.CooldownRunning = function() return nil end
    local chunk = assert(loadstring(Slice("local function SpellReady(sid, now)", "-------------------------------------------------------------------------------")
        .. "\nreturn SpellReady"))
    setfenv(chunk, e.env)
    local ready = chunk()
    e.env.readyAt[e.ns.CooldownKey(48265)] = 70
    Eq(ready(48265, 5), false)
    Eq(ready(999, 5), false)
    Eq(ready(999, 70), true)
end)
print(cases .. " cases; " .. failures .. " failures")
assert(failures == 0)

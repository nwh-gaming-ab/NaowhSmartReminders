-- Naming who a boss cast is aimed at.
--
-- Nothing here identifies the cast, because nothing can: UNIT_SPELLCAST_START is
-- SecretWhenUnitSpellCastRestricted, which the client documents as producing secret values
-- for any unit that is not the player or their pet. A secret cannot key a table, so a cast
-- can never be matched to the reminder that warned about it.
--
-- Whether a cast names somebody is the one plain answer the client gives, so the name is
-- written onto the alert that is ALREADY on screen and the two are never matched. This
-- suite is that decoration, and the watch that has to be live for it.
--
-- The trash half of this was removed in 1.4.12. It matched a cast to its rule by spell id,
-- which is the lookup that can never succeed, and it had never once fired in a dungeon.
local f = assert(io.open(arg[1] or "NaowhUI_SmartReminders.lua", "rb"))
local source = f:read("*a"):gsub("\r\n", "\n"); f:close()
local function Slice(a, b)
    local first = assert(source:find(a, 1, true), a)
    return source:sub(first, assert(source:find(b, first + #a, true), b) - 1)
end

local CHUNK = table.concat({
    Slice("function ns.CastNamesATarget(", "-- Previews one custom line"),
    Slice("function ns.RefreshCastWatch(", "-- Cast end is SUCCEEDED only"),
    Slice("function ns.OnBossCast(", "-- Which single source drives callouts"),
}, "\n")

local function Fixture()
    local e = { db = {}, shown = {}, targets = {}, names = true, watcher = {} }
    local env = {
        TRDB = function() return e.db end,
        CustomRemindersAllowed = function() return e.allowed ~= false end,
        CustomRemindersTable = function() return e.encounterSet end,
        currentEncounter = nil,
        customCounters = {},
        ParseCounterCondition = function() return nil end,
        CheckCounterCondition = function() return true end,
        AppendLog = function() end,
        ActivateCustomReminder = function(r) e.authored = r; return true end,
        UnitShouldDisplaySpellTargetName = function(unit)
            e.askedAbout = unit
            return e.names
        end,
        ShowOnAlert = function(opts)
            if e.refuse then return false end
            e.shown[#e.shown + 1] = opts
            return true
        end,
        CreateFrame = function()
            local w = e.watcher
            w.registered = {}
            w.SetScript = function() end
            w.RegisterEvent = function(_, ev) w.registered[ev] = true end
            w.UnregisterAllEvents = function() w.registered = {}; w.off = true end
            return w
        end,
    }
    e.ns = {
        ShowCastTargetOn = function(unit) e.targets[#e.targets + 1] = unit; return true end,
    }
    setmetatable(env, { __index = _G })
    local chunk = assert(loadstring("local ns = ...\n" .. CHUNK))
    setfenv(chunk, env)
    chunk(e.ns)
    e.env = env
    return e
end

local count = 0
local function Case(name, fn) fn(); count = count + 1; print("PASS " .. name) end

Case("a boss cast names the target on the alert already showing", function()
    local e = Fixture()
    e.db.castTargetBoss = true
    e.env.shownForEvent = "authored"
    -- 999 is watched by nothing, and nothing could watch it. That is the point.
    e.ns.OnBossCast("UNIT_SPELLCAST_START", "boss1", 999)
    assert(#e.targets == 1 and e.targets[1] == "boss1")
end)

Case("with no alert up there is nothing to write on", function()
    local e = Fixture()
    e.db.castTargetBoss = true
    e.ns.OnBossCast("UNIT_SPELLCAST_START", "boss1", 999)
    assert(#e.targets == 0)
end)

Case("a cast naming nobody still reaches the display, which clears the last name", function()
    -- Reached whatever the answer about the name is, so a stale name from an earlier cast
    -- is cleared rather than left sitting under a new callout.
    local e = Fixture()
    e.db.castTargetBoss, e.names = true, false
    e.env.shownForEvent = "authored"
    e.ns.OnBossCast("UNIT_SPELLCAST_START", "boss1", 999)
    assert(#e.targets == 1)
end)

Case("trash casts are not decorated on a guess", function()
    -- A pack has several casters and no way to say which one the alert is about.
    local e = Fixture()
    e.db.castTargetBoss = true
    e.env.shownForEvent = "authored"
    e.ns.OnBossCast("UNIT_SPELLCAST_START", "nameplate1", 999)
    assert(#e.targets == 0)
end)

Case("the boss switch off means no name", function()
    local e = Fixture()
    e.env.shownForEvent = "authored"
    e.ns.OnBossCast("UNIT_SPELLCAST_START", "boss1", 999)
    assert(#e.targets == 0)
end)

Case("the addon being switched off stops it before anything is asked", function()
    local e = Fixture()
    e.db.castTargetBoss, e.allowed = true, false
    e.env.shownForEvent = "authored"
    e.ns.OnBossCast("UNIT_SPELLCAST_START", "boss1", 999)
    assert(#e.targets == 0 and e.askedAbout == nil)
end)

Case("cast end is not a moment at which anybody is casting", function()
    local e = Fixture()
    e.db.castTargetBoss = true
    e.env.shownForEvent = "authored"
    e.ns.OnBossCast("UNIT_SPELLCAST_SUCCEEDED", "boss1", 999)
    assert(#e.targets == 0, "the cast is over; there is nobody to name")
end)

Case("the watcher arms for the name alone, with nothing indexed", function()
    -- There is nothing that could go in the index, so the index cannot be the gate here.
    local e = Fixture()
    e.env.currentEncounter = 3456
    e.db.castTargetBoss = true
    e.ns.RefreshCastWatch()
    assert(e.watcher.registered.UNIT_SPELLCAST_START)
    assert(e.ns.watchedCasts and next(e.ns.watchedCasts) == nil)
end)

Case("and comes off again when the switch does", function()
    local e = Fixture()
    e.env.currentEncounter = 3456
    e.db.castTargetBoss = true
    e.ns.RefreshCastWatch()
    e.db.castTargetBoss = nil
    e.ns.RefreshCastWatch()
    assert(e.watcher.off and next(e.watcher.registered) == nil)
end)

Case("an authored cast reminder still fires, and is named after it draws", function()
    local e = Fixture()
    e.db.castTargetBoss = true
    e.env.currentEncounter = 3456
    e.encounterSet = { c1 = { enabled = true, trigger = { type = "caststart", spellID = 111 } } }
    e.ns.RefreshCastWatch()
    e.ns.OnBossCast("UNIT_SPELLCAST_START", "boss1", 111)
    assert(e.authored, "the reminder waiting on that cast fired")
    assert(#e.targets > 0, "and the name went on after it drew")
end)

print(count .. " boss cast target regressions passed")

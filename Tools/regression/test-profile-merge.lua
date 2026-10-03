-- Merging a contributor's profile into one of yours. Several people maintain parts of
-- Robin's setup now, so the question is what a merge takes and, more importantly, what it
-- leaves alone.
local root = arg[1] or "."

local function Fixture()
    local e = { profiles = { Naowh = {}, Other = {} }, refreshed = 0 }
    local ns = {}
    ns.ListProfiles = function()
        local out = {}
        for name in pairs(e.profiles) do out[#out + 1] = name end
        table.sort(out)
        return out
    end
    ns.ProfileExists = function(name) return type(e.profiles[name]) == "table" end
    ns.EnsureProfile = function(name)
        if type(e.profiles[name]) ~= "table" then e.profiles[name] = {} end
        return e.profiles[name]
    end
    ns.RefreshRuntime = function() e.refreshed = e.refreshed + 1 end
    ns.ActiveProfileName = function() return "Naowh" end
    ns.Print = function(msg) e.printed = msg end
    -- ApplySettings only takes a key whose type matches the default, so the fixture has
    -- to answer for the one setting these cases carry.
    ns.SettingDefault = function(k) return k == "leadTime" and 2 or nil end
    ns.Integrations = { ValidRule = function() return true end }
    ns.UI = { Widgets = {} }
    ns.THEME = { accent = {}, muted = {}, fg = {}, panel = {}, bg = {}, line = {} }

    local env = setmetatable({ NaowhUITankReminder = ns,
        CreateFrame = function() return { SetScript = function() end } end,
    }, { __index = _G })
    env._G = env
    local chunk = assert(loadfile(root .. "/NaowhUI_SmartReminders_Packs.lua"))
    setfenv(chunk, env); chunk()
    e.ns, e.env = ns, env
    return e
end

-- One spec's worth of lists, plus a boss with one reminder on it. Trash rules and raid
-- reminders too, since those are the two that behave differently under a spec filter.
local function Data(specKey, uid)
    return {
        presets = { [specKey] = { p1 = { list = { 100 } } } },
        activePreset = { [specKey] = "p1" },
        abilityBindings = { [specKey] = { ["2001"] = { [10] = { enabled = true } } } },
        bossLists = { [specKey .. ":123"] = { 7 } },
        integrationRules = { [specKey] = { i1 = { name = "Theirs" } } },
        customReminders = { ["2001"] = {
            [uid] = { name = "Theirs", specID = tonumber(specKey), trigger = {} } } },
        raidReminders = { ["2001"] = { [uid] = { name = "Theirs raid", trigger = {} } } },
        callouts = { ["999"] = "Theirs" },
    }
end

local count = 0
local function Case(name, fn) fn(); count = count + 1; print("PASS " .. name) end

Case("a spec they maintain replaces yours, and specs they do not are left alone", function()
    local e = Fixture()
    local mine = e.ns.EnsureProfile("Naowh")
    mine.presets = { ["250"] = { p1 = { list = { 1 } } }, ["577"] = { p1 = { list = { 9 } } } }
    mine.activePreset = { ["250"] = "p1", ["577"] = "p1" }
    local ok, specs = e.ns.MergeProfileFromPack({ data = Data("250", "u1") }, nil, "Naowh")
    assert(ok and specs > 0)
    assert(mine.presets["250"].p1.list[1] == 100, "their spec came across whole")
    assert(mine.presets["577"].p1.list[1] == 9, "a spec they do not cover is untouched")
    assert(e.refreshed == 1)
end)

Case("reminders on a shared boss are added rather than swapped", function()
    local e = Fixture()
    local mine = e.ns.EnsureProfile("Naowh")
    mine.customReminders = { ["2001"] = { u0 = { name = "Mine", trigger = {} } } }
    local ok, _, entries = e.ns.MergeProfileFromPack({ data = Data("250", "u1") }, nil, "Naowh")
    assert(ok and entries == 1)
    assert(mine.customReminders["2001"].u0.name == "Mine", "your own reminder survives")
    assert(mine.customReminders["2001"].u1.name == "Theirs", "and theirs arrives beside it")
end)

Case("the copy is independent of the string it came from", function()
    local e = Fixture()
    local payload = { data = Data("250", "u1") }
    e.ns.MergeProfileFromPack(payload, nil, "Naowh")
    local mine = e.ns.EnsureProfile("Naowh")
    assert(mine.presets["250"] ~= payload.data.presets["250"])
    assert(mine.customReminders["2001"].u1 ~= payload.data.customReminders["2001"].u1)
end)

Case("a profile that is not here is refused rather than created", function()
    local e = Fixture()
    local ok, why = e.ns.MergeProfileFromPack({ data = Data("250", "u1") }, nil, "Missing")
    assert(ok == false and type(why) == "string")
    assert(e.profiles.Missing == nil, "nothing is invented")
    assert(e.refreshed == 0)
end)

Case("a whole-file string needs the profile named, and takes only that one", function()
    local e = Fixture()
    local payload = { profiles = { Theirs = Data("250", "u1"), Spare = Data("577", "u2") } }
    local ok, why = e.ns.MergeProfileFromPack(payload, nil, "Naowh")
    assert(ok == false and type(why) == "string")
    ok = e.ns.MergeProfileFromPack(payload, "Theirs", "Naowh")
    assert(ok)
    local mine = e.ns.EnsureProfile("Naowh")
    assert(mine.presets["250"] and not mine.presets["577"], "only the named profile came across")
end)

Case("their settings stay theirs unless asked for", function()
    local e = Fixture()
    local data = Data("250", "u1")
    data.settings = { leadTime = 9 }
    local mine = e.ns.EnsureProfile("Naowh")
    mine.leadTime = 2
    e.ns.MergeProfileFromPack({ data = data }, nil, "Naowh")
    assert(mine.leadTime == 2, "settings are not taken by default")
    e.ns.MergeProfileFromPack({ data = data }, nil, "Naowh", { settings = true })
    assert(mine.leadTime == 9, "and are taken when asked for")
end)

-- The reason the filter exists: a contributor works in a COPY of the profile they were
-- given, so their string carries every spec in it, most of them months stale.
Case("only the specs handed over move, whatever else their copy contains", function()
    local e = Fixture()
    local mine = e.ns.EnsureProfile("Naowh")
    mine.presets = { ["65"] = { p1 = { list = { 1 } } }, ["250"] = { p1 = { list = { 2 } } } }
    mine.customReminders = { ["2001"] = { u9 = { name = "My tank one", specID = 250, trigger = {} } } }
    mine.integrationRules = { ["250"] = { i1 = { name = "My tank rule" } } }
    -- Their copy carries both a healer spec and a stale tank spec.
    local theirs = Data("65", "u1")
    theirs.presets["250"] = { p1 = { list = { 999 } } }
    theirs.integrationRules["250"] = { i1 = { name = "Their stale tank rule" } }
    theirs.customReminders["2001"].u2 = { name = "Their stale tank one", specID = 250, trigger = {} }
    local ok = e.ns.MergeProfileFromPack({ data = theirs }, nil, "Naowh", { specs = { ["65"] = true } })
    assert(ok)
    assert(mine.presets["65"].p1.list[1] == 100, "the healer spec came across")
    assert(mine.presets["250"].p1.list[1] == 2, "their stale tank spec did not")
    assert(mine.integrationRules["250"].i1.name == "My tank rule", "nor their stale trash rules")
    assert(mine.customReminders["2001"].u9, "and my own reminder survives")
    assert(mine.customReminders["2001"].u2 == nil, "while theirs for an untaken spec stays out")
    assert(mine.customReminders["2001"].u1, "the reminder for the taken spec arrives")
end)

Case("a taken spec's trash rules are replaced whole, not one at a time", function()
    local e = Fixture()
    local mine = e.ns.EnsureProfile("Naowh")
    mine.integrationRules = { ["65"] = { i1 = { name = "Old one" }, i2 = { name = "Old two" },
        i3 = { name = "Old three" } } }
    local theirs = Data("65", "u1")
    theirs.integrationRules["65"] = { i1 = { name = "New one" } }
    e.ns.MergeProfileFromPack({ data = theirs }, nil, "Naowh", { specs = { ["65"] = true } })
    local left = 0
    for _ in pairs(mine.integrationRules["65"]) do left = left + 1 end
    assert(left == 1 and mine.integrationRules["65"].i1.name == "New one",
        "a three-rule set left behind is a half-merge, not a handover")
end)

Case("per-boss orders follow the spec their key names", function()
    local e = Fixture()
    local mine = e.ns.EnsureProfile("Naowh")
    mine.bossLists = { ["250:123"] = { 1 } }
    local theirs = Data("65", "u1")
    theirs.bossLists["250:123"] = { 42 }
    e.ns.MergeProfileFromPack({ data = theirs }, nil, "Naowh", { specs = { ["65"] = true } })
    assert(mine.bossLists["65:123"][1] == 7 and mine.bossLists["250:123"][1] == 1)
end)

Case("raid reminders and callouts name no spec, so a spec merge leaves them", function()
    local e = Fixture()
    local mine = e.ns.EnsureProfile("Naowh")
    e.ns.MergeProfileFromPack({ data = Data("65", "u1") }, nil, "Naowh", { specs = { ["65"] = true } })
    assert(mine.raidReminders == nil or mine.raidReminders["2001"] == nil)
    assert(mine.callouts == nil or mine.callouts["999"] == nil)
    e.ns.MergeProfileFromPack({ data = Data("65", "u1") }, nil, "Naowh",
        { specs = { ["65"] = true }, extras = true })
    assert(mine.raidReminders["2001"].u1 and mine.callouts["999"] == "Theirs")
end)

Case("an empty spec choice is refused rather than merging nothing", function()
    local e = Fixture()
    local ok, why = e.ns.MergeProfileFromPack({ data = Data("65", "u1") }, nil, "Naowh", { specs = {} })
    assert(ok == false and type(why) == "string")
end)

print(count .. " profile merge regressions passed")

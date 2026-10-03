local f = assert(io.open(arg[1] or "NaowhUI_SmartReminders.lua", "rb"))
local source = f:read("*a"):gsub("\r\n", "\n"); f:close()
local function Slice(a, b)
    local first = assert(source:find(a, 1, true))
    return source:sub(first, assert(source:find(b, first + #a, true)) - 1)
end
local function Fixture()
    local db = {
        presets = { ["250"] = { p = {} }, ["581"] = { mine1 = {} } },
        abilityBindings = { ["250"] = { ["3202"] = { [111] = { enabled = true, preset = "p" } } } },
        customReminders = { ["3202"] = {
            src = { defensive = true, specID = 250, preset = "p", name = "AMZ", dur = 5,
                trigger = { type = "bwmsg", spellID = 123, delay = "2" } },
            cast = { defensive = true, specID = 250, name = "Cast", trigger = { type = "cast", spellID = 9 } },
            mine = { defensive = true, specID = 581, name = "Mine", trigger = { type = "bwmsg", spellID = 456 } },
        }, ["4000"] = {
            other = { defensive = true, specID = 250, name = "Other", trigger = { type = "bwmsg", spellID = 789 } },
        } },
    }
    local env = { ns = { SpecName = function(k) return "spec" .. k end }, specID = 581,
        TRDB = function() return db end, GetTime = function() return 1 end,
        PresetsTable = function(spec) return db.presets[tostring(spec)] end,
        ActivePresetKey = function(spec) return next(db.presets[tostring(spec)] or {}) end }
    setmetatable(env, { __index = _G })
    local code = Slice("function ns.SpecsWithBindings(", "-- Copies another spec's bindings")
        .. Slice("function ns.CopyBindingsFromSpec(", "\nend\n") .. "\nend\n"
    local chunk = assert(loadstring(code)); setfenv(chunk, env); chunk()
    return env.ns, db
end
local function MessageReminders(set, spec)
    local out = {}
    for _, r in pairs(set) do
        if r.defensive and r.specID == spec and r.trigger.type == "bwmsg" then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.trigger.spellID < b.trigger.spellID end)
    return out
end
local count = 0
local function Case(name, fn) fn(); count = count + 1; print("PASS " .. name) end
Case("spec picker counts message reminders with the bindings", function()
    local ns = Fixture()
    local specs = ns.SpecsWithBindings(3202)
    assert(#specs == 1 and specs[1].key == "250" and specs[1].here == 2 and specs[1].total == 3)
    specs = ns.SpecsWithBindings(3202, { ["4000"] = true })
    assert(#specs == 1 and specs[1].here == 0 and specs[1].total == 1)
end)
Case("message reminders copy for one boss as independent entries", function()
    local ns, db = Fixture()
    local copied, skipped, reminders = ns.CopyBindingsFromSpec("250", 3202)
    assert(copied == 1 and skipped == 0 and reminders == 1)
    local set = db.customReminders["3202"]
    local got = MessageReminders(set, 581)
    assert(#got == 2 and got[1].trigger.spellID == 123 and got[1].dur == 5)
    -- "p" belongs to spec 250's preset table; this spec has no such key.
    assert(got[1].preset == "mine1" and set.src.preset == "p")
    assert(got[1] ~= set.src and got[1].trigger ~= set.src.trigger and set.src.specID == 250)
    assert(#MessageReminders(db.customReminders["4000"], 581) == 0)
end)
Case("cast-triggered and already-present reminders are left alone", function()
    local ns, db = Fixture()
    db.customReminders["3202"].src.trigger.spellID = 456
    local copied, skipped, reminders = ns.CopyBindingsFromSpec("250", 3202)
    assert(copied == 1 and skipped == 1 and reminders == 0)
    local n = 0
    for _ in pairs(db.customReminders["3202"]) do n = n + 1 end
    assert(n == 3)
end)
Case("whole-spec copy honours the encounter set", function()
    local ns, db = Fixture()
    local _, _, reminders = ns.CopyBindingsFromSpec("250", nil, { ["4000"] = true })
    assert(reminders == 1 and #MessageReminders(db.customReminders["4000"], 581) == 1)
    assert(#MessageReminders(db.customReminders["3202"], 581) == 1)
    _, _, reminders = ns.CopyBindingsFromSpec("250", nil)
    assert(reminders == 1 and #MessageReminders(db.customReminders["3202"], 581) == 2)
end)
Case("a source spec with only message reminders copies without erroring", function()
    local ns, db = Fixture()
    db.abilityBindings = {}
    local copied, skipped, reminders = ns.CopyBindingsFromSpec("250", 3202)
    assert(copied == 0 and skipped == 0 and reminders == 1)
    assert(#MessageReminders(db.customReminders["3202"], 581) == 2)
    local specs = ns.SpecsWithBindings(3202)
    assert(#specs == 1 and specs[1].total == 2)
end)
Case("a preset the destination also has keeps its key", function()
    local ns, db = Fixture()
    db.presets["581"].p = {}
    ns.CopyBindingsFromSpec("250", 3202)
    assert(MessageReminders(db.customReminders["3202"], 581)[1].preset == "p")
end)
Case("an all-spec reminder already here counts as a duplicate", function()
    local ns, db = Fixture()
    db.customReminders["3202"].mine.specID = nil
    db.customReminders["3202"].mine.trigger.spellID = 123
    local _, skipped, reminders = ns.CopyBindingsFromSpec("250", 3202)
    assert(skipped == 1 and reminders == 0)
end)
Case("two source variants on one key both come across, once", function()
    local ns, db = Fixture()
    db.customReminders["3202"].mine = nil
    db.customReminders["3202"].alt = { defensive = true, specID = 250, name = "3rd",
        trigger = { type = "bwmsg", spellID = 123, counter = "3" } }
    local _, _, reminders = ns.CopyBindingsFromSpec("250", 3202)
    assert(reminders == 2)
    local _, _, again = ns.CopyBindingsFromSpec("250", 3202)
    assert(again == 0 and #MessageReminders(db.customReminders["3202"], 581) == 2)
end)
print(count .. " copy-from-spec regressions passed")

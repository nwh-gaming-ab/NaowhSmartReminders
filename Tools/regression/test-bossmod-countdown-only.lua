local f = assert(io.open(arg[1] or "NaowhUI_SmartReminders.lua", "rb"))
local source = f:read("*a"):gsub("\r\n", "\n"); f:close()
local a = assert(source:find("local bwCdEndsAt = {}", 1, true))
local b = assert(source:find("local function OnDBMEvent", a, true))
local function Fixture()
    local e = { now = 0, tank = 0, raid = 0, custom = 0, observed = 0, catalog = 0 }
    local env = { ns = {
        BossSource = function() return "bigwigs" end,
        HandleBigWigsAbility = function() e.tank = e.tank + 1 end,
        HandleRaidReminderAbility = function() e.raid = e.raid + 1 end,
        ObserveCast = function() e.observed = e.observed + 1 end,
    }, GetTime = function() return e.now end, pendingBWFires = {},
        TRDB = function() return {} end, hasCustomReminders = true,
        CustomRemindersAllowed = function() return true end,
        RecordBossModKey = function() e.catalog = e.catalog + 1 end,
        CheckBossModTimerStart = function() e.custom = e.custom + 1 end,
        CheckBossModMessage = function() e.custom = e.custom + 1 end,
    }
    setmetatable(env, { __index = _G })
    local chunk = assert(loadstring(source:sub(a, b - 1) .. "\nreturn OnBigWigsEvent"))
    setfenv(chunk, env); e.event = chunk(); e.env = env
    function e:bar(approx, visible, text)
        if visible then self.event("BigWigs_StartBar", {}, 1307308, text, 15, 1, approx) end
        self.event("BigWigs_Timer", {}, 1307308, 15, nil, text, 1, 1, approx, visible)
    end
    return e
end
local cases = 0
local function Case(name, fn) fn(); cases = cases + 1; print("PASS " .. name) end
Case("Chillstorm countdown schedules once and delayed cast uptime never schedules", function()
    local e = Fixture(); e:bar(true, true, "Chillstorm (1)")
    assert(e.tank == 1 and e.raid == 1 and e.custom == 1 and e.observed == 1)
    -- Beyond the old 1.5s heuristic, with the early warning already consumed.
    e.now = 17
    e.event("BigWigs_StartBar", {}, 1307308, "Casting: Knockback", 11.5, 1, false)
    e.event("BigWigs_CastTimer", {}, 1307308, 11.5, nil, "Casting: Knockback", 0, 1,
        "Casting: Knockback", true)
    assert(e.tank == 1 and e.raid == 1 and e.custom == 1 and e.observed == 1,
        "cast uptime generated another reminder")
    assert(e.catalog == 1, "cast uptime entered the timer catalogue")
end)
Case("exact countdown works with bars shown or hidden", function()
    for _, visible in ipairs({ true, false }) do
        local e = Fixture(); e:bar(false, visible, "Exact countdown")
        assert(e.tank == 1 and e.raid == 1 and e.custom == 1 and e.catalog == 1)
    end
end)
Case("approximate countdown works with bars hidden", function()
    local e = Fixture(); e:bar(true, false, "Countdown")
    assert(e.tank == 1 and e.custom == 1)
end)
Case("visual preview without an ability key is ignored", function()
    local e = Fixture()
    e.event("BigWigs_StartBar", nil, nil, "Preview", 10)
    e.event("BigWigs_Timer", nil, nil, 10, nil, "Preview", 0, 1, false, false)
    assert(e.tank == 0 and e.catalog == 0)
end)
Case("verified Demonic Rage uptime skips timer and message without a preceding countdown", function()
    local e = Fixture(); e.env.currentEncounter = 3103
    local module = { engageId = 3103, GetRename = function(_, _, slot)
        return slot == 3 and "My renamed uptime" or "My renamed countdown"
    end }
    e.event("BigWigs_Timer", module, 474197, 15, nil, "My renamed uptime", 0, 1, false, true)
    e.event("BigWigs_Message", module, 474197, "My renamed uptime")
    assert(e.tank == 0 and e.raid == 0 and e.custom == 0 and e.observed == 0 and e.catalog == 0)
    e.event("BigWigs_Timer", module, 474197, 15, nil, "My renamed countdown (1)", 1, 1, true, true)
    e.event("BigWigs_Message", module, 474197, "My renamed countdown (1)")
    assert(e.tank == 2 and e.custom == 2 and e.catalog == 2)
end)
for _, mismatch in ipairs({ "encounter", "module", "key", "label", "duration", "approx", "collision", "missing", "error" }) do
    Case("uptime rule preserves unmatched " .. mismatch, function()
        local e = Fixture(); e.env.currentEncounter = 3103
        local module = { engageId = 3103, GetRename = function(_, _, slot)
            if mismatch == "error" then error("missing rename") end
            return (slot == 3 or mismatch == "collision") and "Uptime" or "Countdown"
        end }
        local key, label, duration, approx = 474197, "Uptime", 15, false
        if mismatch == "encounter" then e.env.currentEncounter = 2609
        elseif mismatch == "module" then module.engageId = 2609
        elseif mismatch == "key" then key = 123
        elseif mismatch == "label" then label = "Countdown"
        elseif mismatch == "duration" then duration = 30
        elseif mismatch == "approx" then approx = true
        elseif mismatch == "missing" then module.GetRename = nil end
        e.event("BigWigs_Timer", module, key, duration, nil, label, 0, 1, approx, true)
        assert(e.tank == 1 and e.raid == 1 and e.custom == 1 and e.observed == 1)
    end)
end
print(cases .. " boss-mod countdown regressions passed")

local file = assert(io.open(arg[1] or "NaowhUI_SmartReminders.lua", "rb"))
local source = file:read("*a"):gsub("\r\n", "\n"); file:close()
local function Slice(first, last)
    local a = assert(source:find(first, 1, true))
    local b = assert(source:find(last, a + #first, true))
    return source:sub(a, b - 1)
end
local scheduler = Slice("function ns.ScheduleBWFire(", "function ns.HandleBigWigsAbility(")
local cancel = Slice("local function CancelPendingBWFire(", "-- Both dispatchers below")
local fire = Slice("local function FireBigWigsAbility(", "-- Setup's per-ability Test button.")
local function Fixture()
    local e = { now = 0, timers = {}, calls = 0, checks = 0, logs = {}, readyAt = 9,
        db = { enabled = true, voiceOn = true, trace = true, coveredSkip = false },
        encounter = true, enabled = true, list = { 48265 }, builds = 0 }
    local env = { ns = {}, pendingBWFires = {}, SAME_CAST_WINDOW = 0.5,
        GetTime = function() return e.now end, TRDB = function() return e.db end,
        AppendLog = function(row) e.logs[#e.logs + 1] = row end,
        C_Timer = { NewTimer = function(delay, fn)
            local timer = { at = e.now + delay, fn = fn, Cancel = function(t) t.cancelled = true end }
            e.timers[#e.timers + 1] = timer
            return timer
        end },
        frame = { Show = function() end },
        ShouldRun = function() return true end,
        InEncounter = function() return e.encounter end,
        EffectiveList = function() return e.list end,
        IsSpellAvailable = function() return true end,
        IsSpellDisabled = function() return e.disabled end,
        ResyncSpell = function() end,
        SpellReady = function() return e.now >= e.readyAt end,
        RebuildSlots = function() e.builds = e.builds + 1; return true end,
        ApplyPriorityAlpha = function() end, ClearTankGate = function() end,
        SpeakCallout = function()
            if e.external or e.now >= e.readyAt then e.calls = e.calls + 1; return end
            return "waiting"
        end,
        HideReminder = function() end, DEFAULTS = { lingerSec = 5 },
    }
    env.ns.HasMessageDefensive = function() return false end
    env.ns.AbilityEnabledForBinding = function() return e.enabled end
    env.ns.BindingForBossModKey = function() return e.custom and { mode = "custom" } end
    setmetatable(env, { __index = _G })
    local chunk = assert(loadstring(scheduler .. cancel .. fire
        .. "\nreturn CancelPendingBWFire, CancelAllPendingBWFires, FireBigWigsAbility"))
    setfenv(chunk, env)
    e.stop, e.reset, e.fire = chunk()
    function e:advance(at)
        while true do
            local nextTimer
            for _, timer in ipairs(self.timers) do
                if not timer.cancelled and timer.at <= at
                    and (not nextTimer or timer.at < nextTimer.at) then nextTimer = timer end
            end
            if not nextTimer then break end
            nextTimer.cancelled = true; self.now = nextTimer.at; nextTimer.fn()
        end
        self.now = at
    end
    function e:schedule(identity, approximate, channel, duration)
        env.ns.ScheduleBWFire(channel or "tank", 1, duration or 10, identity or "gust", 2,
            function(sid, late)
                self.checks = self.checks + 1
                return self.fire(sid, late)
            end, approximate)
    end
    e.env = env
    return e
end
local cases = 0
local function Case(name, fn) fn(); cases = cases + 1; print("PASS " .. name) end
Case("late charge calls once before deadline without rebuilding while empty", function()
    local e = Fixture(); e:schedule(); e:advance(8.5)
    assert(e.calls == 0 and e.builds == 1)
    e:advance(12); assert(e.calls == 1 and e.builds == 2)
end)
Case("initial ready warning never retries", function()
    local e = Fixture(); e.readyAt = 0; e:schedule(); e:advance(12)
    assert(e.calls == 1 and e.checks == 1)
end)
Case("deadline expires before a later charge", function()
    local e = Fixture(); e.readyAt = 10; e:schedule(); e:advance(12)
    assert(e.calls == 0 and e.builds == 1)
    assert(next(e.env.pendingBWFires.tank[1]) == nil)
    assert(e.logs[#e.logs].text == "late-ready window expired")
end)
for _, approx in ipairs({ false, true }) do
    Case("bar stop cancels waiting, approximate=" .. tostring(approx), function()
        local e = Fixture(); e:schedule("gust", approx); e:advance(8.5)
        e.stop("gust"); e:advance(12); assert(e.calls == 0)
    end)
end
Case("encounter reset cancels waiting", function()
    local e = Fixture(); e:schedule(); e:advance(8.5); e.reset(); e:advance(12)
    assert(e.calls == 0)
end)
for _, change in ipairs({ "master", "voice", "encounter", "binding", "custom", "disabled", "empty" }) do
    Case("retry respects " .. change, function()
        local e = Fixture(); e:schedule(); e:advance(8.5)
        if change == "master" then e.db.enabled = false
        elseif change == "voice" then e.db.voiceOn = false
        elseif change == "encounter" then e.encounter = false
        elseif change == "binding" then e.enabled = false
        elseif change == "custom" then e.custom = true
        elseif change == "disabled" then e.disabled = true
        else e.list = {} end
        e:advance(12); assert(e.calls == 0)
    end)
end
Case("external request is terminal", function()
    local e = Fixture(); e.external = true; e:schedule(); e:advance(12)
    assert(e.calls == 1 and e.checks == 1)
end)
Case("raid channel does not gain retries", function()
    local e = Fixture(); e:schedule("raid", false, "raid"); e:advance(12)
    assert(e.calls == 0 and e.checks == 1)
end)
Case("same-cast alias stop cancels survivor", function()
    local e = Fixture(); e:schedule("bw", false); e:schedule("dbm", false)
    e:advance(8.5); e.stop("bw"); e:advance(12); assert(e.calls == 0)
end)
Case("reused identity supersedes waiting timer", function()
    local e = Fixture(); e:schedule(); e:advance(8.5); e:schedule()
    e:advance(12); assert(e.calls == 0)
    e:advance(20); assert(e.calls == 1)
end)
Case("production callout returns waiting only for a clean empty pick", function()
    -- From the set helpers rather than SpeakCallout itself: the callout resolves its Call
    -- Together line through them now, and a slice starting lower leaves them undefined.
    local speak = Slice("function ns.TogetherPartners(", "--  Showing and hiding")
    local e = { voiceOn = true, external = false, fail = false, ready = false, calls = 0 }
    local env = { ns = {
        ExternalCallFor = function() return e.external end,
        IsAudioOff = function() return true end,
        AnnounceExternalToChat = function() e.calls = e.calls + 1 end,
        Print = function() end, CalledTogetherInPreset = function() return false end,
        StartCDMGlow = function() end,
    }, TRDB = function() return e end, activeSlots = 1, slots = { { spellID = 48265 } },
        ResyncModel = function() end, GetTime = function() return 0 end,
        SpellReady = function() if e.fail then error("pick error") end; return e.ready end,
    }
    setmetatable(env, { __index = _G })
    local chunk = assert(loadstring(speak .. "\nreturn SpeakCallout")); setfenv(chunk, env)
    local call = chunk()
    assert(call(1) == "waiting")
    e.external = true; assert(call(1) == nil and e.calls == 1)
    e.external = false; e.fail = true; assert(call(1) == nil)
    e.fail = false; e.voiceOn = false; assert(call(1) == nil)
    e.voiceOn = true; e.ready = true; assert(call(1) == nil) -- Muted winner is terminal.
end)
print(cases .. " late-ready regressions passed")

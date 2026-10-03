local path = assert(arg[1])
local file = assert(io.open(path, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local begin = assert(source:find("local KNOWN_BASE_COOLDOWN = {", 1, true))
local finish = assert(source:find("local castToBase = {}", begin, true))
local chargeCode = source:sub(begin, finish - 1)
local castBegin = assert(source:find("local function NoteOwnCast(castSpellID)", finish, true))
local castEnd = assert(source:find("-- These three hang off ns", castBegin, true))
local castCode = source:sub(castBegin, castEnd - 1)
local compile = loadstring or load
local SID = 48265
local cases, failures = 0, 0
local function Fixture(recharge)
    recharge = recharge or 45
    local env = { time = 0, active = false, count = 2, plain = false,
        shape = true, max = 2, recharge = recharge, remaining = nil }
    local store = { clientRecharge = { [tostring(SID)] = recharge } }
    local spells = {
        GetSpellCharges = function()
            if not env.shape then return nil end
            return { maxCharges = env.max, isActive = env.active, currentCharges = env.count }
        end,
        GetSpellChargeDuration = function()
            if not env.remaining then return nil end
            return { GetTotalDuration = function() return env.recharge end,
                GetRemainingDuration = function() return env.remaining end }
        end,
        GetSpellCooldownDuration = function() return nil end,
    }
    local globals = { GetSpellBaseCooldown = function() return recharge * 1000 end, C_Spell = spells, GetTime = function() return env.time end,
        CanNameSpellAloud = function() return env.plain end,
        issecretvalue = function(v) return v == env.secret end,
        TRDB = function() return store end, AppendLog = function() end,
        ownCastAt = {}, castToBase = { [SID] = SID }, ns = {}, readyAt = {} }
    setmetatable(globals, { __index = _G })
    local code = chargeCode .. "\nCooldownRunning = function() return false end\n"
        .. castCode .. "\nreturn EnsureChargeState, ChargesAvailable, NoteOwnCast, chargeState"
    local chunk
    if setfenv then chunk = assert(compile(code)); setfenv(chunk, globals)
    else chunk = assert(load(code, "charge production code", "t", globals)) end
    env.ensure, env.available, env.cast, env.states = chunk()
    env.store, env.ns, env.readyAt = store, globals.ns, globals.readyAt
    env.ensure(SID)
    return env
end
local function Case(name, fn)
    cases = cases + 1
    local ok, err = pcall(fn)
    if ok then print("PASS " .. name)
    else failures = failures + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function Eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
Case("first cast spends one charge, not two", function()
    local e = Fixture()
    e.active, e.remaining, e.count = true, 45, 1
    e.cast(SID)
    Eq(e.states[SID].count, 1)
    Eq(e.available(SID), 1)
end)
Case("readable post-cast count is not debited twice", function()
    local e = Fixture()
    e.plain, e.active, e.remaining, e.count = true, true, 45, 1
    e.cast(SID)
    Eq(e.states[SID].count, 1)
    Eq(e.available(SID), 1)
    Eq(e.states[SID].count, 1)
end)
Case("missing charge shape does not invent a charge", function()
    local e = Fixture()
    e.states[SID].count = 0
    e.shape = false
    Eq(e.available(SID), 0)
end)
Case("one landing inferred then observed is counted once", function()
    local e = Fixture()
    e.states[SID].count = 0
    e.active, e.remaining = true, 45
    Eq(e.available(SID), 0)
    e.time, e.remaining = 46, nil
    Eq(e.available(SID), 1)
    e.states[SID].count = 0 -- spend that recovered charge
    e.time, e.remaining = 47, 43
    Eq(e.available(SID), 0)
end)
Case("full readable stack resets the old recharge anchor", function()
    local e = Fixture()
    e.states[SID].count, e.states[SID].rechargeStart = 0, 0
    e.time, e.plain, e.count = 100, true, 2
    Eq(e.available(SID), 2)
    Eq(e.states[SID].rechargeStart, nil)
end)
Case("two spends keep the original recharge deadline", function()
    local e = Fixture()
    e.active, e.remaining = true, 45
    e.cast(SID)
    e.time, e.remaining = 10, 35
    e.cast(SID)
    Eq(e.available(SID), 0)
    Eq(e.states[SID].tick, 0)
    e.time, e.remaining = 45, 45
    Eq(e.available(SID), 1)
    Eq(e.available(SID), 1)
    e.time, e.remaining, e.active = 90, nil, false
    Eq(e.available(SID), 2)
end)
Case("cast after an unobserved refill keeps the other charge", function()
    local e = Fixture()
    e.active, e.remaining = true, 45
    e.cast(SID)
    Eq(e.available(SID), 1)
    e.time, e.remaining = 50, 45
    e.cast(SID)
    Eq(e.states[SID].count, 1)
    Eq(e.available(SID), 1)
end)
Case("exact downward correction does not hide the next real landing", function()
    local e = Fixture()
    e.active, e.remaining = true, 45
    e.states[SID].count = 1
    Eq(e.available(SID), 1)
    e.time, e.remaining, e.count, e.plain = 30, 15, 0, true
    Eq(e.available(SID), 0)
    e.time, e.remaining, e.plain = 45, 45, false
    Eq(e.available(SID), 1)
end)
Case("cold start while recharging stays conservative", function()
    local e = Fixture()
    e.states[SID] = nil
    e.time, e.active, e.remaining = 20, true, 25
    e.ensure(SID)
    Eq(e.available(SID), 0)
    e.time, e.remaining = 45, 45
    Eq(e.available(SID), 1)
end)
Case("two elapsed recharges recover a full stack with an inactive flag", function()
    local e = Fixture()
    e.states[SID].count = 0
    e.time = 100
    Eq(e.available(SID), 2)
end)
Case("unexpected secret count is not compared", function()
    local e = Fixture()
    -- Emulate the secret classifier on a numeric result; Lua itself cannot
    -- manufacture WoW's secret-number tag outside the client.
    e.secret = 1
    e.count, e.plain = e.secret, true
    Eq(e.available(SID), 2)
end)
Case("idle cooldown cannot restore a spent charge before its deadline", function()
    local e = Fixture()
    e.active, e.remaining = true, 45
    e.cast(SID)
    e.time, e.remaining = 10, 35
    e.cast(SID)
    Eq(e.available(SID), 0)
    -- The recharge read temporarily disappears and the inactive flag returns.
    -- Neither is a charge landing: the tracked deadline is still 45 seconds.
    e.time, e.active, e.remaining = 11, false, nil
    Eq(e.available(SID), 0)
    Eq(e.available(SID), 0)
    e.time, e.active, e.remaining = 12, true, 33
    Eq(e.available(SID), 0)
    e.time, e.remaining = 45, 45
    Eq(e.available(SID), 1)
end)
Case("readable charge can recover before an estimated deadline", function()
    local e = Fixture()
    e.states[SID].count = 0
    e.time, e.plain, e.count = 10, true, 1
    Eq(e.available(SID), 1)
end)
Case("one elapsed recharge restores one spent charge, not the full stack", function()
    local e = Fixture()
    e.active, e.remaining = true, 45
    e.cast(SID)
    e.time, e.remaining = 23, 22
    e.cast(SID)
    Eq(e.available(SID), 0)
    e.time, e.active, e.remaining = 45, false, nil
    Eq(e.available(SID), 1)
end)
Case("Golden Serpent cast sequence stays empty after the fourth cast", function()
    local e = Fixture()
    e.active, e.remaining = true, 45
    e.cast(SID) -- 08:07:09
    Eq(e.available(SID), 1)
    e.time, e.remaining = 23, 22
    e.cast(SID) -- 08:07:32
    e.time, e.remaining = 64, 26
    Eq(e.available(SID), 1) -- 08:08:13
    e.time, e.remaining = 66, 24
    e.cast(SID) -- 08:08:15
    -- Exercise the ambiguous inactive read at the next recharge boundary.
    e.time, e.active, e.remaining = 90, false, nil
    e.available(SID)
    e.cast(SID) -- 08:08:39
    e.time, e.active, e.remaining = 129, true, 6
    Eq(e.available(SID), 0) -- 08:09:18: actual reported bad call
    e.time, e.remaining = 135, 45
    Eq(e.available(SID), 1)
end)
Case("readable recharge is not credited again by the next cast", function()
    local e = Fixture()
    e.cast(SID)
    e.time = 20; e.cast(SID)
    e.time, e.plain, e.count = 45, true, 1
    Eq(e.available(SID), 1)
    e.time, e.plain = 47, false
    e.cast(SID)
    Eq(e.available(SID), 0)
end)
Case("Ikuzz between-pull readable recovery does not invent a second charge", function()
    local e = Fixture()
    e.cast(SID) -- 12:19:55
    e.time = 20; e.cast(SID) -- 12:20:15
    e.time = 49; Eq(e.available(SID), 1) -- 12:20:44
    e.time = 80; e.cast(SID) -- 12:21:15
    -- Simulated readable count between pulls; this intermediate API read is not
    -- in the trace. It reproduces the failure without claiming its exact timing.
    e.time, e.plain, e.count = 90, true, 1
    Eq(e.available(SID), 1)
    e.time, e.plain = 92, false; e.cast(SID) -- 12:21:27
    e.time = 135; e.cast(SID) -- 12:22:10
    e.time = 149; Eq(e.available(SID), 0) -- 12:22:24
end)
Case("unchanged readable partial count consumes elapsed model intervals", function()
    local e = Fixture(); e.cast(SID)
    e.time, e.plain, e.count = 46, true, 1
    Eq(e.available(SID), 1)
    e.plain = false; e.cast(SID)
    Eq(e.available(SID), 0)
end)
Case("early readable refill does not immediately invent another charge", function()
    local e = Fixture(); e.cast(SID); e.time = 10; e.cast(SID)
    e.time, e.plain, e.count = 20, true, 1
    Eq(e.available(SID), 1)
    e.plain = false; e.cast(SID)
    e.time = 46; Eq(e.available(SID), 0)
end)
Case("automatic charge evidence is bounded and exports without trace", function()
    local e = Fixture()
    for i = 1, 100 do
        e.time = i * 100; e.plain = true; e.count = 2; e.available(SID)
        e.cast(SID)
    end
    Eq(#e.store.chargeAudit, 80)
    local out = {}; e.ns.AppendChargeAudit(out)
    assert(#out == 81 and out[81]:find("own cast", 1, true))
end)
Case("a shape blip does not refill an empty stack", function()
    local e = Fixture()
    e.cast(SID); e.cast(SID)
    e.active, e.remaining = true, 40
    Eq(e.available(SID), 0)
    -- A talent load, a spec change or the frames after a loading screen report the
    -- untalented shape, and the client stops describing the recharge at the same time.
    -- The count has to survive that and come back empty, not at a full stack.
    e.max, e.active, e.remaining = 1, false, nil
    e.ensure(SID)
    Eq(e.states[SID], nil)
    e.max = 2
    e.ensure(SID)
    Eq(e.available(SID), 0)
end)
Case("a shape blip does not reset the recharge anchor", function()
    local e = Fixture()
    e.cast(SID); e.cast(SID)
    e.active, e.remaining = true, 45
    Eq(e.available(SID), 0)
    e.time = 20
    e.max, e.active, e.remaining = 1, false, nil
    e.ensure(SID)
    e.max = 2; e.ensure(SID)
    -- 25 seconds of the recharge still to run, so still empty.
    e.time, e.remaining = 44, 1
    Eq(e.available(SID), 0)
    e.time, e.remaining = 46, nil
    Eq(e.available(SID), 1)
end)
Case("a rebuilt state stays empty while the client reports a recharge", function()
    local e = Fixture()
    -- isActive false and a readable recharge duration disagree. ChargesAvailable already
    -- trusts the duration over the flag; the seed has to as well, or it starts at max and
    -- the ceiling hands back max-1 for a stack that is empty.
    e.states[SID] = nil
    e.active, e.remaining = false, 30
    e.ensure(SID)
    Eq(e.available(SID), 0)
end)
Case("a shape change carries the count instead of reseeding it", function()
    local e = Fixture()
    e.cast(SID); e.cast(SID)
    e.active, e.remaining = true, 30
    Eq(e.available(SID), 0)
    e.max, e.active, e.remaining = 3, false, nil
    e.ensure(SID)
    Eq(e.states[SID].max, 3)
    Eq(e.available(SID), 0)
end)
Case("a lost counter comes back empty rather than full", function()
    local e = Fixture()
    e.cast(SID); e.cast(SID)
    e.active, e.remaining = true, 40
    Eq(e.available(SID), 0)
    -- Simulate a lost counter. The old trace did not capture the internal reset;
    -- this checks the failure path independently of the proposed live cause.
    e.states[SID] = nil
    e.active, e.remaining = false, nil
    e.ensure(SID)
    Eq(e.available(SID), 0)
end)
Case("REVIEW cast while the charge shape is missing must spend preserved count", function()
    local e = Fixture(); e.cast(SID) -- one charge remains
    e.time, e.max = 10, 1
    e.ensure(SID)
    e.cast(SID) -- spend the last charge while using the single-cooldown path
    assert(e.readyAt[SID] and e.readyAt[SID] > e.time)
    e.max = 2; e.ensure(SID)
    Eq(e.available(SID), 0)
end)
Case("REVIEW shape returns with a different maximum after temporary loss", function()
    local e = Fixture(); e.cast(SID); e.cast(SID)
    e.max, e.active, e.remaining = 1, false, nil; e.ensure(SID)
    e.max = 3; e.ensure(SID)
    Eq(e.available(SID), 0)
end)
Case("larger restored maximum cannot earn a charge from time spent full", function()
    local e = Fixture(); e.plain, e.count = true, 2
    Eq(e.available(SID), 2)
    e.time, e.plain, e.max = 100, false, 1; e.ensure(SID)
    e.max = 3; e.ensure(SID)
    Eq(e.available(SID), 2)
    Eq(e.states[SID].tick, 100)
end)
Case("cast just before estimated landing cannot earn the spent charge again", function()
    local e = Fixture(); e.cast(SID)
    e.time = 3.2; e.cast(SID)
    e.time = 44.99; e.cast(SID)
    e.time = 51.9; Eq(e.available(SID), 0)
    e.time = 90; Eq(e.available(SID), 1)
end)
Case("readable recharge after a zero-count cast establishes a fresh baseline", function()
    local e = Fixture(); e.cast(SID); e.cast(SID)
    e.active, e.remaining = true, 40
    e.time = 5; Eq(e.available(SID), 0)
    e.time, e.remaining = 44.99, nil; e.cast(SID)
    e.time, e.remaining = 51.9, 38.09
    Eq(e.available(SID), 0)
    e.time, e.remaining = 90, 44.99
    Eq(e.available(SID), 1)
end)
Case("readable count can correct a conservative zero-count cast baseline", function()
    local e = Fixture(); e.cast(SID); e.cast(SID)
    e.time = 44.99; e.cast(SID)
    e.time, e.plain, e.count = 46, true, 1
    Eq(e.available(SID), 1)
end)
-- Simulated 60-second charge configuration; verifies shared logic for Fiery Brand.
Case("Fiery Brand depletion survives charge-shape loss", function()
    local original = SID; SID = 204021
    local e = Fixture(60); e.cast(SID); e.cast(SID)
    e.time, e.max = 10, 1; e.ensure(SID)
    e.max = 2; e.ensure(SID)
    e.time = 59; Eq(e.available(SID), 0)
    e.time = 61; Eq(e.available(SID), 1)
    SID = original
end)
Case("Fiery Brand readable landing is not credited twice", function()
    local original = SID; SID = 204021
    local e = Fixture(60); e.cast(SID); e.cast(SID)
    e.time, e.plain, e.count = 61, true, 1; Eq(e.available(SID), 1)
    e.plain = false; e.cast(SID)
    e.time = 62; Eq(e.available(SID), 0)
    SID = original
end)
Case("Fiery Brand boundary cast consumes the pending landing", function()
    local original = SID; SID = 204021
    local e = Fixture(60); e.cast(SID); e.cast(SID)
    e.time = 59.99; e.cast(SID)
    e.time = 67; Eq(e.available(SID), 0)
    e.time = 120; Eq(e.available(SID), 1)
    SID = original
end)
print(cases .. " cases; " .. failures .. " failures")
if failures > 0 then os.exit(1) end

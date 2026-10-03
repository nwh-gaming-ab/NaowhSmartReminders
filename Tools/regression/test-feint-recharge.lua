-- Run against either the focused fix or the combined charge/messages test build.
local file = assert(io.open(assert(arg[1]), "rb"))
local source = file:read("*a"):gsub("\r\n", "\n"); file:close()
local function Slice(first, last)
    local a = assert(source:find(first, 1, true))
    local b = assert(source:find(last, a, true))
    return source:sub(a, b - 1)
end
local function Fixture(learned, client)
    local e = { now = 0, plain = false, count = 2 }
    local db = { learned = { ["1966"] = learned }, clientRecharge = { ["1966"] = client } }
    local env = {
        GetTime = function() return e.now end, TRDB = function() return db end,
        CanNameSpellAloud = function() return e.plain end,
        issecretvalue = function() return false end,
        AppendLog = function() end, ownCastAt = {}, readyAt = {},
        castToBase = { [1966] = 1966 }, ns = {},
        C_Spell = {
            GetSpellCharges = function()
                return { maxCharges = 2, isActive = false, currentCharges = e.count }
            end,
            GetSpellChargeDuration = function()
                if not e.total then return nil end
                return { GetTotalDuration = function() return e.total end,
                    GetRemainingDuration = function() return e.remaining end }
            end,
            GetSpellCooldownDuration = function() return nil end,
        },
    }
    setmetatable(env, { __index = _G })
    local code = Slice("local KNOWN_BASE_COOLDOWN = {", "local castToBase = {}")
        .. "\nCooldownRunning = function() return false end\n"
        .. Slice("local function NoteOwnCast(castSpellID)", "-- These three hang off ns")
        .. "\nreturn EnsureChargeState, ChargesAvailable, NoteOwnCast"
    local chunk = assert(loadstring(code)); setfenv(chunk, env)
    e.ensure, e.available, e.cast = chunk()
    e.state = e.ensure(1966)
    return e
end
local cases = 0
local function Eq(a, b) assert(a == b, "expected " .. b .. ", got " .. tostring(a)) end
local function Case(name, fn) fn(); cases = cases + 1; print("PASS " .. name) end
Case("Feint recovers two spent charges with no readable recharge", function()
    local e = Fixture()
    e.cast(1966); e.now = 1; e.cast(1966)
    Eq(e.available(1966), 0)
    e.now = 14.9; Eq(e.available(1966), 0)
    e.now = 15; Eq(e.available(1966), 1); Eq(e.available(1966), 1)
    e.now = 29.9; Eq(e.available(1966), 1)
    e.now = 30; Eq(e.available(1966), 2)
end)
Case("legacy 334 second measurement cannot pin Feint empty", function()
    local e = Fixture(334)
    Eq(e.state.recharge, 15)
    e.cast(1966); e.now = 1; e.cast(1966)
    e.now = 30; Eq(e.available(1966), 2)
end)
Case("short legacy estimate cannot invent an early Feint charge", function()
    local e = Fixture(6)
    e.cast(1966); e.now = 1; e.cast(1966)
    e.now = 14; Eq(e.available(1966), 0)
end)
Case("saved client recharge remains authoritative", function()
    local e = Fixture(334, 20)
    Eq(e.state.recharge, 20)
    e.cast(1966); e.now = 1; e.cast(1966)
    e.now = 15; Eq(e.available(1966), 0)
    e.now = 20; Eq(e.available(1966), 1)
end)
Case("live charge duration replaces the Feint fallback", function()
    local e = Fixture()
    e.cast(1966); e.now = 1; e.cast(1966)
    e.total, e.remaining = 20, 19
    Eq(e.available(1966), 0); Eq(e.state.recharge, 20)
    e.total, e.remaining = nil, nil
    e.now = 15; Eq(e.available(1966), 0)
    e.now = 20; Eq(e.available(1966), 1)
end)
Case("readable full stack corrects a conservative estimate", function()
    local e = Fixture()
    e.cast(1966); e.now = 1; e.cast(1966)
    e.plain, e.count = true, 2
    Eq(e.available(1966), 2)
end)
print(cases .. " Feint recharge regressions passed")

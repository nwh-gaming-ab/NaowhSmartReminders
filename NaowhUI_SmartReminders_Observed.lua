-------------------------------------------------------------------------------
--  NaowhUI_SmartReminders_Observed.lua -- what the boss actually did, recorded
--  from the player's own pulls.
--
--  The addon has always catalogued WHICH abilities a boss mod broadcasts
--  (bwCatalogue, with a seen count). This records WHEN, so a reminder can be
--  built from a real observed time instead of the player having to already know
--  that Ravenous Stomp lands at 0:03.
--
--  Two rules shape the whole file:
--
--  Nothing is written mid-pull. A bar is a countdown TO a cast, so a landing is
--  a PREDICTION until the bar survives to its own end; a stopped bar (a phase
--  change cancelling the rest, a resync) means the cast never happened.
--  Predictions live in memory for the pull and are committed once at
--  ENCOUNTER_END, keeping only those that actually landed before the pull
--  ended. That costs nothing in combat and keeps cancelled casts out of the data.
--
--  Storage aggregates on write, the same shape bwCatalogue proves: one entry per
--  ability per occurrence, carrying a running mean rather than a row per pull.
--  Growth is bounded by how many abilities a boss has, not by how many times it
--  has been pulled.
-------------------------------------------------------------------------------
local ns = _G.NaowhUITankReminder
if not ns then return end

local SCHEMA = 1              -- bump to retire every stored shape at once
local EXPIRY = 30 * 24 * 60 * 60
local MAX_SAMPLES = 10        -- mean stops averaging past this, so recent pulls keep moving it
local MAX_OCCURRENCES = 12    -- per ability; later casts of a long fight drift too far to be useful
local MAX_ABILITIES = 40      -- per encounter and difficulty
local SAME_CAST = 2           -- a message landing this close to a prediction is that same cast
local ENGAGE_GRACE = 3        -- boss mods broadcast their engage bars before our own
                              -- ENCOUNTER_START lands; casts this far ahead of the pull
                              -- still belong to it
local MAX_BUFFER = 200        -- bounds what accumulates outside an encounter

-- Live for the current pull only.
local pending = {}   -- [barIdentity] = { sid, mod, landing, stage, stageAt }
local landed = {}    -- array of { sid, mod, at, stage, stageAt }

-- The last pull this session committed, kept because ENCOUNTER_END clears the main file's
-- currentEncounter before anyone can type a slash command -- which left /nutank observed
-- answering "not in an encounter" at exactly the moment it was worth asking.
local lastPullEnc, lastPullDiff

function ns.ObservedLastPull()
    return lastPullEnc, lastPullDiff
end

-------------------------------------------------------------------------------
--  Storage
-------------------------------------------------------------------------------
-- At the SavedVariables ROOT, deliberately not inside a profile: this is a record of what
-- the game did, not a preference. In a profile it would be duplicated per profile and
-- wiped by Reset Profile, which would throw away weeks of pulls to change a setting.
local function Root()
    local sv = _G.NaowhUI_SmartRemindersDB
    if type(sv) ~= "table" then return nil end
    local o = sv.observed
    if type(o) ~= "table" or o.v ~= SCHEMA then
        o = { v = SCHEMA }
        sv.observed = o
    end
    return o
end

function ns.ObservedFor(encounterID, difficultyID)
    local o = Root()
    local enc = o and o[tostring(encounterID or 0)]
    if not enc then return nil end
    if difficultyID == nil then return enc end
    return enc[tostring(difficultyID)]
end

-- Which difficulties this encounter has data for, most recently updated first -- the UI
-- offers a picker only when there is more than one.
function ns.ObservedDifficulties(encounterID)
    local enc = ns.ObservedFor(encounterID, nil)
    local out = {}
    if type(enc) ~= "table" then return out end
    for diffKey, block in pairs(enc) do
        if type(block) == "table" then
            out[#out + 1] = { key = diffKey, at = block.at or 0, pulls = block.pulls or 0 }
        end
    end
    table.sort(out, function(a, b) return a.at > b.at end)
    return out
end

-- One pass at login. Nothing else in the addon prunes anything, so this store has to
-- carry its own housekeeping or it grows for the life of the account.
function ns.ObservedPrune()
    local o = Root()
    if not o then return end
    local cutoff = time() - EXPIRY
    for encKey, enc in pairs(o) do
        if encKey ~= "v" and type(enc) == "table" then
            for diffKey, block in pairs(enc) do
                if type(block) ~= "table" or (block.at or 0) < cutoff then
                    enc[diffKey] = nil
                end
            end
            if next(enc) == nil then o[encKey] = nil end
        end
    end
end

-------------------------------------------------------------------------------
--  Recording
-------------------------------------------------------------------------------
local function DropBefore(cutoff)
    for key, p in pairs(pending) do
        if p.at < cutoff then pending[key] = nil end
    end
    for i = #landed, 1, -1 do
        if landed[i].at < cutoff then table.remove(landed, i) end
    end
end

-- Not a wipe: the boss mods receive ENCOUNTER_START before we do and broadcast their
-- engage bars inside their own handler, so the opening cast -- usually the one worth
-- recording most -- arrives just BEFORE this runs. Anything older than the grace window
-- belonged to a previous pull or to trash and is dropped.
function ns.ObserveBeginPull()
    DropBefore(GetTime() - ENGAGE_GRACE)
end

function ns.ObserveCancel(barIdentity)
    if barIdentity ~= nil then pending[barIdentity] = nil end
end

function ns.ObserveCancelAll()
    wipe(pending)
end

-- duration present means a bar: a countdown to a cast that has not happened yet.
-- duration absent means a message: the cast is landing right now.
-- Times are recorded ABSOLUTE and made pull-relative at commit, so a cast that arrives
-- before our own ENCOUNTER_START (see ObserveBeginPull) is not lost for want of a clock.
function ns.ObserveCast(sid, mod, duration, barIdentity)
    if type(sid) ~= "number" or sid <= 0 then return end
    local startedAt, _, stage, stageAt = ns.PullContext()
    local now = GetTime()
    -- Outside a pull only the last ENGAGE_GRACE seconds can still be claimed by the next one;
    -- anything older is trash traffic that would otherwise pile up until then.
    if not startedAt then DropBefore(now - ENGAGE_GRACE) end

    if type(duration) == "number" and duration > 0.5 then
        local key = barIdentity
        if key == nil then key = "sid:" .. sid end
        pending[key] = { sid = sid, mod = mod, at = now, landing = now + duration,
            stage = stage, stageAt = stageAt }
        return
    end
    if #landed >= MAX_BUFFER then return end

    -- A module that pairs a bar with a message for the same cast would otherwise record
    -- it twice; the bar's own prediction is the one already accounted for.
    for key, p in pairs(pending) do
        if p.sid == sid and math.abs(p.landing - now) <= SAME_CAST then
            pending[key] = nil
            break
        end
    end
    landed[#landed + 1] = { sid = sid, mod = mod, at = now, stage = stage, stageAt = stageAt }
end

local function MergeSample(slot, t, stage, ts)
    if not slot.n then
        slot.t, slot.lo, slot.hi, slot.n = t, t, t, 1
    else
        local n = math.min(slot.n + 1, MAX_SAMPLES)
        slot.t = slot.t + (t - slot.t) / n
        slot.n = n
        if t < slot.lo then slot.lo = t end
        if t > slot.hi then slot.hi = t end
    end
    -- Phase-relative is the trustworthy anchor for later phases, whose start is
    -- health-gated rather than scheduled; pull-relative times there drift by whole
    -- seconds between pulls of different speed.
    if stage then
        slot.stage = stage
        if ts then slot.ts = slot.ts and (slot.ts + (ts - slot.ts) / (slot.n or 1)) or ts end
    end
end

function ns.ObserveCommitPull(encounterID, difficultyID)
    local startedAt = ns.PullContext()
    local endedAt = GetTime()
    if encounterID then
        lastPullEnc, lastPullDiff = encounterID, difficultyID
    end
    if not (startedAt and encounterID) then
        wipe(pending); wipe(landed)
        return
    end
    local pullDur = endedAt - startedAt

    -- A prediction still standing at the end only counts if its cast would have landed
    -- before the pull did: a wipe at 0:40 never saw the 4:30 mechanic.
    for _, p in pairs(pending) do
        if p.landing <= endedAt then
            landed[#landed + 1] = { sid = p.sid, mod = p.mod, at = p.landing,
                stage = p.stage, stageAt = p.stageAt }
            if #landed >= MAX_BUFFER then break end
        end
    end
    wipe(pending)

    if #landed == 0 then wipe(landed) return end
    table.sort(landed, function(a, b) return a.at < b.at end)

    local o = Root()
    if not o then wipe(landed) return end
    local encKey, diffKey = tostring(encounterID), tostring(difficultyID or 0)
    local enc = o[encKey]
    if type(enc) ~= "table" then enc = {}; o[encKey] = enc end
    local block = enc[diffKey]
    if type(block) ~= "table" then block = { casts = {} }; enc[diffKey] = block end
    if type(block.casts) ~= "table" then block.casts = {} end

    local abilityCount = 0
    for _ in pairs(block.casts) do abilityCount = abilityCount + 1 end

    local occurrence = {}
    for i = 1, #landed do
        local e = landed[i]
        local slotList = block.casts[e.sid]
        if not slotList and abilityCount < MAX_ABILITIES then
            slotList = { mod = e.mod }
            block.casts[e.sid] = slotList
            abilityCount = abilityCount + 1
        end
        if slotList then
            local idx = (occurrence[e.sid] or 0) + 1
            occurrence[e.sid] = idx
            if idx <= MAX_OCCURRENCES then
                local slot = slotList[idx]
                if type(slot) ~= "table" then slot = {}; slotList[idx] = slot end
                -- Clamped: an engage bar caught inside the grace window is a fraction of
                -- a second before the pull officially started, and a negative time would
                -- read as nonsense in the list.
                MergeSample(slot, math.max(0, e.at - startedAt), e.stage,
                    e.stageAt and math.max(0, e.at - e.stageAt) or nil)
            end
        end
    end

    block.pulls = (block.pulls or 0) + 1
    block.at = time()
    if pullDur > (block.longest or 0) then block.longest = pullDur end
    wipe(landed)
end

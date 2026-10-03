-- Optional trash predictions and native aura sounds. No aura data is read.
local ns = _G.NaowhUITankReminder
local I = {}
ns.Integrations = I
local pending, sounds = {}, {}
local delivered = setmetatable({}, { __mode = "k" })
local hooked, running = nil, false
local revision = 0
-- No cap on how many rules a spec may hold. The 32 that used to sit here was this addon's
-- own choice, not the client's: AddAuraSound has no documented limit, it returns nil when
-- the client declines a registration, and that refusal is already reported below. Worse,
-- the old count was of EVERY rule in the spec, so a spec with thirty trash rules could not
-- register a single debuff sound even though trash rules never touch that API at all.

-- Racial callouts that must stay quiet while the racial itself is unavailable. The client
-- plays these itself once the aura is registered with it, so there is no call of ours to
-- suppress: the FILE is muted instead. That is why each one needs a file of its own, and a
-- second copy for the preview that the gate never touches.
local RACIALS = {
    ["voice:stoneform-ready"] = { spellID = 20594, name = "Stoneform",
        preview = "voice:stoneform-preview" },
    ["voice:shadowmeld-ready"] = { spellID = 58984, name = "Shadowmeld",
        preview = "voice:shadowmeld-preview" },
}
-- Registration key -> the racial sound it belongs to, for the pending-changes comparison.
local gatedSounds = {}
local racialState = {}
for key in pairs(RACIALS) do racialState[key] = {} end
local events, racialEventsOn
local racialEvents = { "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_USABLE", "SPELLS_CHANGED",
    "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }
local function Plain(v) return not (issecretvalue and issecretvalue(v)) end
local function Table(v)
    return Plain(v) and type(v) == "table" and (not canaccesstable or canaccesstable(v))
end
local function Number(v, low, high)
    return Plain(v) and type(v) == "number" and v == v and v >= low and v <= high
end
function I.Spec()
    local index = GetSpecialization()
    return index and GetSpecializationInfo(index) or 0
end
function I.Rules(create)
    local db, spec = ns.DB(), tostring(I.Spec())
    if create then
        db.integrationRules = db.integrationRules or {}
        db.integrationRules[spec] = db.integrationRules[spec] or {}
    end
    return db.integrationRules and db.integrationRules[spec]
end
-- Read the installed timer provider's static catalogue; never copy or modify it.
-- Its dungeon keys are challenge IDs, while reminder filters are instance IDs.
function I.Catalogue()
    local api = _G.EXBossData
    if type(api) ~= "table" or type(api.GetTrashCDDataRoot) ~= "function"
        or type(api.GetEncounterDataRoot) ~= "function" then return {} end
    local ok, trash = pcall(api.GetTrashCDDataRoot)
    local mapsOK, encounter = pcall(api.GetEncounterDataRoot)
    if not ok or not mapsOK or not Table(trash) or not Table(encounter) then return {} end
    local byName, out = {}, {}
    for key, row in pairs(encounter.maps or encounter) do
        if type(row) == "table" and type(row.mapName) == "string" then
            local id = tonumber(row.instanceID or row.instanceId or row.mapID or key)
            if id then
                local prior = byName[row.mapName]
                if prior ~= nil and prior ~= id then byName[row.mapName] = false
                else byName[row.mapName] = id end
            end
        end
    end
    for key, dungeon in pairs(trash) do
        local instanceID = type(dungeon) == "table" and byName[dungeon.mapName]
        if instanceID then
            local name = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo(tonumber(key))
            local entry = { id = instanceID, name = name or dungeon.mapName, abilities = {} }
            local seen = {}
            for npcID, mob in pairs(dungeon.mobs or {}) do
                for spellID in pairs(mob.spells or {}) do
                    if type(spellID) == "number" and not seen[spellID] then
                        seen[spellID] = true
                        local info = C_Spell and C_Spell.GetSpellInfo(spellID)
                        local locale = (_G.EXBOSS_TRASH_CD_LOCALE or {})[npcID] or {}
                        entry.abilities[#entry.abilities + 1] = { spellID = spellID,
                            name = info and info.name or ("Spell " .. spellID),
                            icon = info and info.iconID,
                            mob = locale[GetLocale()] or locale.enUS or ("NPC " .. npcID) }
                    end
                end
            end
            table.sort(entry.abilities, function(a, b)
                if a.name == b.name then return a.spellID < b.spellID end
                return a.name < b.name
            end)
            out[#out + 1] = entry
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end
function I.ValidRule(r)
    if not Table(r) or not Table(r.trigger) or not Table(r.display) then return false end
    local t, d = r.trigger, r.display
    if t.type ~= "exboss" and t.type ~= "auraSound" then return false end
    if not Number(t.spellID, 1, 100000000) or t.spellID % 1 ~= 0
        or not Number(t.mapID, 0, 1000000) or t.mapID % 1 ~= 0 then return false end
    if type(r.name) ~= "string" or #r.name > 120 then return false end
    if r.enabled ~= nil and type(r.enabled) ~= "boolean" then return false end
    if r.healerReminder ~= nil and type(r.healerReminder) ~= "boolean" then return false end
    if not Number(d.dur, 1, 15) or type(d.text) ~= "string" or #d.text > 200 then return false end
    if d.sound ~= nil and (type(d.sound) ~= "string" or #d.sound > 200) then return false end
    if d.tts ~= nil and type(d.tts) ~= "boolean" then return false end
    if d.castRepeat ~= nil and type(d.castRepeat) ~= "boolean" then return false end
    if d.castAudio ~= nil and type(d.castAudio) ~= "boolean" then return false end
    if d.type ~= "icon" and d.type ~= "text" then return false end
    if d.spellID ~= nil and (not Number(d.spellID, 1, 100000000) or d.spellID % 1 ~= 0) then return false end
    if r.preset ~= nil and (type(r.preset) ~= "string" or #r.preset > 120) then return false end
    -- A racial you cast on yourself cannot answer for a debuff on somebody else.
    if RACIALS[d.sound] and (t.type ~= "auraSound" or t.target ~= "player") then return false end
    if t.type == "exboss" then return Number(t.timeleft, 0, 30) end
    return (t.target == "player" or t.target == "party")
        and (t.auraEvent == "Added" or t.auraEvent == "ApplicationsIncreased" or t.auraEvent == "Removed")
        and type(d.sound) == "string" and d.sound ~= "none" and d.sound ~= ""
end
local function Map()
    local _, kind, _, _, _, _, _, id = GetInstanceInfo()
    return id, kind
end
local function Eligible(r, kind)
    if not I.ValidRule(r) or r.trigger.type ~= kind or not ns.IsReminderEnabled(r)
        or ns.DB().enabled ~= true then return false end
    local map, instance = Map()
    return (instance == "party" or instance == "raid")
        and (r.trigger.mapID == 0 or r.trigger.mapID == map)
end
local function ClearPending(id)
    local entries = pending[id]
    pending[id] = nil
    if entries then
        for _, e in pairs(entries) do if e.handle then e.handle:Cancel() end end
    end
end
local function ClearAll()
    for id in pairs(pending) do ClearPending(id) end
    ns.PruneCustomReminderTimers()
end
-- One renderer for every reminder this addon draws: the preset resolution and the icon
-- both happen inside it, so a trash callout is the same object on screen as an authored
-- one rather than a lookalike built here.
local function Display(rule, preview)
    ns.DisplayIntegrationReminder(rule, preview)
end
function I.Preview(rule)
    if not I.ValidRule(rule) or not ns.IsReminderEnabled(rule, true) then return end
    if rule.trigger.type == "auraSound" then
        -- Preview has a separate file: never unmute a live registration for a test.
        local racial = RACIALS[rule.display.sound]
        if racial then
            ns.PlayReminderSound({ sound = racial.preview })
        else ns.PlayReminderSound(rule.display) end
    else
        ns.HideIntegrationReminders(true)
        Display(rule, true)
    end
end
local function TimerAt(scheduler, id)
    local all = scheduler:GetActiveTimers()
    return Table(all) and all[id] or nil
end
function I.ObserveTimer(scheduler, id)
    if not running or not Number(id, 1, 1000000000) then return end
    local timer = TimerAt(scheduler, id)
    if not Table(timer) or not Plain(timer.source) or timer.source ~= "trash"
        or not Number(timer.spellID, 1, 100000000) or not Number(timer.castTime, 0, 10000000000) then return end
    local rules = I.Rules(false)
    local at, generation = timer.castTime, revision
    local anchor
    if Plain(timer.trashFixedCombatTimeline) and timer.trashFixedCombatTimeline == true then
        anchor = at
    elseif Table(timer.trashRuntime) and Table(timer.trashRuntime.nextSpellAnchorAt) then
        local value = timer.trashRuntime.nextSpellAnchorAt[timer.spellID]
        if Number(value, 0, 10000000000) then anchor = value end
    end
    for uid, rule in pairs(rules or {}) do
        local prior = delivered[timer] and delivered[timer][rule]
        -- Anchor changes identify a new observed cast cycle. Without an anchor,
        -- keep deadline corrections quiet until the previously announced cycle ends.
        local alreadyDelivered = prior and ((anchor ~= nil and prior.anchor == anchor)
            or (anchor == nil and (prior.at == at or GetTime() < prior.at)))
        if alreadyDelivered then prior.at = at end
        if Eligible(rule, "exboss") and rule.trigger.spellID == timer.spellID
            and not alreadyDelivered then
            local old = pending[id] and pending[id][uid]
            if not old or old.at ~= at or old.anchor ~= anchor or old.rule ~= rule then
                if old and old.handle then old.handle:Cancel() end
                local entry = { at = at, anchor = anchor, rule = rule }
                pending[id] = pending[id] or {}
                pending[id][uid] = entry
                local function Valid()
                    if not running or revision ~= generation or I.Rules(false) ~= rules
                        or rules[uid] ~= rule or not Eligible(rule, "exboss")
                        or not pending[id] or pending[id][uid] ~= entry then return false end
                    local current = TimerAt(scheduler, id)
                    return Table(current) and current == timer and Plain(current.castTime) and current.castTime == at
                        and Plain(current.source) and current.source == "trash"
                end
                local delay = at - GetTime() - rule.trigger.timeleft
                if at > GetTime() then
                    local tracked = ns.TrackReminderTimer("exboss", math.max(0.01, delay), function()
                        entry.handle = nil
                        if Valid() then
                            entry.fired = true
                            delivered[timer] = delivered[timer] or setmetatable({}, { __mode = "k" })
                            delivered[timer][rule] = { at = at, anchor = anchor }
                            Display(rule)
                        end
                    end, nil, Valid)
                    entry.handle = tracked and tracked.handle
                end
            end
        end
    end
    ns.PruneCustomReminderTimers()
end
local NO_ENGINE = "|cffff6060ExBoss is missing or too old, so no trash alert can fire.|r "
    .. "The ability list needs it too."
-- The scheduler ExBoss hangs its trash timers off. One check answers for the whole tab:
-- EXBoss lists EXBossData, which the ability list is built from, in its RequiredDeps.
local function Engine()
    local scheduler = ExBoss and ExBoss.Timeline and ExBoss.Timeline.Scheduler
    if not scheduler or type(scheduler.GetActiveTimers) ~= "function"
        or type(scheduler.RegisterTrashLocalTimer) ~= "function"
        or type(scheduler._RemoveActiveTimerByID) ~= "function" then return nil end
    return scheduler
end
local function Connect()
    local scheduler = Engine()
    if not scheduler then
        I.trashStatus = NO_ENGINE
        return
    end
    if hooked and hooked ~= scheduler then
        I.trashStatus = "The trash timer engine changed; reload before using trash alerts."
        return
    end
    if not hooked then
        -- Compatibility adapter for the inspected Exboss scheduler. Post-hooks only;
        -- no method replacement, foreign state mutation, inferred spell IDs or polling.
        hooked = scheduler
        hooksecurefunc(scheduler, "RegisterTrashLocalTimer", function(self, runtime, _, spell)
            if not running or not Table(runtime) or not Table(spell)
                or not Number(spell.spellID, 1, 100000000) then return end
            local ids = runtime.localTimerIDsBySpellID
            if Table(ids) then I.ObserveTimer(self, ids[spell.spellID]) end
        end)
        -- Fixed combat timelines advance in place without RegisterTrashLocalTimer.
        if type(scheduler._AdvanceTrashFixedCombatTimeline) == "function" then
            hooksecurefunc(scheduler, "_AdvanceTrashFixedCombatTimeline", function(self, timer)
                if running and Table(timer) and Number(timer.id, 1, 1000000000) then
                    I.ObserveTimer(self, timer.id)
                end
            end)
        end
        hooksecurefunc(scheduler, "_RemoveActiveTimerByID", function(_, id)
            if not running or not Number(id, 1, 1000000000) then return end
            ClearPending(id)
            ns.PruneCustomReminderTimers()
        end)
    end
    I.trashStatus = "Trash timers connected. Alerts predict readiness, not a confirmed cast."
    local all = scheduler:GetActiveTimers()
    if Table(all) then for id in pairs(all) do I.ObserveTimer(scheduler, id) end end
end
local function RestrictionBusy()
    local api, types = C_RestrictedActions, Enum and Enum.AddOnRestrictionType
    if not (api and api.GetAddOnRestrictionState and types) then return false end
    return api.GetAddOnRestrictionState(types.Combat) ~= Enum.AddOnRestrictionState.Inactive
        or api.GetAddOnRestrictionState(types.Encounter) ~= Enum.AddOnRestrictionState.Inactive
end
local function AuraBusy()
    return InCombatLockdown() or (ns.InEncounter and ns.InEncounter()) or RestrictionBusy()
end
-- Every rung reads a plain value or refuses: an unreadable cooldown is not a ready racial.
local function RacialReady(spellID)
    if not (C_SpellBook and C_SpellBook.IsSpellKnown and C_Spell
        and C_Spell.GetSpellCooldown and C_Spell.IsSpellUsable and UnitIsDeadOrGhost) then return false, "API unavailable" end
    local known, dead = C_SpellBook.IsSpellKnown(spellID), UnitIsDeadOrGhost("player")
    if not Plain(known) or known ~= true then return false, "spell not known or unreadable" end
    if not Plain(dead) or dead ~= false then return false, "dead or unreadable player state" end
    local cd = C_Spell.GetSpellCooldown(spellID)
    if not Table(cd) or not Plain(cd.isActive) or not Plain(cd.isEnabled) then return false, "cooldown unreadable" end
    if cd.isActive ~= false or cd.isEnabled ~= true then return false, "cooldown active or on hold" end
    local usable = C_Spell.IsSpellUsable(spellID)
    if not Plain(usable) then return false, "usability unreadable" end
    if usable ~= true then return false, "spell unusable" end
    return true, "ready"
end
local function RacialStatusLine()
    local parts = {}
    for key, racial in pairs(RACIALS) do
        local st = racialState[key]
        if st.owned and st.reason then parts[#parts + 1] = racial.name .. ": " .. st.reason end
    end
    table.sort(parts)
    I.racialStatus = #parts > 0 and table.concat(parts, "  ") or nil
end
local function UpdateRacial(key)
    local st = racialState[key]
    if not st.owned then return end
    local ready, reason = false, "configuration pending or disabled"
    if st.enabled then ready, reason = RacialReady(RACIALS[key].spellID) end
    local muted = not ready
    if muted ~= st.muted then
        local path = ns.UI.SoundPathFor(key)
        if muted then MuteSoundFile(path) else UnmuteSoundFile(path) end
        st.muted = muted
    end
    -- SPELL_UPDATE_USABLE and SPELL_UPDATE_COOLDOWN drive this, so in combat it runs with
    -- an unchanged answer dozens of times a second. The status line is built from
    -- st.reason and nothing else, so an unchanged reason cannot change it -- rebuilding
    -- it regardless cost a table, a sort, a concat and two SetText layout passes per
    -- event. Keyed on reason rather than on `muted` because the two move independently:
    -- several distinct reasons all mean muted, and the line names which one.
    if reason == st.reason then return end
    st.reason = reason
    RacialStatusLine()
    if I.OnStatusChanged then I.OnStatusChanged() end
end
-- The readiness events are shared, so they follow whether ANY racial is being gated rather
-- than being registered once per racial on the same frame.
local function SyncRacialEvents()
    local any = false
    for key in pairs(RACIALS) do
        if racialState[key].enabled then any = true end
    end
    if any == racialEventsOn then return end
    racialEventsOn = any
    for _, event in ipairs(racialEvents) do
        if any then events:RegisterEvent(event) else events:UnregisterEvent(event) end
    end
end
local function SetRacialEnabled(key, enabled)
    enabled = enabled and MuteSoundFile ~= nil and UnmuteSoundFile ~= nil or false
    racialState[key].enabled = enabled
    SyncRacialEvents()
    UpdateRacial(key)
end
local function SetAllRacialsEnabled(enabled)
    for key in pairs(RACIALS) do SetRacialEnabled(key, enabled) end
end
local function RefreshSounds()
    -- Pending edits must not leave a stale profile's racial callout audible.
    SetAllRacialsEnabled(false)
    if not (C_UnitAuras and C_UnitAuras.AddAuraSound and C_UnitAuras.RemoveAuraSound
        and Enum and Enum.UnitAuraSoundTrigger) then
        I.auraStatus = "Aura sounds require the Retail AddAuraSound API."
        return
    end
    local wanted, missing = {}, false
    for _, rule in pairs(I.Rules(false) or {}) do
        if Eligible(rule, "auraSound") then
            local t, path = rule.trigger, ns.UI.SoundPathFor(rule.display.sound)
            local gated = RACIALS[rule.display.sound] and rule.display.sound or nil
            if gated and not (MuteSoundFile and UnmuteSoundFile) then path = nil end
            if type(path) == "string" and path ~= "" then
                local units = t.target == "party" and { "party1", "party2", "party3", "party4" } or { "player" }
                for _, unit in ipairs(units) do
                    local key = unit .. ":" .. t.spellID .. ":" .. t.auraEvent .. ":" .. path
                    wanted[key] = { trigger = Enum.UnitAuraSoundTrigger[t.auraEvent], gated = gated,
                        info = { unitToken = unit, spellID = t.spellID, soundFileName = path, outputChannel = "Master" } }
                end
            else
                missing = true
            end
        end
    end
    if AuraBusy() then
        local matched, any = true, false
        for key in pairs(gatedSounds) do
            any = true
            if not wanted[key] or not wanted[key].gated then matched = false end
        end
        for key, request in pairs(wanted) do
            if request.gated and not gatedSounds[key] then matched = false end
        end
        SetAllRacialsEnabled(any and matched)
        I.auraStatus = "Sound changes pending until combat and encounter restrictions end. Existing registrations remain active."
        return
    end
    for key, id in pairs(sounds) do
        if not wanted[key] then
            C_UnitAuras.RemoveAuraSound(id); sounds[key] = nil; gatedSounds[key] = nil
        end
    end
    local count, failed, live = 0, false, {}
    for key, request in pairs(wanted) do
        local st = request.gated and racialState[request.gated]
        if st and not st.owned then
            st.owned = true
            UpdateRacial(request.gated)
        end
        if not sounds[key] then sounds[key] = C_UnitAuras.AddAuraSound(request.trigger, request.info) end
        if sounds[key] then count = count + 1 else failed = true end
        if sounds[key] and request.gated then
            live[request.gated] = true
            gatedSounds[key] = request.gated
        end
    end
    for racialKey in pairs(RACIALS) do
        SetRacialEnabled(racialKey, live[racialKey] == true)
        local st = racialState[racialKey]
        -- Handing the file back unmuted: a racial nothing is registered for any more must
        -- not leave its clip silenced for everything else that might play it.
        if not live[racialKey] and st.owned then
            UnmuteSoundFile(ns.UI.SoundPathFor(racialKey))
            st.owned, st.muted, st.reason = nil, nil, nil
        end
    end
    RacialStatusLine()
    I.auraStatus = missing and "Some rules could not load: check the selected sound files."
        or failed and "Some aura sounds were not accepted by the client."
        or (count .. " aura sound registrations active. Changes apply outside combat.")
end
function I.Refresh()
    revision = revision + 1
    running = false
    ClearAll()
    if ns.HideIntegrationReminders then ns.HideIntegrationReminders() end
    for _, rule in pairs(I.Rules(false) or {}) do
        if Eligible(rule, "exboss") then running = true end
    end
    if not Engine() then I.trashStatus = NO_ENGINE
    elseif running then Connect()
    else I.trashStatus = "No enabled trash rules for this instance and spec." end
    RefreshSounds()
    -- The cast watch is built from these rules, and this is the one place that knows they
    -- changed: zoning, a spec swap and every edit all land here.
    if ns.RefreshCastWatch then ns.RefreshCastWatch() end
    if I.OnStatusChanged then I.OnStatusChanged() end
end
function I.Save(uid, rule)
    if not I.ValidRule(rule) then return false, "Check IDs, timing and sound. Stoneform voice requires Unit: Me." end
    local rules = I.Rules(true)
    if not uid then
        local index = 1
        while rules["i" .. index] do index = index + 1 end
        uid = "i" .. index
    end
    rules[uid] = rule
    I.Refresh()
    return true, uid
end

-- The same ability, watched the same way, at the same time, in the same place. Everything
-- the trigger uses is in it because this page deliberately allows more than one rule per
-- ability: a debuff sound for the player gaining an aura and one for the party losing it
-- are different rules, and so are two callouts on one spell at eight seconds and at two.
local function RuleKey(r)
    local t = r.trigger
    return table.concat({ tostring(t.type), tostring(t.spellID), tostring(t.mapID),
        tostring(t.target), tostring(t.auraEvent), tostring(t.timeleft) }, ":")
end

local function CopyRule(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, inner in pairs(v) do out[k] = CopyRule(inner) end
    return out
end

-- Which other specs have rules of this kind saved, and how many. Feeds the Copy From Spec
-- picker on whichever page asked; per-spec storage means a fresh spec starts empty.
--
-- kind is "exboss" or "auraSound". Each page copies only its own: the Trash button used to
-- drag debuff alerts across with it, which is not what a button on the trash page says it
-- does, and there was no way to move debuff alerts on their own at all.
local function OfKind(rule, kind)
    return Table(rule) and Table(rule.trigger)
        and (not kind or rule.trigger.type == kind)
end

function I.SpecsWithRules(kind)
    local db = ns.DB()
    local all = Table(db.integrationRules) and db.integrationRules or {}
    local mine, out = tostring(I.Spec()), {}
    for specKey, rules in pairs(all) do
        if specKey ~= mine and Table(rules) then
            local n = 0
            for _, r in pairs(rules) do if OfKind(r, kind) then n = n + 1 end end
            if n > 0 then
                out[#out + 1] = { key = specKey, name = ns.SpecName(specKey), total = n }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Copies another spec's trash and debuff rules into this one. Additive, the same rule the
-- boss pages' own Copy From Spec follows: a rule this spec already has for that ability is
-- left alone, so copying can never overwrite work already done here.
--
-- Each rule is copied rather than shared, and lands on a fresh uid: uids are sequential per
-- spec, so the source's own would collide with unrelated rules already saved here.
--
-- Returns copied, skipped and a third value kept at zero. There is no cap to run out of
-- any more, so nothing is ever left behind for want of room; the return is kept so callers
-- built against the old signature still read a number rather than nil.
function I.CopyRulesFromSpec(fromSpecKey, kind)
    local db = ns.DB()
    local all = Table(db.integrationRules) and db.integrationRules or nil
    local src = all and all[fromSpecKey]
    if not Table(src) then return 0, 0, 0 end
    local dst = I.Rules(true)
    if not Table(dst) then return 0, 0, 0 end

    local have = {}
    for _, r in pairs(dst) do
        if OfKind(r, kind) then have[RuleKey(r)] = true end
    end

    -- Sorted, so a copy that runs out of room takes the source's first rules rather than an
    -- arbitrary subset that changes between two presses of the same button.
    local uids = {}
    for uid in pairs(src) do uids[#uids + 1] = tostring(uid) end
    table.sort(uids)

    local copied, skipped, noRoom, index = 0, 0, 0, 1
    for i = 1, #uids do
        local r = src[uids[i]]
        if OfKind(r, kind) and I.ValidRule(r) then
            local key = RuleKey(r)
            if have[key] then
                skipped = skipped + 1
            else
                while dst["i" .. index] do index = index + 1 end
                dst["i" .. index] = CopyRule(r)
                have[key], copied = true, copied + 1
            end
        end
    end
    -- Once, not per rule: Refresh tears down and rebuilds every registration.
    if copied > 0 then I.Refresh() end
    return copied, skipped, noRoom
end
events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, name, state)
    if event == "ADDON_RESTRICTION_STATE_CHANGED" then
        if (name ~= Enum.AddOnRestrictionType.Combat and name ~= Enum.AddOnRestrictionType.Encounter)
            or state ~= Enum.AddOnRestrictionState.Inactive then return end
    end
    for _, gateEvent in ipairs(racialEvents) do
        if event == gateEvent then
            for key in pairs(RACIALS) do UpdateRacial(key) end
            return
        end
    end
    if event == "ADDON_LOADED" and name ~= "EXBoss" and name ~= "NaowhSmartReminders" then return end
    if event == "PLAYER_SPECIALIZATION_CHANGED" and name ~= "player" then return end
    I.Refresh()
end)
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
    "ENCOUNTER_END", "PLAYER_SPECIALIZATION_CHANGED", "ADDON_LOADED" }) do events:RegisterEvent(event) end
if C_RestrictedActions and C_RestrictedActions.GetAddOnRestrictionState then
    events:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
end

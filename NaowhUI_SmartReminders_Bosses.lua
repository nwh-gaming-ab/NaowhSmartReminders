-------------------------------------------------------------------------------
--  NaowhUI_SmartReminders_Bosses.lua -- browse this season's bosses and every ability the
--  journal lists for them, labelled by who each one is aimed at.
--
--  Every name, icon and tank marking is read out of the player's own client at runtime,
--  so it cannot go stale, it covers whatever season the client is on, and the addon
--  carries no encounter knowledge of its own. A shipped, BigWigs-GetOptions()-derived
--  phase-grouped filter was tried and dropped: BigWigs treats some tank-buster warnings
--  as always-on rather than a toggleable option, which GetOptions() never lists, so the
--  filter silently dropped real tank abilities across a wide range of bosses. Every
--  journal ability shows now, unfiltered.
--
--  The tank marking comes from the Encounter Journal, NOT from C_EncounterEvents. That is
--  deliberate and worth recording, because the other route looks tempting and is wrong:
--
--    * C_EncounterEvents carries the TankRole bit the live HUD uses, in the clear -- but it
--      has NO boss association in any form. No function takes an encounter ID, and no field
--      links a record back to one. Blizzard never calls the namespace from Lua at all; the
--      association lives C-side.
--    * Joining the two on spellID silently loses exactly the abilities we care about. The
--      journal's spellID is the DISPLAY spell (routinely the applied aura), while the event's
--      is the spell that TRIGGERS the cast. For a tank buster that casts one spell and applies
--      a stacking debuff -- which is most of them -- those are different IDs and the join
--      drops the ability. The docs also warn one spell may back several event records with
--      different masks, so the join is not even a function.
--
--  The journal's own Tank flag, by contrast, arrives already attached to its boss, from the
--  same walk that gives the name and icon. No join needed.
-------------------------------------------------------------------------------
local ns = _G.NaowhUITankReminder
if not ns then return end

-- GetSectionIconFlags returns INDICES into the flag list, not the enum values, so Tank (the
-- lowest bit, value 1) is index 0. Blizzard hardcodes the same 0 in its own role table.
--
-- EVERY ability is listed, not only tank-flagged ones: which abilities matter is the player's
-- call, and a healer or a damage dealer needs the same reference a tank does. The flags ride
-- along as labels so the list still says who each one is aimed at.
local FLAG_LABELS = {
    [0]  = "Tank",
    [1]  = "Dps",
    [2]  = "Healer",
    [3]  = "Heroic",
    [4]  = "Deadly",
    [5]  = "Important",
    [6]  = "Interruptible",
    [7]  = "Magic",
    [13] = "Bleed",
}

-- Shared by every row that shows a FLAG_LABELS role off ability.extras: the boss-detail
-- ability list and the Add Abilities picker both colour Tank/Dps/Healer this way, and a
-- second copy of this table would just be a second place for the colours to drift apart.
local ROLE_COLOR = { Tank = "|cffF0A830", Dps = "|cffFF6060", Healer = "|cff6DD09A" }

-------------------------------------------------------------------------------
--  Journal availability
-------------------------------------------------------------------------------
-- Blizzard_EncounterJournal is load-on-demand, so the EJ_ globals do not exist until
-- something has opened it. We load it ourselves rather than telling the user to go and open
-- the dungeon journal first.
-- Second return is true only when THIS call is the one that just triggered the on-demand
-- load -- confirmed live (raid boss descriptions came back empty on the session's first
-- scrape, then correct after a reload) that scraping the instant the module loads can
-- catch some of its data before the Journal has finished populating it. ScrapeBosses
-- uses this to queue one silent re-scrape rather than leave a whole session stuck with
-- whatever the cold first pass happened to catch.
local function EnsureJournal()
    if EJ_GetCurrentTier and C_EncounterJournal and C_EncounterJournal.GetSectionInfo then
        return true, false
    end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
    end
    local ok = EJ_GetCurrentTier ~= nil and C_EncounterJournal ~= nil
        and C_EncounterJournal.GetSectionInfo ~= nil
    return ok, ok
end

-- EJ_SelectTier and EJ_SelectInstance mutate journal state that the Encounter Journal UI
-- reads back with no arguments, and it caches its own copy that will not resync. Scraping
-- underneath an open journal corrupts what the player is looking at. Blizzard evidently hit
-- this too -- there is a commented-out EJ_SelectInstance in their own content-tracking code.
local function JournalBusy()
    return EncounterJournal ~= nil and EncounterJournal:IsShown()
end

-------------------------------------------------------------------------------
--  The scrape
-------------------------------------------------------------------------------
-- In memory, built on first view and kept for the session. Nothing is scraped at login: a
-- player who never opens this page pays nothing for it.
local cache          -- { instances = { {id, name, isRaid, bosses = { {name, abilities} } } } }
local scrapeFailed
local rescrapeQueued
-- Stage-by-stage record of the last scrape, so an empty panel can say WHICH step produced
-- nothing rather than just looking broken. Read by /nutank bosses.
local diag = {}

local function WalkSections(rootID, out, depth, seen)
    -- Depth-capped: the section tree is authored data and a malformed cycle would otherwise
    -- hang the client rather than produce a bad list.
    if not rootID or depth > 12 then return end
    seen = seen or {}
    local id = rootID
    local guard = 0
    while id and guard < 200 do
        guard = guard + 1
        local info = C_EncounterJournal.GetSectionInfo(id)
        if not info then break end

        local flags = C_EncounterJournal.GetSectionIconFlags(id)
        local extras
        if flags then
            for i = 1, #flags do
                local lbl = FLAG_LABELS[flags[i]]
                if lbl then extras = extras and (extras .. ", " .. lbl) or lbl end
            end
        end

        -- A real ability, not a section header. The journal groups its advice under headers
        -- like "Tanks" and "Healers", and those carry the tank icon flag too -- but they have
        -- no spell behind them, which is what tells the two apart.
        local isAbility = info.spellID and info.spellID > 0
        -- Casts only. The journal also lists passives -- auras that empower the boss's
        -- melee, say -- and a passive is never an event: nothing announces it, nothing can
        -- warn about it, and a reference list is for things a tank can react to. The spell
        -- record itself knows, which beats any name list and covers every boss.
        if isAbility and C_Spell and C_Spell.IsSpellPassive then
            local okP, passive = pcall(C_Spell.IsSpellPassive, info.spellID)
            if okP and passive == true then isAbility = false end
        end
        if isAbility and info.title and info.title ~= "" then
            -- One row per spell. The journal repeats the same ability under its overview,
            -- its per-role advice and its stage sections, and rendering each occurrence
            -- made every boss look like it had twice the abilities it does. Later
            -- occurrences only contribute role labels the first one lacked.
            local prior = seen[info.spellID]
            if prior then
                if (not prior.description or prior.description == "")
                    and info.description and info.description ~= "" then
                    prior.description = info.description
                end
                if extras and extras ~= "" then
                    if not prior.extras or prior.extras == "" then
                        prior.extras = extras
                    else
                        -- Per-label, not the whole blob: a later occurrence carrying two
                        -- flags where the first only had one ("Heroic, Deadly" showing up
                        -- after a prior "Heroic") would never substring-match as a whole,
                        -- appending the already-present label a second time.
                        for label in extras:gmatch("[^,]+") do
                            label = label:match("^%s*(.-)%s*$")
                            if label ~= "" and not prior.extras:find(label, 1, true) then
                                prior.extras = prior.extras .. ", " .. label
                            end
                        end
                    end
                end
            else
                local entry = {
                    title       = info.title,
                    spellID     = info.spellID,
                    icon        = info.abilityIcon,
                    extras      = extras,
                    -- The journal's own explanation of what the ability does, for the
                    -- hover tooltip. Blizzard's text, not ours.
                    description = info.description,
                }
                seen[info.spellID] = entry
                out[#out + 1] = entry
            end
        end

        WalkSections(info.firstChildSectionID, out, depth + 1, seen)
        id = info.siblingSectionID
    end
end

-- mapID is the instance map id (GetInstanceInfo's 8th return; what pack TOCs declare in
-- X-BigWigs-LoadOn-InstanceId), kept so a boss page can ask BigWigs for just this
-- instance's pack rather than every pack installed.
local function ScrapeInstance(instanceID, name, isRaid, mapID)
    local entry = { id = instanceID, name = name, isRaid = isRaid, mapID = mapID, bosses = {} }

    EJ_SelectInstance(instanceID)
    for i = 1, 40 do
        local bossName, _, bossID = EJ_GetEncounterInfoByIndex(i)
        if not bossName then break end
        if bossID then
            -- Return 7 is dungeonEncounterID: the same id ENCOUNTER_START reports, which is
            -- what makes a list set up here fire on the right boss.
            local _, _, _, rootSectionID, _, _, dungeonEncounterID = EJ_GetEncounterInfo(bossID)
            local abilities = {}
            WalkSections(rootSectionID, abilities, 1)
            entry.bosses[#entry.bosses + 1] = {
                name = bossName,
                encounterID = dungeonEncounterID,
                abilities = abilities,
            }
        end
    end
    return entry
end

function ns.ScrapeBosses(force)
    if cache and not force then return cache end
    local journalOk, freshLoad = EnsureJournal()
    if not journalOk then scrapeFailed = "journal" return nil end
    if JournalBusy() then scrapeFailed = "busy" return nil end
    scrapeFailed = nil

    -- Put the journal back exactly as we found it. The UI keeps its own copy of the
    -- selection and will not notice ours, so leaving it moved is a real bug for anyone who
    -- opens the journal afterwards.
    local priorTier = EJ_GetCurrentTier and EJ_GetCurrentTier()

    local out = { instances = {} }
    wipe(diag)
    diag.tier = priorTier

    -- Mythic+ pool: this is the live season list, the same call Blizzard's own keystone UI
    -- uses, so it needs no season constant of ours and updates itself.
    if C_ChallengeMode and C_ChallengeMode.GetMapTable and C_EncounterJournal.GetInstanceForGameMap then
        local maps = C_ChallengeMode.GetMapTable()
        diag.mapCount = maps and #maps or 0
        diag.mapped = 0
        for i = 1, (maps and #maps or 0) do
            local mapName, _, _, _, _, gameMapID = C_ChallengeMode.GetMapUIInfo(maps[i])
            local journalID = gameMapID and C_EncounterJournal.GetInstanceForGameMap(gameMapID)
            if journalID then
                diag.mapped = diag.mapped + 1
                out.instances[#out.instances + 1] = ScrapeInstance(journalID, mapName or "?", false, gameMapID)
            end
        end
    else
        diag.mapCount = -1   -- the API itself was unavailable
    end

    -- Current raid. There is no "give me the latest raid" API, so this is the current tier's
    -- raid list, newest last, which is the same heuristic the journal itself leans on.
    diag.raids = 0
    if EJ_SelectTier and EJ_GetInstanceByIndex and priorTier then
        EJ_SelectTier(priorTier)
        for i = 1, 20 do
            local instanceID, rname = EJ_GetInstanceByIndex(i, true)
            if not instanceID then break end
            diag.raids = diag.raids + 1
            -- The instance map id is EJ_GetInstanceInfo's 10th return; Blizzard's own journal
            -- destructures past it to covenantID at 11.
            local _, _, _, _, _, _, _, _, _, raidMapID = EJ_GetInstanceInfo(instanceID)
            out.instances[#out.instances + 1] = ScrapeInstance(instanceID, rname or "?", true, raidMapID)
        end
    end

    diag.instances = #out.instances
    diag.bosses = 0
    for i = 1, #out.instances do diag.bosses = diag.bosses + #out.instances[i].bosses end

    if priorTier and EJ_SelectTier then EJ_SelectTier(priorTier) end

    cache = out

    -- A module loaded on-demand this exact instant is not always fully populated yet.
    -- One silent re-scrape a moment later catches up without the player needing to
    -- notice or hit Refresh themselves. freshLoad is only ever true on the very first
    -- scrape of a session (EnsureJournal reports the module as already loaded on any
    -- later call, including this retry), so this can only ever queue once.
    if freshLoad and not rescrapeQueued then
        rescrapeQueued = true
        C_Timer.After(2, function()
            rescrapeQueued = false
            if JournalBusy() then return end
            ns.ScrapeBosses(true)
            local EUI = ns.UI
            if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
        end)
    end

    return cache
end

-------------------------------------------------------------------------------
--  BigWigs ability lists
-------------------------------------------------------------------------------
-- The journal documents everything -- per-difficulty variants, sub-abilities, whole
-- mechanics BigWigs never warns about -- so the flat journal listing carried rows whose
-- checkbox could never do anything: the engine only ever receives what BigWigs actually
-- broadcasts, and that set is the module's own option list. When a boss has a BigWigs
-- module installed, the page lists exactly that (mod.toggleOptions, the same set
-- BigWigs' own options UI shows), keyed by the ids the engine will receive. Bosses with
-- no module keep the full journal listing.
local bwOptionCache = {}   -- [dungeonEncounterID] = { {id, stage}, ... }, or false
local bwPacksLoaded, bwPacksLoading, bwPackNames

-- Content packs are LoadOnDemand and never loaded outside their own zone; BigWigs' own
-- options UI force-loads them the same way when browsing. Core comes in through each
-- pack's dependencies. Once per session, and only for someone who opens the options
-- window. LittleWigs' expansion packs are included because the season's dungeon rotation
-- reaches back into old expansions.
local function BossModPackNames()
    if bwPackNames then return bwPackNames end
    bwPackNames = {}
    if not (C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetAddOnInfo) then
        return bwPackNames
    end
    for i = 1, C_AddOns.GetNumAddOns() do
        local name = C_AddOns.GetAddOnInfo(i)
        if type(name) == "string"
            and (name:find("^BigWigs_") or name:find("^LittleWigs"))
            and name ~= "BigWigs_Plugins" and name ~= "BigWigs_Options" then
            bwPackNames[#bwPackNames + 1] = name
        end
    end
    return bwPackNames
end

-- Loading every installed BigWigs/LittleWigs pack in one go froze the client for about
-- five seconds the first time a boss page wanted an option list -- 22 synchronous
-- LoadAddOn calls on this machine. Same work, one pack per frame, so the client keeps
-- drawing through it and the page refreshes itself when the last one lands.
--
-- Fallback only, now that BigWigsOptionList asks BigWigs to load the one pack an instance
-- needs. Reached when there is no map id for the instance or the installed BigWigs is too
-- old to have LoadZone. Never runs on window open any more: doing so held the client at
-- single-digit FPS through all 22 loads, on a tab that used none of them.
-- A content pack's own !Options.lua indexes the BigWigs global while it loads, so loading
-- one before the core is up throws inside BigWigs' loader -- out of reach of any pcall of
-- ours, since it happens in their event handler. Reported from the options window with
-- BigWigs installed but not yet loaded: "BigWigs_TheVenomousAbyss/!Options.lua:3: attempt
-- to index global 'BigWigs' (a nil value)", twice.
--
-- The core is load-on-demand as well, so ask for it first. If it will not come up there is
-- nothing to read anyway and the caller falls back to the journal listing.
local function BossModCoreUp()
    if _G.BigWigs then return true end
    if C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn, "BigWigs_Core") end
    return _G.BigWigs ~= nil
end

local function LoadBossModPacks()
    if bwPacksLoaded or bwPacksLoading then return end
    -- Returns without latching bwPacksLoaded: the core comes up by itself on zoning into an
    -- instance, and marking the sweep done here would stop it ever being tried again.
    if not BossModCoreUp() then return end
    if not (C_AddOns and C_AddOns.LoadAddOn and C_Timer and C_Timer.NewTicker) then
        bwPacksLoaded = true
        return
    end
    local names = BossModPackNames()
    if #names == 0 then bwPacksLoaded = true return end
    bwPacksLoading = true
    local i = 0
    C_Timer.NewTicker(0, function(ticker)
        i = i + 1
        if i > #names then
            ticker:Cancel()
            bwPacksLoading, bwPacksLoaded = false, true
            local EUI = ns.UI
            if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
            return
        end
        C_AddOns.LoadAddOn(names[i])
    end)
end
ns.LoadBossModPacks = LoadBossModPacks


local function BigWigsOptionList(encounterID, mapID)
    -- Some journal rows carry no dungeonEncounterID (EJ_GetEncounterInfo's 7th return can
    -- be nil) -- a nil TABLE WRITE below would throw, unlike the read just above, which
    -- Lua allows. Nothing to look up without an id anyway; falls through to the journal
    -- listing the same as "no module found" does.
    if encounterID == nil then return nil end
    local cached = bwOptionCache[encounterID]
    if cached ~= nil then return cached or nil end
    -- BigWigs' own loader knows which pack covers an instance, so ask it for that one
    -- pack: a single synchronous load the first time this instance's page opens. Loading
    -- all 22 installed packs one per frame -- the old approach, kicked off on ANY window
    -- open -- held the client at single-digit FPS for the whole run of them, on the Setup
    -- tab where none of it was even used. LoadZone is a no-op for an unknown zone.
    if mapID and BigWigsLoader and BigWigsLoader.LoadZone and BossModCoreUp() then
        pcall(BigWigsLoader.LoadZone, BigWigsLoader, mapID)
    elseif mapID and BigWigsLoader and BigWigsLoader.LoadZone then
        -- Core refused to load: nothing to look up, and the sweep below would hit the same
        -- wall one pack at a time. NOT cached -- the core comes up on its own when the
        -- player zones into an instance, and a false pinned here would say "no module for
        -- this boss" for the rest of the session.
        return nil
    else
        -- No map id or an old BigWigs without LoadZone: fall back to the sweep, but only
        -- from here, where the result is actually wanted.
        LoadBossModPacks()
        -- Nothing is recorded as "no module for this boss" until every pack has actually
        -- landed, or the first look during the load pins an empty answer for the session.
        if bwPacksLoading then return nil end
    end
    local core = _G.BigWigs
    if not (core and type(core.IterateBossModules) == "function") then
        bwOptionCache[encounterID] = false
        return nil
    end
    local target
    for _, m in core:IterateBossModules() do
        if m.IsEncounterID and m:IsEncounterID(encounterID) then target = m break end
    end
    -- BigWigs core resolves a module's GetOptions into toggleOptions/optionHeaders via
    -- SetupOptions and drops GetOptions; its own options UI calls SetupOptions before
    -- reading too, in case that has not run yet.
    if target and target.SetupOptions then target:SetupOptions() end
    local toggles = target and target.toggleOptions
    if type(toggles) ~= "table" then
        bwOptionCache[encounterID] = false
        return nil
    end
    -- optionHeaders marks the option a group starts at, values already resolved by core
    -- to display strings (stage names from the journal, "Mythic", ...). Carried onto
    -- every following entry so the render loop only has to compare neighbours.
    -- Entries can be plain ids or {id, flag, ...} tables; string options ("stages",
    -- "berserk") are BigWigs UI plumbing, not abilities, and never broadcast as keys.
    local headers = target.optionHeaders
    local list, seen, stage = {}, {}, nil
    for i = 1, #toggles do
        local opt = toggles[i]
        if type(opt) == "table" then opt = opt[1] end
        if headers and headers[opt] ~= nil then stage = tostring(headers[opt]) end
        if type(opt) == "number" and opt > 0 and not seen[opt] then
            seen[opt] = true
            list[#list + 1] = { id = opt, stage = stage }
        end
    end
    if #list == 0 then
        bwOptionCache[encounterID] = false
        return nil
    end
    bwOptionCache[encounterID] = list
    return list
end

-- Merged fresh per render rather than cached: the journal side can improve underneath
-- (the cold-load re-scrape above), and the merge is a dozen table reads per boss.
-- Row identity is ALWAYS the BigWigs id -- it is what the engine receives, so the
-- checkbox/preset written under it is found at fire time directly. The journal entry
-- for the same mechanic is matched by spell id, then by name (the two id spaces are
-- not guaranteed to agree: Possession Barrage is 1292036 in BigWigs, 1284103 in the
-- journal) and contributes description, icon and role tags. A miss there still gets a
-- description from the plain client spell record, same as title and icon already did.
local function BigWigsAbilities(encounterID, journalAbilities, mapID)
    local opts = BigWigsOptionList(encounterID, mapID)
    if not opts then return nil end
    local byId, byName = {}, {}
    for i = 1, #(journalAbilities or {}) do
        local a = journalAbilities[i]
        byId[a.spellID] = a
        if a.title and not byName[a.title] then byName[a.title] = a end
    end
    local list = {}
    for i = 1, #opts do
        local id = opts[i].id
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        local name = info and info.name
        local j = byId[id] or (name and byName[name])
        -- title and icon both already fall back to the plain client spell record when the
        -- journal join misses; description had no such fallback and simply went blank,
        -- which is the common case here -- BigWigs toggles routinely cover mechanics the
        -- journal never narrates as their own section, on top of the id mismatches above.
        local desc = j and j.description
        if (not desc or desc == "") and C_Spell and C_Spell.GetSpellDescription then
            desc = C_Spell.GetSpellDescription(id)
        end
        list[#list + 1] = {
            title       = (j and j.title) or name or ("Spell " .. id),
            spellID     = id,
            icon        = (j and j.icon) or (info and info.iconID),
            extras      = j and j.extras,
            description = (desc and desc ~= "") and desc or nil,
            stage       = opts[i].stage,
        }
    end
    return list
end

-------------------------------------------------------------------------------
--  The tree page
-------------------------------------------------------------------------------
-- Dungeons and raids as a collapsed tree: click an instance to open it, click a boss to set
-- a priority just for that boss. Everything renders through the shared widget factory, so
-- this page reads like every other one rather than a custom window pretending to be one.
--
-- State is page-local and deliberately not saved: which node you last had open is not a
-- setting, and persisting it would make the page open somewhere surprising.
-- Sets rather than one selection: this is a tree, and comparing two bosses side by side is
-- the normal thing to want. Page-local and deliberately unsaved -- which node you last had
-- open is not a setting.
-- Instance expansion state used to live here; instances render inline via
-- BuildBossListPage/RenderInstanceDetail now, not a modal.

-- Rebuilt on every render. The drop target is worked out by comparing the cursor against
-- these rows' real screen bounds, which is why they have to be captured rather than assumed.
local dragRows, dragging = {}, nil

local function DropIndexFromCursor()
    local _, cy = GetCursorPosition()
    for i = 1, #dragRows do
        local r = dragRows[i]
        local f = r.frame
        if f and f:IsShown() then
            local scale = f:GetEffectiveScale()
            local top, bottom = f:GetTop(), f:GetBottom()
            if top and bottom and cy <= top * scale and cy >= bottom * scale then
                return r.index
            end
        end
    end
    return nil
end

-- A small x on the row, left of the label. Takes the ability out of the choices entirely,
-- as opposed to the checkbox which only moves it between in-play and not-in-play.
local function AttachRemove(row, entry, specID, EUI, onGone)
    local btn = CreateFrame("Button", nil, row)
    btn:SetSize(14, 14)
    btn:SetPoint("LEFT", row, "LEFT", 22, 0)
    btn:SetFrameLevel(row:GetFrameLevel() + 6)

    local a = ns.Solid(btn, "OVERLAY", ns.THEME.muted, 0.85)
    a:SetSize(10, 2); a:SetPoint("CENTER"); a:SetRotation(math.rad(45))
    local b = ns.Solid(btn, "OVERLAY", ns.THEME.muted, 0.85)
    b:SetSize(10, 2); b:SetPoint("CENTER"); b:SetRotation(math.rad(-45))

    btn:SetScript("OnEnter", function()
        a:SetColorTexture(1, 0.35, 0.35, 1); b:SetColorTexture(1, 0.35, 0.35, 1)
        local EUIg = ns.UI
        if EUIg and EUIg.ShowWidgetTooltip then
            EUIg.ShowWidgetTooltip(btn, "Remove",
                entry.userAdded and "Deletes this spell you added."
                or "Takes this out of your choices. Restore them with the button at the bottom.")
        end
    end)
    btn:SetScript("OnLeave", function()
        local c = ns.THEME.muted
        a:SetColorTexture(c.r, c.g, c.b, 0.85); b:SetColorTexture(c.r, c.g, c.b, 0.85)
        local EUIg = ns.UI
        if EUIg and EUIg.HideWidgetTooltip then EUIg.HideWidgetTooltip() end
    end)
    btn:SetScript("OnClick", function()
        if onGone then onGone() end
        EUI:RefreshPage(true)
    end)
    return btn
end

local function AttachGrabber(row, spellID, index, specID, encounterID, EUI)
    local grab = CreateFrame("Button", nil, row)
    grab:SetSize(14, 22)
    grab:SetPoint("LEFT", row, "LEFT", 4, 0)
    grab:SetFrameLevel(row:GetFrameLevel() + 6)

    -- Six dots: the conventional "pick me up" affordance, drawn rather than textured so it
    -- follows the theme.
    for c = 0, 1 do
        for r2 = 0, 2 do
            local d = ns.Solid(grab, "OVERLAY", ns.THEME.muted, 0.85)
            d:SetSize(3, 3)
            d:SetPoint("TOPLEFT", grab, "TOPLEFT", 3 + c * 5, -(4 + r2 * 6))
        end
    end

    grab:RegisterForDrag("LeftButton")
    grab:SetScript("OnDragStart", function()
        dragging = { spellID = spellID, from = index }
        row:SetAlpha(0.5)
    end)
    grab:SetScript("OnDragStop", function()
        row:SetAlpha(1)
        local d = dragging
        dragging = nil
        if not d then return end
        local dest = DropIndexFromCursor()
        if dest and dest ~= d.from then
            ns.MoveOnList(specID, encounterID, d.spellID, dest)
            EUI:RefreshPage(true)
        end
    end)
    ns.Tooltip(grab, "Drag to reorder", "Drag this onto another enabled ability to change the "
        .. "order it is called out in.")
    return grab
end

-- The house cog on any row region: 26px, shared art, dim until hovered, anchored left of
-- the region's control -- the same geometry as every cog in the suite.
local function AttachRowCog(rgn, onClick, tipTitle, tipBody)
    if not rgn then return end
    local cog = CreateFrame("Button", nil, rgn)
    cog:SetSize(26, 26)
    cog:SetPoint("RIGHT", rgn._lastInline or rgn._control or rgn, "LEFT", -8, 0)
    rgn._lastInline = cog
    cog:SetFrameLevel(rgn:GetFrameLevel() + 5)
    cog:SetAlpha(0.4)
    local tex = cog:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    local EUIg = ns.UI
    if EUIg and EUIg.COGS_ICON then tex:SetTexture(EUIg.COGS_ICON) end
    cog:SetScript("OnEnter", function(self)
        self:SetAlpha(0.7)
        if EUIg and EUIg.ShowWidgetTooltip and tipTitle then
            EUIg.ShowWidgetTooltip(self, tipBody and (tipTitle .. ": " .. tipBody) or tipTitle)
        end
    end)
    cog:SetScript("OnLeave", function(self)
        self:SetAlpha(0.4)
        if EUIg and EUIg.HideWidgetTooltip then EUIg.HideWidgetTooltip() end
    end)
    cog:SetScript("OnClick", function() if onClick then onClick() end end)
    return cog
end

-------------------------------------------------------------------------------
--  Preset list editor: the spec-default page, one preset picker on the left
--  and its condensed ability list on the right.
-------------------------------------------------------------------------------

-- Frames are never garbage collected, so a dialog built from plain frames is built once and
-- re-pointed on each open, with the per-open values held in a state table the widgets read
-- rather than captured directly. Dialogs built from the widget factory's rows cannot do
-- this -- see ShowAbilitySettingsPopup below for why.
--
-- Add and Rename are the same dialog: a name, a confirm and a cancel.
local namePrompt

local function ShowNamePrompt(title, confirmLabel, initial, onCommit)
    if not namePrompt then
        local dimmer, panel = ns.MakeModal(340, 150, "namePrompt")
        local np = { dimmer = dimmer }

        np.head = ns.Font(panel, 14, "OUTLINE")
        np.head:SetPoint("TOP", panel, "TOP", 0, -16)

        local box = CreateFrame("EditBox", nil, panel)
        box:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -50)
        box:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
        box:SetHeight(26)
        box:SetAutoFocus(true)
        box:SetMaxLetters(40)
        box:SetFontObject("GameFontHighlight")
        box:SetTextInsets(6, 6, 0, 0)
        ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1):SetAllPoints()
        ns.Border(box)
        np.box = box

        local function Commit()
            local fn = np.onCommit
            dimmer:Hide()
            if fn then fn(box:GetText()) end
        end
        box:SetScript("OnEnterPressed", Commit)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); dimmer:Hide() end)

        np.confirm = ns.Button(panel, "Save", 90, 26, Commit)
        np.confirm:SetPoint("BOTTOM", panel, "BOTTOM", -50, 16)
        ns.Button(panel, "Cancel", 90, 26, function() dimmer:Hide() end)
            :SetPoint("BOTTOM", panel, "BOTTOM", 50, 16)

        namePrompt = np
    end

    local np = namePrompt
    np.onCommit = onCommit
    np.head:SetText(title)
    ns.SetButtonText(np.confirm, confirmLabel)
    np.box:SetText(initial or "")
    np.dimmer:Show()
    np.box:SetFocus()
    np.box:HighlightText()
end

local function ShowAddPresetPopup(specID, EUI)
    ShowNamePrompt("New Preset", "Create", ns.NextPresetName(specID), function(text)
        ns.AddPreset(specID, text)
        EUI:RefreshPage(true)
    end)
end

local function ShowRenamePresetPopup(specID, presetKey, currentName, EUI)
    ShowNamePrompt("Rename Preset", "Save", currentName or "", function(text)
        ns.RenamePreset(specID, presetKey, text)
        EUI:RefreshPage(true)
    end)
end

-- Audio settings for one ability. The cog is designed to grow -- text options and whatever
-- else makes sense later -- so its content lives in its own small modal rather than crowding
-- the row.
local function ShowAbilitySettingsPopup(specID, spellID, name, EUI)
    local W = EUI.Widgets
    local dimmer, panel = ns.MakeModal(360, 172, "abilitySettings")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText(name)

    local editBtn, placeClose
    local y = -46
    local _, h = W:DualRow(panel, y,
        { type = "toggle", text = "Audio",
          tooltip = "Speaks this one when it is the defensive to press. Switch it off to "
          .. "keep it in your priority order but stay silent for it -- the icon and text "
          .. "still show.",
          getValue = function() return not ns.IsAudioOff(spellID) end,
          setValue = function(v)
              ns.SetAudioOff(spellID, not v)
              if editBtn then editBtn:SetShown(v) end
              if placeClose then placeClose() end
          end }
    ); y = y - h

    _, h = W:DualRow(panel, y,
        { type = "toggle", text = "Call Together",
          tooltip = "Tick this on every cooldown that should be called as a set. When one "
          .. "of them comes up, the rest that are ready are named with it -- \"Vampiric "
          .. "Blood and Icebound Fortitude\". Order does not matter, and one on cooldown "
          .. "is simply left out rather than holding the callout back.",
          getValue = function() return ns.CalledTogether(specID, spellID) end,
          setValue = function(v)
              ns.SetCalledTogether(specID, spellID, v)
              if EUI.RefreshPage then EUI:RefreshPage(true) end
          end }
    ); y = y - h

    editBtn = ns.Button(panel, "Edit Callout", 120, 26, function()
        ns.ShowCalloutEditor(("Audio callout for %s"):format(name),
            ns.CalloutFor(spellID, name), function(text)
                ns.SetCallout(spellID, text)
                if EUI.RefreshPage then EUI:RefreshPage(true) end
            end, spellID)
    end)
    editBtn:SetPoint("BOTTOM", panel, "BOTTOM", -55, 16)
    editBtn:SetShown(not ns.IsAudioOff(spellID))

    local closeBtn = ns.Button(panel, "Close", 90, 26, function() dimmer:Hide() end)
    placeClose = function()
        closeBtn:ClearAllPoints()
        closeBtn:SetPoint("BOTTOM", panel, "BOTTOM", editBtn:IsShown() and 65 or 0, 16)
    end
    placeClose()

    dimmer:Show()
end

-- A set renders as ONE row named for the whole call, so its members no longer have a cog
-- each. This is where they get one back: a row per member that opens that member's own
-- settings, which is where audio, its spoken name and leaving the set already live. Written
-- as a chooser rather than a second copy of those controls so there is one place each of
-- them can be edited.
local function ShowSetSettingsPopup(specID, members, EUI)
    local dimmer, panel = ns.MakeModal(400, 160, "setSettings")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText("Called Together")

    local y = -44
    for i = 1, #members do
        local sid = members[i]
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
        local nm = (info and info.name) or ("Spell " .. sid)
        local btn = ns.Button(panel, ns.CalloutFor(sid, nm), 340, 26, function()
            dimmer:Hide()
            ShowAbilitySettingsPopup(specID, sid, nm, EUI)
        end)
        btn:SetPoint("TOP", panel, "TOP", 0, y)
        ns.Tooltip(btn, nm, "Its audio, what it is called out loud, and taking it back "
            .. "out of the set.")
        y = y - 32
    end

    -- 26 for the button row, 16 for the bottom inset, and a gap so they do not touch.
    panel:SetHeight(math.abs(y) + 58)

    ns.Button(panel, "Close", 90, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOM", panel, "BOTTOM", 0, 16)

    dimmer:Show()
end

-- Same shape as the ability popup above, but the fallback step stores its audio flag under
-- spellID 0 and its text directly on db.voiceNone rather than through the callout table, so
-- it cannot share ShowAbilitySettingsPopup's storage calls.
local function ShowFallbackSettingsPopup(EUI)
    local W = EUI.Widgets
    local db = ns.DB()
    local dimmer, panel = ns.MakeModal(360, 178, "fallbackSettings")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText("Call for an External")

    local editBtn, placeClose
    local y = -46
    local _, h = W:DualRow(panel, y,
        { type = "toggle", text = "Audio",
          tooltip = "Speaks the fallback line when nothing on your list is up. This step is "
          .. "always last and cannot be moved, but it can be silenced.",
          disabled = function() return db.fallbackOn == false end,
          disabledTooltip = "Switch the last step back on to use this.",
          getValue = function() return db.fallbackOn ~= false and not ns.IsAudioOff(0) end,
          setValue = function(v)
              if db.fallbackOn == false then return end
              ns.SetAudioOff(0, not v)
              if editBtn then editBtn:SetShown(v) end
              if placeClose then placeClose() end
          end }
    ); y = y - h

    _, h = W:DualRow(panel, y,
        { type = "toggle", text = "Announce in Chat",
          tooltip = "Sends |cff0091edEXTERNAL!|r to party, raid or instance chat when nothing on "
          .. "your list is up, so whoever is watching for it can react. Group chat only, and at "
          .. "most once every three seconds however many telegraphs land together.",
          disabled = function() return db.fallbackOn == false end,
          disabledTooltip = "Switch the last step back on to use this.",
          getValue = function() return db.externalChat == true end,
          setValue = function(v)
              if db.fallbackOn == false then return end
              db.externalChat = v and true or false
          end }
    ); y = y - h

    editBtn = ns.Button(panel, "Edit Callout", 120, 26, function()
        ns.ShowCalloutEditor("Said and shown when nothing on the list is up",
            db.voiceNone, function(v)
                db.voiceNone = v
                ns.RefreshRuntime()
            end, 0)
    end)
    editBtn:SetPoint("BOTTOM", panel, "BOTTOM", -55, 16)
    editBtn:SetShown(db.fallbackOn ~= false and not ns.IsAudioOff(0))

    local closeBtn = ns.Button(panel, "Close", 90, 26, function() dimmer:Hide() end)
    placeClose = function()
        closeBtn:ClearAllPoints()
        closeBtn:SetPoint("BOTTOM", panel, "BOTTOM", editBtn:IsShown() and 65 or 0, 16)
    end
    placeClose()

    dimmer:Show()
end

-- A left-column entry: click to switch presets, pencil to rename, x to delete. Hand-drawn
-- rather than a DualRow toggle since it needs the active highlight and the rename/delete
-- affordances a checkbox row does not have.
local function BuildPresetRow(leftPane, ly, rowW, rowH, specID, p, isActive, canDelete, EUI)
    local prow = CreateFrame("Button", nil, leftPane)
    prow:SetSize(rowW, rowH)
    prow:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 0, ly)

    if isActive then
        local bg = ns.Solid(prow, "BACKGROUND", ns.THEME.grey, 0.55)
        bg:SetAllPoints()
    end

    local lbl = ns.Font(prow, 13, nil, isActive and ns.THEME.accent or ns.THEME.muted)
    lbl:SetPoint("LEFT", prow, "LEFT", 8, 0)
    lbl:SetPoint("RIGHT", prow, "RIGHT", canDelete and -56 or -34, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    lbl:SetText(p.name)

    prow:SetScript("OnClick", function()
        ns.SelectPreset(specID, p.key)
        EUI:RefreshPage(true)
    end)

    local edit = ns.Font(prow, 11, nil, ns.THEME.muted)
    edit:SetText("Edit")
    local editHit = CreateFrame("Button", nil, prow)
    editHit:SetSize(28, rowH)
    if canDelete then
        editHit:SetPoint("RIGHT", prow, "RIGHT", -26, 0)
    else
        editHit:SetPoint("RIGHT", prow, "RIGHT", -6, 0)
    end
    edit:SetPoint("CENTER", editHit, "CENTER", 0, 0)
    editHit:SetScript("OnEnter", function(self)
        local c = ns.THEME.accent
        edit:SetTextColor(c.r, c.g, c.b, 1)
        local EUIg = ns.UI
        if EUIg and EUIg.ShowWidgetTooltip then
            EUIg.ShowWidgetTooltip(self, "Rename this preset.")
        end
    end)
    editHit:SetScript("OnLeave", function()
        local c = ns.THEME.muted
        edit:SetTextColor(c.r, c.g, c.b, 1)
        local EUIg = ns.UI
        if EUIg and EUIg.HideWidgetTooltip then EUIg.HideWidgetTooltip() end
    end)
    editHit:SetScript("OnClick", function() ShowRenamePresetPopup(specID, p.key, p.name, EUI) end)

    if canDelete then
        local del = CreateFrame("Button", nil, prow)
        del:SetSize(14, 14)
        del:SetPoint("RIGHT", prow, "RIGHT", -6, 0)
        local a = ns.Solid(del, "OVERLAY", ns.THEME.muted, 0.85)
        a:SetSize(10, 2); a:SetPoint("CENTER"); a:SetRotation(math.rad(45))
        local b = ns.Solid(del, "OVERLAY", ns.THEME.muted, 0.85)
        b:SetSize(10, 2); b:SetPoint("CENTER"); b:SetRotation(math.rad(-45))
        del:SetScript("OnEnter", function(self)
            a:SetColorTexture(1, 0.35, 0.35, 1); b:SetColorTexture(1, 0.35, 0.35, 1)
            local EUIg = ns.UI
            if EUIg and EUIg.ShowWidgetTooltip then
                EUIg.ShowWidgetTooltip(self,
                    "|cff0091edDelete Preset|r\nRemoves this preset and its list. Cannot be undone.")
            end
        end)
        del:SetScript("OnLeave", function()
            local c = ns.THEME.muted
            a:SetColorTexture(c.r, c.g, c.b, 0.85); b:SetColorTexture(c.r, c.g, c.b, 0.85)
            local EUIg = ns.UI
            if EUIg and EUIg.HideWidgetTooltip then EUIg.HideWidgetTooltip() end
        end)
        del:SetScript("OnClick", function()
            ns.DeletePreset(specID, p.key)
            EUI:RefreshPage(true)
        end)
    end

    return prow
end

-- The spec-default page: a preset picker on the left, and the active preset's list -- every
-- row condensed to one column, with a settings cog where the old layout had a second column
-- -- on the right. Per-boss overrides go through RenderInstanceDetail/RenderAbilityRow, keyed
-- by spell id rather than a priority list.
function ns.RenderPresetListEditor(parent, y, W, EUI, specID)
    local _, h, row
    local topY = y

    if #ns.ListPresets(specID) == 0 then
        ns.AddPreset(specID, "Default")
    end
    local presets = ns.ListPresets(specID)
    local activeKey = ns.ActivePresetKey(specID)

    local PRESET_ROW_H = 34
    local LEFT_W = 190
    local GAP = 16
    local totalW = parent:GetWidth() - EUI.CONTENT_PAD * 2
    local rightW = totalW - LEFT_W - GAP

    local leftPane = CreateFrame("Frame", nil, parent)
    leftPane:SetSize(LEFT_W, 10)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD, topY)

    local rightPane = CreateFrame("Frame", nil, parent)
    rightPane:SetSize(rightW, 10)
    rightPane:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD + LEFT_W + GAP, topY)

    -- Left column: one row per preset, then the add-preset row.
    local ly = 0
    for i = 1, #presets do
        local p = presets[i]
        BuildPresetRow(leftPane, ly, LEFT_W, PRESET_ROW_H, specID, p,
            p.key == activeKey, #presets > 1, EUI)
        ly = ly - PRESET_ROW_H
    end

    local addRow = CreateFrame("Button", nil, leftPane)
    addRow:SetSize(LEFT_W, PRESET_ROW_H)
    addRow:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 0, ly)
    local addLbl = ns.Font(addRow, 13, nil, ns.THEME.muted)
    addLbl:SetPoint("LEFT", addRow, "LEFT", 8, 0)
    addLbl:SetText("+ Add Preset")
    addRow:SetScript("OnEnter", function()
        local c = ns.THEME.fg
        addLbl:SetTextColor(c.r, c.g, c.b, 1)
    end)
    addRow:SetScript("OnLeave", function()
        local c = ns.THEME.muted
        addLbl:SetTextColor(c.r, c.g, c.b, 1)
    end)
    addRow:SetScript("OnClick", function() ShowAddPresetPopup(specID, EUI) end)
    ly = ly - PRESET_ROW_H

    -- Right column: the active preset's list, condensed to one control per row.
    local ry = 0
    local list = ns.EffectiveListFor(specID, nil) or {}
    local auto = ns.AllDefensives(specID, nil)

    wipe(dragRows)

    local hidden = ns.HiddenSpells(specID)
    local function IsHidden(id) return hidden ~= nil and hidden[tostring(id)] == true end

    local pool, seen = {}, {}
    for i = 1, #auto do
        if not IsHidden(auto[i].id) then
            pool[#pool + 1] = auto[i]
            seen[auto[i].id] = true
        end
    end
    local custom = ns.CustomSpells(specID)
    if custom then
        for key in pairs(custom) do
            local sid = tonumber(key)
            if sid and not seen[sid] and not IsHidden(sid) then
                seen[sid] = true
                local si = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                pool[#pool + 1] = {
                    id = sid, name = (si and si.name) or ("Spell " .. sid),
                    icon = si and si.iconID, cd = 0, userAdded = true,
                }
            end
        end
    end

    -- The set is drawn as ONE row, at the position of its first member, named for the whole
    -- call -- "Guardian and Ardent". Later members are skipped rather than repeated: the
    -- point of ticking them together is that they are one thing to press, so they should read
    -- as one line. Their own settings move to the set popup, which is what the merged row's
    -- cog opens.
    -- Talented members only. RebuildSlots drops anything untalented before the engine ever
    -- sees it, so an untalented half can never actually be called with the other one, and
    -- folding it into the merged name would promise a callout that cannot happen. It falls
    -- back to its own row, carrying the usual "(not talented)".
    local setMembers
    for i = 1, #list do
        if ns.CalledTogether(specID, list[i]) and ns.IsSpellAvailable(list[i]) then
            setMembers = setMembers or {}
            setMembers[#setMembers + 1] = list[i]
        end
    end
    -- A set of one is not a set; it renders as an ordinary row until a second is ticked.
    if setMembers and #setMembers < 2 then setMembers = nil end

    local setDrawn = false
    for i = 1, #list do
        local spellID = list[i]
        local idx = i
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
        local name = (info and info.name) or ("Spell " .. spellID)
        local inSet = setMembers and ns.CalledTogether(specID, spellID)
            and ns.IsSpellAvailable(spellID)
        local skip = inSet and setDrawn

        if not skip then
            local label
            if inSet then
                setDrawn = true
                local said
                for m = 1, #setMembers do
                    local mi = C_Spell and C_Spell.GetSpellInfo
                        and C_Spell.GetSpellInfo(setMembers[m])
                    local one = ns.CalloutFor(setMembers[m], mi and mi.name)
                    said = said and (said .. " and " .. one) or one
                end
                label = ("      %d.  %s"):format(idx, said)
            else
                label = ("      %d.  %s"):format(idx, name)
                if not ns.IsSpellAvailable(spellID) then
                    label = label .. "  (not talented)"
                end
            end

            row, h = W:DualRow(rightPane, ry,
                { type = "toggle", text = label,
                  tooltip = inSet
                      and "Called as one. Open the cog to rename either half or take one out."
                      or ("Spell ID %d. Untick to drop it to the bottom of the list."):format(spellID),
                  getValue = function() return true end,
                  -- The whole set leaves together: it is drawn as one entry, so dropping it
                  -- has to take every member with it or the other half reappears on its own
                  -- row a line later.
                  setValue = function()
                      if inSet then
                          for m = 1, #setMembers do
                              ns.SetSpellOnList(specID, nil, setMembers[m], false)
                          end
                      else
                          ns.SetSpellOnList(specID, nil, spellID, false)
                      end
                      EUI:RefreshPage(true)
                  end }
            ); ry = ry - h

            if row then
                dragRows[#dragRows + 1] = { frame = row, spellID = spellID, index = idx }
                AttachGrabber(row, spellID, idx, specID, nil, EUI)
                AttachRemove(row, { id = spellID, userAdded = false }, specID, EUI, function()
                    for m = 1, (inSet and #setMembers or 1) do
                        local rid = inSet and setMembers[m] or spellID
                        ns.SetSpellOnList(specID, nil, rid, false)
                        ns.HideSpell(specID, rid)
                    end
                end)
                -- The row is single-column (no rightCfg), so the toggle lives in the LEFT
                -- region -- chain the cog off that region's control, not the empty right one,
                -- or it would anchor off in the dead space past the toggle.
                AttachRowCog(row._leftRegion, function()
                    if inSet then
                        ShowSetSettingsPopup(specID, setMembers, EUI)
                    else
                        ShowAbilitySettingsPopup(specID, spellID, name, EUI)
                    end
                end, "Settings", inSet and "What each half is called, and leaving the set."
                    or "Audio, and anything added later.")
            end
        end
    end

    local spare = {}
    for i = 1, #pool do
        if not ns.ListIndexOf(list, pool[i].id) then spare[#spare + 1] = pool[i] end
    end
    table.sort(spare, function(a, b) return a.name < b.name end)

    for i = 1, #spare do
        local c = spare[i]
        row, h = W:DualRow(rightPane, ry,
            { type = "toggle",
              text = "      |cff9a9ea6" .. c.name .. (c.userAdded and " (added by you)" or "") .. "|r",
              tooltip = ("Spell ID %d. Tick to put it into your priority order."):format(c.id),
              getValue = function() return false end,
              setValue = function()
                  ns.SetSpellOnList(specID, nil, c.id, true)
                  EUI:RefreshPage(true)
              end }
        ); ry = ry - h

        if row then
            AttachRemove(row, c, specID, EUI, function()
                if c.userAdded then ns.RemoveCustomSpell(specID, c.id)
                else ns.HideSpell(specID, c.id) end
                ns.SetSpellOnList(specID, nil, c.id, false)
            end)
        end
    end

    if #list == 0 and #spare == 0 then
        _, h = W:DualRow(rightPane, ry,
            { type = "label", text = "      No major defensives found for this specialization." }
        ); ry = ry - h
    end

    if hidden and next(hidden) ~= nil then
        _, h = W:DualRow(rightPane, ry,
            { type = "toggle", text = "      Restore Removed Abilities",
              tooltip = "Brings back everything you removed from the choices for this spec.",
              getValue = function() return false end,
              setValue = function()
                  ns.UnhideAll(specID)
                  EUI:RefreshPage(true)
              end }
        ); ry = ry - h
    end

    -- The fallback step, condensed like everything above it: its own toggle plus a cog for
    -- audio and text, matching the shape of an ability row even though it is not one.
    local db = ns.DB()
    row, h = W:DualRow(rightPane, ry,
        { type = "toggle",
          text = ("      |cff0091edLast:  %s|r"):format(db.voiceNone or "Call for an External"),
          tooltip = "The final step, used when nothing on your list is up. Switch it off to say "
          .. "and show nothing at all in that case.\n\nThis is the default for the whole spec. "
          .. "An individual ability can override it from its own cog on a boss page, for hits "
          .. "the raid was never going to answer.",
          getValue = function() return db.fallbackOn ~= false end,
          setValue = function(v)
              db.fallbackOn = v
              ns.RefreshRuntime()
              EUI:RefreshPage(true)
          end }
    ); ry = ry - h
    if row then
        AttachRowCog(row._leftRegion, function() ShowFallbackSettingsPopup(EUI) end,
            "Settings", "Audio, and anything added later.")
    end

    -- The spell ID entry, last: the widget factory has no text input, so the box and its
    -- button are built here and laid over the row's right half.
    row, h = W:DualRow(rightPane, ry,
        { type = "label", text = "      Add an Ability by Spell ID" },
        { type = "label", text = "" }   -- overlaid below with the entry box and Add button
    ); ry = ry - h

    if row and row._rightRegion then
        local rgn = row._rightRegion

        local add = ns.Button(rgn, "Add", 54, 22, nil)
        add:SetPoint("RIGHT", rgn, "RIGHT", -14, 0)

        local box = CreateFrame("EditBox", nil, rgn)
        box:SetPoint("LEFT", rgn, "LEFT", 6, 0)
        box:SetPoint("RIGHT", add, "LEFT", -8, 0)
        box:SetHeight(24)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(9)
        box:SetFontObject("GameFontHighlight")
        box:SetTextInsets(6, 6, 0, 0)
        local well = ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1)
        well:SetAllPoints()
        ns.Border(box)

        local placeholder = ns.Font(box, 12, nil, ns.THEME.muted)
        placeholder:SetPoint("LEFT", box, "LEFT", 8, 0)
        placeholder:SetText("Enter SpellID")

        local feedback = ns.Font(rgn, 10, nil, ns.THEME.muted)
        feedback:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -1)
        feedback:SetPoint("RIGHT", add, "LEFT", -8, 0)
        feedback:SetJustifyH("LEFT")

        local function Commit()
            local sid = ns.ResolveSpell(box:GetText())
            if not sid then return end
            if ns.AddCustomSpell(specID, sid) then
                ns.SetSpellOnList(specID, nil, sid, true)
                box:SetText("")
                box:ClearFocus()
                EUI:RefreshPage(true)
            end
        end

        local function Validate()
            local text = box:GetText()
            placeholder:SetShown(text == nil or text == "")
            local sid, info = ns.ResolveSpell(text)
            if sid then
                add:Enable()
                add:SetAlpha(1)
                feedback:SetText("|cff6DD09A" .. (info.name or "") .. "|r")
            else
                add:Disable()
                add:SetAlpha(0.35)
                feedback:SetText((text ~= "" and text ~= nil) and "|cffff6060Not a spell ID|r" or "")
            end
        end

        add:SetScript("OnClick", Commit)
        box:SetScript("OnTextChanged", Validate)
        box:SetScript("OnEnterPressed", Commit)
        box:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
        Validate()
    end

    return topY + math.min(ly, ry)
end

-- The boss's own preset choice: which of the spec's presets it calls its defensives
-- from. The Enable This Boss toggle lives on the boss-picker row in
-- RenderInstanceDetail, which gates this whole section.
-- Used by RenderInstanceDetail, the journal-sourced ability list. Returns y.
local function RenderBossHeader(parent, y, W, EUI, encounterID, specID)
    local _, h

    -- Which of the spec's presets this boss calls its defensives from. Shows the spec's
    -- active preset until the tank actually picks one for this boss -- nothing is written
    -- just from opening the modal and looking at it.
    local presets = ns.ListPresets(specID)
    if #presets > 0 then
        local presetValues, presetOrder = {}, {}
        for i = 1, #presets do
            presetValues[presets[i].key] = presets[i].name
            presetOrder[i] = presets[i].key
        end
        _, h = W:DualRow(parent, y,
            { type = "dropdown", text = "Cooldown Preset",
              values = presetValues, order = presetOrder,
              tooltip = "Which of your spec's presets this boss calls its defensives from.",
              getValue = function()
                  return ns.BossPresetKey(specID, encounterID) or ns.ActivePresetKey(specID)
              end,
              setValue = function(v)
                  ns.SetBossPreset(specID, encounterID, v)
                  ns.RefreshRuntime()
                  EUI:RefreshPage(true)
              end }
        ); y = y - h
    end

    return y
end

-------------------------------------------------------------------------------
--  Custom reminder editor: name, message, trigger, linger
-------------------------------------------------------------------------------
local TRIGGER_CHOICES = { bwmsg = "BigWigs Message Timer",
    caststart = "Boss Cast Starts", castend = "Boss Cast Finishes" }
local TRIGGER_ORDER = { "bwmsg", "caststart", "castend" }

local SHOW_IN_TIP = "Seconds after the trigger. Blank or zero fires immediately. "
    .. "For messages, the delay starts only when BigWigs/DBM sends the message. "
    .. "Enable Messages for this ability in BigWigs; disabled messages cannot trigger reminders."
local COUNTER_TIP = "Blank fires every time. Match a count with >N, >=N, <N, <=N, !N (not "
    .. "N) or a bare number (exactly N). Separate conditions with a comma to match any of "
    .. "them, or add a leading + on the second one to require both -- example: >3,+<7 "
    .. "fires between 4 and 6."

-- Rebuilt fresh on every open: an occasional settings dialog is not worth the bookkeeping
-- a cached singleton would need for a dropdown and text fields that all close over a
-- different encounter/uid each time.
-- callerEUI, when given, is a caller's own EUI proxy (e.g. the ability picker's) -- its
-- RefreshPage also re-renders that caller, not just the real options page, which is what
-- actually makes a saved/edited reminder show up in its list without a reopen.
-- Icon + display name for a catalogued BigWigs/DBM key. Positive keys are almost always
-- real spell ids; negative ones are BigWigs' own convention for "this is really a
-- Dungeon Journal section", the same -sectionID scheme its own options panel uses. Both
-- routes read Blizzard's plain data (C_Spell / C_EncounterJournal) -- nothing here reads
-- anything of BigWigs' or DBM's own beyond the bare key and label they already broadcast.
local function ResolveMechanicIcon(key)
    if key > 0 then
        return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(key)
    elseif C_EncounterJournal and C_EncounterJournal.GetSectionInfo then
        local ok, info = pcall(C_EncounterJournal.GetSectionInfo, -key)
        return ok and info and info.abilityIcon or nil
    end
end

local function ResolveMechanicName(key, entry)
    if key > 0 then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(key)
        if info and info.name then return info.name end
    end
    -- The boss mod's own message/bar text as a fallback: it is not always a real spell
    -- (a negative journal key, or an arbitrary internal id some modules use), and that
    -- text is still the clearest label available for it.
    if type(entry.text) == "string" and entry.text ~= "" then return entry.text end
    return "Key " .. tostring(key)
end

-- List only the selected boss's BigWigs options, without a row cap.
function ns.ReminderAbilityChoices(encounterID)
    local byKey = {}
    local function Add(key, text, mod)
        if type(key) ~= "number" or key == 0 then return end
        if not byKey[key] then byKey[key] = { key = key, entry = { text = text, mod = mod } } end
    end
    local data = ns.ScrapeBosses and ns.ScrapeBosses(false)
    for _, inst in ipairs(data and data.instances or {}) do
        for _, boss in ipairs(inst.bosses or {}) do
            if boss.encounterID == encounterID then
                for _, ability in ipairs(BigWigsAbilities(encounterID, nil, inst.mapID) or {}) do
                    Add(ability.spellID, ability.title, "BW")
                end
            end
        end
    end
    local list = {}
    for _, item in pairs(byKey) do list[#list + 1] = item end
    table.sort(list, function(a, b)
        local an, bn = ResolveMechanicName(a.key, a.entry), ResolveMechanicName(b.key, b.entry)
        if an == bn then return a.key < b.key end
        return an < bn
    end)
    return list
end

-- New reminders default to a message; boss cast start/finish remain selectable.
function ns.ShowCustomReminderEditor(encounterID, uid, callerEUI, initialTrigger)
    local EUI = callerEUI or ns.UI
    local W = EUI.Widgets

    local dimmer, panel = ns.MakeModal(480, 740, "customReminderEditor")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText(uid and "Edit Reminder" or "New Reminder")

    local set = ns.CustomRemindersTable(false, encounterID)
    local existing = (set and uid) and set[uid] or nil
    local trig = (existing and existing.trigger)
        or { type = initialTrigger or "bwmsg" }

    local PAD = 20

    local function HoverTip(hit, tooltip)
        hit:SetScript("OnEnter", function(self)
            local EUIg = ns.UI
            if EUIg and EUIg.ShowWidgetTooltip then EUIg.ShowWidgetTooltip(self, tooltip) end
        end)
        hit:SetScript("OnLeave", function()
            local EUIg = ns.UI
            if EUIg and EUIg.HideWidgetTooltip then EUIg.HideWidgetTooltip() end
        end)
    end

    local triggerBody = CreateFrame("Frame", nil, panel)
    triggerBody:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -42)
    triggerBody:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -42)
    triggerBody:SetHeight(650)
    local messageBody = CreateFrame("Frame", nil, triggerBody)
    messageBody:SetSize(480, 230)

    local my = 0

    local function AddLabelM(text, tooltip)
        local l = ns.Font(messageBody, 11, nil, ns.THEME.muted)
        l:SetPoint("TOPLEFT", messageBody, "TOPLEFT", PAD, my)
        l:SetText(text)
        if tooltip then
            local hit = CreateFrame("Frame", nil, messageBody)
            hit:SetPoint("TOPLEFT", l, "TOPLEFT", -4, 4)
            hit:SetPoint("BOTTOMRIGHT", l, "BOTTOMRIGHT", 4, -4)
            HoverTip(hit, tooltip)
        end
        my = my - 16
    end

    local function AddBoxM(maxLetters, numeric, rightInset)
        local box = CreateFrame("EditBox", nil, messageBody)
        box:SetPoint("TOPLEFT", messageBody, "TOPLEFT", PAD, my)
        box:SetPoint("RIGHT", messageBody, "RIGHT", -(rightInset or PAD), 0)
        box:SetHeight(26)
        box:SetAutoFocus(false)
        box:SetMaxLetters(maxLetters or 60)
        if numeric then box:SetNumeric(true) end
        box:SetFontObject("GameFontHighlight")
        box:SetTextInsets(6, 6, 0, 0)
        ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1):SetAllPoints()
        ns.Border(box)
        my = my - 32
        return box
    end

    AddLabelM("Name")
    local nameBox = AddBoxM(40)
    nameBox:SetText((existing and existing.name) or "")

    -- A preset rather than a typed line: the reminder announces whichever defensive in that
    -- preset is actually still up when it fires. Free text could only ever name a fixed
    -- spell, which is wrong the moment that spell is on cooldown -- the reason these are
    -- called smart reminders at all.
    local editorSpecID = ns.CurrentSpec()
    if #ns.ListPresets(editorSpecID) == 0 then
        ns.AddPreset(editorSpecID, "Default")
    end
    local presets = ns.ListPresets(editorSpecID)
    local presetValues, presetOrder = {}, {}
    for i = 1, #presets do
        presetValues[presets[i].key] = presets[i].name
        presetOrder[i] = presets[i].key
    end

    local presetVal = (existing and existing.preset) or ns.ActivePresetKey(editorSpecID)
        or presetOrder[1]

    local _, presetRowH = W:DualRow(messageBody, my,
        { type = "dropdown", text = "Preset Group",
          values = presetValues, order = presetOrder,
          tooltip = "Which of your spec's presets this reminder calls from. When it fires "
              .. "it names the highest defensive on that list still off cooldown.",
          getValue = function() return presetVal end,
          setValue = function(v) presetVal = v end },
        { type = "label", text = "" }
    ); my = my - presetRowH

    AddLabelM("Linger (seconds)")
    local durBox = AddBoxM(3, true)
    durBox:SetText(tostring((existing and existing.dur) or 3))

    local healerVal = existing and existing.healerReminder == true or false
    local enabledVal = (existing == nil) or existing.enabled ~= false
    W:DualRow(messageBody, my,
        { type = "toggle", text = "Enabled",
          getValue = function() return enabledVal end,
          setValue = function(v) enabledVal = v end },
        { type = "toggle", text = "Healer Reminder",
          tooltip = "Mark this reminder so players can opt out with Enable Healer Reminders in Setup.",
          getValue = function() return healerVal end,
          setValue = function(v) healerVal = v end }
    )

    -------------------------------------------------------------------------
    --  Trigger tab: type, mechanic picker, dynamic fields.
    -------------------------------------------------------------------------
    -- Legacy records retain their data until saved explicitly in this editor.
    local trigVal = (trig.type == "caststart" or trig.type == "castend")
        and trig.type or "bwmsg"

    local spellIDText = (trig.spellID and tostring(trig.spellID)) or ""
    local counterText = (type(trig.counter) == "string" and trig.counter)
        or (type(trig.counter) == "number" and tostring(trig.counter)) or ""
        local delayText = (trig.type ~= "combat" and type(trig.delay) == "string" and trig.delay) or ""

    -- The dynamic block below the Trigger dropdown -- which fields it holds depends on
    -- trigVal, so it is torn down and rebuilt on every change rather than show/hidden in
    -- place. The current widgets (nil for whichever fields the active type does not use)
    -- are read back into the *Text locals before a rebuild so switching types and back
    -- does not lose what was typed.
    local dynFrame, spellBox, counterBox, delayBox
    local DYN_Y   -- set below, once the Trigger dropdown row's height is known
    local RebuildDynFields
    local triggerRow -- the Trigger dropdown's own row handle, so a picker pick can refresh its label

    local function SaveDynFieldsToText()
        if spellBox then spellIDText = spellBox:GetText() or "" end
        if counterBox then counterText = counterBox:GetText() or "" end
        if delayBox then delayText = delayBox:GetText() or "" end
    end

    -- Public entry point for the picker rows below: picking a mechanic changes trigVal
    -- and spellIDText from OUTSIDE the Trigger dropdown's own setValue, so the dropdown's
    -- displayed label has to be told to re-read them rather than assume it already knows.
    local function RefreshTriggerLabel()
        local ctrl = triggerRow and triggerRow._leftRegion and triggerRow._leftRegion._control
        if ctrl and ctrl._refreshLabel then ctrl._refreshLabel() end
    end

    local triggerRowH
    triggerRow, triggerRowH = W:DualRow(triggerBody, 0,
        { type = "dropdown", text = "Trigger",
          values = TRIGGER_CHOICES,
          order = TRIGGER_ORDER,
          tooltip = "What starts this reminder.",
          getValue = function() return trigVal end,
          setValue = function(v)
              SaveDynFieldsToText()
              trigVal = v
              RebuildDynFields()
          end },
        { type = "label", text = "" }
    )
    DYN_Y = -triggerRowH

    -- The mechanic picker: every BigWigs/DBM key actually seen for this boss (recorded by
    -- RecordBossModKey the moment it fires live -- see the bridge above), sorted by how
    -- often it has come up. Picking one fills the Spell ID field below exactly the way
    -- typing it in would, so nothing downstream (BuildTrigger, Save) needed to change.
    -- Every row below anchors at DYN_Y (the bottom of the Trigger dropdown), not at 0 --
    -- 0 is triggerBody's own top, which is where the dropdown ITSELF starts. Anchored
    -- there, the picker's first row and its "nothing recorded" hint sat directly on top of
    -- the Trigger dropdown rather than below it, for BigWigs/DBM Message and Timer -- the
    -- two trigger types that show the picker at all.
    local pickerRows = {}
    local pickerScroll = CreateFrame("ScrollFrame", nil, triggerBody, "UIPanelScrollFrameTemplate")
    pickerScroll:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, DYN_Y)
    pickerScroll:SetPoint("TOPRIGHT", triggerBody, "TOPRIGHT", -PAD - 22, DYN_Y)
    pickerScroll:SetHeight(120)
    local pickerContent = CreateFrame("Frame", nil, pickerScroll)
    pickerContent:SetSize(418, 1)
    pickerScroll:SetScrollChild(pickerContent)
    local function MakePickerRow(i)
        local row = CreateFrame("Button", nil, pickerContent)
        row:SetHeight(24)
        row:SetPoint("TOPLEFT", pickerContent, "TOPLEFT", 0, 0)
        row:SetPoint("RIGHT", pickerContent, "RIGHT", 0, 0)

        row.hl = ns.Solid(row, "BACKGROUND", ns.THEME.accent, 0.14)
        row.hl:SetAllPoints()
        row.hl:Hide()
        row:SetScript("OnEnter", function(s) s.hl:Show() end)
        row:SetScript("OnLeave", function(s) s.hl:Hide() end)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 2, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.name = ns.Font(row, 11, nil, ns.THEME.fg)
        row.name:SetPoint("LEFT", 24, 0)
        row.name:SetPoint("RIGHT", -34, 0)
        row.name:SetJustifyH("LEFT")

        row.tag = ns.Font(row, 9, nil, ns.THEME.muted)
        row.tag:SetPoint("RIGHT", -2, 0)

        pickerRows[i] = row
        return row
    end
    local pickerHint = ns.Font(triggerBody, 10, nil, ns.THEME.muted)
    pickerHint:SetPoint("RIGHT", triggerBody, "RIGHT", -PAD, 0)
    pickerHint:SetJustifyH("LEFT")
    local PICKER_ROW_H = 24
    local PICKER_HEIGHT = 0

    local function RebuildPicker()
        for i = 1, #pickerRows do pickerRows[i]:Hide() end
        local list = ns.ReminderAbilityChoices(encounterID)
        pickerScroll:SetShown(#list > 0)
        pickerScroll:SetVerticalScroll(0)
        pickerContent:SetHeight(math.max(1, #list * PICKER_ROW_H))
        local height = math.min(120, #list * PICKER_ROW_H)
        pickerScroll:SetHeight(math.max(1, height))
        for i = 1, #list do
            local item = list[i]
            local row = pickerRows[i] or MakePickerRow(i)
            row:SetPoint("TOPLEFT", pickerContent, "TOPLEFT", 0, -(i - 1) * PICKER_ROW_H)
            row.icon:SetTexture(ResolveMechanicIcon(item.key))
            row.name:SetText(ResolveMechanicName(item.key, item.entry))
            row.tag:SetText(item.entry.mod or "Journal")
            row:SetScript("OnClick", function()
                SaveDynFieldsToText()
                spellIDText = tostring(item.key)
                RefreshTriggerLabel()
                RebuildDynFields()
            end)
            row:Show()
        end
        pickerHint:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, DYN_Y - height - 4)
        pickerHint:SetText(#list == 0 and "No BigWigs abilities available for this boss. Enter a spell ID below."
            or (trigVal == "bwmsg" and "Only abilities announced by BigWigs/DBM can trigger a message reminder." or "Select the spell the boss casts."))
        pickerHint:SetHeight(28)
        PICKER_HEIGHT = height + 36
    end

    RebuildDynFields = function()
        if dynFrame then dynFrame:Hide() end
        RebuildPicker()

        dynFrame = CreateFrame("Frame", nil, triggerBody)
        dynFrame:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", 0, DYN_Y - PICKER_HEIGHT)
        dynFrame:SetSize(480, 210)
        spellBox, counterBox, delayBox = nil, nil, nil

        local dy = 0
        local function DLabel(text, tooltip)
            local l = ns.Font(dynFrame, 11, nil, ns.THEME.muted)
            l:SetPoint("TOPLEFT", dynFrame, "TOPLEFT", PAD, dy)
            l:SetText(text)
            if tooltip then
                local hit = CreateFrame("Frame", nil, dynFrame)
                hit:SetPoint("TOPLEFT", l, "TOPLEFT", -4, 4)
                hit:SetPoint("BOTTOMRIGHT", l, "BOTTOMRIGHT", 4, -4)
                HoverTip(hit, tooltip)
            end
            dy = dy - 16
        end
        local function DBox(maxLetters, numeric, rightInset)
            local box = CreateFrame("EditBox", nil, dynFrame)
            box:SetPoint("TOPLEFT", dynFrame, "TOPLEFT", PAD, dy)
            box:SetPoint("RIGHT", dynFrame, "RIGHT", -(rightInset or PAD), 0)
            box:SetHeight(26)
            box:SetAutoFocus(false)
            box:SetMaxLetters(maxLetters or 60)
            if numeric then box:SetNumeric(true) end
            box:SetFontObject("GameFontHighlight")
            box:SetTextInsets(6, 6, 0, 0)
            ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1):SetAllPoints()
            ns.Border(box)
            dy = dy - 32
            return box
        end

        DLabel(trigVal == "bwmsg" and "Message Spell ID / Key" or "Spell ID")
        spellBox = DBox(12)
        spellBox:SetText(spellIDText)
        DLabel("Counter", COUNTER_TIP)
        counterBox = DBox(40)
        counterBox:SetText(counterText)
        DLabel(trigVal == "bwmsg" and "Show seconds after the message" or "Show in",
            SHOW_IN_TIP)
        delayBox = DBox(60)
        delayBox:SetText(delayText)
        messageBody:ClearAllPoints()
        messageBody:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", 0,
            DYN_Y - PICKER_HEIGHT + dy - 12)
    end
    RebuildDynFields()

    local function BuildTrigger()
        SaveDynFieldsToText()
        local sid = tonumber(spellIDText)
        if not sid or sid == 0 or sid ~= math.floor(sid) then return nil end
        if trigVal ~= "bwmsg" and sid < 0 then return nil end
        if delayText ~= "" then
            local delay = tonumber(delayText)
            if not delay or delay < 0 then return nil end
        end
        local newTrig = { type = trigVal, spellID = sid,
            counter = (counterText ~= "" and counterText) or nil,
            delay = (delayText ~= "" and delayText) or nil }
        return newTrig
    end

    local function Save()
        local newTrig = BuildTrigger()
        if not newTrig then
            ns.Print("|cffff6060Enter a valid spell/key and a delay of zero or more seconds.|r")
            return
        end
        local name = nameBox:GetText()
        if not name or name == "" then name = "Reminder" end
        local dur = tonumber(durBox:GetText()) or 3
        local writeSet = ns.CustomRemindersTable(true, encounterID)
        local key = uid or ("r" .. math.floor(GetTime() * 1000) .. math.random(1, 9999))
        writeSet[key] = {
            name = name, preset = presetVal, trigger = newTrig,
            dur = math.max(1, dur), enabled = enabledVal, healerReminder = healerVal or nil,
            defensive = true, specID = editorSpecID,
        }
        ns.RefreshRuntime()
        dimmer:Hide()
        if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
    end

    ns.Button(panel, "Save", 90, 26, Save):SetPoint("BOTTOM", panel, "BOTTOM", -10, 16)
    ns.Button(panel, "Cancel", 90, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOM", panel, "BOTTOM", 90, 16)

    dimmer:Show()
    -- Returned so a caller (ns.ShowBossReminderPicker) can hook OnHide and refresh its
    -- own list once this editor closes -- ignored by every other existing call site.
    return dimmer, panel
end

-- Profiles tab: profile management and sharing (Reminder Packs).
function ns.BuildProfileSettings(parent, y)
    local EUI = ns.UI
    local W   = EUI.Widgets
    local _, h

    _, h = W:SectionHeader(parent, "PROFILES", y); y = y - h

    -- Values/order rebuilt per page build; a create/copy/delete refreshes the page, so the
    -- dropdown never shows a stale list.
    local profNames = ns.ListProfiles()
    local profValues = {}
    for _, name in ipairs(profNames) do profValues[name] = name end
    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Active Profile",
          values = profValues, order = profNames,
          tooltip = "Which settings profile this character uses. Everything on these pages "
          .. "-- priority lists, per-boss orders, callouts, positions -- lives in the "
          .. "profile.",
          getValue = function() return ns.ActiveProfileName() end,
          setValue = function(v)
              ns.SwitchProfile(v)
              EUI:RefreshPage(true)
          end },
        { type = "toggle", text = "Match My Spec",
          tooltip = "Loads the profile bound to whatever spec you switch to, on login and on "
          .. "every spec change. A whole-file import sets those bindings up; after that, "
          .. "picking a profile yourself binds it to the spec you are playing.",
          getValue = function() return ns.AutoSpecProfile() end,
          setValue = function(v)
              ns.AutoSpecProfile(v)
              if v and ns.ApplySpecProfile and ns.CurrentSpec then
                  ns.ApplySpecProfile((ns.CurrentSpec()))
              end
              EUI:RefreshPage(true)
          end }
    ); y = y - h

    -- Declared here rather than where it is written below: the save buttons offer an
    -- overwrite through it, and their closures need it in scope when they are built.
    local ConfirmOn

    local profRow
    profRow, h = W:DualRow(parent, y,
        { type = "label", text = "" },
        { type = "label", text = "" }
    ); y = y - h
    if profRow then
        local function AfterChange()
            EUI:RefreshPage(true)
        end
        local newBtn = ns.Button(profRow._leftRegion, "New Profile", 110, 22, function()
            ShowNamePrompt("New Profile", "Create", "", function(text)
                local name = text:match("^%s*(.-)%s*$")
                -- A taken name used to fail with "that name is taken" and nothing else, so
                -- the only way on was to invent a second name. Offer the replacement instead,
                -- named and spelled out, rather than refusing or doing it silently.
                if ns.ProfileExists and ns.ProfileExists(name) then
                    ConfirmOn("Replace", "It starts empty at default settings, on every "
                        .. "character standing in it. Cannot be undone.", "Replace", name,
                        function(n)
                            local ok, err = ns.CreateProfile(n, true)
                            if not ok then return false, err end
                            ns.SwitchProfile(n)
                            return true
                        end)
                    return
                end
                local ok, err = ns.CreateProfile(name)
                if not ok then ns.Print(err) return end
                ns.SwitchProfile(name)
                AfterChange()
            end)
        end)
        newBtn:SetPoint("LEFT", profRow._leftRegion, "LEFT", 20, 0)
        ns.Tooltip(newBtn, "New Profile", "A fresh profile with default settings. It becomes "
            .. "the one every character on this account uses, including any you log into "
            .. "later. Switch a single character afterwards if you want it on its own.")
        -- "Save As", not "Copy": what it does is store what you have set up under a name of
        -- your choosing, which is what someone looks for a Save button to do. There is no
        -- plain Save because there is nothing to save -- every change is written into the
        -- profile as it is made, and a button that did nothing would only suggest otherwise.
        local copyBtn = ns.Button(profRow._leftRegion, "Save As New Profile", 150, 22, function()
            ShowNamePrompt("Save As New Profile", "Save", "", function(text)
                local name = text:match("^%s*(.-)%s*$")
                if ns.ProfileExists and ns.ProfileExists(name) then
                    ConfirmOn("Overwrite", "Everything set up right now replaces what is "
                        .. "stored under it, on every character standing in it. Cannot be "
                        .. "undone.", "Overwrite", name,
                        function(n)
                            local ok, err = ns.CopyProfile(ns.ActiveProfileName(), n, true)
                            if not ok then return false, err end
                            ns.SwitchProfile(n)
                            return true
                        end)
                    return
                end
                local ok, err = ns.CopyProfile(ns.ActiveProfileName(), name)
                if not ok then ns.Print(err) return end
                ns.SwitchProfile(name)
                AfterChange()
            end)
        end)
        copyBtn:SetPoint("LEFT", newBtn, "RIGHT", 8, 0)
        ns.Tooltip(copyBtn, "Save As New Profile", "Stores everything set up right now as a "
            .. "new profile under a name you choose, and switches to it. Your current "
            .. "profile is left as it was.")

        -- Import always lands a NEW profile and never touches what is here, which is the
        -- right default and the wrong tool once somebody else maintains part of your
        -- setup. This is that other tool.
        local mergeBtn = ns.Button(profRow._rightRegion, "Merge a Profile In", 150, 22,
            function()
                if ns.ShowProfileMergeDialog then ns.ShowProfileMergeDialog() end
            end)
        mergeBtn:SetPoint("LEFT", profRow._rightRegion, "LEFT", 20, 0)
        ns.Tooltip(mergeBtn, "Merge a Profile In", "Takes a profile string somebody else "
            .. "maintains and merges it into one of yours. A spec they look after "
            .. "replaces yours for that spec; specs they do not cover are left exactly "
            .. "as they are, and per-boss reminders are added rather than swapped.")
    end

    -- Reset and Delete pick their target rather than acting on whatever is loaded. Having to
    -- switch to a profile before you could delete it meant loading the thing you were trying
    -- to get rid of, and reading the confirm dialog as the only clue you were on the right
    -- one. Northern Sky drives both from dropdowns; these do the same.
    local pickValues, pickOrder = { [""] = "Choose a profile..." }, { "" }
    for i = 1, #profNames do
        pickValues[profNames[i]] = profNames[i]
        pickOrder[#pickOrder + 1] = profNames[i]
    end

    -- Confirms name the profile CHOSEN, not the one in use -- the whole point is that they
    -- differ. Both reset to the placeholder afterwards through the page refresh.
    ConfirmOn = function(title, hintText, verb, chosen, act)
        local dimmer, panel = ns.MakeModal(360, 140, "profileActConfirm")
        local head = ns.Font(panel, 14, "OUTLINE")
        head:SetPoint("TOP", panel, "TOP", 0, -16)
        head:SetText(("%s '%s'?"):format(title, chosen))
        local hint = ns.Font(panel, 11, nil, ns.THEME.muted)
        hint:SetPoint("TOP", head, "BOTTOM", 0, -8)
        hint:SetPoint("LEFT", panel, "LEFT", 16, 0)
        hint:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
        hint:SetText(hintText)
        local yes = ns.Button(panel, verb, 100, 24, function()
            local ok, err = act(chosen)
            if not ok and err then ns.Print(err) end
            dimmer:Hide()
            EUI:RefreshPage(true)
        end)
        yes:SetPoint("BOTTOM", panel, "BOTTOM", -56, 14)
        ns.Button(panel, "Cancel", 100, 24, function()
            dimmer:Hide()
            EUI:RefreshPage(true)
        end):SetPoint("BOTTOM", panel, "BOTTOM", 56, 14)
        dimmer:Show()
    end

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Reset Profile",
          values = pickValues, order = pickOrder,
          tooltip = "Wipes the chosen profile's settings back to defaults. Every other "
          .. "profile is untouched, and you do not have to be standing in it.",
          getValue = function() return "" end,
          setValue = function(v)
              if v == "" then return end
              ConfirmOn("Reset", "Every setting in it returns to default. Cannot be undone.",
                  "Reset", v, ns.ResetProfileNamed)
          end },
        { type = "dropdown", text = "Delete Profile",
          values = pickValues, order = pickOrder,
          tooltip = "Removes the chosen profile. Characters using it move to the account's "
          .. "default profile, and the last profile cannot be deleted.",
          getValue = function() return "" end,
          setValue = function(v)
              if v == "" then return end
              ConfirmOn("Delete", "Cannot be undone. Characters using it move to the "
                  .. "account's default profile.", "Delete", v, ns.DeleteProfile)
          end }
    ); y = y - h
    local packRow
    packRow, h = W:DualRow(parent, y,
        { type = "label", text = "      Share your Smart Reminders" },
        { type = "label", text = "" }
    ); y = y - h
    -- Not AttachInline here: it chains off a region's existing control, and this right
    -- half has none (its label field is blank) -- it fell back to anchoring off the
    -- region's own LEFT edge (the row's midpoint) instead, so the button sat in the
    -- row's LEFT half and overlapped the label text next to it regardless of width.
    -- Anchored to the region's own RIGHT edge directly instead.
    if packRow and packRow._rightRegion then
        local btn = ns.Button(packRow._rightRegion, "Share your Profile", 130, 22, function()
            if ns.ShowPackExport then ns.ShowPackExport() end
        end)
        btn:SetPoint("RIGHT", packRow._rightRegion, "RIGHT", -14, 0)
        ns.Tooltip(btn, "Share your Smart Reminders",
            "Everything a curator sets up -- priority lists, per-boss orders, callouts and "
            .. "written reminders -- as one string to share. A profile built from someone "
            .. "else's imported pack cannot be shared onward.")
    end
    local packRow2
    packRow2, h = W:DualRow(parent, y,
        { type = "label", text = "      Import Smart Reminder Profile" },
        { type = "label", text = "" }
    ); y = y - h
    if packRow2 and packRow2._rightRegion then
        local btn = ns.Button(packRow2._rightRegion, "Import Profile", 120, 22, function()
            if ns.ShowPackImport then ns.ShowPackImport() end
        end)
        btn:SetPoint("RIGHT", packRow2._rightRegion, "RIGHT", -14, 0)
        ns.Tooltip(btn, "Import Profile",
            "Paste a profile string. Nothing applies until you press Import, and a damaged "
            .. "string is refused outright.")
    end

    return y
end

-- InstanceSlot/AttachInstanceCog (the old bulk on/off toggle + cog opening the old
-- fingerprint-accordion boss modal, both since removed) were here and are gone -- the left
-- column is pure navigation now, and the bulk on/off they wrote is still reachable, just
-- relocated to the selected boss's own Enable This Boss toggle (on the boss-picker row
-- in RenderInstanceDetail) instead of a per-instance shortcut.

-- Which instance is selected on each tab, and which boss within it -- both persist
-- across a RefreshPage (module-level upvalues, not page-local), the same way the Setup
-- tab's old tile selection did before that got removed. Independent per tab: picking a
-- dungeon must not disturb whichever raid was showing.
local selectedInst = { dungeon = nil, raid = nil }
local selectedBossIdx = {}   -- keyed by instance.id

-- One ability row: checkbox (this ability's binding, stored in AbilityBindingsTable by
-- its journal spellID), icon, title, description, a cog on the right. Fixed height rather
-- than measured from the wrapped description's real extent -- GetStringHeight() right
-- after SetPoint/SetText depends on this row's own width having already resolved through
-- its parent chain, which is exactly the kind of synchronous-layout assumption that
-- produced the Setup-tab overlap earlier tonight. A long description clips instead;
-- annoying, never wrong.
-------------------------------------------------------------------------------
--  Per-ability reminder picker: this ability's spot on the normal defensive
--  priority list, and (Custom Reminder tab) a written note of its own bound
--  straight to its own BigWigs cast/bar -- built on the Raid Reminder engine
--  (NaowhUI_SmartReminders_RaidReminders.lua) so it can be assigned to a role/class/
--  spec/name/subgroup too, the same NSRT/TimelineReminders-style tool
--  ns.ShowBossReminderPicker's boss-wide reminders already are.
-------------------------------------------------------------------------------
local RR_ROLE_VALUES = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }
local RR_ROLE_ORDER = { "TANK", "HEALER", "DAMAGER" }

-- Categories join with " + " (AND, narrows), values within one category join with
-- "/" (OR, widens) -- mirrors ns.RaidReminderTargetsMe's own semantics exactly, so
-- what the summary says is what the targeting actually does.
local function RaidReminderTargetDesc(target)
    target = ns.NormalizeRaidReminderTarget(target)
    if target.all then return "Everyone" end

    local function Joined(set, label, order)
        if not (set and next(set)) then return nil end
        local list = {}
        for key in pairs(set) do list[#list + 1] = (label and label(key)) or tostring(key) end
        table.sort(list)
        return table.concat(list, order or "/")
    end

    local parts = {}
    local p
    p = Joined(target.roles, function(k) return RR_ROLE_VALUES[k] or k end); if p then parts[#parts + 1] = p end
    p = Joined(target.classes, function(k)
        local names = _G.LOCALIZED_CLASS_NAMES_MALE
        return (names and names[k]) or k
    end); if p then parts[#parts + 1] = p end
    p = Joined(target.specs, ns.SpecName); if p then parts[#parts + 1] = p end
    p = Joined(target.names, nil, ", "); if p then parts[#parts + 1] = p end
    p = Joined(target.subgroups, function(k) return "Group " .. k end); if p then parts[#parts + 1] = p end

    if #parts == 0 then return "Everyone" end
    return table.concat(parts, " + ")
end

-- A reminder built from this ability's own cog carries abilitySpellID (the journal
-- spellID, not necessarily the same value as trigger.spellID -- the BigWigs key the
-- mechanic picker resolved it to) so it shows here instead of in the boss-wide list
-- ns.ShowBossReminderPicker renders. One per ability, same as the old bound-reminder
-- model this replaces -- first match wins.
local function FindBoundRaidReminder(encounterID, spellID)
    local set = ns.RaidRemindersTable and ns.RaidRemindersTable(false, encounterID)
    if not set then return nil, nil end
    for uid, r in pairs(set) do
        if r.abilitySpellID == spellID then return uid, r end
    end
    return nil, nil
end

local RR_DISPLAY_VALUES = { text = "Message", timer = "Timer", icon = "Icon", bar = "Bar",
    circle = "Circle", chat = "Chat Line", nameplateGlow = "Nameplate Glow",
    raidframeGlow = "Raid-Frame Glow" }
local RR_DISPLAY_ORDER = { "text", "timer", "icon", "bar", "circle", "chat",
    "nameplateGlow", "raidframeGlow" }
-- LOCALIZED_CLASS_NAMES_MALE carries every class token the client knows, including ones
-- nobody plays -- Adventurer and Traveler both show up in it and were landing in the class
-- grids. GetClassInfo bounded by GetNumClasses walks only the real playable set, which is
-- how Blizzard's own class filter menu builds its list.
-- Returns { token, displayName } pairs sorted by display name.
function ns.PlayableClasses()
    local out = {}
    if GetNumClasses and GetClassInfo then
        for i = 1, GetNumClasses() do
            local displayName, token = GetClassInfo(i)
            if token and displayName then out[#out + 1] = { token, displayName } end
        end
    end
    if #out == 0 then
        for token, displayName in pairs(_G.LOCALIZED_CLASS_NAMES_MALE or {}) do
            out[#out + 1] = { token, displayName }
        end
    end
    table.sort(out, function(a, b) return a[2] < b[2] end)
    return out
end

-- Human-readable summary of who loads a binding. Its own spec always does -- that is the
-- table it is stored in -- so this only ever describes the extra role/class shares.
function ns.DescribeBindingScope(scope)
    if type(scope) ~= "table" or not next(scope) then return "this spec only" end
    local parts = { "this spec" }

    local roles = {}
    for role in pairs(scope.roles or {}) do
        roles[#roles + 1] = (role == "DAMAGER" and "DPS") or (role:sub(1, 1) .. role:sub(2):lower())
    end
    table.sort(roles)
    if #roles > 0 then parts[#parts + 1] = "any " .. table.concat(roles, "/") end

    local classes = {}
    local names = _G.LOCALIZED_CLASS_NAMES_MALE or {}
    for token in pairs(scope.classes or {}) do
        classes[#classes + 1] = names[token] or token
    end
    table.sort(classes)
    if #classes > 0 then parts[#parts + 1] = "any " .. table.concat(classes, "/") end

    return table.concat(parts, " + ")
end

-- Shares one binding with specs other than the one that owns it. There is no spec list:
-- the owning spec always loads it, and naming other specs individually is what the role
-- and class rows cover without a 39-entry matrix in a 400-wide modal.
function ns.ShowBindingScopePicker(scope, onAccept)
    local dimmer, panel = ns.MakeModal(400, 470, "bindingScopePicker")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText("Loads for")

    local hint = ns.Font(panel, 10, nil, ns.THEME.muted)
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -40)
    hint:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("The spec that made this always loads it. Tick anything here to share it with other specs as well.")

    -- Working copies, so Cancel leaves the saved scope untouched.
    local roles, classes = {}, {}
    for k in pairs(type(scope) == "table" and scope.roles or {}) do roles[k] = true end
    for k in pairs(type(scope) == "table" and scope.classes or {}) do classes[k] = true end

    local y = -74
    local function Label(text)
        local l = ns.Font(panel, 11, nil, ns.THEME.muted)
        l:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
        l:SetText(text)
        y = y - 18
    end
    local function Grid(items, set, perRow, itemW, colorFn)
        for i = 1, #items do
            local key, label = items[i][1], items[i][2]
            local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
            local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            check:SetSize(18, 18)
            check:SetPoint("TOPLEFT", panel, "TOPLEFT", 20 + col * itemW, y - row * 22)
            check:SetChecked(set[key])
            check:SetScript("OnClick", function(self)
                set[key] = self:GetChecked() and true or nil
            end)
            local lbl = ns.Font(panel, 10, nil, ns.THEME.fg)
            lbl:SetPoint("LEFT", check, "RIGHT", 2, 0)
            lbl:SetWordWrap(false)
            lbl:SetText(label)
            if colorFn then
                local r, g, b = colorFn(key)
                if r then lbl:SetTextColor(r, g, b, 1) end
            end
        end
        y = y - math.ceil(#items / perRow) * 22 - 10
    end

    Label("Also load for any of these roles")
    Grid({ { "TANK", "Tank" }, { "HEALER", "Healer" }, { "DAMAGER", "DPS" } }, roles, 3, 110)

    Label("...or any of these classes")
    do
        local items = ns.PlayableClasses()
        local colors = RAID_CLASS_COLORS or CUSTOM_CLASS_COLORS
        Grid(items, classes, 3, 120, function(token)
            local c = colors and colors[token]
            if c then return c.r, c.g, c.b end
        end)
    end

    ns.Button(panel, "Accept", 90, 26, function()
        local out = {}
        if next(roles) then out.roles = roles end
        if next(classes) then out.classes = classes end
        -- Nothing ticked means private to the owning spec, which is nil rather than an
        -- empty table so it never lands in SavedVariables as noise.
        onAccept(next(out) and out or nil)
        dimmer:Hide()
    end):SetPoint("BOTTOM", panel, "BOTTOM", -50, 16)
    ns.Button(panel, "Cancel", 90, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOM", panel, "BOTTOM", 50, 16)

    dimmer:Show()
end



function ns.ShowAbilityReminderPicker(encounterID, ability, callerEUI)
    local EUI = callerEUI or ns.UI
    local W = EUI.Widgets

    -- Taller than before (was 440x480/body 320): a preset can carry up to MAX_SLOTS
    -- defensives, each now its own row below the preset dropdown. Grown by the same
    -- amount panel and body both, preserving the original's ~84px margin above Save/
    -- Cancel -- matches the 480x620 precedent this file already uses for its other,
    -- taller modal (the full custom reminder editor).
    local dimmer, panel = ns.MakeModal(440, 640, "abilityReminderPicker")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText(ability.title or "Ability")

    local PAD = 20
    local TAB_TOP = -46

    local binding = ns.EnsureBinding(encounterID, ability.spellID)
    local specID = ns.CurrentSpec and ns.CurrentSpec()
    -- Held rather than written straight through, so Cancel discards a scope change the
    -- same way it discards a preset pick.
    local scopeVal = binding.scope
    local healerVal = binding.healerReminder == true
    -- One warning time for the whole preset on this ability -- not per defensive within
    -- it (that granularity was tried and dropped: too fiddly for what it bought). Lazily
    -- initialized inside RebuildBody, same reasoning presetVal below documents: re-deriving
    -- it on every rebuild would stomp an in-progress drag the instant switching tabs or
    -- presets triggered one.
    local leadTimeVal
    -- Same lazy-init reasoning as leadTimeVal: a rebuild must not stomp an unsaved choice.
    local externalVal

    -- Same destroy-and-recreate idiom as the custom reminder editor's own dynFrame: the
    -- old body is hidden and dropped rather than cleared field by field, since GetChildren
    -- only ever returns child FRAMES, not the label FontStrings this also has to remove.
    local body
    -- presetVal is written by the dropdown built in RebuildBody and read back by Save()
    -- -- it has to outlive any single rebuild, since a pick must not be lost if switching
    -- tabs or presets forces a reflow later.
    local presetVal

    -- RebuildBody is assigned below (forward-declared here so SelectPageTab, built next,
    -- can close over it) -- same forward-reference shape RebuildTriggerFields uses in
    -- ShowRaidReminderEditor above.
    local RebuildBody

    -- Two tabs, independent of each other rather than mutually exclusive like the old
    -- single-toggle model: Defensive Preset (unchanged) and Custom Reminder, a written
    -- note bound straight to this ability's own BigWigs cast/bar. An ability can carry
    -- both -- the defensive callout is always for you; a Custom Reminder can target
    -- anyone, so silencing one when the other is set would be wrong as often as right.
    local pageTab = "defensive"
    local tabBtns = {}
    local function SelectPageTab(id)
        pageTab = id
        for tid, btn in pairs(tabBtns) do
            local on = (tid == id)
            btn.marker:SetShown(on)
            local c = on and ns.THEME.fg or ns.THEME.muted
            btn.label:SetTextColor(c.r, c.g, c.b, 1)
        end
        RebuildBody()
    end
    local function AddPageTab(id, text, anchorTo)
        local btn = CreateFrame("Button", nil, panel)
        btn:SetHeight(22)
        local lbl = ns.Font(btn, 12, nil, ns.THEME.muted)
        lbl:SetText(text)
        btn:SetSize(lbl:GetStringWidth() + 4, 22)
        lbl:SetPoint("CENTER")
        if anchorTo then btn:SetPoint("LEFT", anchorTo, "RIGHT", 18, 0)
        else btn:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, TAB_TOP) end
        local marker = ns.Solid(btn, "OVERLAY", ns.THEME.accent, 1)
        marker:SetPoint("BOTTOMLEFT", 0, -3)
        marker:SetPoint("BOTTOMRIGHT", 0, -3)
        marker:SetHeight(2)
        marker:Hide()
        btn:SetScript("OnClick", function() SelectPageTab(id) end)
        btn.label, btn.marker = lbl, marker
        tabBtns[id] = btn
        return btn
    end
    local defTabBtn = AddPageTab("defensive", "Cooldown Preset")
    AddPageTab("custom", "Ability Reminder", defTabBtn)
    defTabBtn.marker:Show()
    defTabBtn.label:SetTextColor(ns.THEME.fg.r, ns.THEME.fg.g, ns.THEME.fg.b, 1)

    RebuildBody = function()
        if body then body:Hide() end
        body = CreateFrame("Frame", nil, panel)
        body:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, TAB_TOP - 30)
        body:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, TAB_TOP - 30)
        -- An explicit height, not just the two TOP anchors -- matching dynFrame in the full
        -- custom reminder editor below (SetSize) and messageBody/triggerBody in the same
        -- (SetHeight): a frame anchored on only one edge never resolves a height on its
        -- own, and every rebuilt-body frame elsewhere in this file sets one for that reason.
        body:SetHeight(480)

        -- Wrapped: a blank body with no error anywhere on screen is the exact failure mode
        -- that shipped once already (the tab buttons mispositioned so badly the whole
        -- panel looked dead). If something in here throws, this says so instead of leaving
        -- another silent blank panel.
        local ok, err = pcall(function()
        local by = 0

        -- One-column helpers throughout -- W:DualRow's second slot always reserves the
        -- full right half even fed a blank label, which is exactly the dead space this
        -- popup does not have the width to spare (it is 440px, not a page-width column).
        local function Label(text)
            local lbl = ns.Font(body, 11, nil, ns.THEME.muted)
            lbl:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            lbl:SetText(text)
            by = by - 16
        end
        -- Fixed width instead of stretching to the body's edge, matching every other
        -- field this popup lines up on both edges.
        local FIELD_W = 260
        -- A single dropdown row, fixed width to FIELD_W -- BuildDropdownControl
        -- is the same primitive W:DualRow's own "dropdown" slot type calls, without the
        -- page-row chrome (background band, hover-tag) that widget wraps it in, which is
        -- built for a full-width options page rather than a small modal.
        local function DropdownRow(values, order, getValue, setValue)
            local ddBtn = EUI.BuildDropdownControl(body, FIELD_W,
                body:GetFrameLevel() + 1, values, order, getValue, setValue)
            ddBtn:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            by = by - 32
            return ddBtn
        end

        if pageTab == "defensive" then
            -- One preset, not a hand-built list: this ability draws from whichever preset
            -- is chosen here, the same way a boss or a custom reminder already draws from
            -- one -- edited on the Setup page, not duplicated per ability.
            local presets = ns.ListPresets(specID)
            if #presets == 0 then
                local hint = ns.Font(body, 11, nil, ns.THEME.muted)
                hint:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
                hint:SetPoint("RIGHT", body, "RIGHT", 0, 0)
                hint:SetWordWrap(true)
                hint:SetText("|cff9a9ea6No presets yet -- add one on the Setup page "
                    .. "first.|r")
                by = by - 34
            else
                local presetValues, presetOrder = {}, {}
                for i = 1, #presets do
                    presetValues[presets[i].key] = presets[i].name
                    presetOrder[i] = presets[i].key
                end
                -- Derived from binding.preset ONLY the first time this body is ever
                -- built (presetVal starts nil, and no real preset key is ever nil) --
                -- shows the effective default (this boss's preset, else the spec's
                -- active one) until this ability actually gets its own pick, matching
                -- the same fallback EffectiveList itself uses at runtime. A rebuild
                -- triggered by the dropdown's OWN change must never re-derive this: it
                -- would re-read binding.preset, still the OLD value until Save() runs,
                -- and stomp the pick right back to it -- which is exactly what made the
                -- dropdown look stuck on the old preset the instant a different one was
                -- clicked (the same trap leadTimeVal's own init below already has to
                -- dodge, just missed here when RebuildBody() was added to this one).
                if presetVal == nil then
                    presetVal = binding.preset or ns.BossPresetKey(specID, encounterID)
                        or ns.ActivePresetKey(specID) or presetOrder[1]
                end
                Label("Cooldown Preset")
                DropdownRow(presetValues, presetOrder,
                    function() return presetVal end,
                    function(v) presetVal = v end)
            end

            local note = ns.Font(body, 10, nil, ns.THEME.muted)
            note:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            note:SetPoint("RIGHT", body, "RIGHT", 0, 0)
            note:SetJustifyH("LEFT")
            note:SetWordWrap(true)
            note:SetText("Calls out the highest defensive on that preset still ready "
                .. "when this ability is cast.")
            by = by - 30

            -- Lazily initialized, not re-derived on every rebuild (see its own comment
            -- above) -- an edit that triggers a rebuild (switching presets or tabs) must
            -- not stomp a drag still in progress.
            if leadTimeVal == nil then
                leadTimeVal = binding.leadTime or (ns.DB().leadTime or 3)
            end
            Label("Warning Time (+before / -after impact)")
            -- -30 to 10, not 0 to 10: requested for Rav'i's Triple Shot, called out a beat
            -- AFTER the volley lands rather than before it. Negative is what that is --
            -- ScheduleBWFire already reads a lead past the bar's own length as "wait this
            -- much further" once the sign flips, so this is the one place that needed to
            -- change, not a second mode alongside it. -30 comfortably covers a delayed call
            -- on anything shorter than a boss's longest bars; the spec-wide default stays
            -- positive-only on its own slider on the Setup page.
            local trackFrame, valBox = EUI.BuildSliderCore(body, 200, 4, 12, 40, 22, 12,
                1, -30, 10, 1,
                function() return leadTimeVal end,
                function(v) leadTimeVal = v end)
            trackFrame:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            valBox:SetPoint("LEFT", trackFrame, "RIGHT", 10, 0)
            by = by - 32

            local leadHint = ns.Font(body, 10, nil, ns.THEME.muted)
            leadHint:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            leadHint:SetPoint("RIGHT", body, "RIGHT", 0, 0)
            leadHint:SetJustifyH("LEFT")
            leadHint:SetWordWrap(true)
            leadHint:SetText("Positive calls out before the hit lands, as usual. Negative "
                .. "waits until that many seconds AFTER it lands instead -- for a defensive "
                .. "that only matters once the mechanic is over.")
            by = by - math.ceil(leadHint:GetStringHeight()) - 16

            -- The last step, per ability rather than once for the spec. Defaults to whatever
            -- the spec-wide toggle says and only stores a value when it differs, the same
            -- rule leadTime saves under.
            if externalVal == nil then
                externalVal = ns.ExternalCallFor(encounterID, ability.spellID)
            end
            Label("|cff6DD09AHealer|r Reminder")
            local healerCheck = EUI.BuildToggleControl(body, body:GetFrameLevel() + 1,
                function() return healerVal end,
                function(v) healerVal = v and true or false end)
            healerCheck:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            ns.Tooltip(healerCheck, "Healer Reminder",
                "Mark this preset callout for the healer-reminder switch. General defensive callouts should stay unmarked.")
            by = by - 38

            Label("Call for an External when nothing of yours is up")
            local extHint = ns.Font(body, 10, nil, ns.THEME.muted)
            extHint:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            extHint:SetPoint("RIGHT", body, "RIGHT", 0, 0)
            extHint:SetJustifyH("LEFT")
            extHint:SetWordWrap(true)
            extHint:SetText("Off means this ability stays silent when your list is empty, "
                .. "instead of asking the raid for help on a hit nobody was going to answer. "
                .. "Untouched, it follows the spec-wide setting on the Setup page.")
            by = by - math.ceil(extHint:GetStringHeight()) - 10

            local extCheck = (EUI or ns.UI).BuildToggleControl(body, body:GetFrameLevel() + 1,
                function() return externalVal end,
                function(v) externalVal = v and true or false end)
            extCheck:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            by = by - 26

        else
            local hint = ns.Font(body, 11, nil, ns.THEME.muted)
            hint:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
            hint:SetPoint("RIGHT", body, "RIGHT", 0, 0)
            hint:SetJustifyH("LEFT")
            hint:SetWordWrap(true)
            hint:SetText("A written note tied straight to this ability's own BigWigs "
                .. "cast or bar -- assignable to a role, class, spec, player or "
                .. "subgroup, not just you.")
            by = by - 36

            local uid, entry = FindBoundRaidReminder(encounterID, ability.spellID)
            if entry then
                local nameLbl = ns.Font(body, 12, nil, ns.THEME.fg)
                nameLbl:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
                nameLbl:SetText(entry.name or "Reminder")
                by = by - 18

                local descLbl = ns.Font(body, 11, nil, ns.THEME.muted)
                descLbl:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
                descLbl:SetText(RaidReminderTargetDesc(entry.target) .. "  -- "
                    .. (RR_DISPLAY_VALUES[entry.display and entry.display.type] or "Message"))
                by = by - 30

                local editBtn = ns.Button(body, "Edit", 100, 26, function()
                    local nestedDimmer = ns.ShowRaidReminderEditor(
                        encounterID, uid, EUI, nil, ability.spellID)
                    if nestedDimmer then nestedDimmer:HookScript("OnHide", RebuildBody) end
                end)
                editBtn:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
                local removeBtn = ns.Button(body, "Remove", 100, 26, function()
                    local writeSet = ns.RaidRemindersTable(false, encounterID)
                    if writeSet then writeSet[uid] = nil end
                    RebuildBody()
                end)
                removeBtn:SetPoint("LEFT", editBtn, "RIGHT", 10, 0)
                by = by - 32
            else
                local noneLbl = ns.Font(body, 11, nil, ns.THEME.muted)
                noneLbl:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
                noneLbl:SetText("None yet for this ability.")
                by = by - 26

                local addBtn = ns.Button(body, "+ Add a Ability Reminder", 200, 26, function()
                    local nestedDimmer = ns.ShowRaidReminderEditor(
                        encounterID, nil, EUI, nil, ability.spellID)
                    if nestedDimmer then nestedDimmer:HookScript("OnHide", RebuildBody) end
                end)
                addBtn:SetPoint("TOPLEFT", body, "TOPLEFT", 0, by)
                by = by - 32
            end
        end
        end)
        if not ok then
            local errText = ns.Font(body, 11, nil, { r = 1, g = 0.35, b = 0.35 })
            errText:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
            errText:SetPoint("RIGHT", body, "RIGHT", 0, 0)
            errText:SetJustifyH("LEFT")
            errText:SetWordWrap(true)
            errText:SetText("Failed to build this panel: " .. tostring(err))
            ns.Print("|cffff6060ability reminder picker|r: " .. tostring(err))
        end
    end

    RebuildBody()

    -- Only the Defensive Preset tab's settings -- the Custom Reminder tab saves
    -- immediately through its own nested editor's Save button (ns.ShowRaidReminderEditor),
    -- there's nothing of its deferred to this button.
    local function Save()
        -- "defensive" unconditionally: nothing on this picker writes "custom" anymore
        -- (the Custom Reminder tab is additive now, not a mode switch -- see the header
        -- comment above), so this also self-heals a profile with a stale "custom" from
        -- before that change, which would otherwise silently suppress this ability's
        -- Pre-Selected Defensives pick forever (ns.HandleBigWigsAbility's own gate).
        binding.mode = "defensive"
        binding.preset = presetVal
        -- Per-defensive leadTimeBySpell was tried and dropped -- too fiddly for what it
        -- bought -- back to one warning time for the whole preset on this ability. No
        -- migration: any leftover leadTimeBySpell from that build is simply never read
        -- again once this saves.
        binding.leadTimeBySpell = nil
        binding.leadTime = (leadTimeVal ~= (ns.DB().leadTime or 3)) and leadTimeVal or nil
        -- nil when it agrees with the spec-wide toggle, so an ability that was never given
        -- an opinion keeps following that toggle when it later changes.
        if externalVal == nil or externalVal == (ns.DB().fallbackOn ~= false) then
            binding.external = nil
        else
            binding.external = externalVal
        end
        binding.scope = scopeVal
        binding.healerReminder = healerVal or nil
        ns.ApplyReminderFilter()
        ns.RefreshRuntime()
        dimmer:Hide()
        if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
    end

    -- Sits above Save/Cancel rather than in either tab: the scope is the binding's, not
    -- the Defensive Preset's or the Custom Reminder's, so it must not move with the tabs.
    local scopeText = ns.Font(panel, 10, nil, ns.THEME.muted)
    scopeText:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, 52)
    scopeText:SetPoint("RIGHT", panel, "RIGHT", -PAD - 76, 0)
    scopeText:SetJustifyH("LEFT")
    scopeText:SetWordWrap(false)
    local function RefreshScopeText()
        scopeText:SetText("Loads for: " .. ns.DescribeBindingScope(scopeVal))
    end
    RefreshScopeText()

    ns.Button(panel, "Change", 70, 22, function()
        ns.ShowBindingScopePicker(scopeVal, function(newScope)
            scopeVal = newScope
            RefreshScopeText()
        end)
    end):SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, 48)

    ns.Button(panel, "Save", 90, 26, Save):SetPoint("BOTTOM", panel, "BOTTOM", -50, 16)
    ns.Button(panel, "Cancel", 90, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOM", panel, "BOTTOM", 50, 16)

    dimmer:Show()
end

local ABILITY_ROW_H = 62

local function RenderAbilityRow(parent, y, encounterID, ability, specID, EUI)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    row:SetHeight(ABILITY_ROW_H)

    -- The tick is whether the boss has the ability, same as the Add Ability picker's, so
    -- unticking silences the ability but keeps it, along with its preset and warning time.
    -- Taking it off the boss entirely is the X, which asks first -- an untick is reversible
    -- with the same click, a delete is not, so they are deliberately different controls.
    local enabled = ability.spellID and ns.AbilityEnabledForBinding(encounterID, ability.spellID, true)

    -- The addon's own toggle rather than a Blizzard checkbox, matching every other on/off
    -- control in here. `enabled` backs the getter so the widget reads its own state without
    -- another binding lookup per repaint.
    local check = (EUI or ns.UI).BuildToggleControl(row, row:GetFrameLevel() + 1,
        function() return enabled end,
        function(v)
            if not ability.spellID then return end
            enabled = v and true or false
            ns.EnsureBinding(encounterID, ability.spellID).enabled = enabled
            ns.RefreshRuntime()
            if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
        end)
    check:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -6)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(30, 30)
    icon:SetPoint("TOPLEFT", check, "TOPRIGHT", 8, 6)
    if ability.icon then icon:SetTexture(ability.icon) end
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local cog = ns.Button(row, "...", 30, 26, function()
        if not ability.spellID then
            ns.Print("|cffff6060this journal entry has no spell id to bind to|r")
            return
        end
        ns.ShowAbilityReminderPicker(encounterID, ability, EUI)
    end)
    cog:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -4)

    local test = ns.Button(row, "Test", 44, 26, function()
        if not ability.spellID then
            ns.Print("|cffff6060this journal entry has no spell id to bind to|r")
            return
        end
        ns.TestFireAbility(encounterID, ability.spellID)
    end)
    test:SetPoint("TOPRIGHT", cog, "TOPLEFT", -4, 0)

    local remove = ns.Button(row, "X", 26, 26, function()
        ns.ConfirmRemoveAbility(encounterID, ability, EUI)
    end)
    remove:SetPoint("TOPRIGHT", test, "TOPLEFT", -4, 0)
    remove.label:SetTextColor(1, 0.38, 0.38, 1)
    ns.Tooltip(remove, "Remove Ability",
        "Take this ability off the boss. Its preset and warning time go with it.")

    -- Role/difficulty flags straight off the journal (FLAG_LABELS, same icon set the
    -- in-game Adventure Guide shows) -- Tank/Dps/Healer first since those are the ones
    -- worth a glance, the rest folded into the description line below instead of a
    -- second row, which is what caused the Setup-tab overlap this row's fixed height
    -- comment already warns about.
    local roleTag, restTag
    if ability.extras then
        local roles, rest = {}, {}
        for label in ability.extras:gmatch("[^,]+") do
            label = label:match("^%s*(.-)%s*$")
            if ROLE_COLOR[label] then
                roles[#roles + 1] = ROLE_COLOR[label] .. label .. "|r"
            elseif label ~= "" then
                rest[#rest + 1] = label
            end
        end
        if #roles > 0 then roleTag = table.concat(roles, " ") end
        if #rest > 0 then restTag = table.concat(rest, ", ") end
    end

    local title = ns.Font(row, 13, nil, ns.THEME.fg)
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -2)
    title:SetPoint("RIGHT", remove, "LEFT", -8, 0)
    title:SetJustifyH("LEFT")
    local binding = ability.spellID and ns.BindingForBossModKey(encounterID, ability.spellID)
    local healerTag = binding and binding.healerReminder and "  |cff6DD09A[Healer Reminder]|r" or ""
    title:SetText((ability.title or "?") .. (roleTag and ("  " .. roleTag) or "") .. healerTag)

    local desc = ns.Font(row, 11, nil, ns.THEME.muted)
    desc:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -20)
    desc:SetPoint("RIGHT", remove, "LEFT", -8, 0)
    desc:SetHeight(ABILITY_ROW_H - 24)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    local descText = ability.description or "|cff9a9ea6No description in the journal.|r"
    if restTag then descText = ("|cff9a9ea6[%s]|r  "):format(restTag) .. descText end
    desc:SetText(descText)

    local div = ns.Solid(row, "ARTWORK", ns.THEME.line, 1)
    div:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    div:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    div:SetHeight(1)

    return y - ABILITY_ROW_H
end

-- The selected instance's own view: Share Profile / Select Boss, the boss's own
-- Explicit message-driven defensive reminders, below the boss's ability rows.
local function RenderBossMessageSection(parent, y, EUI, encounterID)
    local PADR = EUI.CONTENT_PAD or 16
    local function Refresh() EUI:RefreshPage(true) end
    local function Edit(uid)
        local d = ns.ShowCustomReminderEditor(encounterID, uid, EUI, "bwmsg")
        if d then d:HookScript("OnHide", Refresh) end
    end

    local head = ns.Font(parent, 12, nil, ns.THEME.accent)
    head:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    head:SetText("BOSS REMINDERS")
    y = y - 20

    local note = ns.Font(parent, 11, nil, ns.THEME.muted)
    note:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    note:SetPoint("RIGHT", parent, "RIGHT", -PADR, 0)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetText("Your own reminders for this boss. A reminder can start from a BigWigs or "
        .. "DBM message, or from the boss beginning or finishing a cast -- pick which in the "
        .. "editor. A message trigger needs Messages enabled for that ability in BigWigs. "
        .. "Bars keep using the ability's own preset and warning time, so both can run "
        .. "together. Test previews the saved output immediately, without waiting.")
    note:SetHeight(math.max(16, note:GetStringHeight() + 4))
    y = y - note:GetHeight() - 8

    local set = ns.CustomRemindersTable and ns.CustomRemindersTable(false, encounterID)
    local list = {}
    if set then
        for uid, r in pairs(set) do
            if r.trigger and (r.trigger.type == "bwmsg" or r.defensive)
                and (not r.specID or r.specID == ns.CurrentSpec()) then
                list[#list + 1] = { uid = uid, r = r }
            end
        end
        table.sort(list, function(a, b) return (a.r.name or "") < (b.r.name or "") end)
    end

    if #list == 0 then
        local none = ns.Font(parent, 11, nil, ns.THEME.muted)
        none:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
        none:SetText("None yet for this boss.")
        y = y - 20
    else
        for i = 1, #list do
            local uid, r = list[i].uid, list[i].r
            local row = CreateFrame("Frame", nil, parent)
            row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
            row:SetPoint("RIGHT", parent, "RIGHT", -PADR, 0)
            row:SetHeight(24)

            local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            check:SetSize(20, 20)
            check:SetPoint("LEFT", row, "LEFT", 0, 0)
            check:SetChecked(r.enabled ~= false)
            check:SetScript("OnClick", function(self)
                r.enabled = self:GetChecked() and true or false
                ns.RefreshRuntime()
            end)

            local del = ns.Button(row, "Delete", 56, 22, function()
                local writeSet = ns.CustomRemindersTable(false, encounterID)
                if writeSet then writeSet[uid] = nil end
                ns.RefreshRuntime()
                Refresh()
            end)
            del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            local edit = ns.Button(row, "Edit", 46, 22, function() Edit(uid) end)
            edit:SetPoint("RIGHT", del, "LEFT", -4, 0)

            local test = ns.Button(row, "Test", 44, 22, function()
                if r.defensive then
                    ns.TestFireAbility(encounterID, r.trigger.spellID, r)
                else
                    ns.PreviewCustomReminder(r)
                end
            end)
            test:SetPoint("RIGHT", edit, "LEFT", -4, 0)

            local delay = r.trigger.delay
            local lbl = ns.Font(row, 11, nil, ns.THEME.fg)
            lbl:SetPoint("LEFT", check, "RIGHT", 4, 0)
            lbl:SetPoint("RIGHT", test, "LEFT", -8, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetText((r.name or "Reminder") .. "  |cff9a9ea6("
                .. ((TRIGGER_CHOICES[r.trigger.type] or r.trigger.type)
                    .. (delay and (" +" .. tostring(delay) .. "s") or ""))
                .. ")|r")
            y = y - 26
        end
    end
    y = y - 6

    local add = ns.Button(parent, "+ Add Reminder", 230, 26,
        function() Edit(nil) end)
    add:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    return y - 34
end

-- Enable/Preset header (RenderBossHeader), then
-- every ability the Dungeon Journal lists for that boss -- journal icon, description
-- and role flags (Tank/Dps/Healer) included, all data ns.ScrapeBosses already collects
-- (boss.abilities).
local function RenderInstanceDetail(parent, y, W, EUI, inst, specID)
    local boss = inst.bosses[selectedBossIdx[inst.id] or 1]

    if not boss then
        local hint = ns.Font(parent, 12, nil, ns.THEME.muted)
        hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
        hint:SetText("This instance has no bosses in the journal yet.")
        return y - 20
    end

    -- One row carries the whole boss selection state: the picker on the left (with the
    -- boss-wide reminders cog chained inline), Enable This Boss on the right. The picker
    -- is a real dropdown slot keyed by boss index.
    local db = ns.DB()
    local bossOn = not (db.bossOff and db.bossOff[tostring(boss.encounterID)])
    local bossValues, bossOrder = {}, {}
    for b = 1, #inst.bosses do
        bossValues[b] = inst.bosses[b].name
        bossOrder[b] = b
    end
    local _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Boss", width = 220,
          values = bossValues, order = bossOrder,
          tooltip = "Which of this instance's bosses the options below apply to.",
          getValue = function() return selectedBossIdx[inst.id] or 1 end,
          setValue = function(v)
              selectedBossIdx[inst.id] = v
              EUI:RefreshPage(true)
          end },
        { type = "toggle", text = "Enable This Boss",
          tooltip = "Off means this boss makes no alerts at all -- no defensives, no "
          .. "reminders, nothing -- and its options below disappear until it is back on.",
          getValue = function() return bossOn end,
          setValue = function(v)
              if type(db.bossOff) ~= "table" then db.bossOff = {} end
              db.bossOff[tostring(boss.encounterID)] = (not v) or nil
              if next(db.bossOff) == nil then db.bossOff = nil end
              ns.RefreshRuntime()
              EUI:RefreshPage(true)
          end }
    ); y = y - h
    if not bossOn then return y end

    y = RenderBossHeader(parent, y, W, EUI, boss.encounterID, specID)

    y = y - 10
    -- The shipped-data curated list (extracted from GetOptions with a script) was tried
    -- and dropped in 0824t for systematically missing abilities; re-auditing its misses
    -- against the module source showed the extractor's parsing was at fault ({id, flag}
    -- table entries), plus abilities BigWigs does not track at all -- which the engine
    -- can never fire anyway. Reading the installed modules at runtime has neither
    -- problem, so this listing is exact by construction.
    local abilities = BigWigsAbilities(boss.encounterID, boss.abilities, inst.mapID) or boss.abilities
    if not (abilities and #abilities > 0) then
        local hint = ns.Font(parent, 12, nil, ns.THEME.muted)
        hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
        hint:SetText("No abilities listed in the journal for this boss.")
        return RenderBossMessageSection(parent, y - 26, EUI, boss.encounterID)
    end

    -- Only what the player has actually added. A boss starts blank: the journal lists
    -- everything a fight does, most of which is not a tank hit, and a page of rows that
    -- are all off by default reads as broken rather than as a choice.
    local added = {}
    for i = 1, #abilities do
        local a = abilities[i]
        if a.spellID and ns.AbilityAdded(boss.encounterID, a.spellID) then
            added[#added + 1] = a
        end
    end

    local addBtn = ns.Button(parent, "+ Add Ability", 130, 24, function()
        ns.ShowAbilityPicker(boss.encounterID, abilities, EUI)
    end)
    addBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)

    local copyBtn = ns.Button(parent, "Copy From Spec", 130, 24, function()
        -- The set travels with it so this popup's own "every boss" tick keeps to the same
        -- side of the raid/dungeon split as the boss it was opened from.
        local set, word = ns.EncounterSetForKind(inst.isRaid)
        ns.ShowCopyBindingsPopup(boss.encounterID, boss.name, EUI, set, word)
    end)
    copyBtn:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
    ns.Tooltip(copyBtn, "Copy From Spec",
        "Brings another spec's abilities for this boss over to this one. Abilities are saved "
        .. "per spec, so a spec you have not set up yet starts empty. Anything already set up "
        .. "here is left alone.")
    y = y - 30

    if #added == 0 then
        local hint = ns.Font(parent, 12, nil, ns.THEME.muted)
        hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
        hint:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        hint:SetText("No abilities picked for this boss yet. Add Ability lists everything "
            .. "the journal has for the fight, with the known tank hits marked.")
        return RenderBossMessageSection(parent, y - 40, EUI, boss.encounterID)
    end

    local lastStage
    for i = 1, #added do
        local a = added[i]
        if a.stage and a.stage ~= lastStage then
            lastStage = a.stage
            local hdr = ns.Font(parent, 11, nil, ns.THEME.muted)
            hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y - 6)
            hdr:SetText(a.stage)
            y = y - 24
        end
        y = RenderAbilityRow(parent, y, boss.encounterID, a, specID, EUI)
    end

    -- Custom Reminders and Raid/Dungeon Reminders for this boss used to render inline
    -- here; both moved to the Custom Reminders tab, which pairs an instance and boss
    -- picker with the same lists, so picking a boss once covers everything about it.

    return RenderBossMessageSection(parent, y - 6, EUI, boss.encounterID)
end

-- Dungeon Bosses / Raid Bosses tab: a pure navigation list on the left -- one row per
-- instance, click to select, no per-row toggle here anymore (the old bulk on/off per
-- instance is still reachable; it lives on the selected boss's own Enable This Boss row,
-- same as it always did for a single boss) -- and the selected instance's detail on the
-- right.
function ns.ConfirmRemoveAbility(encounterID, ability, callerEUI)
    local EUI = callerEUI or ns.UI
    local dimmer, panel = ns.MakeModal(400, 190, "abilityRemoveConfirm")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText("Remove Ability")

    local body = ns.Font(panel, 12, nil, ns.THEME.fg)
    body:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -48)
    body:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    body:SetJustifyH("LEFT")
    body:SetWordWrap(true)
    body:SetText(("Remove |cff0091ed%s|r from this boss?"):format(ability.title or "this ability"))

    local warn = ns.Font(panel, 11, nil, ns.THEME.muted)
    warn:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -84)
    warn:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    warn:SetJustifyH("LEFT")
    warn:SetWordWrap(true)
    warn:SetText("Its cooldown preset and warning time go with it. Adding it back later "
        .. "starts that ability fresh.")

    local remove = ns.Button(panel, "Remove", 110, 26, function()
        -- EnsureBinding first: a binding saved under this ability's journal alias reads
        -- back fine but would survive a delete keyed on the current id. Ensuring migrates
        -- the alias onto that id, so the nil below actually removes it.
        ns.EnsureBinding(encounterID, ability.spellID)
        local set = ns.AbilityBindingsTable(false, encounterID)
        if set then set[ability.spellID] = nil end
        ns.RefreshRuntime()
        dimmer:Hide()
        if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
    end)
    remove:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -6, 16)
    remove.label:SetTextColor(1, 0.38, 0.38, 1)

    local cancel = ns.Button(panel, "Cancel", 110, 26, function() dimmer:Hide() end)
    cancel:SetPoint("BOTTOMLEFT", panel, "BOTTOM", 6, 16)

    dimmer:Show()
    return dimmer
end

function ns.BuildBossListPage(parent, y, isRaid)
    local EUI = ns.UI
    local W   = EUI.Widgets
    local _, h
    local specID, isTank = ns.CurrentSpec()

    -- W:SectionHeader is a fixed widget -- left-aligned, one set colour, a 40px band with
    -- the label sitting near its bottom -- no centering or colour override exists on it.
    -- Hand-built here instead: centered, Naowh's gold, and a fraction of that height, which
    -- is most of what was leaving a gap between the tab strip and the content below.
    local pageHead = ns.Font(parent, 14, nil, ns.THEME.accent)
    pageHead:SetPoint("TOP", parent, "TOP", 0, y)
    pageHead:SetJustifyH("CENTER")
    pageHead:SetText(isRaid and "Raid Bosses" or "Dungeon Bosses")
    y = y - 22

    -- Raid-only on purpose. The gate asks whether the OTHER tank has the boss, and that
    -- question only exists with two of them -- a five-man has one tank holding every boss
    -- unit, so the check always answers yes there and changes nothing.
    --
    -- No longer a manual toggle: it used to sit here as a global switch that a respec could
    -- leave mismatched (on for a spec that no longer tanks), silently killing every callout
    -- with nothing but /nutank status to say why. It now just follows the spec's real role.
    if isRaid then
        local note = ns.Font(parent, 11, nil, ns.THEME.accentSoft)
        note:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD, y)
        note:SetPoint("RIGHT", parent, "RIGHT", -EUI.CONTENT_PAD, 0)
        note:SetJustifyH("LEFT")
        note:SetWordWrap(true)
        note:SetText(isTank
            and "Only While I Have the Boss: on. Stays quiet when the boss is on the "
                .. "other tank."
            or "Only While I Have the Boss: off. This spec does not tank, so calls fire "
                .. "regardless of aggro.")
        y = y - 30
    end

    -- Here rather than on Setup: it only reaches reminders authored from this page, and
    -- trash asks for the same thing separately on its own. Shown on both boss tabs, which
    -- are this same page built twice, and driving the one account-wide switch.
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Show Target on Boss Casts",
          tooltip = "When a boss cast you have a Boss Cast Starts reminder for names a "
          .. "player, puts that player's name on the alert in their class colour. Only "
          .. "while the cast is going out, since that is the only moment the game will say "
          .. "who is being targeted, and only for the abilities that name anybody at all.",
          getValue = function() return ns.DB().castTargetBoss == true end,
          setValue = function(v)
              ns.DB().castTargetBoss = v or nil
              -- The cast watch arms from this switch, and nothing else here would rebuild
              -- it until the next pull, so ticking it mid-fight would do nothing until
              -- then.
              if ns.RefreshCastWatch then ns.RefreshCastWatch() end
          end }
    ); y = y - h

    -- The same copy the per-boss button offers, asked once for the whole spec. Building a
    -- pack means repeating that copy on every boss in turn otherwise, and it is the single
    -- biggest cost in setting a spec up. Only shown when another spec has something to take.
    local data = ns.ScrapeBosses(false)
    if not data or #data.instances == 0 then
        local why = (scrapeFailed == "busy")
            and "Close the Dungeon Journal and reopen this page."
            or "Nothing found yet. Open the Adventure Guide once, then use Refresh below."
        _, h = W:DualRow(parent, y,
            { type = "label", text = why },
            { type = "label", text = "Run /nutank bosses to see which step came back empty." }
        ); y = y - h
        _, h = W:Button(parent, "Refresh From the Dungeon Journal", y, function()
            ns.ScrapeBosses(true)
            EUI:RefreshPage(true)
        end)
        return y - h
    end

    local list = {}
    for i = 1, #data.instances do
        local inst = data.instances[i]
        if (inst.isRaid or false) == isRaid then list[#list + 1] = inst end
    end

    local key = isRaid and "raid" or "dungeon"
    local sel = selectedInst[key]
    -- The scraped list is rebuilt fresh on every refresh (ns.ScrapeBosses is cached, but
    -- a new table each call after a forced rescan) -- match the remembered selection back
    -- up by id rather than by table identity, or picking an instance would un-pick itself
    -- the moment anything else on the page forced a refresh.
    if sel then
        local found
        for i = 1, #list do if list[i].id == sel.id then found = list[i]; break end end
        sel = found
        selectedInst[key] = found
    end

    -- Placed after the instance list because it needs it: the copy is confined to the bosses
    -- THIS page lists, so pressing it on Raid Bosses cannot quietly drag every dungeon across
    -- with it. Only shown when another spec has something inside that set to give.
    local encSet, scopeWord = ns.EncounterSetForKind(isRaid)

    -- An empty page because this spec has nothing looks exactly like an empty page because
    -- the addon lost everything, and the second reading is the one people reach for -- it
    -- cost an evening on a profile that had imported perfectly, where the work was simply
    -- filed under specs the character was not playing. Say which it is.
    local others = (specID and specID ~= 0 and ns.SpecsWithBindings)
        and ns.SpecsWithBindings(nil, encSet) or {}
    if specID and specID ~= 0 and ns.OwnBindingCount
        and ns.OwnBindingCount(encSet) == 0 and #others > 0 then
        local total = 0
        for i = 1, #others do total = total + (others[i].total or 0) end
        local note = ns.Font(parent, 11, nil, ns.THEME.accentSoft)
        note:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD + 20, y)
        note:SetPoint("RIGHT", parent, "RIGHT", -EUI.CONTENT_PAD, 0)
        note:SetJustifyH("LEFT")
        note:SetWordWrap(true)
        note:SetText(("This profile has %d %s set up, but none of them on %s -- abilities are "
            .. "saved per spec. Copy them across below, or switch to a spec that has them.")
            :format(total, total == 1 and "ability" or "abilities",
                ns.SpecName(specID) or "this spec"))
        y = y - 30
    end

    if specID and specID ~= 0 and #others > 0 then
        -- Built directly rather than through W:Button: that helper hardcodes a 200px button
        -- and this label overran it, drawing outside its own border. The width follows the
        -- text instead, with the explanation in a caption beside it.
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(34)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD, y)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -EUI.CONTENT_PAD, y)

        local label = isRaid and "Copy All Raids From a Spec" or "Copy All Dungeons From a Spec"
        local btn = ns.Button(row, label, 220, 26, function()
            ns.ShowCopyBindingsPopup(nil, nil, EUI, encSet, scopeWord)
        end)
        btn:SetPoint("LEFT", row, "LEFT", 20, 0)
        ns.Tooltip(btn, label, ("Brings another spec's abilities across for every %s at once, "
            .. "instead of repeating the per-boss copy on each in turn. %s are left to their "
            .. "own page, and anything this spec already has is left alone."):format(
            scopeWord:lower(), isRaid and "Dungeons" or "Raids"))

        local cap = ns.Font(row, 11, nil, ns.THEME.muted)
        cap:SetPoint("LEFT", btn, "RIGHT", 12, 0)
        cap:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        cap:SetJustifyH("LEFT")
        cap:SetText(("Sets a new spec up in one press. %s only, nothing already here is "
            .. "replaced."):format(isRaid and "Raids" or "Dungeons"))

        y = y - 40
    end

    local LEFT_W = 190
    local topY = y

    -- The picker's own label, above the pool it picks from -- used to be a hint on the
    -- right that only showed up once nothing was picked yet; moved here so it reads as
    -- the list's heading instead of an empty-state message.
    local leftHead = ns.Font(parent, 12, nil, ns.THEME.muted)
    leftHead:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, topY)
    leftHead:SetJustifyH("LEFT")
    leftHead:SetText(isRaid and "Select a Raid" or "Select a Dungeon")
    local listTop = topY - 18

    local leftPane = CreateFrame("Frame", nil, parent)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, listTop)
    leftPane:SetSize(LEFT_W, math.max(1, #list * 26))

    for i = 1, #list do
        local inst = list[i]
        local row = CreateFrame("Button", nil, leftPane)
        row:SetSize(LEFT_W, 26)
        row:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 0, -(i - 1) * 26)

        local isSel = (sel == inst)
        local bg = ns.Solid(row, "BACKGROUND", ns.THEME.accent, isSel and 0.16 or 0)
        bg:SetAllPoints()

        local lbl = ns.Font(row, 12, nil, isSel and ns.THEME.fg or ns.THEME.muted)
        lbl:SetPoint("LEFT", row, "LEFT", 6, 0)
        lbl:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(inst.name)

        row:SetScript("OnClick", function()
            selectedInst[key] = inst
            EUI:RefreshPage(true)
        end)
    end

    -- Right edge inset by CONTENT_PAD, same as RenderPresetListEditor's own right column
    -- above -- without it, everything anchored to this pane's own RIGHT (the ability
    -- rows' cog button in particular) sits under the scroll frame's scrollbar, both
    -- visually clipped and unclickable since the scrollbar's hit region wins the click.
    local rightPane = CreateFrame("Frame", nil, parent)
    rightPane:SetPoint("TOPLEFT", parent, "TOPLEFT", LEFT_W + 16, topY)
    rightPane:SetPoint("RIGHT", parent, "RIGHT", -(EUI.CONTENT_PAD or 16), 0)

    local rightBottom = topY
    if sel then
        rightBottom = RenderInstanceDetail(rightPane, 0, W, EUI, sel, specID)
    else
        rightBottom = 0
    end

    local leftBottom = listTop - (#list * 26)
    return math.min(leftBottom, topY + rightBottom)
end

-- Choose which of a boss's abilities get reminders; the boss page lists exactly these.
-- The curated tank list marks rows here instead of pre-selecting them, so it still says
-- which hits are the real tank busters without choosing for the player.
--
-- Two-way: the tick is whether the boss has the ability, so unticking one drops it along
-- with the preset and warning time saved on it -- the same thing the boss page's own row
-- tick does.
-- Copy another spec's bindings for this boss into the current one. Per-spec storage means
-- every alt starts empty; this is how a spec gets a working list without rebuilding it by
-- hand. Additive only -- anything already set up here survives untouched.
-- encounterID nil means the whole spec, which is what the Dungeon and Raid list pages ask
-- for: one press instead of the same copy repeated on every boss in turn. The per-boss
-- entry point still passes an encounter and keeps its own checkbox.
-- Every encounter the journal lists on one side of the raid/dungeon split, as a set of
-- encounter keys. Both copy entry points confine themselves with it, so neither can reach
-- across that split into content the page it was opened from never mentions.
function ns.EncounterSetForKind(isRaid)
    local data = ns.ScrapeBosses(false)
    local set = {}
    if not data then return set, isRaid and "Raid Boss" or "Dungeon Boss" end
    for i = 1, #data.instances do
        local inst = data.instances[i]
        if (inst.isRaid or false) == (isRaid and true or false) then
            for j = 1, #inst.bosses do
                local eid = inst.bosses[j].encounterID
                if eid then set[tostring(eid)] = true end
            end
        end
    end
    return set, isRaid and "Raid Boss" or "Dungeon Boss"
end

function ns.ShowCopyBindingsPopup(encounterID, bossName, callerEUI, encSet, scopeWord)
    local EUI = callerEUI or ns.UI
    local specs = ns.SpecsWithBindings(encounterID, encSet)
    local allMode = (encounterID == nil)

    local dimmer, panel = ns.MakeModal(420, 150 + math.max(1, #specs) * 30, "copyBindings")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText(allMode
        and ("Copy Every %s From"):format(scopeWord or "Boss")
        or "Copy Abilities From")

    local y = -46
    if #specs == 0 then
        local none = ns.Font(panel, 12, nil, ns.THEME.muted)
        none:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
        none:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
        none:SetJustifyH("LEFT")
        none:SetWordWrap(true)
        none:SetText("No other spec has any abilities saved yet.")
    else
        local hint = ns.Font(panel, 11, nil, ns.THEME.muted)
        hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
        hint:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        hint:SetText(allMode
            and ("Every %s that spec has set up is copied, and nothing outside them. "
                .. "Anything this spec already has is left alone."):format(
                (scopeWord or "boss"):lower())
            or "Anything this spec already has is left alone.")
        y = y - (allMode and 38 or 26)

        -- Nothing to choose when the whole spec is already the subject, and a ticked box
        -- that cannot be unticked reads as broken.
        local allBosses = allMode
        if not allMode then
            local chk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            chk:SetSize(20, 20)
            chk:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
            chk:SetScript("OnClick", function(self) allBosses = self:GetChecked() and true or false end)
            local chkLbl = ns.Font(panel, 11, nil, ns.THEME.fg)
            chkLbl:SetPoint("LEFT", chk, "RIGHT", 4, 0)
            -- Names the split it keeps to. "Every boss" read as everything the addon knows,
            -- which is what it used to do and what it no longer does.
            chkLbl:SetText(("Every %s, not just %s"):format(
                (scopeWord or "boss"):lower(), bossName or "this one"))
            y = y - 28
        end

        for i = 1, #specs do
            local s = specs[i]
            -- The count is what tells the finished spec from one barely started, which is
            -- the whole question when copying a whole spec across.
            local label = allMode and ("%s  (%d)"):format(s.name, s.total) or s.name
            local btn = ns.Button(panel, label, 200, 24, function()
                local copied, skipped, reminders = ns.CopyBindingsFromSpec(
                    s.key, (not allBosses) and encounterID or nil, encSet)
                ns.Print(("copied |cff0091ed%d|r abilities%s from %s%s.")
                    :format(copied,
                        reminders > 0 and (" and |cff0091ed" .. reminders .. "|r message reminders") or "",
                        s.name,
                        skipped > 0 and (", left " .. skipped .. " already here alone") or ""))
                ns.RefreshRuntime()
                dimmer:Hide()
                if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
            end)
            btn:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
            local count = ns.Font(panel, 11, nil, ns.THEME.muted)
            count:SetPoint("LEFT", btn, "RIGHT", 10, 0)
            count:SetText(("%d here, %d total"):format(s.here, s.total))
            y = y - 30
        end
    end

    ns.Button(panel, "Cancel", 90, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOM", panel, "BOTTOM", 0, 16)
    dimmer:Show()
end

function ns.ShowAbilityPicker(encounterID, abilities, callerEUI)
    local EUI = callerEUI or ns.UI
    local PANEL_W = 460
    local dimmer, panel = ns.MakeModal(PANEL_W, 560, "abilityPicker")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText("Add Abilities")

    local hint = ns.Font(panel, 11, nil, ns.THEME.muted)
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -42)
    hint:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Tick the abilities you want reminders for. Marked ones are what the "
        .. "addon knows to be tank hits on this boss. Unticking one drops it from the "
        .. "boss, along with any warning time or reminder set up on it.")

    -- Scrolled rather than capped: a journal boss can list well past a screenful, and this
    -- is the only place an ability can be switched on, so a row that does not fit still has
    -- to be reachable.
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -82)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -40, 54)
    local content = CreateFrame("Frame", nil, scroll)
    -- Sized off the panel, not scroll:GetWidth(): the scroll frame is anchor-derived and
    -- still reads 0 wide until a layout pass has run.
    content:SetSize(PANEL_W - 62, 1)
    scroll:SetScrollChild(content)

    local ok, err = pcall(function()
        local y, shown = 0, 0
        for i = 1, #abilities do
            local a = abilities[i]
            if a.spellID then
                shown = shown + 1
                local row = CreateFrame("Frame", nil, content)
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
                row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                row:SetHeight(26)

                -- Two-way: the box IS whether this boss has the ability, so unticking
                -- drops it. Reading the box's own state rather than assuming the click
                -- means "add" -- an already-added row used to be disabled, which left one
                -- ticked in this same session (built before it was added) live but
                -- one-directional, so unticking it silently re-added and the ability
                -- stayed on the boss.
                local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                check:SetSize(22, 22)
                check:SetPoint("LEFT", row, "LEFT", 0, 0)
                check:SetChecked(ns.AbilityAdded(encounterID, a.spellID))
                check:SetScript("OnClick", function(self)
                    if self:GetChecked() then
                        ns.EnsureBinding(encounterID, a.spellID).enabled = true
                    else
                        ns.RemoveBinding(encounterID, a.spellID)
                    end
                    ns.RefreshRuntime()
                    if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
                end)

                local icon = row:CreateTexture(nil, "ARTWORK")
                icon:SetSize(20, 20)
                icon:SetPoint("LEFT", check, "RIGHT", 4, 0)
                if a.icon then icon:SetTexture(a.icon) end
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local curated = ns.TANK_ABILITIES and ns.TANK_ABILITIES[a.spellID]
                -- Same role colouring the already-added rows below use, off the same
                -- journal extras -- this list was reading a.name, a field these ability
                -- tables have never had (the journal walk and the BigWigs merge both
                -- write .title), so every row fell through to the bare spell id.
                local roleTag
                if a.extras then
                    local roles = {}
                    for label in a.extras:gmatch("[^,]+") do
                        label = label:match("^%s*(.-)%s*$")
                        if ROLE_COLOR[label] then
                            roles[#roles + 1] = ROLE_COLOR[label] .. label .. "|r"
                        end
                    end
                    if #roles > 0 then roleTag = table.concat(roles, " ") end
                end
                local lbl = ns.Font(row, 11, nil, ns.THEME.fg)
                lbl:SetPoint("LEFT", icon, "RIGHT", 6, 0)
                lbl:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                lbl:SetJustifyH("LEFT")
                lbl:SetWordWrap(false)
                lbl:SetText((a.title or ("Spell " .. a.spellID))
                    .. (roleTag and ("  " .. roleTag) or "")
                    .. (curated and "  |cff0091ed[tank hit]|r" or ""))

                y = y - 28
            end
        end
        if shown == 0 then
            local none = ns.Font(content, 11, nil, ns.THEME.muted)
            none:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
            none:SetText("Nothing in the journal for this boss carries a spell id.")
        end
        content:SetHeight(math.max(1, math.abs(y)))
    end)
    if not ok then
        local errText = ns.Font(content, 11, nil, { r = 1, g = 0.35, b = 0.35 })
        errText:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        errText:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        errText:SetJustifyH("LEFT")
        errText:SetWordWrap(true)
        errText:SetText("Failed to build this: " .. tostring(err))
        ns.Print("|cffff6060ability add picker|r: " .. tostring(err))
    end

    ns.Button(panel, "Close", 100, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOM", panel, "BOTTOM", 0, 16)
    dimmer:Show()
    return dimmer
end

-------------------------------------------------------------------------------
--  Raid/Dungeon Reminders and Custom Reminders for one boss, behind the cog next to
--  that boss's picker (RenderInstanceDetail) -- a different shape than the per-ability
--  cog (ShowAbilityReminderPicker), which configures one ability's own tank-buster
--  callout. Both used to be full top-level tabs, each with its own boss dropdown
--  duplicating the one already on Dungeon/Raid Bosses; folded in here so a boss is only
--  ever picked once. Engine for raid reminders (data, targeting, BigWigs scheduling,
--  the four displays) lives in NaowhUI_SmartReminders_RaidReminders.lua; this is the
--  authoring UI on top of it, kept here since it needs the same tab/mechanic-picker/
--  HoverTip scaffolding ShowCustomReminderEditor/ShowRaidReminderEditor already built.
--  Ability-bound reminders (r.abilitySpellID set) are excluded below -- those live on
--  their own ability's cog instead (ShowAbilityReminderPicker's Custom Reminder tab).
-------------------------------------------------------------------------------
-- Opened from the cog next to a boss's picker (RenderInstanceDetail). isRaid decides
-- which of RaidRemindersTable's two kinds this boss's encounterID belongs to (the same
-- split ns.BuildBossListPage's left column already keys instances on), not something
-- picked here.
-- Which difficulty's recording the observed section is showing, per encounter. Page-local
-- rather than saved: it is a viewing choice, not a setting.
local observedDiffPick = {}

-- One recorded ability: icon, name, then each observed occurrence as a clickable time.
-- Clicking opens the reminder editor already pointed at that moment.
local function ObservedRow(content, sid, list, encounterID, isRaid, EUI, onChanged, y)
    local row = CreateFrame("Frame", nil, content)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    row:SetHeight(24)

    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    icon:SetTexture((info and info.iconID) or 134400)

    local lbl = ns.Font(row, 11, nil, ns.THEME.fg)
    lbl:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    lbl:SetWidth(150)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    lbl:SetText((info and info.name) or ("Spell " .. sid))

    -- How many time chips actually fit. This row renders on two very different surfaces --
    -- the 480px cog modal and the much wider options tab -- and a boss with a dozen
    -- recorded occurrences would run straight off the narrow one.
    local avail = content:GetWidth()
    if avail <= 0 then avail = 440 end
    local fits = math.max(1, math.floor((avail - 190) / 70))
    local shownCount = math.min(#list, fits)

    local anchor = lbl
    for i = 1, shownCount do
        local slot = list[i]
        if slot and slot.t then
            local phased = slot.stage and slot.stage > 1 and slot.ts
            local shown = phased and slot.ts or slot.t
            local label = ("%d:%02d"):format(math.floor(shown / 60), math.floor(shown % 60))
            if phased then label = "P" .. slot.stage .. " " .. label end
            local chip = ns.Button(row, label, phased and 62 or 46, 20, function()
                -- A phase-anchored observation seeds a phase trigger, since a pull-relative
                -- time for a later phase is only true for a pull of the same speed.
                local seed
                if phased then
                    seed = { trigger = { type = "stage", stage = slot.stage,
                        delay = math.floor(slot.ts * 10 + 0.5) / 10 },
                        name = (info and info.name) or nil }
                else
                    seed = { trigger = { type = "pull",
                        delay = math.floor(slot.t * 10 + 0.5) / 10 },
                        name = (info and info.name) or nil }
                end
                local d = ns.ShowRaidReminderEditor(encounterID, nil, EUI, isRaid, nil, seed)
                if d then d:HookScript("OnHide", onChanged) end
            end)
            chip:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
            local spread = (slot.hi and slot.lo) and (slot.hi - slot.lo) or 0
            local spreadNote = (spread > 3)
                and ("Varies by %.0fs across pulls -- treat it as approximate."):format(spread)
                or "Consistent across pulls."
            ns.Tooltip(chip, label,
                ("Occurrence %d, averaged over %d pull(s). %s Click to build a reminder "
                .. "for this moment."):format(i, slot.n or 1, spreadNote))
            anchor = chip
        end
    end
    if #list > shownCount then
        local more = ns.Font(row, 10, nil, ns.THEME.muted)
        more:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
        more:SetText(("+%d more"):format(#list - shownCount))
    end
    return row
end

-- The boss-scoped reminder lists -- RAID/DUNGEON REMINDERS, ABILITY REMINDERS, the
-- anchors button and both Add buttons -- shared verbatim by the cog picker modal and
-- the Custom Reminders tab, so the two surfaces cannot drift. Renders into `content`
-- starting at startY (negative running offset) and returns the final y. opts.onChanged
-- runs after any edit/delete/add closes, and nested editors hook it onto their OnHide.
function ns.BuildBossReminderSections(content, encounterID, isRaid, startY, opts)
    local EUI = (opts and opts.EUI) or ns.UI
    local onChanged = (opts and opts.onChanged) or function() end

    local function EditRaidReminder(uid)
        local nestedDimmer = ns.ShowRaidReminderEditor(encounterID, uid, EUI, isRaid)
        if nestedDimmer then nestedDimmer:HookScript("OnHide", onChanged) end
    end
    local function EditCustomReminder(uid)
        local nestedDimmer = ns.ShowCustomReminderEditor(encounterID, uid, EUI)
        if nestedDimmer then nestedDimmer:HookScript("OnHide", onChanged) end
    end

    -- The boss-less bucket the Custom Reminders tab's "Any Combat" entry writes to. Only
    -- the custom list applies there: observed timings come from encounter events, and a
    -- raid reminder reads currentEncounter, so neither has anything to say without a boss.
    local anyCombat = (encounterID == 0)

    local y = startY or 0

    -- Hand-rolled rows throughout, not W:SectionHeader/W:DualRow -- those are built
    -- for a full-width options page (row backgrounds, hover-tags, a half-column each
    -- slot always reserves) and look wrong crammed into a 480px floating popup, the
    -- same reasoning ShowAbilityReminderPicker's own compact Label/Box helpers state.
    local function Header(text)
        local lbl = ns.Font(content, 12, nil, ns.THEME.accent)
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        lbl:SetText(text)
        y = y - 20
    end

    local function NoneRow()
        local lbl = ns.Font(content, 11, nil, ns.THEME.muted)
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        lbl:SetText(anyCombat and "None yet." or "None yet for this boss.")
        y = y - 20
    end

    -- One reminder: an enabled checkbox, name + description, Edit/Delete on the right.
    local function ReminderRow(name, desc, getEnabled, setEnabled, editFn, deleteFn)
        local row = CreateFrame("Frame", nil, content)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        row:SetHeight(24)

        local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        check:SetSize(20, 20)
        check:SetPoint("LEFT", row, "LEFT", 0, 0)
        check:SetChecked(getEnabled())
        check:SetScript("OnClick", function(self)
            setEnabled(self:GetChecked() and true or false)
        end)

        local delBtn = ns.Button(row, "Delete", 56, 22, deleteFn)
        delBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        local editBtn = ns.Button(row, "Edit", 46, 22, editFn)
        editBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)

        local lbl = ns.Font(row, 11, nil, ns.THEME.fg)
        lbl:SetPoint("LEFT", check, "RIGHT", 4, 0)
        lbl:SetPoint("RIGHT", editBtn, "LEFT", -8, 0)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(name .. "  |cff9a9ea6(" .. desc .. ")|r")

        y = y - 26
    end

    if not anyCombat then
        -- What this boss actually did, from the player's own pulls. Rendered above the
        -- reminder lists because it is the raw material they are built from: pick a time here
        -- and the editor opens already pointed at it.
        local diffs = ns.ObservedDifficulties and ns.ObservedDifficulties(encounterID) or {}
        Header("OBSERVED TIMINGS")
        if #diffs > 0 then
            local pick = observedDiffPick[encounterID]
            local chosen
            for _, d in ipairs(diffs) do
                if d.key == pick then chosen = d break end
            end
            chosen = chosen or diffs[1]
            local block = ns.ObservedFor(encounterID, tonumber(chosen.key))

            if #diffs > 1 then
                -- Only when there is a choice to make: the same boss on two difficulties casts
                -- on genuinely different schedules and the two must never be read as one.
                local dvalues, dorder = {}, {}
                for _, d in ipairs(diffs) do
                    local dn = GetDifficultyInfo and GetDifficultyInfo(tonumber(d.key))
                    dvalues[d.key] = ("%s (%d pulls)"):format(tostring(dn or d.key), d.pulls or 0)
                    dorder[#dorder + 1] = d.key
                end
                local ddBtn = EUI.BuildDropdownControl(content, 220, content:GetFrameLevel() + 4,
                    dvalues, dorder,
                    function() return chosen.key end,
                    function(v) observedDiffPick[encounterID] = v; onChanged() end)
                ddBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
                y = y - 30
            end

            local rows = {}
            for sid, list in pairs(block and block.casts or {}) do
                rows[#rows + 1] = { sid = sid, list = list }
            end
            table.sort(rows, function(a, b)
                local at = a.list[1] and a.list[1].t or 0
                local bt = b.list[1] and b.list[1].t or 0
                return at < bt
            end)

            if #rows == 0 then
                NoneRow()
            else
                for i = 1, #rows do
                    ObservedRow(content, rows[i].sid, rows[i].list, encounterID, isRaid, EUI,
                        onChanged, y)
                    y = y - 26
                end
            end

            local cover = ns.Font(content, 10, nil, ns.THEME.muted)
            cover:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            cover:SetText(("from %d pull(s), longest %d:%02d -- click a time to build a "
                .. "reminder from it"):format(block and block.pulls or 0,
                math.floor((block and block.longest or 0) / 60), (block and block.longest or 0) % 60))
            y = y - 22
        else
            -- Says which of the two reasons it is. They need different actions from the
            -- player, and neither is guessable from an empty list.
            local src = ns.BossSource and ns.BossSource() or "timeline"
            local why = ns.Font(content, 11, nil, ns.THEME.muted)
            why:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            why:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            why:SetJustifyH("LEFT")
            why:SetWordWrap(true)
            if src ~= "bigwigs" and src ~= "dbm" then
                -- Boss Addon only lands on Timeline now by an explicit pick or with no boss
                -- mod installed at all, and those need different things from the player.
                if not (_G.BigWigsLoader or _G.DBM) then
                    why:SetText("Recording rides BigWigs or DBM broadcasts and neither is "
                        .. "installed. With one of them running, every boss you pull records "
                        .. "itself here -- there is nothing to switch on.")
                else
                    why:SetText("Boss Addon is set to Blizzard Timeline, which keeps ability "
                        .. "identity secret, so there is nothing to record from. Switch it to "
                        .. "BigWigs or DBM on the Smart Reminders > Setup tab.")
                end
            else
                why:SetText(("Nothing recorded for this boss yet. Pull it with %s running and "
                    .. "its timings appear here once the fight ends. It has to be a real boss "
                    .. "encounter -- trash fires no encounter events, so it records nothing.")
                    :format(src == "dbm" and "DBM" or "BigWigs"))
            end
            why:SetHeight(math.max(16, why:GetStringHeight() + 4))
            y = y - why:GetHeight() - 10
        end

        Header((isRaid and "RAID" or "DUNGEON") .. " REMINDERS")
        local rrSet = ns.RaidRemindersTable and ns.RaidRemindersTable(false, encounterID)
        local rrList = {}
        if rrSet then
            for uid, r in pairs(rrSet) do
                if not r.abilitySpellID then rrList[#rrList + 1] = { uid = uid, r = r } end
            end
            table.sort(rrList, function(a, b) return (a.r.name or "") < (b.r.name or "") end)
        end
        if #rrList == 0 then
            NoneRow()
        else
            for i = 1, #rrList do
                local uid, r = rrList[i].uid, rrList[i].r
                local rowName = r.name or "Reminder"
                local desc = RaidReminderTargetDesc(r.target)
                local trig = r.trigger
                if trig and trig.type == "pull" and trig.delay then
                    desc = ("+%gs  %s"):format(trig.delay, desc)
                elseif trig and trig.type == "stage" and trig.delay then
                    desc = ("P%d +%gs  %s"):format(trig.stage or 0, trig.delay, desc)
                end
                ReminderRow(rowName, desc,
                    function() return r.enabled ~= false end,
                    function(v) r.enabled = v end,
                    function() EditRaidReminder(uid) end,
                    function()
                        local writeSet = ns.RaidRemindersTable(false, encounterID)
                        if writeSet then writeSet[uid] = nil end
                        onChanged()
                    end)
            end
        end
        y = y - 6

        local addRRBtn = ns.Button(content,
            isRaid and "+ Add a Raid Reminder" or "+ Add a Dungeon Reminder", 190, 26, function()
                -- A thrown error here would otherwise be indistinguishable from a dead
                -- button -- WoW hides script errors by default, so an uncaught throw looks
                -- exactly like nothing happening at all.
                local okClick, clickErr = pcall(EditRaidReminder, nil)
                if not okClick then
                    ns.Print("|cffff6060could not open the raid reminder editor|r: "
                        .. tostring(clickErr))
                end
            end)
        addRRBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        y = y - 34
    end

    -- Excludes "spell"-triggered entries -- those are the per-ability picker's own
    -- Custom Reminder mode (ShowAbilityReminderPicker), already editable from that
    -- ability's row; listing them here too would let this generic editor delete the
    -- reminder object while the ability's binding still says "custom", leaving that
    -- ability silently unable to fire either kind of callout.
    Header("ABILITY REMINDERS")
    local crSet = ns.CustomRemindersTable and ns.CustomRemindersTable(false, encounterID)
    local crList = {}
    if crSet then
        for uid, r in pairs(crSet) do
            if not (r.trigger and r.trigger.type == "spell") then
                crList[#crList + 1] = { uid = uid, r = r }
            end
        end
        table.sort(crList, function(a, b) return (a.r.name or "") < (b.r.name or "") end)
    end
    if #crList == 0 then
        NoneRow()
    else
        for i = 1, #crList do
            local uid, r = crList[i].uid, crList[i].r
            local trig = r.trigger
            local trigDesc = "?"
            if trig and trig.type == "pull" then
                trigDesc = "Pull"
            elseif trig and trig.type == "combat" then
                trigDesc = trig.delay and ("In Combat +" .. tostring(trig.delay) .. "s")
                    or "In Combat"
            elseif trig and (trig.type == "bwmsg" or trig.type == "bwtimer") then
                local info = C_Spell and C_Spell.GetSpellInfo
                    and C_Spell.GetSpellInfo(trig.spellID)
                trigDesc = (trig.type == "bwtimer" and "Timer: " or "Message: ")
                    .. ((info and info.name) or tostring(trig.spellID))
            elseif trig and trig.type == "aura" then
                local info = C_Spell and C_Spell.GetSpellInfo
                    and C_Spell.GetSpellInfo(trig.spellID)
                trigDesc = (trig.auraEvent == "removed" and "Aura Removed: " or "Aura Applied: ")
                    .. ((info and info.name) or tostring(trig.spellID))
                    .. (trig.target == "player" and " (You)" or " (Boss)")
            elseif trig and (trig.type == "caststart" or trig.type == "castend") then
                local info = C_Spell and C_Spell.GetSpellInfo
                    and C_Spell.GetSpellInfo(trig.spellID)
                trigDesc = (trig.type == "castend" and "Cast Finishes: " or "Cast Starts: ")
                    .. ((info and info.name) or tostring(trig.spellID))
            end
            ReminderRow(r.name or "Reminder", trigDesc,
                function() return r.enabled ~= false end,
                function(v) r.enabled = v; ns.RefreshRuntime() end,
                function() EditCustomReminder(uid) end,
                function()
                    local writeSet = ns.CustomRemindersTable(false, encounterID)
                    if writeSet then writeSet[uid] = nil end
                    ns.RefreshRuntime()
                    onChanged()
                end)
        end
    end
    y = y - 6

    local addCRBtn = ns.Button(content,
        anyCombat and "+ Add Reminder" or "+ Add an Ability Reminder",
        anyCombat and 230 or 190, 26, function()
            EditCustomReminder(nil)
        end)
    addCRBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
    y = y - 34

    return y
end


-- ShowCustomReminderEditor's twin: same modal size, same tab/mechanic-picker/Save
-- shape, restricted to BigWigs triggers only (no pull/aura, no DBM -- a raid reminder is
-- always tied to a real BigWigs broadcast) and carrying the two things that editor has
-- no concept of:
-- who this is for (Target) and which of the four displays shows it.
-- abilitySpellID, passed only from ShowAbilityReminderPicker's Custom Reminder tab,
-- tags a brand-new entry as bound to that ability (so it shows on the ability's own
-- cog instead of ShowBossReminderPicker's boss-wide list) and seeds the mechanic
-- picker's Spell ID field with it -- still just a starting guess, not locked, since
-- the real BigWigs key for an ability can differ from its journal spellID.
-- seed (optional): { trigger = {...}, name = "..." } -- a starting point for a brand-new
-- reminder, used by the observed-timings rows so a recorded moment opens the editor
-- already pointed at it. Ignored when editing an existing entry.
function ns.ShowRaidReminderEditor(encounterID, uid, callerEUI, isRaid, abilitySpellID, seed)
    local EUI = callerEUI or ns.UI
    local W = EUI.Widgets
    local kind = isRaid and "Raid" or "Dungeon"

    -- Taller than ShowCustomReminderEditor's 620: the Target tab now carries full
    -- role/class/subgroup checkbox grids plus spec/name text fields instead of one
    -- kind dropdown, and none of these tab bodies scroll.
    local dimmer, panel = ns.MakeModal(480, 860, "raidReminderEditor")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText((uid and "Edit " or "New ")
        .. (abilitySpellID and "Ability Reminder" or (kind .. " Reminder")))

    local set = ns.RaidRemindersTable and ns.RaidRemindersTable(false, encounterID)
    local existing = (set and uid) and set[uid] or nil
    local boundAbilitySpellID = (existing and existing.abilitySpellID) or abilitySpellID
    local trig = (existing and existing.trigger) or (seed and seed.trigger) or { type = "bwtimer" }
    -- New reminders open with Everyone unticked and the role/class grid already showing:
    -- assigning to somebody specific is the common case, and starting on Everyone hid the
    -- controls that do it. Only the editor's starting state -- a saved reminder with no
    -- target of its own still means everyone, which is what NormalizeRaidReminderTarget says.
    local target = (existing and existing.target) or { all = false }
    local display = (existing and existing.display) or { type = "text" }

    local PAD = 20

    -- Wrapped, matching ShowAbilityReminderPicker's own RebuildBody: a blank panel with
    -- no error anywhere on screen is a failure mode this codebase has already shipped
    -- once, so anything that throws here shows up as text on the panel instead of an
    -- empty modal nobody can diagnose from a screenshot alone.
    local ok, err = pcall(function()

    local function HoverTip(hit, tooltip)
        hit:SetScript("OnEnter", function(self)
            local EUIg = ns.UI
            if EUIg and EUIg.ShowWidgetTooltip then EUIg.ShowWidgetTooltip(self, tooltip) end
        end)
        hit:SetScript("OnLeave", function()
            local EUIg = ns.UI
            if EUIg and EUIg.HideWidgetTooltip then EUIg.HideWidgetTooltip() end
        end)
    end

    -------------------------------------------------------------------------
    --  Tabs -- same split ShowCustomReminderEditor uses: what fires this,
    --  and for whom (Trigger & Target), versus how it looks (Display).
    -------------------------------------------------------------------------
    local TAB_TOP = -40
    local BODY_TOP = TAB_TOP - 30

    local tabBar = CreateFrame("Frame", nil, panel)
    tabBar:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, TAB_TOP)
    -- A single-corner anchor with no width ever set left tabBar's own geometry (and
    -- everything anchored off its LEFT/RIGHT points transitively -- every tab button)
    -- unresolvable: GetLeft/GetTop came back nil for the tab buttons even fully shown
    -- with alpha 1, confirmed live via debug prints. A second anchor point gives it a
    -- real width, same as every other full-width strip in this file already does.
    tabBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, TAB_TOP)
    tabBar:SetHeight(24)

    local tabDivider = ns.Solid(panel, "ARTWORK", ns.THEME.line, 1)
    tabDivider:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, BODY_TOP + 6)
    tabDivider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, BODY_TOP + 6)
    tabDivider:SetHeight(1)

    local tabButtons, tabBodies = {}, {}

    local function SelectTab(id)
        for tid, btn in pairs(tabButtons) do
            local on = (tid == id)
            btn.marker:SetShown(on)
            local c = on and ns.THEME.fg or ns.THEME.muted
            btn.label:SetTextColor(c.r, c.g, c.b, 1)
        end
        for tid, body in pairs(tabBodies) do body:SetShown(tid == id) end
    end

    local function AddTab(id, text, anchorTo)
        local btn = CreateFrame("Button", nil, tabBar)
        btn:SetHeight(24)
        local lbl = ns.Font(btn, 12, nil, ns.THEME.muted)
        lbl:SetText(text)
        btn:SetSize(lbl:GetStringWidth() + 4, 24)
        lbl:SetPoint("CENTER")
        if anchorTo then btn:SetPoint("LEFT", anchorTo, "RIGHT", 18, 0)
        else btn:SetPoint("LEFT", tabBar, "LEFT", 0, 0) end
        local marker = ns.Solid(btn, "OVERLAY", ns.THEME.accent, 1)
        marker:SetPoint("BOTTOMLEFT", 0, -3)
        marker:SetPoint("BOTTOMRIGHT", 0, -3)
        marker:SetHeight(2)
        marker:Hide()
        btn:SetScript("OnClick", function() SelectTab(id) end)
        btn.label, btn.marker = lbl, marker
        tabButtons[id] = btn

        local body = CreateFrame("Frame", nil, panel)
        body:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, BODY_TOP)
        body:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, BODY_TOP)
        body:SetHeight(-BODY_TOP - 60)
        tabBodies[id] = body
        return btn, body
    end

    local triggerTabBtn, triggerBody = AddTab("trigger", "Trigger & Target")
    local _, displayBody = AddTab("display", "Display", triggerTabBtn)

    -------------------------------------------------------------------------
    --  Trigger & Target tab
    -------------------------------------------------------------------------
    local ty = 0
    local function TLabel(text, tooltip)
        local l = ns.Font(triggerBody, 11, nil, ns.THEME.muted)
        l:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, ty)
        l:SetText(text)
        if tooltip then
            local hit = CreateFrame("Frame", nil, triggerBody)
            hit:SetPoint("TOPLEFT", l, "TOPLEFT", -4, 4)
            hit:SetPoint("BOTTOMRIGHT", l, "BOTTOMRIGHT", 4, -4)
            HoverTip(hit, tooltip)
        end
        ty = ty - 16
    end
    local function TBox(maxLetters, numeric, rightInset)
        local box = CreateFrame("EditBox", nil, triggerBody)
        box:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, ty)
        box:SetPoint("RIGHT", triggerBody, "RIGHT", -(rightInset or PAD), 0)
        box:SetHeight(26)
        box:SetAutoFocus(false)
        box:SetMaxLetters(maxLetters or 60)
        if numeric then box:SetNumeric(true) end
        box:SetFontObject("GameFontHighlight")
        box:SetTextInsets(6, 6, 0, 0)
        ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1):SetAllPoints()
        ns.Border(box)
        ty = ty - 32
        return box
    end

    TLabel("Name")
    local nameBox = TBox(40)
    if existing then
        nameBox:SetText(existing.name or "")
    elseif seed and seed.name then
        nameBox:SetText(seed.name)
    elseif abilitySpellID then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(abilitySpellID)
        nameBox:SetText((info and info.name) or "")
    end

    -- The mechanic picker: every BigWigs/DBM key actually seen for this boss (recorded
    -- by RecordBossModKey the moment it fires live), sorted by how often it has come
    -- up -- same data source and shape ShowCustomReminderEditor's own picker uses,
    -- since it is the one place both editors need "which real ability is this."
    local MECHANIC_ROWS = 6
    local pickerRows = {}
    for i = 1, MECHANIC_ROWS do
        local row = CreateFrame("Button", nil, triggerBody)
        row:SetHeight(22)
        row:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, 0)
        row:SetPoint("RIGHT", triggerBody, "RIGHT", -PAD, 0)
        row.hl = ns.Solid(row, "BACKGROUND", ns.THEME.accent, 0.14)
        row.hl:SetAllPoints()
        row.hl:Hide()
        row:SetScript("OnEnter", function(s) s.hl:Show() end)
        row:SetScript("OnLeave", function(s) s.hl:Hide() end)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 2, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.name = ns.Font(row, 11, nil, ns.THEME.fg)
        row.name:SetPoint("LEFT", 22, 0)
        row.name:SetPoint("RIGHT", -34, 0)
        row.name:SetJustifyH("LEFT")
        row.tag = ns.Font(row, 9, nil, ns.THEME.muted)
        row.tag:SetPoint("RIGHT", -2, 0)
        pickerRows[i] = row
    end
    local pickerHint = ns.Font(triggerBody, 10, nil, ns.THEME.muted)
    pickerHint:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, ty)
    pickerHint:SetPoint("RIGHT", triggerBody, "RIGHT", -PAD, 0)
    pickerHint:SetJustifyH("LEFT")
    local PICKER_ROW_H = 22
    local PICKER_TOP = ty

    local trigTypeVal = (trig.type == "bwmsg" and "bwmsg")
        or (trig.type == "pull" and "pull") or (trig.type == "aura" and "aura")
        or (trig.type == "stage" and "stage") or "bwtimer"
    local spellIDText = (trig.spellID and tostring(trig.spellID))
        or (abilitySpellID and tostring(abilitySpellID)) or ""
    local leadTimeText = (trig.leadTime and tostring(trig.leadTime)) or "3"
    local pullDelayText = (trig.delay and tostring(trig.delay)) or "5"
    local stageNumText = (trig.stage and tostring(trig.stage)) or "2"
    -- The early-fire lead for pull/stage (bwtimer has its own leadTimeText with different
    -- semantics); blank means fire exactly at the noted time.
    local earlyLeadText = ((trig.type == "pull" or trig.type == "stage") and trig.leadTime
        and tostring(trig.leadTime)) or ""
    local auraEventVal = (trig.auraEvent == "removed") and "removed" or "applied"
    local auraTargetVal = (trig.target == "boss") and "boss" or "player"

    -- Declared here, assigned below: a picker row's OnClick (built by RebuildPicker,
    -- called from inside RebuildTriggerFields itself) has to reach the rebuild function
    -- that is still being defined at the point this local exists -- same forward-
    -- reference shape ShowCustomReminderEditor's own RebuildDynFields/dynFrame pair uses.
    local RebuildTriggerFields

    local function RebuildPicker()
        for i = 1, MECHANIC_ROWS do pickerRows[i]:Hide() end
        pickerHint:SetText("")
        local cat = ns.BossModCatalogueTable and ns.BossModCatalogueTable(false, encounterID)
        local list = {}
        if cat then
            -- BigWigs only: a raid reminder's trigger is always "BigWigs Message/Timer"
            -- now (see the Trigger Type dropdown above), so a DBM-only catalogue entry
            -- would just be a dead pick here -- the catalogue itself stays shared with
            -- ShowCustomReminderEditor, which still wants both.
            for key, entry in pairs(cat) do
                if entry.mod ~= "DBM" then list[#list + 1] = { key = key, entry = entry } end
            end
        end
        table.sort(list, function(a, b) return (a.entry.seen or 0) > (b.entry.seen or 0) end)

        if #list == 0 then
            pickerHint:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, PICKER_TOP)
            pickerHint:SetText("|cff9a9ea6Nothing recorded for this boss yet -- pull it with "
                .. "BigWigs running, or type a Spell ID below.|r")
            pickerHint:SetHeight(28)
            return 28
        end

        local shown = math.min(#list, MECHANIC_ROWS)
        for i = 1, shown do
            local row, item = pickerRows[i], list[i]
            row:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, PICKER_TOP - (i - 1) * PICKER_ROW_H)
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(item.key)
            row.icon:SetTexture((info and info.iconID) or 134400)
            row.name:SetText((info and info.name) or (item.entry.text or ("Spell " .. item.key)))
            row.tag:SetText("|cfff0a830BW|r")
            row:SetScript("OnClick", function()
                trigTypeVal = (item.entry.kind == "timer") and "bwtimer" or "bwmsg"
                spellIDText = tostring(item.key)
                RebuildTriggerFields()
            end)
            row:Show()
        end
        pickerHint:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", PAD, PICKER_TOP - shown * PICKER_ROW_H)
        if #list > shown then
            pickerHint:SetText(("|cff9a9ea6+%d more not shown -- type the Spell ID below.|r")
                :format(#list - shown))
            pickerHint:SetHeight(16)
            return shown * PICKER_ROW_H + 20
        end
        pickerHint:SetHeight(4)
        return shown * PICKER_ROW_H + 4
    end

    local dynFrame, spellBox, leadTimeBox, pullDelayBox
    local triggerTypeRow

    -- Target: who sees this -- AND across categories (role/class/spec/name/subgroup),
    -- OR within one, matching ns.RaidReminderTargetsMe exactly (see its own comment).
    -- Declared here, built below: RebuildTriggerFields' own tail calls
    -- RebuildTargetSection so toggling Message/Timer (which changes how tall the
    -- fields above it are) re-anchors the whole Target section instead of leaving it
    -- frozen at its original position.
    local nTarget = ns.NormalizeRaidReminderTarget(target)
    local targetAllVal = nTarget.all
    local targetRoles, targetClasses, targetSubgroups = {}, {}, {}
    for k in pairs(nTarget.roles or {}) do targetRoles[k] = true end
    for k in pairs(nTarget.classes or {}) do targetClasses[k] = true end
    for k in pairs(nTarget.subgroups or {}) do targetSubgroups[k] = true end
    local targetSpecText, targetNameText
    do
        local list = {}
        for id in pairs(nTarget.specs or {}) do list[#list + 1] = tostring(id) end
        table.sort(list)
        targetSpecText = table.concat(list, ", ")
    end
    do
        local list = {}
        for name in pairs(nTarget.names or {}) do list[#list + 1] = name end
        table.sort(list)
        targetNameText = table.concat(list, ", ")
    end
    local targetSection
    local RebuildTargetSection

    RebuildTriggerFields = function()
        -- RebuildPicker returns a POSITIVE height consumed; SUBTRACT it from PICKER_TOP
        -- (already negative) to move further down the panel, same sign convention every
        -- other "ty = ty - rowHeight" line in this function already uses. Written as +
        -- originally, which flipped ty positive and threw everything after the picker
        -- back above it -- the overlap seen live.
        -- Skipped entirely for "pull"/"aura": neither is anchored to a BigWigs
        -- mechanic (pull is a flat delay, aura is a plain spell id + apply/remove),
        -- so there's nothing on the boss-mod catalogue to pick from either way.
        if trigTypeVal == "pull" or trigTypeVal == "aura" then
            for i = 1, MECHANIC_ROWS do pickerRows[i]:Hide() end
            pickerHint:SetText("")
            ty = PICKER_TOP
        else
            ty = PICKER_TOP - RebuildPicker()
        end
        -- Every call rebuilds this row from scratch (picking a mechanic off the
        -- picker, or switching Message/Timer itself, both call RebuildTriggerFields
        -- again) -- the previous one has to be hidden first or picking two different
        -- mechanics in a row stacks a second "Trigger Type" dropdown exactly on top
        -- of the first, both drawing their own label text into the same spot.
        if triggerTypeRow then triggerTypeRow:Hide() end

        local typeRowH
        triggerTypeRow, typeRowH = W:DualRow(triggerBody, ty,
            { type = "dropdown", text = "Trigger Type",
              values = { bwmsg = "BigWigs Message", bwtimer = "BigWigs Timer",
                  pull = "Time After Pull", aura = "Gain/Lose a Buff or Debuff",
                  stage = "Phase Start" },
              order = { "bwmsg", "bwtimer", "pull", "aura", "stage" },
              tooltip = "Message fires the instant BigWigs announces it. Timer waits "
                  .. "out the bar and fires this many seconds before it ends. Time "
                  .. "After Pull fires a fixed number of seconds into the encounter, "
                  .. "with no BigWigs mechanic involved. Gain/Lose a Buff or Debuff "
                  .. "fires off the combat log directly, reliable even when BigWigs "
                  .. "says nothing about it. Phase Start fires a fixed number of seconds "
                  .. "after the boss mod announces that phase -- it needs BigWigs or DBM, "
                  .. "and only fires on bosses whose module announces phases.",
              getValue = function() return trigTypeVal end,
              setValue = function(v) trigTypeVal = v; RebuildTriggerFields() end }
        )
        ty = ty - typeRowH

        if dynFrame then dynFrame:Hide() end
        dynFrame = CreateFrame("Frame", nil, triggerBody)
        dynFrame:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", 0, ty)
        dynFrame:SetSize(440, 120)
        local dy = 0
        local function DLabel(text)
            local l = ns.Font(dynFrame, 11, nil, ns.THEME.muted)
            l:SetPoint("TOPLEFT", dynFrame, "TOPLEFT", PAD, dy)
            l:SetText(text)
            dy = dy - 16
        end
        local function DBox(maxLetters, numeric, rightInset)
            local box = CreateFrame("EditBox", nil, dynFrame)
            box:SetPoint("TOPLEFT", dynFrame, "TOPLEFT", PAD, dy)
            box:SetPoint("RIGHT", dynFrame, "RIGHT", -(rightInset or PAD), 0)
            box:SetHeight(26)
            box:SetAutoFocus(false)
            box:SetMaxLetters(maxLetters or 60)
            if numeric then box:SetNumeric(true) end
            box:SetFontObject("GameFontHighlight")
            box:SetTextInsets(6, 6, 0, 0)
            ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1):SetAllPoints()
            ns.Border(box)
            dy = dy - 32
            return box
        end

        if trigTypeVal == "pull" then
            spellBox, leadTimeBox = nil, nil
            DLabel("Delay After Pull (seconds)")
            -- Not a numeric box: note-born entries carry fractional times (1:09.1).
            pullDelayBox = DBox(8)
            pullDelayBox:SetText(pullDelayText)
            pullDelayBox:SetScript("OnTextChanged", function()
                pullDelayText = pullDelayBox:GetText() or ""
            end)
            DLabel("Show This Many Seconds Early (blank = at that time)")
            local leadBox = DBox(4)
            leadBox:SetText(earlyLeadText)
            leadBox:SetScript("OnTextChanged", function()
                earlyLeadText = leadBox:GetText() or ""
            end)
        elseif trigTypeVal == "stage" then
            spellBox, leadTimeBox, pullDelayBox = nil, nil, nil
            DLabel("Phase Number")
            local stageBox = DBox(2, true)
            stageBox:SetText(stageNumText)
            stageBox:SetScript("OnTextChanged", function()
                stageNumText = stageBox:GetText() or ""
            end)
            DLabel("Seconds After the Phase Starts")
            local sdBox = DBox(8)
            sdBox:SetText(pullDelayText)
            sdBox:SetScript("OnTextChanged", function()
                pullDelayText = sdBox:GetText() or ""
            end)
            DLabel("Show This Many Seconds Early (blank = at that time)")
            local leadBox = DBox(4)
            leadBox:SetText(earlyLeadText)
            leadBox:SetScript("OnTextChanged", function()
                earlyLeadText = leadBox:GetText() or ""
            end)
        elseif trigTypeVal == "aura" then
            pullDelayBox, leadTimeBox = nil, nil
            DLabel("Spell ID")
            spellBox = DBox(9, true, 80)
            spellBox:SetText(spellIDText)
            local okBtn = ns.Button(dynFrame, "OK", 54, 26, function() spellBox:ClearFocus() end)
            okBtn:SetPoint("LEFT", spellBox, "RIGHT", 6, 0)
            local feedback = ns.Font(dynFrame, 10, nil, ns.THEME.muted)
            feedback:SetPoint("TOPLEFT", dynFrame, "TOPLEFT", PAD, dy + 6)
            feedback:SetPoint("RIGHT", dynFrame, "RIGHT", -PAD, 0)
            feedback:SetJustifyH("LEFT")
            dy = dy - 14
            local function Sync()
                local sid, info = ns.ResolveSpell(spellBox:GetText())
                if sid then
                    feedback:SetText("|cff6DD09A" .. ((info and info.name) or "") .. "|r")
                elseif spellBox:GetText() == "" then
                    feedback:SetText("")
                else
                    feedback:SetText("|cffff6060not a spell id|r")
                end
            end
            spellBox:SetScript("OnTextChanged", function() spellIDText = spellBox:GetText() or ""; Sync() end)
            spellBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
            Sync()

            local auraRowH
            _, auraRowH = W:DualRow(dynFrame, dy,
                { type = "dropdown", text = "Event",
                  values = { applied = "Gained", removed = "Lost" }, order = { "applied", "removed" },
                  getValue = function() return auraEventVal end,
                  setValue = function(v) auraEventVal = v end },
                { type = "dropdown", text = "On",
                  values = { player = "You", boss = "The Boss" }, order = { "player", "boss" },
                  tooltip = "Watch YOUR OWN aura (a defensive/buff you gain or lose) or "
                      .. "one applied TO the boss (a debuff you or the raid puts on it).",
                  getValue = function() return auraTargetVal end,
                  setValue = function(v) auraTargetVal = v end }
            )
            dy = dy - auraRowH
        else
            pullDelayBox = nil
            DLabel("Spell ID")
            spellBox = DBox(9, true, 80)
            spellBox:SetText(spellIDText)
            local okBtn = ns.Button(dynFrame, "OK", 54, 26, function() spellBox:ClearFocus() end)
            okBtn:SetPoint("LEFT", spellBox, "RIGHT", 6, 0)
            local feedback = ns.Font(dynFrame, 10, nil, ns.THEME.muted)
            feedback:SetPoint("TOPLEFT", dynFrame, "TOPLEFT", PAD, dy + 6)
            feedback:SetPoint("RIGHT", dynFrame, "RIGHT", -PAD, 0)
            feedback:SetJustifyH("LEFT")
            dy = dy - 14
            local function Sync()
                local sid, info = ns.ResolveSpell(spellBox:GetText())
                if sid then
                    feedback:SetText("|cff6DD09A" .. ((info and info.name) or "") .. "|r")
                elseif spellBox:GetText() == "" then
                    feedback:SetText("")
                else
                    feedback:SetText("|cff9a9ea6no spell name found -- boss-mod keys aren't "
                        .. "always real spell ids, that's fine|r")
                end
            end
            spellBox:SetScript("OnTextChanged", function() spellIDText = spellBox:GetText() or ""; Sync() end)
            spellBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
            Sync()

            if trigTypeVal == "bwtimer" then
                DLabel("Warning Time (seconds before it lands)")
                leadTimeBox = DBox(4, true)
                leadTimeBox:SetText(leadTimeText)
                leadTimeBox:SetScript("OnTextChanged", function() leadTimeText = leadTimeBox:GetText() or "" end)
            else
                leadTimeBox = nil
            end
        end

        -- dynFrame's own dy cursor is local to this closure and never reaches the outer
        -- ty on its own -- without this, the Target section built right after this call
        -- returns would render on top of whatever dynFrame just placed here, since ty
        -- would still be sitting at the Trigger Type row's own bottom edge.
        ty = ty + dy
        RebuildTargetSection()
    end

    RebuildTargetSection = function()
        if targetSection then targetSection:Hide() end
        targetSection = CreateFrame("Frame", nil, triggerBody)
        targetSection:SetPoint("TOPLEFT", triggerBody, "TOPLEFT", 0, ty - 10)
        targetSection:SetPoint("RIGHT", triggerBody, "RIGHT", 0, 0)

        local tgy = 0
        local function TargetLabel(text)
            local l = ns.Font(targetSection, 11, nil, ns.THEME.muted)
            l:SetPoint("TOPLEFT", targetSection, "TOPLEFT", PAD, tgy)
            l:SetText(text)
            tgy = tgy - 16
        end
        TargetLabel("Target")

        local allCheck = CreateFrame("CheckButton", nil, targetSection, "UICheckButtonTemplate")
        allCheck:SetSize(20, 20)
        allCheck:SetPoint("TOPLEFT", targetSection, "TOPLEFT", PAD, tgy)
        allCheck:SetChecked(targetAllVal)
        local allLbl = ns.Font(targetSection, 11, nil, ns.THEME.fg)
        allLbl:SetPoint("LEFT", allCheck, "RIGHT", 4, 0)
        allLbl:SetText("Everyone")
        tgy = tgy - 28

        -- Greyed out (not just ignored) while Everyone is checked -- an irrelevant
        -- control should read as irrelevant, same reasoning the boss cast-bar's own
        -- AddCastBlock gating uses elsewhere in this addon suite.
        local restFrame = CreateFrame("Frame", nil, targetSection)
        restFrame:SetPoint("TOPLEFT", targetSection, "TOPLEFT", 0, tgy)
        restFrame:SetPoint("RIGHT", targetSection, "RIGHT", 0, 0)

        local ry = 0
        local function RestLabel(text)
            local l = ns.Font(restFrame, 11, nil, ns.THEME.muted)
            l:SetPoint("TOPLEFT", restFrame, "TOPLEFT", PAD, ry)
            l:SetText(text)
            ry = ry - 16
        end
        -- A fixed grid of small checkboxes -- shared shape for role/class/subgroup,
        -- the three fixed-size enumerations. AND-across/OR-within (see
        -- ns.RaidReminderTargetsMe) means checking two roles widens ("Tank OR
        -- Healer"), while a role AND a class both checked narrows to their overlap.
        local function CheckGrid(items, set, perRow, itemW, colorFn)
            for i = 1, #items do
                local key, label = items[i][1], items[i][2]
                local col = (i - 1) % perRow
                local row = math.floor((i - 1) / perRow)
                local check = CreateFrame("CheckButton", nil, restFrame, "UICheckButtonTemplate")
                check:SetSize(18, 18)
                check:SetPoint("TOPLEFT", restFrame, "TOPLEFT", PAD + col * itemW, ry - row * 22)
                check:SetChecked(set[key])
                check:SetScript("OnClick", function(self)
                    if self:GetChecked() then set[key] = true else set[key] = nil end
                end)
                local lbl = ns.Font(restFrame, 10, nil, ns.THEME.fg)
                lbl:SetPoint("LEFT", check, "RIGHT", 2, 0)
                lbl:SetWordWrap(false)
                lbl:SetText(label)
                if colorFn then
                    local r, g, b = colorFn(key)
                    if r then lbl:SetTextColor(r, g, b, 1) end
                end
            end
            ry = ry - math.ceil(#items / perRow) * 22 - 8
        end

        RestLabel("Role")
        do
            local items = {}
            for i = 1, #RR_ROLE_ORDER do items[i] = { RR_ROLE_ORDER[i], RR_ROLE_VALUES[RR_ROLE_ORDER[i]] } end
            CheckGrid(items, targetRoles, 3, 140)
        end

        RestLabel("Class")
        do
            local items = ns.PlayableClasses()
            local classColors = RAID_CLASS_COLORS or CUSTOM_CLASS_COLORS
            CheckGrid(items, targetClasses, 3, 140, function(token)
                local c = classColors and classColors[token]
                if c then return c.r, c.g, c.b end
            end)
        end

        RestLabel("Raid Group")
        do
            local items = {}
            for i = 1, 4 do items[i] = { i, tostring(i) } end
            -- Four covers a 20-man mythic roster. A flex raid can still run to eight, so
            -- groups above four appear only when something is already assigned to one --
            -- an older assignment stays editable without cluttering the usual case.
            for i = 5, 8 do
                if targetSubgroups[i] then items[#items + 1] = { i, tostring(i) } end
            end
            CheckGrid(items, targetSubgroups, 8, 52)
        end

        local function RestBox(labelText, existingText, onChange)
            RestLabel(labelText)
            local box = CreateFrame("EditBox", nil, restFrame)
            box:SetPoint("TOPLEFT", restFrame, "TOPLEFT", PAD, ry)
            box:SetPoint("RIGHT", restFrame, "RIGHT", -PAD, 0)
            box:SetHeight(26)
            box:SetAutoFocus(false)
            box:SetMaxLetters(200)
            box:SetFontObject("GameFontHighlight")
            box:SetTextInsets(6, 6, 0, 0)
            ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1):SetAllPoints()
            ns.Border(box)
            box:SetText(existingText)
            box:SetScript("OnTextChanged", function() onChange(box:GetText() or "") end)
            ry = ry - 32
        end
        RestBox("Spec IDs (comma-separated, optional)", targetSpecText,
            function(v) targetSpecText = v end)
        RestBox("Player Names (comma-separated, exact, optional)", targetNameText,
            function(v) targetNameText = v end)

        restFrame:SetHeight(-ry)
        restFrame:SetShown(not targetAllVal)
        allCheck:SetScript("OnClick", function(self)
            targetAllVal = self:GetChecked() and true or false
            restFrame:SetShown(not targetAllVal)
        end)

        targetSection:SetHeight(-tgy + (targetAllVal and 0 or -ry))
    end
    RebuildTriggerFields()

    -------------------------------------------------------------------------
    --  Display tab
    -------------------------------------------------------------------------
    local dsy = 0
    local function DsLabel(text)
        local l = ns.Font(displayBody, 11, nil, ns.THEME.muted)
        l:SetPoint("TOPLEFT", displayBody, "TOPLEFT", PAD, dsy)
        l:SetText(text)
        dsy = dsy - 16
    end
    local function DsBox(maxLetters, numeric, rightInset)
        local box = CreateFrame("EditBox", nil, displayBody)
        box:SetPoint("TOPLEFT", displayBody, "TOPLEFT", PAD, dsy)
        box:SetPoint("RIGHT", displayBody, "RIGHT", -(rightInset or PAD), 0)
        box:SetHeight(26)
        box:SetAutoFocus(false)
        box:SetMaxLetters(maxLetters or 60)
        if numeric then box:SetNumeric(true) end
        box:SetFontObject("GameFontHighlight")
        box:SetTextInsets(6, 6, 0, 0)
        ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1):SetAllPoints()
        ns.Border(box)
        dsy = dsy - 32
        return box
    end

    local displayTypeVal = display.type or "text"
    local _, dispRowH = W:DualRow(displayBody, dsy,
        { type = "dropdown", text = "Display As",
          values = RR_DISPLAY_VALUES, order = RR_DISPLAY_ORDER,
          tooltip = "Message/Timer/Icon/Bar/Circle each have their own fixed on-screen "
              .. "spot. Chat Line prints instead of showing anything. Nameplate/"
              .. "Raid-Frame Glow highlight another raider's own frame -- set who "
              .. "below. Nameplate Glow does nothing inside dungeons and raids, where the "
              .. "game keeps friendly nameplates from addons; use Raid-Frame Glow there.",
          getValue = function() return displayTypeVal end,
          setValue = function(v) displayTypeVal = v end }
    ); dsy = dsy - dispRowH

    DsLabel("Glow Player Name (Nameplate/Raid-Frame Glow only)")
    local glowTargetBox = DsBox(24)
    glowTargetBox:SetText(display.glowTarget or "")

    DsLabel("Text -- %name (your name), %specicon, %time (linger seconds), {spell:ID}")
    local textBox = DsBox(120)
    textBox:SetText(display.text or "")

    DsLabel("Icon Spell ID (used for Icon display; optional otherwise)")
    local iconBox = DsBox(9, true, PAD + 34)
    local iconPreview = displayBody:CreateTexture(nil, "ARTWORK")
    iconPreview:SetSize(24, 24)
    iconPreview:SetPoint("LEFT", iconBox, "RIGHT", 6, 0)
    iconPreview:Hide()
    local iconFeedback = ns.Font(displayBody, 10, nil, ns.THEME.muted)
    iconFeedback:SetPoint("TOPLEFT", displayBody, "TOPLEFT", PAD, dsy)
    iconFeedback:SetPoint("RIGHT", displayBody, "RIGHT", -PAD, 0)
    iconFeedback:SetJustifyH("LEFT")
    dsy = dsy - 14
    local function SyncIcon()
        local sid, info = ns.ResolveSpell(iconBox:GetText())
        if sid then
            local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
            if tex then iconPreview:SetTexture(tex); iconPreview:Show() else iconPreview:Hide() end
            iconFeedback:SetText("|cff6DD09A" .. ((info and info.name) or "") .. "|r")
        elseif iconBox:GetText() == "" then
            iconPreview:Hide(); iconFeedback:SetText("")
        else
            iconPreview:Hide(); iconFeedback:SetText("|cffff6060not a spell id|r")
        end
    end
    iconBox:SetScript("OnTextChanged", SyncIcon)
    iconBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    iconBox:SetText((display.spellID and tostring(display.spellID)) or "")
    SyncIcon()

    local existingColor = display.color
    local pendingColor = { r = (existingColor and existingColor.r) or 1,
        g = (existingColor and existingColor.g) or 1, b = (existingColor and existingColor.b) or 1,
        a = (existingColor and existingColor.a) or 1 }
    local _, colorRowH = W:DualRow(displayBody, dsy,
        { type = "colorpicker", text = "Text Color", hasAlpha = false,
          tooltip = "This reminder's text color.",
          getValue = function() return pendingColor.r, pendingColor.g, pendingColor.b, pendingColor.a end,
          setValue = function(r, g, b, a) pendingColor = { r = r, g = g, b = b, a = a } end }
    ); dsy = dsy - colorRowH

    local pendingSoundKey = display.sound or "none"
    local soundPaths, soundNames, soundOrder = EUI.BuildAlertSoundTables()
    if EUI.AppendSharedMediaSounds then EUI.AppendSharedMediaSounds(soundPaths, soundNames, soundOrder) end
    local _, soundRowH = W:DualRow(displayBody, dsy,
        { type = "dropdown", text = "Sound", values = soundNames, order = soundOrder,
          tooltip = "Plays once when this reminder fires.",
          getValue = function() return pendingSoundKey end,
          setValue = function(v)
              pendingSoundKey = v
              if EUI._PlayLSMSound and soundPaths[v] then EUI._PlayLSMSound(soundPaths[v]) end
          end }
    ); dsy = dsy - soundRowH

    local ttsVal = display.tts == true
    local _, ttsRowH = W:DualRow(displayBody, dsy,
        { type = "toggle", text = "Speak (Text-to-Speech)",
          tooltip = "Reads the Text field aloud through your own client's built-in "
              .. "text-to-speech, using whatever voice/rate you set in the "
              .. "Accessibility panel.",
          getValue = function() return ttsVal end,
          setValue = function(v) ttsVal = v end }
    ); dsy = dsy - ttsRowH

    DsLabel("Linger (seconds)")
    local durBox = DsBox(3, true)
    durBox:SetText(tostring(display.dur or 4))

    -- MRT's event-13 "hide after use" gate -- once YOU successfully cast this spell,
    -- whatever's currently on screen for this reminder disappears immediately instead
    -- of waiting out its own Linger. Optional: blank means it only ever hides on its
    -- own timer, same as before this existed.
    DsLabel("Hide Once I Cast (Spell ID, optional)")
    local hideCastBox = DsBox(9, true, PAD + 34)
    local hideCastFeedback = ns.Font(displayBody, 10, nil, ns.THEME.muted)
    hideCastFeedback:SetPoint("TOPLEFT", displayBody, "TOPLEFT", PAD, dsy)
    hideCastFeedback:SetPoint("RIGHT", displayBody, "RIGHT", -PAD, 0)
    hideCastFeedback:SetJustifyH("LEFT")
    dsy = dsy - 14
    local function SyncHideCast()
        local sid, info = ns.ResolveSpell(hideCastBox:GetText())
        if sid then
            hideCastFeedback:SetText("|cff6DD09A" .. ((info and info.name) or "") .. "|r")
        elseif hideCastBox:GetText() == "" then
            hideCastFeedback:SetText("")
        else
            hideCastFeedback:SetText("|cffff6060not a spell id|r")
        end
    end
    hideCastBox:SetScript("OnTextChanged", SyncHideCast)
    hideCastBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    hideCastBox:SetText((display.hideAfterCastID and tostring(display.hideAfterCastID)) or "")
    SyncHideCast()

    local healerVal = existing and existing.healerReminder == true or false
    local enabledVal = (existing == nil) or existing.enabled ~= false
    W:DualRow(displayBody, dsy,
        { type = "toggle", text = "Enabled",
          getValue = function() return enabledVal end,
          setValue = function(v) enabledVal = v end },
        { type = "toggle", text = "Healer Reminder",
          tooltip = "Mark this reminder so players can opt out with Enable Healer Reminders in Setup.",
          getValue = function() return healerVal end,
          setValue = function(v) healerVal = v end }
    )

    SelectTab("trigger")

    -------------------------------------------------------------------------
    --  Save / Preview
    -------------------------------------------------------------------------
    local function BuildEntry()
        local newTrig
        if trigTypeVal == "pull" then
            local delay = tonumber(pullDelayText)
            if not delay or delay < 0 then return nil, "need a valid delay in seconds" end
            newTrig = { type = "pull", delay = delay, leadTime = tonumber(earlyLeadText) }
        elseif trigTypeVal == "stage" then
            local stageN = tonumber(stageNumText)
            local delay = tonumber(pullDelayText)
            if not stageN or stageN < 1 then return nil, "need a phase number of 1 or more" end
            if not delay or delay < 0 then return nil, "need a valid delay in seconds" end
            newTrig = { type = "stage", stage = stageN, delay = delay,
                leadTime = tonumber(earlyLeadText) }
        else
            local sid = tonumber(spellIDText)
            if not sid then return nil, "need a valid Spell ID" end
            newTrig = { type = trigTypeVal, spellID = sid }
            if trigTypeVal == "bwtimer" then
                newTrig.leadTime = tonumber(leadTimeText) or 3
            elseif trigTypeVal == "aura" then
                newTrig.auraEvent = auraEventVal
                newTrig.target = auraTargetVal
            end
        end
        local newTarget = { all = targetAllVal }
        if not targetAllVal then
            if next(targetRoles) then newTarget.roles = targetRoles end
            if next(targetClasses) then newTarget.classes = targetClasses end
            if next(targetSubgroups) then newTarget.subgroups = targetSubgroups end
            local specs = {}
            for numStr in targetSpecText:gmatch("[^,%s]+") do
                local id = tonumber(numStr)
                if id then specs[id] = true end
            end
            if next(specs) then newTarget.specs = specs end
            local names = {}
            for namePart in targetNameText:gmatch("[^,]+") do
                namePart = namePart:match("^%s*(.-)%s*$")
                if namePart ~= "" then names[namePart] = true end
            end
            if next(names) then newTarget.names = names end
        end
        local iconSid = tonumber(iconBox:GetText())
        local hideCastSid = tonumber(hideCastBox:GetText())
        local newDisplay = {
            type = displayTypeVal,
            text = textBox:GetText(),
            spellID = (iconSid and iconSid > 0) and iconSid or nil,
            color = pendingColor,
            dur = math.max(1, tonumber(durBox:GetText()) or 4),
            sound = (pendingSoundKey ~= "none") and pendingSoundKey or nil,
            hideAfterCastID = (hideCastSid and hideCastSid > 0) and hideCastSid or nil,
            tts = ttsVal or nil,
            glowTarget = (glowTargetBox:GetText() ~= "" and glowTargetBox:GetText()) or nil,
        }
        return {
            name = (nameBox:GetText() ~= "" and nameBox:GetText()) or "Reminder",
            enabled = enabledVal, trigger = newTrig, target = newTarget, display = newDisplay,
            healerReminder = healerVal or nil,
            abilitySpellID = boundAbilitySpellID,
        }
    end

    local function Save()
        local entry, err = BuildEntry()
        if not entry then
            ns.Print("|cffff6060" .. (err or "could not save this reminder") .. "|r")
            return
        end
        local writeSet = ns.RaidRemindersTable(true, encounterID)
        local key = uid or ("rr" .. math.floor(GetTime() * 1000) .. math.random(1, 9999))
        writeSet[key] = entry
        -- Takes effect now, and refreshes the cached has-reminders flags the combat log
        -- hot path reads.
        ns.RefreshRuntime()
        dimmer:Hide()
        if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
    end

    ns.Button(panel, "Preview", 90, 26, function()
        -- Bypasses ns.RaidReminderTargetsMe entirely, same as ShowCustomReminderEditor's
        -- own Preview button bypasses trigger matching -- a curator previewing sees it
        -- regardless of whether they personally match the target they just chose.
        local entry, buildErr = BuildEntry()
        if entry then
            if ns.PreviewRaidReminder then ns.PreviewRaidReminder(entry) end
        else
            ns.Print("|cffff6060" .. (buildErr or "could not preview this reminder") .. "|r")
        end
    end):SetPoint("BOTTOM", panel, "BOTTOM", -110, 16)
    ns.Button(panel, "Save", 90, 26, Save):SetPoint("BOTTOM", panel, "BOTTOM", -10, 16)
    ns.Button(panel, "Cancel", 90, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOM", panel, "BOTTOM", 90, 16)

    end)
    if not ok then
        -- Fixed offset, not TAB_TOP -- that local only exists inside the pcall'd
        -- closure above, out of scope here precisely because it failed to run.
        local errText = ns.Font(panel, 11, nil, { r = 1, g = 0.35, b = 0.35 })
        errText:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -70)
        errText:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
        errText:SetJustifyH("LEFT")
        errText:SetWordWrap(true)
        errText:SetText("Failed to build this panel: " .. tostring(err))
        ns.Print("|cffff6060raid reminder editor|r: " .. tostring(err))
    end

    dimmer:Show()
    -- Returned so a caller (ns.ShowBossReminderPicker) can hook OnHide and refresh its
    -- own list once this editor closes -- ignored by every other existing call site.
    return dimmer, panel
end

-------------------------------------------------------------------------------
--  Diagnostics
-------------------------------------------------------------------------------
-- Coverage check. The journal's Tank flag is an editorial annotation and may not perfectly
-- match the TankRole bit the live HUD uses, and neither dataset is in the client source --
-- both are DB2 tables. This prints the totals so the two can be compared against a boss
-- whose abilities you already know.
function ns.PrintBossSummary()
    local data = ns.ScrapeBosses(false)
    if not data then
        ns.Print("could not read the journal (" .. tostring(scrapeFailed) .. ").")
        return
    end

    -- Stage report first: an empty list is almost always one of these returning nothing,
    -- and knowing which turns a guessing game into a one-line fix.
    ns.Print(("stages: tier=%s  challengeMaps=%s  mappedToJournal=%s  raidInstances=%s")
        :format(tostring(diag.tier), tostring(diag.mapCount),
                tostring(diag.mapped), tostring(diag.raids)))
    if diag.mapCount == -1 then
        ns.Print("|cffff6060C_ChallengeMode.GetMapTable is unavailable|r -- no dungeons can be listed.")
    elseif diag.mapCount == 0 then
        ns.Print("|cffff6060The keystone map table is empty|r -- open the Mythic+ UI once, then Refresh.")
    elseif (diag.mapped or 0) == 0 then
        ns.Print("|cffff6060No dungeon mapped to a journal instance|r -- GetInstanceForGameMap returned nothing.")
    end
    if (diag.raids or 0) == 0 then
        ns.Print("|cffff6060No raid found for the current tier|r -- open the Adventure Guide once, then Refresh.")
    end
    local instCount, bossCount, abilCount, emptyBosses = 0, 0, 0, 0
    for i = 1, #data.instances do
        local inst = data.instances[i]
        instCount = instCount + 1
        for b = 1, #inst.bosses do
            bossCount = bossCount + 1
            local n = #inst.bosses[b].abilities
            abilCount = abilCount + n
            if n == 0 then emptyBosses = emptyBosses + 1 end
        end
        ns.Print(("%s%s: %d bosses"):format(inst.isRaid and "[raid] " or "", inst.name, #inst.bosses))
    end
    ns.Print(("total: %d instances, %d bosses, %d abilities, %d bosses with none")
        :format(instCount, bossCount, abilCount, emptyBosses))
end

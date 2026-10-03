-------------------------------------------------------------------------------
--  NaowhUI_TankReminder.lua -- shows which defensive to press when Blizzard's encounter
--  timeline says a tank ability is about to land.
--
--  The core owns the DB and profiles; the Window file owns the options window the pages
--  here render into.
--
--  Both halves of this feature are secret on 12.1, and neither can be an `if`:
--
--    "is this a tank hit"  -- the TankRole bit of EncounterTimelineEventInfo.icons,
--                             secret for every Encounter-source event.
--    "is this spell ready" -- cooldown state, secret in instanced combat.
--
--  Comparing a secret, testing its truthiness, doing arithmetic on it or using it as a table
--  key all raise. So nothing in this file decides anything: the decision is handed to the
--  engine and consumed as alpha. The priority pick rides a chain of
--  C_CurveUtil.EvaluateColorValueFromBoolean, which is AllowedWhenTainted in ALL arguments
--  and therefore composes -- a secret may be both the condition and a branch value, and the
--  result goes straight into SetAlpha. Exactly one icon ends up visible without the answer
--  ever reaching Lua.
--
--  The engine's own tank gate (SetEventIconTextures) reaches TEXTURES only, never a
--  FontString, which is why the fingerprint filter replaced it -- see ClearTankGate.
-------------------------------------------------------------------------------
local ns = _G.NaowhUITankReminder
if not ns then return end

-------------------------------------------------------------------------------
--  DB
-------------------------------------------------------------------------------
-- enabled defaults off: until the user opts in, no events are registered and no frames
-- are built. Flat scalars only -- a nested default would hand out a live reference to
-- DEFAULTS itself. `disabled` and `lists` are created on demand for the same reason.
local DEFAULTS = {
    -- Everything ships OFF, at the owner's direction: a fresh install does nothing and
    -- shows nothing until each switch -- the master, a display channel, and where it
    -- runs -- is deliberately turned on.
    enabled   = false,
    showIcon  = false,
    showText  = false,
    showBar   = false,
    soundOn   = false,
    soundKey  = "none",
    fallbackOn = false,
    coveredSkip = true,
    -- Marks a profile past the one-time flip in TRDB. A default so packs carry it, and an
    -- imported coveredSkip = false is not flipped back on.
    coveredSkipDefaultOn = true,
    coveredCastWindow = 6,   -- how long your own cast counts as cover
    leadTime   = 3,     -- seconds before impact that the alert fires
    lingerSec  = 3,     -- display duration; early dismissal on cast is opt-in
    cdmGlow    = false, -- glow the called defensive on the Cooldown Manager bar
    voiceOn   = false,
    voiceNone = "Call for external",
    externalChat = false,
    voiceVol  = 100,
    iconSize  = 64,
    -- 21 matches what the OLD derived formula (floor(iconSize * 0.34), floored at 12)
    -- produced at the default iconSize of 64, so a first read after this shipped changed
    -- nothing on screen for an existing install.
    textSize   = 21,
    -- Which side of the icon the text callout sits on: TOP, BOTTOM, LEFT or RIGHT.
    textSide   = "BOTTOM",
    -- Which single source drives the callouts: "timeline" (Blizzard's own encounter
    -- timeline), "bigwigs" or "dbm". Exclusive by design -- the other two are ignored.
    bossSource = "timeline",
    -- pos = { point, relPoint, x, y } once moved in Unlock Mode; nil = default centre.
}

-- Which profile tables have already had the migration and the defaults fill run against
-- them. Keyed by the table itself rather than a flag on it, so nothing lands in
-- SavedVariables, and weak so a profile switched away from does not pin its table.
--
-- Per TABLE, not once at init: SettingsRoot() answers for the ACTIVE profile, so a single
-- cached table would keep handing back the old profile's settings after a switch. This way
-- each profile is prepared the first time it is touched and cheap on every call after.
local prepared = setmetatable({}, { __mode = "k" })

local function TRDB()
    local root = ns.SettingsRoot()
    if type(root.tankReminder) ~= "table" then root.tankReminder = {} end
    local t = root.tankReminder
    if prepared[t] then return t end
    prepared[t] = true
    -- One-way migration from the single flat list per spec this addon shipped with before
    -- presets existed: every existing list becomes that spec's "Default" preset, so nobody's
    -- configured priority order disappears the first time this loads.
    if type(t.lists) == "table" and next(t.lists) ~= nil and type(t.presets) ~= "table" then
        t.presets = {}
        t.activePreset = t.activePreset or {}
        for specKey, list in pairs(t.lists) do
            t.presets[specKey] = { p1 = { name = "Default", list = list } }
            t.activePreset[specKey] = "p1"
        end
        t.lists = nil
    end
    -- The text used to be dragged around on its own; it rides the icon now, so a stored
    -- position for it is dead weight that would outlive every reset button.
    t.textPos = nil
    -- Broadcasts outside any encounter used to be catalogued under "0", which nothing reads.
    if type(t.bwCatalogue) == "table" then t.bwCatalogue["0"] = nil end
    -- Older builds pre-filled the callout editor with "Use <name>", so saved callouts still
    -- carry the prefix the spoken default dropped.
    if type(t.callouts) == "table" then
        for id, text in pairs(t.callouts) do
            local bare = type(text) == "string" and text:match("^[Uu]se%s+(.+)$")
            if bare then t.callouts[id] = bare end
        end
    end
    -- Trash rules were saved with a generic "Use a defensive" line the editor minted for
    -- them; the page has never had a text box for anyone to have typed it in. A rule
    -- carrying it has no line of its own, and a blank one answers with the spec's preset
    -- instead of speaking a placeholder over icons that have already gone dark.
    if type(t.integrationRules) == "table" then
        for _, rules in pairs(t.integrationRules) do
            if type(rules) == "table" then
                for _, rule in pairs(rules) do
                    if type(rule) == "table" and type(rule.display) == "table"
                        and type(rule.trigger) == "table" and rule.trigger.type == "exboss"
                        and rule.display.text == "Use a defensive" then
                        rule.display.text = ""
                    end
                end
            end
        end
    end
    -- Call Together was briefly stored as a chain to the entry below before it became a set
    -- ticked per entry. Nothing reads the old key, so it is dead weight in the saved file.
    if type(t.presets) == "table" then
        for _, specPresets in pairs(t.presets) do
            if type(specPresets) == "table" then
                for _, p in pairs(specPresets) do
                    if type(p) == "table" then p.chain = nil end
                end
            end
        end
    end
    -- Skip When Already Covered shipped off, and the fill below saved that false into every
    -- profile, so turning the default on needs a one-time flip to reach them.
    if not t.coveredSkipDefaultOn then
        t.coveredSkip = true
        t.coveredSkipDefaultOn = true
    end
    for k, v in pairs(DEFAULTS) do if t[k] == nil then t[k] = v end end
    return t
end

local function IsSpellDisabled(spellID)
    local d = TRDB().disabled
    return d ~= nil and d[spellID] == true
end

local function SetSpellDisabled(spellID, off)
    local t = TRDB()
    if off then
        if type(t.disabled) ~= "table" then t.disabled = {} end
        t.disabled[spellID] = true
    elseif type(t.disabled) == "table" then
        t.disabled[spellID] = nil
        if next(t.disabled) == nil then t.disabled = nil end
    end
end

-------------------------------------------------------------------------------
--  The priority list is the user's, per spec -- grouped into named presets
-------------------------------------------------------------------------------
-- This addon ships with NO ability data of its own -- no boss timers, no spell lists, no
-- encounter knowledge. It is an engine: the player builds the priority order themselves
-- (or imports one through an EllesmereUI profile string) and it drives whatever they put
-- in it. Everything it reacts to at runtime comes from Blizzard's own encounter timeline.
--
-- Per spec rather than global, because a priority order is only meaningful within one spec
-- and a tank who also heals should not rebuild it on every switch. Within a spec, a player
-- can keep more than one named list (an M+ set, a raid-CD set, ...) and switch which one is
-- active; only the active preset's list is "the" spec default anywhere else in this file.
-- profile.presets[specKey][presetKey] = { name = "...", list = { spellID, ... } }
-- profile.activePreset[specKey] = presetKey
local function PresetsTable(forSpec, create)
    local t = TRDB()
    if type(t.presets) ~= "table" then
        if not create then return nil end
        t.presets = {}
    end
    local key = tostring(forSpec or 0)
    if type(t.presets[key]) ~= "table" then
        if not create then return nil end
        t.presets[key] = {}
    end
    return t.presets[key]
end

-- Read-only: which preset is active for this spec, or nil if none exist yet.
local function ActivePresetKey(forSpec)
    local t = TRDB()
    local presets = PresetsTable(forSpec, false)
    if not presets then return nil end
    local key = tostring(forSpec or 0)
    local a = type(t.activePreset) == "table" and t.activePreset[key]
    if a and presets[a] then return a end
    -- The pointer is missing or points at a preset that got deleted: the first one that
    -- still exists becomes active, rather than the spec silently reading as unconfigured.
    a = next(presets)
    if a then
        if type(t.activePreset) ~= "table" then t.activePreset = {} end
        t.activePreset[key] = a
    end
    return a
end
ns.ActivePresetKey = ActivePresetKey

-- Same, but seeds an empty "Default" preset the first time this spec is touched at all, so
-- there is always something selected to add spells to.
local function EnsureActivePreset(forSpec)
    local a = ActivePresetKey(forSpec)
    if a then return a end
    local presets = PresetsTable(forSpec, true)
    presets.p1 = { name = "Default", list = {} }
    local t = TRDB()
    if type(t.activePreset) ~= "table" then t.activePreset = {} end
    t.activePreset[tostring(forSpec or 0)] = "p1"
    return "p1"
end

-- Every preset for this spec, name and key, in a stable creation-ish order (numerically by
-- key where the key is one of ours -- "p1", "p2", ... -- which sorts sensibly since they
-- are only ever appended, never renumbered).
-- p.name falls back to something visibly a placeholder, never the bare internal key --
-- every preset created through AddPreset gets a real name ("Preset 1", with a space; the
-- key itself never has one), so a dropdown showing literally "p2" is a malformed entry,
-- not a real choice, and should read as one rather than pass for a preset the player made.
function ns.ListPresets(forSpec)
    local presets = PresetsTable(forSpec, false)
    local out = {}
    if not presets then return out end
    for key, p in pairs(presets) do
        local name = p.name
        if type(name) ~= "string" or name == "" then name = "(unnamed " .. key .. ")" end
        out[#out + 1] = { key = key, name = name }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- The actual priority list behind one preset key -- ns.ListPresets only hands back
-- {key, name} pairs, not the list itself, which the per-defensive warning-time rows need
-- to know which spells to show.
function ns.PresetList(forSpec, presetKey)
    local presets = PresetsTable(forSpec, false)
    local p = presets and presetKey and presets[presetKey]
    return p and type(p.list) == "table" and p.list or nil
end

-- Default name is "Preset N" for the lowest N not already in use, so deleting one and
-- adding another does not produce a duplicate label.
function ns.NextPresetName(forSpec)
    local presets = PresetsTable(forSpec, false)
    local used = {}
    if presets then
        for _, p in pairs(presets) do
            if p.name then used[p.name] = true end
        end
    end
    local n = 1
    while used["Preset " .. n] do n = n + 1 end
    return "Preset " .. n
end

function ns.AddPreset(forSpec, name)
    local presets = PresetsTable(forSpec, true)
    local n = 1
    while presets["p" .. n] do n = n + 1 end
    local key = "p" .. n
    presets[key] = { name = (name and name ~= "" and name) or ns.NextPresetName(forSpec),
                      list = {} }
    local t = TRDB()
    if type(t.activePreset) ~= "table" then t.activePreset = {} end
    t.activePreset[tostring(forSpec or 0)] = key
    return key
end

function ns.SelectPreset(forSpec, presetKey)
    local presets = PresetsTable(forSpec, false)
    if not (presets and presets[presetKey]) then return false end
    local t = TRDB()
    if type(t.activePreset) ~= "table" then t.activePreset = {} end
    t.activePreset[tostring(forSpec or 0)] = presetKey
    return true
end

function ns.RenamePreset(forSpec, presetKey, name)
    local presets = PresetsTable(forSpec, false)
    local p = presets and presets[presetKey]
    if not p then return false end
    p.name = (name and name ~= "") and name or p.name
    return true
end

-- Refuses to delete the last preset a spec has: EnsureActivePreset would just recreate an
-- empty "Default" preset a moment later, so the button would look like it did nothing.
function ns.DeletePreset(forSpec, presetKey)
    local presets = PresetsTable(forSpec, false)
    if not presets or not presets[presetKey] then return false end
    local count = 0
    for _ in pairs(presets) do count = count + 1 end
    if count <= 1 then return false end
    local t = TRDB()
    for _, set in pairs(t.customReminders or {}) do
        for _, r in pairs(set) do
            if r.preset == presetKey and (not r.specID or r.specID == forSpec) then
                ns.Print("Reassign or delete reminder '" .. (r.name or "Reminder")
                    .. "' before deleting this preset.")
                return false
            end
        end
    end
    local integrationRules = t.integrationRules and t.integrationRules[tostring(forSpec or 0)]
    for _, rule in pairs(integrationRules or {}) do
        if rule.preset == presetKey then
            ns.Print("Reassign or delete trash rule '" .. (rule.name or "Reminder")
                .. "' before deleting this preset.")
            return false
        end
    end
    presets[presetKey] = nil
    local key = tostring(forSpec or 0)
    if type(t.activePreset) == "table" and t.activePreset[key] == presetKey then
        t.activePreset[key] = nil
    end
    ActivePresetKey(forSpec)   -- re-pick immediately so nothing reads as unconfigured
    return true
end

local function UserList(forSpec, create)
    local presetKey = create and EnsureActivePreset(forSpec) or ActivePresetKey(forSpec)
    if not presetKey then return nil end
    local presets = PresetsTable(forSpec, create)
    local p = presets and presets[presetKey]
    if not p then return nil end
    if type(p.list) ~= "table" then
        if not create then return nil end
        p.list = {}
    end
    return p.list
end

-- The entries on this preset that are called TOGETHER. One group per preset, ticked per
-- entry: when the pick lands on any member, every other member that is ready is named
-- alongside it. Order is not part of it -- an earlier version chained each entry to the one
-- below and the ordering was the confusing part, since what the player wants to say is
-- simply "these go together".
--
-- Keyed by spell id rather than by list position, so drag-reorder needs no repair.
--
-- ns functions rather than chunk locals: this file is at the 200-local ceiling.
function ns.CalledTogetherInPreset(forSpec, presetKey, spellID)
    if not presetKey then return false end
    local presets = PresetsTable(forSpec, false)
    local p = presets and presets[presetKey]
    return (p and type(p.together) == "table" and p.together[tostring(spellID)]) == true
end

-- The editor always edits the ACTIVE preset, so this is the one the options pages want.
function ns.CalledTogether(forSpec, spellID)
    return ns.CalledTogetherInPreset(forSpec, ActivePresetKey(forSpec), spellID)
end

function ns.SetCalledTogether(forSpec, spellID, on)
    local presetKey = EnsureActivePreset(forSpec)
    if not presetKey then return end
    local presets = PresetsTable(forSpec, true)
    local p = presets and presets[presetKey]
    if not p then return end
    if type(p.together) ~= "table" then p.together = {} end
    p.together[tostring(spellID)] = on and true or nil
end

-- Per-boss overrides live beside the spec default, keyed spec:encounter. The key is the
-- dungeonEncounterID -- the same id ENCOUNTER_START reports and the same one the journal
-- hands back -- so what the tree sets up and what fires in the fight are the same record.
--
-- Fallback is deliberate and one level deep: an empty or absent boss list means "use my spec
-- default", so a tank sets their normal order once and only overrides the fights that need it.
local function BossKey(forSpec, encounterID)
    return tostring(forSpec or 0) .. ":" .. tostring(encounterID or 0)
end

local function BossList(forSpec, encounterID, create)
    local t = TRDB()
    if type(t.bossLists) ~= "table" then
        if not create then return nil end
        t.bossLists = {}
    end
    local key = BossKey(forSpec, encounterID)
    if type(t.bossLists[key]) ~= "table" then
        if not create then return nil end
        t.bossLists[key] = {}
    end
    return t.bossLists[key]
end

local function ClearBossList(forSpec, encounterID)
    local t = TRDB()
    if type(t.bossLists) ~= "table" then return end
    t.bossLists[BossKey(forSpec, encounterID)] = nil
    if next(t.bossLists) == nil then t.bossLists = nil end
end

-- Which preset a boss draws its defensives from -- a persistent, per-boss choice, not a
-- live mirror of the spec's active preset. nil means nothing was ever explicitly picked
-- for this boss, at which point the active preset applies by fallback (see EffectiveList).
local function BossPresetKey(forSpec, encounterID)
    local t = TRDB()
    local bp = type(t.bossPreset) == "table" and t.bossPreset[BossKey(forSpec, encounterID)]
    local presets = PresetsTable(forSpec, false)
    if bp and presets and presets[bp] then return bp end
    return nil
end
ns.BossPresetKey = BossPresetKey

local function SetBossPreset(forSpec, encounterID, presetKey)
    local t = TRDB()
    if type(t.bossPreset) ~= "table" then t.bossPreset = {} end
    t.bossPreset[BossKey(forSpec, encounterID)] = presetKey
end
ns.SetBossPreset = SetBossPreset

local function ListIndexOf(list, spellID)
    for i = 1, #list do
        if list[i] == spellID then return i end
    end
    return nil
end

-- Spoken line per spell. Defaults to the spell name; the point of storing an override is
-- that "Incarnation: Guardian of Ursoc" is not what anyone says out loud.
local function CalloutFor(spellID, spellName)
    local c = TRDB().callouts
    local custom = c and c[spellID]
    if type(custom) == "string" and custom ~= "" then return custom end
    -- The name alone, no "Use " prefix (cut on tester feedback): in a fight the extra
    -- word is latency, and nobody hearing "Shield Wall" wonders what to do with it.
    return spellName or ""
end

local function SetCallout(spellID, text)
    local t = TRDB()
    if type(text) == "string" and text ~= "" then
        if type(t.callouts) ~= "table" then t.callouts = {} end
        t.callouts[spellID] = text
    elseif type(t.callouts) == "table" then
        t.callouts[spellID] = nil
        if next(t.callouts) == nil then t.callouts = nil end
    end
end

-- The encounter we are actually in, from ENCOUNTER_START. Plain: encounter ids are not
-- secret. nil outside a boss fight, which is what makes the spec default apply everywhere else.
local currentEncounter

-- BigWigs' own stage number, current for this pull, from its own BigWigs_SetStage
-- broadcast -- not read from anything of theirs beyond the live message, same as
-- everything else this bridge catalogues. Reset every pull, alongside bwActiveMod (both
-- reset at the same ENCOUNTER_START/END handler, far below). Stamped onto each
-- catalogued key by RecordBossModKey so the boss browser can group abilities by the
-- stage they were actually seen in, once that display exists. Declared here rather than
-- beside bwActiveMod itself: RecordBossModKey, which reads it, is defined well before
-- that point in the file, and a bare local has to exist before its first use textually,
-- not just before it runs.
local currentStage
-- When the current stage began, and when the pull did. Both are plain GetTime() stamps;
-- observed-timing recording measures against them, and a phase-relative time is the only
-- trustworthy one for later phases, whose start is health-gated rather than scheduled.
local currentStageAt
local currentEncounterStartedAt
local currentDifficultyID

-- The list that actually drives the alert: this ability's own preset choice when it has
-- one, else this boss's chosen preset, else the spec default.
-- fp, when given, is a spellID (as a string) from the ability picker's Pre-Selected
-- Defensives dropdown -- checked first since it is the most specific, most recent choice
-- for this exact ability.
local function EffectiveList(forSpec, encounterID, fp, presetOverride)
    if presetOverride then
        local presets = PresetsTable(forSpec, false)
        local preset = presets and presets[presetOverride]
        return preset and preset.list, true, presetOverride
    end
    if encounterID and fp then
        local sid = tonumber(fp)
        local binding = sid and ns.BindingForBossModKey and ns.BindingForBossModKey(encounterID, sid)
        if binding and binding.preset then
            local presets = PresetsTable(forSpec, false)
            local p = presets and presets[binding.preset]
            if p and type(p.list) == "table" and #p.list > 0 then
                return p.list, true, binding.preset
            end
        end
        -- The older per-ability raw list (composite key "encounter#fingerprint"), from
        -- before this moved to picking one whole preset per ability -- still honored for
        -- anyone who has one saved, though nothing writes new ones.
        local al = BossList(forSpec, tostring(encounterID) .. "#" .. fp, false)
        if al and #al > 0 then return al, true, nil end
    end
    if encounterID then
        local explicit = BossPresetKey(forSpec, encounterID)
        local presetKey = explicit or ActivePresetKey(forSpec)
        if presetKey then
            local presets = PresetsTable(forSpec, false)
            local p = presets and presets[presetKey]
            if p and type(p.list) == "table" and #p.list > 0 then
                return p.list, explicit ~= nil, presetKey
            end
        end
    end
    return UserList(forSpec, false), false, ActivePresetKey(forSpec)
end
ns.EffectiveList = EffectiveList

-- Cap on built slots, and on how long a list the options page will accept. Nothing reads a
-- secret to size this, and it must not: slot count, creation and layout are all driven by
-- the saved list and talent state, which stay plain.
local MAX_SLOTS = 8

-------------------------------------------------------------------------------
--  Capability gate
-------------------------------------------------------------------------------
-- Probed once rather than assumed. Every one of these is load-bearing, and on a client
-- missing any of them the feature stays inert instead of erroring per boss ability.
local canSelect, canGate, canSound, canBar

local function ProbeCapabilities()
    canSelect = (C_CurveUtil ~= nil and C_CurveUtil.EvaluateColorValueFromBoolean ~= nil
        and C_Spell ~= nil and C_Spell.GetSpellCooldownDuration ~= nil)

    canGate = (C_EncounterTimeline ~= nil and C_EncounterTimeline.SetEventIconTextures ~= nil
        and Enum ~= nil and Enum.EncounterEventIconmask ~= nil
        and Enum.EncounterEventIconmask.TankRole ~= nil)

    canSound = (C_EncounterEvents ~= nil and C_EncounterEvents.SetEventSound ~= nil
        and C_EncounterEvents.GetEventList ~= nil and C_EncounterEvents.GetEventInfo ~= nil
        and Enum ~= nil and Enum.EncounterEventSoundTrigger ~= nil)

    canBar = (C_EncounterTimeline ~= nil and C_EncounterTimeline.GetEventTimer ~= nil)
end

-- The feature exists on this client at all. This is the ONLY availability check that may
-- gate event registration.
--
-- IsFeatureEnabled() must never be used for that: it folds in the player's CVars, and the
-- events keep firing when those are off. A popular boss-mod addon ships with
-- encounterTimelineEnabled forced to "0" and the timeline frame reparented away, and then
-- drives its own bars from these very events -- so gating on IsFeatureEnabled would break
-- this addon for that entire userbase while the data was flowing the whole time.
local function TimelineAvailable()
    return C_EncounterTimeline ~= nil
        and C_EncounterTimeline.IsFeatureAvailable ~= nil
        and C_EncounterTimeline.IsFeatureAvailable()
end

-- The master switch, which is a different thing from the timeline's own display toggle.
-- We never write either one: two boss-mod addons already fight over the display CVar every
-- pull, and a third writer would just make that worse. Detect, tell the user once, move on.
-- Reported by the diagnostic command, never acted on. The CVar gates Blizzard's own
-- timeline frame and nothing else: with it at 0 the events still arrive and a registered
-- sound still plays, both measured on a live boss. Worth SHOWING when reading a bug
-- report, worth never warning about.
local function TimelineDisplayOff()
    return C_CVar ~= nil and C_CVar.GetCVarBool ~= nil
        and C_CVar.GetCVarBool("encounterTimelineEnabled") == false
end

local function CombatWarningsOff()
    return C_CVar ~= nil and C_CVar.GetCVarBool ~= nil
        and C_CVar.GetCVarBool("combatWarningsEnabled") == false
end

-------------------------------------------------------------------------------
--  Can we legally NAME the defensive out loud?
-------------------------------------------------------------------------------
-- Every visual channel dodges the secret by handing the question to the engine and taking
-- back pixels. A spoken line cannot: choosing which line to speak IS a Lua branch on
-- readiness, and no sound or speech API accepts a secret in the argument that would select
-- it. (C_VoiceChat.SpeakText does accept a secret string, but nothing hands us a
-- pre-selected secret spell NAME, so that opening leads nowhere.)
--
-- So the callout is only lawful when the spell's cooldown is not classified. The predicate
-- below returns a PLAIN boolean and is safe to branch on -- Blizzard's own code does the
-- same shape in Blizzard_AuraContainerUtil.
--
-- Realistically that means out of combat, because SecretWhenCooldownsRestricted engages on
-- combat, encounter, challenge mode OR pvp match -- which is precisely when a defensive
-- callout is wanted. The one way it survives combat is a spell carrying the data-side
-- NeverSecret flag, which overrides restrictions. Whether any real defensive is flagged that
-- way is game data, not something the client source can answer: /nutank secrecy measures it.
--
-- Note HasSecretRestrictions() is NOT the check. It reports whether this client BUILD has
-- the system compiled in, not whether restrictions are live, so it is constant true on
-- retail and gates nothing.
local function CanNameSpellAloud(spellID)
    if not (C_Secrets and C_Secrets.ShouldSpellCooldownBeSecret) then return false end
    local ok, secret = pcall(C_Secrets.ShouldSpellCooldownBeSecret, spellID)
    return ok and secret == false
end

-- Shared by /nutank secrecy and the automatic call log below, so a spell's classification
-- reads the same both places.
local function SecrecyLevelName(spellID)
    if not (C_Secrets and C_Secrets.GetSpellCooldownSecrecy and Enum.SecrecyLevel) then
        return "?"
    end
    local ok, lv = pcall(C_Secrets.GetSpellCooldownSecrecy, spellID)
    if not ok then return "?" end
    for name, value in pairs(Enum.SecrecyLevel) do
        if value == lv then return name end
    end
    return "?"
end

local function IsSpellAvailable(spellID)
    if C_SpellBook and C_SpellBook.IsSpellKnownOrInSpellBook then
        if C_SpellBook.IsSpellKnownOrInSpellBook(spellID) then return true end
    end
    return IsPlayerSpell ~= nil and IsPlayerSpell(spellID) == true
end

-------------------------------------------------------------------------------
--  Spec and role
-------------------------------------------------------------------------------
-- One call answers both, and `role` is why this beats reading the spec ID alone:
-- UnitGroupRolesAssigned returns "NONE" for an ungrouped player, so it cannot gate a
-- feature that has to work while soloing a dummy.
local specID, isTank = 0, false

-- Role and class are the two axes a binding can load on besides the spec itself, so an
-- assignment can read "every healer" or "every paladin" without naming four specs. They
-- live on ns rather than as file locals: this chunk is close enough to Lua's 200-local
-- ceiling that adding two here stops the whole addon compiling.
local function RefreshSpec()
    specID, isTank = 0, false
    ns.playerRole = nil
    ns.playerClass = select(2, UnitClass("player"))
    if not (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) then return end
    local index = C_SpecializationInfo.GetSpecialization()
    if not index then return end
    local id, _, _, _, role = C_SpecializationInfo.GetSpecializationInfo(index)
    specID = id or 0
    isTank = (role == "TANK")
    ns.playerRole = role
    -- Resolved through ns rather than called directly: this runs before the migration is
    -- defined further down the file. It no-ops once the profile is stamped.
    if ns.MigrateBindingScopes then ns.MigrateBindingScopes() end
end

function ns.CurrentRole() return ns.playerRole end
function ns.CurrentClass() return ns.playerClass end

-------------------------------------------------------------------------------
--  The display
-------------------------------------------------------------------------------
local Reminder = {}
local frame, slots = nil, {}
-- A 1x1 anchor the text callout hangs off, parked on whichever side of the icon the
-- player picked. slot.label stays PARENTED to its slot (nothing here touches
-- ApplyPriorityAlpha's secret-driven alpha cascade, which slot.label still rides
-- unchanged); only the anchor TARGET is textFrame. Parent and anchor target are
-- independent in the frame API, which is what makes this safe.
local textFrame
local bar
local activeSlots = 0           -- how many slots the current spec actually uses
local hideTimer
local shownForEvent

local function ApplyPosition()
    if not frame then return end
    local p = TRDB().pos
    frame:ClearAllPoints()
    if p then
        frame:SetPoint(p.point or "CENTER", UIParent, p.relPoint or "CENTER", p.x or 0, p.y or 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
    end
end

-- Not in DEFAULTS: that table is filled into a profile with a plain `t[k] = v` shallow
-- copy (see PrepareProfile below), which for a TABLE value would hand every profile the
-- SAME table by reference -- one profile's color would silently move every other
-- profile's too, and mutating it in place would corrupt the shared default itself. A
-- fresh literal on every read/write here means nothing is ever shared.
local function DefensiveTextColor()
    local c = TRDB().defensiveTextColor
    return (c and c.r) or 1, (c and c.g) or 1, (c and c.b) or 1, (c and c.a) or 1
end


-- Both colors are opt-in ("as an option", not a forced restyle): white unless the player
-- has switched the toggle on, matching what every install has always shown.
--
-- Two different font strings both count as "the defensive text": slots[i].label is the
-- one actually seen in combat -- "Barkskin", stacked one per priority slot so the tank
-- gate's per-icon alpha can pick the winning line the same way it picks the winning icon,
-- see CreateSlot's own comment -- while frame.reminder is a separate authored-reminder
-- line the Says/Preview path draws, one line further from the icon. Coloring only the
-- latter is what shipped first and is why the toggle looked like it did nothing: the text
-- someone actually watches during a pull never went through it.
local function ApplyDefensiveTextColor()
    if not frame then return end
    local on = TRDB().defensiveTextColorOn
    local r, g, b, a = 1, 1, 1, 1
    if on then r, g, b, a = DefensiveTextColor() end

    if frame.reminder then frame.reminder:SetTextColor(r, g, b, a) end
    for i = 1, #slots do
        if slots[i].label then slots[i].label:SetTextColor(r, g, b, a) end
    end
end


-- Where the countdown bar sits under the icon, shared with the text layout below so the
-- two cannot drift apart.
local BAR_DROP, BAR_HEIGHT = 26, 10

local TEXT_GAP = 6
local REMINDER_SIZE = 15

-- The icon is the one thing that moves; the text rides whichever side of it was chosen.
-- Each line is placed off the same anchor point rather than off the line before it, so an
-- empty authored reminder or a hidden authoring tag collapses to nothing instead of
-- pushing the callout away from the icon.
--
-- The near edge is anchored, never the centre: a centred string grows in both directions,
-- which is what made the text creep into the icon as the defensive name got longer and
-- sit miles away from it when the name was short.
local function ApplyTextLayout()
    if not (frame and textFrame) then return end
    local t = TRDB()
    local side = t.textSide or DEFAULTS.textSide
    local line = (t.textSize or DEFAULTS.textSize) + 4

    textFrame:ClearAllPoints()
    local point, dir
    if side == "TOP" then
        textFrame:SetPoint("BOTTOM", frame, "TOP", 0, TEXT_GAP)
        point, dir = "BOTTOM", 1
    elseif side == "LEFT" then
        textFrame:SetPoint("RIGHT", frame, "LEFT", -TEXT_GAP, 0)
        point, dir = "RIGHT", 1
    elseif side == "RIGHT" then
        textFrame:SetPoint("LEFT", frame, "RIGHT", TEXT_GAP, 0)
        point, dir = "LEFT", 1
    else
        -- Clear of the countdown bar when a stored profile still has one: its toggle is
        -- gone from the UI but the setting outlives it.
        local drop = TEXT_GAP + (t.showBar and (BAR_DROP + BAR_HEIGHT) or 0)
        textFrame:SetPoint("TOP", frame, "BOTTOM", 0, -drop)
        point, dir = "TOP", -1
    end

    local function place(fs, offset)
        if not fs then return end
        fs:ClearAllPoints()
        fs:SetPoint(point, textFrame, point, 0, dir * offset)
    end
    for i = 1, #slots do place(slots[i].label, 0) end
    place(frame.fallback, 0)
    place(frame.reminder, line)
    place(frame.learnTag, line * 2 + REMINDER_SIZE + 4)

    -- The target name takes the authored line's row when that line is not in use, which for
    -- a boss-mod callout is always: it is only shown for a reminder carrying its own text.
    -- Fixed at line * 2 it floated a clear row above the callout with a hole beneath it,
    -- which reads as belonging to nothing and was missed entirely in play.
    --
    -- Placed from here rather than at draw time because place() owns the anchor and the
    -- direction, and those change with Text Position. Re-run when the name goes up, since
    -- whether the authored line is showing is decided per callout, not per setting.
    --
    -- Its own pitch, floored at the font's own height: `line` follows Text Size, but these
    -- strings are drawn at REMINDER_SIZE whatever that is set to, so at a small Text Size a
    -- single `line` of separation is less than the glyphs are tall and the name lands on
    -- top of the callout. The old two-row gap hid that; one row does not.
    ns.PlaceCastTargetLine = function()
        local pitch = math.max(line, REMINDER_SIZE + 4)
        local occupied = frame.reminder and frame.reminder:IsShown()
        place(frame.castTarget, occupied and pitch * 2 or pitch)
    end
    ns.PlaceCastTargetLine()
end

-- The suite's own media, resolved through SharedMedia so the paths live in one place and
-- locale variants (the Asia font files) resolve themselves. Everything degrades: no media
-- addon means the client default font.
local function NaowhMedia(kind, name)
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if not LSM then return nil end
    local ok, path = pcall(LSM.Fetch, LSM, kind, name, true)
    return ok and path or nil
end

local function AlertFont()
    local selected = TRDB().fontName
    local path = type(selected) == "string" and NaowhMedia("font", selected)
    return path or NaowhMedia("font", "Naowh") or STANDARD_TEXT_FONT
end
ns.AlertFontPath = AlertFont

-- Display only, never clickable. Alpha 0 hides the art but NOT hit-testing, so a losing
-- slot left mouse-enabled would still be a live mouse target sitting over the screen.
local function CreateSlot(index)
    local slot = CreateFrame("Frame", nil, frame)
    slot:SetPoint("TOP")                -- every slot stacks on the same spot: one wins, the
    slot:EnableMouse(false)             -- rest sit at alpha 0 behind it
    slot:SetAlpha(0)

    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetAllPoints()
    slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- 1px black edge so a bright spell icon reads as its own object against whatever is
    -- behind it in the world. Parented to the slot, so it rides the same priority alpha
    -- the icon does rather than hanging around on a slot that lost.
    ns.Border(slot, { r = 0, g = 0, b = 0 }, 1)

    local T = ns.THEME

    -- The spoken callout, written instead of said: "Barkskin". It stays PARENTED to the
    -- slot, so the priority alpha that picks the winning icon still picks the winning line
    -- too -- one stacked font string per spell, engine-revealed, no branch. That is why the
    -- text can name the defensive in combat while the spoken version cannot. Only the ANCHOR
    -- target is textFrame, which the frame API allows independent of parentage, so the line
    -- can sit on any side of the icon without touching the secret-driven alpha at all.
    --
    -- A FontString still cannot carry the tank gate (that rides textures only), which is the
    -- separate reason this channel is offered only while the tank filter is off.
    slot.label = slot:CreateFontString(nil, "OVERLAY")
    slot.label:SetFont(AlertFont(), 16, "OUTLINE")
    slot.label:SetTextColor(T.fg.r, T.fg.g, T.fg.b, 1)
    slot.label:Hide()

    slots[index] = slot
    ApplyDefensiveTextColor()  -- a freshly created slot starts at T.fg above; this corrects
                               -- it to whatever the player has actually chosen, if anything.
    ApplyTextLayout()
    return slot
end

-- One bar for the whole alert, not one per slot: it counts down the incoming ability, which
-- is the same fact whichever defensive wins. Built from textures throughout so the tank gate
-- can reach every part of it.
local function CreateBar()
    if bar then return bar end
    bar = CreateFrame("StatusBar", nil, frame)
    bar:SetPoint("TOP", frame, "BOTTOM", 0, -BAR_DROP)
    bar:SetHeight(BAR_HEIGHT)
    bar:EnableMouse(false)
    bar:SetMinMaxValues(0, 1)
    bar:SetStatusBarTexture(NaowhMedia("statusbar", "NaowhGradient")
        or "Interface\\TargetingFrame\\UI-StatusBar")
    bar.fill = bar:GetStatusBarTexture()
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetPoint("TOPLEFT", bar, "TOPLEFT", -1, 1)
    bar.bg:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 1, -1)
    local T = ns.THEME
    bar.bg:SetColorTexture(T.bg.r, T.bg.g, T.bg.b, 0.9)
    if bar.fill then bar.fill:SetVertexColor(T.accent.r, T.accent.g, T.accent.b, 1) end
    bar:Hide()
    return bar
end

function Reminder.Create()
    if frame then return frame end

    -- Not "NaowhUITankReminder": a named frame replaces the global of that name, and that
    -- global is the addon table other addons look up.
    frame = CreateFrame("Frame", "NaowhUITankReminderAlert", UIParent)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(false)
    frame:Hide()

    -- Nothing draws on textFrame itself, only the font strings anchored to it, so it is
    -- a bare anchor point parked against the icon by ApplyTextLayout.
    textFrame = CreateFrame("Frame", "NaowhUITankReminderText", UIParent)
    textFrame:SetSize(1, 1)
    textFrame:SetFrameStrata("HIGH")
    textFrame:EnableMouse(false)
    textFrame:Hide()

    -- "Call for external". This one is not per-spell, so it sits on the container and takes
    -- the accumulator LEFT OVER after the priority walk: that value is 1 only when nobody
    -- won, which is exactly "nothing on your list is up". The engine works it out; we never
    -- learn it.
    -- The authored reminder line sits one line further from the icon than the defensive
    -- callout, so the two never fight. Plain data only: fingerprints and authored text.
    frame.reminder = textFrame:CreateFontString(nil, "OVERLAY")
    frame.reminder:SetFont(AlertFont(), REMINDER_SIZE, "OUTLINE")
    ApplyDefensiveTextColor()
    frame.reminder:Hide()

    frame.fallback = textFrame:CreateFontString(nil, "OVERLAY")
    frame.fallback:SetFont(AlertFont(), 16, "OUTLINE")
    local T = ns.THEME
    frame.fallback:SetTextColor(T.accentSoft.r, T.accentSoft.g, T.accentSoft.b, 1)
    frame.fallback:SetAlpha(0)
    frame.fallback:Hide()

    -- Call Out Unknown Bosses changes what every uncovered boss does -- quiet becomes
    -- call-everything -- and shipped with no on-screen sign it was active at all. Twice
    -- now, a callout that looked like wrong data was actually just this switch left on
    -- from an earlier authoring session. The tag rides the text callout; the border rides
    -- the icon -- between the two, whichever one someone's eyes are on says so.
    -- Who the boss is casting at. Its own font string, never appended to the callout
    -- line: the name arrives as a secret and joining a secret to anything raises. Blizzard
    -- draws its own cast bar the same way, with a separate label for exactly this reason.
    frame.castTarget = textFrame:CreateFontString(nil, "OVERLAY")
    frame.castTarget:SetFont(AlertFont(), REMINDER_SIZE, "OUTLINE")
    frame.castTarget:Hide()

    -- There is deliberately no "you are the one targeted" marker. PlayerIsSpellTarget
    -- answers that, but as a SECRET boolean, and the only thing to do with one is hand it
    -- to SetShown -- which is documented AllowedWhenUntainted and refuses a secret from
    -- addon code. Blizzard's own cast bar does exactly this and gets away with it because
    -- its code is untainted; ours never is. It shipped pcall-wrapped and so failed
    -- silently for three versions rather than erroring. The name below carries the same
    -- information anyway: when the cast is on you, the name it prints is yours.

    frame.learnTag = textFrame:CreateFontString(nil, "OVERLAY")
    frame.learnTag:SetFont(AlertFont(), 12, "OUTLINE")
    frame.learnTag:SetTextColor(1, 0.65, 0.2, 1)
    frame.learnTag:SetText("AUTHORING MODE -- CALLING EVERY ABILITY")
    frame.learnTag:Hide()
    frame.learnBorder = ns.Border(frame, { r = 1, g = 0.65, b = 0.2 }, 1)
    if frame.learnBorder and frame.learnBorder._frame then frame.learnBorder._frame:Hide() end

    -- A spec with no list never reaches RebuildSlots, and a zero-sized frame is one Unlock
    -- Mode cannot pick up, so position it now regardless.
    ApplyPosition()
    ApplyTextLayout()
    return frame
end

local function ApplySize()
    if not frame then return end
    if frame.reminder then frame.reminder:SetFont(AlertFont(), REMINDER_SIZE, "OUTLINE") end
    if frame.castTarget then frame.castTarget:SetFont(AlertFont(), REMINDER_SIZE, "OUTLINE") end
    if frame.learnTag then frame.learnTag:SetFont(AlertFont(), 12, "OUTLINE") end
    local t = TRDB()
    local size = t.iconSize or DEFAULTS.iconSize
    -- Independent of icon size: this used to be derived from it (floor(size * 0.34)), which
    -- was the whole reason moving the icon and text apart still left them stuck at the same
    -- size as each other.
    local fontSize = t.textSize or DEFAULTS.textSize
    local textOn = t.showText
    frame:SetSize(size, size)
    for i = 1, #slots do
        slots[i]:SetSize(size, size)
        slots[i].label:SetFont(AlertFont(), fontSize, "OUTLINE")
        slots[i].label:SetShown(textOn)
        slots[i].icon:SetShown(t.showIcon)
    end
    if frame.fallback then
        frame.fallback:SetFont(AlertFont(), fontSize, "OUTLINE")
        frame.fallback:SetText(t.voiceNone or "")
        frame.fallback:SetShown(textOn and t.fallbackOn ~= false)
    end
    if bar then bar:SetWidth(math.max(size * 2, 120)) end
    ApplyTextLayout()
end

-------------------------------------------------------------------------------
--  Rebuilding the slot list
-------------------------------------------------------------------------------
-- Talent state is plain, so everything here -- which spells qualify, how many slots exist,
-- what icon each carries -- is decided in the clear and never mid-fight. The secret half
-- only ever touches alpha.
local function RebuildSlots(fp, keepIfEmpty, presetOverride)
    -- A general rebuild waits for a live callout to end (HideReminder): it would swap that
    -- callout's slots for the default list and blank what is on screen.
    if shownForEvent and not keepIfEmpty then
        ns.slotsStale = true
        return
    end
    -- A warning with no usable defensive must leave the current display intact.
    if keepIfEmpty then
        if not frame then return false end
        local candidateList = EffectiveList(specID, currentEncounter, fp, presetOverride)
        if not candidateList then return false end
        local found = false
        for i = 1, #candidateList do
            local sid = candidateList[i]
            if IsSpellAvailable(sid) and not IsSpellDisabled(sid) then
                found = true
                break
            end
        end
        if not found then return false end
    end
    activeSlots = 0
    if not frame then return end

    -- Which preset these slots came from. Call Together is stored per preset, and the
    -- list in play is not always the spec's ACTIVE one -- a boss or a single ability can
    -- bind its own -- so the set has to be read from the same preset the slots were built
    -- from, or it leaks into presets it was never configured on and is ignored on the one
    -- actually running.
    local list, _, presetKey = EffectiveList(specID, currentEncounter, fp, presetOverride)
    ns.slotsPreset = presetKey
    -- No auto-seeding: an untouched spec stays silent rather than calling out a list the
    -- player never chose. Robin wants every preset built deliberately in Setup, per spec.
    if not list then
        for i = 1, #slots do slots[i]:SetAlpha(0) end
        return
    end

    for i = 1, #list do
        local spellID = list[i]
        if activeSlots < MAX_SLOTS and IsSpellAvailable(spellID) and not IsSpellDisabled(spellID) then
            activeSlots = activeSlots + 1
            local slot = slots[activeSlots] or CreateSlot(activeSlots)
            slot.spellID = spellID
            -- GetSpellInfo returns nothing for a spell the client has not cached, which is
            -- the normal case right after someone types an ID in. GetSpellTexture answers from
            -- a different path and usually has it; the question mark is the last resort.
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
            local iconID = info and info.iconID
            if not iconID and C_Spell and C_Spell.GetSpellTexture then
                local ok, tex = pcall(C_Spell.GetSpellTexture, spellID)
                if ok then iconID = tex end
            end
            slot.iconID = iconID or 134400
            slot.icon:SetTexture(slot.iconID)
            -- Same string the spoken callout uses, so editing it once changes both.
            slot.label:SetText(CalloutFor(spellID, info and info.name))
        end
    end

    -- Unused slots keep existing but never light up. Rebuilding on talent change rather
    -- than releasing them keeps frame creation off the combat path entirely.
    for i = 1, #slots do
        slots[i]:SetAlpha(0)
    end
    ApplySize()
    return true
end

-------------------------------------------------------------------------------
--  The priority pick
-------------------------------------------------------------------------------
-- N-way exclusive select with no branch on a secret anywhere.
--
--   ready     -- a possibly-secret boolean, never inspected
--   eligible  -- "nobody above me has won yet"; plain 1 on the first pass, secret after
--
-- SetAlpha(ev(ready, eligible, 0)) lights this slot only when it is ready AND still
-- eligible, and the accumulator then closes the door for everyone below. The evaluator is
-- AllowedWhenTainted in every argument, which is what makes the secret `eligible` legal as a
-- branch value. EllesmereUI already chains these two deep for the nameplate kick tick; this
-- is the same primitive generalised to N.
--
-- The loop runs for EVERY slot on every pass, with no break and no early return: Blizzard's
-- own comment in EncounterTimelineTemplates warns that skipping setters leaks the secret
-- through the call count.
-- Defined further down alongside chargeState; forward-declared so ApplyPriorityAlpha can
-- close over them.
local EnsureChargeState, ChargesAvailable

local function ApplyPriorityAlpha()
    local ev = C_CurveUtil.EvaluateColorValueFromBoolean
    local eligible = 1

    for i = 1, activeSlots do
        local slot = slots[i]

        -- Charges first, mirroring SpeakCallout below: holding 1 of 2 charges leaves a
        -- recharge timer ACTIVE, so GetSpellCooldownDuration reads it as running even
        -- though the spell is castable right now. Without this the icon lost the pick to
        -- the next slot down while the voice, which already special-cased charges,
        -- correctly called the held one -- a callout with the wrong icon lit.
        EnsureChargeState(slot.spellID)
        local charges = ChargesAvailable(slot.spellID)
        local dur = (not charges) and C_Spell.GetSpellCooldownDuration(slot.spellID, true) or nil
        -- ignoreGCD=true is load-bearing. It defaults to FALSE, and the returned duration
        -- then covers the global cooldown -- so mid-fight, with a GCD running almost
        -- constantly, every defensive reported as unavailable and no icon ever appeared.
        --
        -- A duration object is a PLAIN handle wrapping secret state (unlike GetSpellCooldown,
        -- which is flagged SecretWhenCooldownsRestricted), so testing the handle and its
        -- method is legal. Calling IsZero() is what produces the secret.

        if charges then
            -- Tracked from the player's own casts, so this is plain even in restricted
            -- content: no engine evaluator needed for this branch.
            local ready = charges > 0
            slot:SetAlpha(ready and eligible or 0)
            if ready then eligible = 0 end
        elseif dur and dur.IsZero then
            local ready = dur:IsZero()
            -- SetAlpha with an engine-evaluated value rather than SetAlphaFromBoolean: the
            -- latter documents its alpha default as 255, so its scale is ambiguous, and this
            -- is the form EllesmereUI already ships for secret-driven alpha.
            slot:SetAlpha(ev(ready, eligible, 0))
            eligible = ev(ready, 0, eligible)
        else
            -- The API is MayReturnNothing and returns the ACTIVE cooldown, so a spell that is
            -- READY hands back nothing at all. Treating that as unknown was why a defensive
            -- sitting off cooldown never won the pick and everything fell through to the
            -- fallback line. Nil-ness is plain, so branching on it is legal.
            slot:SetAlpha(eligible)
            eligible = 0
        end
    end

    -- Whatever eligibility survived the walk IS "nobody was ready", so the fallback line
    -- needs no extra check of its own. Set unconditionally, like every other slot: a
    -- conditional setter here would leak the answer through the call count.
    -- Switched off means never shown, so the alpha is forced rather than left to the
    -- accumulator.
    if frame and frame.fallback then
        if TRDB().fallbackOn == false then
            frame.fallback:SetAlpha(0)
        else
            frame.fallback:SetAlpha(eligible)
        end
    end
end

-- Both per-boss sets share one shape: profile.<field>[encounterID][fingerprint] = true.
local function PerBossSet(field, create, enc)
    local t = TRDB()
    if type(t[field]) ~= "table" then
        if not create then return nil end
        t[field] = {}
    end
    local key = tostring(enc or 0)
    if type(t[field][key]) ~= "table" then
        if not create then return nil end
        t[field][key] = {}
    end
    return t[field][key]
end
ns.PerBossSet = PerBossSet

-- Boss-scoped custom reminders, independent of the timeline-fingerprint system: each one
-- carries its own trigger (pull, a spell cast/aura) rather than riding an existing marked
-- ability. profile.customReminders[encounterID][uid] = { name, preset, trigger = {...}, dur }.
-- `preset` names a spec preset to pick from at fire time; older entries carry a `msg` string
-- instead and still display it verbatim.
local function CustomRemindersTable(create, enc)
    return PerBossSet("customReminders", create, enc)
end

-- What BigWigs/DBM have actually broadcast for this boss, keyed by the same `key` the
-- match functions below compare against. Recorded so the reminder editor can offer a
-- PICK LIST instead of asking for a typed spell id -- BigWigs/DBM already resolved which
-- ability this is using their own tuned data, and by the time a message crosses this bus
-- it is a plain key and a plain string, nothing secret and nothing for us to identify.
-- Recording it is only remembering what we were already handed.
--
-- This never grows past what a real pull has actually produced: a boss nobody here has
-- pulled yet has an empty catalogue, same as the timeline-fingerprint system before it.
local function BossModCatalogueTable(create, enc)
    return PerBossSet("bwCatalogue", create, enc)
end
ns.BossModCatalogueTable = BossModCatalogueTable

-- Per-ability bindings, keyed by whatever spell id Setup's row displays for that ability --
-- the journal id for a boss with no BigWigs module installed, the BigWigs option id when
-- one is (NaowhUI_SmartReminders_Bosses.lua's BigWigsAbilities). Never read or written
-- directly outside this file's own resolvers, ns.BindingForBossModKey (read) and
-- ns.EnsureBinding (write) -- both bridge the two id spaces via ns.BOSSMOD_KEY_TO_JOURNAL
-- for the confirmed mismatches, so a stale binding from before an id correction is found
-- (and migrated forward on write) instead of silently orphaned.
-- profile.abilityBindings[encounterID][spellID] = { enabled = bool, mode, preset }.
-- Bindings are stored under the spec that made them: abilityBindings[specKey][enc][sid].
-- One shared entry per encounter+spell was the old shape, and it could not work -- enabled,
-- preset and leadTime are all spec-local (a preset key only means anything inside
-- presets[specKey]), so two specs sharing one entry meant the second to touch an ability
-- silently overwrote the first's settings.
local function AbilityBindingsTable(create, enc)
    local t = TRDB()
    if type(t.abilityBindings) ~= "table" then
        if not create then return nil end
        t.abilityBindings = {}
    end
    if specID == 0 then return nil end
    local specKey = tostring(specID)
    local bySpec = t.abilityBindings[specKey]
    if type(bySpec) ~= "table" then
        if not create then return nil end
        bySpec = {}
        t.abilityBindings[specKey] = bySpec
    end
    local encKey = tostring(enc or 0)
    if type(bySpec[encKey]) ~= "table" then
        if not create then return nil end
        bySpec[encKey] = {}
    end
    return bySpec[encKey]
end
ns.AbilityBindingsTable = AbilityBindingsTable

-- A binding another spec owns, offered to this one because its scope names our role or
-- class. Spec ownership is the storage key now, so scope only ever carries roles/classes.
function ns.InheritedBinding(enc, sid)
    local t = TRDB()
    local all = t.abilityBindings
    if type(all) ~= "table" then return nil end
    local encKey, mySpec = tostring(enc or 0), tostring(specID)
    for specKey, bySpec in pairs(all) do
        if specKey ~= mySpec and type(bySpec) == "table" then
            local byEnc = bySpec[encKey]
            local b = type(byEnc) == "table" and byEnc[sid]
            if b == nil and type(byEnc) == "table" and ns.BOSSMOD_KEY_TO_JOURNAL then
                local jid = ns.BOSSMOD_KEY_TO_JOURNAL[sid]
                if jid then b = byEnc[jid] end
            end
            if type(b) == "table" and ns.BindingSharedToMe(b) then return b end
        end
    end
    return nil
end

-- Defined with the rest of the logging further down; forward-declared because the boss-mod
-- key recorder below logs too and runs earlier in the file. Without this the call there
-- read a nil global and threw on every bar a boss mod broadcast, but only ever with the
-- trace switched on, which is why it sat unnoticed.
local AppendLog

-- enc is the broadcasting module's own encounter, for a key sent before our ENCOUNTER_START
-- has set currentEncounter. Outside any encounter there is no boss to file a key under.
local function RecordBossModKey(mod, key, text, kind, enc)
    if type(key) ~= "number" then return end
    enc = currentEncounter or enc
    if not enc then return end
    local cat = BossModCatalogueTable(true, enc)
    if not cat then return end
    local entry = cat[key]
    if not entry then
        cat[key] = { mod = mod, kind = kind, text = text, seen = 1, stage = currentStage }
        -- First time this pull only. Every repeat would bury the callouts in bar traffic.
        if TRDB().trace then
            AppendLog({ kind = "key", sid = key, mod = mod, tankPath = kind })
        end
    else
        entry.mod, entry.kind = mod, kind
        -- The most recent text wins: a bar's "(3)" occurrence suffix drifts pull to
        -- pull, and the freshest label is the one worth showing in the picker.
        if type(text) == "string" and text ~= "" then entry.text = text end
        -- Stage, likewise: an ability seen in two different stages across pulls (a
        -- reused mechanic, or BigWigs itself correcting a stage late) keeps whichever
        -- one was most recently confirmed rather than whatever happened to record first.
        if currentStage then entry.stage = currentStage end
        entry.seen = (entry.seen or 0) + 1
    end
end

ns.CustomRemindersTable = CustomRemindersTable

local BOSS_UNITS = { "boss1", "boss2", "boss3", "boss4", "boss5" }

-- UnitGUID is SecretWhenUnitIdentityRestricted, and that already cost days once on the
-- tank gate (see TankingCaster). Read once from wherever it comes back plainly and kept,
-- rather than called fresh on every combat log line inside a raid, where the answer may
-- not be readable at all. A GUID does not change for the life of the character.
-- Declared here rather than beside OnCombatLog, its original home, because
-- CheckAuraReminder sits earlier in the file and needs it too.
local playerGUID
local function PlayerGUID()
    if playerGUID then return playerGUID end
    local ok, guid = pcall(UnitGUID, "player")
    if ok and not (issecretvalue and issecretvalue(guid)) and type(guid) == "string" then
        playerGUID = guid
    end
    return playerGUID
end
ns.PlayerGUID = PlayerGUID

-- Which GUIDs are currently on boss1-5. The aura triggers ask "is this destGUID a boss"
-- once per combat log line, and answering it with UnitGUID("boss"..i) meant five API
-- calls and five string builds per line -- hundreds of lines a second in a raid, against
-- an answer that only changes when the engage units do. Same secrecy reasoning as
-- PlayerGUID above, and refreshed from INSTANCE_ENCOUNTER_ENGAGE_UNIT.
ns.bossGUIDs = {}
function ns.RefreshBossGUIDs()
    wipe(ns.bossGUIDs)
    for i = 1, 5 do
        local unit = BOSS_UNITS[i]
        if UnitExists(unit) then
            local ok, guid = pcall(UnitGUID, unit)
            if ok and not (issecretvalue and issecretvalue(guid)) and type(guid) == "string" then
                ns.bossGUIDs[guid] = true
            end
        end
    end
end

-- Per-unit tanking verdict: true/false, or nil when both available reads come back
-- secret. Threat status is checked first (>= 2 means tanking) and trusted on its own
-- when it's readable -- confirmed live to be reliably plain even in raid content where
-- the target-match fallback below is not. That fallback exists for the opposite case,
-- content where threat status itself reads secret (SecretWhenUnitThreatStateRestricted
-- vs SecretWhenUnitComparisonRestricted are different gates, so one being secret says
-- nothing about the other).
-- Split out so the pcall can take it by reference: this runs up to five times per
-- boss mod broadcast, and the inline closure it replaced was allocated on every one.
local function ReadTankedVerdict(unit)
    local status = UnitThreatSituation("player", unit)
    local statusKnown = not (issecretvalue and issecretvalue(status))
    if statusKnown then
        return type(status) == "number" and status >= 2
    end
    local same = UnitIsUnit(unit .. "target", "player")
    local sameKnown = not (issecretvalue and issecretvalue(same))
    if sameKnown then return same == true end
    return nil
end

local function UnitTankedVerdict(unit)
    local ok, verdict = pcall(ReadTankedVerdict, unit)
    if not ok then return nil end
    return verdict
end

-- What the boss slots actually said, for the refusal log. "I am not tanking any boss" and
-- "threat came back secret" both reach the gate as a plain false, and they call for
-- different fixes, so the per-slot verdicts are recorded rather than the conclusion.
local function BossThreatSummary()
    local out
    for i = 1, 5 do
        local unit = BOSS_UNITS[i]
        if UnitExists(unit) then
            out = (out and out .. "," or "")
                .. ("%s=%s"):format(unit, tostring(UnitTankedVerdict(unit)))
        end
    end
    return out or "no boss units"
end

-- Does any live boss consider ME its problem? For two-tank raids: the buster lands on
-- whoever has the boss, and the other tank does not need to burn a cooldown for it. An
-- unknown verdict still fails OPEN: a spare callout costs a moment of attention, a
-- suppressed one on the actual tank costs a death. No boss units at all also fails open,
-- for the same reason.
local function TankingSomeBoss()
    local sawBoss, unknown = false, false
    for i = 1, 5 do
        local unit = BOSS_UNITS[i]
        if UnitExists(unit) then
            sawBoss = true
            local verdict = UnitTankedVerdict(unit)
            if verdict == true then return true end
            if verdict == nil then unknown = true end
        end
    end
    if not sawBoss or unknown then return true end
    return false
end

-- Fights that run more than one boss1-5 unit at once (adds, split forms sharing a
-- spell id) make "tanking SOME boss" the wrong question -- the player can hold one
-- unit securely while a different one, casting THIS ability, is the other tank's. When
-- the combat log has told us which unit last cast this spell id, check tanking against
-- that one unit specifically; otherwise fall back to the any-boss check (also what
-- covers single-boss fights, where the two questions have the same answer).
-- Set by FireBigWigsAbility right where it calls TankingCaster, read by LogCallout so a
-- wrong call ("tanking Zul'jan, got called for a Malacrass-only ability") can be
-- diagnosed from /nutank calls after the fact -- reported live on The Coiled Altar P2,
-- no way to react to it typed in the moment a pull is already past.
local lastAggroCheck   -- { sid, verdict, path }

-- Second return is which path answered -- "boss:<unit>", "owner-gone", "nocache" or
-- "fallback" -- so a wrong call can be diagnosed after the fact (see LogCallout)
-- instead of guessed at from a VOD.
--
-- UnitGUID is SecretWhenUnitIdentityRestricted, so inside a raid every GUID read off a
-- boss1-5 or nameplate unit comes back secret and no comparison against a combat-log
-- sourceGUID can ever match. That is why the curated owner map, which names the boss
-- SLOT and needs no identity read at all, is consulted first: it is the only one of
-- these paths that works in the content the gate exists for. Confirmed live on The
-- Coiled Altar with the whole map populated -- every single callout logged the
-- no-match path, in both phases, for both severs.
local castSourceGUID = {}
-- Threat is read at the instant the callout is due, and it does not hold steady for a tank
-- who has the boss the whole time: UnitThreatSituation drops below 2 while the boss is
-- mid-cast with no melee target, across a stage change, and while it is untargetable. Live
-- capture on Ula'tek, one tank on the boss for the whole pull: three callouts went through
-- on boss:boss1 and two were refused seconds later with boss1=false.
--
-- So a refusal is only believed if we have not just seen the player tanking that unit. The
-- grace is short enough that a real taunt swap starts calling for the other tank within a
-- few seconds, and the direction is the safe one: an extra call costs a moment, a swallowed
-- tank buster costs the pull.
-- ns fields, not chunk locals: this chunk is at the 200-local ceiling.
ns.TANKED_GRACE = 6
ns.lastTankedAt = {}

-- Sampled off bar traffic, not only when a callout is due. Written solely at fire time the
-- grace was useless: busters come 25 to 30 seconds apart, so the one stored sample was
-- always older than the grace and every threat dip still refused. Boss mods broadcast bars
-- for the whole encounter every few seconds, which is well inside it.
function ns.SampleTanking()
    local now = GetTime()
    for i = 1, 5 do
        local unit = BOSS_UNITS[i]
        if UnitExists(unit) and UnitTankedVerdict(unit) then ns.lastTankedAt[unit] = now end
    end
end

local function TankingCaster(sid)
    local ownerSlot = ns.TANK_ABILITY_OWNER_UNIT and ns.TANK_ABILITY_OWNER_UNIT[sid]
    if ownerSlot then
        local unit = BOSS_UNITS[ownerSlot]
        if unit and UnitExists(unit) then
            local verdict = UnitTankedVerdict(unit)
            if verdict == nil then return true, "boss:" .. unit .. ":unreadable" end
            if verdict then
                ns.lastTankedAt[unit] = GetTime()
                return true, "boss:" .. unit
            end
            if (GetTime() - (ns.lastTankedAt[unit] or 0)) <= ns.TANKED_GRACE then
                return true, "boss:" .. unit .. ":recent"
            end
            return false, "boss:" .. unit
        end
        -- Slot empty: the owner is dead or not out yet and someone else is taking the
        -- hit. DBM's own Twin Fangs module handles the same case the same way.
        return TankingSomeBoss(), "owner-gone"
    end

    local guid = castSourceGUID[sid]
    if not guid then return TankingSomeBoss(), "nocache" end
    for i = 1, 5 do
        local unit = BOSS_UNITS[i]
        if UnitExists(unit) then
            local ok, unitGUID = pcall(UnitGUID, unit)
            if ok and not (issecretvalue and issecretvalue(unitGUID)) and unitGUID == guid then
                local verdict = UnitTankedVerdict(unit)
                if verdict == nil then return true, "boss:" .. unit .. ":unreadable" end
                return verdict, "boss:" .. unit
            end
        end
    end
    return TankingSomeBoss(), "fallback"
end

-- Is one of the listed defensives ALREADY active? A tank who just pressed Shield Wall
-- does not need "Demoralizing Shout" shouted over it -- the next callout can wait for
-- the next buster.
--
-- Tracked from the combat log (playerAuraUp, populated in OnCombatLog below) rather
-- than polled from C_UnitAuras.GetPlayerAuraBySpellID -- that call carries
-- RequiresNonSecretAura, so it can return NOTHING for an aura the game has decided to
-- treat as secret, not just a secret expirationTime field on an otherwise-normal
-- table. Reported live on Mythic (secrecy tightens with difficulty): Ardent Defender
-- was genuinely up 5s+ and the callout fired anyway. Combat log aura events are not
-- gated the same way -- the same reasoning CheckAuraReminder's own aura trigger
-- already relies on for boss auras in restricted content.
--
-- No remaining-time threshold anymore either (the old COVERED_MIN_REMAINING >= 5s
-- check) -- there turns out to be no secret-safe way to read exactly how much is
-- left (confirmed against the aura/cooldown/curve API surface: every duration-typed
-- return can be secret, and arithmetic on a secret value throws, so nothing can
-- compare it to a threshold). A defensive genuinely up counts as covering outright,
-- matching the exp==0 "no clock" case the old check already trusted the same way.
local playerAuraUp = {}   -- [spellID] = true while up, per our own combat-log tracking

-- Last rung, and the only one that survives with no combat log at all. Registering
-- COMBAT_LOG_EVENT_UNFILTERED is only legal outside restricted content, so a session that
-- logs straight into an instance and never leaves has no aura tracking for its whole
-- length -- and that is exactly a raid night. UNIT_SPELLCAST_SUCCEEDED is unit-filtered to
-- the player, carries no identity read, and is never restricted, so "I pressed one of these
-- a moment ago" is answerable when "one of these is on me" is not.
--
-- A flat window rather than each defensive's real duration: the addon ships no class
-- knowledge by design, and a buff's length cannot be read before it exists. 6s is chosen to
-- be longer than the whole press-to-hit window (the callout leads the cast by 3s by
-- default, and a tank who pre-pops does so as the cast begins) while staying far short of
-- any real tank buster's cycle, so it cannot reach forward and silence the NEXT hit. That
-- direction matters more than covering every case: see ns.HandleBigWigsAbility.
local bigDefSeen = 0
-- The player's, because the right answer depends on how they play and the addon cannot see
-- enough to choose. Raising it to 10 covered Ardent Defender's own duration, after a call
-- named Divine Shield over one 7 seconds in -- and then swallowed the pull callout for a
-- tank who pre-pops Sentinel as the boss engages, twice on Ula'tek, because the hit landed
-- 5 seconds after the press. Both are the same window disagreeing about what a press meant.
-- Back to the 6 that shipped, with the setting for anyone who wants either edge.
local OWN_CAST_COVER_DEFAULT = 6
local ownCastAt = {}   -- [spellID] = GetTime() of our own last cast of it

-- The one question the client will still answer about an aura it has made secret.
-- Every by-spellID aura read carries RequiresNonSecretAura, so it returns NOTHING rather
-- than a secret -- that is deliberate on Blizzard's side and cannot be worked around from
-- that direction. C_UnitAuras.AuraIsBigDefensive is the exception: it accepts a SECRET
-- spellID (SecretArguments = "AllowedWhenTainted") and hands back a plain boolean, so
-- Blizzard's own classification of the aura crosses the boundary even when its identity
-- does not. AuraUtil.IsBigDefensive is Blizzard's cached wrapper around it.
--
-- Whether the ENUMERATION is allowed for us is the part the source cannot settle
-- (GetAuraDataByIndex is RequiresUnitAuraAccess). If it is refused, this throws or comes
-- back empty and the rungs below still answer -- hence the pcall and the plain false.
-- bigDefSeen counts successes so /nutank can say whether this path ever worked.
local function BigDefensiveUp()
    if not (AuraUtil and AuraUtil.IsBigDefensive
        and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
        return false
    end
    -- An unreadable entry is skipped, not treated as the end of the list. Stopping at the
    -- first non-table aborted the scan at whichever index the client had made secret, so a
    -- defensive sitting behind one was never reached -- and restricted content, where that
    -- happens, is the only place this rung is the one still answering. Only a plain nil ends
    -- the list. Reported live on Rav'i: Ardent Defender up 7 seconds and Divine Shield named
    -- over it.
    local ok, found = pcall(function()
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if type(aura) == "table" then
                if AuraUtil.IsBigDefensive(aura) == true then return true end
            elseif not (issecretvalue and issecretvalue(aura)) then
                return false
            end
        end
        return false
    end)
    if ok and found == true then
        bigDefSeen = bigDefSeen + 1
        return true
    end
    return false
end

-- Second and third returns name the covering spell and which rung answered. A skip is
-- otherwise completely invisible -- the callout simply does not happen, which looks
-- identical to the engine never firing at all, and that ambiguity has already cost a round
-- of guessing about whether this gate runs.
local function CoveredByActiveDefensive(fp, presetOverride)
    local now = GetTime()
    if BigDefensiveUp() then return true, nil, "bigdef" end
    local list = EffectiveList(specID, currentEncounter, fp, presetOverride) or {}
    local eligible = 0
    for i = 1, #list do
        local sid = list[i]
        if IsSpellAvailable(sid) and not IsSpellDisabled(sid) then
            eligible = eligible + 1
            if eligible > MAX_SLOTS then break end
            if playerAuraUp[sid] then return true, sid, "aura" end
            local window = TRDB().coveredCastWindow or OWN_CAST_COVER_DEFAULT
            if window > 0 and ownCastAt[ns.CooldownKey(sid)] and (now - ownCastAt[ns.CooldownKey(sid)]) < window then
                return true, sid, "cast"
            end
            -- Fallback for a buff that was already up before tracking could see it apply
            -- (addon just enabled, UI just reloaded, pre-popped before pull) -- existence
            -- only, not exact timing, same as playerAuraUp itself answers.
            if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
                local ok, exists = pcall(function()
                    return type(C_UnitAuras.GetPlayerAuraBySpellID(sid)) == "table"
                end)
                if ok and exists then return true, sid, "poll" end
            end
        end
    end
    return false
end


-- The engine gate (SetEventIconTextures, which paints a secret TankRole bit straight into
-- a texture's alpha) is no longer applied: ns.AbilityEnabledForBinding (checked in
-- FireBigWigsAbility, before anything fires) silences whole abilities upstream and covers
-- text and voice too, which the engine gate could never reach. It is still probed by
-- `canGate` and exercised by /nutank gate. What remains here is the unconditional clear,
-- so every event's art is left visible for the priority pick.
local function ClearTankGate()
    for i = 1, activeSlots do
        slots[i].icon:SetAlpha(1)
    end
    if bar then
        if bar.fill then bar.fill:SetAlpha(1) end
        if bar.bg then bar.bg:SetAlpha(1) end
    end
end

-------------------------------------------------------------------------------
--  Sound
-------------------------------------------------------------------------------
-- Sound is an ACTION, not a visual channel: there is no way to play one at alpha 0 and let
-- the engine decide, and no sound API anywhere accepts a secret argument. So the alpha trick
-- cannot carry it.
--
-- What CAN: C_EncounterEvents.SetEventSound registers a file against a static
-- encounterEventID, and the client plays it when that event highlights. The static records
-- (unlike the live timeline ones) carry NO secrecy at all, so their TankRole bit reads in the
-- clear and we can register against exactly the tank-flagged abilities.
--
-- The limit this leaves, and it is worth being honest about in the UI: the sound knows the
-- ability is a tank hit, but nothing can make it know whether YOUR defensive is ready. That
-- half is secret and there is no operator that joins the two. Sound says when; the icon and
-- bar say whether.
local soundError               -- surfaced on the options page; silence is the worst outcome

-- The engine keeps a registered sound until it is cleared, whatever happens to the setting
-- that asked for it, so every registration is tracked to be undone.
ns.soundEvents = {}
ns.soundGeneration = 0

function ns.ClearEventSounds()
    ns.soundGeneration = ns.soundGeneration + 1
    ns.soundFile = nil
    for id in pairs(ns.soundEvents) do
        pcall(C_EncounterEvents.SetEventSound, id,
            Enum.EncounterEventSoundTrigger.OnTimelineEventHighlight, nil)
        ns.soundEvents[id] = nil
    end
end

local function ResolveSoundFile()
    local key = TRDB().soundKey
    if not key or key == "none" then return nil end
    local value = ns.UI.SoundPathFor(key)
    -- SetEventSound wants a file asset. A SoundKitID (LSM hands out either) is not one, so
    -- a numeric entry is skipped rather than passed through and silently ignored.
    if type(value) == "string" then return value end
    return nil
end

-- Chunked: GetEventList is the whole encounter-event database, not the current pull, and
-- registering it in one pass is a login hitch nobody asked for.
-- MEASURED on a live boss, and worth recording because it cost five rounds of chasing
-- to establish: the engine plays a registered sound AT MOST ONCE PER ENCOUNTER.
--
-- It is not a registration problem. After a fight where the same ability cast twice and
-- sounded once, GetEventSound still returned our file for every sampled event, both casts
-- had highlighted, and re-registering between them -- including clearing before setting --
-- changed nothing. The engine simply will not replay it.
--
-- So this channel is a once-per-fight cue, not a per-cast one, and the tooltip says so.
-- The ICON is unaffected: SetEventIconTextures paints every time, which is why the icon
-- is the reliable per-cast signal and the sound is not.
--
-- Anything wanting a repeating, filtered, NAMED callout cannot be built on this API at
-- all. That needs the ability identified in Lua, and the only route to that is recording
-- a fight and matching on the plain ordinal and base duration.
local function RegisterEventSounds()
    soundError = nil
    ns.ClearEventSounds()
    if not (TRDB().enabled and TRDB().soundOn) then return end
    if ns.BossSource() ~= "timeline" then
        soundError = "Per-ability sounds ride the Blizzard timeline. Boss Addon is set to "
            .. "a boss mod, so they are off."
        return
    end
    if not canSound then
        soundError = "This client does not support per-ability sounds."
        return
    end

    -- There used to be a warning here that a registered sound will not play while
    -- encounterTimelineEnabled is 0. It has been removed because it is MEASURED FALSE:
    -- on a live boss with that CVar at 0, a registered sound played and the timeline
    -- events kept arriving throughout. The CVar gates Blizzard's own frame and nothing
    -- else.
    --
    -- It was also stale by construction. soundError is only recomputed when registration
    -- re-runs, so once shown it stayed on the page after the player turned the CVar on,
    -- which is how it came to be reported as wrong twice over.
    --
    -- The real limit of this channel is that the engine plays a registered sound at most
    -- once per encounter, and that is on the option's own tooltip where it belongs.

    local file = ResolveSoundFile()
    if not file then
        soundError = soundError or "Pick a sound file. Built-in game sounds cannot be used here."
        return
    end

    local ids = C_EncounterEvents.GetEventList()
    if not ids then
        soundError = "No encounter ability data available yet."
        return
    end

    local trigger = Enum.EncounterEventSoundTrigger.OnTimelineEventHighlight
    local mask = Enum.EncounterEventIconmask.TankRole

    -- Read here rather than captured at load: the data file is optional, and the feature
    -- has to work identically when it is absent.
    local curatedTank = ns.TANK_ABILITIES
    local sound = { file = file, volume = 1 }
    local i, total = 1, #ids
    local generation = ns.soundGeneration

    local function Step()
        -- A clear or a newer registration since this pass began supersedes it.
        if generation ~= ns.soundGeneration then return end
        -- Each step is a GetEventInfo (which hands back a fresh table) plus a pcall'd
        -- SetEventSound, against a catalogue of roughly 870 events, and this re-runs on
        -- ENCOUNTER_START under the healer opt-out, so whatever it costs lands on the
        -- pull. Both ends of the trade are real and neither is measured: 200 per frame
        -- was a visible hitch over 5 frames, and 50 stretched the registration to 18,
        -- which is ~0.3s at 60fps where an ability firing early in a pull has no sound
        -- registered yet. 100 splits it at ~9 frames. Measure both before moving it
        -- again; MeasureCall on one Step is enough to price a chunk.
        local stop = math.min(i + 99, total)
        while i <= stop do
            local info = C_EncounterEvents.GetEventInfo(ids[i])

            -- Blizzard's bit OR our own list. Measured against a live 870-event
            -- catalogue, the bit alone carries 13 of the 23 tank busters this season's
            -- pool has in that catalogue, so on its own it is correctly silent on nearly
            -- half of them -- which from the player's chair is indistinguishable from
            -- the feature being broken.
            --
            -- Additive deliberately: an ability neither source knows about is still
            -- handled the moment Blizzard flags it, with no update to this addon.
            local flagged = info and info.icons and bit.band(info.icons, mask) ~= 0
            local curated = info and info.spellID and curatedTank
                and curatedTank[info.spellID] ~= nil

            if (flagged or curated)
                and not ns.IsAbilityHealerFiltered(currentEncounter, info.spellID)
                and pcall(C_EncounterEvents.SetEventSound, ids[i], trigger, sound) then
                ns.soundEvents[ids[i]] = true
            end
            i = i + 1
        end
        if i <= total then C_Timer.After(0, Step) end
    end

    ns.soundFile = file
    Step()
end

-------------------------------------------------------------------------------
--  Self-tracked cooldowns (what lets the voice work in combat)
-------------------------------------------------------------------------------
-- The API's answer to "is this ready" is sealed in combat, but our OWN casts are not:
-- cast queries only go secret for units other than the player or their pet. So this watches
-- the player's UNIT_SPELLCAST_SUCCEEDED, writes down GetTime() + cooldown, and the voice
-- pick branches on numbers the addon wrote itself -- plain Lua, legal anywhere.
--
-- Three layers keep it honest, each covering what the previous cannot:
--   1. LEARNED totals. Base cooldowns do not include static talent reductions, so whenever a
--      cast happens while this spell's cooldown is readable, the real total is recorded (per
--      profile) and used instead of the base from then on -- including later, inside a key.
--   2. The PLAIN nil signal. Whether the API returns a duration object at all is not sealed,
--      only what is inside one -- and no object means no active cooldown. Every
--      SPELL_UPDATE_COOLDOWN re-checks it, so spender-driven reduction (the kind no table
--      can predict) corrects the model the moment a spell actually comes back.
--   3. Full resync whenever cooldowns are readable (out of combat; between raid pulls).
local readyAt = {}          -- [list spellID] = GetTime() at which it is back up

-------------------------------------------------------------------------------
--  Charges
-------------------------------------------------------------------------------
-- Real cooldowns for spells GetSpellBaseCooldown misreports, in seconds. Both models read
-- this: the plain-cooldown estimate treats it as the cooldown, and a charge spell treats it
-- as the per-charge recharge, which is what the tooltip figure means on a charge spell.
--
-- Only ever measured or authoritative numbers here, never a scaled guess -- the whole point
-- is to bypass an API that is not merely imprecise. It reports 0 for Divine Shield and 8
-- SECONDS for Guardian of Ancient Kings, whose real cooldown is three minutes; used as a
-- recharge rate that handed back a charge every 8 seconds and called the spell all fight.
--
-- Declared HERE, above the charge code rather than beside the cooldown model that used to
-- own it: a local declared later in the file is not an upvalue to a function defined
-- earlier, so referencing it from EnsureChargeState would have read a nil global and
-- silently done nothing.
-- Only a STARTING guess for the per-charge recharge, used until the client hands over the
-- real one: ChargesAvailable reads that from GetSpellChargeDuration the moment a recharge
-- is actually running, which needs no table and is right for every build. This is what
-- answers before the first recharge of a session. Deliberately the ability's full
-- cooldown rather than a shorter number observed on one build: talents move the real
-- figure, and one hardcoded value cannot be right for everyone. 180 sat here for
-- Guardian of Ancient Kings and handed a second charge back two minutes early on a build
-- that did not have that reduction -- the callout named a defensive that was visibly on
-- cooldown, reported live off Robin's stream on Kings Rest.
--
-- Too LONG is the safe direction here, unlike the bar dedupe: an understated charge count
-- makes the pick name a different defensive that IS up, which is a worse choice, not
-- silence. Too short names one that is down, which is worthless at the moment it matters.
local KNOWN_BASE_COOLDOWN = {
    [1966] = 15,      -- Feint: recharge fallback when charge duration is unavailable
    [642] = 300,      -- Divine Shield
    [86659] = 300,    -- Guardian of Ancient Kings
}

-- All readiness readers use the same key as player-cast accounting.
function ns.CooldownKey(sid)
    return ns.cooldownAliases and ns.cooldownAliases[sid] or sid
end

-- GetSpellCooldownDuration describes the COOLDOWN. A charge spell is gated by its
-- RECHARGE, which is a separate clock, and the two disagree in both directions:
--
--   * Holding 1 of 2 charges, a recharge IS running, so the cooldown accessor hands
--     back an object and the spell reads as unavailable while it is perfectly castable.
--   * At ZERO charges the spell cooldown is not running at all, so the accessor can hand
--     back nothing and the spell reads as ready when it is empty.
--
-- SpellChargeInfo marks exactly two fields NeverSecret, and they are the whole solution:
--   maxCharges -- is this a charge spell, and how many
--   isActive   -- FALSE means not recharging, which means AT MAXIMUM
--
-- currentCharges is NOT among them, so the count is never readable in a key and is
-- tracked from the player's own casts, which are always plain. `isActive` going false is
-- then a free correction back to full.
local chargeState = {}
local chargeMemory = {} -- Same live counter, retained across temporary shape loss.

-- Bounded transition evidence is recorded even without trace. Never store raw
-- API fields here: these are the model's already-classified plain values.
function ns.RecordChargeTransition(sid, reason, before, tick, st)
    if reason ~= "own cast" and before == st.count
        and (tick == st.tick or st.count == st.max) then return end
    local t = TRDB()
    if type(t.chargeAudit) ~= "table" then t.chargeAudit = {} end
    local log = t.chargeAudit
    log[#log + 1] = {
        stamp = date and date("%H:%M:%S") or "?", build = ns.CODE_BUILD,
        sid = sid, reason = reason, before = before, after = st.count,
        oldTick = tick, tick = st.tick, at = GetTime(), recharge = st.recharge,
        source = st.rechargeSrc,
    }
    while #log > 80 do table.remove(log, 1) end
end

function ns.AppendChargeAudit(out)
    local log = TRDB().chargeAudit
    if type(log) ~= "table" then return end
    out[#out + 1] = "Charge model transitions (automatic, last 80):"
    for i = 1, #log do
        local e = log[i]
        out[#out + 1] = ("%s build=%s spell=%d %s: %s -> %d, anchor age %.1f -> %.1f, recharge %.1f (%s)"):format(
            e.stamp, tostring(e.build), e.sid, e.reason, tostring(e.before), e.after,
            e.at - (e.oldTick or e.at), e.at - e.tick, e.recharge, tostring(e.source))
    end
end

-- Defined below with the rest of the cooldown reads; forward-declared because the charge
-- model needs it and sits above it. It answers the one question the charge fields cannot:
-- isActive says a charge is missing, never how many.
local CooldownRunning

-- Third return is whether the read is trustworthy at all -- false means the API call or
-- the field read itself failed (missing API, a thrown pcall), as opposed to a valid read
-- that CONFIRMS max < 2. The distinction matters to the caller: a spell that genuinely
-- lost its second charge (a talent swap) should wipe the tracked count, but a spell that
-- simply could not be read THIS one time must not -- see EnsureChargeState.
local function ReadChargeShape(sid)
    if not (C_Spell and C_Spell.GetSpellCharges) then return nil, nil, false end

    local ok, info = pcall(C_Spell.GetSpellCharges, sid)
    if not ok or type(info) ~= "table" then return nil, nil, false end

    -- The two plain fields are read behind their own pcall. The rest of this struct is
    -- secret in restricted content and a wrong field raises rather than returning nil.
    local got, max, active = pcall(function() return info.maxCharges, info.isActive end)
    if not got then return nil, nil, false end
    if type(max) ~= "number" or max < 2 then return nil, nil, true end

    return max, active == true, true
end

-- The real per-charge recharge, from the client, for THIS character and THIS build.
--
-- C_Spell.GetSpellChargeDuration hands back a LuaDurationObject describing the ACTIVE
-- recharge, and unlike GetSpellCharges it carries no SecretWhenCooldownsRestricted --
-- nor do the duration object's own getters, which are annotated only on their arguments.
-- So the one number the charge model could never obtain is readable after all, and the
-- addon was modelling around a gap that had an API the whole time. Its sibling
-- GetSpellCooldownDuration was already trusted for the non-charge path here; the charge
-- path simply never got the same treatment.
--
-- MayReturnNothing: at full charges there is no active recharge to describe, so this only
-- answers while one is running. That is exactly when it is needed and the value is cached.
-- GetSpellChargeDuration appears nowhere in Blizzard's own UI, so it is the less proven of
-- the two. While exactly one charge is out a recharge IS running and the cooldown accessor
-- describes it, and that one the non-charge path here has trusted all along -- so it stands
-- in when the charge-specific call declines to answer. Neither is derived from isActive,
-- which is the whole point: the seeded rate cannot be right for every build, and a
-- protection paladin's Guardian of Ancient Kings recharges in 180s against a 300s seed.
-- Indexed without a type check, the same way the cooldown path already treats the object
-- GetSpellCooldownDuration returns: a duration object is not necessarily a Lua table, and
-- demanding one would reject every real answer.
--
-- GetRemainingDuration is annotated exactly as GetTotalDuration is, so the client will also
-- say how far through the running recharge it is. That fixes the anchor as well as the
-- rate: the climb counts from st.tick, and without this the tick can only be the moment the
-- addon happened to witness the drop from maximum. A spell first seen mid-recharge -- a
-- cast before login, or before the first callout of the session -- anchored a full recharge
-- late and read as empty while a charge was up.
local function ReadDurationObject(fn, ...)
    if not fn then return nil end
    local ok, dur = pcall(fn, ...)
    if not ok or not dur then return nil end
    local got, total = pcall(function() return dur:GetTotalDuration() end)
    if not got or (issecretvalue and issecretvalue(total)) then return nil end
    if type(total) ~= "number" or total <= 1.5 then return nil end

    local okRem, remaining = pcall(function() return dur:GetRemainingDuration() end)
    if not okRem or (issecretvalue and issecretvalue(remaining)) then return total end
    if type(remaining) ~= "number" or remaining < 0 or remaining > total then return total end
    return total, remaining
end

-- The COOLDOWN stand-in takes the seed floor, the same one EnsureChargeState applies and
-- for the same reason: it describes a different clock. Guardian of Ancient Kings reads 8
-- seconds there against a ~180s recharge, and unfloored that 8 reached st.recharge
-- through both callers -- persisted as clientRecharge, which EnsureChargeState prefers
-- ahead of the seed, so it survived the reload too. The climb then handed a charge back
-- every 8 seconds and the pick named the spell all fight with none in hand. Reported live
-- on The Coiled Altar; /nutank cds read "recharge 8s".
--
-- Floored rather than rejected: the same call returns the real recharge while one is
-- running, and Guardian's 180s is under its own 300s seed, so a rejection would throw
-- away the true figure along with the false one. Too long costs silence about a spell
-- that is up; too short calls one that is down.
--
-- GetSpellChargeDuration describes the recharge itself, so it is taken as it comes.
local function ReadChargeRecharge(sid)
    if not C_Spell then return nil end
    local total, remaining = ReadDurationObject(C_Spell.GetSpellChargeDuration, sid)
    if total then return total, remaining end
    total, remaining = ReadDurationObject(C_Spell.GetSpellCooldownDuration, sid, true)
    if not total then return nil end
    local seed = KNOWN_BASE_COOLDOWN[sid] or 0
    -- remaining goes with the reading it came from: it anchors rechargeStart, and pairing
    -- 3 seconds left with a 300 second total puts that anchor five minutes in the past and
    -- reads as several charge landings at once.
    -- Third return says the figure is the seed standing in, not something the client
    -- stated. clientRecharge means "the client said so" and EnsureChargeState prefers it
    -- ahead of the seed floor for exactly that reason, so a floored value written there
    -- would round a real 180s recharge up to its 300s seed permanently, across reloads --
    -- the regression clientRecharge exists to prevent.
    if total < seed then return seed, nil, true end
    return total, remaining, false
end

function EnsureChargeState(sid)
    sid = ns.CooldownKey(sid)
    local max, active, ok = ReadChargeShape(sid)
    if not ok then
        -- The read itself failed -- keep whatever is already tracked rather than guessing.
        -- Wiping here on a single dropped read was the bug: the very next successful read
        -- re-establishes a FRESH state at full charges, so a spell that had just spent its
        -- last charge would read as ready again the moment one read hiccuped.
        return chargeState[sid]
    end
    if not max then
        -- A confirmed read says this is not (or is no longer) a charge spell.
        chargeState[sid] = nil
        return nil
    end

    local st = chargeState[sid]
    if not st then
        local retained = chargeMemory[sid]
        if retained and retained.witnessed then
            st = retained
            chargeState[sid] = st
            ns.RecordChargeTransition(sid, "restore", nil, nil, st)
        end
    end
    if st and st.max ~= max then
        local before, oldTick = st.count, st.tick
        -- A larger maximum is not evidence that new charges are available. If
        -- the old stack was full, its idle clock cannot earn the new charge.
        if st.count == st.max and max > st.max then
            st.tick, st.rechargeStart = GetTime(), nil
        end
        st.max, st.count = max, math.min(st.count, max)
        ns.RecordChargeTransition(sid, "shape change", before, oldTick, st)
    end
    if not st then
        -- MEASURED: GetSpellBaseCooldown reports 8 seconds for Guardian of Ancient Kings,
        -- whose real cooldown is five minutes. Used as a recharge rate that regenerates a
        -- charge every 8 seconds, so spending both charges put the model back at full
        -- inside twenty seconds and it called the spell for the rest of the pull. The
        -- number is not merely imprecise here, it is wrong by a factor of forty, and it is
        -- the ONLY input that can invent a charge the player does not have. So it is not
        -- used for charge spells at all: either the recharge has been measured from a
        -- readable cooldown, or there is no climb.
        local t = TRDB()
        local learned = type(t.learned) == "table" and t.learned[tostring(sid)] or nil
        -- Feint's legacy inactive-flag measurement captured time between observations
        -- (334s in the reporter's log), not its recharge. Use its known base instead.
        -- Client-reported charge durations still take precedence below and on refresh.
        if sid == 1966 then learned = nil end
        -- Kept apart from `learned` because the seed floor below must not touch it. The
        -- floor exists for figures measured off isActive, which lies for a talent-granted
        -- extra charge; a number the client stated outright is not that, and floors were
        -- silently discarding it. Guardian of Ancient Kings recharges in 180s for a
        -- protection paladin against a 300s seed, so every rebuild of this state threw the
        -- real figure away and put the count two minutes behind -- the callout then named
        -- Divine Shield with a charge in hand, twice in one Kings Rest key.
        local fromClient = type(t.clientRecharge) == "table" and t.clientRecharge[tostring(sid)] or nil
        st = {
            -- currentCharges is secret, so a spell seen for the first time cannot be read
            -- directly -- but isActive (a charge recharging right now) is plain, and it was
            -- being discarded here. Assuming a full stack regardless was the bug: a spell
            -- already on cooldown before this pull, or before the addon got a chance to see
            -- it, kept reading as fully charged for the rest of the session.
            --
            -- isActive only says "at least one charge missing," never how many. Guessing
            -- max-1 was tried and is still wrong whenever more than one is actually missing
            -- -- still a false ready, just a smaller one. Zero is the only guess with no way
            -- to be an overcount: the recharge math below counts back up from there on its
            -- own, so an undercount here costs a few seconds of silence instead of a false
            -- callout for a defensive still on cooldown.
            max = max, count = (active or ReadChargeRecharge(sid) ~= nil) and 0 or max, tick = GetTime(),
            -- Zero means no climb at all, which is a complete answer rather than a
            -- degraded one: the count still falls on every witnessed cast, and
            -- ChargesAvailable still snaps it back to full the moment isActive reports
            -- nothing recharging. What is lost is only the middle of the stack -- holding
            -- 1 of 2 reads as 0 until the last charge lands -- and that is silence about a
            -- spell that is up, never a call for one that is down.
            -- The larger of the two, not the learned one outright. Learned values for
            -- charge spells were measured off isActive, which lies for a talent-granted
            -- extra charge, so a stored figure BELOW the ability's real cooldown is more
            -- likely that lie than a genuine talent reduction -- and it hands back a
            -- charge that is not there. The seed is a floor for the spells it names;
            -- everything else still takes the measurement, which is all it has.
            recharge = fromClient or math.max(learned or 0, KNOWN_BASE_COOLDOWN[sid] or 0),
            -- Where that number came from, for /nutank cds. A wrong recharge is invisible
            -- from the callout itself -- it just names a spell that is down -- so the
            -- source has to be readable directly rather than inferred from behaviour.
            rechargeSrc = fromClient and "client"
                or (math.max(learned or 0, KNOWN_BASE_COOLDOWN[sid] or 0) <= 0
                and "none")
                or ((learned or 0) >= (KNOWN_BASE_COOLDOWN[sid] or 0) and "learned" or "seed"),
        }
        chargeState[sid], chargeMemory[sid] = st, st
        ns.RecordChargeTransition(sid, "initialize", nil, nil, st)
    end
    return st
end

function ChargesAvailable(sid)
    sid = ns.CooldownKey(sid)
    local st = chargeState[sid]
    if not st then return nil end
    local before, oldTick = st.count, st.tick

    local max, active = ReadChargeShape(sid)

    -- A running recharge is the client telling us the real rate outright, so take it over
    -- anything seeded or measured. Persisted because it can only be read WHILE recharging,
    -- and the pick has to answer between pulls too.
    --
    -- Read WITHOUT consulting isActive first. GetSpellCharges is SecretWhenCooldownsRestricted
    -- and in a real key it declines outright, so `active` comes back nil there and gating on
    -- it skipped this read exactly where it was needed -- the rate stayed at the 300s seed
    -- while GetSpellChargeDuration, which carries no such restriction, would have answered
    -- 180. That is the whole Kings Rest failure: at a dummy the sealed accessor answers and
    -- the rate is right, in the key it does not and the count runs two minutes behind.
    -- An answer here also PROVES a recharge is running, so it stands in for isActive.
    local real, remaining, floored = ReadChargeRecharge(sid)
    if real then
        active = true
        st.recharge, st.rechargeSrc = real, floored and "seed" or "client"
        if not floored then
            local t = TRDB()
            if type(t.clientRecharge) ~= "table" then t.clientRecharge = {} end
            t.clientRecharge[tostring(sid)] = real
        end
        -- A charge landing IS the client's recharge start jumping forward by one recharge,
        -- and that is a far better signal than the elapsed-time climb below: it needs no
        -- anchor of our own and no witnessed cast, so a state rebuilt mid-fight recovers on
        -- the next landing instead of guessing.
        --
        -- This replaces re-anchoring st.tick while the count sat at zero. That was written
        -- to fix a rebuilt state's anchor and did the opposite: zero is exactly when the
        -- climb has to run, so moving the anchor to the running recharge's start on every
        -- read held `gained` at zero forever and pinned the count. Live capture, Rav'i
        -- 15:26:54 -- Divine Shield named on 0/2 with a charge in hand two seconds later.
        if remaining then
            local start = GetTime() - (real - remaining)
            if st.rechargeStart then
                local landed = math.floor((start - st.rechargeStart) / real + 0.5)
                if landed > 0 then st.count = math.min(st.max, st.count + landed) end
            end
            st.rechargeStart = start
            -- Kept in step so the elapsed-time climb stays quiet while the client is
            -- answering, and picks up from the right place if it stops.
            st.tick = start
        end
    end

    -- currentCharges is secret only while cooldowns are restricted. Everywhere else it is
    -- the answer outright, and it was never read: the model could drift on a press made
    -- while the cast watcher was unregistered and had nothing to correct against for the
    -- rest of the session. Placed after the recharge learning above so that still runs,
    -- and returned immediately because nothing below improves on a stated count.
    if CanNameSpellAloud(sid) then
        local okCur, cur = pcall(function() return C_Spell.GetSpellCharges(sid).currentCharges end)
        if okCur and not (issecretvalue and issecretvalue(cur))
            and type(cur) == "number" and cur >= 0 and cur <= st.max then
            -- A readable count already includes completed recharges. Consume those
            -- intervals before returning, or NoteOwnCast/the next sealed read credits
            -- the same landing again. Preserve a readable remaining-duration anchor.
            if not remaining and st.recharge > 0 and cur < st.max then
                local now = GetTime()
                local elapsed = math.max(0, math.floor((now - st.tick) / st.recharge))
                if cur > st.count and elapsed < cur - st.count then
                    -- An early refill/reset has no known recharge phase. Start a
                    -- conservative new interval; do not invent the next charge.
                    st.tick, st.rechargeStart = now, nil
                elseif elapsed > 0 then
                    local advance = elapsed * st.recharge
                    st.tick = st.tick + advance
                    if st.rechargeStart then st.rechargeStart = st.rechargeStart + advance end
                end
            end
            -- The climb re-anchors on a correction downward: the count is known as of now.
            if cur < st.count then st.tick = GetTime() end
            st.count, st.witnessed = cur, true
            if cur == st.max then
                st.tick, st.missingSince, st.rechargeStart = GetTime(), nil, nil
            end
            ns.RecordChargeTransition(sid, "readable count", before, oldTick, st)
            return st.count
        end
    end

    -- An inactive flag does not prove that every charge is back. With two
    -- charges missing, one elapsed recharge can restore only one. Let the
    -- clock below advance by the actual number of intervals; only a readable
    -- currentCharges result above can replace that count outright. Do not
    -- learn a recharge duration from this ambiguous flag either.

    if st.recharge > 0 and st.count < st.max then
        local gained = math.floor((GetTime() - st.tick) / st.recharge)
        if gained > 0 then
            st.count = math.min(st.max, st.count + gained)
            st.tick  = st.tick + gained * st.recharge
            -- Mark inferred landings as consumed before the duration API
            -- reports them again after a missed read.
            if st.rechargeStart then
                st.rechargeStart = st.rechargeStart + gained * st.recharge
            end
        end
    end

    -- No optimistic floor here, deliberately. One used to raise a guessed count to max-1,
    -- because isActive proves at least one charge is out and on a two-charge spell that
    -- was read as "the other one is up" -- but isActive says the same thing when BOTH are
    -- out, so it claimed a charge that did not exist and called a defensive that was down.
    --
    -- It existed only because a guessed count could not recover: with `recharge <= 0`
    -- there is no climb, so the pessimistic zero stood for the rest of the run and a held
    -- Guardian of Ancient Kings lost the pick to "call for external" on Xathuux. The
    -- client's own recharge (ReadChargeRecharge) removes that condition -- it answers
    -- precisely when a recharge is running, which is exactly when the count is guessed --
    -- so zero now climbs back on its own and the floor has nothing left to fix.
    --
    -- Where no rate can be had at all, zero stands, and that is the right answer: the
    -- count is genuinely unknown, and for charges an undercount names a DIFFERENT
    -- defensive that is up rather than one that is down.

    -- isActive is plain and exact, and it was only ever read in the one direction above.
    -- Read the other way it is a hard ceiling: something is recharging, so the stack CANNOT
    -- be full, whatever the model believes. Catches an over-count from any source -- a
    -- missed cast, a stale learned recharge, a talent swap mid-fight -- not just the base
    -- cooldown that produced this one.
    if active and st.count >= st.max then
        st.count = st.max - 1
    end

    -- An inactive cooldown does not establish an available charge. Keep a
    -- tracked empty stack empty until the recharge model or a readable count
    -- above restores it; a fallback floor here bypassed the recharge deadline.
    ns.RecordChargeTransition(sid, "reconcile", before, oldTick, st)
    return st.count
end
local castToBase = {}       -- cast-time override id -> the id the list stores

-- Track all configured spells, not just the preset currently drawn. Boss abilities
-- and custom reminders can select another preset without rebuilding the display's
-- cast map, and a spell may be pressed before its first warning of the pull.
ns.trackedCooldownSpells = {}
local function RebuildCastMap()
    local aliases, configured = {}, {}
    local function Root(sid)
        while aliases[sid] and aliases[sid] ~= sid do sid = aliases[sid] end
        return sid
    end
    local function Add(sid)
        if type(sid) ~= "number" or sid <= 0 or configured[sid] then return end
        configured[sid] = true
        aliases[sid] = aliases[sid] or sid
        if C_Spell and C_Spell.GetOverrideSpell then
            local ok, ov = pcall(C_Spell.GetOverrideSpell, sid)
            if ok and not (issecretvalue and issecretvalue(ov))
                and type(ov) == "number" and ov > 0 and ov ~= sid then
                aliases[ov] = aliases[ov] or ov
                local base, replacement = Root(sid), Root(ov)
                if base ~= replacement then aliases[replacement] = base end
            end
        end
    end
    local function AddList(list)
        if type(list) ~= "table" then return end
        for i = 1, #list do Add(list[i]) end
    end
    for i = 1, activeSlots do Add(slots[i].spellID) end
    local presets = PresetsTable(specID, false)
    if presets then
        for _, preset in pairs(presets) do
            if type(preset) == "table" then AddList(preset.list) end
        end
    end
    -- Older per-boss/per-ability lists still participate in EffectiveList.
    local legacy = TRDB().bossLists
    if type(legacy) == "table" then
        local prefix = tostring(specID) .. ":"
        for key, list in pairs(legacy) do
            if type(key) == "string" and key:sub(1, #prefix) == prefix then AddList(list) end
        end
    end

    -- Finish discovering aliases before seeding or sampling any state. Otherwise
    -- preset iteration order can create two independent counters for one ability.
    local merged, deadlines, casts, roots = {}, {}, {}, {}
    for sid in pairs(aliases) do
        local root = Root(sid)
        roots[sid] = root
        local previous = castToBase[sid] or sid
        local state = chargeState[previous]
        local retained = chargeMemory[previous]
        if not state and retained and retained.witnessed then state = retained end
        local kept = merged[root]
        -- Existing counters may already disagree. Keep the lower count (and the
        -- later anchor on a tie); a readable client count can correct it afterward.
        if state and (not kept or state.count < kept.count
            or (state.count == kept.count and state.tick > kept.tick)) then
            merged[root] = state
        end
        if readyAt[previous] then
            deadlines[root] = math.max(deadlines[root] or 0, readyAt[previous])
        end
        if ownCastAt[previous] then
            casts[root] = math.max(casts[root] or 0, ownCastAt[previous])
        end
    end
    wipe(castToBase)
    wipe(ns.trackedCooldownSpells)
    for sid, root in pairs(roots) do castToBase[sid] = root end
    ns.cooldownAliases = castToBase
    for sid, root in pairs(roots) do
        if sid == root then
            if merged[root] then
                chargeState[root], chargeMemory[root] = merged[root], merged[root]
            end
            readyAt[root], ownCastAt[root] = deadlines[root], casts[root]
            ns.trackedCooldownSpells[#ns.trackedCooldownSpells + 1] = root
        end
    end
    for i = 1, #ns.trackedCooldownSpells do
        local sid = ns.trackedCooldownSpells[i]
        pcall(EnsureChargeState, sid)
        pcall(ChargesAvailable, sid)
    end
end

-- Every actual cast or callout for a tracked defensive is appended here, capped and
-- persisted, so a bad call ("it said X was ready right after I used X") can be checked
-- against what actually happened instead of relying on memory mid-fight.
-- 30 is enough to read back a bad pull in chat. A trace covers a whole key, so it keeps
-- far more -- still capped, because this lives in SavedVariables and an uncapped list
-- would grow without bound on a long session.
function AppendLog(entry)
    local CALL_LOG_MAX, TRACE_LOG_MAX = 30, 600
    local t = TRDB()
    if type(t.callLog) ~= "table" then t.callLog = {} end
    local log = t.callLog
    entry.stamp = date and date("%H:%M:%S") or "?"
    entry.enc, entry.stage = currentEncounter, currentStage
    log[#log + 1] = entry
    local cap = t.trace and TRACE_LOG_MAX or CALL_LOG_MAX
    while #log > cap do table.remove(log, 1) end
end

-- One renderer for both /nutank calls and the export, so a line never says two different
-- things depending on where it is read. Plain text: the export has to survive a paste.
local function LogLine(e)
    local function nameOf(id)
        local info = id and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        return (info and info.name) or tostring(id)
    end
    local head = ("%s enc=%s stage=%s"):format(e.stamp, tostring(e.enc), tostring(e.stage))
    if e.kind == "cast" then
        return head .. " -- CAST " .. nameOf(e.sid)
    elseif e.kind == "enc" then
        return head .. " -- ENCOUNTER " .. tostring(e.text)
    elseif e.kind == "key" then
        return ("%s -- KEY %s %s (%s/%s)"):format(head, tostring(e.sid), nameOf(e.sid),
            tostring(e.mod), tostring(e.tankPath))
    elseif e.kind == "quiet" then
        return ("%s -- icon-only for %s (voice repeat-muted, trigger %s)"):format(head,
            nameOf(e.sid), nameOf(e.tankSid))
    elseif e.kind == "drop" then
        return ("%s -- dropped broadcast for %s (%s)"):format(head, nameOf(e.sid),
            tostring(e.text))
    elseif e.kind == "bosscast" then
        return ("%s -- BOSS CAST %s on %s (%s)"):format(head,
            e.sid and nameOf(e.sid) or "secret id", tostring(e.unit), e.text or "?")
    elseif e.kind == "aside" then
        return head .. " -- " .. nameOf(e.sid) .. " stepped aside to its Ability Reminder"
    elseif e.kind == "cancel" then
        return ("%s -- cancelled pending callout for %s (bar '%s' stopped early)"):format(
            head, nameOf(e.sid), tostring(e.text))
    elseif e.kind == "schedule" then
        return ("%s -- SCHEDULE %s bar='%s' duration=%.1f approx=%s delay=%.1f%s"):format(
            head, nameOf(e.sid), tostring(e.text), e.duration, tostring(e.isApprox), e.delay,
            e.existingFireIn and (" (replaced one %.1fs out)"):format(e.existingFireIn) or "")
    elseif e.kind == "aggro" then
        return ("%s -- BLOCKED %s -- not tanking the caster (%s) -- %s"):format(head,
            nameOf(e.sid), tostring(e.tankPath), tostring(e.text))
    elseif e.kind == "skip" then
        return ("%s -- skipped %s -- already covered by %s (%s)"):format(head,
            nameOf(e.tankSid), nameOf(e.sid), tostring(e.tankPath))
    end
    return ("%s -- %s %s -- running=%s%s readyIn=%s secrecy=%s%s%s"):format(head,
        e.kind == "test" and "TEST-called" or "called", nameOf(e.sid),
        tostring(e.running), e.charges and (" charges=" .. e.charges) or "",
        e.readyAtDelta and ("%.1fs"):format(e.readyAtDelta) or "n/a", tostring(e.secrecy),
        e.tankPath and (" tankCheck=%s(%s)"):format(e.tankPath, nameOf(e.tankSid)) or "",
        (e.castTracked ~= nil and (" castTracked=" .. tostring(e.castTracked)) or "")
            .. (e.lastOwnCastAgo and (" lastCast=%.1fs ago"):format(e.lastOwnCastAgo) or "")
            .. (e.withSids and (" with=" .. e.withSids) or "")
            .. (e.auraUp and (" auraUp=" .. e.auraUp) or "")
            .. (e.chargeModel and ("\n    charges: " .. e.chargeModel) or ""))
end

local function NoteOwnCast(castSpellID)
    local sid = castSpellID and castToBase[castSpellID]
    if not sid then return end
    AppendLog({ kind = "cast", sid = sid })
    ownCastAt[sid] = GetTime()

    -- A charge spell never touches readyAt: a cast spends a charge, and holding one is
    -- what makes it available, not the absence of a timer. Established here too, not only
    -- from ResyncModel/ApplyPriorityAlpha: a charge spell's very first cast of a session,
    -- before either of those has run for it yet, would otherwise fall through to the
    -- readyAt/base-cooldown model below and get tracked by the wrong clock entirely.
    EnsureChargeState(sid)
    local st = chargeState[sid]
    local retained = chargeMemory[sid]
    if not st and retained and retained.witnessed then st = retained end
    if st then
        local before, oldTick = st.count, st.tick
        -- Spend from the previously tracked count. Sampling the post-cast
        -- state first can already remove a charge (the active ceiling or an
        -- exact count), so subtracting again would charge this cast twice.
        -- Advance only the elapsed clock here; normal reads reconcile later.
        if st.recharge > 0 and st.count < st.max then
            local gained = math.floor((GetTime() - st.tick) / st.recharge)
            if gained > 0 then
                st.count = math.min(st.max, st.count + gained)
                st.tick = st.tick + gained * st.recharge
                if st.rechargeStart then
                    st.rechargeStart = st.rechargeStart + gained * st.recharge
                end
            end
        end
        -- The recharge clock starts on the drop FROM maximum. Restarting it on every
        -- cast would push the next charge further away each time one was spent.
        -- missingSince marks the same moment for the measurement in ChargesAvailable:
        -- this cast is what put the stack below full, so the run back up starts here.
        -- A successful cast at zero spent a landing our estimate has not seen.
        -- Retire that pending landing instead of granting it after the cast.
        -- A readable recharge/count can refine this conservative baseline later.
        if st.count >= st.max or st.count == 0 then
            st.tick = GetTime()
            st.missingSince = GetTime()
            -- This cast starts a fresh recharge, so the next read establishes its own
            -- baseline rather than reading the gap since an older one as landings.
            st.rechargeStart = nil
        end
        st.count = math.max(0, st.count - 1)
        st.witnessed = true
        ns.RecordChargeTransition(sid, "own cast", before, oldTick, st)
        -- A missing charge shape still needs the single-cooldown deadline below,
        -- but its cast must also spend from the retained charge counter.
        if chargeState[sid] then return end
    end

    -- Learned beats base: a previously observed real total already includes every static
    -- talent reduction, which the base number never does.
    local t = TRDB()
    local learned = type(t.learned) == "table" and t.learned[tostring(sid)] or nil
    local baseMs = GetSpellBaseCooldown and GetSpellBaseCooldown(sid)
    -- A cast whose length we cannot determine STILL put the spell on cooldown. Leaving
    -- readyAt untouched left it reading as available forever, so a defensive that had
    -- just been pressed kept being called for: GetSpellBaseCooldown reports 0 for plenty
    -- of spells whose cooldown comes from a talent or an aura, and Divine Shield is one.
    --
    -- The placeholder only has to be wrong in the safe direction. ResyncModel clears it
    -- the moment the cooldown object disappears, so an over-long guess costs nothing and
    -- an absent one costs a wrong callout.
    local UNKNOWN_COOLDOWN = 30

    local secs
    if learned then
        secs = learned
    elseif KNOWN_BASE_COOLDOWN[sid] then
        secs = KNOWN_BASE_COOLDOWN[sid]
    elseif type(baseMs) == "number" and baseMs > 0 then
        -- An UPPER bound, not a measurement. GetSpellBaseCooldown ignores talent cooldown
        -- reduction -- Unbreakable Spirit alone takes 30% off Ardent Defender and Divine
        -- Shield -- and it appears nowhere in Blizzard's current UI source or generated
        -- docs, so nothing keeps it honest. Held at full length while cooldowns are sealed
        -- it cannot self-correct (see ResyncSpell: the free correction needs a nil the API
        -- almost never returns), so it keeps a defensive marked down long after it is back
        -- and the callout falls through to "call for external" with two defensives up.
        -- Trimmed by the largest common tank reduction so the residual error lands on the
        -- side this file already documents as the cheaper one -- naming a defensive that
        -- turns out to be down beats staying silent when one was available. A learned
        -- total, once measured, replaces this outright.
        secs = (baseMs / 1000) * 0.7
    else
        secs = UNKNOWN_COOLDOWN
    end
    readyAt[sid] = GetTime() + secs

    -- And when the cooldown this cast just started is readable, record its real total for
    -- every future cast -- the learning half of layer 1 above. The 1.5s floor keeps a
    -- GCD-length reading from ever overwriting a real cooldown.
    if CanNameSpellAloud(sid) then
        local ok, total = pcall(function()
            local dur = C_Spell.GetSpellCooldownDuration(sid, true)
            return (dur and dur.GetTotalDuration and dur:GetTotalDuration()) or nil
        end)
        if ok and type(total) == "number" and total > 1.5 then
            if type(t.learned) ~= "table" then t.learned = {} end
            t.learned[tostring(sid)] = total
            readyAt[sid] = GetTime() + total
        end
    end
end

-- These three hang off ns rather than being file locals: this chunk peaks against Lua's
-- 200-local ceiling around line 5700, and going over stops the whole file compiling.
--
-- Hoisted out of ResyncSpell, where it was an anonymous function under pcall, so a fresh
-- closure was built for every tracked spell on every cooldown event.
function ns.ReadPlainCooldown(dur)
    -- Nothing back means nothing running, so zero remaining.
    if not dur or not dur.GetRemainingDuration then return 0 end
    return dur:GetRemainingDuration() or 0,
        (dur.GetTotalDuration and dur:GetTotalDuration()) or nil
end

ns.sidKeys = {}

-- The measured total is the same number on almost every pass, and writing it back each
-- time dirtied SavedVariables and built a fresh key string for nothing.
function ns.LearnTotal(sid, total)
    local key = ns.sidKeys[sid]
    if not key then key = tostring(sid); ns.sidKeys[sid] = key end
    local t = TRDB()
    if type(t.learned) ~= "table" then t.learned = {} end
    if t.learned[key] ~= total then t.learned[key] = total end
end

local function ResyncSpell(sid)
    sid = ns.CooldownKey(sid)
    -- Re-read the shape every pass. A talent swap can add or remove charges, and a
    -- stale shape is what makes the model confidently wrong rather than absent.
    EnsureChargeState(sid)

    -- Everything below is the plain-cooldown model, which says nothing useful about
    -- a charge spell: it holds a running recharge while still being castable.
    local cs = chargeState[sid]
    if cs then
        -- One thing here IS worth reading for a charge spell: the real recharge time, so
        -- the count climbs back up off that figure rather than a base-derived guess that
        -- is too short and resurrects charges the player never got back. Learned into the
        -- same store the cooldown model uses, so it survives the reload that wipes
        -- chargeState. Through ReadChargeRecharge for the seed floor it applies -- this
        -- read is where Guardian of Ancient Kings' 8 second cooldown got in.
        local total = ReadChargeRecharge(sid)
        if total then
            cs.recharge, cs.rechargeSrc = total, "learned"
            ns.LearnTotal(sid, total)
        end
        return
    end

    -- Free correction, available even in restricted content: no duration object means no
    -- active cooldown, so whatever the estimate believed is wrong and the spell is up.
    -- This is what keeps the model from drifting through a fight as talent and resource
    -- cooldown reductions shorten things it thinks are still running.
    local live = C_Spell.GetSpellCooldownDuration(sid, true)
    if not live then readyAt[sid] = 0 end

    -- Only while the predicate says this spell's cooldown reads plainly; the pcall is
    -- belt and braces against the classification changing under us mid-read.
    if CanNameSpellAloud(sid) then
        -- Reuses the object read for `live` above rather than asking again; that call is
        -- already made unprotected on the same line, so nothing is newly exposed.
        local ok, rem, total = pcall(ns.ReadPlainCooldown, live)
        if ok and type(rem) == "number" then
            readyAt[sid] = GetTime() + math.max(0, rem)
        end

        -- A cooldown still running while this reads plainly IS the real total, talent
        -- reductions and all. Captured here and not only at cast time: the cast almost
        -- always happens inside an instance where this is sealed, while the tail of that
        -- same cooldown is usually still running once the player is back outside, which
        -- makes this a free measurement of a number the estimate can only guess at.
        -- The 1.5s floor keeps a GCD-length reading from overwriting a real cooldown.
        if ok and type(total) == "number" and total > 1.5 then
            ns.LearnTotal(sid, total)
        end
    end
end

local function ResyncModel()
    for i = 1, #ns.trackedCooldownSpells do
        ResyncSpell(ns.trackedCooldownSpells[i])
    end
end

-- SPELL_UPDATE_COOLDOWN arrives in bursts -- several in one frame off a single cast --
-- and each one re-reads every tracked spell. One pass per frame instead. Nothing consumes
-- the model faster than it is drawn, and the spec-change and login callers below still
-- run ResyncModel directly where the result is needed before the next line.
ns.resyncQueued = false
function ns.RunQueuedResync()
    ns.resyncQueued = false
    ResyncModel()
end
function ns.ResyncModelSoon()
    if ns.resyncQueued then return end
    ns.resyncQueued = true
    C_Timer.After(0, ns.RunQueuedResync)
end

-- Is this spell castable right now? Shared by the voice pick and by preset-bound custom
-- reminders, deliberately in one place: a second copy of this ladder drifting out of step
-- with the first is precisely the class of bug this file keeps producing.
--
-- MEASURED, after getting this wrong three times. Write down what is actually true so the
-- next attempt does not relitigate it:
--
--   * GetSpellCooldownDuration returns an OBJECT for a READY spell too. It is IsZero() that
--     separates ready from running. Testing `== nil` instead was tried on a live boss and
--     every defensive lost the pick, every pull, so the player heard "call for external"
--     while Ardent Defender sat off cooldown. Nil comes back rarely, so nil-ness is a
--     usable READY signal but never a usable NOT-READY one.
--   * IsZero() returns a secret ONLY while cooldowns are restricted. CanNameSpellAloud is
--     exactly that question, so branching on IsZero behind that predicate is legal. An
--     earlier pass here removed it as an illegal secret branch; that was wrong, and removing
--     it is what broke the pick.
--   * Sealed and unwitnessed is genuinely unknowable. Defaulting to READY is the right
--     direction: at a pull start every defensive is up, and naming one that turns out to be
--     down costs less than staying silent when one was available.
--
-- May raise on the IsZero branch if the classification changes mid-read, so every caller
-- runs it inside a pcall.
-- Is this spell's cooldown actually running? Blizzard's own definition, lifted from
-- CooldownViewer: isOnActualCooldown = not isOnGCD and cooldownIsActive. Both fields are
-- flagged NeverSecret on SpellCooldownInfo, so unlike IsZero() this ANSWERS in restricted
-- content -- which removes the reason the voice was dead reckoning off readyAt for a whole
-- dungeon, and with it every way that estimate could drift out of step with the icon.
--
-- Operand order is Blizzard's, not incidental: the GCD test is the clean one and
-- short-circuits, which is how their code stays legal. Written the other way round the
-- same expression can raise.
--
-- Returns nil, not a guess, when the client cannot answer -- callers fall back to the
-- older ladder rather than treating "no answer" as ready.
function CooldownRunning(sid)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
    local ok, running = pcall(function()
        local info = C_Spell.GetSpellCooldown(sid)
        if type(info) ~= "table" then return nil end
        return (not info.isOnGCD) and info.isActive
    end)
    if not ok or type(running) ~= "boolean" then return nil end
    return running
end

local function SpellReady(sid, now)
    sid = ns.CooldownKey(sid)
    local charges = ChargesAvailable(sid)
    if charges then return charges > 0 end

    -- The real answer first, whenever the client gives one. Everything below is what this
    -- addon had to do before it turned out one was available.
    local running = CooldownRunning(sid)
    if running ~= nil then return not running end

    local dur = C_Spell.GetSpellCooldownDuration(sid, true)
    if not dur then return true end
    if CanNameSpellAloud(sid) then
        return dur.IsZero and dur:IsZero() and true or false
    end
    return (readyAt[sid] or 0) <= now
end

-------------------------------------------------------------------------------
--  Spoken callouts
-------------------------------------------------------------------------------
-- The one channel that has to branch in Lua, and therefore the one that only works while
-- the cooldowns it reads are unclassified. See CanNameSpellAloud for why.
--
-- The whole list is checked first and the walk is abandoned unless EVERY entry is readable.
-- A partial read would silently skip the sealed entries and name a lower-priority defensive
-- as though the better one were down, which is worse than saying nothing.
-- Which voice both spoken paths use. The addon's own pick wins; "Game Default" stores no id
-- and follows whatever the player chose in Blizzard's Text to Speech panel. A stored id for
-- a voice that is no longer installed falls back rather than going silent, which is what
-- would otherwise happen after a Windows voice pack is removed.
--
-- Cached, because Speak() resolved this on every single callout: GetTtsVoices builds a fresh
-- table per call, and "Game Default" -- what everyone is on until they pick a voice -- then
-- goes through Blizzard's TextToSpeech_GetSelectedVoice, which calls GetTtsVoices a SECOND
-- time and walks it with a closure.
--
-- The key is the stored setting, so the dropdown and a profile switch both invalidate with
-- no wiring at either site, and VOICE_CHAT_TTS_VOICES_UPDATE catches the installed list.
-- Blizzard's own Text to Speech panel raises no event when its voice changes, so combat
-- start drops the cache too, which bounds a stale read to one pull.
--
-- Upvalues in a do block rather than file locals: this chunk is at Lua's 200-local ceiling.
do
    local cachedWant, cachedID

    function ns.InvalidateTTSVoice()
        cachedWant, cachedID = nil, nil
    end

    function ns.TTSVoiceID()
        local want = TRDB().ttsVoiceID
        if cachedID and cachedWant == want then return cachedID end
        if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then return 0 end
        local voices = C_VoiceChat.GetTtsVoices()
        local resolved
        if want and voices then
            for i = 1, #voices do
                if voices[i].voiceID == want then
                    resolved = want
                    break
                end
            end
        end
        if not resolved and TextToSpeech_GetSelectedVoice then
            local ok, voice = pcall(TextToSpeech_GetSelectedVoice, Enum.TtsVoiceType.Standard)
            if ok and voice and voice.voiceID then resolved = voice.voiceID end
        end
        if not resolved then
            resolved = (voices and voices[1] and voices[1].voiceID) or 0
        end
        cachedWant, cachedID = want, resolved
        return resolved
    end
end

-- Voice list for the options dropdown: values keyed by voiceID, plus a Game Default entry
-- keyed "" since a dropdown cannot carry nil as a value.
function ns.TTSVoiceChoices()
    local values, order = { [""] = "Game Default" }, { "" }
    if C_VoiceChat and C_VoiceChat.GetTtsVoices then
        local voices = C_VoiceChat.GetTtsVoices()
        for i = 1, #(voices or {}) do
            local v = voices[i]
            if v and v.voiceID and v.name then
                values[v.voiceID] = v.name
                order[#order + 1] = v.voiceID
            end
        end
    end
    return values, order
end

local function Speak(text)
    if not (C_VoiceChat and C_VoiceChat.SpeakText) or not text or text == "" then return end
    -- (voiceID, text, rate, volume, overlap). The third argument is the RATE, and the
    -- player's own is what belongs there. This passed a hardcoded 1 on an EllesmereUI field
    -- note that the live client treats it as a destination that must be 1; that note does
    -- not hold here. Blizzard's own chat TTS passes C_TTSSettings.GetSpeechRate() into that
    -- slot (TextToSpeechFrame.lua), and so does ns.SpeakReminderTTS below, which is shipped
    -- and working -- so this addon already proves the argument is a rate.
    --
    -- It is not only correctness. Synthesis happens on the calling thread while the client
    -- waits, so a slower rate is a longer utterance and a longer stall, and a tank who set a
    -- fast rate to get callouts out quickly was being overridden into the slowest one.
    --
    -- 0 is Blizzard's normal rate, matching SpeakReminderTTS's own fallback. Do not write
    -- `or 0` against the call itself -- a real 0 is truthy in Lua, so the guard is on the
    -- API being present, not on the value.
    local rate = 0
    if C_TTSSettings and C_TTSSettings.GetSpeechRate then
        rate = C_TTSSettings.GetSpeechRate() or 0
    end
    -- Only `text` may carry a secret; every other argument is NeverSecret, and ours are plain.
    --
    -- /nutank speaktime wraps this one call. debugprofilestop is read as a DELTA and
    -- debugprofilestart is never called: that global timer belongs to whoever started it,
    -- and restarting it would corrupt another addon's measurement mid-fight.
    local p = ns.speakProf
    local before = p and debugprofilestop() or 0
    pcall(C_VoiceChat.SpeakText, ns.TTSVoiceID(), text,
        rate, TRDB().voiceVol or 100, true)
    if p then
        local ms = debugprofilestop() - before
        p.ttsN, p.ttsSum = p.ttsN + 1, p.ttsSum + ms
        if ms > p.ttsMax then p.ttsMax = ms end
    end
end

-- The single place a callout becomes audible, so the sound-or-speech choice is made once
-- rather than at each of the call sites below.
-- When the priority list has nothing of your own left to press, say so in chat so whoever
-- is watching for it can react. Group channels only: an external call means nothing solo,
-- and SAY would carry it to strangers out in the world.
--
-- The timestamp lives in this block rather than as a file local -- the main chunk is close
-- enough to Lua's 200-local ceiling that one more stops the addon compiling. It survives as
-- an upvalue, and the slot is released when the block ends.
do
    local lastAt = 0
    function ns.AnnounceExternalToChat()
        if not TRDB().externalChat then return end
        local now = GetTime()
        -- Several telegraphs landing together are still one call for help.
        if now - lastAt < 3 then return end
        local channel
        if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then channel = "INSTANCE_CHAT"
        elseif IsInRaid() then channel = "RAID"
        elseif IsInGroup() then channel = "PARTY" end
        if not channel then return end
        lastAt = now
        -- C_ChatInfo, not the bare SendChatMessage: that global now only exists as a
        -- deprecation shim behind the loadDeprecationFallbacks CVar, so on a client with it
        -- off the call is nil and this would quietly do nothing forever.
        if C_ChatInfo and C_ChatInfo.SendChatMessage then
            pcall(C_ChatInfo.SendChatMessage, "EXTERNAL!", channel)
        elseif SendChatMessage then
            pcall(SendChatMessage, "EXTERNAL!", channel)
        end
    end
end

local function Announce(spellID, text)
    local key = ns.SoundFor(spellID)
    if key then
        local value = ns.UI.SoundPathFor(key)
        if value then
            ns.UI._PlayLSMSound(value)
            return
        end
        -- The chosen file is gone (a SharedMedia pack removed, say). Speaking is better than
        -- silence, since the callout still has its words.
    end
    Speak(text)
end

-- A second timeline event landing while the first is still fresh and picking the SAME
-- defensive says nothing new -- the player was already told to press it. A DIFFERENT pick
-- still announces normally: that genuinely is new information (the first choice went on
-- cooldown, say).
--
-- Two windows, because the same-spell-same-pick case splits into two failure modes that
-- pull in opposite directions:
--
-- SAME boss ability firing again is usually a resynced or double-reported bar for what is
-- actually a fresh occurrence -- reported live on Rav'i, where suppressing it read as "the
-- icon came up but not the sound alert". That needs the full window: 5 seconds (the alert's
-- own display window) measured too short on a live pull, repeats of the same ability landed
-- up to ~10s apart and still announced twice. 12s covers that with a little room, while
-- staying well short of any real defensive's own cooldown.
--
-- DIFFERENT boss abilities landing within a second or two of each other and both picking
-- the same defensive is the Entombed Sentinels case (Empowering Slam / Bloodvenom Injection,
-- confirmed from a VOD landing well under a second apart) -- the player cannot have pressed
-- anything in that gap, so the second announcement is just noise. This window has to stay
-- short: long enough to catch two casts that are really the same moment, short enough that
-- two busters seconds apart (the case the trigger-keyed window above exists to protect)
-- still both get their own line.
--
-- On ns rather than a chunk local: this file is at the 200-local ceiling, and one more
-- would stop the whole file compiling.
ns.SUPPRESS_REPEAT_WINDOW = 12
ns.SUPPRESS_CROSS_TRIGGER_WINDOW = 3
local lastAnnouncedSpellID, lastAnnouncedAt = nil, 0
local lastAnnouncedTrigger

-- Snapshot of what SpellReady actually saw for the winning pick, so a wrong call --
-- "it named X while X was on cooldown" -- can be diagnosed from what already happened,
-- instead of needing /nutank secrecy typed in the moment, which a live pull never allows.
-- Persisted (capped) so it survives the relog a bad pull often ends in.
-- Every charge spell on the list, not just the one that won the pick. A charge spell that
-- LOSES leaves no trace otherwise, which is exactly the case worth reading: Guardian of
-- Ancient Kings dropping out of the walk is invisible in a log that only records the
-- winner. Anchor age is included because a rebuilt charge state is not visible from the
-- count alone -- it reseeds the count to zero AND resets the anchor, so an age that falls
-- back to roughly zero between two entries with no cast in between is the tell.
local function ChargeModelSnapshot()
    local out
    for i = 1, activeSlots do
        local s = slots[i] and slots[i].spellID
        local st = s and chargeState[ns.CooldownKey(s)]
        if st then
            out = (out and out .. " " or "") .. ("%d=%d/%d %ds(%s) age=%ds cdRunning=%s"):format(
                s, ChargesAvailable(s) or 0, st.max, st.recharge or 0,
                tostring(st.rechargeSrc), GetTime() - (st.tick or GetTime()),
                tostring(CooldownRunning(s)))
        end
    end
    return out
end

local function LogCallout(sid, partners)
    local st = chargeState[ns.CooldownKey(sid)]
    local running = CooldownRunning(sid)
    -- Which of the player's own defensives the combat-log tracking believed were up at the
    -- moment this went out. A callout naming a second defensive seconds after the first one
    -- was actually pressed means Skip When Already Covered did not see the buff land, and
    -- this says so outright instead of leaving it a guess between that and a double fire.
    local auraUp
    for i = 1, activeSlots do
        local s = slots[i].spellID
        if playerAuraUp[s] then auraUp = (auraUp and auraUp .. "," or "") .. s end
    end
    AppendLog({
        auraUp = auraUp,
        kind = ns.testFiring and "test" or "call",
        sid = sid,
        charges = st and ("%d/%d"):format(ChargesAvailable(sid) or 0, st.max) or nil,
        chargeModel = ChargeModelSnapshot(),
        castTracked = castToBase[sid] ~= nil,
        lastOwnCastAgo = ownCastAt[ns.CooldownKey(sid)] and (GetTime() - ownCastAt[ns.CooldownKey(sid)]) or nil,
        running = running == nil and "unreadable" or tostring(running),
        readyAtDelta = readyAt[ns.CooldownKey(sid)] and (readyAt[ns.CooldownKey(sid)] - GetTime()) or nil,
        secrecy = SecrecyLevelName(sid),
        -- Only present when Only While I Have the Boss was actually the gate that let
        -- this through -- how TankingCaster answered for the BOSS ABILITY that triggered
        -- this pick, not the defensive itself. Test fires skip that gate entirely
        -- (ns.testFiring), so lastAggroCheck there would only ever be stale leftover
        -- data from an unrelated earlier real call -- excluded rather than shown as if
        -- it were this fire's own answer.
        tankSid = (not ns.testFiring) and lastAggroCheck and lastAggroCheck.sid or nil,
        tankPath = (not ns.testFiring) and lastAggroCheck and lastAggroCheck.path or nil,
        -- Named, not counted: "with Icebound Fortitude" is the whole question when a pair
        -- reads wrong, and a bare 2 would send the next look at the preset instead of here.
        withSids = partners and table.concat(partners, ",") or nil,
    })
end

-- Every other member of the pick's Call Together group that is ready, in list order. nil
-- when the pick is not itself in a group: a group the pick never reached says nothing
-- about this hit. A member that is down is skipped rather than waited for -- being in a
-- group must never be able to silence a callout, which is the failure this engine keeps
-- having to unlearn.
--
-- Read from the preset the slots were BUILT from rather than the spec's active one: a
-- boss or a single ability can bind its own, and Call Together is stored per preset.
--
-- Its own pcall for the same reason the pick has one: a throw here would otherwise take
-- the callout with it.
--
-- ns functions rather than chunk locals: this file is at the 200-local ceiling.
function ns.TogetherPartners(picked, presetKey, now)
    if not (picked and presetKey) then return nil end
    now = now or GetTime()
    local ok, out = pcall(function()
        if not ns.CalledTogetherInPreset(specID, presetKey, picked) then return nil end
        local partners
        for i = 1, activeSlots do
            local sid = slots[i].spellID
            if sid ~= picked and ns.CalledTogetherInPreset(specID, presetKey, sid)
                and SpellReady(sid, now) then
                partners = partners or {}
                partners[#partners + 1] = sid
            end
        end
        return partners
    end)
    return ok and out or nil
end

-- What the voice says for a pick. Spoken in LIST order, not winner-first, so the line
-- matches the one the preset row shows for the set -- "Guardian and Ardent" reads the same
-- in both places whichever half happened to win the pick. A per-spell SOUND FILE still
-- belongs to the winner alone: two files cannot be run together into one announcement, and
-- the voice is the channel where a set reads as a set.
--
-- A muted member stays out of the spoken line but keeps its glow: muting an entry means
-- "do not say this one", not "drop it from the set".
function ns.SetCalloutLine(picked, partners)
    local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(picked)
    local own = CalloutFor(picked, info and info.name)
    if not partners then return own end
    local said
    for i = 1, activeSlots do
        local sid = slots[i].spellID
        local part = sid == picked
        if not part then
            for j = 1, #partners do
                if partners[j] == sid then part = true break end
            end
        end
        if part and not ns.IsAudioOff(sid) then
            local si = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
            local one = CalloutFor(sid, si and si.name)
            said = said and (said .. " and " .. one) or one
        end
    end
    return said or own
end

-- triggerSid: the boss ability this callout is FOR, so the repeat window only mutes a
-- re-announcement of the same defensive for the SAME incoming hit (a resynced or
-- double-reported bar). Two different busters seconds apart each deserve their own
-- audio even when the pick lands on the same defensive -- suppressing the second read
-- as "the icon came up but not the sound alert", reported live on Rav'i.
local function SpeakCallout(triggerSid)
    local t = TRDB()
    if not t.voiceOn or activeSlots == 0 then return end

    -- NOTE: the tank filter cannot reach audio -- the engine applies it to artwork only. So
    -- with that filter on, the voice speaks for every timeline ability while the icon shows
    -- only tank ones. That is stated in the option's tooltip. Suppressing the voice instead
    -- was tried and was worse: the feature simply went silent with no indication why.

    -- The model is the last rung of the ladder below, for spells whose cooldown is sealed
    -- and whose cast we have not witnessed. Resync first so it is current.
    -- /nutank speaktime measures the two halves of a callout separately: deciding what to
    -- say (here) and saying it (in Speak). Which one costs has been guessed at twice and
    -- got it wrong twice, so it is measured rather than reasoned about. This half is timed
    -- here rather than around the whole function because it is contiguous, while the
    -- function has four exits and a subtraction would go wrong at whichever one got missed.
    local prof = ns.speakProf
    local pickedAt = prof and debugprofilestop() or 0

    ResyncModel()
    local now = GetTime()

    -- The winner is chosen inside a pcall so that a throw cannot swallow the fallback.
    -- That failure mode has already been seen once here: an error mid-loop skipped the
    -- fallback line at the end, and the symptom was not an error message but SILENCE
    -- exactly when the player most needed to be told nobody was up. A pick that errors
    -- must degrade to "call for external", never to nothing.
    local ok, picked = pcall(function()
        for i = 1, activeSlots do
            local sid = slots[i].spellID
            if SpellReady(sid, now) then return sid end
        end
    end)

    if prof then
        local ms = debugprofilestop() - pickedAt
        prof.pickN, prof.pickSum = prof.pickN + 1, prof.pickSum + ms
        if ms > prof.pickMax then prof.pickMax = ms end
    end

    -- On failure pcall's second return is the error STRING, which is truthy and would be
    -- announced as though it were the winning spell.
    -- A thrown pick degrades to the fallback, which is right, but it must not do so
    -- SILENTLY: "call for external" then looks identical to a genuine no-defensive-up and
    -- hides the throw completely. Reported through the same guarded stringify used
    -- elsewhere, because a secret-carrying error raises again on tostring.
    if not ok then
        local why = picked
        if issecretvalue and issecretvalue(why) then
            why = "the error itself carries a secret"
        end
        ns.Print("|cffff6060pick failed|r, using the fallback: " .. tostring(why))
        picked = nil
    end

    if picked then
        local partners = ns.TogetherPartners(picked, ns.slotsPreset, now)

        -- Outside the audio gate below: a muted entry still wins the pick and still shows,
        -- so it should still light up its Cooldown Manager button.
        ns.StartCDMGlow(picked)
        if partners then
            for i = 1, #partners do ns.StartCDMGlow(partners[i], true) end
        end
        -- A muted winner means silence, not the next one down: the player deliberately
        -- turned this entry's audio off and still wants it to win the pick.
        if not ns.IsAudioOff(picked) then
            local sinceLast = now - lastAnnouncedAt
            if picked == lastAnnouncedSpellID and
                ((triggerSid == lastAnnouncedTrigger and sinceLast < ns.SUPPRESS_REPEAT_WINDOW)
                    or (triggerSid ~= lastAnnouncedTrigger
                        and sinceLast < ns.SUPPRESS_CROSS_TRIGGER_WINDOW)) then
                -- Icon-only fires were invisible in the trace, which cost a hunt.
                if t.trace then AppendLog({ kind = "quiet", sid = picked, tankSid = triggerSid }) end
                return
            end
            lastAnnouncedSpellID, lastAnnouncedTrigger, lastAnnouncedAt = picked, triggerSid, now
            LogCallout(picked, partners)
            Announce(picked, ns.SetCalloutLine(picked, partners))
        end
        return
    end

    -- Per ability, falling back to the spec-wide toggle. triggerSid is nil on a test fire,
    -- which finds no binding and so answers with that toggle -- the test still demonstrates
    -- what the spec default does.
    if ns.ExternalCallFor(currentEncounter, triggerSid) then
        if not ns.IsAudioOff(0) then Announce(0, t.voiceNone) end
        -- Outside the audio gate: silencing the callout should not silence the chat call.
        ns.AnnounceExternalToChat()
    elseif ok then
        return "waiting"
    end
end

-------------------------------------------------------------------------------
--  Showing and hiding
-------------------------------------------------------------------------------
-- Visibility is driven by plain data only. It must never ride a secret: SetShown is
-- AllowedWhenUntainted and would error, and hiding on a secret would leak the answer
-- through frame state.

-- Bumped whenever this readout changes. Printed in the header so a report answers "is the
-- current code even loaded" outright, instead of us inferring it from which lines are
-- missing, which cost a pull to get wrong.
local function BuildString()
    local toc = (C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(ns.MODULE_KEY, "Version")) or "unknown"
    -- The TOC half only moves on release; ns.CODE_BUILD moves whenever the Lua does.
    return ns.CODE_BUILD and (toc .. " code " .. ns.CODE_BUILD) or toc
end

-- Never tostring an error straight into a message. When a secret value is what raised, the
-- error object carries one, and tostring() on it raises in turn -- OUTSIDE the guard that
-- caught the original. That is how a report can vanish completely and silently: the row
-- throws, printing the row's failure throws, printing THAT failure throws, and the whole
-- thing unwinds out of the event handler with nothing on screen and nothing in the log.
-- Reduces a possibly-secret value to a string that is always safe to display.
--
-- The guard that matters is issecretvalue(), not pcall. tostring() on a secret does NOT
-- raise: it hands back a SECRET STRING, and secretness then rides through string.format
-- and .. all the way to the display call, which silently drops the line. No error, nothing
-- in the log, just a missing line. Four builds of this diagnostic went missing that way
-- before the cause was found, each time looking like the code had not loaded.
--
-- issecretvalue() answers a PLAIN boolean about a value without reading it, which is why
-- branching on it is legal where branching on the value is not. Blizzard's own Dump and
-- EventTrace pick their formatting the same way.
local function ErrText(err)
    if issecretvalue and issecretvalue(err) then
        return "unreadable (the error itself carries a secret)"
    end
    local ok, text = pcall(function() return tostring(err) end)
    return ok and text or "unreadable"
end

-- Whether the options window is open, which every hide path has to respect so a preview
-- is not yanked off the screen. Declared here rather than beside the rest of the preview
-- state further down: the reads above that point compiled to a nil global.
local previewing = false

-- Glowing the Cooldown Manager button for the defensive being called, so the answer lands
-- on the bar the player is already watching and not only on this addon's own icon.
--
-- GetSpellID can come back secret in restricted content and comparing a secret raises, so
-- every read is pcall'd and screened with issecretvalue before it reaches a comparison.
function ns.CDMButtonForSpell(spellID)
    if not spellID then return nil end
    local viewers = { "EssentialCooldownViewer", "UtilityCooldownViewer",
                      "BuffIconCooldownViewer", "BuffBarCooldownViewer" }
    for i = 1, #viewers do
        local viewer = _G[viewers[i]]
        if viewer and viewer.GetItemFrames then
            local ok, items = pcall(viewer.GetItemFrames, viewer)
            if ok and type(items) == "table" then
                for j = 1, #items do
                    local item = items[j]
                    if item and item.GetSpellID then
                        local ok2, sid = pcall(item.GetSpellID, item)
                        if ok2 and not (issecretvalue and issecretvalue(sid))
                            and type(sid) == "number" and sid == spellID then
                            return item
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- The glow rides our own frame anchored over the button, never a texture parented onto
-- Blizzard's. CooldownViewerSecure keeps tables that refuse tainted access, and adding
-- children or scripts to those frames is the kind of thing that turns a cosmetic feature
-- into a combat bug. SetAllPoints only reads their geometry; it changes nothing of theirs.
-- A set is called as one and every member of it should light up, so this holds a list of
-- anchors rather than the single one it started with. With one anchor, glowing a second
-- spell stopped the first: StartCDMGlow clears whatever is lit before it starts, so a paired
-- callout left only the last member glowing -- or nothing at all, if that member had no
-- button on the bar.
do
    local glowing = {}
    local GLOW_COLOR = { 1, 0.82, 0, 1 }

    function ns.StopCDMGlow()
        local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
        for i = #glowing, 1, -1 do
            local anchor = glowing[i]
            if LCG then pcall(LCG.PixelGlow_Stop, anchor) end
            anchor:Hide()
            glowing[i] = nil
        end
    end

    -- keep = add to what is already lit, for the rest of a set. Without it every call
    -- clears first, which is what a fresh callout wants.
    function ns.StartCDMGlow(spellID, keep)
        if not TRDB().cdmGlow then return end
        if not keep then ns.StopCDMGlow() end
        local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
        if not LCG then return end
        local btn = ns.CDMButtonForSpell(spellID)
        if not btn then return end
        if type(ns.cdmGlowFrames) ~= "table" then ns.cdmGlowFrames = {} end
        local anchor = ns.cdmGlowFrames[#glowing + 1]
        if not anchor then
            anchor = CreateFrame("Frame", nil, UIParent)
            anchor:SetFrameStrata("HIGH")
            ns.cdmGlowFrames[#glowing + 1] = anchor
        end
        anchor:ClearAllPoints()
        anchor:SetAllPoints(btn)
        anchor:Show()
        glowing[#glowing + 1] = anchor
        LCG.PixelGlow_Start(anchor, GLOW_COLOR)
    end
end

local function HideReminder()
    if hideTimer then hideTimer:Cancel(); hideTimer = nil end
    ns.activeAuthoredReminder = nil
    shownForEvent = nil
    -- On ns rather than chunk locals: this chunk is already at Lua's 200-local ceiling.
    ns.integrationShowing, ns.integrationWasPreview = nil, nil
    -- Undo any Preview-specific elevation so a real fight never inherits it.
    if frame then frame:SetFrameStrata("HIGH") end
    if textFrame then textFrame:SetFrameStrata("HIGH") end
    ns.StopCDMGlow()
    if frame then
        if frame.reminder then frame.reminder:Hide() end
        if frame.castTarget then frame.castTarget:Hide() end
        frame:Hide()
    end
    if textFrame then textFrame:Hide() end
    if bar then bar:Hide() end
    if ns.slotsStale then
        ns.slotsStale = nil
        RebuildSlots()
    end
end

-- Dismiss the actual displayed slot, independently of voice and per-spell mute.
-- Alpha may be secret; when its visibility cannot be read, retain the timed display.
function ns.HideIfCalloutPressed(castSpellID)
    if TRDB().hideOnCast ~= true or not shownForEvent then return end
    local sid = castSpellID and castToBase[castSpellID]
    if not sid then return end
    for i = 1, activeSlots do
        local slot = slots[i]
        if slot.spellID == sid then
            local ok, alpha = pcall(slot.GetAlpha, slot)
            if ok and not (issecretvalue and issecretvalue(alpha))
                and type(alpha) == "number" and alpha > 0 then
                HideReminder()
                return
            end
        end
    end
end

-- Who a boss is casting at, drawn on the alert beside the callout that just fired.
--
-- Three of the four calls here hand back SECRET values: the name, the class and "is it
-- me". A secret may be held, stored, and handed back to a Blizzard API, and nothing else.
-- Comparing one, joining it to a string, or printing it raises, and the raise lands in
-- combat where it is least welcome. So nothing below reads any of them:
--
--   * the name goes straight into a font string of its own, never into the callout line,
--     since joining it to anything is precisely the operation that raises;
--   * the class goes straight into GetClassColor and the result straight into SetTextColor;
--   * "is it me" goes straight into SetShown, which is what makes the marker appear without
--     this code ever learning the answer.
--
-- UnitShouldDisplaySpellTargetName is the only one returning a plain boolean, which is why
-- it is the one thing here an `if` may touch. Blizzard's own cast bar is built from the same
-- four calls in the same shape; this follows it rather than inventing a second way.
--
-- A consequence worth stating plainly: the voice cannot follow any of this. Speaking or
-- muting needs a real branch and the answer never becomes readable, which is the same
-- reason the tank filter reaches artwork but not audio.
function ns.ShowCastTargetOn(unit, allowed)
    if not frame or type(unit) ~= "string" then return false end
    if not (UnitShouldDisplaySpellTargetName and UnitSpellTargetName) then return false end
    -- Whether a name may show at all is the caller's switch, not one read here.
    if not allowed then return false end

    -- The NAME only. Whether the cast is on you is a different question with its own call,
    -- asked below whatever this answers: a spell the client will not name a target for can
    -- still be aimed at you, and hiding the marker here said it was not. Blizzard's own
    -- cast bar keeps them apart the same way -- UpdateTargetNameText and
    -- UpdateHighlightWhenCastTarget are separate calls, and the highlight does not consult
    -- the name at all.
    local named = ns.CastNamesATarget(unit)
    if not named and frame.castTarget then frame.castTarget:Hide() end

    if named and frame.castTarget then
        local gotName, name = pcall(UnitSpellTargetName, unit)
        if gotName and name ~= nil then
            frame.castTarget:SetText(name)
            -- Reset first: the lookup is documented as able to return nothing, and without
            -- this a failed one leaves the new name wearing the last target's class colour.
            frame.castTarget:SetTextColor(1, 1, 1, 1)
            if UnitSpellTargetClass and C_ClassColor and C_ClassColor.GetClassColor then
                local gotColour, colour = pcall(function()
                    return C_ClassColor.GetClassColor(UnitSpellTargetClass(unit))
                end)
                if gotColour and colour then
                    pcall(function() frame.castTarget:SetTextColor(colour:GetRGB()) end)
                end
            end
            -- Which row it takes depends on whether the authored line is up, and that is
            -- decided per callout rather than per setting.
            if ns.PlaceCastTargetLine then ns.PlaceCastTargetLine() end
            frame.castTarget:Show()
        end
    end

    return named
end
-- The one plain answer in the set, so an `if` may use it. Split out because a caller that
-- is deciding whether to put a callout up at all has to ask BEFORE it draws: most abilities
-- name nobody, and a second callout that adds no name is the same warning twice.
function ns.CastNamesATarget(unit)
    if type(unit) ~= "string" or not UnitShouldDisplaySpellTargetName then return false end
    -- False also covers "not casting" and "casting at nobody".
    local ok, show = pcall(UnitShouldDisplaySpellTargetName, unit)
    return ok and show == true
end
-- Previews one custom line exactly as a fight would deliver it: the text over the alert
-- frame for a few seconds, and the voice saying it. Used by the Says row's Preview button.
function ns.PreviewReminderLine(text)
    if type(text) ~= "string" or text == "" then return end
    if not frame then Reminder.Create() end
    if frame and frame.reminder then
        frame.reminder:SetText(text)
        frame.reminder:Show()
        frame:Show()
        if textFrame then textFrame:Show() end
        C_Timer.After(3, function()
            if frame and frame.reminder and not shownForEvent then
                frame.reminder:Hide()
                if not previewing then
                    frame:Hide()
                    if textFrame then textFrame:Hide() end
                end
            end
        end)
    end
    Speak(text)
end

-- Used by /nutank test. Deliberately bypasses the tank gate so the two failure modes can
-- be told apart.
function ns.ForceShowTest()
    if not frame then Reminder.Create() end
    ApplyPriorityAlpha()
    ClearTankGate()
    if TRDB().showBar then
        CreateBar()
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0.6)
        if bar.fill then bar.fill:SetAlpha(1) end
        if bar.bg then bar.bg:SetAlpha(1) end
        bar:Show()
    end
    ns.activeAuthoredReminder = nil
    shownForEvent = nil
    frame:Show()
    if textFrame then textFrame:Show() end
    -- The voice too: a test that skips a channel reports that channel broken when it is
    -- merely untested. At the desk cooldowns read plainly, so this speaks whichever
    -- defensive is genuinely up, exactly as a fight would.
    SpeakCallout()

    -- A test that can show nothing must SAY so. With every channel off this otherwise
    -- reports success by displaying nothing, which reads as broken -- and the engine sound
    -- cannot prove itself here at all, since it only fires on a real boss event.
    local t2 = TRDB()
    if not (t2.showIcon or t2.showText or t2.voiceOn) then
        ns.Print("|cffff6060icon, text and voice are all switched off|r -- there is nothing "
            .. "for this test to show. Play a Sound is engine-driven and only fires on a "
            .. "real boss.")
    end
    if hideTimer then hideTimer:Cancel() end
    hideTimer = C_Timer.NewTimer(TRDB().lingerSec or DEFAULTS.lingerSec, HideReminder)
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local watcher

-- A boss switched off in the tree. Enforceable because the game tells us which encounter we
-- are in, unlike which ability is incoming.
local function BossAllowed()
    local t = TRDB()
    if not (currentEncounter and type(t.bossOff) == "table") then return true end
    return t.bossOff[tostring(currentEncounter)] ~= true
end

-- The timeline carries more than boss abilities -- respawn timers and other non-encounter
-- events ride it too, which is how a callout fired while standing at the instance entrance
-- after a wipe. Gate on an encounter actually being underway.
local function InEncounter()
    if C_InstanceEncounter and C_InstanceEncounter.IsEncounterInProgress then
        return C_InstanceEncounter.IsEncounterInProgress()
    end
    return currentEncounter ~= nil
end
ns.InEncounter = InEncounter
ns.BossAllowed = BossAllowed
function ns.CurrentEncounter() return currentEncounter end

-- Every specialization. The role is still resolved because the optional tank filter needs
-- it, but it no longer gates whether the feature runs at all.
--
-- activeSlots is deliberately NOT tested here. It counts the ACTIVE preset, and a callout
-- that names a preset of its own -- an ability binding, a boss override, a trash rule --
-- never reads that one. Gating on it meant selecting a preset built for another spec
-- silenced every binding the player owned, which is how an imported profile could leave
-- someone with 30 working bindings and no callouts at all. Emptiness is decided per
-- callout instead: RebuildSlots(fp, true, preset) already refuses when nothing on the
-- list it actually resolved is castable.
local function ShouldRun()
    return TRDB().enabled == true and canSelect
        and TimelineAvailable() and BossAllowed()
end

-------------------------------------------------------------------------------
--  Custom reminders: pull, BigWigs/DBM message and BigWigs/DBM timer triggers
-------------------------------------------------------------------------------
-- Independent of the defensive-priority system entirely: a player with nothing on their
-- priority list should still get these, so gating never touches ShouldRun()/activeSlots.
local function CustomRemindersAllowed()
    return TRDB().enabled == true and BossAllowed()
end

-- "Show in" syntax: blank fires immediately. A plain number or MM:SS(.ms) (e.g. "1:30.5")
-- is seconds; comma-separate several to fire more than once. Non-positive values are
-- nudged up rather than treated as "now", so a scheduled fire never lands in the past.
local function ParseDelayList(text)
    if type(text) ~= "string" or text == "" then return nil end
    local out = {}
    for tok in text:gmatch("[^, ]+") do
        local n = tonumber(tok)
        if not n then
            local m, s, frac = tok:match("^(%d+):(%d+)%.?(%d*)$")
            if m then
                local ms = (frac ~= "") and tonumber("0." .. frac) or 0
                n = tonumber(m) * 60 + tonumber(s) + ms
            end
        end
        if n then out[#out + 1] = math.max(n, 0.01) end
    end
    return #out > 0 and out or nil
end

-- Counter condition syntax: a bare number, >=N, >N, <=N, <N, !N or =N. Comma-separated
-- terms are OR'd; a leading + on a term ANDs it with the one before it in the same group
-- (comma still required) -- e.g. ">3,+<7" means "more than 3 and less than 7".
local function ParseOnePred(tok)
    local op, num = tok:match("^(>=)(%-?%d+%.?%d*)$")
    if not num then op, num = tok:match("^(<=)(%-?%d+%.?%d*)$") end
    if not num then op, num = tok:match("^(>)(%-?%d+%.?%d*)$") end
    if not num then op, num = tok:match("^(<)(%-?%d+%.?%d*)$") end
    if not num then op, num = tok:match("^(!)(%-?%d+%.?%d*)$") end
    if not num then op, num = tok:match("^(=)(%-?%d+%.?%d*)$") end
    if not num then op, num = "=", tok:match("^(%-?%d+%.?%d*)$") end
    num = tonumber(num)
    if not num then return nil end
    return { op = op, num = num }
end

local function ParseCounterCondition(text)
    if type(text) ~= "string" or text == "" then return nil end
    local groups = {}
    for tok in text:gmatch("[^,]+") do
        tok = tok:gsub("^%s+", ""):gsub("%s+$", "")
        local andWithPrev = tok:sub(1, 1) == "+"
        local pred = ParseOnePred(andWithPrev and tok:sub(2) or tok)
        if pred then
            if andWithPrev and #groups > 0 then
                local g = groups[#groups]
                g[#g + 1] = pred
            else
                groups[#groups + 1] = { pred }
            end
        end
    end
    return #groups > 0 and groups or nil
end

local function CheckCounterCondition(groups, n)
    if not groups then return true end
    for i = 1, #groups do
        local g = groups[i]
        local allMatch = true
        for k = 1, #g do
            local p = g[k]
            local ok
            if p.op == ">=" then ok = n >= p.num
            elseif p.op == "<=" then ok = n <= p.num
            elseif p.op == ">" then ok = n > p.num
            elseif p.op == "<" then ok = n < p.num
            elseif p.op == "!" then ok = n ~= p.num
            else ok = n == p.num end
            if not ok then allMatch = false; break end
        end
        if allMatch then return true end
    end
    return false
end

-- Per-uid occurrence count for the "Nth cast" counter, reset every pull.
local customCounters = {}
-- Cached at ENCOUNTER_START so OnCombatLog's hot path stays a single boolean read on a
-- boss with nothing configured, the same reasoning runActive already uses below.
local hasCustomReminders = false
local hasRaidReminders = false

local function RefreshCustomRemindersFlag()
    local set = currentEncounter and CustomRemindersTable(false, currentEncounter)
    hasCustomReminders = set ~= nil and next(set) ~= nil
    -- Raid reminders were read LIVE out of the DB on every combat log line, because a
    -- stale flag would have silently stopped them firing after an edit. The real fix was
    -- to make every edit path refresh -- the raid editor's own Save did not -- so this
    -- can be a cached boolean like its neighbour. The live read cost a settings-chain
    -- walk, a tostring() and, on the common no-raid-reminders boss, a throwaway table,
    -- thousands of times a second in a raid.
    local rr = currentEncounter and ns.RaidRemindersTable
        and ns.RaidRemindersTable(false, currentEncounter)
    hasRaidReminders = rr ~= nil and next(rr) ~= nil
    -- Resolved through ns: defined further down the file, and it no-ops before then.
    if ns.RefreshCastWatch then ns.RefreshCastWatch() end
end
ns.RefreshCustomRemindersFlag = RefreshCustomRemindersFlag

-- Same shape as ApplyPosition: nil = default centre, otherwise wherever
-- Unlock Mode last saved it.



-- Trash rules occupy the defensive alert now, so the integration hide path has to reach it
-- as well as the raid-reminder regions it already walks -- otherwise one test sits on
-- screen until its own timer runs out instead of being replaced by the next.
function ns.HideIntegrationCustomReminder(previewOnly)
    if not ns.integrationShowing then return end
    if previewOnly and not ns.integrationWasPreview then return end
    HideReminder()
end

-- The best still-available defensive in an ordered spellID list, decided at fire time by
-- the same ladder the main callout uses -- shared by preset resolution below and by a
-- per-ability override list (EffectiveList's own fp-keyed layer, see FireCustomReminder).
-- On ns rather than staying local: the main chunk is already at Lua's 200-local ceiling
-- (see the Countdown block's own comment on this), and a table field costs nothing there.
function ns.PickFromList(list)
    if type(list) ~= "table" then return nil end
    local now = GetTime()
    -- SpellReady can raise if a cooldown's classification changes mid-read; the whole walk
    -- is guarded so that degrades to the no-defensive line rather than to a Lua error.
    local ok, picked = pcall(function()
        for i = 1, #list do
            local sid = list[i]
            -- Untalented entries are skipped rather than called for, matching RebuildSlots.
            if IsSpellAvailable(sid) then
                ResyncSpell(sid)
                if SpellReady(sid, now) then return sid end
            end
        end
    end)
    return ok and picked or nil
end

-- What a preset-bound reminder actually says. A line the player typed before the pull
-- cannot know what is up, which is the whole reason these moved from free text to a
-- preset. Resolved against the CURRENT spec, like every other preset lookup here --
-- presets are per-spec and the stored key indexes into whichever spec is live.
local function PickFromPreset(presetKey)
    local presets = PresetsTable(specID, false)
    local p = presets and presets[presetKey]
    return ns.PickFromList(p and p.list)
end

-- Shared by every display type that carries an optional r.sound: one-shot, at the moment
-- the display fires, same as popup always has.
function ns.PlayReminderSound(r)
    if not r.sound then return end
    local path = ns.UI.SoundPathFor(r.sound)
    if path then ns.UI._PlayLSMSound(path) end
end

-- Reminder speech uses the same voice and volume as the main addon callouts.
-- Keep Blizzard's speech rate; the addon has no separate rate control.
-- Test failures are reported locally rather than leaving a silent icon unexplained.
function ns.SpeakReminderTTS(r, overrideText, preview)
    if not (r and r.tts) then return end
    local text = overrideText or r.text
    if not (text and text ~= "") then return end
    local function Unavailable(message)
        if preview then ns.Print(message) end
    end
    if not (C_VoiceChat and C_VoiceChat.SpeakText and C_VoiceChat.GetTtsVoices) then
        return Unavailable("TTS is unavailable in this client.")
    end
    local voices = C_VoiceChat.GetTtsVoices()
    if not voices or #voices == 0 then
        return Unavailable("No TTS voices are available. Check WoW's Text to Speech settings.")
    end
    local voiceID = ns.TTSVoiceID()
    if not voiceID then return Unavailable("No TTS voice is selected.") end
    local rate = (C_TTSSettings and C_TTSSettings.GetSpeechRate and C_TTSSettings.GetSpeechRate()) or 0
    local volume = TRDB().voiceVol or 100
    if volume <= 0 then
        return Unavailable("Voice Volume is zero. Raise it under Smart Reminders > Setup > Sounds and Voice.")
    end
    -- Blizzard's documented order is voiceID, text, rate, volume, overlap.
    local ok = pcall(C_VoiceChat.SpeakText, voiceID, text, rate, volume, false)
    if not ok then return Unavailable("WoW could not start TTS playback. Check its Text to Speech settings.") end
end

-- Shared by every display type that can be bound to a defensive rather than free text
-- (abilitySpellID from the ability picker's Pre-Selected Defensives mode, or preset from
-- the full editor) -- resolves once to the actual spell that would be called, so the
-- callout text and an auto-filled icon never have to re-derive it separately or disagree.
-- On ns rather than staying local: the main chunk is already at Lua's 200-local ceiling.
function ns.ResolveReminderSpell(r, presetKey)
    if not r then return nil end
    if r.abilitySpellID then
        -- EffectiveList's fp-keyed layer already does exactly what a per-ability override
        -- needs: this exact ability's own list first (editable from the ability picker),
        -- falling back to the boss's chosen preset, then the spec default -- the identical
        -- three-layer resolution RebuildSlots uses for the live alert, just entered
        -- through the ability's own spellID instead of a timeline fingerprint.
        local list = EffectiveList(specID, currentEncounter, tostring(r.abilitySpellID))
        local picked = ns.PickFromList(list)
        if picked then return picked end
    end
    -- The caller's key when it has one: ShowOnAlert has already resolved which preset the
    -- slots were built from, and re-deriving it here from r.preset alone would answer with
    -- a different list than the icons are showing.
    presetKey = presetKey or r.preset
    if presetKey then return PickFromPreset(presetKey) end
    return nil
end

-- Bypasses trigger matching entirely -- used both by the real firing path below and by
-- the editor's Preview button, so a preview shows exactly what a fight would.
-- Authored reminders draw on the defensive alert, the same slots and the same text row
-- every boss callout uses. They had a frame of their own until this, which put a second
-- icon and line on screen beside the real display and gave one job two different looks.
-- The per-reminder colour and icon-spell settings went with it: the alert owns both, and a
-- reminder restyling it would be the second display all over again.
--
-- opts: fp, preset, text, dur, audio, preview, resolveFrom.
local function ShowOnAlert(opts)
    if not frame then Reminder.Create() end
    if not frame then return false end

    if opts.preset or opts.fp then
        -- keepIfEmpty: nothing on the list being available leaves whatever is on screen
        -- alone rather than blanking it, same as a boss callout that cannot be answered.
        if not RebuildSlots(opts.fp or "authored", true, opts.preset) then return false end
        ApplyPriorityAlpha()
        ClearTankGate()
        if frame.reminder then frame.reminder:Hide() end
    elseif frame.reminder and type(opts.text) == "string" and opts.text ~= "" then
        -- The slots keep whatever the spec's own preset last put in them, so showing the
        -- frame for a line alone still displayed a defensive nobody asked for.
        for i = 1, #slots do slots[i]:SetAlpha(0) end
        activeSlots = 0
        if frame.fallback then frame.fallback:SetAlpha(0) end
        ns.slotsStale = true
        frame.reminder:SetText(opts.text)
        frame.reminder:Show()
    else
        return false
    end

    -- Cleared on every fire. A second callout inside the display window re-arms the hide
    -- timer instead of hiding, so without this it inherits the previous cast's target name.
    -- Blizzard's own cast bar blanks the same label on the same branch.
    if frame.castTarget then frame.castTarget:Hide() end

    -- Who owns what is on screen. ApplyReminderFilter reads it to pull a live callout when
    -- its reminder is switched off or filtered out mid-display, so leaving this nil meant a
    -- healer reminder could stay up after the healer opt-out had just removed it.
    ns.activeAuthoredReminder = opts.resolveFrom
    -- Not a spell id, and never compared against one: it marks the alert as occupied so a
    -- general rebuild or the options preview cannot pull it off screen mid-display.
    shownForEvent = "authored"
    ns.integrationShowing, ns.integrationWasPreview = true, opts.preview or nil
    -- An editor's Preview fires from inside a modal at FULLSCREEN_DIALOG, which HIGH sits
    -- well below. HideReminder drops both back, so the elevation never leaks into a fight.
    if opts.preview then
        frame:SetFrameStrata("FULLSCREEN_DIALOG")
        if textFrame then textFrame:SetFrameStrata("FULLSCREEN_DIALOG") end
    end
    frame:Show()
    if textFrame then textFrame:Show() end

    if opts.audio then
        local spoken, resolved = opts.text, true
        if opts.resolveFrom and (opts.preset or opts.fp) then
            local picked = ns.ResolveReminderSpell(opts.resolveFrom, opts.preset)
            -- The same set line the boss callout speaks, for the same reason: a pick that
            -- belongs to a Call Together group is named with every other ready member
            -- rather than on its own. This said the winner alone, so a set built as
            -- "AMS + Death's Advance" called out half of itself.
            --
            -- Reads the slots RebuildSlots just filled for this preset above, which is why
            -- it belongs here rather than in ResolveReminderSpell. Through CalloutFor, not
            -- the spell's own name: someone who renames Vampiric Blood to "Vamp" wants to
            -- hear "Vamp", and the slot label beside it has always said so.
            local named = picked and ns.SetCalloutLine(picked,
                ns.TogetherPartners(picked, ns.slotsPreset))
            if named and named ~= "" then spoken = named else resolved = false end
        end
        -- Nothing on the list is up. RebuildSlots let the callout through because every
        -- entry is KNOWN -- readiness is the alpha's job -- so the icons had already gone
        -- dark while the sound file and the pre-pull line still called for a defensive the
        -- player did not have. A rule carrying only custom text never reaches this.
        if resolved then
            ns.PlayReminderSound(opts.audio)
            ns.SpeakReminderTTS(opts.audio, spoken, opts.preview)
        elseif TRDB().trace then
            AppendLog({ kind = "drop",
                sid = opts.resolveFrom.trigger and opts.resolveFrom.trigger.spellID,
                text = "authored callout silent; nothing on the preset is ready" })
        end
    end

    if hideTimer then hideTimer:Cancel() end
    hideTimer = C_Timer.NewTimer((type(opts.dur) == "number" and opts.dur > 0)
        and opts.dur or 3, HideReminder)
    return true
end

local function FireCustomReminder(r)
    if not r then return end
    return ShowOnAlert({
        -- A per-ability override list is keyed by the spell it belongs to; a preset names
        -- one outright. Either way the slots answer, and the line is the fallback for a
        -- reminder that carries neither.
        fp = r.abilitySpellID and tostring(r.abilitySpellID) or nil,
        preset = r.preset,
        text = (type(r.msg) == "string" and r.msg ~= "" and r.msg) or r.name,
        dur = r.dur,
        audio = r,
        resolveFrom = r,
    })
end

-- ActivateCustomReminder (the real fire path) and PreviewCustomReminder (the editor's
-- Preview button) both call this, so a preview always shows exactly what a fight would.
function ns.DisplayReminder(r)
    if not ns.IsReminderEnabled(r) then return end
    if r.defensive then
        if r.specID and r.specID ~= specID then return end
        if not CustomRemindersAllowed() then return end
        return ns.FireMessageDefensive(r)
    end
    return FireCustomReminder(r)
end

-- Which preset a trash rule answers with, resolved per fire rather than stamped when the
-- rule was saved. Preset keys are allocated per spec, so a key written on one spec, or
-- arriving inside a pack, names a different list here or none at all -- and the fire path
-- takes a key as an override with no fall-through, which makes a stale one a rule that
-- silently never calls anything (CopyRemindersFromSpec carries the same note).
--
-- An empty line means "answer with the preset", not "say nothing": this page has had no
-- text box since these moved from free text to presets, so only rules saved before that
-- carry a line of their own, and those are still asking for the line rather than for a
-- defensive.
function ns.IntegrationPreset(rule)
    if not (rule.trigger and rule.trigger.type == "exboss") then return rule.preset end
    local d = rule.display
    if type(d) == "table" and type(d.text) == "string" and d.text ~= "" then return rule.preset end
    local presets = PresetsTable(specID, false)
    if rule.preset and presets and presets[rule.preset] then return rule.preset end
    return ActivePresetKey(specID)
end

-- Trash and debuff rules take the same renderer as every other authored reminder: a rule
-- answering with a preset is asking the question the alert already answers, and one with
-- only custom text takes the alert's own text row.
function ns.DisplayIntegrationReminder(rule, preview)
    if not rule or not rule.display then return end
    local d = rule.display
    local preset = ns.IntegrationPreset(rule)
    -- The boss callout's Skip When Already Covered, for a trash pull that overlaps a
    -- defensive the player already pressed for the previous pack.
    if not preview and preset and TRDB().coveredSkip ~= false then
        local covered, bySid, how = CoveredByActiveDefensive("authored", preset)
        if covered then
            local sid = rule.trigger and rule.trigger.spellID
            AppendLog({ kind = "skip", sid = bySid or sid, tankSid = sid, tankPath = how })
            return
        end
    end
    ShowOnAlert({
        preset = preset,
        text = d.text,
        dur = d.dur,
        audio = d,
        preview = preview,
        resolveFrom = rule,
    })
end

-- The editor's Preview button fires from inside its own modal (FULLSCREEN_DIALOG), which
-- the alert's HIGH sits well below. ShowOnAlert raises it for a preview and HideReminder
-- puts it back, so there is nothing left for this to arrange.
function ns.PreviewCustomReminder(r)
    ns.DisplayReminder(r)
end

-- Every reminder timer scheduled against a moment in the fight is tracked here so it can
-- be cancelled when that moment stops existing. Untracked timers were a live bug: a
-- reminder set for 4:30 still fired after a wipe at 0:40, into the corpse run. Two
-- scopes: "pull" timers die on the encounter boundaries, "stage" timers additionally die
-- whenever the stage changes or the boss module disables -- a phase that ended takes its
-- scheduled callouts with it. ns fields, not chunk locals: this chunk is at the 200-local
-- ceiling.
ns.trackedReminderTimers = {}

-- Owns the timer creation rather than taking a ready-made handle, so a timer that fires
-- normally can drop its own entry: tracked-but-fired entries would otherwise pile up for
-- the length of a pull and every later cancel sweep would walk them.
function ns.IsCurrentCustomReminder(r, set)
    if not ns.IsReminderEnabled(r) or (r.specID and r.specID ~= specID) then return false end
    if set ~= CustomRemindersTable(false, currentEncounter) then return false end
    for _, current in pairs(set or {}) do
        if current == r then return true end
    end
    return false
end

function ns.PruneCustomReminderTimers()
    local timers = ns.trackedReminderTimers
    for i = #timers, 1, -1 do
        local entry = timers[i]
        if (entry.reminder and not ns.IsCurrentCustomReminder(entry.reminder, entry.reminderSet))
            or (entry.valid and not entry.valid()) then
            entry.handle:Cancel()
            table.remove(timers, i)
        end
    end
end

function ns.TrackReminderTimer(scope, delay, fn, reminder, valid)
    if reminder and not ns.IsReminderEnabled(reminder) then return end
    if valid and not valid() then return end
    local list = ns.trackedReminderTimers
    local entry = { scope = scope, reminder = reminder, valid = valid,
        reminderSet = reminder and CustomRemindersTable(false, currentEncounter) }
    entry.handle = C_Timer.NewTimer(delay, function()
        for i = #list, 1, -1 do
            if list[i] == entry then table.remove(list, i) break end
        end
        if reminder and not ns.IsCurrentCustomReminder(reminder, entry.reminderSet) then return end
        if valid and not valid() then return end
        fn()
    end)
    list[#list + 1] = entry
    return entry.handle
end

function ns.CancelTrackedReminderTimers(scope)
    local t = ns.trackedReminderTimers
    for i = #t, 1, -1 do
        if scope == nil or t[i].scope == scope then
            local h = t[i].handle
            if h.Cancel then h:Cancel() end
            table.remove(t, i)
        end
    end
end

-- The match decided a reminder should go off; this is where "Show in" (a raw string on
-- the trigger, parsed fresh here rather than pre-compiled -- these fire rarely enough that
-- the cost never matters) turns into either an immediate call or one timer per listed
-- delay, so a comma list fires more than once from the same match.
--
-- Returns true only when a callout went up right now. A delayed one has not shown yet and
-- a refused one never will, and the cast-target display keys off this rather than assuming
-- the alert is on screen.
local function ActivateCustomReminder(r, scope)
    if not ns.IsReminderEnabled(r) then return end
    local delays = ParseDelayList(r.trigger and r.trigger.delay)
    if not delays then
        return ns.DisplayReminder(r) == true
    end
    -- Custom reminders need not have any tracked cooldown spells, so the regen
    -- listener may be absent. Recheck combat before a combat-scoped timer fires.
    local combat = (scope == "combat")
    for i = 1, #delays do
        ns.TrackReminderTimer(scope or "pull", delays[i], function()
            if combat and not InCombatLockdown() then return end
            ns.DisplayReminder(r)
        end, r)
    end
end

-- Boss cast triggers. UNIT_SPELLCAST_* rather than the combat log: CLEU is unavailable in
-- restricted content (status reports registered=false restrictedHere=true on a raid boss),
-- which is why the old combat-log "spell" trigger stopped being offered.
--
-- The index is keyed by spell id and holds the reminders waiting on it, so the handler
-- NEVER compares the event's spellID -- UNIT_SPELLCAST_START is
-- SecretWhenUnitSpellCastRestricted, and comparing a secret raises where a table lookup
-- does not. Same shape castToBase[castSpellID] already uses for the player's own casts.
-- Everything read back out is ours and plain, so no secret spreads past this point.
function ns.RefreshCastWatch()
    local index, any = {}, false
    local set = currentEncounter and CustomRemindersTable(false, currentEncounter)
    if set then
        for uid, r in pairs(set) do
            local trig = r.trigger
            local kind = trig and trig.type
            if r.enabled ~= false and (kind == "caststart" or kind == "castend")
               and type(trig.spellID) == "number" then
                local entry = index[trig.spellID]
                if not entry then entry = {}; index[trig.spellID] = entry end
                entry[kind] = entry[kind] or {}
                entry[kind][#entry[kind] + 1] = { uid = uid, r = r }
                any = true
            end
        end
    end
    -- Trash rules are deliberately not here. Watching a trash cast meant matching it to the
    -- rule that predicted it, by spell id, and that id is secret for every unit that is not
    -- the player or their pet -- so the lookup never matched and the repeat never fired.
    -- It shipped in 1.4.1 and was removed once the traces proved it could not work.
    ns.watchedCasts = index

    -- Armed for the target name alone, with nothing in the index to match against. A boss
    -- cast cannot be identified at all -- UNIT_SPELLCAST_START is
    -- SecretWhenUnitSpellCastRestricted, which the client documents as producing secret
    -- values "if the unit being queried for cast information is not the player or their
    -- pet", so the id is secret for every boss in every fight rather than only in
    -- restricted content. Naming who a cast is aimed at never needed the id, so that half
    -- still works; see the decoration branch in OnBossCast.
    --
    -- Bounded to an encounter so the events are not registered for every cast in the group
    -- while walking around. currentEncounter is already set or cleared by the time the
    -- ENCOUNTER_START/END handler calls this.
    if currentEncounter and TRDB().castTargetBoss then any = true end

    if any and not ns.castWatcher then
        ns.castWatcher = CreateFrame("Frame")
        ns.castWatcher:SetScript("OnEvent", function(_, event, unit, _, spellID)
            ns.OnBossCast(event, unit, spellID)
        end)
    end
    if ns.castWatcher then
        if any then
            -- Plain RegisterEvent, not RegisterUnitEvent: that takes only a couple of
            -- units and this needs boss1-5 plus every nameplate. The unit filter below
            -- does the same job.
            ns.castWatcher:RegisterEvent("UNIT_SPELLCAST_START")
            ns.castWatcher:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        else
            ns.castWatcher:UnregisterAllEvents()
        end
    end
end

-- Cast end is SUCCEEDED only. An interrupted or cancelled cast fires nothing: the mechanic
-- never happened, and calling "move" after a kicked cast is worse than saying nothing.
function ns.OnBossCast(event, unit, spellID)
    -- Unit filter first. This is a plain RegisterEvent, so every cast in the group lands
    -- here, and the gate below costs a GetInstanceInfo and three profile reads. Almost
    -- every event is a raid member casting and stops on these two lines instead.
    if type(unit) ~= "string" then return end
    -- Plain find rather than a ^boss%d pattern: this filter IS the per-event cost for
    -- every cast in the group and on every nameplate, and a pattern match compiles the
    -- pattern and builds a result string on each hit. Only base unit tokens reach an
    -- event payload, so a prefix test accepts exactly what the pattern did.
    local isBoss = unit:find("boss", 1, true) == 1
    if not (isBoss or unit:find("nameplate", 1, true) == 1) then return end
    if not CustomRemindersAllowed() then return end

    -- Who a cast is aimed at, written onto the alert that is ALREADY on screen. Nothing
    -- here asks what was cast, because nothing can: the id is secret for any unit that is
    -- not the player or their pet. Whether a cast names somebody is the one plain answer
    -- the client gives, so the reminder that warned about the ability seconds ago picks up
    -- the name when the cast actually goes out, without the two ever being matched.
    --
    -- What that costs: the name belongs to whatever is being cast right now, not provably
    -- to the ability the alert names. Boss units only, where there is one caster and the
    -- alert is nearly always about it -- a trash pack has several and the guess would be
    -- worth much less. Asked before drawing, so a cast that names nobody leaves a name
    -- already on the alert alone instead of clearing it.
    --
    -- Traced on every branch, not only the one that draws. Each silent outcome looks
    -- identical in play and has a different answer -- the switch is off, nothing was on
    -- screen to write on, or the client says this cast names nobody, which is true of most
    -- casts and is not a fault. Logging only the success cost a pull to find that out.
    if event == "UNIT_SPELLCAST_START" and isBoss then
        local why
        if not TRDB().castTargetBoss then why = "target display off"
        -- Asked even with nothing on screen, so a trace of one dungeon answers "which
        -- abilities here carry a target name at all" instead of only reporting the ones
        -- that happened to coincide with a callout. That question has cost several pulls
        -- to guess at, and it is one plain boolean away.
        elseif not shownForEvent then
            -- Only worth asking when somebody is reading the answer: with trace off this
            -- string is built and thrown away, and the question is an API call per cast.
            why = TRDB().trace and ns.CastNamesATarget(unit)
                and "no alert, but this cast names somebody" or "no alert to name"
        elseif ns.ShowCastTargetOn(unit, true) then why = "target named"
        else why = "cast names nobody" end
        if TRDB().trace then AppendLog({ kind = "bosscast", unit = unit, text = why }) end
    end

    local index = ns.watchedCasts
    if not index then return end
    -- Screened before the lookup: a secret cannot be used as a table key.
    local plain = not (issecretvalue and issecretvalue(spellID)) and spellID or nil
    local entry = plain and index[plain]
    -- Traced on BOTH paths on purpose. If the spell id arrives secret in restricted
    -- content there is no match, and a miss is indistinguishable in play from the boss
    -- never casting -- exactly the ambiguity /nutank keys exists to end elsewhere.
    if TRDB().trace then
        -- Never the raw id: a secret must not reach callLog, which is written to
        -- SavedVariables. Logged as "secret id" when it is one -- which is itself the
        -- answer worth having.
        AppendLog({ kind = "bosscast", sid = plain, unit = unit,
            text = entry and "matched" or "not watched" })
    end
    if not entry then return end

    local list = entry[event == "UNIT_SPELLCAST_START" and "caststart" or "castend"]
    if not list then return end

    for i = 1, #list do
        local uid, r = list[i].uid, list[i].r
        local hit = true
        if r.trigger.counter and r.trigger.counter ~= "" then
            customCounters[uid] = (customCounters[uid] or 0) + 1
            hit = CheckCounterCondition(ParseCounterCondition(r.trigger.counter),
                customCounters[uid])
        end
        if hit then
            local shown = ActivateCustomReminder(r)
            -- After the callout, and only when one actually went up: the display clears the
            -- target line on its way in, and a delayed or refused reminder would otherwise
            -- leave a name latched onto whatever alert comes next.
            --
            -- Start only. On UNIT_SPELLCAST_SUCCEEDED the unit has stopped casting, and the
            -- client answers "is there a target to show" with false at that point, so a
            -- castend reminder could never have displayed one anyway.
            if shown and event == "UNIT_SPELLCAST_START" then
                ns.ShowCastTargetOn(unit, TRDB().castTargetBoss)
            end
        end
    end
end

-- Which single source drives callouts this session. Read at event time, never cached:
-- the Setup dropdown changes it live.
-- The pull clocks, for the observed-timing recorder in its own file. One accessor rather
-- than six exported fields, and read rarely (once per broadcast).
function ns.PullContext()
    return currentEncounterStartedAt, currentDifficultyID, currentStage, currentStageAt
end

-- No saved pick follows whatever boss mod is actually installed. Sitting on "timeline"
-- instead meant a player who never opened Setup recorded nothing, ever, and the observed
-- timeline is meant to build itself in the background rather than be switched on.
--
-- Resolved live, never written into the profile: an explicit pick still wins, and
-- uninstalling a boss mod moves the fallback with it instead of stranding a saved value
-- pointing at something that is no longer there. This decides WHICH engine drives
-- callouts, not whether they fire -- TRDB().enabled is that switch and is still off by
-- default -- so nothing starts talking because of this.
function ns.BossSource()
    local saved = TRDB().bossSource
    if saved then return saved end
    if _G.BigWigsLoader then return "bigwigs" end
    if _G.DBM then return "dbm" end
    return "timeline"
end

-- kind: "pull" | "cast" | "aura". spellID is nil for a pull check. "cast"/"aura" are the
-- older combat-log triggers -- the editor no longer creates them, but anything already
-- saved that way keeps working.
local function CheckCustomReminders(kind, spellID)
    if not (hasCustomReminders and CustomRemindersAllowed()) then return end
    local set = CustomRemindersTable(false, currentEncounter)
    if not set then return end
    for uid, r in pairs(set) do
        local trig = r.trigger
        if r.enabled ~= false and trig then
            local hit = (kind == "pull" and trig.type == "pull")
                or (trig.type == "spell" and trig.spellID == spellID
                    and (trig.kind or "cast") == kind)
            if hit and type(trig.counter) == "number" and trig.counter > 1 then
                customCounters[uid] = (customCounters[uid] or 0) + 1
                hit = customCounters[uid] >= trig.counter
            end
            if hit then ActivateCustomReminder(r) end
        end
    end
end

-- Time In Combat is the one trigger that is not boss-scoped: it counts from entering
-- combat, so it has to work on trash and in the open world, where there is no encounter
-- at all. Those reminders live in PerBossSet's own `enc or 0` bucket, which nothing else
-- writes -- every other reader nil-guards currentEncounter before it can reach key "0".
-- Read live rather than through hasCustomReminders: that flag is cached at
-- ENCOUNTER_START and so is false for exactly the fights this trigger exists for. An ns
-- function, not a chunk local -- this chunk is at the 200-local ceiling.
function ns.CheckCombatReminders()
    -- Retired trigger; saved records are retained for manual editing.
end

-- The same trigger saved on a boss. Which boss it is only becomes known at
-- ENCOUNTER_START, so the schedule is worked out here and the time already spent in
-- combat comes off it -- the clock the player set is combat entry, not the pull.
function ns.CheckBossCombatReminders()
    -- Retired trigger; saved records are retained for manual editing.
end

-------------------------------------------------------------------------------
--  Custom reminders: BigWigs/DBM message and timer triggers
-------------------------------------------------------------------------------
-- Which boss mod owns this pull, latched on its first message so a player running both
-- BigWigs and DBM does not get every message/timer trigger firing twice. Reset every pull.
local bwActiveMod

-- Pending "timeleft" activations for bwtimer triggers, so a bar that stops or pauses
-- early can cancel the reminder before it fires. Keyed by uid .. "|" .. mod .. ":" .. bar
-- text, since a stop/pause event only ever carries the bar's text back, not its key.
local bwPendingTimers = {}
ns.pendingCustomReminderOwners = {}


-- Keys end in "|mod:identity". An exact identity cancels that bar only; "" cancels every bar
-- from the mod.
local function CancelBossModTimers(mod, text)
    local tag = "|" .. mod .. ":"
    local suffix = tag .. tostring(text)
    for k, handle in pairs(bwPendingTimers) do
        local hit
        if text == "" then
            hit = k:find(tag, 1, true) ~= nil
        else
            hit = k:sub(-#suffix) == suffix
        end
        if hit then
            if handle.Cancel then handle:Cancel() end
            bwPendingTimers[k] = nil
            ns.pendingCustomReminderOwners[k] = nil
        end
    end
end

function ns.HasMessageDefensive(encounterID, sid)
    local set = CustomRemindersTable(false, encounterID)
    for _, r in pairs(set or {}) do
        if r.defensive and r.enabled ~= false and (not r.specID or r.specID == specID)
            and r.trigger and r.trigger.type == "bwmsg" then
            -- The catalogue saves DBM's raw id while HandleBigWigsAbility asks about the
            -- BigWigs key it was normalized to, so a reminder on a mapped DBM ability
            -- looks like a different ability here and both callouts fire for one message.
            local key = r.trigger.spellID
            if key == sid or (ns.DBM_TO_BIGWIGS and ns.DBM_TO_BIGWIGS[key] == sid) then
                return true
            end
        end
    end
    return false
end

local function CheckBossModMessage(mod, key, encounterID, retried)
    if TRDB().trace then
        AppendLog({ kind = "drop", sid = key, text = "message check: mod=" .. mod
            .. " expectedEncounter=" .. tostring(encounterID) .. " cached=" .. tostring(hasCustomReminders)
            .. " retry=" .. tostring(retried) })
    end
    -- Boss mods can announce opening casts inside their encounter-start handler,
    -- before our handler has populated the encounter and custom-reminder cache. DBM
    -- names no encounter, so for it any message arriving before ours is retried.
    local early
    if encounterID then
        early = currentEncounter ~= encounterID or not hasCustomReminders
    else
        early = currentEncounter == nil and CustomRemindersAllowed()
    end
    if early then
        if not retried then
            C_Timer.After(0, function()
                if currentEncounter ~= nil
                    and (encounterID == nil or currentEncounter == encounterID) then
                    CheckBossModMessage(mod, key, encounterID, true)
                end
            end)
        end
        return
    end
    if bwActiveMod and bwActiveMod ~= mod then return end
    if type(key) ~= "number" then return end
    if not (hasCustomReminders and CustomRemindersAllowed()) then return end
    local set = CustomRemindersTable(false, currentEncounter)
    if not set then return end
    -- Compared through DBM_TO_BIGWIGS on both sides, the way HasMessageDefensive already
    -- does: a reminder saved under one mod's id otherwise suppressed the ability callout
    -- for the other mod's message and then never fired itself.
    local map = ns.DBM_TO_BIGWIGS or {}
    local want = map[key] or key
    local matched = false
    for uid, r in pairs(set) do
        local trig = r.trigger
        if r.enabled ~= false and (not r.specID or r.specID == specID)
            and trig and trig.type == "bwmsg" and (map[trig.spellID] or trig.spellID) == want then
            matched = true
            local hit = true
            if trig.counter and trig.counter ~= "" then
                customCounters[uid] = (customCounters[uid] or 0) + 1
                hit = CheckCounterCondition(ParseCounterCondition(trig.counter), customCounters[uid])
            end
            if TRDB().trace then
                AppendLog({ kind = "drop", sid = key, text = "message matched: " .. (r.name or "Reminder")
                    .. " counterPassed=" .. tostring(hit) .. " delay=" .. tostring(trig.delay)
                    .. " preset=" .. tostring(r.preset) })
            end
            if hit then ActivateCustomReminder(r) end
        end
    end
    if not matched and TRDB().trace then
        AppendLog({ kind = "drop", sid = key, text = "message: no enabled reminder matched" })
    end
    if matched and not bwActiveMod then bwActiveMod = mod end
end

-- barIdentity is whatever the stop/pause event for this mod hands back later -- BigWigs
-- only ever gives the bar TEXT back, DBM only ever gives the timer ID back, so the two
-- mods key their pending timers differently even though everything else is shared. text
-- carries the bar's own occurrence count when the boss mod prints one in parens (BigWigs'
-- "(3)" ability-count suffix) -- that overrides our own tally for the counter check when
-- present, matching what the number on screen actually says.
local function CheckBossModTimerStart(mod, key, barIdentity, duration, text, retried)
    if type(key) ~= "number" or type(duration) ~= "number" then return end
    -- An engage bar can arrive before our own ENCOUNTER_START handler has run: retried next
    -- frame with the time already elapsed taken off the bar.
    if currentEncounter == nil then
        if not retried and CustomRemindersAllowed() then
            local at = GetTime()
            C_Timer.After(0, function()
                if currentEncounter ~= nil then
                    CheckBossModTimerStart(mod, key, barIdentity, duration - (GetTime() - at),
                        text, true)
                end
            end)
        end
        return
    end
    if bwActiveMod and bwActiveMod ~= mod then return end
    if not (hasCustomReminders and CustomRemindersAllowed()) then return end
    local set = CustomRemindersTable(false, currentEncounter)
    if not set then return end
    local barCount = type(text) == "string" and tonumber(text:match("%((%d%d?)%)"))
    local matched = false
    for uid, r in pairs(set) do
        local trig = r.trigger
        if r.enabled ~= false and trig and trig.type == "bwtimer" and trig.spellID == key
           and type(trig.timeleft) == "number" and duration >= trig.timeleft then
            matched = true
            customCounters[uid] = (customCounters[uid] or 0) + 1
            local n = barCount or customCounters[uid]
            local hit = true
            if trig.counter and trig.counter ~= "" then
                hit = CheckCounterCondition(ParseCounterCondition(trig.counter), n)
            end
            if hit and ns.IsReminderEnabled(r) then
                local barKey = uid .. "|" .. mod .. ":" .. tostring(barIdentity)
                -- A re-announced bar (some modules resync a running bar rather than only
                -- ever starting a fresh one) must not stack a second pending fire on top
                -- of the first.
                local old = bwPendingTimers[barKey]
                if old and old.Cancel then old:Cancel() end
                local fireDelay = math.max(duration - trig.timeleft, 0.01)
                ns.pendingCustomReminderOwners[barKey] = r
                bwPendingTimers[barKey] = C_Timer.NewTimer(fireDelay, function()
                    bwPendingTimers[barKey] = nil
                    ns.pendingCustomReminderOwners[barKey] = nil
                    if ns.IsCurrentCustomReminder(r, set) then ActivateCustomReminder(r) end
                end)
            end
        end
    end
    if matched and not bwActiveMod then bwActiveMod = mod end
end

-- kind: "applied" | "removed". destGUID identifies whether the affected unit is a boss --
-- cross-referenced against boss1-boss5, rather than a destFlags hostile-NPC check that
-- would also catch trash adds -- or
-- the player. Reads directly off the combat log rather than through BigWigs/DBM, since
-- SPELL_AURA_APPLIED/REMOVED fire for every aura on every unit regardless of whether any
-- boss module's author chose to announce it, giving this broader coverage than a message
-- trigger ever could for something as generic as "an aura landed."
-- kind "stacks" is SPELL_AURA_APPLIED_DOSE, not another SPELL_AURA_APPLIED occurrence --
-- amount is that event's own new stack count, read straight off the combat log rather
-- than the C_UnitAuras route this addon confirmed live is hard-blocked on a boss unit in
-- restricted content (GetAuraDataByIndex/BySpellID error outright there, for any addon;
-- this sidesteps it since dose count is a plain combat-log field, not an API read).
-- trig.counter here is not the incrementing occurrence tally the other kinds use --
-- CheckCounterCondition is reused as a plain threshold check against the live amount, so
-- "fires at 3+ stacks" is trig.counter = ">=3" checked against amount directly.
local function CheckAuraReminder(kind, destGUID, spellID, amount)
    if not (hasCustomReminders and CustomRemindersAllowed()) then return end
    if type(spellID) ~= "number" or type(destGUID) ~= "string" then return end
    -- Ahead of the GUID tests, not after them: this is the check that says whether there
    -- is anything on this boss to fire at all, and behind it the tests below were being
    -- paid on every aura line of every boss by anyone with a reminder saved on any of them.
    local set = CustomRemindersTable(false, currentEncounter)
    if not set then return end
    local isPlayer = destGUID == PlayerGUID()
    local isBoss = not isPlayer and ns.bossGUIDs[destGUID] == true
    if not (isPlayer or isBoss) then return end
    for uid, r in pairs(set) do
        local trig = r.trigger
        if r.enabled ~= false and trig and trig.type == "aura" and trig.spellID == spellID
           and (trig.auraEvent or "applied") == kind
           and (trig.target == "player") == isPlayer then
            local hit = true
            if kind == "stacks" then
                hit = type(amount) == "number"
                    and CheckCounterCondition(ParseCounterCondition(trig.counter), amount)
            elseif trig.counter and trig.counter ~= "" then
                customCounters[uid] = (customCounters[uid] or 0) + 1
                hit = CheckCounterCondition(ParseCounterCondition(trig.counter), customCounters[uid])
            end
            if hit then ActivateCustomReminder(r) end
        end
    end
end

-------------------------------------------------------------------------------
--  BigWigs/DBM-driven primary callout
-------------------------------------------------------------------------------
-- BigWigs/DBM hand over a real, non-secret identity (see OnBigWigsEvent/OnDBMEvent
-- below), so this decides directly off the spell id rather than through a duration
-- proxy -- the only detection path this addon has.
local lastBWSid, lastBWAt = nil, 0

-- Whether a binding owned by ANOTHER spec is offered to this one. The two axes are OR'd,
-- so "any healer" covers every healing spec without naming them. A binding with no scope
-- is private to the spec that owns it, which is the default and the common case.
function ns.BindingSharedToMe(b)
    local scope = b and b.scope
    if type(scope) ~= "table" then return false end
    if type(scope.roles) == "table" and ns.playerRole and scope.roles[ns.playerRole] then return true end
    if type(scope.classes) == "table" and ns.playerClass and scope.classes[ns.playerClass] then return true end
    return false
end

-- Bindings used to live at abilityBindings[enc][sid], one entry shared by every character
-- on the account. They move under the spec that owns them here. Two shapes arrive:
-- genuinely old entries with no scope, and build 0901a's entries carrying scope.specs --
-- that build stamped ownership but still stored one shared entry, so a second spec touching
-- an ability overwrote the first spec's preset and warning time.
--
-- Ownership comes from scope.specs when 0901a recorded it, otherwise from whoever logs in
-- first. scope.specs is dropped afterwards: the storage key carries that now, and scope is
-- left holding only the role/class shares.
--
-- Deferred to login rather than run inside TRDB: the profile table is often prepared before
-- the spec is known, and filing every binding under spec 0 would be worse than the bug.
function ns.MigrateBindingScopes()
    if specID == 0 then return end
    local t = TRDB()
    if t.bindingsBySpec then return end
    local all = t.abilityBindings
    if type(all) ~= "table" then
        t.bindingsBySpec = true
        return
    end

    local backup, moved, rebuilt = {}, 0, {}
    for encKey, bySpell in pairs(all) do
        if type(bySpell) == "table" then
            local encCopy = {}
            for sid, b in pairs(bySpell) do
                if type(b) == "table" then
                    local copy = {}
                    for k, v in pairs(b) do copy[k] = v end
                    encCopy[sid] = copy

                    -- Which specs this entry belongs to. More than one only happens if
                    -- 0901a's picker was used to name several before this shipped.
                    local owners = {}
                    if type(b.scope) == "table" and type(b.scope.specs) == "table" then
                        for id in pairs(b.scope.specs) do owners[#owners + 1] = tostring(id) end
                    end
                    if #owners == 0 then owners[1] = tostring(specID) end

                    if type(b.scope) == "table" then
                        b.scope.specs = nil
                        if not next(b.scope) then b.scope = nil end
                    end

                    for _, specKey in ipairs(owners) do
                        rebuilt[specKey] = rebuilt[specKey] or {}
                        rebuilt[specKey][encKey] = rebuilt[specKey][encKey] or {}
                        -- Each owner gets its own table: sharing one would restore the very
                        -- aliasing this migration exists to end.
                        local own = {}
                        for k, v in pairs(b) do own[k] = v end
                        if type(b.scope) == "table" then
                            local sc = {}
                            for k, v in pairs(b.scope) do sc[k] = v end
                            own.scope = sc
                        end
                        rebuilt[specKey][encKey][sid] = own
                        moved = moved + 1
                    end
                end
            end
            backup[encKey] = encCopy
        end
    end

    t.abilityBindings = rebuilt
    if moved > 0 and t.preSpecBindings == nil then t.preSpecBindings = backup end
    t.bindingsBySpec = true
    t.scopeMigrated = nil
    if moved > 0 then
        ns.Print(("|cffffa300%d saved abilities|r now belong to the spec that made them. Other specs start clean -- your originals are kept if this guessed wrong.")
            :format(moved))
    end
end

-- Whether a given ability calls out, now that Setup's per-ability checklist
-- (AbilityBindingsTable) is finally load-bearing instead of decorative. No explicit
-- choice yet defaults to on for anything already curated, mirroring the old fingerprint
-- filter's "shipped marks are on by default" so existing users see no coverage
-- regression the moment this ships.
-- On ns rather than staying local: the main chunk is already at Lua's 200-local ceiling
-- (luac -p catches it directly), and a table field costs nothing there.
-- Setup's rows are keyed by whatever spell id the row displays -- the journal id for a
-- boss with no BigWigs module installed, the BigWigs option id when one is (see
-- BigWigsAbilities in Bosses.lua) -- and those two id spaces are not always the same
-- (ns.BOSSMOD_KEY_TO_JOURNAL has the confirmed mismatches). Every sid reaching the
-- engine is always the BigWigs/DBM broadcast key, so all engine-side binding reads go
-- through this resolver, and Setup's own writes go through ns.EnsureBinding below, so a
-- mismatched pair still finds the player's Setup choice instead of silently falling back
-- to defaults.
function ns.BindingForBossModKey(enc, sid)
    local bindings = AbilityBindingsTable(false, enc)
    local b
    if bindings then
        b = bindings[sid]
        if b == nil and ns.BOSSMOD_KEY_TO_JOURNAL then
            local jid = ns.BOSSMOD_KEY_TO_JOURNAL[sid]
            if jid then b = bindings[jid] end
        end
    end
    -- Our own spec's binding wins; a share from another spec only fills the gap.
    if b == nil then b = ns.InheritedBinding(enc, sid) end
    return b
end

-- Write-side counterpart: Setup's checkbox and per-ability cog both need a binding
-- table to write into for a row's spellID. A plain "or {}" there would shadow an
-- existing binding still saved under the journal alias (e.g. anyone who had Possession
-- Barrage configured before its curated id moved to BigWigs' 1292036) with a fresh,
-- empty table the moment the row is touched, orphaning the old preset/mode/enabled
-- choice with no error and no warning. This migrates it onto the new key instead.
-- Which other specs have ability bindings saved, with how many. Feeds the Copy From Spec
-- picker: per-spec storage means a fresh spec starts empty, and rebuilding a whole boss
-- list by hand on every alt is not a reasonable ask.
-- How many abilities THIS spec has inside encSet. Its only job is telling an empty page that
-- happens to be empty from one that is empty because the profile's work sits under a spec
-- you are not currently playing -- which reads as the addon having lost it, and cost an
-- evening proving otherwise on a profile that had imported perfectly.
function ns.OwnBindingCount(encSet)
    if specID == 0 then return 0 end
    local t = TRDB()
    local n = 0
    local all = type(t.abilityBindings) == "table" and t.abilityBindings or nil
    local mine = all and all[tostring(specID)]
    if type(mine) == "table" then
        for eKey, bySpell in pairs(mine) do
            if type(bySpell) == "table" and (not encSet or encSet[eKey]) then
                for _ in pairs(bySpell) do n = n + 1 end
            end
        end
    end
    -- Counted the same way ns.SpecsWithBindings counts other specs, or a spec whose whole
    -- setup is message reminders reads as empty and the page says its work went missing.
    local sets = type(t.customReminders) == "table" and t.customReminders or {}
    for eKey, set in pairs(sets) do
        if type(set) == "table" and (not encSet or encSet[eKey]) then
            for _, r in pairs(set) do
                if type(r) == "table" and r.defensive and r.specID == specID
                    and r.trigger and r.trigger.type == "bwmsg" then
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- encSet mirrors CopyBindingsFromSpec's: when the caller is only going to copy a subset of
-- encounters, the count offered beside each spec has to describe that same subset or it
-- promises abilities the copy will not bring.
function ns.SpecsWithBindings(encounterID, encSet)
    local t = TRDB()
    local all = type(t.abilityBindings) == "table" and t.abilityBindings or {}
    local mine, counts = tostring(specID), {}
    local encKey = tostring(encounterID or 0)
    local function Count(specKey, eKey)
        if specKey == mine or (encSet and not encSet[eKey]) then return end
        local c = counts[specKey]
        if not c then c = { total = 0, here = 0 }; counts[specKey] = c end
        c.total = c.total + 1
        if eKey == encKey then c.here = c.here + 1 end
    end
    for specKey, byEnc in pairs(all) do
        if type(byEnc) == "table" then
            for eKey, bySpell in pairs(byEnc) do
                if type(bySpell) == "table" then
                    for _ in pairs(bySpell) do Count(specKey, eKey) end
                end
            end
        end
    end
    -- Message reminders sit under the boss with a specID field, not under the spec key.
    local sets = type(t.customReminders) == "table" and t.customReminders or {}
    for eKey, set in pairs(sets) do
        if type(set) == "table" then
            for _, r in pairs(set) do
                if type(r) == "table" and r.defensive and r.specID
                    and r.trigger and r.trigger.type == "bwmsg" then
                    Count(tostring(r.specID), eKey)
                end
            end
        end
    end
    local out = {}
    for specKey, c in pairs(counts) do
        out[#out + 1] = { key = specKey, name = ns.SpecName(specKey), here = c.here, total = c.total }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Copies another spec's bindings into this one. Additive: an ability this spec already has
-- is left alone, so copying can never overwrite work already done here. encounterID limits
-- it to one boss; nil takes everything.
--
-- Each binding is copied, never shared by reference -- two specs pointing at one table is
-- the exact aliasing the per-spec split exists to end.
-- encSet, when given, is a set of encounter keys the copy is confined to -- how the Dungeon
-- and Raid lists keep to their own bosses, since a copy launched from the Raid page dragging
-- every dungeon across with it is not what the page says it does. encounterID still names a
-- single boss; with neither, everything is taken.
function ns.CopyBindingsFromSpec(fromSpecKey, encounterID, encSet)
    if specID == 0 then return 0, 0, 0 end
    local t = TRDB()
    local mine = tostring(specID)
    local encKey = encounterID and tostring(encounterID) or nil
    local copied, skipped, reminders = 0, 0, 0

    local all = type(t.abilityBindings) == "table" and t.abilityBindings or nil
    local src = all and all[fromSpecKey]
    -- A spec whose whole setup is message reminders has no binding table at all, and the
    -- picker offers it -- so this returns early from the BINDING pass only.
    if type(src) == "table" then
        all[mine] = all[mine] or {}
        local dst = all[mine]
        for eKey, bySpell in pairs(src) do
            if (not encKey or eKey == encKey) and (not encSet or encSet[eKey])
                and type(bySpell) == "table" then
                dst[eKey] = dst[eKey] or {}
                for sid, b in pairs(bySpell) do
                    if type(b) == "table" then
                        if dst[eKey][sid] ~= nil then
                            skipped = skipped + 1
                        else
                            local copy = {}
                            for k, v in pairs(b) do copy[k] = v end
                            if type(b.scope) == "table" then
                                local sc = {}
                                for k, v in pairs(b.scope) do sc[k] = v end
                                copy.scope = sc
                            end
                            dst[eKey][sid] = copy
                            copied = copied + 1
                        end
                    end
                end
            end
        end
    end

    -- Message reminders sit under the boss carrying a specID, not under the spec key, so
    -- they need their own pass. Same additive rule, with the message key as the identity:
    -- a key this spec already listens for brings nothing across, which is also what stops
    -- a second press stacking duplicates. `have` is built once and not updated as we go,
    -- so a source with two variants on one key (a counter and a plain one) brings both.
    local presets = PresetsTable(specID, false)
    local sets = type(t.customReminders) == "table" and t.customReminders or {}
    for eKey, set in pairs(sets) do
        if (not encKey or eKey == encKey) and (not encSet or encSet[eKey]) and type(set) == "table" then
            local have, fresh = {}, {}
            for _, r in pairs(set) do
                if type(r) == "table" and r.defensive and r.trigger and r.trigger.type == "bwmsg"
                    and (not r.specID or r.specID == specID) then
                    have[r.trigger.spellID] = true
                end
            end
            for _, r in pairs(set) do
                if type(r) == "table" and r.defensive and r.trigger and r.trigger.type == "bwmsg"
                    and tostring(r.specID) == fromSpecKey then
                    if have[r.trigger.spellID] then
                        skipped = skipped + 1
                    else
                        local copy = {}
                        for k, v in pairs(r) do copy[k] = v end
                        copy.trigger = {}
                        for k, v in pairs(r.trigger) do copy.trigger[k] = v end
                        copy.specID = specID
                        -- Preset keys are allocated per spec, so the source's key names a
                        -- different list here or none at all, and the reminder fire path
                        -- takes it as an override with no fall-through: a stale key is a
                        -- reminder that silently never calls anything.
                        if not (presets and presets[copy.preset]) then
                            copy.preset = ActivePresetKey(specID)
                        end
                        fresh[#fresh + 1] = copy
                    end
                end
            end
            for i = 1, #fresh do
                local key
                repeat key = "r" .. math.floor(GetTime() * 1000) .. math.random(1, 9999) until set[key] == nil
                set[key] = fresh[i]
                reminders = reminders + 1
            end
        end
    end
    return copied, skipped, reminders
end

function ns.EnsureBinding(enc, sid)
    local bindings = AbilityBindingsTable(true, enc)
    -- Storage is keyed by spec now, so there is nowhere to file a binding until the spec
    -- resolves. A throwaway table keeps the editor's writes from erroring; they are simply
    -- not persisted, which beats filing them under a spec we would have to guess.
    if not bindings then return {} end
    if bindings[sid] then return bindings[sid] end
    local jid = ns.BOSSMOD_KEY_TO_JOURNAL and ns.BOSSMOD_KEY_TO_JOURNAL[sid]
    if jid and bindings[jid] then
        bindings[sid] = bindings[jid]
        bindings[jid] = nil
        return bindings[sid]
    end
    bindings[sid] = {}
    return bindings[sid]
end

--- Drops an ability from a boss entirely -- either untick, and the counterpart to
--- EnsureBinding above. Clears the journal alias too, or a binding saved under the old id
--- would keep AbilityAdded answering true and the row would come straight back.
function ns.RemoveBinding(enc, sid)
    local bindings = ns.AbilityBindingsTable(false, enc)
    if not bindings then return end
    bindings[sid] = nil
    local jid = ns.BOSSMOD_KEY_TO_JOURNAL and ns.BOSSMOD_KEY_TO_JOURNAL[sid]
    if jid then bindings[jid] = nil end
end

-- Setup's own "Warn This Many Seconds Early" slider is the base every ability uses; a
-- per-ABILITY override (set from that ability's own cog, on the Defensive Preset tab)
-- wins when it has one set -- one warning time for the whole preset, not broken out
-- per defensive within it.
--
-- Positive: warn this many seconds before the hit, as the base slider always does.
-- Negative is the override's alone -- the base slider stops at 1 -- and calls out this
-- many seconds AFTER the hit instead, for a mechanic where the useful moment is once it
-- is over rather than while it is coming (requested for Rav'i's Triple Shot).
function ns.LeadTimeFor(enc, sid)
    local binding = ns.BindingForBossModKey(enc, sid)
    if binding and binding.leadTime then return binding.leadTime end
    return TRDB().leadTime or 3
end

-- Whether the last step -- "call for an external" when nothing of your own is up -- fires for
-- THIS ability. Same shape as the lead time above: the binding answers when it has an opinion,
-- the spec-wide toggle otherwise, and a binding only stores one when it differs from that
-- toggle. Asking for help on every hit that outruns your cooldowns is noise on the ones the
-- raid was never going to answer, so it belongs per ability rather than once for the spec.
function ns.ExternalCallFor(enc, sid)
    local binding = ns.BindingForBossModKey(enc, sid)
    if binding and binding.external ~= nil then return binding.external end
    return TRDB().fallbackOn ~= false
end

-- Nothing calls out until the player has deliberately added it to the boss. The curated
-- tank list no longer switches abilities on by itself -- it marks them in the Add Ability
-- picker instead, so it still says which hits are the real tank busters without choosing
-- for anyone.
function ns.IsAbilityHealerFiltered(enc, sid)
    if ns.HealerRemindersEnabled() then return false end
    local binding = ns.BindingForBossModKey(enc, sid)
    return binding ~= nil and binding.healerReminder == true
end

function ns.AbilityEnabledForBinding(enc, sid, raw)
    local b = ns.BindingForBossModKey(enc, sid)
    if b and b.enabled ~= nil then return b.enabled and (raw or ns.IsReminderEnabled(b)) end
    return false
end

-- Has the player added this ability to this boss at all? A binding is what "added" means;
-- the boss page lists exactly these.
function ns.AbilityAdded(enc, sid)
    return ns.BindingForBossModKey(enc, sid) ~= nil
end

-- sid here is a REAL spellID (BigWigs' key resolved positive, or DBM's own spellId) --
-- never a fingerprint, so no learning/attribution step is needed: identity was handed to
-- us directly, nothing to guess.
-- Everything that decides and shows the actual callout, re-evaluated at FIRE time rather
-- than when the bar/message first arrived -- tanking status, an active defensive, even the
-- ability's own enabled/mode choice can all change across a multi-second bar, and the
-- moment that matters is the one right before the hit lands, not the one the warning
-- started.
local function FireBigWigsAbility(sid, lateRetry, reminder)
    if reminder and not ns.IsReminderEnabled(reminder) then return end
    if lateRetry then
        if not (frame and TRDB().enabled and TRDB().voiceOn
            and ShouldRun() and InEncounter()) then return end
        -- Read the binding again: the visible slots can belong to another warning.
        -- An empty retry must not rebuild frames or extend their display timer.
        local list = EffectiveList(specID, currentEncounter, tostring(sid))
        if not list then return end
        local configured, ready = false, false
        local now = GetTime()
        for i = 1, #list do
            local spellID = list[i]
            if IsSpellAvailable(spellID) and not IsSpellDisabled(spellID) then
                configured = true
                ResyncSpell(spellID)
                if SpellReady(spellID, now) then ready = true break end
            end
        end
        if not configured then return end
        if not ready then return "waiting" end
    end
    if reminder then
        -- ENCOUNTER_START can already be handled while the separate progress API
        -- still returns false for an opening message. Our lifecycle clears this ID
        -- on ENCOUNTER_END and owns cancellation of the delayed reminder timers.
        if not (frame and TRDB().enabled and (ns.testFiring or (canSelect and BossAllowed() and currentEncounter ~= nil))) then
            if TRDB().trace then AppendLog({ kind = "drop", sid = sid,
                text = "message fire gated: frame=" .. tostring(frame ~= nil)
                    .. " enabled=" .. tostring(TRDB().enabled) .. " canSelect=" .. tostring(canSelect)
                    .. " bossAllowed=" .. tostring(BossAllowed()) .. " encounter=" .. tostring(InEncounter()) }) end
            return
        end
    elseif not ns.AbilityEnabledForBinding(currentEncounter, sid) then return end
    -- Mutually exclusive with Custom Reminder: when the ability picker's toggle is set to
    -- Custom Reminder for this exact ability, that reminder (matched separately off the
    -- combat log, see CheckCustomReminders) is the only thing that fires for it -- the
    -- generic priority pick steps aside rather than showing alongside it.
    do
        local binding = ns.BindingForBossModKey(currentEncounter, sid)
        if not reminder and binding and binding.mode == "custom" then
            AppendLog({ kind = "aside", sid = sid })
            return
        end
    end
    if not ns.testFiring then
        -- Pretend Tank lets someone who is not tanking run the whole engine for real, on a
        -- live pull, so a DPS can reproduce and trace a report instead of the fix waiting
        -- on the one person who has the boss. Both gates it lifts are about whether the
        -- hit is coming at YOU; everything downstream -- ability enablement, the priority
        -- pick, cooldown state, covered-skip, the voice -- runs exactly as it would for a
        -- tank, which is the point.
        --
        -- The aggro check still RUNS and still records its verdict, it just does not stop
        -- the callout. A trace taken this way therefore still shows what the gate would
        -- have answered, which is usually the thing being investigated.
        --
        -- The spec's ROLE decides nothing about whether the ability list fires at all. A
        -- raid-wide hit a DPS answers with a personal is the same question a tank buster
        -- asks, put to somebody else, and adding the ability for this spec is already the
        -- answer -- bindings are per spec, so a spec nobody has set up still fires nothing.
        -- This used to refuse outright unless the spec had a tank role, which left the
        -- ability list on every other spec switched on and silent.
        --
        -- The role DOES decide this one sub-gate, automatically: the aggro/threat check
        -- below only makes sense for someone who can actually hold the boss, so it runs
        -- for tank specs and never for anyone else -- a manual toggle used to leave it
        -- mismatched (on for a spec that had since respecced away from tanking), which
        -- silently killed every callout on that spec.
        local pretend = TRDB().pretendTank
        if isTank then
            local verdict, path = TankingCaster(sid)
            lastAggroCheck = { sid = sid, verdict = verdict, path = pretend and not verdict
                and ("pretend/" .. tostring(path)) or path }
            if not verdict and not pretend then
                -- Refusing SILENTLY was the whole problem: 37 broadcasts of a curated tank
                -- ability produced no callout and no log line, so a trace of the pull looked
                -- identical to one where the boss mod never spoke. The threat readings go in
                -- too, since "not tanking any boss" and "threat unreadable" are different
                -- answers that both arrive here as false.
                AppendLog({ kind = "aggro", sid = sid, tankPath = path,
                    tankSid = sid, text = BossThreatSummary() })
                return
            end
        else
            lastAggroCheck = nil
        end
    end

    -- Inspect the incoming preset before rebuilding frames: a skipped warning must
    -- not erase the previous callout while its display timer is still running.
    if not ns.testFiring and TRDB().coveredSkip ~= false then
        local covered, bySid, how = CoveredByActiveDefensive(tostring(sid), reminder and reminder.preset)
        if covered then
            AppendLog({ kind = "skip", sid = bySid or sid, tankSid = sid, tankPath = how })
            return
        end
    end

    if not RebuildSlots(tostring(sid), true, reminder and reminder.preset) then
        if reminder and TRDB().trace then AppendLog({ kind = "drop", sid = sid,
            text = "message: preset has no available configured spells" }) end
        return
    end

    ApplyPriorityAlpha()
    ClearTankGate()
    -- Marks a real callout as showing, same as the old timeline path did (just keyed by
    -- spellID instead of an event id) -- the preview system and the options-panel-close
    -- handler both check this before hiding anything, so it must be set before frame:Show()
    -- or closing Setup mid-fight would yank a live callout off screen.
    ns.activeAuthoredReminder = reminder or ns.BindingForBossModKey(currentEncounter, sid)
    shownForEvent = sid
    -- A second bar callout inside the display window re-arms the hide timer instead of
    -- hiding, so without this it keeps the previous cast's target name under a callout
    -- that has nothing to do with it. ShowOnAlert clears the same label for the same
    -- reason; this path never did.
    if frame.castTarget then frame.castTarget:Hide() end
    frame:Show()
    if textFrame then textFrame:Show() end
    -- A message reminder answers the same ability as the bar callout that ran seconds
    -- earlier, with its own preset, so the repeat window reads the two as one callout
    -- repeating and mutes the second whenever both presets pick the same defensive.
    if reminder then lastAnnouncedSpellID = nil end
    local result = SpeakCallout(sid)
    if hideTimer then hideTimer:Cancel() end
    hideTimer = C_Timer.NewTimer((reminder and reminder.dur) or TRDB().lingerSec or DEFAULTS.lingerSec, HideReminder)
    return result
end

-- Message delays reach the same display, cooldown selection, grouping and audio as bars.
function ns.FireMessageDefensive(r)
    if not ns.IsReminderEnabled(r) then return end
    if TRDB().trace then AppendLog({ kind = "drop", sid = r.trigger and r.trigger.spellID,
        text = "message defensive dispatch: " .. (r.name or "Reminder") }) end
    if not r.preset then return end
    local sid = r.trigger and r.trigger.spellID
    if type(sid) ~= "number" then return end
    return FireBigWigsAbility(sid, false, r)
end

-- Setup's per-ability Test button. Fires the ability through FireBigWigsAbility itself --
-- enablement, Custom Reminder exclusivity, the priority pick, voice, the configured auto-hide --
-- bypassing only the gates a test outside the fight cannot satisfy (tank spec, holding
-- aggro, an active defensive), so what a test plays is what the pull plays. BigWigs' own
-- test mode is no substitute: on retail it plays Blizzard's edit-mode timeline samples
-- and never broadcasts real boss spell ids. On ns: the main chunk is at Lua's 200-local
-- ceiling.
function ns.TestFireAbility(enc, sid, reminder)
    if not TRDB().enabled then
        ns.Print("switch the reminder on first.")
        return
    end
    if reminder and (not ns.IsReminderEnabled(reminder) or (reminder.specID and reminder.specID ~= ns.CurrentSpec())) then
        ns.Print("this message reminder is disabled or belongs to another spec.")
        return
    end
    if not reminder and not ns.AbilityEnabledForBinding(enc, sid) then
        ns.Print("this ability is toggled off for this boss, so it will not call out.")
        return
    end
    local binding = ns.BindingForBossModKey(enc, sid)
    if not reminder and binding and binding.mode == "custom" then
        ns.Print("this ability is set to Ability Reminder; the generic callout stays quiet for it.")
        return
    end
    RefreshSpec()
    ns.Apply()
    local priorEnc = currentEncounter
    currentEncounter = enc
    ns.testFiring = true
    lastAnnouncedSpellID = nil   -- repeat test clicks should not be eaten by the repeat window
    shownForEvent = nil -- a previous successful test must not hide a failed one
    local ok, err = pcall(FireBigWigsAbility, sid, false, reminder)
    ns.testFiring = nil
    currentEncounter = priorEnc
    if not ok then error(err, 0) end
    if shownForEvent ~= sid then
        ns.Print("nothing on your priority list is talented for this spec, so there is nothing to call.")
    elseif not TRDB().voiceOn then
        ns.Print("voice is off, so the test shows the icon only.")
    end
    if not reminder and ns.HasMessageDefensive(enc, sid) then
        ns.Print("this tests the bar callout; the ability's messages fire the reminder under BOSS REMINDERS, which has its own Test.")
    end
end

-- duration, when given, is how many seconds are left on BigWigs'/DBM's own bar (a
-- StartBar/Timer event carries one; a plain Message does not, and fires immediately as it
-- always has). Scheduled to land "Warn This Many Seconds Early" (the same slider the old
-- native-timeline engine used) before the bar actually ends, matching how the custom
-- reminder system's own bwtimer trigger already waits out a bar rather than firing at its
-- start -- the primary engine just never got the same treatment until now.
-- At most one pending fire per sid: a second bar for the same ability arriving while one
-- is already scheduled CANCELS the first and replaces it, rather than the two schedules
-- coexisting. Used to allow a second, far-enough-apart schedule to stand alongside the
-- first (kept for Vorasius' genuinely concurrent double Shadowclaw Slam bar) -- dropped
-- by request, since Vorasius isn't in this season's rotation, in favor of always
-- collapsing to one: Nek'zali's Possession Barrage broadcasts twice for the SAME real
-- cast (a rough predictive bar at each stage transition, self:Bar(1292036, 40+gap, ...),
-- and the accurate one off Blizzard's own encounter timeline once it actually schedules
-- the event) with durations far enough apart that the old 2s proximity check let both
-- through, calling out twice for one hit. The later arrival -- normally the more accurate
-- one, since a rough estimate is what shows up first and gets corrected once the real
-- timeline event exists -- now wins outright.
-- The 3s repeat guard against the last fire that ACTUALLY happened (lastBWSid/lastBWAt,
-- only ever updated at the moment FireBigWigsAbility itself runs, never at schedule time)
-- still applies up front regardless, so a module that broadcasts both an immediate
-- Message and a StartBar for the one real cast -- confirmed as a real BigWigs pattern,
-- e.g. Entombed Sentinels' Empowering Slam pairs a CDBar with a same-key Message -- does
-- not schedule a second callout for the one that already fired.
-- Channel-namespaced so the tank-buster engine and the raid-reminder engine (a separate
-- feature, NaowhUI_SmartReminders_RaidReminders.lua) never collide when both have a
-- pending fire for the same sid -- each channel's own timers are independent.
local pendingBWFires = { tank = {} }   -- [channel][sid] = { [identity] = {fireAt, timer} }

-- The scheduling primitive itself: waits out a BigWigs/DBM bar to fire `lead` seconds
-- before it ends, same duplicate/resync handling regardless of which feature is calling.
-- Exported (ns.ScheduleBWFire) so the raid-reminder engine gets the identical handling
-- instead of a second hand-rolled copy that could drift out of sync with this one on some
-- BigWigs edge case only one of them hits.
-- How close two scheduled fires must be to count as the same real cast. Two boss mods
-- timing one cast land within a frame of each other; the next occurrence of the same
-- buster is a full cooldown away.
local SAME_CAST_WINDOW = 2

-- isApprox is the bar's own flavour, straight from BigWigs: true for :CDBar, the countdown
-- to the NEXT cast, false for :Bar and :CastBar, which describe something already happening.
-- Only entries of the same flavour share identities. A module that starts a debuff bar under
-- the ability's own key -- Rav'i's "Debuffs (N)" under Triple Shot's -- otherwise has that
-- name welded onto the real callout by the inheritance below, and the debuff expiring then
-- cancels a cast that was still coming. Nil counts as a cooldown: DBM sends no flavour and
-- its timers are cooldowns, and pairing its id with BigWigs' text is what aliases are for.
function ns.ScheduleBWFire(channel, sid, duration, barIdentity, lead, fireFn, isApprox, valid)
    local fires = pendingBWFires[channel]
    if not fires then fires = {} pendingBWFires[channel] = fires end
    local sidFires = fires[sid]
    if not sidFires then sidFires = {} fires[sid] = sidFires end
    -- lead 0 means "fire when the bar reaches 0", so the wait is the WHOLE bar. Only a
    -- lead PAST the bar's own length is already inside its window and fires now; treating
    -- 0 that way fired every such reminder the instant its bar started, which for a
    -- boss's opening bar is the moment you enter combat.
    --
    -- Requested for mechanics where the useful moment is after the hit lands, not before
    -- it -- Rav'i's Triple Shot named as the case, called a beat once the volley is over
    -- rather than while it is incoming. A NEGATIVE lead is what that is: the formula below
    -- already reads as "how far past the bar's own end to wait" once lead goes below
    -- zero, so delaying past impact needed no separate mode, only letting the sign through
    -- instead of clamping it away. Per-ability only (the boss page's own Warning Time
    -- slider) -- the spec-wide default stays a positive warning, and the raid-reminder
    -- engine keeps its own explicit floor at zero, unasked-for and untouched here.
    if type(lead) ~= "number" then lead = 0 end
    local delay = (lead < duration) and (duration - lead) or 0.01
    local key = barIdentity or false
    local fireAt = GetTime() + delay

    -- Every schedule call, trace-only: answers whether a stop that later cancels this key
    -- is cancelling THIS bar or one that was already superseded by a more accurate one
    -- under the same name -- the existing "cancel" line can't tell those apart on its own.
    if TRDB().trace then
        local existing = sidFires[key]
        AppendLog({ kind = "schedule", sid = sid, text = tostring(barIdentity),
            duration = duration, isApprox = isApprox, delay = delay,
            existingFireIn = existing and (existing.fireAt - GetTime()) or nil })
    end

    -- Whatever else is pending for this sid -- the same bar resynced, or a different
    -- bar entirely -- gets superseded by this one, but the survivor INHERITS the
    -- superseded entry's identities when both are aimed at the same cast.
    --
    -- A stop event only ever hands back one mod's own name for the bar: BigWigs returns
    -- the bar TEXT, DBM returns a numeric timer id. With both installed, one cast is
    -- timed twice and only the later arrival's identity survived, so a stop from the
    -- other mod matched nothing and the callout still landed for a cast that had been
    -- interrupted or resynced away. Only visible in dungeons, where running both mods is
    -- normal. One entry now answers to every identity that has named it.
    --
    -- Gated on the fire times matching, NOT inherited unconditionally: aliases carried
    -- across to the NEXT occurrence would let the previous bar's ordinary stop cancel the
    -- callout for the cast after it, which is the silent-buster direction.
    -- Three cases, and only the first two end the pending fire.
    --
    -- Same cast: collapse them, and the survivor answers to both identities.
    --
    -- Pending fire is LATER: this bar times the same ability nearer, so the far one is a
    -- stale estimate and goes.
    --
    -- Pending fire is EARLIER: it belongs to a cast still coming, and this bar times the one
    -- after it. Cancelling it was silently dropping that callout -- the next cooldown bar
    -- starts as the current cast lands, which at a short lead is the same moment the fire is
    -- due, so the hit you needed the defensive for lost its call to a bar 24 seconds out.
    -- Captured with the log line this replaces: 18:20:48 "superseded, 24.0s early, by a bar
    -- 24.0s out", one call on the first cast and nothing on the second. Both entries stand;
    -- sidFires is keyed by identity and each clears itself when it fires.
    local uptime = (isApprox == false)
    local aliases = { [key] = true }
    for otherKey, f in pairs(sidFires) do
        if math.abs(f.fireAt - fireAt) <= SAME_CAST_WINDOW then
            if f.timer.Cancel then f.timer:Cancel() end
            if f.uptime == uptime then
                for k in pairs(f.aliases) do aliases[k] = true end
            end
            sidFires[otherKey] = nil
        elseif f.fireAt > fireAt then
            if f.timer.Cancel then f.timer:Cancel() end
            sidFires[otherKey] = nil
        elseif TRDB().trace then
            AppendLog({ kind = "drop", sid = sid,
                text = ("kept a fire %.1fs out, this bar is %.1fs out"):format(
                    f.fireAt - GetTime(), delay) })
        end
    end

    local entry = { fireAt = fireAt, aliases = aliases, uptime = uptime, valid = valid,
        approx = (isApprox == true) }
    entry.endsAt = GetTime() + duration
    local function finish()
        for k in pairs(aliases) do
            if sidFires[k] == entry then sidFires[k] = nil end
        end
    end
    local function attempt()
        if valid and not valid() then finish(); return end
        -- Keep the entry indexed while waiting so stops, resyncs and encounter reset
        -- cancel the retry through the same aliases as the original warning.
        if entry.late and GetTime() >= entry.endsAt then
            if TRDB().trace then
                AppendLog({ kind = "drop", sid = sid, text = "late-ready window expired" })
            end
            finish()
            return
        end
        local result = fireFn(sid, entry.late)
        local remaining = entry.endsAt - GetTime()
        if channel == "tank" and result == "waiting" and remaining > 0 then
            if not entry.late and TRDB().trace then
                AppendLog({ kind = "drop", sid = sid,
                    text = "no cooldown ready; waiting until bar expiry" })
            end
            entry.late = true
            -- No permanent ticker or new event registrations. Work exists only for an
            -- empty warning, at most ten checks per second until this bar's deadline.
            entry.timer = C_Timer.NewTimer(math.min(0.1, remaining), attempt)
        else
            finish()
        end
    end
    entry.timer = C_Timer.NewTimer(delay, attempt)
    -- A kept entry under one of these identities means the module reused the bar text. While
    -- its bar is still running this is the same bar after all, so it ends. Once its bar has
    -- ended this is the next cast, and the kept entry is a call still due after impact (a
    -- negative warning time): it keeps firing, under a key of its own so resets still reach it.
    for k in pairs(aliases) do
        local prev = sidFires[k]
        if prev and prev ~= entry then
            if prev.endsAt <= GetTime() then
                local own = {}
                prev.aliases[own] = true
                sidFires[own] = prev
            elseif prev.timer.Cancel then
                prev.timer:Cancel()
            end
        end
        sidFires[k] = entry
    end
end

-- Settings changes can invalidate raid work without ending the encounter.
function ns.PrunePendingBWFires()
    for _, fires in pairs(pendingBWFires) do
        for _, sidFires in pairs(fires) do
            for key, entry in pairs(sidFires) do
                if entry.valid and not entry.valid() then
                    entry.timer:Cancel()
                    sidFires[key] = nil
                end
            end
        end
    end
end

-- Called only when the account toggle changes; no new ticker or event watcher.
function ns.ApplyReminderFilter()
    ns.PruneCustomReminderTimers()
    ns.PrunePendingBWFires()
    for key, reminder in pairs(ns.pendingCustomReminderOwners) do
        if not ns.IsReminderEnabled(reminder) then
            local handle = bwPendingTimers[key]
            if handle then handle:Cancel() end
            bwPendingTimers[key] = nil
            ns.pendingCustomReminderOwners[key] = nil
        end
    end
    if ns.activeAuthoredReminder and not ns.IsReminderEnabled(ns.activeAuthoredReminder) then
        HideReminder()
    end
    if ns.HideFilteredRaidReminders then ns.HideFilteredRaidReminders() end
    if ns.Integrations then ns.Integrations.Refresh() end
    if ns.BossSource and ns.BossSource() == "timeline" then RegisterEventSounds() end
end

function ns.HandleBigWigsAbility(sid, duration, barIdentity, isRetry, isApprox)
    if type(sid) ~= "number" or sid <= 0 then return end
    if not (frame and TRDB().enabled) then return end
    if InEncounter() then ns.SampleTanking() end
    if not (ShouldRun() and InEncounter()) then
        -- Boss mods receive ENCOUNTER_START before our watcher does and broadcast their
        -- engage bars DURING their own handler, so a bar can arrive here while
        -- currentEncounter is still nil. Confirmed live: Fresh Meat's engage bar was
        -- dropped at the same second as ENCOUNTER START. One next-frame retry is enough
        -- -- by then our own handler has run -- and one only, so a broadcast outside any
        -- encounter does not loop.
        if not InEncounter() and not isRetry then
            C_Timer.After(0, function()
                ns.HandleBigWigsAbility(sid, duration, barIdentity, true, isApprox)
            end)
            return
        end
        if TRDB().trace then
            AppendLog({ kind = "drop", sid = sid,
                text = not InEncounter() and "not in encounter" or "engine gated" })
        end
        return
    end
    if not ns.AbilityEnabledForBinding(currentEncounter, sid) then return end
    -- Both duplicates and next occurrences arrive `lead` seconds after our own fire, so
    -- timing alone cannot separate them -- the presence of a duration can. See each branch.
    local lead = ns.LeadTimeFor(currentEncounter, sid)

    if type(duration) == "number" and duration > 0.5 then
        -- Deliberately NOT repeat-guarded. A repeating tank buster's NEXT bar starts the
        -- instant the current one lands, which is `lead` seconds after we already fired
        -- for it -- indistinguishable by timing alone from the duplicate this guard is
        -- for. Widening the guard to span the lead time swallowed that next bar instead,
        -- and the callout for the following hit never got scheduled at all: reported on
        -- Kings Rest's Golden Serpent as "then it's not calling anything on the next tank
        -- hit". A duplicate costs a moment of attention; a silent buster costs the tank.
        -- ScheduleBWFire already collapses genuine duplicates on this path by superseding
        -- whatever is pending for the sid, so nothing here needs the guard anyway.
        ns.ScheduleBWFire("tank", sid, duration, barIdentity, lead, function(fireSid, lateRetry)
            lastBWSid, lastBWAt = fireSid, GetTime()
            return FireBigWigsAbility(fireSid, lateRetry)
        end, isApprox, function()
            return ns.AbilityEnabledForBinding(currentEncounter, sid)
        end)
    else
        -- A message reminder under BOSS REMINDERS owns this ability's messages and
        -- fires its own preset. Bars stay on the branch above with the ability's own
        -- preset and warning time, so the two run side by side.
        if ns.HasMessageDefensive(currentEncounter, sid) then return end
        -- No duration means this is the cast itself landing, not a countdown to one, and
        -- ours already fired `lead` seconds ago for exactly this cast. The guard belongs
        -- here and only here: a Message cannot be the next occurrence announcing itself,
        -- so widening it cannot swallow the next bar the way it would on the branch above.
        --
        -- Floored at 4 seconds rather than left at lead + 1. A module can send a second
        -- message for the same cast well after the bar ends -- Rav'i's Triple Shot has one
        -- at the end of its 2 second cast -- and at leadTime 1 the window was 2 seconds, so
        -- that follow-up read as a fresh cast and called a second time. A tank buster does
        -- not repeat inside 4 seconds, so nothing real is lost. Short leads are deliberate:
        -- a tank who wants the callout as the hit lands sets one.
        if sid == lastBWSid and (GetTime() - lastBWAt) < math.max(lead + 1, 4) then return end

        -- A plain Message never goes through ScheduleBWFire (no duration to wait out), so
        -- it never touched pendingBWFires -- a module that pairs a StartBar with a same-key
        -- Message for the one real cast (confirmed: Entombed Sentinels' Empowering Slam)
        -- left the StartBar's delayed fire pending regardless of which order the two
        -- arrived in, and it fired again seconds later on top of this immediate one. Same
        -- "whichever arrives last wins" rule ScheduleBWFire itself now follows.
        --
        -- Only fires aimed at THIS cast, which is the rule ScheduleBWFire already applies to
        -- its aliases and this branch did not: a pending fire tens of seconds out belongs to
        -- the NEXT occurrence, and cancelling it is the silent-buster direction. Rav'i sends
        -- Triple Shot twice -- the bar's own Message as it lands, then a PersonalMessage at
        -- the end of the 2s cast -- and the second one arrives lead+2 seconds after our fire.
        -- Past the guard above once the lead is short, so at leadTime 1 it fell through here
        -- and cancelled the next Triple Shot's callout, every other cast. Reported as calling
        -- on some casts and not others, with one tank holding threat throughout.
        local sidFires = pendingBWFires.tank and pendingBWFires.tank[sid]

        -- A genuine (non-uptime) bar still pending for this sid IS the delayed callout a
        -- negative lead asked for -- ScheduleBWFire already scheduled it to land past the
        -- bar's own end. This Message is that same bar completing: Rav'i's own "the bar's
        -- own Message as it lands" above is exactly that CDBar's completion echo, which
        -- reaches HERE with no duration attached and would otherwise fire immediately --
        -- AT impact, defeating the delay -- and then the bar's timer would fire it AGAIN
        -- when the real delay elapses. Skipped in that case; the bar owns firing. Only
        -- falls through and fires now when NO bar is pending, since a Message-only ability
        -- configured with a negative lead has no bar duration to delay past.
        if lead < 0 and sidFires then
            for _, f in pairs(sidFires) do
                if not f.uptime then return end
            end
        end

        if sidFires then
            local thisCastUntil = GetTime() + lead + SAME_CAST_WINDOW
            for key, f in pairs(sidFires) do
                if f.fireAt <= thisCastUntil then
                    if f.timer.Cancel then f.timer:Cancel() end
                    sidFires[key] = nil
                end
            end
        end
        lastBWSid, lastBWAt = sid, GetTime()
        FireBigWigsAbility(sid)
    end
end

-- A bar that stops or pauses before its own scheduled fire has to cancel that fire too,
-- the same as the custom-reminder bwtimer trigger already does for itself -- otherwise the
-- callout lands seconds later for a cast that was interrupted or resynced away, which reads
-- as an unprompted call for an ability that was never actually coming. Walks every
-- channel: a bar stopping is real for every feature listening to it, not just tank busters.
--
-- Only for a PRECISE bar, though. An approximate one (:CDBar -- BigWigs' own flag that the
-- length is an estimate of the NEXT cast, not a timer on something happening) stopping is
-- not the module saying the cast is off; it is the module done guessing. Keyed on the
-- flag BigWigs actually set, not on "not known-precise": DBM sends no flavour at all and
-- its timer stops fire on real interrupts too, so an unflagged entry still cancels.
-- The Hoardmonger (Den of Nalorakk) sends only such bars for Spoiled Supplies, Earthshatter Slam and
-- Ravenous Bellow: all three scheduled approx at ENCOUNTER START (30s/16s/6s), all three
-- stopped together 11s in with nothing ever replacing them, and every callout cancelled --
-- one 0.4s before it was due. Traced twice, no second bar ever arrived under any of those
-- names. Letting the estimate-based fire stand is the same direction every other rule in
-- this file takes: a call at a rough time costs a moment, a swallowed one costs the tank.
-- A precise bar's stop still cancels, since that IS a genuine interrupt or resync, and a
-- superseded approx bar's stop already finds nothing here (ScheduleBWFire cleared it), so
-- the only behaviour that changes is the orphaned-estimate case above. Known cost: an
-- estimate stopped because a phase change retired the ability still fires at its rough
-- time; a wipe does not, since CancelAllPendingBWFires is a separate, unconditional path.
local function CancelPendingBWFire(barIdentity)
    if barIdentity == nil then return end
    for _, fires in pairs(pendingBWFires) do
        for sid, sidFires in pairs(fires) do
            local f = sidFires[barIdentity]
            if f then
                if f.approx and not f.late then
                    if TRDB().trace then
                        AppendLog({ kind = "drop", sid = sid,
                            text = ("kept estimate fire, bar '%s' stopped %.1fs before it"):format(
                                tostring(barIdentity), f.fireAt - GetTime()) })
                    end
                else
                    if f.timer.Cancel then f.timer:Cancel() end
                    -- A cancelled fire is a callout that will now never happen, which from
                    -- the outside is indistinguishable from one that was never scheduled --
                    -- exactly the shape that has cost multiple investigations. Logged for
                    -- the trace, with how far out it still was.
                    AppendLog({ kind = "cancel", sid = sid,
                        text = ("%s (%.1fs before it would have fired)"):format(
                            tostring(barIdentity), f.fireAt - GetTime()) })
                    -- Clear every identity this one entry answers to, not just the name the
                    -- stop happened to arrive under, or the other mod's alias would be left
                    -- pointing at a cancelled timer.
                    for k in pairs(f.aliases) do
                        if sidFires[k] == f then sidFires[k] = nil end
                    end
                end
            end
        end
    end
end

local function CancelAllPendingBWFires()
    for _, fires in pairs(pendingBWFires) do
        for sid, sidFires in pairs(fires) do
            local logged
            for key, f in pairs(sidFires) do
                if f.timer.Cancel then f.timer:Cancel() end
                -- One line per sid, not per alias, and only under trace: boundary cancels
                -- are routine, but a fire still pending when the pull dies is exactly the
                -- "it never called" report shape and must be readable afterward.
                if not logged and TRDB().trace then
                    logged = true
                    AppendLog({ kind = "cancel", sid = sid, text = "encounter reset" })
                end
                sidFires[key] = nil
            end
            fires[sid] = nil
        end
    end
end

-- Both dispatchers below register with a plain function, so the message name arrives as
-- the FIRST argument -- confirmed against BigWigs' and DBM's own dispatch code, not
-- assumed. issecretvalue guards the payload before anything touches it, the same rule
-- every other identity channel in this file follows.
-- BigWigs tags every bar with the length's reliability: only :CDBar -- the cooldown
-- until the NEXT cast, whose length is an estimate -- passes true, while :Bar and
-- :CastBar (exact durations) pass false. That is the only thing separating a repeating
-- ability's next cooldown bar from the UPTIME bar a module starts for the buff the cast
-- just applied, since both begin at the same instant: the moment the cooldown bar ended.
-- Without it every reminder on such an ability fired a second time when the buff expired.
--
-- Deliberately narrow, because dropping a real next-cast bar is the direction that costs
-- someone a wipe: a bar is only read as an uptime when it is unflagged AND a flagged
-- cooldown bar for the SAME key is expiring right now, or is already waiting on a callout
-- of its own. An ability whose module never uses CDBar records nothing here and keeps
-- today's behaviour.
--
-- That second test is the timing-free one, and it is the one that matters: an unflagged bar
-- cannot be the next cast when a flagged bar for the same key is already counting down to
-- one. Rav'i starts a "Debuffs (1)" bar under Triple Shot's own key partway through that
-- countdown -- too early for the window above -- so it was taken for a fresh cooldown,
-- superseded the pending callout, and then cancelled it outright when the debuff bar
-- stopped. Trace of a live pull, 17:49:42: "cancelled pending callout for Triple Shot (bar
-- 'Debuffs (1)' stopped early)", and no callout for that cast at all.
local bwCdEndsAt = {}

-- Verified ordinary-Bar uptimes. Keep these encounter-scoped and match the
-- module's configured rename slot, not English text or duration alone.
-- XathuuxTheAnnihilator:DemonicRageTimeline emits slot 3 as a message and a
-- 15s Bar after its 4s CastBar. Slot 1 is the countdown's base label.
ns.bossModUptimeRules = {
    [3103] = { [474197] = { rename = 3, duration = 15, message = true } },
}

function ns.IsVerifiedBossModUptime(module, key, text, duration, isApprox)
    local encounterRules = ns.bossModUptimeRules[currentEncounter]
    local rule = encounterRules and encounterRules[key]
    if not rule or type(module) ~= "table" or module.engageId ~= currentEncounter
        or type(module.GetRename) ~= "function" then return false end
    if duration ~= nil then
        if isApprox ~= false or duration ~= rule.duration then return false end
    elseif not rule.message then
        return false
    end
    local ok, label = pcall(module.GetRename, module, key, rule.rename)
    local baseOK, base = pcall(module.GetRename, module, key, 1)
    if not ok or not baseOK or (issecretvalue and (issecretvalue(label) or issecretvalue(base)))
        or type(label) ~= "string" or type(base) ~= "string" or label == base
        or text ~= label then return false end
    if TRDB().trace then
        AppendLog({ kind = "drop", sid = key, text = "verified uptime: " .. label })
    end
    return true
end

local function NoteBossModBar(key, duration, isApprox)
    if isApprox and type(duration) == "number" and duration > 0 then
        bwCdEndsAt[key] = GetTime() + duration
    end
end

-- The pending test asks for a COOLDOWN callout specifically. Any pending entry at all was
-- too broad by a wide margin: ScheduleBWFire runs before the enablement check, so nearly
-- every timed key has one, and dropping the bar here returns before NoteBossModBar, the
-- raid engine and the custom-reminder catalogue ever see it -- none of which this was
-- meant to touch. An entry born of a descriptive bar proves nothing either; only a
-- cooldown bar counting down to a cast does.
local function IsUptimeBar(key, isApprox)
    if isApprox then return false end
    for _, fires in pairs(pendingBWFires) do
        for _, f in pairs(fires[key] or {}) do
            if not f.uptime then return true end
        end
    end
    local UPTIME_MATCH_WINDOW = 1.5
    local endsAt = bwCdEndsAt[key]
    return endsAt ~= nil and math.abs(GetTime() - endsAt) <= UPTIME_MATCH_WINDOW
end

local function OnBigWigsEvent(event, ...)
    if ns.BossSource() ~= "bigwigs" then return end
    -- Cataloguing runs ahead of the hasCustomReminders gate below on purpose: that gate
    -- means "does this boss already have a saved reminder", which is exactly backwards
    -- for a picker whose whole job is helping someone create their FIRST one. It still
    -- respects CustomRemindersAllowed -- the feature's own on/off switch and content
    -- gate -- so a player with the feature off, or outside allowed content, records
    -- nothing, matching what the rest of this bridge already treats as "not running".
    if event == "BigWigs_Message" then
        local module, key, text = ...
        if issecretvalue and issecretvalue(key) then return end
        -- Target messages may include a secret player name. Match the readable
        -- option key, keeping protected text out of filters and SavedVariables.
        if issecretvalue and issecretvalue(text) then text = nil end
        if ns.IsVerifiedBossModUptime(module, key, text) then return end
        if CustomRemindersAllowed() then
            RecordBossModKey("BW", key, text, "message", type(module) == "table" and module.engageId or nil)
        end
        if ns.ObserveCast then ns.ObserveCast(key, "BW", nil, nil) end
        ns.HandleBigWigsAbility(key)
        if ns.HandleRaidReminderAbility then ns.HandleRaidReminderAbility(key) end
        CheckBossModMessage("BW", key, type(module) == "table" and module.engageId or nil)
    elseif event == "BigWigs_Timer" then
        -- Bar and CDBar always publish this callback, even with visual bars enabled.
        -- CastBar instead publishes BigWigs_CastTimer. StartBar mixes all three,
        -- so using it scheduled a second warning for Chillstorm's cast/debuff bar.
        -- The regular timer callback retains exact countdowns without guessing their
        -- purpose from the approximate-duration flag or elapsed wall-clock time.
        local module, key, duration, _, text, _, _, isApprox = ...
        if issecretvalue and (issecretvalue(key) or issecretvalue(text) or issecretvalue(duration)) then return end
        if key == nil then return end
        if ns.IsVerifiedBossModUptime(module, key, text, duration, isApprox) then return end
        if CustomRemindersAllowed() then
            RecordBossModKey("BW", key, text, "timer", type(module) == "table" and module.engageId or nil)
        end
        if IsUptimeBar(key, isApprox) then
            if TRDB().trace then
                AppendLog({ kind = "drop", sid = key, text = "uptime bar" })
            end
            return
        end
        NoteBossModBar(key, duration, isApprox)
        if ns.ObserveCast then ns.ObserveCast(key, "BW", duration, text) end
        ns.HandleBigWigsAbility(key, duration, text, nil, isApprox)
        if ns.HandleRaidReminderAbility then ns.HandleRaidReminderAbility(key, duration, text) end
        CheckBossModTimerStart("BW", key, text, duration, text)
    elseif event == "BigWigs_StopBar" or event == "BigWigs_PauseBar" then
        local _, text = ...
        if issecretvalue and issecretvalue(text) then return end
        if ns.ObserveCancel then ns.ObserveCancel(text) end
        CancelPendingBWFire(text)
        if not hasCustomReminders then return end
        CancelBossModTimers("BW", text)
    elseif event == "BigWigs_StopBars" or event == "BigWigs_OnBossDisable" then
        CancelAllPendingBWFires()
        -- The module disabling mid-run (a wipe, before ENCOUNTER_END lands) means the
        -- stage it reported is over; a stale value or an armed phase timer must not
        -- survive into that gap.
        currentStage = nil
        currentStageAt = nil
        if ns.ObserveCancelAll then ns.ObserveCancelAll() end
        ns.CancelTrackedReminderTimers("stage")
        if not hasCustomReminders then return end
        CancelBossModTimers("BW", "")
    elseif event == "BigWigs_SetStage" then
        -- (module, stage) -- read regardless of CustomRemindersAllowed/hasCustomReminders:
        -- the ambient currentStage is stamped onto catalogue entries above whether or not
        -- any reminder cares. Only a CHANGE arms stage triggers -- that is also the
        -- dual-mod arbitration, since the second mod reporting the same stage is a no-op.
        local _, stage = ...
        if issecretvalue and issecretvalue(stage) then return end
        if type(stage) == "number" and stage ~= currentStage then
            currentStage = stage
            currentStageAt = GetTime()
            ns.CancelTrackedReminderTimers("stage")
            if ns.CheckRaidReminderStageTriggers then
                ns.CheckRaidReminderStageTriggers(stage)
            end
        end
    end
end

local function OnDBMEvent(event, ...)
    if ns.BossSource() ~= "dbm" then return end
    -- Same reasoning as OnBigWigsEvent above: cataloguing ignores hasCustomReminders,
    -- since that gate is precisely what a picker needs to work around, and still
    -- respects CustomRemindersAllowed.
    -- The primary engine, the curated list and Setup's rows all speak BigWigs ids, and
    -- DBM keys several of the same warnings by a different id (ns.DBM_TO_BIGWIGS) --
    -- normalized only for HandleBigWigsAbility, while cataloguing and custom-reminder
    -- matching keep DBM's raw id, since that is what DBM actually broadcasts.
    if event == "DBM_Announce" then
        local _, _, _, spellId = ...
        if issecretvalue and issecretvalue(spellId) then return end
        if CustomRemindersAllowed() then RecordBossModKey("DBM", spellId, nil, "message") end
        if ns.ObserveCast then ns.ObserveCast(spellId, "DBM", nil, nil) end
        ns.HandleBigWigsAbility(ns.DBM_TO_BIGWIGS and ns.DBM_TO_BIGWIGS[spellId] or spellId)
        -- Raid Reminders are BigWigs-only by design (see ShowRaidReminderEditor) --
        -- deliberately no ns.HandleRaidReminderAbility call here.
        CheckBossModMessage("DBM", spellId)
    elseif event == "DBM_TimerBegin" or event == "DBM_TimerStart" then
        local id, msg, duration, _, _, spellId = ...
        if issecretvalue and (issecretvalue(spellId) or issecretvalue(id) or issecretvalue(duration)) then return end
        if CustomRemindersAllowed() then RecordBossModKey("DBM", spellId, msg, "timer") end
        -- DBM hands the timer ID back on stop/pause, not the message text, so ID is the
        -- cancellation identity here; msg is only used for count extraction.
        if ns.ObserveCast then ns.ObserveCast(spellId, "DBM", duration, id) end
        ns.HandleBigWigsAbility(ns.DBM_TO_BIGWIGS and ns.DBM_TO_BIGWIGS[spellId] or spellId, duration, id)
        -- Raid Reminders are BigWigs-only by design (see ShowRaidReminderEditor) --
        -- deliberately no ns.HandleRaidReminderAbility call here.
        CheckBossModTimerStart("DBM", spellId, id, duration, msg)
    elseif event == "DBM_TimerStop" or event == "DBM_TimerPause" then
        local id = ...
        if issecretvalue and issecretvalue(id) then return end
        if ns.ObserveCancel then ns.ObserveCancel(id) end
        CancelPendingBWFire(id)
        if not hasCustomReminders then return end
        CancelBossModTimers("DBM", id)
    elseif event == "DBM_SetStage" then
        -- (mod, modId, stage, encounterID, stageTotality). Same change-detected block as
        -- the BigWigs branch; the shared currentStage is what keeps a dual-mod setup from
        -- arming the same phase twice.
        local _, _, stage = ...
        if issecretvalue and issecretvalue(stage) then return end
        if type(stage) == "number" and stage ~= currentStage then
            currentStage = stage
            currentStageAt = GetTime()
            ns.CancelTrackedReminderTimers("stage")
            if ns.CheckRaidReminderStageTriggers then
                ns.CheckRaidReminderStageTriggers(stage)
            end
        end
    end
end

local bwHooked, dbmHooked = false, false
local function RegisterBossModHooks()
    if _G.BigWigsLoader and not bwHooked then
        local ok = pcall(function()
            local BWL = _G.BigWigsLoader
            BWL.RegisterMessage(ns, "BigWigs_Message", OnBigWigsEvent)
            BWL.RegisterMessage(ns, "BigWigs_Timer", OnBigWigsEvent)
            BWL.RegisterMessage(ns, "BigWigs_StopBar", OnBigWigsEvent)
            BWL.RegisterMessage(ns, "BigWigs_PauseBar", OnBigWigsEvent)
            BWL.RegisterMessage(ns, "BigWigs_StopBars", OnBigWigsEvent)
            BWL.RegisterMessage(ns, "BigWigs_OnBossDisable", OnBigWigsEvent)
            BWL.RegisterMessage(ns, "BigWigs_SetStage", OnBigWigsEvent)
        end)
        bwHooked = ok and true or false
    end
    if _G.DBM and not dbmHooked then
        local ok = pcall(function()
            local D = _G.DBM
            -- Both event names registered defensively: the installed DBM fires
            -- DBM_TimerBegin (verified against its own source), but registering the
            -- older DBM_TimerStart name too costs nothing if some fork still sends it.
            D:RegisterCallback("DBM_Announce", OnDBMEvent)
            D:RegisterCallback("DBM_TimerBegin", OnDBMEvent)
            D:RegisterCallback("DBM_TimerStart", OnDBMEvent)
            D:RegisterCallback("DBM_TimerStop", OnDBMEvent)
            D:RegisterCallback("DBM_TimerPause", OnDBMEvent)
            D:RegisterCallback("DBM_SetStage", OnDBMEvent)
        end)
        dbmHooked = ok and true or false
    end
end
ns.RegisterBossModHooks = RegisterBossModHooks

-- Channel 2: the combat log. A different door than the cast bar, with its own secrecy
-- rules, so one being sealed says nothing about the other. No source check is needed: the curated list holds boss tank
-- busters only, so a matching spell id IS the answer regardless of who cast it.
--
-- Registered for the whole session, not per encounter: its registration cannot be toggled
-- from insecure code in restricted content at all. This event fires for every combat action
-- on screen, so the handler must cost nothing outside the one window where it can learn
-- something, which is what the two plain reads at the top of OnCombatLog are for.
-- Mirrors the last ShouldRun() result so OnCombatLog can gate on a plain read. The event
-- is now registered for the whole session (see UpdateEventRegistration), so "feature off
-- during an encounter" is a state the handler must refuse cheaply; calling ShouldRun()
-- itself per combat log line would mean several function calls a line instead of one read.
local runActive = false

local cleuLines, cleuUsable, cleuOwnAuras = 0, 0, 0

local function OnCombatLog()
    -- The price of static registration: this fires for every combat log line, so outside
    -- an encounter it must cost one plain variable read and nothing else -- the
    -- currentEncounter check short-circuits everything after it, including the
    -- RaidRemindersTable lookup, so that lookup's cost is confined to real pulls.
    -- Custom reminders ride the same registration under their own gate
    -- (hasCustomReminders), independent of runActive: a defensive priority list is
    -- not a prerequisite for a boss-pull reminder. Raid reminders' own aura triggers
    -- now ride hasRaidReminders, the same shape as hasCustomReminders. That flag was
    -- live-read here for years because a raid reminder can be added or removed from
    -- several UI entry points and a stale one silently stops firing; what made the
    -- cache safe was making every one of those paths call RefreshCustomRemindersFlag,
    -- so add the refresh before adding another write path.
    -- The dispatcher gates this before the pcall; kept as the function's own contract.
    if currentEncounter == nil then return end
    -- Counted here, ABOVE the secrecy filter, so /nutank can separate three different
    -- reasons Skip When Already Covered can read an empty table: the event never arrived
    -- (lines stays 0), it arrived but every line carried a secret and was discarded
    -- (usable stays 0), or lines survived and the own-buff branch still never matched.
    -- They need opposite fixes. Both counters sit below the currentEncounter gate, so
    -- nothing here costs anything outside a pull.
    cleuLines = cleuLines + 1
    local _, sub, _, sourceGUID, _, _, _, destGUID, _, _, _, spellId, _, _, _, amount = CombatLogGetCurrentEventInfo()
    if issecretvalue and (issecretvalue(sub) or issecretvalue(spellId) or issecretvalue(destGUID)
        or issecretvalue(amount)) then
        return
    end
    cleuUsable = cleuUsable + 1

    -- Feeds TankingCaster: which boss1-5 unit is actually behind a given spell id, for
    -- fights running more than one boss unit at once. Checked on its own, not folded into
    -- the early-return above, so a secret sourceGUID only skips this and never blocks
    -- custom reminders on the same line.
    if type(spellId) == "number" and (sub == "SPELL_CAST_START" or sub == "SPELL_CAST_SUCCESS")
        and not (issecretvalue and issecretvalue(sourceGUID)) then
        castSourceGUID[spellId] = sourceGUID
    end

    -- Feeds CoveredByActiveDefensive: own-buff uptime tracked from these events rather
    -- than polled later, since C_UnitAuras.GetPlayerAuraBySpellID can go quiet on
    -- exactly the aura this needs to see (RequiresNonSecretAura). Gated on runActive,
    -- not hasCustomReminders -- this is core tank-buster behavior, not a custom-
    -- reminders-specific one.
    if runActive and type(spellId) == "number" and destGUID == PlayerGUID() then
        if sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" then
            playerAuraUp[spellId] = true
            cleuOwnAuras = cleuOwnAuras + 1
        elseif sub == "SPELL_AURA_REMOVED" then
            playerAuraUp[spellId] = nil
        end
    end

    -- Raid Reminders' own "aura" trigger -- independent of hasCustomReminders, which
    -- only ever reflects the older CustomRemindersTable. hasRaidReminders is this
    -- feature's own cached flag and every edit path refreshes it (RefreshCustomRemindersFlag),
    -- so it gates the call here instead of the callee re-deriving the same answer -- a
    -- settings-chain walk and a tostring() per line -- on a boss with none saved.
    if hasRaidReminders and ns.CheckRaidReminderAuraTriggers and type(spellId) == "number" then
        if sub == "SPELL_AURA_APPLIED" then
            ns.CheckRaidReminderAuraTriggers("applied", destGUID, spellId)
        elseif sub == "SPELL_AURA_REMOVED" then
            ns.CheckRaidReminderAuraTriggers("removed", destGUID, spellId)
        end
    end

    if hasCustomReminders and type(spellId) == "number" then
        if sub == "SPELL_CAST_SUCCESS" then
            CheckCustomReminders("cast", spellId)
        elseif sub == "SPELL_AURA_APPLIED" then
            CheckCustomReminders("aura", spellId)
            CheckAuraReminder("applied", destGUID, spellId)
        elseif sub == "SPELL_AURA_REMOVED" then
            CheckAuraReminder("removed", destGUID, spellId)
        elseif sub == "SPELL_AURA_APPLIED_DOSE" then
            CheckAuraReminder("stacks", destGUID, spellId, amount)
        end
    end

end


local cleuRegistered = false

local function UpdateEventRegistration()
    if not watcher then return end

    -- ABOVE the ShouldRun gate, and that placement is the whole point. Registering this
    -- HasRestrictions event from insecure code inside restricted content throws
    -- ADDON_ACTION_FORBIDDEN (confirmed live from the main chunk, 11x, on a raid login),
    -- and pcall cannot catch it, so the one legal moment is while standing outside such
    -- content. But ShouldRun() requires TimelineAvailable(), which is false out there --
    -- so with this below that gate the attempt could only ever run in the one place it
    -- cannot succeed, and a whole raid night reported registered=false, lines=0 with the
    -- own-buff tracking never receiving a line. Latched, because unregistering is
    -- forbidden the same way and there is nothing to undo.
    -- MEASURED, and it settles what the probe means: IsCombatLogRestricted() returns true in
    -- a capital city as well as in a Mythic+ dungeon, and registering from the city anyway --
    -- gated on IsInInstance, which reads false there -- raised ADDON_ACTION_FORBIDDEN 13
    -- times off this exact line. The two agree. The combat log is restricted for an insecure
    -- addon everywhere in this build, not merely inside instances, so the probe is accurate
    -- rather than broken and "step outside once" was never going to work.
    --
    -- Kept as the gate for that reason, and because it is self-correcting: if the restriction
    -- is ever relaxed the probe reads false and registration resumes with no change here.
    -- Nothing else can be substituted for it -- a gate that guesses instead throws, and pcall
    -- cannot catch a forbidden call.
    if not cleuRegistered then
        local restricted = C_CombatLog and C_CombatLog.IsCombatLogRestricted
            and C_CombatLog.IsCombatLogRestricted()
        if restricted == false or restricted == nil then
            watcher:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            cleuRegistered = true
        end
    end

    -- Cast history must survive gaps between bosses and empty display presets.
    -- Only the master switch and the configured watch list gate these inputs.
    if TRDB().enabled and #ns.trackedCooldownSpells > 0 then
        watcher:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
        watcher:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    else
        watcher:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        watcher:UnregisterEvent("PLAYER_REGEN_ENABLED")
        watcher:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
    end

    -- Which boss we are on, so a per-boss override can take over from the spec default.
    -- ABOVE the gate, for the reason the off branch below gives for never UNregistering
    -- them: registering them only on the running side left the same latch at FIRST
    -- registration. A player whose active preset is empty at login never passes the gate,
    -- so currentEncounter stays nil all session and every per-boss preset, boss-off and
    -- marks lookup reads as though no boss had been pulled. Seen in a trace that spanned
    -- real pulls with no ENCOUNTER line in it.
    --
    -- The master switch and the client's capabilities still gate them: what the latch turns
    -- on is the priority list, and a client that can never run would announce every pull.
    if TRDB().enabled and canSelect and TimelineAvailable() then
        watcher:RegisterEvent("ENCOUNTER_START")
        watcher:RegisterEvent("ENCOUNTER_END")
    end

    if not ShouldRun() then
        runActive = false
        -- COMBAT_LOG_EVENT_UNFILTERED (a HasRestrictions event) is NEVER unregistered,
        -- matching how the register side already treats it. InCombatLockdown() was the
        -- wrong gate and produced a live ADDON_ACTION_FORBIDDEN on UnregisterEvent from
        -- inside its own guard: toggling a restricted event's registration is forbidden
        -- for insecure code in restricted content generally, not only inside the
        -- secure-frame lockdown window, and ENCOUNTER_START (which calls this) is exactly
        -- that context. pcall cannot catch a forbidden call, so there is no window to
        -- find. OnCombatLog already self-gates on `currentEncounter == nil`, so leaving it
        -- registered costs one plain read per event and changes no behaviour.
        watcher:UnregisterEvent("PLAYER_ALIVE")
        watcher:UnregisterEvent("PLAYER_UNGHOST")
        -- ENCOUNTER_START and ENCOUNTER_END stay registered, always. Dropping them was a
        -- LATCH: ShouldRun() tests BossAllowed(), and the slots it once tested were built
        -- for the boss we are on, which is what these two events establish.
        -- Turning them off is the gate discarding the only thing that could tell it to
        -- come back on.
        --
        -- It fires on a completely ordinary setup. A tank who keeps per-boss lists and an
        -- empty spec default drops to activeSlots == 0 the moment a boss ENDS, because
        -- RebuildSlots falls back to that empty default -- so ENCOUNTER_START is
        -- unregistered on the first kill of the run, and every boss after it never sets
        -- currentEncounter at all. The marks lookup then reads nil, and a boss we ship
        -- data for reports "no tank buster data yet": Murder Row's Zaen, which carries a
        -- mark, came back as an unknown boss for exactly this reason.
        --
        -- Leaving them on costs two plain assignments per pull and gates nothing: alerts
        -- run off the BigWigs/DBM handlers, which test ShouldRun() themselves.
        HideReminder()
        return
    end

    watcher:RegisterEvent("PLAYER_ALIVE")
    watcher:RegisterEvent("PLAYER_UNGHOST")

    runActive = true
end

-- Said once per session, not per pull. The master switch genuinely stops the data; the
-- timeline's own display toggle does not, and warning about that one would nag every
-- boss-mod user for no reason.
local warnedCombatWarnings = false
local saidAudioOnly = false

local function WarnIfMuted()
    if warnedCombatWarnings or not TRDB().enabled then return end
    if not CombatWarningsOff() then return end
    warnedCombatWarnings = true
    ns.Print("|cffff6060Boss Warnings are turned off|r, so the game sends no timeline data and "
        .. "the tank reminder cannot fire. Turn it back on in Options, Advanced, Combat Warnings, "
        .. "Enable Boss Warnings. Hiding the timeline itself is fine and changes nothing here.")
end

-- The BigWigs/DBM-driven callout (ns.HandleBigWigsAbility) has nothing to listen to
-- without one of the two installed -- unlike the native-timeline engine, there is no
-- fallback here by design (see the redesign plan). Said once per session, matching
-- WarnIfMuted's own cadence.
local warnedNoBossMod = false
-- On ns rather than staying local: the main chunk is already at Lua's 200-local ceiling.
function ns.WarnIfNoBossMod()
    if warnedNoBossMod or not TRDB().enabled then return end
    local source = ns.BossSource()
    if source == "timeline" then return end
    if (source == "bigwigs" and _G.BigWigsLoader) or (source == "dbm" and _G.DBM) then return end
    warnedNoBossMod = true
    ns.Print(("|cffff6060Boss Addon is set to %s, but it is not loaded|r -- callouts have "
        .. "nothing to listen to. Install it, or switch Boss Addon on the Smart "
        .. "Reminders Setup tab."):format(
        source == "bigwigs" and "BigWigs" or "DBM"))
end

function ns.Apply()
    if ns.Integrations then ns.Integrations.Refresh() end
    ns.PruneCustomReminderTimers()
    ns.PrunePendingBWFires()
    -- Resolved even while switched off: the list is built BEFORE the feature is enabled, and
    -- an unknown spec silently refuses every add. Two API calls, which is not a cost worth a
    -- bug. Everything expensive still sits behind the gate below.
    RefreshSpec()

    if not TRDB().enabled then
        activeSlots = 0
        HideReminder()
        UpdateEventRegistration()
        ns.ClearEventSounds()
        return
    end

    ProbeCapabilities()
    RefreshSpec()
    Reminder.Create()
    ApplyPosition()
    -- Reminder.Create() only sets the color the first time frame.reminder is built, so a
    -- profile switch (which runs this without recreating an already-existing frame) needs
    -- these called explicitly or it would keep showing the PREVIOUS profile's color.
    ApplyDefensiveTextColor()
    RebuildSlots()
    RebuildCastMap()
    ResyncModel()
    UpdateEventRegistration()
    WarnIfMuted()
    ns.WarnIfNoBossMod()

    -- Redone whenever what should be registered no longer matches what is: the switch, the
    -- file (a profile switch can change it) or Boss Addon moving off the timeline.
    if not (ns.soundFile and ns.soundFile == ResolveSoundFile() and TRDB().soundOn
        and ns.BossSource() == "timeline" and ns.HealerRemindersEnabled()) then
        RegisterEventSounds()
    end
end

-------------------------------------------------------------------------------
--  Preview
-------------------------------------------------------------------------------
-- The settings panel is the only window in which anyone needs something to drag, so the
-- stand-in lives exactly as long as it does. Alpha is set directly here rather than through
-- the gate: out of an encounter there is no event to gate against. Declared far above,
-- with the rest of the frame state, because the hide timers read it from there.
-- The visible half of the preview switch: previewing says the options window is open,
-- previewPin says the player wants the stand-in on screen. Both must hold. Pinned on by
-- default so the preview appears the moment the page opens -- tester feedback was not
-- "the preview is intrusive" but "I cannot find it".
local previewPin = true
-- Held true by anchor config mode (Customize Anchors), where the defensive alert is
-- one of the placeable displays -- independent of the window being open.
local configPreview = false

local function UpdatePreview()
    if not ((previewing and previewPin) or configPreview) then
        -- Strip the preview's drag affordances the moment it stops being a preview: a
        -- mouse-enabled alert frame in a fight would sit invisibly over the screen
        -- eating clicks.
        if frame then
            frame:EnableMouse(false)
            frame:SetScript("OnDragStart", nil)
            frame:SetScript("OnDragStop", nil)
        end
        -- Never yank a live call-out off the screen because the settings panel closed.
        if frame and not shownForEvent then frame:Hide() end
        if textFrame and not shownForEvent then textFrame:Hide() end
        if bar and not shownForEvent then bar:Hide() end
        return
    end
    -- No gate on the master switch here: everything ships OFF, so the addon is still
    -- disabled at exactly the moment someone is placing and sizing the alert.

    Reminder.Create()
    RebuildSlots()

    -- The preview doubles as the placement tool: drag it and the position saves to the
    -- same slot Unlock Mode writes. Mouse and movability exist ONLY while the preview is
    -- up -- the early-return branch above strips them -- so the fight-time alert stays a
    -- pure display that can never eat a click. The text is not draggable: it rides the
    -- icon, on the side the Text Position option picks.
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        if point then
            TRDB().pos = { point = point, relPoint = relPoint, x = x, y = y }
        end
        ApplyPosition()
    end)


    -- An empty or fully switched-off list previews a stand-in in slot 1, so Show Icon
    -- and the size/position tools work before any ability has been enabled.
    local slot = slots[1]
    if activeSlots == 0 then
        slot = slot or CreateSlot(1)
        slot.spellID = nil
        slot.iconID = 134400
        slot.icon:SetTexture(134400)
        slot.label:SetText("Defensive")
        ApplySize()
    end
    slot:SetAlpha(1)
    slot.icon:SetAlpha(1)
    -- Config mode forces every channel visible, matching the other anchors' samples:
    -- on a fresh install each channel still ships off, and that is exactly when the
    -- alert is being placed.
    slot.icon:SetShown((TRDB().showIcon or configPreview) and true or false)
    -- The text channel previews too: the label carries exactly what a fight would show
    -- for this slot, so moving and sizing is done against the real thing.
    if slot.label then
        if activeSlots > 0 then
            local sid = slot.spellID
            local si = sid and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
            slot.label:SetText(CalloutFor(sid, si and si.name))
        end
        slot.label:SetShown((TRDB().showText or configPreview) and true or false)
    end
    -- The stand-in shows the winning line, not the fallback: a preview of "nothing is ready"
    -- is not what anyone is trying to position.
    if frame.fallback then frame.fallback:SetAlpha(0) end
    if TRDB().showBar or configPreview then
        CreateBar()
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0.6)
        if bar.fill then bar.fill:SetAlpha(1) end
        if bar.bg then bar.bg:SetAlpha(1) end
        bar:Show()
    elseif bar then
        bar:Hide()
    end
    frame:Show()
    textFrame:Show()
end

-- The anchor-config half of the defensive alert: config mode shows it through the
-- preview machinery above, so dragging and the saved position slot are shared.
function ns.SetDefensiveAnchorConfigShown(shown)
    configPreview = shown and true or false
    UpdatePreview()
end

function ns.GetDefensiveAlertFrame()
    return frame, bar
end

function ns.RefreshDefensivePreview()
    ApplySize()
    UpdatePreview()
end

-- Re-seat the alert from its saved slot after a config-mode drag, the same call the
-- preview's own drag handler makes.
function ns.ApplyDefensiveAlertPosition()
    ApplyPosition()
end

-------------------------------------------------------------------------------
--  Diagnostics
-------------------------------------------------------------------------------
-- /nutank -- the two things that cannot be settled from Blizzard's source.
--
--   catalogue : C_EncounterEvents carries no secret annotations at all, so the full list of
--               authored boss abilities and their TankRole bits should read in the clear.
--               This is what tells a silent test apart from a broken one.
--   gate      : what the engine actually does to a texture whose icon bit is absent is
--               documented only as "atlases and alpha values" -- the absent case is not
--               specified, and Blizzard never reads these textures back. Run this on a live
--               boss with an ability on the timeline.
-- Everything that can make a capture worthless, checked in one place. A tester who sends
-- back "0 entries" has learned nothing and neither has the person reading it, and that has
-- now happened -- trace on, no priority list, not a tank, Pretend Tank off, so there was
-- never anything to record. Every one of those is stated up front instead.
local function DiagProblems()
    local t, out = TRDB(), {}
    if t.enabled ~= true then
        out[#out + 1] = "the reminder is switched OFF -- turn it on in Smart Reminders"
    end
    -- Read from the active preset itself, not activeSlots: those hold whatever was built
    -- last, a boss preset or a text-only alert, and blamed a preset that was fine. Named,
    -- because "your list is empty" sent a reporter looking at five populated presets.
    local key = ActivePresetKey(specID)
    local presets = key and PresetsTable(specID, false)
    local p = presets and presets[key]
    if type(p) ~= "table" then
        out[#out + 1] = "this spec has no cooldown preset, so a callout without one of its "
            .. "own stays silent -- make one under Cooldown Presets"
    else
        local castable = false
        for _, sid in ipairs(type(p.list) == "table" and p.list or {}) do
            if IsSpellAvailable(sid) and not IsSpellDisabled(sid) then
                castable = true
                break
            end
        end
        if not castable then
            local name = (type(p.name) == "string" and p.name ~= "" and p.name)
                or "the selected preset"
            out[#out + 1] = ("nothing on your active preset (%s) can be cast on this "
                .. "character, so a callout falling back to it stays silent -- pick another "
                .. "one under Cooldown Presets. Callouts bound to a preset of their own "
                .. "still fire."):format(name)
        end
    end
    -- No instruction any more: the client refuses the registration everywhere in this build,
    -- so there is nothing a tester can do about it and the old "step outside once" line sent
    -- several of them on a walk that could not have worked.
    if watcher and not watcher:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED") then
        out[#out + 1] = "the client refuses the combat log to addons in this build, so Skip "
            .. "When Already Covered has no aura data -- it runs on your own casts instead, "
            .. "for " .. tostring(TRDB().coveredCastWindow or OWN_CAST_COVER_DEFAULT)
            .. "s after you press one"
    end
    if not TimelineAvailable() then
        out[#out + 1] = "the boss timeline feature is unavailable here"
    end
    return out
end

SLASH_NAOWHUITANK1 = "/nutank"
SlashCmdList["NAOWHUITANK"] = function(msg)
    msg = msg or ""
    local arg = msg:lower():match("^%s*(%S*)")
    -- Case preserved: the remainder names the pack, and that name is what the
    -- importer's profile ends up called.
    local rest = msg:match("^%s*%S*%s+(.-)%s*$")
    ProbeCapabilities()
    RefreshSpec()

    -- "It did not work at all on that boss" has now cost three separate investigations,
    -- because nothing distinguished "the ability never broadcast" from "it broadcast and we
    -- ignored it". RecordBossModKey has been storing exactly that all along with no way to
    -- read it back. Per encounter, so it answers for whichever boss is being complained
    -- about rather than only the current one.
    -- Recording is a persisted flag, not a session one: a key run can span a reload, and a
    -- trace that silently stopped at the first loading screen would be worse than none.
    if arg == "pretendtank" then
        local t = TRDB()
        t.pretendTank = not t.pretendTank and true or nil
        if t.pretendTank then
            ns.Print("|cffF0A830PRETEND TANK ON|r -- callouts now fire for tank busters even "
                .. "though you are not tanking. For testing only; turn it back off before "
                .. "playing normally. The aggro check still records what it WOULD have said.")
            local problems = DiagProblems()
            for i = 1, #problems do ns.Print("  |cffff6060still blocked:|r " .. problems[i]) end
        else
            ns.Print("|cff6DD09APretend Tank off|r -- back to normal tank-only behaviour.")
        end
        return
    end

    -- Handing work back to the curator whose profile this is. Not on the Profiles tab on
    -- purpose: the button there is for sharing something you built, and it refuses a profile
    -- that came from somebody else's pack, which is the right answer for everyone except the
    -- handful of people maintaining part of that pack. The refusal deliberately does NOT
    -- name this command any more: telling everyone who hit it how to get round it is how a
    -- licensed pack left as a licence-free string. Contributors are told it directly.
    if arg == "share" then
        if not ns.ExportPack then
            ns.Print("this build has no profile export.")
            return
        end
        local packName = (rest and rest ~= "") and rest or "Naowh"
        local str, err = ns.ExportPack(packName,
            UnitName and UnitName("player"), true)
        if not str then ns.Print("|cffff6060" .. tostring(err) .. "|r") return end
        if ns.ShowDiagExport then
            ns.ShowDiagExport(str)
            ns.Print("your whole active profile, ready to send back. It is marked as worked "
                .. "on from their pack, so they can see what it is.")
        else
            ns.Print("|cffff6060nowhere to show the string in this build.|r")
        end
        return
    end

    if arg == "trace" then
        local t = TRDB()
        t.trace = not t.trace and true or nil
        if t.trace then
            if type(t.callLog) == "table" then wipe(t.callLog) end
            ns.Print("|cff6DD09Atrace ON|r -- run your key, then /nutank trace again to stop "
                .. "and /nutank export to get the text to send.")
            local problems = DiagProblems()
            for i = 1, #problems do
                ns.Print("  |cffff6060this trace will capture nothing:|r " .. problems[i])
            end
        else
            ns.Print(("|cffF0A830trace OFF|r -- %d entries recorded. /nutank export opens them "
                .. "in a copyable box."):format(type(t.callLog) == "table" and #t.callLog or 0))
        end
        return
    end

    -- Splits a callout's cost in two: choosing the defensive, and Windows speaking its
    -- name. A session flag, not a saved one -- this is measured across one pull and read
    -- back straight away, and a profiler left on across a reload is a profiler nobody
    -- remembers turning on.
    if arg == "speaktime" then
        local pr = ns.speakProf
        if not pr then
            ns.speakProf = { pickN = 0, pickSum = 0, pickMax = 0,
                             ttsN = 0, ttsSum = 0, ttsMax = 0 }
            ns.Print("|cff6DD09Acallout timing ON|r -- pull once, then /nutank speaktime "
                .. "again to stop and read it.")
            if not TRDB().voiceOn then
                ns.Print("  |cffff6060this will record nothing:|r Speak Which Defensive to "
                    .. "Use is off, and that switch gates the whole callout.")
            end
            return
        end
        ns.speakProf = nil
        if pr.pickN == 0 then
            ns.Print("|cffF0A830callout timing OFF|r -- no callouts fired, so there is "
                .. "nothing to report.")
            return
        end
        ns.Print(("|cff0091edcallout timing|r (build %s), %d callout(s):")
            :format(BuildString(), pr.pickN))
        ns.Print(("  choosing the defensive: avg %.2fms, worst %.2fms, total %.0fms")
            :format(pr.pickSum / pr.pickN, pr.pickMax, pr.pickSum))
        if pr.ttsN > 0 then
            ns.Print(("  speaking it: avg %.2fms, worst %.2fms, total %.0fms, %d utterance(s)")
                :format(pr.ttsSum / pr.ttsN, pr.ttsMax, pr.ttsSum, pr.ttsN))
        else
            ns.Print("  speaking it: never reached -- every callout was suppressed or muted.")
        end
        -- The whole point of the split. Windows synthesises on the calling thread, so time
        -- inside SpeakText is the client standing still.
        local worst = pr.ttsMax > pr.pickMax and "speaking" or "choosing"
        ns.Print(("  worst single frame was |cffF0A830%s|r, at %.2fms.")
            :format(worst, math.max(pr.ttsMax, pr.pickMax)))
        return
    end

    if arg == "export" then
        local t = TRDB()
        local log = type(t.callLog) == "table" and t.callLog or {}
        local out = {}
        out[#out + 1] = ("build %s | spec %d | tank %s | pretendTank %s | slots %d | trace %s"):format(
            BuildString(), specID, tostring(isTank), tostring(t.pretendTank and true or false),
            activeSlots, tostring(t.trace and true or false))
        -- inInstance is the one that decides whether registering can happen; restrictedHere
        -- reads true everywhere and is kept only so a future report can show it still does.
        out[#out + 1] = ("combat log registered=%s inInstance=%s restrictedHere=%s lines=%d usable=%d ownAuras=%d"):format(
            tostring(watcher:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED")),
            tostring(IsInInstance()),
            tostring(C_CombatLog and C_CombatLog.IsCombatLogRestricted
                and C_CombatLog.IsCombatLogRestricted()),
            cleuLines, cleuUsable, cleuOwnAuras)
        out[#out + 1] = ("timeline=%s aggroGate=%s coveredSkip=%s leadTime=%s"):format(
            tostring(TimelineAvailable()), tostring(isTank), tostring(t.coveredSkip ~= false),
            tostring(t.leadTime))
        out[#out + 1] = ("%d entries"):format(#log)
        local problems = DiagProblems()
        for i = 1, #problems do out[#out + 1] = "PROBLEM: " .. problems[i] end
        if #log == 0 and #problems == 0 then
            out[#out + 1] = "PROBLEM: nothing recorded, but the setup looks able to call -- "
                .. "either no pull happened while tracing, or no boss mod broadcast a "
                .. "curated ability (check /nutank keys during a pull)"
        end
        for i = 1, #log do out[#out + 1] = LogLine(log[i]) end
        ns.AppendChargeAudit(out)
        local text = table.concat(out, "\n")
        if ns.ShowDiagExport then
            ns.ShowDiagExport(text)
        else
            ns.Print(text)
        end
        return
    end

    if arg == "observed" then
        -- Falls back to the last pull committed this session: ENCOUNTER_END nils
        -- currentEncounter, so without this the command is unusable in the one moment
        -- anyone actually runs it -- right after the boss dies.
        local enc = currentEncounter
        if not enc and ns.ObservedLastPull then enc = ns.ObservedLastPull() end
        if not enc then
            ns.Print("no pull to report yet. Fight a boss with BigWigs or DBM running, or "
                .. "open the Ability Reminders tab to browse what has been recorded.")
            return
        end
        local diffs = ns.ObservedDifficulties and ns.ObservedDifficulties(enc) or {}
        if #diffs == 0 then
            ns.Print(("nothing recorded for encounter %s yet. Recording rides the boss "
                .. "mods, so it needs Boss Addon set to BigWigs or DBM (currently %s), and "
                .. "a real boss encounter -- trash fires no encounter events."):format(
                tostring(enc), ns.BossSource()))
            return
        end
        if not currentEncounter then
            ns.Print(("|cff9a9ea6last pull, encounter %s|r"):format(tostring(enc)))
        end
        for _, d in ipairs(diffs) do
            local block = ns.ObservedFor(enc, tonumber(d.key))
            local name = GetDifficultyInfo and GetDifficultyInfo(tonumber(d.key))
            ns.Print(("|cff0091edobserved|r %s (%s): %d pull(s), longest %.0fs"):format(
                tostring(name or "?"), d.key, block.pulls or 0, block.longest or 0))
            for sid, list in pairs(block.casts or {}) do
                local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                local parts = {}
                for i = 1, #list do
                    local s = list[i]
                    if s and s.t then
                        parts[#parts + 1] = ("%d:%04.1f%s"):format(math.floor(s.t / 60),
                            s.t % 60, (s.stage and s.stage > 1) and ("(P" .. s.stage .. ")") or "")
                    end
                end
                ns.Print(("  %d %s -- %s"):format(sid, (info and info.name) or "?",
                    table.concat(parts, ", ")))
            end
        end
        return
    end

    if arg == "keys" then
        local enc = currentEncounter
        local cat = enc and BossModCatalogueTable(false, enc)
        if not cat or not next(cat) then
            ns.Print(enc
                and ("nothing recorded for encounter %s yet. Either no boss mod broadcast "
                    .. "anything, or this ran outside a pull."):format(tostring(enc))
                or "not in an encounter, so there is nothing to attribute keys to. Run this "
                    .. "during or right after a pull.")
            return
        end
        ns.Print(("|cff0091edboss mod keys|r seen this pull (encounter %s):"):format(tostring(enc)))
        for key, e in pairs(cat) do
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(key)
            local curated = ns.TANK_ABILITIES and ns.TANK_ABILITIES[key]
            local on = ns.AbilityEnabledForBinding(enc, key)
            local binding = ns.BindingForBossModKey(enc, key)
            local verdict
            if on and binding and binding.mode == "custom" then
                verdict = "|cff9a9ea6steps aside to its Ability Reminder|r"
            elseif on then
                verdict = "|cff6DD09Awould call|r"
            else
                verdict = "|cffff6060OFF for this boss|r"
            end
            ns.Print(("  %d %s -- %s/%s x%d -- %s, %s"):format(
                key, (info and info.name) or "?", tostring(e.mod), tostring(e.kind),
                e.seen or 0,
                curated and "in the tank list" or "|cff9a9ea6not a tank ability|r",
                verdict))
        end
        return
    end

    if arg == "catalogue" or arg == "catalog" then
        if not (C_EncounterEvents and C_EncounterEvents.GetEventList) then
            ns.Print("C_EncounterEvents is not available on this client.")
            return
        end
        local ids = C_EncounterEvents.GetEventList()
        local total, tank, unreadable = 0, 0, 0
        for i = 1, #ids do
            local info = C_EncounterEvents.GetEventInfo(ids[i])
            if info then
                total = total + 1
                -- bit.band on a secret raises, so the read is pcall'd rather than trusted:
                -- the whole point of this probe is that the docs say these are plain and
                -- only the client can confirm it.
                -- Reduced to a plain number INSIDE the guard. Returning the comparison
                -- itself hands back a secret boolean that the branch below then throws on,
                -- outside the pcall, which is the guard catching nothing.
                local ok, isTankFlag = pcall(function()
                    return bit.band(info.icons, Enum.EncounterEventIconmask.TankRole) ~= 0
                        and 1 or 0
                end)
                if not ok then
                    unreadable = unreadable + 1
                elseif isTankFlag == 1 then
                    tank = tank + 1
                end
            end
        end
        ns.Print(("catalogue: %d events, %d tank-flagged, %d unreadable"):format(total, tank, unreadable))
        return
    end

    -- The decisive test for spoken callouts. A spell whose cooldown secrecy is NeverSecret
    -- keeps reading plainly THROUGH combat restrictions, because per-spell flags override
    -- them -- so if your defensives come back NeverSecret, voice works everywhere. If they
    -- are ContextuallySecret, voice is out-of-combat only and there is no way around it.
    -- Run this once at rest and once mid-pull; the restriction lines should differ.
    if arg == "secrecy" or arg == "voice" then
        local list = UserList(specID, false)
        if not (list and #list > 0) then
            ns.Print("no priority list for this spec yet -- add a defensive first.")
            return
        end
        if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive and Enum.AddOnRestrictionType then
            local parts = {}
            for _, key in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch" }) do
                local rt = Enum.AddOnRestrictionType[key]
                if rt then
                    local on = C_RestrictedActions.IsAddOnRestrictionActive(rt)
                    parts[#parts + 1] = ("%s=%s"):format(key, on and "ON" or "off")
                end
            end
            ns.Print("restrictions: " .. table.concat(parts, "  "))
        end
        for i = 1, #list do
            local sid = list[i]
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
            ns.Print(("%d. %s -- secrecy=%s speakable_now=%s"):format(
                i, (info and info.name) or sid, SecrecyLevelName(sid), tostring(CanNameSpellAloud(sid))))
        end
        return
    end

    -- Ahead of the status block, like every other subcommand: it sits in a separate file, so
    -- saying plainly that the file is missing beats printing nothing and looking dead.
    -- Does Blizzard actually flag YOUR defensives? The predicate is real, but which spell
    -- ids carry the flag is client data no source can answer. This dumps it for the spells
    -- the picker is offering, plus anything already on your list.
    if arg == "defensives" then
        local shown = 0
        for _, slot in ipairs({ INVSLOT_TRINKET1, INVSLOT_TRINKET2 }) do
            local link = GetInventoryItemLink("player", slot)
            if link and C_Item and C_Item.GetItemSpell then
                local spellName, spellID = C_Item.GetItemSpell(link)
                ns.Print(("trinket slot %d: %s -> %s"):format(slot, link,
                    spellID and ("%s (%d)"):format(tostring(spellName), spellID) or "no on-use spell"))
            else
                ns.Print(("trinket slot %d: empty"):format(slot))
            end
        end
        local CV = C_CooldownViewer
        if CV and CV.GetCooldownViewerCategorySet and Enum and Enum.CooldownViewerCategory then
            for _, cat in ipairs({ Enum.CooldownViewerCategory.Essential,
                                  Enum.CooldownViewerCategory.Utility }) do
                local ids = CV.GetCooldownViewerCategorySet(cat, false)
                for i = 1, (ids and #ids or 0) do
                    local info = CV.GetCooldownViewerCooldownInfo(ids[i])
                    if info and info.isKnown then
                        local sid = info.spellID
                        local si = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                        local flag = false
                        if C_UnitAuras and C_UnitAuras.AuraIsBigDefensive then
                            local ok, v = pcall(C_UnitAuras.AuraIsBigDefensive, sid)
                            flag = ok and v and true or false
                        end
                        local ext = false
                        if C_Spell and C_Spell.IsExternalDefensive then
                            local ok2, v2 = pcall(C_Spell.IsExternalDefensive, sid)
                            ext = ok2 and v2 and true or false
                        end
                        shown = shown + 1
                        -- Everything the filter looks at, so a missing spell can be traced to
                        -- the signal that failed rather than guessed at.
                        ns.Print(("%s (%d) bigDef=%s ext=%s selfAura=%s hasAura=%s -> %s"):format(
                            (si and si.name) or "?", sid, tostring(flag), tostring(ext),
                            tostring(info.selfAura), tostring(info.hasAura),
                            ns.InfoIsDefensive(info) and "|cff6DD09AINCLUDED|r" or "|cffff6060skipped|r"))
                    end
                end
            end
        end
        if shown == 0 then
            ns.Print("the Cooldown Manager returned nothing -- open it once, then retry.")
        end
        return
    end

    -- Checks ns.TANK_ABILITIES -- the file header says GENERATED, regenerate rather than
    -- hand-edit, and Tactyks' sheet is not something this addon can re-derive -- against
    -- the one thing that can outrank it: Blizzard's own Dungeon Journal role flags, the
    -- same data the boss page itself already shows next to each ability. Built to close
    -- out a live case the hard way: the picker tagged Triple Shot [tank hit] from this
    -- list while the boss page, reading the Journal, showed it Healer -- and the Journal
    -- was right, confirmed independently that same week by how the ability actually
    -- fires (a PersonalMessage targeted by the mechanic, never by threat). A static
    -- source-code read of the community modules found the boundary of what it could
    -- settle -- most curated abilities carry no GetOptions role tag at all whether or not
    -- they are genuinely tank mechanics, so absence there proves nothing on its own. Only
    -- live Journal data, walked here the same way the boss page already trusts it, can.
    if arg == "tanksheet" then
        local cache = ns.ScrapeBosses and ns.ScrapeBosses()
        if not cache then
            ns.Print("the journal has not been scraped yet -- open a Dungeon Bosses or "
                .. "Raid Bosses page once, then retry.")
            return
        end
        local extrasFor = {}
        for i = 1, #cache.instances do
            local inst = cache.instances[i]
            for j = 1, #inst.bosses do
                local abilities = inst.bosses[j].abilities
                for k = 1, #abilities do
                    local a = abilities[k]
                    if a.spellID then extrasFor[a.spellID] = a.extras end
                end
            end
        end
        -- Only these three are ROLE flags. Heroic, Deadly, Magic and the rest say when an
        -- ability happens or what it does, never who it is aimed at, so an ability carrying
        -- only those has not been classified by role at all.
        local ROLE_FLAGS = { "Tank", "Dps", "Healer" }
        local function NamesARole(extras)
            for i = 1, #ROLE_FLAGS do
                if extras:find(ROLE_FLAGS[i], 1, true) then return true end
            end
            return false
        end

        local checked, agree, contra, unconfirmed, noData = 0, 0, 0, 0, 0
        local contraLines, unconfLines = {}, {}
        local curated = ns.TANK_ABILITIES or {}
        local ids = {}
        for sid in pairs(curated) do ids[#ids + 1] = sid end
        table.sort(ids)
        ns.Print(("|cff0091edtank sheet cross-check|r against %d journal-scraped bosses:")
            :format(#cache.instances))
        for i = 1, #ids do
            local sid = ids[i]
            checked = checked + 1
            local extras = extrasFor[sid]
            local si = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
            local name = (si and si.name) or tostring(sid)
            if extras == nil then
                noData = noData + 1
            elseif extras:find("Tank", 1, true) then
                agree = agree + 1
            elseif NamesARole(extras) then
                -- The journal named a DIFFERENT role. This is the case worth acting on: the
                -- Triple Shot entry that had to come out read exactly like this.
                contra = contra + 1
                contraLines[#contraLines + 1] =
                    ("  |cffff6060%s|r (%d) -- journal says: %s"):format(name, sid, extras)
            else
                -- No role flag either way. Not evidence against us: Apex Predator lands here
                -- while BigWigs' own module renames it CL.tank_combo.
                unconfirmed = unconfirmed + 1
                unconfLines[#unconfLines + 1] =
                    ("  %s (%d) -- no role flag%s"):format(name, sid,
                        extras ~= "" and (", only: " .. extras) or "")
            end
        end

        if contra > 0 then
            ns.Print("|cffff6060contradicted|r -- the journal names a different role:")
            for i = 1, #contraLines do ns.Print(contraLines[i]) end
        end
        if unconfirmed > 0 then
            ns.Print("|cffffc000unconfirmed|r -- no role flag either way, check the boss mod "
                .. "before changing anything:")
            for i = 1, #unconfLines do ns.Print(unconfLines[i]) end
        end
        ns.Print(("%d checked: %d confirmed, %d contradicted, %d unconfirmed, %d not in this "
            .. "season's journal pool"):format(checked, agree, contra, unconfirmed, noData))
        if contra == 0 then
            ns.Print("nothing the journal actively contradicts.")
        end
        if noData > 0 then
            ns.Print("open more Dungeon Bosses and Raid Bosses pages to cover the rest.")
        end
        return
    end

    -- Shows the alert exactly as a fight would, minus the tank gate. If the icon appears
    -- here but not on a boss, the display is fine and the gate is the variable. If it does
    -- not appear here either, the problem is the display itself.
    -- mute/unmute/tank/untank/learn/marked/muted all worked against fingerprints
    -- (a timeline bar's duration standing in for an ability's identity), and retired along
    -- with that engine -- BigWigs/DBM hand over a real spellID now, so "which ability" is
    -- never a guess to record by hand. Setup's own per-ability checklist is the on/off
    -- switch these used to be. trace and export came BACK as spellID-based recorders and
    -- are handled above; leaving them listed here made their retirement notice look live.
    if arg == "mute" or arg == "unmute" or arg == "tank" or arg == "untank"
        or arg == "learn" or arg == "marked" or arg == "muted" then
        ns.Print("/nutank " .. arg .. " was part of the old fingerprint engine and has been "
            .. "retired. Enable or disable an ability from Setup's own checklist instead.")
        return
    end

    -- "It called for an external while I had cooldowns up" is the report this answers, and
    -- it needs no boss and no armed trace: it prints what the pick would decide right now,
    -- for every slot, from the same SpellReady the voice uses. If a spell reads ready here
    -- and the fight still called for an external, the pick is not the problem -- the list
    -- is, and the last line says whether the fallback would fire.
    if arg == "cds" then
        RefreshSpec()
        ns.Apply()
        if activeSlots == 0 then
            ns.Print("nothing on your priority list is talented, so there is nothing to read. "
                .. "Add defensives in Smart Reminders, or check you are on the right spec.")
            return
        end
        ResyncModel()
        local now, anyReady = GetTime(), false
        ns.Print(("|cff0091edcooldowns|r (build %s), in priority order:"):format(BuildString()))
        for i = 1, activeSlots do
            local sid = slots[i].spellID
            local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
            local ok, ready = pcall(SpellReady, sid, now)
            if ok and ready then anyReady = true end
            local st = chargeState[ns.CooldownKey(sid)]
            local detail = st
                and ("%d/%d charges, recharge %s (%s)"):format(
                    ChargesAvailable(sid) or 0, st.max,
                    st.recharge > 0 and ("%.0fs"):format(st.recharge) or "unknown",
                    st.rechargeSrc == "client" and "|cff6DD09Aclient|r"
                        or ("|cffF0A830" .. tostring(st.rechargeSrc) .. "|r"))
                or (CooldownRunning(sid) == nil and "cooldown unreadable, using the estimate"
                    or "cooldown read directly")
            ns.Print(("  %d. %s -- %s (%s)"):format(i, (info and info.name) or tostring(sid),
                ok and (ready and "|cff6DD09AREADY|r" or "|cffff6060on cooldown|r")
                    or "|cffff6060read failed|r", detail))
        end
        if anyReady then
            ns.Print("  at least one is up, so a callout now would name it, not an external.")
        else
            ns.Print("  nothing is up, so a callout now WOULD say " .. tostring(TRDB().voiceNone) .. ".")
        end
        return
    end

    -- Read after the fact, never typed in the moment: every real callout AND every actual
    -- cast of a tracked defensive logs here, interleaved, so a call that turns out wrong --
    -- named a defensive that was actually on cooldown -- can be checked against whether it
    -- was really pressed beforehand, once the pull is over, with nothing to remember.
    if arg == "calls" then
        local log = TRDB().callLog
        if not (log and #log > 0) then
            ns.Print("nothing logged yet this session.")
            return
        end
        for i = 1, #log do
            ns.Print(LogLine(log[i]))
        end
        return
    end

    if arg == "test" then
        if not TRDB().enabled then
            ns.Print("switch the reminder on first.")
            return
        end
        RefreshSpec()
        ns.Apply()
        if activeSlots == 0 then
            ns.Print("nothing on your priority list is talented, so there is nothing to show.")
            return
        end
        ns.ForceShowTest()
        ns.Print(("showing %d slot(s) for 5s with the tank filter bypassed. If you see nothing, "
            .. "the icon is hidden or off-screen -- try Reset Icon Position."):format(activeSlots))
        return
    end

    if arg == "bosses" then
        if ns.PrintBossSummary then
            ns.PrintBossSummary()
        else
            ns.Print("|cffff6060the boss browser did not load|r -- "
                .. "NaowhUI_TankReminder_Bosses.lua is missing from the addon folder.")
        end
        return
    end

    if arg == "gate" then
        if not canGate then
            ns.Print("SetEventIconTextures is not available on this client.")
            return
        end
        local list = C_EncounterTimeline.GetEventList and C_EncounterTimeline.GetEventList()
        if not (list and #list > 0) then
            ns.Print("no timeline events right now -- run this during a boss encounter.")
            return
        end
        local probe = UIParent:CreateTexture(nil, "BACKGROUND")
        probe:SetSize(1, 1)
        probe:SetPoint("CENTER")
        probe:SetAlpha(1)
        for i = 1, math.min(#list, 3) do
            local id = list[i]
            local set = pcall(C_EncounterTimeline.SetEventIconTextures, id,
                Enum.EncounterEventIconmask.TankRole, { probe })
            -- Reading back is expected to fail: GetAlpha is SecretReturnsForAspect once the
            -- Alpha aspect is applied, and even issecretvalue/tostring may refuse a secret
            -- from tainted code. A refusal here is the gate WORKING -- it means the engine
            -- really did write the secret bit into our texture's alpha.
            local read, alpha = pcall(function() return tostring(probe:GetAlpha()) end)
            ns.Print(("gate: event %s -> set=%s read=%s"):format(
                tostring(id),
                set and "ok" or "REFUSED",
                read and alpha or "SECRET/refused (gate is live)"))
        end
        probe:SetTexture(nil)
        probe:Hide()
        return
    end

    -- Bare command opens the options; the diagnostic dump that used to live here moved
    -- under "status" when the addon got its own window.
    if arg == "" and ns.ToggleOptionsWindow then
        ns.ToggleOptionsWindow("Setup")
        return
    end
    if arg ~= "status" then
        ns.Print("unknown command '" .. arg .. "' -- /nutank status for diagnostics, or see below.")
    end

    -- The build, first, because every report that cost a run to diagnose started with not
    -- knowing which one was loaded. A version string is weaker evidence than a stack line,
    -- but it is the only thing a tester can read out without an error to paste.
    ns.Print(("build: %s"):format(BuildString()))
    ns.Print(("tank reminder: enabled=%s spec=%d tank=%s slots=%d"):format(
        tostring(TRDB().enabled), specID, tostring(isTank), activeSlots))
    if TRDB().pretendTank then
        ns.Print("|cffF0A830PRETEND TANK IS ON|r -- the aggro gate is ignored, so abilities "
            .. "call whether or not you hold the boss. /nutank pretendtank turns it off.")
    end
    ns.Print(("boss addon: %s"):format(ns.BossSource()))
    if currentEncounter then
        local diffName = currentDifficultyID and GetDifficultyInfo
            and GetDifficultyInfo(currentDifficultyID)
        ns.Print(("pull: enc=%s elapsed=%.1fs difficulty=%s(%s) stage=%s%s"):format(
            tostring(currentEncounter),
            currentEncounterStartedAt and (GetTime() - currentEncounterStartedAt) or -1,
            tostring(diffName or "?"), tostring(currentDifficultyID),
            tostring(currentStage),
            currentStageAt and (" stageElapsed=%.1fs"):format(GetTime() - currentStageAt) or ""))
    end
    ns.Print(("timeline: available=%s bossWarnings=%s timelineDisplay=%s"):format(
        tostring(TimelineAvailable()),
        CombatWarningsOff() and "|cffff6060OFF|r" or "on",
        TimelineDisplayOff() and "off (fine -- data still flows)" or "on"))
    ns.Print(("engine: select=%s gate=%s bar=%s sound=%s"):format(
        tostring(canSelect and true or false), tostring(canGate and true or false),
        tostring(canBar and true or false), tostring(canSound and true or false)))
    -- Asked of the frame rather than tracked in a flag of our own, so it answers for the
    -- code that is actually loaded. The two counters only move during an encounter (the
    -- handler returns on currentEncounter == nil before reaching them), so a zero outside
    -- a pull says nothing -- registered= is the one that answers on its own.
    ns.Print(("aura cover: bigDefensiveHits=%d (Blizzard's own classification; 0 all pull "
        .. "means the aura enumeration is refused here)"):format(bigDefSeen))
    ns.Print(("combat log: registered=%s inInstance=%s restrictedHere=%s lines=%d usable=%d ownAuras=%d playerGUID=%s"):format(
        watcher:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED") and "true"
            or "|cffff6060false|r",
        tostring(IsInInstance()),
        tostring(C_CombatLog and C_CombatLog.IsCombatLogRestricted
            and C_CombatLog.IsCombatLogRestricted()),
        cleuLines, cleuUsable, cleuOwnAuras,
        PlayerGUID() and "readable" or "|cffff6060UNREADABLE|r"))
    ns.Print("usage: /nutank status | observed | cds | calls | keys | trace | export | pretendtank | test | catalogue | gate | secrecy | bosses | defensives | tanksheet")
end

-------------------------------------------------------------------------------
--  "Add a Defensive" picker
-------------------------------------------------------------------------------
-- Built from the player's OWN spellbook, not from any list we ship. Reading someone's
-- spellbook is reading their character, not shipping ability data, so this stays inside the
-- rule that the addon carries no encounter or class knowledge -- while sparing them from
-- hunting spell IDs on a website.
--
-- The filter is a heuristic, not a database: non-passive, on the active spec, with a real
-- base cooldown. GetSpellBaseCooldown is static data and stays readable when live cooldown
-- state is secret.
-- Blizzard classifies these for us, so the addon still ships no spell list of its own.
-- Two client sources, each supplying half the answer:
--
--   * the Cooldown Manager's category sets give a spec-correct, Blizzard-authored,
--     server-hotfixed list of the player's real cooldowns -- already free of passives,
--     off-spec entries and trinket noise. But its taxonomy is essential/utility, not
--     offensive/defensive: Barkskin and Berserk both sit in Essential.
--   * C_UnitAuras.AuraIsBigDefensive supplies the missing axis. It is the same predicate
--     Blizzard's own aura frames use to decide what counts as a big defensive, and its
--     ordering code shows the set includes self-cast defensives, not just externals.
--
-- Note it is an AURA flag, so the id carrying it can differ from the id you press. Every
-- candidate is tested on its cast id, its override, and its linked ids.

-- Set from the picker's own toggle. The defensive flag is Blizzard's data, and if it turns
-- out thin for a spec the player must still be able to find their spell -- so the filter is
-- the default, not a cage. Declared here because the fallback collector below reads it and
-- is written before the picker itself.
local pickerShowAll = false

local bigDefCache = {}

-- Externals are flagged big-defensive too (Pain Suppression comes back true), but they are
-- cast on somebody else -- pressing one does not save you. C_Spell.IsExternalDefensive is
-- Blizzard's own split between the two, so the list stays "what I press for myself".
local function IsExternalDefensive(spellID)
    if not (C_Spell and C_Spell.IsExternalDefensive) then return false end
    local ok, v = pcall(C_Spell.IsExternalDefensive, spellID)
    return ok and v == true
end

local function IsBigDefensive(spellID)
    if not (spellID and spellID > 0) then return false end
    if bigDefCache[spellID] == nil then
        local ok, v = false, nil
        if C_UnitAuras and C_UnitAuras.AuraIsBigDefensive then
            ok, v = pcall(C_UnitAuras.AuraIsBigDefensive, spellID)
        end
        bigDefCache[spellID] = (ok and v and not IsExternalDefensive(spellID)) and true or false
    end
    return bigDefCache[spellID]
end

-- An external is cast on somebody else, so it never belongs in a "what do I press to save
-- myself" list. Checked across every id the cooldown carries, because the flag sits on the
-- aura and that is often not the id you press.
local function InfoIsExternal(info)
    if IsExternalDefensive(info.spellID) then return true end
    if info.overrideSpellID and IsExternalDefensive(info.overrideSpellID) then return true end
    local linked = info.linkedSpellIDs
    if type(linked) == "table" then
        for i = 1, #linked do
            if IsExternalDefensive(linked[i]) then return true end
        end
    end
    -- selfAura is false for anything whose aura lands on another player, which catches the
    -- externals Blizzard's own flag misses.
    if info.hasAura and info.selfAura == false then return true end
    return false
end

local function InfoIsDefensive(info)
    if InfoIsExternal(info) then return false end

    if IsBigDefensive(info.spellID) or IsBigDefensive(info.overrideSpellID) then return true end
    local linked = info.linkedSpellIDs
    if type(linked) == "table" then
        for i = 1, #linked do
            if IsBigDefensive(linked[i]) then return true end
        end
    end

    -- A selfAura+hasAura fallback was tried here and removed. Measured against a live
    -- Protection Paladin it contributed nothing: the real defensives (Divine Shield, Ardent
    -- Defender) both report hasAura=false, so the pair never fired, while loosening it to
    -- selfAura alone would have pulled in Consecration and Divine Steed. Blizzard's flag plus
    -- the external exclusion is what actually works; anything it misses (Lay on Hands, say)
    -- is one spell ID away in the editor.
    return false
end

-- Fallback for a client without the Cooldown Manager: the old spellbook sweep, still
-- narrowed by the defensive predicate where it is available.
local function CollectFromSpellbook(seen, list, out)
    local MIN_BASE_CD_MS = 30000
    if not (C_SpellBook and C_SpellBook.GetSpellBookSkillLineInfo
        and C_SpellBook.GetSpellBookItemInfo and Enum and Enum.SpellBookSpellBank) then
        return
    end
    local havePredicate = C_UnitAuras and C_UnitAuras.AuraIsBigDefensive
    for line = 1, 12 do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if not info then break end
        local offset, count = info.itemIndexOffset or 0, info.numSpellBookItems or 0
        for i = 1, count do
            local item = C_SpellBook.GetSpellBookItemInfo(offset + i, Enum.SpellBookSpellBank.Player)
            local sid = item and item.spellID
            if sid and not seen[sid] and not item.isPassive and not item.isOffSpec then
                seen[sid] = true
                local base = GetSpellBaseCooldown and GetSpellBaseCooldown(sid)
                local keep
                if pickerShowAll or not havePredicate then
                    keep = type(base) == "number" and base >= MIN_BASE_CD_MS
                else
                    keep = IsBigDefensive(sid)
                end
                if keep and not (list and ns.ListIndexOf(list, sid)) then
                    out[#out + 1] = {
                        id = sid, name = item.name or ("Spell " .. sid),
                        icon = item.iconID, cd = (type(base) == "number" and base) or 0,
                    }
                end
            end
        end
    end
end

-- nil = the spec default; set = a per-boss override. The picker is otherwise identical, so
-- one popup serves both rather than two that could drift apart.
local pickerEncounter

local function TargetList(create)
    if pickerEncounter then return BossList(specID, pickerEncounter, create) end
    return UserList(specID, create)
end

-- When true the caller wants EVERY defensive, listed or not: the inline editor renders the
-- full set and lets a toggle decide membership.
local collectAll = false

ns.InfoIsDefensive = InfoIsDefensive

local function CollectCandidates()
    local out, seen = {}, {}
    local list = (not collectAll) and TargetList(false) or nil

    -- Equipped trinket on-use effects, read straight off the item rather than through the
    -- Cooldown Manager's category sets: GetItemSpell needs no participation from Blizzard's
    -- cooldown/defensive classification and has not changed shape across expansions, unlike
    -- the Cooldown Viewer categories. Only ever two slots to check, so no noise concern the
    -- way a spellbook-wide relaxation would have -- the player recognizes their own gear and
    -- picks the defensive one themselves, same as they already do among ambiguous class
    -- cooldowns InfoIsDefensive lets through.
    for _, slot in ipairs({ INVSLOT_TRINKET1, INVSLOT_TRINKET2 }) do
        local link = GetInventoryItemLink("player", slot)
        if link and C_Item and C_Item.GetItemSpell then
            local spellName, spellID = C_Item.GetItemSpell(link)
            if spellID and not seen[spellID] then
                seen[spellID] = true
                if not (list and ns.ListIndexOf(list, spellID)) then
                    local si = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
                    local base = GetSpellBaseCooldown and GetSpellBaseCooldown(spellID)
                    out[#out + 1] = {
                        id   = spellID,
                        name = spellName or (si and si.name) or ("Spell " .. spellID),
                        icon = si and si.iconID,
                        cd   = (type(base) == "number" and base) or 0,
                    }
                end
            end
        end
    end

    local CV = C_CooldownViewer
    if CV and CV.GetCooldownViewerCategorySet and CV.GetCooldownViewerCooldownInfo
        and Enum and Enum.CooldownViewerCategory then
        for _, cat in ipairs({ Enum.CooldownViewerCategory.Essential,
                              Enum.CooldownViewerCategory.Utility }) do
            local ids = CV.GetCooldownViewerCategorySet(cat, false)
            for i = 1, (ids and #ids or 0) do
                local info = CV.GetCooldownViewerCooldownInfo(ids[i])
                if info and info.isKnown and (pickerShowAll or InfoIsDefensive(info)) then
                    -- The pressable id, which is the override when one is active.
                    local castID = info.overrideSpellID
                    if not castID or castID == 0 then castID = info.spellID end
                    if castID and not seen[castID] then
                        seen[castID] = true
                        local si = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(castID)
                        local base = GetSpellBaseCooldown and GetSpellBaseCooldown(castID)
                        if not (list and ns.ListIndexOf(list, castID)) then
                            out[#out + 1] = {
                                id   = castID,
                                name = (si and si.name) or ("Spell " .. castID),
                                icon = si and si.iconID,
                                cd   = (type(base) == "number" and base) or 0,
                            }
                        end
                    end
                end
            end
        end
    end

    -- Nothing from the Cooldown Manager (older client, or data not loaded yet): sweep the
    -- spellbook instead rather than showing an empty picker.
    if #out == 0 then
        CollectFromSpellbook(seen, list, out)
    end

    table.sort(out, function(a, b)
        if a.cd ~= b.cd then return a.cd > b.cd end   -- longest cooldown first: the big buttons
        return a.name < b.name
    end)
    return out
end

local pickPopup
local ShowPicker

local function AddSpell(spellID)
    -- Every refusal is reported. A silent false here reads as a broken button.
    if specID == 0 then
        RefreshSpec()
        if specID == 0 then
            ns.Print("cannot tell which specialization you are in yet -- try again in a moment.")
            return false
        end
    end
    local cur = TargetList(true)
    if not cur then return false end
    if ListIndexOf(cur, spellID) then return false end
    if #cur >= MAX_SLOTS then
        ns.Print(("your list is full (%d maximum) -- remove one first."):format(MAX_SLOTS))
        return false
    end
    cur[#cur + 1] = spellID
    RebuildSlots()
    UpdateEventRegistration()
    UpdatePreview()
    return true
end

local function BuildPicker()
    if pickPopup then return pickPopup end

    local dimmer, panel = ns.MakeModal(380, 460, "defensivePicker")

    local title = ns.Font(panel, 14, "OUTLINE")
    title:SetPoint("TOP", panel, "TOP", 0, -16)
    title:SetText("Add a Defensive")

    local hint = ns.Font(panel, 11, nil, ns.THEME.muted)
    hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
    hint:SetPoint("LEFT", panel, "LEFT", 14, 0)
    hint:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    hint:SetJustifyH("CENTER")

    local toggle

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -68)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 52)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(300, 10)
    scroll:SetScrollChild(content)

    local rows = {}

    local function Refresh()
        local cands = CollectCandidates()
        for i = 1, #rows do rows[i]:Hide() end
        local y = 0
        for i = 1, #cands do
            local c = cands[i]
            local row = rows[i]
            if not row then
                row = CreateFrame("Button", nil, content)
                row:SetHeight(30)
                row:SetPoint("LEFT", content, "LEFT", 0, 0)
                row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                row.hl = ns.Solid(row, "BACKGROUND", ns.THEME.accentSoft, 0.10)
                row.hl:SetAllPoints(); row.hl:Hide()
                row.tex = row:CreateTexture(nil, "ARTWORK")
                row.tex:SetSize(24, 24)
                row.tex:SetPoint("LEFT", row, "LEFT", 2, 0)
                row.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.name = ns.Font(row, 13, nil)
                row.name:SetPoint("LEFT", row.tex, "RIGHT", 8, 0)
                row.name:SetJustifyH("LEFT")
                row.cd = ns.Font(row, 12, nil, ns.THEME.muted)
                row.cd:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                rows[i] = row
            end
            row:SetPoint("TOP", content, "TOP", 0, -y)
            row.tex:SetTexture(c.icon)
            row.name:SetText(c.name)
            row.cd:SetText(("%ds"):format(math.floor(c.cd / 1000)))
            row:SetScript("OnEnter", function(self) self.hl:Show() end)
            row:SetScript("OnLeave", function(self) self.hl:Hide() end)
            row:SetScript("OnClick", function()
                if AddSpell(c.id) then
                    Refresh()
                    if pickPopup._onDone then pickPopup._onDone() end
                end
            end)
            row:Show()
            y = y + 30
        end
        content:SetHeight(math.max(y, 10))
        if #cands == 0 then
            hint:SetText(pickerShowAll
                and "Nothing left to add."
                or "No major defensives found. Try Show All Cooldowns.")
        else
            hint:SetText(pickerShowAll
                and "Every cooldown you have. Click one to add it."
                or "Your major defensives. Click one to add it to the bottom of the list.")
        end
    end

    pickPopup = { dimmer = dimmer, refresh = Refresh }

    toggle = ns.Button(panel, "Show All Cooldowns", 150, 22, function()
        pickerShowAll = not pickerShowAll
        Refresh()
    end)
    toggle:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 14)
    ns.Tooltip(toggle, "Show All Cooldowns",
        "The list is filtered to what the game marks as a major defensive. Turn this on to "
        .. "see every cooldown you have, in case something you want is not flagged.")

    ns.Button(panel, "Done", 110, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 14)

    return pickPopup
end

function ShowPicker(onDone)   -- forward-declared above; a global here would leak
    RefreshSpec()
    local p = BuildPicker()
    p._onDone = onDone
    p.refresh()
    p.dimmer:Show()
end

-------------------------------------------------------------------------------
--  Callout text editor
-------------------------------------------------------------------------------
-- A free-text box rather than a dropdown: the whole point is that the spoken line is
-- shorter than the spell name.
local textPopup

-- Two ways to be heard: pick a SharedMedia sound, or type what should
-- be spoken. The dropdown carries a "Speak the text instead" entry, which is the no-sound
-- state -- so the two live on one control rather than needing a mode switch.
local function ShowCalloutEditor(title, current, onAccept, spellID)
    if not textPopup then
        local dimmer, panel = ns.MakeModal(400, 240, "calloutEditor")

        local head = ns.Font(panel, 14, "OUTLINE")
        head:SetPoint("TOP", panel, "TOP", 0, -16)

        local modeHolder = CreateFrame("Frame", nil, panel)
        modeHolder:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, -46)
        modeHolder:SetSize(356, 22)

        -- The sound and text controls occupy the SAME slot: only one is ever shown, so
        -- stacking them keeps the dialog the same height either way.
        local soundLbl = ns.Font(panel, 11, nil, ns.THEME.muted)
        soundLbl:SetPoint("TOPLEFT", modeHolder, "BOTTOMLEFT", 0, -16)
        soundLbl:SetText("Sound")

        local ddHolder = CreateFrame("Frame", nil, panel)
        ddHolder:SetPoint("TOPLEFT", soundLbl, "BOTTOMLEFT", 0, -4)
        ddHolder:SetSize(356, 30)

        local textLbl = ns.Font(panel, 11, nil, ns.THEME.muted)
        textLbl:SetPoint("TOPLEFT", modeHolder, "BOTTOMLEFT", 0, -16)
        textLbl:SetText("Spoken text")

        -- The one hand-built widget: the factory has no text input.
        local box = CreateFrame("EditBox", nil, panel)
        box:SetPoint("TOPLEFT", textLbl, "BOTTOMLEFT", 0, -4)
        box:SetSize(356, 28)
        box:SetAutoFocus(false)
        box:SetMaxLetters(60)
        box:SetFontObject("GameFontHighlight")
        box:SetTextInsets(6, 6, 0, 0)
        local well = ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1)
        well:SetAllPoints()
        ns.Border(box)

        textPopup = { dimmer = dimmer, panel = panel, box = box, head = head,
                      ddHolder = ddHolder, textLbl = textLbl,
                      modeHolder = modeHolder, soundLbl = soundLbl }

        local function Accept()
            -- Both halves land together on Save; picking a sound and then cancelling leaves
            -- nothing behind. Text mode clears the sound, which is what makes the radio the
            -- single source of truth for how this callout is heard.
            ns.SetSoundFor(textPopup._spellID,
                (textPopup._mode == "sound") and textPopup._soundKey or nil)
            dimmer:Hide()
            if textPopup._onAccept then textPopup._onAccept(box:GetText()) end
        end

        local hear = ns.Button(panel, "Hear it", 96, 26, function()
            local key = (textPopup._mode == "sound") and textPopup._soundKey or nil
            local EUI = ns.UI
            if key and textPopup._paths and EUI and EUI._PlayLSMSound then
                EUI._PlayLSMSound(textPopup._paths[key])
            else
                Speak(box:GetText())
            end
        end)
        hear:SetPoint("BOTTOM", panel, "BOTTOM", -114, 16)
        ns.Tooltip(hear, "Hear it", "Plays it exactly as it will sound in a fight.")

        ns.Button(panel, "Save", 96, 26, Accept):SetPoint("BOTTOM", panel, "BOTTOM", -6, 16)
        ns.Button(panel, "Cancel", 96, 26, function() dimmer:Hide() end)
            :SetPoint("BOTTOM", panel, "BOTTOM", 102, 16)

        box:SetScript("OnEnterPressed", Accept)
        box:SetScript("OnEscapePressed", function() dimmer:Hide() end)
    end

    local tp = textPopup
    tp._onAccept = onAccept
    tp._spellID = spellID or 0
    tp.head:SetText(title or "Callout")
    tp.box:SetText(current or "")

    -- Choices are refilled per open, since SharedMedia may have registered more by now.
    local paths, names, order = ns.SoundChoices()
    tp._paths = paths
    -- nil, not "none": the mode below is derived from this being set, and a placeholder
    -- string is truthy, which would open every callout in sound mode.
    tp._soundKey = ns.SoundFor(tp._spellID)

    -- Mode is explicit, so "I want a sound" and "I have not picked one yet" are different
    -- states rather than both reading as empty.
    tp._mode = tp._soundKey and "sound" or "text"
    tp._firstSound = order and order[1] or nil

    local EUI = ns.UI
    local segRefresh

    local function Sync()
        local speaking = (tp._mode == "text")
        tp.box:SetShown(speaking)
        tp.textLbl:SetShown(speaking)
        if tp._dd then tp._dd:SetShown(not speaking) end
        tp.soundLbl:SetShown(not speaking)
        if segRefresh then segRefresh() end
    end
    tp._sync = Sync

    -- One switch, built once. On means spoken text, off means a sound file -- and only the
    -- control that actually applies is on screen, so there is never a dimmed widget inviting
    -- a click that does nothing.
    if not tp._modeToggle and EUI and EUI.BuildToggleControl then
        local tg, _, tgSnap = EUI.BuildToggleControl(tp.modeHolder,
            tp.modeHolder:GetFrameLevel() + 5,
            function() return tp._mode == "text" end,
            function(v)
                tp._mode = v and "text" or "sound"
                -- Switching to sound with nothing chosen takes the first one, so the mode is
                -- never left meaning nothing.
                if tp._mode == "sound" and not tp._soundKey then
                    tp._soundKey = tp._firstSound
                end
                if tp._sync then tp._sync() end
            end)
        tg:SetPoint("LEFT", tp.modeHolder, "LEFT", 0, 0)
        tp._modeToggle, tp._modeSnap = tg, tgSnap

        tp.modeLbl = ns.Font(tp.modeHolder, 12, nil)
        tp.modeLbl:SetPoint("LEFT", tg, "RIGHT", 10, 0)
        tp.modeLbl:SetText("Speak Text")
    end

    segRefresh = function()
        if tp._modeSnap then tp._modeSnap() end
    end

    if paths and EUI and EUI.BuildDropdownControl then
        if not tp._dd then
            tp._names, tp._order = {}, {}
            tp._dd = EUI.BuildDropdownControl(tp.ddHolder, 356, tp.panel:GetFrameLevel() + 8,
                tp._names, tp._order,
                function() return tp._soundKey or tp._firstSound end,
                function(v)
                    tp._soundKey = v   -- held until Save
                    tp._mode = "sound"
                    tp._sync()
                end)
            tp._dd:SetPoint("TOPLEFT", tp.ddHolder, "TOPLEFT", 0, 0)
        end
        wipe(tp._names)
        wipe(tp._order)
        for k, v in pairs(names) do tp._names[k] = v end
        for i = 1, #order do tp._order[i] = order[i] end
        tp._dd._refreshLabel()
    end
    Sync()

    tp.dimmer:Show()
    tp.box:SetFocus()
end

-------------------------------------------------------------------------------
--  Options
-------------------------------------------------------------------------------
-- Every builder returns the raw running y, section-builder style; the window's page
-- wrapper is what takes math.abs of it.
-------------------------------------------------------------------------------
--  Setup tab panels
-------------------------------------------------------------------------------
-- Split out of what used to be one long ns.BuildSection. Core stays always
-- visible on the Setup tab (master enable, behaviour toggles, and the
-- priority list are not "Bars", "Colors", "Sounds" or "Profile" -- none of
-- the four own "when this fires", only "how it looks or sounds" or "what
-- profile owns it"), while the rest split into the four side-list panels.

-- Core: master enable, boss-tanking scope, timing/behaviour, the priority
-- list. Always shown at the top of the Setup tab regardless of which of the
-- four side items is selected.
function ns.BuildCoreSettings(parent, y)
    local EUI = ns.UI
    local W   = EUI.Widgets
    local _, h

    _, h = W:SectionHeader(parent, "SMART REMINDERS", y); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Smart Reminders",
          tooltip = "Shows what to press when the boss timeline says an ability is about to land. "
          .. "It picks the highest entry on your own list that you have talented and off "
          .. "cooldown. Build that list below -- nothing is set up for you. Works on every "
          .. "specialization.",
          getValue = function() return TRDB().enabled end,
          setValue = function(v)
              TRDB().enabled = v
              ns.Apply()
              UpdatePreview()
              EUI:RefreshPage(true)
          end },
        -- "Only for Tank Abilities" lived here until the fingerprint data shipped. It was
        -- the engine's icon-only filter: it could not reach text or audio, so the channels
        -- disagreed with each other, and on covered bosses the fingerprint filter now does
        -- the same job for every channel at once. The stored tankOnly flag is ignored, not
        -- migrated, so downgrading does not lose it.
        -- "Only While I Have the Boss" moved to the Raid Bosses tab: it only ever changes
        -- anything with two tanks, and a five-man has one who holds every boss unit, so on
        -- the Setup tab it read as a global behaviour switch that does nothing in half the
        -- content. Same stored key, so nobody loses their choice.
        { type = "toggle", text = "Enable Healer Reminders",
          tooltip = "Show reminders marked Healer Reminder. Turning this off hides them and cancels "
          .. "their pending alerts. Applies to every character and profile; imports do not change it. "
          .. "Native debuff sound changes wait until combat and the encounter end.",
          getValue = ns.HealerRemindersEnabled,
          setValue = function(v) ns.SetHealerRemindersEnabled(v) end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Boss Addon", width = 180,
          values = { timeline = "Blizzard Timeline", bigwigs = "BigWigs", dbm = "DBM" },
          order = { "timeline", "bigwigs", "dbm" },
          tooltip = "Which single source drives the callouts. Blizzard Timeline is the "
          .. "game's own encounter feed -- no addons needed, and per-ability sounds only "
          .. "work here. BigWigs or DBM instead ride that mod's bars and messages -- "
          .. "what powers timer/message reminders and phase (p2) note lines. Ability-timer "
          .. "Raid Reminders are BigWigs only. The other two sources are ignored entirely.",
          getValue = function() return TRDB().bossSource or "timeline" end,
          setValue = function(v)
              TRDB().bossSource = v
              ns.Apply()
              EUI:RefreshPage(true)
          end },
        { type = "label", text = "      Callouts follow exactly one source." }
    ); y = y - h

    -- Only worth saying when it is actually wrong. The timeline's own display toggle is
    -- deliberately not mentioned: boss-mod addons turn it off as a matter of course and the
    -- data keeps flowing, so flagging it would be a false alarm for a lot of people.
    if TRDB().enabled and CombatWarningsOff() then
        _, h = W:DualRow(parent, y,
            { type = "label", text = "|cffff6060Boss Warnings are off in the game options.|r" },
            { type = "label", text = "Options, Advanced, Enable Boss Warnings." }
        ); y = y - h
    end

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Skip When Already Covered",
          tooltip = "Stays quiet when one of your defensives is already active as the "
          .. "warning fires -- you are covered, no need to stack another.",
          getValue = function() return TRDB().coveredSkip ~= false end,
          setValue = function(v) TRDB().coveredSkip = v end },
        { type = "slider", text = "Warn This Many Seconds Early", min = 1, max = 5, step = 1,
          tooltip = "How close to the hit the alert fires. The game announces abilities about "
          .. "five seconds out; the alert waits and fires this many seconds before impact, so "
          .. "lower is closer to the hit. When the game announces later than this, the alert "
          .. "fires immediately. This is the BASE value every defensive uses -- override "
          .. "one specifically from an ability's own cog on a boss's page, next to that "
          .. "defensive on its preset list. That override can go negative too, to call out "
          .. "AFTER the hit instead of before it.",
          getValue = function() return TRDB().leadTime or 3 end,
          setValue = function(v) TRDB().leadTime = v end }
    ); y = y - h

    -- Its own row: the two above are a settled pair and the slider is long-labelled.
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Your Own Cast Covers You For", min = 0, max = 15, step = 1,
          tooltip = "The client refuses addons the combat log in this build, so a defensive "
          .. "you press cannot be watched landing -- the press itself is all there is. This "
          .. "is how long after one the callout stays quiet. Set it to the length of what "
          .. "you actually press, or to 0 to hear about every hit even while covered. A "
          .. "tank who pre-pops as the boss engages wants it low: at 10 seconds, a hit "
          .. "five seconds after the press says nothing at all.",
          getValue = function() return TRDB().coveredCastWindow or 6 end,
          setValue = function(v) TRDB().coveredCastWindow = v end }
    ); y = y - h

    -- The player's own list for the current spec, in priority order. This addon ships no
    return y
end

-- The priority list, on the Defensive Presets tab by itself. RenderPresetListEditor's own
-- returned height (topY + math.min(ly, ry) across two independently-tracked columns)
-- runs a little short of its true rendered extent once the spare-defensives column gets
-- long, so nothing may ever stack below it; alone on its page, the inexact number costs
-- at worst a little extra or missing empty space, never content drawn on top of content.
function ns.BuildPresetListSettings(parent, y)
    local EUI = ns.UI
    local W   = EUI.Widgets
    local _, h

    -- The player's own list for the current spec, in priority order. This addon ships no
    -- ability data, so an empty list here is the correct starting state -- the section says
    -- so rather than looking broken.
    _, h = W:SectionHeader(parent, "PRESET LIST (THIS SPEC)", y); y = y - h

    -- Left: the presets you have for this spec, and a way to add more. Right: the active
    -- one's list, every row condensed to a name, a switch, and a settings cog.
    if ns.RenderPresetListEditor then
        y = ns.RenderPresetListEditor(parent, y, W, EUI, specID)
    end

    return y
end

-- Visibility Options + Size and Location. "Show Icon" and "Show Text Call Out" used to be
-- paired with unrelated toggles on the same row (Skip When Covered, Play a Sound) -- kept
-- unpaired here now that they've settled into one section together.
function ns.BuildBarsSettings(parent, y)
    local EUI = ns.UI
    local W   = EUI.Widgets
    local _, h

    _, h = W:SectionHeader(parent, "VISIBILITY OPTIONS", y); y = y - h

    -- The countdown bar toggle lived here and was removed on tester feedback; the bar
    -- machinery stays for stored profiles that still have showBar set, it just cannot be
    -- switched on from the UI anymore.
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Show Icon",
          tooltip = "The icon of the defensive to press.",
          getValue = function() return TRDB().showIcon end,
          setValue = function(v) TRDB().showIcon = v; ApplySize(); UpdatePreview() end },
        -- This toggle used to lock itself while the engine tank filter was on, because a
        -- FontString cannot carry that filter and the text would have contradicted the icon.
        -- ns.AbilityEnabledForBinding made the lock obsolete: it silences whole abilities
        -- upstream, so text is tank-only regardless -- and voice was never locked despite
        -- having the identical limitation, so the lock bought inconsistency, not honesty.
        { type = "toggle", text = "Show Text Call Out",
          tooltip = "Writes the callout on screen -- \"Barkskin\" -- for whichever defensive "
          .. "it picked, and your fallback line when nothing is up. Only appears for "
          .. "abilities enabled in that boss's ability list, in the Bosses tab. Set each "
          .. "line's own wording in the list below.",
          getValue = function() return TRDB().showText end,
          setValue = function(v)
              TRDB().showText = v; ApplySize(); UpdatePreview()
          end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Glow It on the Cooldown Manager",
          tooltip = "Also glows the called defensive on Blizzard's Cooldown Manager bar, so "
          .. "the answer appears on the bar you are already watching. Needs the Cooldown "
          .. "Manager turned on and that defensive placed on it.|n|n"
          .. "|cffff6b5eOff by default:|r this reaches across to Blizzard's own frames, so it "
          .. "is the first thing to switch off if anything misbehaves in combat.",
          getValue = function() return TRDB().cdmGlow == true end,
          setValue = function(v)
              TRDB().cdmGlow = v and true or false
              if not v then ns.StopCDMGlow() end
          end },
        { type = "label", text = "" }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Icon Display Duration", min = 1, max = 15, step = 1,
          tooltip = "How many seconds the defensive icon and callout text stay visible. "
          .. "Defaults to 3 seconds. Hide After Casting can dismiss it early.",
          getValue = function() return TRDB().lingerSec or DEFAULTS.lingerSec end,
          setValue = function(v) TRDB().lingerSec = v end },
        { type = "toggle", text = "Hide After Casting",
          tooltip = "Dismiss the icon and callout text when you cast the suggested defensive. "
          .. "Off by default so they remain for the selected display duration.",
          getValue = function() return TRDB().hideOnCast == true end,
          setValue = function(v) TRDB().hideOnCast = v and true or nil end }
    ); y = y - h

    _, h = W:SectionHeader(parent, "SIZE AND LOCATION", y); y = y - h

    local fontValues, fontOrder = { [""] = "Default (Naowh)" }, { "" }
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        for _, name in ipairs(LSM:List("font")) do
            fontValues[name] = name
            fontOrder[#fontOrder + 1] = name
        end
    end
    local selectedFont = TRDB().fontName
    if type(selectedFont) == "string" and selectedFont ~= "" and not fontValues[selectedFont] then
        fontValues[selectedFont] = selectedFont .. " (unavailable)"
        fontOrder[#fontOrder + 1] = selectedFont
    end
    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Reminder Font", values = fontValues, order = fontOrder,
          tooltip = "Font for defensive callouts and ability reminder text. Saved with this "
          .. "profile. Unavailable fonts use the default font.",
          getValue = function() return TRDB().fontName or "" end,
          setValue = function(v)
              TRDB().fontName = v ~= "" and v or nil
              ApplySize()
              UpdatePreview()
          end },
        { type = "label", text = "" }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Icon Size", min = 32, max = 128, step = 1,
          tooltip = "Size of the defensive icon. Independent of the text callout's size.",
          getValue = function() return TRDB().iconSize or DEFAULTS.iconSize end,
          setValue = function(v)
              TRDB().iconSize = v
              ApplySize()
              UpdatePreview()
          end },
        { type = "slider", text = "Text Size", min = 10, max = 40, step = 1,
          tooltip = "Size of the text callout -- the defensive name and fallback line. "
          .. "Independent of the icon's size.",
          getValue = function() return TRDB().textSize or DEFAULTS.textSize end,
          setValue = function(v)
              TRDB().textSize = v
              ApplySize()
              UpdatePreview()
          end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Text Position",
          values = { TOP = "Above the Icon", BOTTOM = "Below the Icon",
                     LEFT = "Left of the Icon", RIGHT = "Right of the Icon" },
          order = { "TOP", "BOTTOM", "LEFT", "RIGHT" },
          tooltip = "Which side of the icon the text callout sits on. The text is anchored "
          .. "by its near edge, so it keeps the same gap from the icon however long the "
          .. "defensive's name is.",
          getValue = function() return TRDB().textSide or DEFAULTS.textSide end,
          setValue = function(v)
              TRDB().textSide = v
              ApplyTextLayout()
              UpdatePreview()
          end },
        { type = "toggle", text = "Show a Preview",
          tooltip = "Puts a stand-in of the alert on screen while these options are open -- "
          .. "the icon and the text callout exactly as a fight would draw them. DRAG IT to "
          .. "move the alert; the position saves instantly. It hides itself when the "
          .. "options close.",
          getValue = function() return previewPin end,
          setValue = function(v) previewPin = v; UpdatePreview() end }
    ); y = y - h

    -- Escape hatch: a UI-scale change can strand a moved alert off-screen where the
    -- preview drag cannot reach it. Side by side rather than stacked -- W:Button always claims a
    -- full row of its own, so these are two ns.Button primitives chained off a blank
    -- DualRow's two regions instead, the same way a settings cog attaches inline elsewhere
    -- in this file.
    local resetRow
    resetRow, h = W:DualRow(parent, y,
        { type = "label", text = "" },
        { type = "label", text = "" }
    ); y = y - h

    if resetRow then
        if resetRow._leftRegion and not resetRow._resetIcon then
            local btn = ns.Button(resetRow._leftRegion, "Reset Icon Position", 200, 26, function()
                TRDB().pos = nil
                ApplyPosition()
            end)
            btn:SetPoint("LEFT", resetRow._leftRegion, "LEFT", 8, 0)
            resetRow._resetIcon = btn
        end
    end

    _, h = W:SectionHeader(parent, "OPTIONS WINDOW", y); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Window Scale",
          values = { [100] = "100%  (default)", [90] = "90%", [80] = "80%",
                     [70] = "70%", [60] = "60%", [50] = "50%" },
          order = { 100, 90, 80, 70, 60, 50 },
          tooltip = "Size of this options window and the editors it opens, as a percentage. "
          .. "Turn it down if the window is too big for your screen; 1080p usually wants 80 "
          .. "or below.|n|nSaved for this computer instead of in the profile, so switching "
          .. "profile leaves it alone and an exported pack never carries it to someone on a "
          .. "different monitor.",
          getValue = function() return tonumber(ns.AccountSettings().windowScale) or 100 end,
          setValue = function(v) ns.SetWindowScale(v) end },
        { type = "label", text = "" }
    ); y = y - h

    return y
end

-- Sounds: engine-played sound, spoken callout, and the alert sound file
-- picker. "Play a Sound" used to share a row with "Show a Text Callout"
-- (Bars); unpaired here for the same reason as above.
function ns.BuildSoundsSettings(parent, y)
    local EUI = ns.UI
    local W   = EUI.Widgets
    local _, h

    _, h = W:SectionHeader(parent, "SOUNDS AND VOICE", y); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Play a Sound",
          tooltip = "Plays a sound when a tank ability is coming. The game plays this one itself, "
          .. "which is the only way it can be limited to tank abilities -- but it also means the "
          .. "sound cannot know whether your defensive is ready. Watch the icon for that.|n|n"
          .. "|cffff6b5eIt plays at most ONCE per boss fight.|r The game will not repeat a "
          .. "registered sound, so a second cast of the same ability is silent. The icon is "
          .. "not affected and marks every cast.",
          getValue = function() return TRDB().soundOn end,
          setValue = function(v)
              TRDB().soundOn = v
              RegisterEventSounds()
              EUI:RefreshPage(true)
          end },
        { type = "toggle", text = "Speak Which Defensive to Use",
          tooltip = "Says the callout for the defensive it picked, and your fallback line when "
          .. "nothing is up. On bosses with tank buster data this speaks only for tank "
          .. "busters; on bosses without it yet, it speaks for every timeline ability. In "
          .. "combat the pick comes from the addon's own tracking of your casts.",
          getValue = function() return TRDB().voiceOn end,
          setValue = function(v) TRDB().voiceOn = v; EUI:RefreshPage(true) end }
    ); y = y - h

    local voiceValues, voiceOrder = ns.TTSVoiceChoices()
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Voice Volume", min = 0, max = 100, step = 5,
          tooltip = "Volume of the spoken callouts.",
          getValue = function() return TRDB().voiceVol or 100 end,
          setValue = function(v) TRDB().voiceVol = v end },
        { type = "dropdown", text = "Voice", width = 180,
          values = voiceValues, order = voiceOrder,
          tooltip = "Which text-to-speech voice speaks the callouts. Game Default follows "
          .. "whatever is picked in the game's own Text to Speech options; anything else is "
          .. "this addon's alone and does not change the game's setting. The list is the "
          .. "voices your system has installed.",
          getValue = function() return TRDB().ttsVoiceID or "" end,
          setValue = function(v)
              TRDB().ttsVoiceID = (v ~= "" and v) or nil
          end }
    ); y = y - h

    if TRDB().soundOn then
        local paths, names, order = EUI.BuildAlertSoundTables()
        if EUI.AppendSharedMediaSounds then EUI.AppendSharedMediaSounds(paths, names, order) end
        _, h = W:DualRow(parent, y,
            { type = "dropdown", text = "Alert Sound",
              values = names, order = order,
              tooltip = "Sound files only. A few entries are built-in game sounds rather than "
              .. "files, and the game will not accept those for this.",
              getValue = function() return TRDB().soundKey or "none" end,
              setValue = function(v)
                  TRDB().soundKey = v
                  if EUI._PlayLSMSound and paths[v] then EUI._PlayLSMSound(paths[v]) end
                  RegisterEventSounds()
              end },
            { type = "label", text = "Re-registers when you change it." }
        ); y = y - h

        if soundError then
            _, h = W:DualRow(parent, y,
                { type = "label", text = "|cffff6060" .. soundError .. "|r" },
                { type = "label", text = "" }
            ); y = y - h
        end
    end

    return y
end

-- Colors: nothing built yet. There is no colour customisation anywhere in
-- this addon today -- the icon and text callout use the defensive's own
-- Blizzard colouring, unconfigurable. Said plainly rather than hidden.
-- Both toggles are opt-in: off keeps the default white, matching every install before
-- this existed. The color row under each is conditional on its own toggle, same idiom as
-- the Alert Sound dropdown under Sounds -- so a toggle flip also calls RefreshPage to make
-- that row appear or disappear immediately.
function ns.BuildColorsSettings(parent, y)
    local EUI = ns.UI
    local W   = EUI.Widgets
    local _, h

    _, h = W:SectionHeader(parent, "COLORS", y); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Color the Defensive Text",
          tooltip = "Recolor the defensive callout text -- the spell name shown by the "
          .. "icon. Off uses the default white.",
          getValue = function() return TRDB().defensiveTextColorOn end,
          setValue = function(v)
              TRDB().defensiveTextColorOn = v
              ApplyDefensiveTextColor()
              EUI:RefreshPage(true)
          end },
        { type = "label", text = "" }
    ); y = y - h

    -- One colour setting now that the authored line and the defensive callout share the
    -- same display; the second one coloured a frame that no longer exists.
    if TRDB().defensiveTextColorOn then
        _, h = W:ColorPicker(parent, "Defensive Text Color", y,
            DefensiveTextColor,
            function(r, g, b, a)
                TRDB().defensiveTextColor = { r = r, g = g, b = b, a = a }
                ApplyDefensiveTextColor()
            end,
            true)
        y = y - h
    end


    if not TRDB().defensiveTextColorOn then
        _, h = W:DualRow(parent, y,
            { type = "label", text = "|cff9a9ea6Nothing else to configure here yet.|r" },
            { type = "label", text = "" }
        ); y = y - h
    end

    return y
end

-------------------------------------------------------------------------------
--  Setup tab: core settings, visibility, size and location, sounds, colors,
--  and reminder appearance. Profile management has its own tab.
-------------------------------------------------------------------------------
function ns.BuildSetupPage(parent, yOffset)
    local EUI = ns.UI
    if EUI.ClearContentHeader then EUI:ClearContentHeader() end
    RefreshSpec()   -- the list editors below are all keyed on it

    local y = yOffset
    if ns.BuildCoreSettings    then y = ns.BuildCoreSettings(parent, y) end
    if ns.BuildBarsSettings    then y = ns.BuildBarsSettings(parent, y) end
    if ns.BuildSoundsSettings  then y = ns.BuildSoundsSettings(parent, y) end
    if ns.BuildColorsSettings  then y = ns.BuildColorsSettings(parent, y) end

    return math.abs(y)
end

-- Defensive Presets tab: the preset list editor, alone on its own page.
function ns.BuildPresetsPage(parent, yOffset)
    local EUI = ns.UI
    if EUI.ClearContentHeader then EUI:ClearContentHeader() end
    RefreshSpec()   -- the preset editor is keyed on it

    local y = yOffset
    if ns.BuildPresetListSettings then y = ns.BuildPresetListSettings(parent, y) end
    return math.abs(y)
end

-- Dungeon Bosses / Raid Bosses tabs: the boss list and reminder editors.
function ns.BuildBossTabPage(parent, yOffset, isRaid)
    local EUI = ns.UI
    if EUI.ClearContentHeader then EUI:ClearContentHeader() end
    RefreshSpec()

    local y = yOffset
    if ns.BuildBossListPage then
        y = ns.BuildBossListPage(parent, y, isRaid)
    end
    return math.abs(y)
end

-- Shared with the boss tree page, which renders the same list editor for a per-boss
-- override as this page does for the spec default.
-- Every major defensive the player has, regardless of what is already on a list.
function ns.AllDefensives(forSpec, encounterID)
    RefreshSpec()
    local prevEnc, prevAll = pickerEncounter, collectAll
    pickerEncounter, collectAll = encounterID, true
    local ok, out = pcall(CollectCandidates)
    pickerEncounter, collectAll = prevEnc, prevAll
    return ok and out or {}
end

-- Adds or removes a spell from whichever list the editor is pointed at.
function ns.SetSpellOnList(forSpec, encounterID, spellID, on)
    RefreshSpec()
    local cur
    if encounterID then cur = BossList(forSpec, encounterID, true)
    else cur = UserList(forSpec, true) end
    if not cur then return false end

    local at = ListIndexOf(cur, spellID)
    if on then
        if at then return true end
        if #cur >= MAX_SLOTS then
            ns.Print(("that list is full (%d maximum) -- switch one off first."):format(MAX_SLOTS))
            return false
        end
        cur[#cur + 1] = spellID
    elseif at then
        table.remove(cur, at)
    end
    RebuildSlots()
    UpdateEventRegistration()
    UpdatePreview()
    return true
end

-- Moves an entry to a new position in its list.
function ns.MoveOnList(forSpec, encounterID, spellID, dest)
    local cur = encounterID and BossList(forSpec, encounterID, true) or UserList(forSpec, true)
    if not cur then return end
    local at = ListIndexOf(cur, spellID)
    if not at then return end
    table.remove(cur, at)
    if dest < 1 then dest = 1 end
    if dest > #cur + 1 then dest = #cur + 1 end
    table.insert(cur, dest, spellID)
    RebuildSlots()
    UpdateEventRegistration()
    UpdatePreview()
end

function ns.EffectiveListFor(forSpec, encounterID)
    if encounterID then return BossList(forSpec, encounterID, false) end
    return UserList(forSpec, false)
end

-- User-added spell IDs, per spec. The automatic list comes from Blizzard's classification;
-- this is the escape hatch for anything it misses.
function ns.CustomSpells(forSpec)
    local t = TRDB()
    if type(t.custom) ~= "table" then return nil end
    return t.custom[tostring(forSpec or 0)]
end

function ns.AddCustomSpell(forSpec, spellID)
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    if not info then
        ns.Print(("no spell with ID %s."):format(tostring(spellID)))
        return false
    end
    local t = TRDB()
    if type(t.custom) ~= "table" then t.custom = {} end
    local key = tostring(forSpec or 0)
    if type(t.custom[key]) ~= "table" then t.custom[key] = {} end
    t.custom[key][tostring(spellID)] = true
    ns.Print(("added %s (%d). Switch it on to put it in your priority."):format(
        info.name or "?", spellID))
    return true
end

function ns.RemoveCustomSpell(forSpec, spellID)
    local t = TRDB()
    local key = tostring(forSpec or 0)
    if type(t.custom) ~= "table" or type(t.custom[key]) ~= "table" then return end
    t.custom[key][tostring(spellID)] = nil
    if next(t.custom[key]) == nil then t.custom[key] = nil end
    if next(t.custom) == nil then t.custom = nil end
end

-- Removing an auto-populated ability cannot delete it -- Blizzard's classification will hand
-- it straight back on the next rebuild -- so removal is recorded as a hide instead. User-added
-- spells are deleted outright, since nothing regenerates those.
function ns.HiddenSpells(forSpec)
    local t = TRDB()
    if type(t.hidden) ~= "table" then return nil end
    return t.hidden[tostring(forSpec or 0)]
end

function ns.HideSpell(forSpec, spellID)
    local t = TRDB()
    if type(t.hidden) ~= "table" then t.hidden = {} end
    local key = tostring(forSpec or 0)
    if type(t.hidden[key]) ~= "table" then t.hidden[key] = {} end
    t.hidden[key][tostring(spellID)] = true
end

function ns.UnhideAll(forSpec)
    local t = TRDB()
    if type(t.hidden) ~= "table" then return end
    t.hidden[tostring(forSpec or 0)] = nil
    if next(t.hidden) == nil then t.hidden = nil end
end

-- A spell ID resolves to a real spell. Used to gate the Add button as the user types.
function ns.ResolveSpell(text)
    local sid = tonumber(text and tostring(text):match("^%s*(%d+)%s*$"))
    if not sid or sid <= 0 then return nil end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
    if not info then return nil end
    return sid, info
end

-- Per-spell audio. On unless switched off, so nothing has to be migrated and a fresh list
-- speaks by default. Spell ID 0 is the "nothing is up" fallback line.
function ns.IsAudioOff(spellID)
    local a = TRDB().audioOff
    return a ~= nil and a[tostring(spellID or 0)] == true
end

function ns.SetAudioOff(spellID, off)
    local t = TRDB()
    local key = tostring(spellID or 0)
    if off then
        if type(t.audioOff) ~= "table" then t.audioOff = {} end
        t.audioOff[key] = true
    elseif type(t.audioOff) == "table" then
        t.audioOff[key] = nil
        if next(t.audioOff) == nil then t.audioOff = nil end
    end
end

-- A callout is either a sound file or spoken text. Storing only the sound key keeps the
-- text intact underneath, so switching back to speech does not lose what was typed.
function ns.SoundFor(spellID)
    local t = TRDB().sounds
    local key = t and t[tostring(spellID or 0)]
    if key == nil or key == "none" then return nil end
    return key
end

function ns.SetSoundFor(spellID, key)
    local t = TRDB()
    local id = tostring(spellID or 0)
    if key and key ~= "none" then
        if type(t.sounds) ~= "table" then t.sounds = {} end
        t.sounds[id] = key
    elseif type(t.sounds) == "table" then
        t.sounds[id] = nil
        if next(t.sounds) == nil then t.sounds = nil end
    end
end

-- Fresh tables per call: the SharedMedia appender mutates in place and caches by
-- table identity, so handing the same tables to two dropdowns collapses them into one.
function ns.SoundChoices()
    local EUI = ns.UI
    if not (EUI and EUI.BuildAlertSoundTables) then return nil end
    local paths, names, order = EUI.BuildAlertSoundTables()
    if EUI.AppendSharedMediaSounds then EUI.AppendSharedMediaSounds(paths, names, order) end
    -- The speech option used to live in here as a pseudo-sound. It is a radio now, so the
    -- dropdown lists sounds and nothing else.
    names["none"] = nil
    for i = #order, 1, -1 do
        if order[i] == "none" then table.remove(order, i) end
    end
    return paths, names, order
end

-- The plain settings a profile carries, for the pack exporter: everything DEFAULTS names,
-- which is display, sound, voice, scope and behaviour. A fresh list rather than DEFAULTS
-- itself so nothing can write back through it. `pos` is not in DEFAULTS -- it is a table and
-- only exists once the alert has been moved -- so the exporter takes it separately.
function ns.SettingKeys()
    local out = {}
    for k in pairs(DEFAULTS) do out[#out + 1] = k end
    table.sort(out)
    return out
end

function ns.SettingDefault(key)
    return DEFAULTS[key]
end

ns.DB            = TRDB
ns.UserList      = UserList
ns.BossList      = BossList
ns.ClearBossList = ClearBossList
ns.ListIndexOf   = ListIndexOf
ns.CalloutFor    = CalloutFor
ns.SetCallout    = SetCallout
ns.IsSpellDisabled  = IsSpellDisabled
ns.SetSpellDisabled = SetSpellDisabled
ns.IsSpellAvailable = IsSpellAvailable
ns.ShowPicker    = function(onDone) pickerEncounter = nil; ShowPicker(onDone) end
ns.ShowPickerFor = function(_, encounterID, onDone)
    pickerEncounter = encounterID
    ShowPicker(function()
        pickerEncounter = nil
        if onDone then onDone() end
    end)
end
ns.ShowCalloutEditor = function(...) return ShowCalloutEditor(...) end
ns.MAX_SLOTS     = MAX_SLOTS
function ns.CurrentSpec() return specID, isTank end
function ns.RefreshRuntime()
    if ns.Integrations then ns.Integrations.Refresh() end
    ns.PruneCustomReminderTimers()
    ns.PrunePendingBWFires()
    RebuildSlots()
    RebuildCastMap()
    UpdateEventRegistration()
    UpdatePreview()
    RefreshCustomRemindersFlag()
end

-------------------------------------------------------------------------------
--  Reset / re-apply
-------------------------------------------------------------------------------
-- Re-apply is owned by the core's QueueReapply, called by our own profile switch and the
-- spec-change handler below.

function ns.Reset()
    HideReminder()
    activeSlots = 0
    ns.ClearEventSounds()
    ns.SettingsRoot().tankReminder = nil
    ns.PruneCustomReminderTimers()
    ns.PrunePendingBWFires()
    ApplySize()        -- the saved size and position went with the table
    ApplyPosition()
    ApplyTextLayout()
    UpdateEventRegistration()
end

-------------------------------------------------------------------------------
--  Boot
-------------------------------------------------------------------------------
watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
watcher:RegisterEvent("SPELLS_CHANGED")
watcher:RegisterEvent("TRAIT_CONFIG_UPDATED")
-- Not in UpdateEventRegistration with the others: everything it toggles sits under
-- ShouldRun(), and a Time In Combat reminder has to fire for a player with no defensive
-- priority list at all (CustomRemindersAllowed is the gate instead).
watcher:RegisterEvent("PLAYER_REGEN_DISABLED")
-- Fires whenever the boss1-5 engage units change, which is the only thing that can
-- invalidate ns.bossGUIDs. Static rather than under UpdateEventRegistration: the aura
-- triggers that read the cache run under hasCustomReminders/hasRaidReminders, neither of
-- which is tied to ShouldRun(), so a cache refreshed only on that path would go stale for
-- exactly the players still using it.
watcher:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
-- The engage-unit event is not the only thing that moves a unit in or out of a boss
-- slot. Blizzard's own boss frames refresh on both it and UNIT_TARGETABLE_CHANGED
-- (Blizzard_UnitFrame/Mainline/TargetFrame.lua), because a boss that phases in becomes
-- targetable without the engage list changing. Registered here for the same reason: a
-- GUID that arrives that way would otherwise stay out of ns.bossGUIDs until the next
-- engage-unit event, and every aura on that boss is missed for the whole window.
watcher:RegisterEvent("UNIT_TARGETABLE_CHANGED")
-- Rare, and all it does is drop a cache: the resolved TTS voice stops being valid once the
-- installed voice list changes underneath us.
watcher:RegisterEvent("VOICE_CHAT_TTS_VOICES_UPDATE")

watcher:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    -- FIRST in the chain, and gated before the pcall: this is by far the most frequent
    -- event in the game (thousands a second in a raid), every other branch below it was
    -- a string compare it had to walk past, and a protected-call frame per line is not
    -- free either. Out of an encounter, or on a boss with nothing configured, the whole
    -- handler is now three plain boolean reads.
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if currentEncounter == nil
            or not (runActive or hasCustomReminders or hasRaidReminders) then
            return
        end
        local okL, errL = pcall(OnCombatLog)
        if not okL then
            ns.Print("|cffff6060combat log watch failed|r: " .. ErrText(errL))
        end
        return
    end

    if event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        ns.RefreshBossGUIDs()
        return
    end

    if event == "UNIT_TARGETABLE_CHANGED" then
        -- Fires for every unit the client tracks, nameplates included, so both filters
        -- earn their place: outside a pull nothing reads the cache (both aura readers
        -- sit behind currentEncounter), and a token that is not boss1-5 cannot change
        -- what is in it. What survives both is rare enough to refresh all five slots.
        if currentEncounter ~= nil and type(arg1) == "string"
            and arg1:find("boss", 1, true) == 1 then
            ns.RefreshBossGUIDs()
        end
        return
    end

    if event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        -- Dying and running back resets much of a kit, and the model cannot see that. Drop
        -- the estimates and re-read whatever is readable now.
        wipe(readyAt)
        ResyncModel()
        return
    end

    if event == "ENCOUNTER_START" or event == "ENCOUNTER_END" then
        local starting = (event == "ENCOUNTER_START")
        -- Commit BEFORE the clocks are cleared: the recorder measures against them, and
        -- clearing first left it with no pull start, so it bailed and discarded the pull.
        if not starting and ns.ObserveCommitPull then
            ns.ObserveCommitPull(arg1, arg3)
        end
        currentEncounter = starting and arg1 or nil
        -- INSTANCE_ENCOUNTER_ENGAGE_UNIT covers changes mid-fight; this is the baseline
        -- for a pull whose units were already up, and the clear on the way out.
        ns.RefreshBossGUIDs()
        -- Static timeline sounds have no per-fire Lua callback. Refresh their
        -- registration against this encounter's tags when the opt-out is active.
        if not ns.HealerRemindersEnabled() and ns.BossSource() == "timeline" then
            RegisterEventSounds()
        end
        -- arg3 is difficultyID (payload is encounterID, name, difficultyID, groupSize).
        -- Timings genuinely differ between difficulties, so observed data is keyed by it.
        currentEncounterStartedAt = starting and GetTime() or nil
        currentDifficultyID = starting and arg3 or nil
        if starting and ns.ObserveBeginPull then ns.ObserveBeginPull() end
        if TRDB().trace then
            AppendLog({ kind = "enc", text = ("%s %s %s"):format(
                event == "ENCOUNTER_START" and "START" or "END",
                tostring(arg1), tostring(arg2)) })
        end
        -- Boss death does not reset the player's cooldowns; keep witnessed deadlines.
        wipe(ns.lastTankedAt)
        lastAnnouncedSpellID = nil
        RebuildSlots()          -- swap to this boss's list before the first ability lands
        RebuildCastMap()
        UpdateEventRegistration()   -- this boss may be switched off entirely

        -- Custom reminders: a fresh pull means a fresh count for the "Nth cast" counter,
        -- and the coverage flag has to catch up before the pull trigger itself can fire.
        -- Boss-mod arbitration and any bar-timeleft activations scheduled on the last
        -- pull reset the same way -- a stale pending timer must never survive into the
        -- next attempt.
        wipe(customCounters)
        bwActiveMod = nil
        currentStage = nil
        currentStageAt = nil
        -- By scope, not everything: a combat trigger counts from entering combat, and
        -- pulling a boss out of the trash in front of it does not restart that clock.
        ns.CancelTrackedReminderTimers("pull")
        ns.CancelTrackedReminderTimers("stage")
        ns.CancelTrackedReminderTimers("bosscombat")
        for k, handle in pairs(bwPendingTimers) do
            if handle.Cancel then handle:Cancel() end
            bwPendingTimers[k] = nil
            ns.pendingCustomReminderOwners[k] = nil
        end
        wipe(bwCdEndsAt)
        CancelAllPendingBWFires()
        for k in pairs(castSourceGUID) do
            castSourceGUID[k] = nil
        end
        -- A missed SPELL_AURA_REMOVED (addon toggled off mid-buff, reload mid-fight)
        -- must not leave a stale "still covered" reading into the next pull.
        for k in pairs(playerAuraUp) do
            playerAuraUp[k] = nil
        end
        RefreshCustomRemindersFlag()
        if event == "ENCOUNTER_START" then
            RegisterBossModHooks()   -- in case BigWigs/DBM loaded after this addon did
            CheckCustomReminders("pull", nil)
            ns.CheckBossCombatReminders()
            if ns.CheckRaidReminderPullTriggers then ns.CheckRaidReminderPullTriggers() end
        end

        if event == "ENCOUNTER_START" and TRDB().enabled == true then
            local why
            if not canSelect then why = "this client lacks the cooldown API"
            elseif not TimelineAvailable() then why = "the boss timeline feature is unavailable here"
            elseif not BossAllowed() then why = "this boss is switched off in Smart Reminders"
            end
            if not why then
                local t2 = TRDB()
                if not (t2.showIcon or t2.showText or t2.voiceOn or t2.soundOn) then
                    why = "icon, text, voice and sound are ALL switched off"
                elseif not (t2.showIcon or t2.showText or t2.voiceOn)
                    and not saidAudioOnly then
                    -- A reminder for a legitimate configuration, so once per session; the
                    -- true all-off state above stays per boss because it is always wrong.
                    saidAudioOnly = true
                    why = "only Play a Sound is on: expect one beep per ability per pull, "
                        .. "nothing else"
                end
            end
            if why then
                ns.Print("|cffff6060not running this fight|r: " .. why)
            end
        end

        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        NoteOwnCast(arg3)   -- (unit, castGUID, spellID); unit is always "player" here
        ns.HideIfCalloutPressed(arg3)
        return
    end

    -- Login and spec change are where a profile bound to a spec takes effect. It runs before
    -- everything below rather than returning: PLAYER_LOGIN has its own handler further down
    -- that registers the boss mod hooks and the CVar callbacks, and returning here would skip
    -- them. SwitchProfile clears the cached root, so whatever reads settings after this --
    -- including that handler -- already sees the new profile.
    if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_LOGIN"
        or event == "PLAYER_ENTERING_WORLD" then
        RefreshSpec()
        if ns.ApplySpecProfile then ns.ApplySpecProfile(specID) end
    end

    if event == "PLAYER_REGEN_DISABLED" then
        -- An ns field, not a chunk local: this chunk is at the 200-local ceiling.
        ns.combatStartedAt = GetTime()
        -- Blizzard's Text to Speech panel fires nothing when its selected voice changes, so
        -- re-resolve once per pull instead. Warmed here rather than left lazy so the first
        -- callout of the fight is not the one paying for the lookup.
        ns.InvalidateTTSVoice()
        if TRDB().voiceOn then ns.TTSVoiceID() end
        ns.CheckCombatReminders()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" or event == "SPELL_UPDATE_COOLDOWN" then
        if event == "SPELL_UPDATE_COOLDOWN" then ns.ResyncModelSoon() else ResyncModel() end
        if event == "PLAYER_REGEN_ENABLED" then
            ns.CancelTrackedReminderTimers("combat")
            -- A combat log toggle skipped because of combat lockdown lands here.
            UpdateEventRegistration()
        end
        return
    end

    if event == "VOICE_CHAT_TTS_VOICES_UPDATE" then
        ns.InvalidateTTSVoice()
        return
    end


    if event == "PLAYER_LOGIN" then
        RegisterBossModHooks()
        if ns.ObservedPrune then ns.ObservedPrune() end
        local EUI = ns.UI
        if EUI and EUI.RegisterOnShow then
            EUI:RegisterOnShow(function() previewing = true; UpdatePreview() end)
        end
        if EUI and EUI.RegisterOnHide then
            EUI:RegisterOnHide(function()
                previewing = false
                UpdatePreview()
                -- Closing the settings panel should not leave the anchor-config toolbar
                -- and its draggable handles orphaned on screen.
                if ns.HideRaidReminderAnchorConfig then ns.HideRaidReminderAnchorConfig(true) end
            end)
        end
        -- The two CVars that decide whether data flows. Blizzard already marks them cachable,
        -- so this piggybacks rather than polling. We only ever READ them.
        if CVarCallbackRegistry and CVarCallbackRegistry.RegisterCallback then
            for _, cvar in ipairs({ "combatWarningsEnabled", "encounterTimelineEnabled" }) do
                pcall(function()
                    CVarCallbackRegistry:RegisterCallback(cvar, function() ns.Apply() end, watcher)
                end)
            end
        end
        C_Timer.After(1, function() ns.Apply() end)
        return
    end

    -- SPELLS_CHANGED and TRAIT_CONFIG_UPDATED arrive in bursts; one Apply covers them.
    ns.QueueReapply()
end)

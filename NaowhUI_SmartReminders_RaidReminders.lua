-------------------------------------------------------------------------------
--  NaowhUI_SmartReminders_RaidReminders.lua -- raid-wide external/CD reminders.
--
--  Same idea as NorthernSkyRaidTools/TimelineReminders (countdown Bar/Icon/Text/
--  Circle reminders assignable to a role/class/spec/name/subgroup, not just the local
--  player), built on the BigWigs/DBM bar bridge the main file already runs for tank
--  busters (ns.ScheduleBWFire) instead of a hand-authored pull-timer table. Neither
--  reference addon actually listens to BigWigs/DBM at all -- this is additive to
--  proven code, not a port of their approach.
--
--  Targeting is evaluated LOCALLY, per client, at fire time -- no addon comms. Every
--  raider's own BigWigs instance already broadcasts the same bar independently, so
--  each client deciding for itself whether a reminder is "for me" is the same model
--  the tank-buster engine already uses, just with an extra yes/no check before
--  showing anything.
--
--  Engine only -- data model, scheduling, targeting, and all four displays. The
--  authoring UI (ns.ShowRaidReminderEditor, reached through the boss-detail cog's
--  ns.ShowBossReminderPicker rather than its own top-level tab) lives in
--  NaowhUI_SmartReminders_Bosses.lua, which already had the tab/mechanic-picker
--  scaffolding this needed and loads after this file.
-------------------------------------------------------------------------------
local ns = _G.NaowhUITankReminder
if not ns then return end

-------------------------------------------------------------------------------
--  Data
-------------------------------------------------------------------------------
-- profile.raidReminders[encounterID][uid] = {
--     name, enabled,
--     trigger = { type = "bwtimer"|"bwmsg"|"pull"|"stage", spellID, leadTime,
--                 delay (pull/stage: seconds after the anchor), stage (stage only) },
--     target  = { all = bool, roles = {TANK=true,...}, classes = {PALADIN=true,...},
--                 specs = {[specID]=true,...}, names = {["Name"]=true,...},
--                 subgroups = {[1]=true,...} },
--     display = { type = "text"|"icon"|"bar"|"circle"|"chat"|"wa"|"nameplateGlow"|
--                 "raidframeGlow", text, spellID, color, dur, sound, tts },
-- }
-- Same PerBossSet shape customReminders already uses (NaowhUI_SmartReminders.lua),
-- reused rather than reimplemented -- one helper, every per-boss table goes through it.
local function RaidRemindersTable(create, enc)
    return ns.PerBossSet("raidReminders", create, enc)
end
ns.RaidRemindersTable = RaidRemindersTable

-------------------------------------------------------------------------------
--  Targeting -- evaluated against the LOCAL player only, no roster sync needed
-------------------------------------------------------------------------------
-- Subgroup needs a roster walk since UnitGroupRolesAssigned/UnitClass/spec all answer
-- for "player" directly, but there is no single-call "which subgroup am I in" outside
-- raid group info -- confirmed against NorthernSkyRaidTools' own GetSubGroup, which
-- walks the same GetRaidRosterInfo/UnitIsUnit loop (architecture only, not copied).
local function MySubgroup()
    for i = 1, 40 do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name and UnitIsUnit(name, "player") then return subgroup end
    end
    return 1   -- solo/party: no raid roster, only ever "group 1"
end

-- Which unit token a player name currently answers to -- needed for the glow display
-- types (nameplate/raid-frame), which target a SPECIFIC other raider's frame rather
-- than deciding whether the local client should show anything at all. nil when the
-- name isn't found (out of group, typo, or just not visible in the roster this frame).
local function UnitTokenForName(name)
    if not name or name == "" then return nil end
    if UnitName("player") == name then return "player" end
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do
            local unit = "raid" .. i
            if UnitExists(unit) and UnitName(unit) == name then return unit end
        end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) and UnitName(unit) == name then return unit end
        end
    end
    return nil
end

-- Old single kind+value shape, normalized to the new multi-flag one on read rather
-- than migrated in place -- this feature only shipped this session, so there is no
-- real saved data to preserve, and a read-time fallback is simpler than a migration
-- file for something this new. Every reader of a raid reminder's target (targeting
-- itself, the editor, the summary description) goes through this.
function ns.NormalizeRaidReminderTarget(target)
    if not target then return { all = true } end
    if target.kind then
        local n = { all = target.kind == "all" }
        if target.kind == "role" then n.roles = { [target.value] = true }
        elseif target.kind == "class" then n.classes = { [target.value] = true }
        elseif target.kind == "spec" then n.specs = { [target.value] = true }
        elseif target.kind == "name" then n.names = { [target.value] = true }
        elseif target.kind == "subgroup" then n.subgroups = { [target.value] = true }
        end
        return n
    end
    return target
end

-- Confirmed against MRT's own CheckPlayerCondition: AND across categories, OR within
-- one. Multiple role flags OR together, multiple class flags OR together, but setting
-- both Role=Healer AND Class=Priest narrows to their intersection, not their union --
-- an empty/unset category is vacuously true rather than false, same as MRT's own
-- pflitercount/cflitercount/rflitercount == 0 short-circuit, so picking only a role
-- does not also require a class match by accident.
function ns.RaidReminderTargetsMe(target)
    target = ns.NormalizeRaidReminderTarget(target)
    if target.all then return true end

    if target.roles and next(target.roles) and not target.roles[UnitGroupRolesAssigned("player")] then
        return false
    end
    if target.classes and next(target.classes) then
        local _, classToken = UnitClass("player")
        if not target.classes[classToken] then return false end
    end
    if target.specs and next(target.specs) then
        local id = ns.CurrentSpec and ns.CurrentSpec()
        if not target.specs[id] then return false end
    end
    if target.names and next(target.names) and not target.names[UnitName("player")] then
        return false
    end
    if target.subgroups and next(target.subgroups) and not target.subgroups[MySubgroup()] then
        return false
    end
    return true
end

-------------------------------------------------------------------------------
--  Rendering -- one Anchor (movable container) per display type, each holding a pool
--  of Region instances (one per currently-shown reminder of that type). Regions are
--  created once and hidden/reused, never destroyed -- same idiom RebuildSlots already
--  uses for the tank-buster slots[] pool.
-------------------------------------------------------------------------------
local ANCHOR_DEFAULT_POS = {
    text = { x = 0, y = 40 },
    timer = { x = -120, y = 40 },
    icon = { x = 120, y = 40 },
    bar = { x = 0, y = -60 },
    circle = { x = 120, y = -60 },
}

-- profile.raidReminderAnchorPos[displayType] = { point, relPoint, x, y }, written by
-- Unlock Mode (ns.GetRaidReminderAnchor/ns.ApplyRaidReminderAnchorPosition, wired up in
-- NaowhUI_SmartReminders.lua's RegisterUnlock) the same way the tank-buster frame's own
-- TRDB().pos already works. Falls back to ANCHOR_DEFAULT_POS when nothing is saved.
local function ApplyAnchorPosition(a, displayType)
    local p = ns.DB().raidReminderAnchorPos and ns.DB().raidReminderAnchorPos[displayType]
    a:ClearAllPoints()
    if p then
        a:SetPoint(p.point or "CENTER", UIParent, p.relPoint or "CENTER", p.x or 0, p.y or 0)
    else
        local def = ANCHOR_DEFAULT_POS[displayType]
        a:SetPoint("CENTER", UIParent, "CENTER", def and def.x or 0, def and def.y or 0)
    end
end

local anchors = {}   -- [displayType] = frame, .pool = {}, .active = {}

local function GetAnchor(displayType)
    local a = anchors[displayType]
    if a then return a end
    a = CreateFrame("Frame", "NaowhUIRaidReminder" .. displayType .. "Anchor", UIParent)
    a:SetSize(10, 10)
    a:SetClampedToScreen(true)
    -- Matches the tank-buster callout's own baseline (NaowhUI_SmartReminders.lua) --
    -- HIGH normally, bumped to FULLSCREEN_DIALOG only while ns.PreviewRaidReminder has
    -- the editor modal open (see below).
    a:SetFrameStrata("HIGH")
    a.pool, a.active = {}, {}
    anchors[displayType] = a
    ApplyAnchorPosition(a, displayType)
    return a
end

-- Unlock Mode's getFrame: lazily creates the anchor the first time Unlock Mode itself
-- is opened, same as a real/preview fire would, so there is always something to drag
-- even if this display type has never fired this session.
ns.GetRaidReminderAnchor = GetAnchor

function ns.ApplyRaidReminderAnchorPosition(displayType)
    local a = anchors[displayType]
    if a then ApplyAnchorPosition(a, displayType) end
end

-- Stacks active regions top-to-bottom under the anchor, most-recently-added first --
-- same function for all four display types, since each has its own Anchor and never
-- stacks against a different type. Fixed top-down for now; a real grow-direction
-- setting (the authoring UI's per-anchor gear window) is a later phase, not this loop.
-- Every region an anchor owns, which is NOT just pool + active: config mode's sample
-- (a._configSample, see RefreshConfigVisual) is built off-pool on purpose, and it is the
-- one region actually on screen while you drag a size slider. Resizing only the tracked
-- lists is why the sliders looked dead.
local function ForEachRegion(a, fn)
    for _, r in ipairs(a.pool) do fn(r) end
    for _, r in ipairs(a.active) do fn(r) end
    if a._configSample then fn(a._configSample) end
end

local function RestackRegions(a)
    local y = 0
    for i = 1, #a.active do
        local r = a.active[i]
        r:ClearAllPoints()
        r:SetPoint("TOP", a, "TOP", 0, y)
        y = y - r:GetHeight() - 4
    end
end

local function ReleaseRegion(a, r)
    r.reminderEntry = nil
    for i = 1, #a.active do
        if a.active[i] == r then table.remove(a.active, i) break end
    end
    r:Hide()
    if r.hideTimer then r.hideTimer:Cancel(); r.hideTimer = nil end
    a.pool[#a.pool + 1] = r
    -- Undo any Preview-specific elevation (ns.PreviewRaidReminder) so a real fight never
    -- inherits it -- same reset-on-hide shape HideCustomReminder already uses for the
    -- tank-buster editor's own Preview button.
    a:SetFrameStrata("HIGH")
    a:SetFrameLevel(1)
    RestackRegions(a)
end

-- Use the same profile font as defensive and ability reminders.
local function AlertFontPath()
    return ns.AlertFontPath()
end

-- User-resizable via Unlock Mode (see MakeRaidReminderUnlockElement in
-- NaowhUI_SmartReminders.lua): width is the text box's own width, font size drives how
-- big the text itself reads -- independent axes, unlike Circle/Icon which stay square.
local TEXT_WIDTH_DEFAULT, TEXT_FONTSIZE_DEFAULT = 320, 16
local function TextSize()
    local w = ns.DB().raidReminderTextWidth
    local fs = ns.DB().raidReminderTextFontSize
    w = (type(w) == "number" and w > 0) and w or TEXT_WIDTH_DEFAULT
    fs = (type(fs) == "number" and fs > 0) and fs or TEXT_FONTSIZE_DEFAULT
    return w, fs
end

-- Caption size for the four displays that draw a label beside their content (Message
-- carries its own, above). Stored per display type so a big Bar caption does not drag
-- the Icon's along with it.
local LABEL_SIZE_DEFAULTS = {
    raidReminderIconTextSize = 12,
    raidReminderCircleTextSize = 12,
    raidReminderBarTextSize = 12,
    raidReminderTimerTextSize = 11,
    raidReminderTimerNumberSize = 26,
}
local function LabelSize(key)
    local s = ns.DB()[key]
    return (type(s) == "number" and s > 0) and s or LABEL_SIZE_DEFAULTS[key]
end

local function CreateTextRegion(a)
    local w, fs = TextSize()
    local r = CreateFrame("Frame", nil, a)
    r:SetSize(w, fs + 10)
    r.text = ns.Font(r, fs, "OUTLINE")
    r.text:SetFont(AlertFontPath(), fs, "OUTLINE")
    r.text:SetPoint("CENTER")
    r:Hide()
    return r
end

function ns.ResizeRaidReminderText()
    local a = anchors.text
    if not a then return end
    local w, fs = TextSize()
    ForEachRegion(a, function(r)
        r:SetSize(w, fs + 10)
        r.text:SetFont(AlertFontPath(), fs, "OUTLINE")
    end)
    RestackRegions(a)
end

-- A big ticking number, distinct from the static Message display -- what NSRT and
-- TimelineReminders call a Timer. label is the optional caption above it (what the
-- countdown is FOR); the number itself is driven by the same expirationTime/OnUpdate
-- idiom CreateBarRegion already uses, just formatted as whole seconds instead of a fill.
local function TimerSize()
    local cap = LabelSize("raidReminderTimerTextSize")
    local num = LabelSize("raidReminderTimerNumberSize")
    return cap, num, math.max(120, num * 3), cap + num + 8
end

local function CreateTimerRegion(a)
    local cap, num, w, h = TimerSize()
    local r = CreateFrame("Frame", nil, a)
    r:SetSize(w, h)
    r.label = ns.Font(r, cap, "OUTLINE")
    r.label:SetFont(AlertFontPath(), cap, "OUTLINE")
    r.label:SetPoint("TOP", r, "TOP", 0, 0)
    r.number = ns.Font(r, num, "OUTLINE")
    r.number:SetFont(AlertFontPath(), num, "OUTLINE")
    r.number:SetPoint("TOP", r.label, "BOTTOM", 0, -2)
    r:Hide()
    return r
end

function ns.ResizeRaidReminderTimer()
    local a = anchors.timer
    if not a then return end
    local cap, num, w, h = TimerSize()
    local function Apply(r)
        r:SetSize(w, h)
        r.label:SetFont(AlertFontPath(), cap, "OUTLINE")
        r.number:SetFont(AlertFontPath(), num, "OUTLINE")
    end
    ForEachRegion(a, Apply)
    RestackRegions(a)
end

-- Icon inset matches CreateSlot's (NaowhUI_SmartReminders.lua) own texture coords --
-- same reason: crops the icon's own border art rather than showing it doubled up
-- against this region's border.
-- User-resizable via Unlock Mode, stored at TRDB().raidReminderIconSize (see
-- CircleSize's own comment for the shape).
local ICON_SIZE_DEFAULT = 48
local function IconSize()
    local s = ns.DB().raidReminderIconSize
    return (type(s) == "number" and s > 0) and s or ICON_SIZE_DEFAULT
end

local function CreateIconRegion(a)
    local size = IconSize()
    local r = CreateFrame("Frame", nil, a)
    r:SetSize(size, size + LabelSize("raidReminderIconTextSize") + 6)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(size, size)
    r.icon:SetPoint("TOP", r, "TOP", 0, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local fs = LabelSize("raidReminderIconTextSize")
    r.label = ns.Font(r, fs, "OUTLINE")
    r.label:SetFont(AlertFontPath(), fs, "OUTLINE")
    r.label:SetPoint("TOP", r.icon, "BOTTOM", 0, -2)
    r:Hide()
    return r
end

function ns.ResizeRaidReminderIcon()
    local a = anchors.icon
    if not a then return end
    local size = IconSize()
    local fs = LabelSize("raidReminderIconTextSize")
    local function Apply(r)
        r:SetSize(size, size + fs + 6)
        r.icon:SetSize(size, size)
        r.label:SetFont(AlertFontPath(), fs, "OUTLINE")
    end
    ForEachRegion(a, Apply)
    RestackRegions(a)
end

-- LibSharedMedia lookup, same source NaowhMedia (NaowhUI_SmartReminders.lua) reads --
-- duplicated rather than exported: six lines, no state, not worth a cross-file call for.
local function StatusBarTexture()
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if not LSM then return nil end
    local ok, path = pcall(LSM.Fetch, LSM, "statusbar", "NaowhGradient", true)
    return ok and path or nil
end

-- Styled like the tank-buster CreateBar (NaowhUI_SmartReminders.lua) -- same texture,
-- same bg/fill colors -- but genuinely counts down here (that bar is a static 1-slot
-- display with nothing driving its value live). expirationTime/OnUpdate are this
-- region's own; set fresh by ns.DisplayRaidReminder on every acquire, so a pooled
-- region picked back up for a new reminder starts counting down from the new value the
-- moment OnUpdate's next tick runs, never from whatever the last reminder left behind.
-- User-resizable via Unlock Mode, stored at TRDB().raidReminderBarWidth/Height --
-- independent axes (unlike Circle/Icon), since a bar naturally has separate width and
-- thickness.
local BAR_WIDTH_DEFAULT, BAR_HEIGHT_DEFAULT = 240, 16
local function BarSize()
    local w, h = ns.DB().raidReminderBarWidth, ns.DB().raidReminderBarHeight
    w = (type(w) == "number" and w > 0) and w or BAR_WIDTH_DEFAULT
    h = (type(h) == "number" and h > 0) and h or BAR_HEIGHT_DEFAULT
    return w, h
end

local function CreateBarRegion(a)
    local w, h = BarSize()
    local fs = LabelSize("raidReminderBarTextSize")
    local r = CreateFrame("Frame", nil, a)
    r:SetSize(w, h + fs + 4)

    r.label = ns.Font(r, fs, "OUTLINE")
    r.label:SetFont(AlertFontPath(), fs, "OUTLINE")
    r.label:SetPoint("TOP", r, "TOP", 0, 0)

    r.bar = CreateFrame("StatusBar", nil, r)
    r.bar:SetSize(w, h)
    r.bar:SetPoint("BOTTOM", r, "BOTTOM", 0, 0)
    r.bar:SetMinMaxValues(0, 1)
    r.bar:SetStatusBarTexture(StatusBarTexture() or "Interface\\TargetingFrame\\UI-StatusBar")
    local T = ns.THEME
    local bg = r.bar:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", r.bar, "TOPLEFT", -1, 1)
    bg:SetPoint("BOTTOMRIGHT", r.bar, "BOTTOMRIGHT", 1, -1)
    bg:SetColorTexture(T.bg.r, T.bg.g, T.bg.b, 0.9)
    local fill = r.bar:GetStatusBarTexture()
    if fill then fill:SetVertexColor(T.accent.r, T.accent.g, T.accent.b, 1) end
    ns.Border(r.bar)

    r:Hide()
    return r
end

function ns.ResizeRaidReminderBar()
    local a = anchors.bar
    if not a then return end
    local w, h = BarSize()
    local fs = LabelSize("raidReminderBarTextSize")
    local function Apply(r)
        r:SetSize(w, h + fs + 4)
        r.bar:SetSize(w, h)
        r.label:SetFont(AlertFontPath(), fs, "OUTLINE")
    end
    ForEachRegion(a, Apply)
    RestackRegions(a)
end

-- A real spell icon, circularly cropped, with the standard Blizzard cooldown-swipe
-- widget on top -- a square icon plus a swipe is what every action button does, but
-- reads as a square with a pie-wipe, not "an actual circle". The mask/ring pair is the
-- addon's own (Tools/make_media.py): shape in the alpha channel, since masks read alpha,
-- and the ring doubles as the drawn border.
local CIRCLE_SIZE_DEFAULT = 56
local CIRCLE_MASK_PATH = "Interface\\AddOns\\NaowhSmartReminders\\Media\\circle_mask.tga"

-- Set from the anchor's gear popup, stored at TRDB().raidReminderCircleSize.
local function CircleSize()
    local s = ns.DB().raidReminderCircleSize
    return (type(s) == "number" and s > 0) and s or CIRCLE_SIZE_DEFAULT
end

-- The ring is two half-disc textures, each clipped to one half of the circle and
-- rotated so its straight edge lands on the sweep angle -- the remaining arc is
-- whatever survives the clip. No per-frame geometry, and the edge is exact at any
-- angle rather than quantised. It replaces a 24-segment tick ring, which existed
-- because masking the Cooldown widget's swipe returns an opaque black square on this
-- client (confirmed live twice, with two different mask shapes -- do not retry it).
-- Thickness is a centred mask that punches the middle out, so it is a live setting
-- rather than baked into the art.
local CIRCLE_HALF_PATH = "Interface\\AddOns\\NaowhSmartReminders\\Media\\circle_half.tga"
local CIRCLE_HOLE_PATH = "Interface\\AddOns\\NaowhSmartReminders\\Media\\circle_hole.tga"
local CIRCLE_THICKNESS_DEFAULT = 10

local function CircleThickness()
    local t = ns.DB().raidReminderCircleThickness
    t = (type(t) == "number" and t > 0) and t or CIRCLE_THICKNESS_DEFAULT
    -- A hole at least 2px across, or the mask stops reading as a ring at all.
    return math.min(t, CircleSize() / 2 - 1)
end

-- circle_half.tga carries the RIGHT half of a disc, which is the clockwise span 0-180
-- from twelve o'clock. Rotating it clockwise by A moves that span to A..180+A, and the
-- half it is clipped to shows only what still falls inside -- so the right piece draws
-- A..180 and the left piece, based one half-turn round, draws A..360. Positive rotation
-- is counter-clockwise (Blizzard's own arrow rotations), hence the negated angles.
local function SetCircleSweep(r, elapsedDeg)
    if elapsedDeg >= 360 then
        r.fillR:Hide(); r.fillL:Hide()
        return
    end
    r.fillR:SetShown(elapsedDeg < 180)
    r.fillR:SetRotation(-math.rad(math.min(elapsedDeg, 180)))
    r.fillL:Show()
    r.fillL:SetRotation(-math.pi - math.rad(math.max(elapsedDeg - 180, 0)))
end

local function LayoutCircle(r, size, thickness, fs)
    r:SetSize(size, size + fs + 6)
    r.ring:SetSize(size, size)
    r.bg:SetSize(size, size)
    r.clipL:SetSize(size / 2, size)
    r.clipR:SetSize(size / 2, size)
    r.fillL:SetSize(size, size)
    r.fillR:SetSize(size, size)
    r.hole:SetSize(size - 2 * thickness, size - 2 * thickness)
    r.label:SetFont(AlertFontPath(), fs, "OUTLINE")
end

local function CreateCircleRegion(a)
    local size, thickness = CircleSize(), CircleThickness()
    local fs = LabelSize("raidReminderCircleTextSize")
    local r = CreateFrame("Frame", nil, a)

    r.ring = CreateFrame("Frame", nil, r)
    r.ring:SetPoint("BOTTOM", r, "BOTTOM", 0, 0)

    r.hole = r.ring:CreateMaskTexture()
    r.hole:SetPoint("CENTER", r.ring, "CENTER")
    r.hole:SetTexture(CIRCLE_HOLE_PATH, "CLAMPTOWHITE", "CLAMPTOWHITE")

    r.bg = r.ring:CreateTexture(nil, "BACKGROUND")
    r.bg:SetPoint("CENTER", r.ring, "CENTER")
    r.bg:SetTexture(CIRCLE_MASK_PATH)
    r.bg:SetVertexColor(0, 0, 0, 0.5)
    r.bg:AddMaskTexture(r.hole)

    -- The clip frames are what turn a rotating half-disc into an arc; without
    -- SetClipsChildren each piece would spill into the other half.
    r.clipL = CreateFrame("Frame", nil, r.ring)
    r.clipL:SetPoint("TOPLEFT", r.ring, "TOPLEFT")
    r.clipL:SetClipsChildren(true)
    r.clipR = CreateFrame("Frame", nil, r.ring)
    r.clipR:SetPoint("TOPRIGHT", r.ring, "TOPRIGHT")
    r.clipR:SetClipsChildren(true)

    for _, side in ipairs({ "L", "R" }) do
        local clip = (side == "L") and r.clipL or r.clipR
        local t = clip:CreateTexture(nil, "ARTWORK")
        t:SetTexture(CIRCLE_HALF_PATH)
        t:SetPoint("CENTER", r.ring, "CENTER")
        t:AddMaskTexture(r.hole)
        r["fill" .. side] = t
    end

    r.label = ns.Font(r, fs, "OUTLINE")
    r.label:SetPoint("BOTTOM", r.ring, "TOP", 0, 4)

    LayoutCircle(r, size, thickness, fs)
    SetCircleSweep(r, 0)
    r:Hide()
    return r
end

-- Re-sizes every pooled/active Circle region, from the gear popup's Size, Thickness
-- and Text Size sliders.
function ns.ResizeRaidReminderCircle()
    local a = anchors.circle
    if not a then return end
    local size, thickness = CircleSize(), CircleThickness()
    local fs = LabelSize("raidReminderCircleTextSize")
    local function Apply(r) LayoutCircle(r, size, thickness, fs) end
    ForEachRegion(a, Apply)
    RestackRegions(a)
end

-- Anchor sizes for Unlock Mode's mover box (ns.GetRaidReminderAnchor's caller) -- the
-- anchor frame itself is a bare 10x10 point, so without this the mover would draw far
-- smaller than what actually appears there. Floored at MOVER_MIN in both dimensions
-- (well past the tank-buster "Smart" element's own default iconSize of 64) so every
-- anchor is comfortably easier to click and drag than that one, even where the real
-- content is thinner (Text/Bar are only ~16-32px tall by default).
local MOVER_MIN = 100
function ns.RaidReminderAnchorSize(displayType)
    local w, h
    if displayType == "text" then local tw, fs = TextSize(); w, h = tw, fs + 10
    elseif displayType == "timer" then local _, _, tw, th = TimerSize(); w, h = tw, th
    elseif displayType == "icon" then local s = IconSize()
        w, h = s, s + LabelSize("raidReminderIconTextSize") + 6
    elseif displayType == "bar" then local bw, bh = BarSize()
        w, h = bw, bh + LabelSize("raidReminderBarTextSize") + 4
    elseif displayType == "circle" then local s = CircleSize()
        w, h = s, s + LabelSize("raidReminderCircleTextSize") + 6
    else w, h = MOVER_MIN, MOVER_MIN end
    return math.max(w, MOVER_MIN), math.max(h, MOVER_MIN)
end

local REGION_CTORS = {
    text = CreateTextRegion, timer = CreateTimerRegion, icon = CreateIconRegion,
    bar = CreateBarRegion, circle = CreateCircleRegion,
}

local function AcquireRegion(displayType)
    local a = GetAnchor(displayType)
    local ctor = REGION_CTORS[displayType]
    if not ctor then return nil end
    local r = table.remove(a.pool)
    if not r then r = ctor(a) end
    -- Set explicitly rather than left to inherit from the parent at creation time --
    -- a pooled region can be reused long after the anchor's own strata/level last
    -- changed (e.g. a preview elevation from an earlier open of the editor).
    r:SetFrameStrata(a:GetFrameStrata())
    r:SetFrameLevel(a:GetFrameLevel() + 1)
    a.active[#a.active + 1] = r
    return a, r
end

-------------------------------------------------------------------------------
--  Glow display types -- nameplate/raid-frame, a highlight on an EXISTING unit frame
--  rather than a floating on-screen widget, so they don't fit the Anchor/Region pool
--  above (that pool always renders at one fixed screen spot; a glow's location is
--  wherever the target's frame happens to be this instant, resolved fresh on every
--  fire). Own small pool of dedicated overlay wrapper frames instead: the glow engine
--  parks its textures on whatever frame it is handed, so that frame has to be a
--  dedicated overlay parented over the target, never the nameplate/raid-frame's own
--  display frame -- a stray leftover on that would outlive the reminder.
-------------------------------------------------------------------------------
local glowPool, activeGlows = {}, {}

local function AcquireGlowWrapper()
    local w = table.remove(glowPool)
    if not w then
        w = CreateFrame("Frame", nil, UIParent)
        w:SetFrameStrata("HIGH")
    end
    activeGlows[#activeGlows + 1] = w
    return w
end

local function ReleaseGlowWrapper(w)
    local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
    if LCG then LCG.PixelGlow_Stop(w) end
    if w.hideTimer then w.hideTimer:Cancel(); w.hideTimer = nil end
    w:Hide()
    w:ClearAllPoints()
    w:SetParent(UIParent)
    w.hideAfterCastID = nil
    w.reminderEntry = nil
    for i = 1, #activeGlows do
        if activeGlows[i] == w then table.remove(activeGlows, i) break end
    end
    glowPool[#glowPool + 1] = w
end

-- nameplate reads the live Blizzard nameplate directly (C_NamePlate); raidframe goes
-- through LibGetFrame, which resolves the unit's frame on whichever raid-frame addon is
-- actually drawing it. Either can come back nil (unit not currently visible on any frame
-- of that kind), in which case the glow is silently skipped for this fire.
-- LibGetFrame drives its scan with `coroutine.resume(co, 0, UIParent)` and
-- discards the return value, so one frame that raises anywhere under UIParent
-- kills the walk silently and the cache keeps whatever partial set it had --
-- every later rescan dies in the same place. Measured live on two accounts
-- 2026-09-04: EllesmereUI raid buttons pass every gate that scan applies
-- (Button, not forbidden, visible, no cancelaura type attribute, a real global
-- name, a readable unit attribute, three hops under UIParent) and still never
-- appear in its cache, so raidframeGlow silently did nothing for those users.
--
-- The library is asked first, so nothing changes for anyone it already answers
-- for. This backs it up: the unit lives on the secure "unit" attribute, which
-- is what LibGetFrame itself reads.
local EUI_UNIT_BUTTONS
local function ResolveEUIUnitFrame(unit)
    if not EUI_UNIT_BUTTONS then
        EUI_UNIT_BUTTONS = {}
        local function add(n) EUI_UNIT_BUTTONS[#EUI_UNIT_BUTTONS + 1] = n end
        -- Ranges follow what the raid frames actually build: the flat header
        -- holds up to 40, each separated group header exactly 5, and the extra
        -- frames are capped at 20 (XF.CAP), not 8.
        for i = 1, 40 do add("ERFFlatHeaderUnitButton" .. i) end
        for g = 1, 8 do for i = 1, 5 do add("ERFGroupHeader" .. g .. "UnitButton" .. i) end end
        for i = 1, 20 do add("ERFExtraFrame" .. i) end
        for i = 1, 5 do add("ERFPartyHeaderUnitButton" .. i) end
        add("ERFPartySelfButton")
    end
    local issec = _G.issecretvalue
    for i = 1, #EUI_UNIT_BUTTONS do
        local b = _G[EUI_UNIT_BUTTONS[i]]
        if b then
            -- IsVisible, not IsShown: a button reports shown while an ancestor
            -- is hidden, and the raid header's buttons sit hidden in a party.
            local okV, vis = pcall(b.IsVisible, b)
            if okV and vis then
                local okA, u = pcall(b.GetAttribute, b, "unit")
                -- Type check before any comparison: a secret attribute is not a
                -- string, so this rejects it without ever comparing one.
                if okA and type(u) == "string" and not (issec and issec(u)) then
                    if u == unit then return b end
                    -- In a raid the player's own button carries a raidN token,
                    -- so a literal compare never finds "player" -- the library
                    -- matched it through UnitIsUnit. Ask only for that case, and
                    -- only accept a plain true, since the comparison is refused
                    -- rather than answered on an addon-restricted map.
                    if unit == "player" then
                        local okU, same = pcall(UnitIsUnit, u, "player")
                        if okU and not (issec and issec(same)) and same == true then
                            return b
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function ResolveGlowFrame(displayType, unit)
    if displayType == "nameplateGlow" then
        local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
        return plate and (plate.UnitFrame or plate)
    elseif displayType == "raidframeGlow" then
        local LGF = LibStub and LibStub("LibGetFrame-1.0", true)
        local f = LGF and LGF.GetUnitFrame and LGF.GetUnitFrame(unit)
        if f then return f end
        return ResolveEUIUnitFrame(unit)
    end
    return nil
end

local function FireGlowReminder(display, dur, entry)
    local unit = UnitTokenForName(display.glowTarget)
    local frame = unit and ResolveGlowFrame(display.type, unit)
    if not frame then return end

    local w = AcquireGlowWrapper()
    w:SetParent(frame)
    w:ClearAllPoints()
    w:SetAllPoints(frame)
    w:Show()
    w.hideAfterCastID = display.hideAfterCastID
    w.reminderEntry = entry

    local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
    if LCG then
        local c = display.color
        LCG.PixelGlow_Start(w, { (c and c.r) or 1, (c and c.g) or 0.82, (c and c.b) or 0, 1 })
    end

    if w.hideTimer then w.hideTimer:Cancel() end
    w.hideTimer = C_Timer.NewTimer(dur, function() ReleaseGlowWrapper(w) end)
end

-- Same two-step icon resolution CreateSlot (NaowhUI_SmartReminders.lua) already uses:
-- GetSpellInfo first (nothing for a spell the client has not cached yet), GetSpellTexture
-- as a second try, the question mark as the last resort -- never a blank icon. Shared by
-- Icon and Circle, the two display types that show a real spell icon.
local function ResolveDisplayIconID(display)
    if not display.spellID then return nil end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(display.spellID)
    local iconID = info and info.iconID
    if not iconID and C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, display.spellID)
        if ok then iconID = tex end
    end
    return iconID
end

-- Curated subset of MRT's own placeholder language (MRT's version runs to roughly 40
-- distinct constructs -- a math evaluator, regex find/replace, a class/role/subgroup
-- filter-query language; deliberately not reproduced here, see this session's own MRT
-- research). %name is always the VIEWER's own name and class color, never anyone
-- else's -- a reminder can target more than one person, and each client only ever
-- needs to say its own. {spell:ID} skips the hover tooltip MRT's version has: nothing
-- in this addon's display widgets are hoverable, so a tooltip would never be reachable.
local function FormatReminderMsg(text, display)
    if type(text) ~= "string" or text == "" then return text end

    if text:find("%%name") then
        local name = UnitName("player") or ""
        local _, classToken = UnitClass("player")
        local colors = RAID_CLASS_COLORS or CUSTOM_CLASS_COLORS
        local c = classToken and colors and colors[classToken]
        if c and c.colorStr then name = "|c" .. c.colorStr .. name .. "|r" end
        text = text:gsub("%%name", name)
    end

    if text:find("%%specicon") then
        local icon = ""
        if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
            local index = C_SpecializationInfo.GetSpecialization()
            if index then
                local _, _, _, iconTex = C_SpecializationInfo.GetSpecializationInfo(index)
                if iconTex then icon = "|T" .. iconTex .. ":16|t" end
            end
        end
        text = text:gsub("%%specicon", icon)
    end

    if text:find("%%time") then
        local dur = (type(display.dur) == "number" and display.dur > 0) and display.dur or 4
        text = text:gsub("%%time", tostring(math.floor(dur + 0.5)))
    end

    if text:find("{spell:") then
        text = text:gsub("{spell:(%-?%d+)}", function(idStr)
            local sid = tonumber(idStr)
            if not sid then return "" end
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
            local name = (info and info.name) or ("Spell " .. sid)
            local iconID = info and info.iconID
            if not iconID and C_Spell and C_Spell.GetSpellTexture then
                local ok, tex = pcall(C_Spell.GetSpellTexture, sid)
                if ok then iconID = tex end
            end
            return (iconID and ("|T" .. iconID .. ":16|t") or "") .. name
        end)
    end

    return text
end
ns.FormatReminderMsg = FormatReminderMsg

-- The one place every real fire (and, once the editor exists, every Preview click)
-- routes through -- same "one dispatcher" shape as the existing ns.DisplayReminder for
-- Custom Reminders.
function ns.DisplayRaidReminder(entry, preview)
    if not ns.IsReminderEnabled(entry, preview) then return end
    local display = entry and entry.display
    if not display then return end

    -- Resolved once, used everywhere below (every display widget, chat, and TTS) --
    -- display.text itself stays the raw saved template, since Preview/every future
    -- fire has to re-resolve it fresh (the viewer's own name can change between
    -- fires even within one pull, e.g. a raid reminder that fires more than once).
    local formattedText = FormatReminderMsg(display.text, display)

    -- Chat has no on-screen Region at all -- a local chat line, same sound/TTS as
    -- every other type, no pooled frame or hide timer to manage.
    if display.type == "chat" then
        if formattedText and formattedText ~= "" then ns.Print(formattedText) end
        ns.PlayReminderSound(display)
        ns.SpeakReminderTTS(display, formattedText, preview)
        return
    end

    -- Glow types highlight an existing unit frame instead of the Anchor/Region pool
    -- below -- FireGlowReminder owns their whole lifecycle (frame resolution, the
    -- dedicated overlay wrapper, the hide timer), same sound/TTS tacked on same as
    -- every other type.
    if display.type == "nameplateGlow" or display.type == "raidframeGlow" then
        local dur = (type(display.dur) == "number" and display.dur > 0) and display.dur or 4
        FireGlowReminder(display, dur, entry)
        ns.PlayReminderSound(display)
        ns.SpeakReminderTTS(display, formattedText, preview)
        return
    end

    local a, r = AcquireRegion(display.type)
    if not r then
        ns.Print(("|cffff6060raid reminder|r: display type %q not built yet."):format(
            tostring(display.type)))
        return
    end
    -- Read by the UNIT_SPELLCAST_SUCCEEDED watcher below -- nil for the vast majority
    -- of reminders, which never carry this optional field.
    r.hideAfterCastID = display.hideAfterCastID
    r.reminderEntry = entry

    -- Computed here, not after the type dispatch below: Bar/Circle need it to drive
    -- their own live countdown, and the release timer at the bottom needs the SAME
    -- value so a bar's visual countdown and the moment it actually disappears agree.
    local dur = (type(display.dur) == "number" and display.dur > 0) and display.dur or 4

    if display.type == "text" then
        r.text:SetText(formattedText or "")
        if display.color then
            r.text:SetTextColor(display.color.r or 1, display.color.g or 1,
                display.color.b or 1, display.color.a or 1)
        else
            r.text:SetTextColor(1, 1, 1, 1)
        end
    elseif display.type == "icon" then
        r.icon:SetTexture(ResolveDisplayIconID(display) or 134400)
        if formattedText and formattedText ~= "" then
            r.label:SetText(formattedText)
            r.label:Show()
        else
            r.label:Hide()
        end
    elseif display.type == "timer" then
        r.label:SetText(formattedText or "")
        r.expirationTime = GetTime() + dur
        r.number:SetText(tostring(math.ceil(dur)))
        r.shownSecond = math.ceil(dur)
        -- Only when the displayed second actually changes: SetText plus the tostring it
        -- needs was allocating a string every frame for a number that changes once a
        -- second, and several reminders can be on screen at once.
        r:SetScript("OnUpdate", function(self)
            local remain = self.expirationTime - GetTime()
            local sec = remain > 0 and math.ceil(remain) or 0
            if sec ~= self.shownSecond then
                self.shownSecond = sec
                self.number:SetText(tostring(sec))
            end
        end)
    elseif display.type == "bar" then
        r.label:SetText(formattedText or "")
        r.bar.expirationTime = GetTime() + dur
        r.bar:SetMinMaxValues(0, dur)
        r.bar:SetValue(dur)
        r.bar:SetScript("OnUpdate", function(self)
            local remain = self.expirationTime - GetTime()
            self:SetValue(remain > 0 and remain or 0)
        end)
    elseif display.type == "circle" then
        -- The spell icon rides inline in the caption rather than filling the ring, so a
        -- reminder with no spell ID reads as text over an empty ring instead of a
        -- question mark.
        local iconID = ResolveDisplayIconID(display)
        local caption = formattedText or ""
        if iconID then caption = ("|T%s:0|t %s"):format(tostring(iconID), caption) end
        local color = display.color
        if color then
            r.fillL:SetVertexColor(color.r, color.g, color.b)
            r.fillR:SetVertexColor(color.r, color.g, color.b)
            r.label:SetTextColor(color.r, color.g, color.b)
        else
            local T = ns.THEME
            r.fillL:SetVertexColor(T.accent.r, T.accent.g, T.accent.b)
            r.fillR:SetVertexColor(T.accent.r, T.accent.g, T.accent.b)
            r.label:SetTextColor(1, 1, 1)
        end
        r.caption = caption
        r.expirationTime = GetTime() + dur
        SetCircleSweep(r, 0)
        r.label:SetText(caption)
        r.shownTenth = nil
        -- One decimal, matching how the ring reads: the arc visibly moves between whole
        -- seconds, so a whole-second number beside it looks stuck.
        --
        -- The sweep stays per frame because the arc is meant to look continuous, but the
        -- caption only changes ten times a second and was being rebuilt on every one of
        -- them. Same fix, and the same reason, as the "timer" display above.
        r:SetScript("OnUpdate", function(self)
            local remain = self.expirationTime - GetTime()
            if remain < 0 then remain = 0 end
            SetCircleSweep(self, (1 - remain / dur) * 360)
            -- Printed FROM the tenth it keys on, not from remain: keying on one value and
            -- printing another lets the two disagree, and %.1f rounds half to even where
            -- any arithmetic here rounds half up, so an exact .x5 frame showed a tenth the
            -- key had already moved past. Truncating also reads correctly for a countdown
            -- -- 9.2 means at least 9.2 left -- at the cost of showing each tenth up to
            -- 0.05s earlier than before, which is not visible at a tenth's granularity.
            local tenth = math.floor(remain * 10)
            if tenth ~= self.shownTenth then
                self.shownTenth = tenth
                self.label:SetFormattedText("%s (%.1f)", self.caption, tenth / 10)
            end
        end)
    end

    r:Show()
    RestackRegions(a)
    ns.PlayReminderSound(display)
    ns.SpeakReminderTTS(display, formattedText, preview)

    if r.hideTimer then r.hideTimer:Cancel() end
    r.hideTimer = C_Timer.NewTimer(dur, function() ReleaseRegion(a, r) end)
end

-- The editor's Preview button fires this from inside its own modal (FULLSCREEN_DIALOG),
-- which the anchor's normal HIGH strata sits well below -- same problem and same fix
-- ns.PreviewCustomReminder (NaowhUI_SmartReminders.lua) already solved for the
-- tank-buster editor's own Preview button. ReleaseRegion drops the anchor back to HIGH
-- once the preview ends, so the elevation never leaks into a real fight's display.
function ns.PreviewRaidReminder(entry)
    if not ns.IsReminderEnabled(entry, true) then return end
    local display = entry and entry.display
    if not display then return end
    -- Chat and the glow types have no anchor to elevate -- ns.DisplayRaidReminder's
    -- own branches for them handle everything needed below with nothing extra here.
    local NO_ANCHOR_TYPES = { chat = true, nameplateGlow = true, raidframeGlow = true }
    local a = (not NO_ANCHOR_TYPES[display.type]) and GetAnchor(display.type) or nil
    if a then
        a:SetFrameStrata("FULLSCREEN_DIALOG")
        a:SetFrameLevel(250)
        -- Clicking Preview again before the last one finished lingering was stacking a
        -- brand new region on top of it each time (AcquireRegion has no reason to know
        -- a previous preview of this exact type is still up) -- release whatever is
        -- still active on this anchor first so a preview replaces the last one instead
        -- of piling up. Only Preview does this; a real fire never should, since two
        -- genuinely different reminders of the same display type stacking together is
        -- correct there.
        while #a.active > 0 do ReleaseRegion(a, a.active[#a.active]) end
    end
    ns.DisplayRaidReminder(entry, true)
end

-- Clear only displays owned by opted-out reminders; preserve unrelated alerts.
function ns.HideFilteredRaidReminders()
    for _, a in pairs(anchors) do
        for i = #a.active, 1, -1 do
            local r = a.active[i]
            if r.reminderEntry and not ns.IsReminderEnabled(r.reminderEntry) then ReleaseRegion(a, r) end
        end
    end
    for i = #activeGlows, 1, -1 do
        local w = activeGlows[i]
        if w.reminderEntry and not ns.IsReminderEnabled(w.reminderEntry) then ReleaseGlowWrapper(w) end
    end
end

-- MRT's event-13 "hide after use" gate: a reminder with display.hideAfterCastID set
-- disappears the instant you successfully cast that spell, instead of waiting out its
-- own Linger. RegisterUnitEvent("player") rather than parsing the combat log --
-- lighter, and there is no need to know about anyone else's casts here.
local castGateWatcher = CreateFrame("Frame")
castGateWatcher:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
castGateWatcher:SetScript("OnEvent", function(_, _, _, _, spellID)
    if not spellID then return end
    for _, a in pairs(anchors) do
        for i = #a.active, 1, -1 do
            local r = a.active[i]
            if r.hideAfterCastID == spellID then ReleaseRegion(a, r) end
        end
    end
    for i = #activeGlows, 1, -1 do
        local w = activeGlows[i]
        if w.hideAfterCastID == spellID then ReleaseGlowWrapper(w) end
    end
end)

-------------------------------------------------------------------------------
--  Anchor config -- move and resize every anchor with a live sample shown for each,
--  opened from the Setup page ("Customize Anchors" button). Same idea
--  NSRT/TimelineReminders both offer, built on this addon's own existing pieces (the
--  Anchor/pool system above, ns.MakeModal, ns.THEME) rather than copying either one's
--  look: a plain in-house drag handle + gear popup instead of their green banner rows.
-------------------------------------------------------------------------------
local DISPLAY_TYPE_LABEL = { defensive = "Defensive", text = "Message", timer = "Timer", icon = "Icon", bar = "Bar", circle = "Circle" }
local CONFIG_ORDER = { "defensive", "text", "timer", "icon", "bar", "circle" }

-- All checked by default, so entering config mode shows everything; unticking is the
-- session-local way to declutter while placing one display.
local configShown = {}
for _, dt in ipairs(CONFIG_ORDER) do configShown[dt] = true end
local configActive = false
local reopenWindowOnExit = false

-- Fills a region with static placeholder content -- no live countdown, no hide timer --
-- so it sits still on screen for as long as config mode has that type checked. Separate
-- from ns.DisplayRaidReminder's dispatch, which is built around a live, expiring fire.
local function PopulateSample(displayType, r)
    if displayType == "text" then
        r.text:SetText("Sample Reminder")
        r.text:SetTextColor(1, 1, 1, 1)
    elseif displayType == "icon" then
        r.icon:SetTexture(134400)
        r.label:SetText("Sample")
        r.label:Show()
    elseif displayType == "timer" then
        r.label:SetText("Sample Timer")
        r.number:SetText("5")
    elseif displayType == "bar" then
        r.label:SetText("Sample Bar")
        r.bar:SetScript("OnUpdate", nil)
        r.bar:SetMinMaxValues(0, 1)
        r.bar:SetValue(0.6)
    elseif displayType == "circle" then
        r:SetScript("OnUpdate", nil)
        r.label:SetText("|T134400:0|t Sample (3.4)")
        r.label:SetTextColor(1, 1, 1)
        local T = ns.THEME
        r.fillL:SetVertexColor(T.accent.r, T.accent.g, T.accent.b)
        r.fillR:SetVertexColor(T.accent.r, T.accent.g, T.accent.b)
        -- Parked 40% through so the sweep's direction is visible while placing it.
        SetCircleSweep(r, 0.4 * 360)
    end
end

-- The draggable handle: a small labeled bar below the anchor's sample, carrying the
-- gear button. Created once per anchor and reused; StartMoving/StopMovingOrSizing are
-- called on the ANCHOR (the handle is just the visible grip), same idiom
-- NaowhUI_SmartReminders.lua's own UpdatePreview already uses for the tank-buster frame.
-- Shared by the drag and the snap grid, so both land in the same slot. The defensive alert
-- keeps its own position field, which the preview drag in the main file also writes.
local function SaveAnchorPos(displayType, point, relPoint, x, y)
    if not point then return end
    local db = ns.DB()
    if displayType == "defensive" then
        db.pos = { point = point, relPoint = relPoint, x = x, y = y }
        if ns.ApplyDefensiveAlertPosition then ns.ApplyDefensiveAlertPosition() end
    else
        db.raidReminderAnchorPos = db.raidReminderAnchorPos or {}
        db.raidReminderAnchorPos[displayType] = { point = point, relPoint = relPoint, x = x, y = y }
    end
end

-- The alignment grid, matching EllesmereUI's unlock mode: 32px spacing measured outward
-- from screen centre so the centre always lands on a line, a full-length accent crosshair
-- marking it, and everything on BACKGROUND strata so it sits behind the real UI rather
-- than over the anchors being placed. Alphas sit above EUI's own bright pair (0.30/0.50),
-- which still read faint here -- this grid competes with the game world behind it rather
-- than the flat options background EUI's sits on.
local GRID_SPACING = 32
local GRID_LINE_ALPHA = 0.45
local GRID_CENTER_ALPHA = 0.70
local gridOverlay

-- One physical pixel, whatever the UI scale. Lines drawn at a fractional width land on a
-- blurred pair of pixels instead, which is what makes a grid look dirty.
local function PixelMult()
    local _, screenH = GetPhysicalScreenSize()
    local scale = UIParent:GetEffectiveScale()
    if not screenH or screenH <= 0 or not scale or scale <= 0 then return 1 end
    return (768 / screenH) / scale
end

local function BuildGridOverlay()
    if gridOverlay then return gridOverlay end
    gridOverlay = CreateFrame("Frame", nil, UIParent)
    gridOverlay:SetFrameStrata("BACKGROUND")
    gridOverlay:SetFrameLevel(1)
    gridOverlay:SetAllPoints(UIParent)
    gridOverlay._lines = {}
    gridOverlay:Hide()

    function gridOverlay:Rebuild()
        for i = 1, #self._lines do self._lines[i]:Hide() end
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        local c = ns.THEME.accent
        local mult = PixelMult()
        local spacing = GRID_SPACING * mult
        local function Snap(v) return math.floor(v / mult + 0.5) * mult end
        local centerX, centerY = Snap(w / 2), Snap(h / 2)
        local idx = 0

        local function Line(isVert, pos, alpha)
            idx = idx + 1
            local tex = self._lines[idx]
            if not tex then
                tex = self:CreateTexture(nil, "BACKGROUND", nil, -7)
                if tex.SetSnapToPixelGrid then
                    tex:SetSnapToPixelGrid(false)
                    tex:SetTexelSnappingBias(0)
                end
                self._lines[idx] = tex
            end
            tex:SetColorTexture(c.r, c.g, c.b, alpha)
            tex:ClearAllPoints()
            if isVert then
                tex:SetSize(mult, h)
                tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", pos, 0)
            else
                tex:SetSize(w, mult)
                tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -pos)
            end
            tex:Show()
        end

        local x = centerX - spacing
        while x > 0 do Line(true, Snap(x), GRID_LINE_ALPHA); x = x - spacing end
        x = centerX + spacing
        while x < w do Line(true, Snap(x), GRID_LINE_ALPHA); x = x + spacing end

        local y = centerY - spacing
        while y > 0 do Line(false, Snap(y), GRID_LINE_ALPHA); y = y - spacing end
        y = centerY + spacing
        while y < h do Line(false, Snap(y), GRID_LINE_ALPHA); y = y + spacing end

        Line(true, centerX, GRID_CENTER_ALPHA)
        Line(false, centerY, GRID_CENTER_ALPHA)
    end

    return gridOverlay
end

function ns.SetAnchorGridShown(shown)
    if not shown then
        if gridOverlay then gridOverlay:Hide() end
        return
    end
    local g = BuildGridOverlay()
    g:Rebuild()
    g:Show()
end

local function EnsureConfigHandle(displayType, a)
    if a._configHandle then return a._configHandle end
    local T = ns.THEME
    local h = CreateFrame("Button", nil, a)
    h:SetSize(150, 24)
    ns.Solid(h, "BACKGROUND", T.panel, 0.95)
    ns.Border(h)

    local label = ns.Font(h, 12, "OUTLINE", T.accent)
    label:SetPoint("LEFT", h, "LEFT", 8, 0)
    label:SetText(DISPLAY_TYPE_LABEL[displayType])

    local gear = CreateFrame("Button", nil, h)
    gear:SetSize(18, 18)
    gear:SetPoint("RIGHT", h, "RIGHT", -4, 0)
    local gearTex = gear:CreateTexture(nil, "ARTWORK")
    gearTex:SetAllPoints()
    gearTex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    gear:SetScript("OnClick", function() ns.ShowRaidReminderAnchorSizePopup(displayType) end)

    h:SetMovable(true)
    a:SetMovable(true)
    h:EnableMouse(true)
    h:RegisterForDrag("LeftButton")
    h:SetScript("OnDragStart", function() a:StartMoving() end)
    h:SetScript("OnDragStop", function()
        a:StopMovingOrSizing()
        local point, _, relPoint, x, y = a:GetPoint(1)
        SaveAnchorPos(displayType, point, relPoint, x, y)
    end)

    a._configHandle = h
    return h
end

local function RefreshConfigVisual(displayType)
    -- The defensive alert is not a pooled anchor: its sample is the alert's own preview,
    -- forced visible by the main file while config mode holds it. Only the drag handle
    -- comes from here, seated under the lowest visible piece (the bar, when shown).
    if displayType == "defensive" then
        if not (ns.SetDefensiveAnchorConfigShown and ns.GetDefensiveAlertFrame) then return end
        ns.SetDefensiveAnchorConfigShown(true)
        local f, alertBar = ns.GetDefensiveAlertFrame()
        if not f then return end
        local h = EnsureConfigHandle("defensive", f)
        h:ClearAllPoints()
        local below = (alertBar and alertBar:IsShown()) and alertBar or f
        h:SetPoint("TOP", below, "BOTTOM", 0, -4)
        h:Show()
        return
    end
    local a = GetAnchor(displayType)
    local h = EnsureConfigHandle(displayType, a)

    -- Built directly from REGION_CTORS rather than AcquireRegion, deliberately NOT
    -- tracked in a.active/a.pool: a real fire or Preview click while config mode is
    -- open would otherwise pull this sample into RestackRegions' normal stacking and
    -- reshuffle both it and the handle anchored off it. This way the sample always
    -- sits still at the anchor's own TOP regardless of what else happens to fire.
    if not a._configSample then
        a._configSample = REGION_CTORS[displayType](a)
    end
    a._configSample:SetFrameStrata(a:GetFrameStrata())
    a._configSample:SetFrameLevel(a:GetFrameLevel() + 1)
    PopulateSample(displayType, a._configSample)
    a._configSample:ClearAllPoints()
    a._configSample:SetPoint("TOP", a, "TOP", 0, 0)
    a._configSample:Show()

    -- Right under the sample's ACTUAL current height, not a fixed guess -- otherwise a
    -- small type (Message, Timer) leaves a large gap to the handle below it, and a
    -- large one could have the handle overlapping it.
    h:ClearAllPoints()
    h:SetPoint("TOP", a._configSample, "BOTTOM", 0, -4)
    h:Show()
end

local function HideConfigVisual(displayType)
    if displayType == "defensive" then
        local f = ns.GetDefensiveAlertFrame and ns.GetDefensiveAlertFrame()
        if f and f._configHandle then f._configHandle:Hide() end
        if ns.SetDefensiveAnchorConfigShown then ns.SetDefensiveAnchorConfigShown(false) end
        return
    end
    local a = anchors[displayType]
    if not a then return end
    if a._configHandle then a._configHandle:Hide() end
    -- Not pool-tracked (see RefreshConfigVisual), so just hidden and kept cached on the
    -- anchor for next time rather than released back to a.pool.
    if a._configSample then a._configSample:Hide() end
end

-- Rebuilds every checked type's visual -- called on entering config mode and after any
-- resize, since the handle is anchored off the sample's own height and needs re-placing
-- when that height changes.
local function RefreshAllConfigVisuals()
    if not configActive then return end
    for _, displayType in ipairs(CONFIG_ORDER) do
        if configShown[displayType] then RefreshConfigVisual(displayType) end
    end
end
ns.RefreshRaidReminderAnchorConfig = RefreshAllConfigVisuals

function ns.SetRaidReminderAnchorConfigShown(displayType, shown)
    configShown[displayType] = shown or nil
    if not configActive then return end
    if shown then RefreshConfigVisual(displayType) else HideConfigVisual(displayType) end
end

function ns.IsRaidReminderAnchorConfigShown(displayType)
    return configShown[displayType] == true
end

-- The toolbar itself: a small draggable panel on UIParent (not inside the EllesmereUI
-- options panel, so it stays put and usable while the panel is scrolled or another
-- tab is open) with one checkbox per display type and an Exit button. Built once,
-- shown/hidden rather than recreated.
local configToolbar

-- 2-column grid, two checkboxes per row; Exit Config takes the slot after the last
-- checkbox -- beside it when the count is odd, on its own row when even -- and the
-- panel height is derived from whichever row that lands on.
-- Column width fits the longest label ("Show Defensive Anchor") without running into
-- the next column; the panel is two columns plus the outer margins.
local CONFIG_COL_W, CONFIG_ROW_H = 162, 24

local function BuildConfigToolbar()
    if configToolbar then return configToolbar end
    local T = ns.THEME
    local f = CreateFrame("Frame", "NaowhUIRaidReminderAnchorConfig", UIParent)
    f:SetSize(14 + CONFIG_COL_W * 2 + 14, 116)
    f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    ns.Solid(f, "BACKGROUND", { r = 0, g = 0, b = 0 }, 1):SetAllPoints()
    ns.Border(f)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local head = ns.Font(f, 12, "OUTLINE", T.accent)
    head:SetPoint("TOP", f, "TOP", 0, -10)
    head:SetText("Reminder Anchors")

    local checks = {}
    local lastRow = 0
    for i, displayType in ipairs(CONFIG_ORDER) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        lastRow = row
        local chk = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        chk:SetSize(20, 20)
        chk:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + col * CONFIG_COL_W, -32 - row * CONFIG_ROW_H)
        local lbl = ns.Font(f, 11, nil, T.fg)
        lbl:SetPoint("LEFT", chk, "RIGHT", 2, 1)
        lbl:SetText("Show " .. DISPLAY_TYPE_LABEL[displayType] .. " Anchor")
        chk:SetScript("OnClick", function(self)
            ns.SetRaidReminderAnchorConfigShown(displayType, self:GetChecked() and true or false)
        end)
        checks[displayType] = chk
    end

    -- 5 items leaves the right column of the last row open; an odd count would instead
    -- fall after the last row entirely.
    local exitCol = (#CONFIG_ORDER % 2 == 1) and 1 or 0
    local exitRow = (#CONFIG_ORDER % 2 == 1) and lastRow or (lastRow + 1)
    ns.Button(f, "Exit Config", CONFIG_COL_W - 14, 22, function() ns.HideRaidReminderAnchorConfig() end)
        :SetPoint("TOPLEFT", f, "TOPLEFT", 14 + exitCol * CONFIG_COL_W, -31 - exitRow * CONFIG_ROW_H)
    f:SetHeight(44 + (exitRow + 1) * CONFIG_ROW_H)

    f._checks = checks
    configToolbar = f
    return f
end

function ns.ShowRaidReminderAnchorConfig()
    -- Stash BEFORE arming config mode: hiding the window fires the options OnHide
    -- callback, which calls HideRaidReminderAnchorConfig -- armed first, that callback
    -- disarmed the mode in the same click, leaving the toolbar up with its checkboxes
    -- checked and no sample ever drawn.
    -- Reopened on Exit Config only if it was open when we started, so entering config
    -- mode from a slash command does not conjure the window on the way out.
    local reopen = ns.StashOptionsWindow and ns.StashOptionsWindow() or false
    configActive = true
    reopenWindowOnExit = reopen
    local f = BuildConfigToolbar()
    for _, displayType in ipairs(CONFIG_ORDER) do
        if f._checks[displayType] then f._checks[displayType]:SetChecked(configShown[displayType] == true) end
    end
    f:Show()
    ns.SetAnchorGridShown(true)
    RefreshAllConfigVisuals()
end

-- windowClosing: called from the options window's own OnHide, which must not reopen it.
function ns.HideRaidReminderAnchorConfig(windowClosing)
    configActive = false
    ns.SetAnchorGridShown(false)
    if configToolbar then configToolbar:Hide() end
    for _, displayType in ipairs(CONFIG_ORDER) do HideConfigVisual(displayType) end
    if reopenWindowOnExit then
        reopenWindowOnExit = false
        if not windowClosing and ns.OpenOptionsWindow then ns.OpenOptionsWindow() end
    end
end

function ns.IsRaidReminderAnchorConfigActive()
    return configActive
end

-- Compact size popup for one anchor's gear button -- Width/Height for Bar and Message
-- (independent axes), a single Size for Icon/Circle (kept square), and a text size
-- everywhere, since every display draws a caption someone may need to read across the
-- room. Timer has no box to size, so its two font sizes ARE its rows -- without them its
-- gear opened nothing at all.
local TEXT_SIZE_MIN, TEXT_SIZE_MAX = 8, 48
local function TextSizeRow(label, key, resize)
    return { label = label, min = TEXT_SIZE_MIN, max = TEXT_SIZE_MAX,
        get = function() return LabelSize(key) end,
        set = function(v) ns.DB()[key] = math.floor(v); resize() end }
end
local RESIZE_ROWS = {
    defensive = {
        { label = "Icon Size", min = 16, max = 200,
            get = function() return ns.DB().iconSize or 64 end,
            set = function(v)
                ns.DB().iconSize = math.max(16, math.floor(v))
                if ns.RefreshDefensivePreview then ns.RefreshDefensivePreview() end
            end },
        { label = "Text Size", min = TEXT_SIZE_MIN, max = TEXT_SIZE_MAX,
            get = function() return ns.DB().textSize or 21 end,
            set = function(v)
                ns.DB().textSize = math.floor(v)
                if ns.RefreshDefensivePreview then ns.RefreshDefensivePreview() end
            end },
    },
    circle = {
        { label = "Size", min = 20, max = 200, get = function() return CircleSize() end,
            set = function(v) ns.DB().raidReminderCircleSize = math.max(20, math.floor(v)); ns.ResizeRaidReminderCircle() end },
        { label = "Thickness", min = 2, max = 40, get = function() return CircleThickness() end,
            set = function(v) ns.DB().raidReminderCircleThickness = math.max(2, math.floor(v)); ns.ResizeRaidReminderCircle() end },
        TextSizeRow("Text Size", "raidReminderCircleTextSize", function() ns.ResizeRaidReminderCircle() end),
    },
    icon = {
        { label = "Size", min = 16, max = 200, get = function() return IconSize() end,
            set = function(v) ns.DB().raidReminderIconSize = math.max(16, math.floor(v)); ns.ResizeRaidReminderIcon() end },
        TextSizeRow("Text Size", "raidReminderIconTextSize", function() ns.ResizeRaidReminderIcon() end),
    },
    bar = {
        { label = "Width", min = 60, max = 600, get = function() return (BarSize()) end,
            set = function(v) ns.DB().raidReminderBarWidth = math.max(60, math.floor(v)); ns.ResizeRaidReminderBar() end },
        { label = "Height", min = 6, max = 60, get = function() local _, h = BarSize(); return h end,
            set = function(v) ns.DB().raidReminderBarHeight = math.max(6, math.floor(v)); ns.ResizeRaidReminderBar() end },
        TextSizeRow("Text Size", "raidReminderBarTextSize", function() ns.ResizeRaidReminderBar() end),
    },
    text = {
        { label = "Width", min = 60, max = 800, get = function() return (TextSize()) end,
            set = function(v) ns.DB().raidReminderTextWidth = math.max(60, math.floor(v)); ns.ResizeRaidReminderText() end },
        { label = "Text Size", min = TEXT_SIZE_MIN, max = TEXT_SIZE_MAX,
            get = function() local _, fs = TextSize(); return fs end,
            set = function(v) ns.DB().raidReminderTextFontSize = math.max(8, math.floor(v)); ns.ResizeRaidReminderText() end },
    },
    timer = {
        TextSizeRow("Caption Size", "raidReminderTimerTextSize", function() ns.ResizeRaidReminderTimer() end),
        { label = "Number Size", min = 12, max = 96,
            get = function() return LabelSize("raidReminderTimerNumberSize") end,
            set = function(v) ns.DB().raidReminderTimerNumberSize = math.floor(v); ns.ResizeRaidReminderTimer() end },
    },
}

-- Built once per display type and re-shown: its rows never change, only the values shown in
-- them, which are repainted on each open.
local sizePopups = {}

function ns.ShowRaidReminderAnchorSizePopup(displayType)
    local rows = RESIZE_ROWS[displayType]
    if not rows then return end
    for other, popup in pairs(sizePopups) do
        if other ~= displayType then popup.dimmer:Hide() end
    end

    local popup = sizePopups[displayType]
    if not popup then
        -- Wide enough for label + 120px track + value box; the old numeric-box layout fit in 240.
        local dimmer, panel = ns.MakeModal(340, 60 + #rows * 34,
            "raidReminderAnchorSize:" .. displayType)
        local head = ns.Font(panel, 13, "OUTLINE")
        head:SetPoint("TOP", panel, "TOP", 0, -14)
        head:SetText((DISPLAY_TYPE_LABEL[displayType] or displayType) .. " Size")

        popup = { dimmer = dimmer, paints = {} }
        local PAD, y = 16, -42
        for i = 1, #rows do
            local row = rows[i]
            local l = ns.Font(panel, 11, nil, ns.THEME.muted)
            l:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
            l:SetText(row.label)

            local track, valBox, paint = ns.UI.BuildSliderCore(panel, 120, 4, 12, 44, 22, 12, 1,
                row.min or 8, row.max or 200, 1, row.get,
                function(v) row.set(v); RefreshAllConfigVisuals() end)
            valBox:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, y + 4)
            track:SetPoint("RIGHT", valBox, "LEFT", -8, 0)
            popup.paints[i] = paint
            y = y - 34
        end

        ns.Button(panel, "Done", 90, 26, function() dimmer:Hide() end)
            :SetPoint("BOTTOM", panel, "BOTTOM", 0, 14)
        sizePopups[displayType] = popup
    end
    for i = 1, #popup.paints do popup.paints[i]() end
    popup.dimmer:Show()
end

-------------------------------------------------------------------------------
--  Firing
-------------------------------------------------------------------------------
local function FireRaidReminder(entry)
    if ns.DB().enabled ~= true or not ns.BossAllowed() then return end
    if not ns.IsReminderEnabled(entry) then return end
    if not ns.RaidReminderTargetsMe(entry.target) then return end
    ns.DisplayRaidReminder(entry)
end

-- Same master switch as everything else in this addon (Custom Reminders already share
-- TRDB().enabled rather than having their own separate on/off) -- one switch, not a
-- second concept of "is the addon on" to keep in sync.
local function RaidRemindersAllowed()
    return ns.DB().enabled == true and ns.BossAllowed()
end

function ns.HideIntegrationReminders(previewOnly)
    for _, a in pairs(anchors) do
        for i = #a.active, 1, -1 do
            local r = a.active[i]
            local entry = r.reminderEntry
            if entry and entry.integration and (not previewOnly or entry.integrationPreview) then
                ReleaseRegion(a, r)
            end
        end
    end
    -- Integration reminders draw through the authored-reminder frame, not these regions;
    -- the loop above only still matters for anything saved before that moved.
    if ns.HideIntegrationCustomReminder then ns.HideIntegrationCustomReminder(previewOnly) end
end

-- Capture ownership, not just the entry: an editor replaces/deletes the table value,
-- and a profile switch can leave an otherwise enabled entry belonging to old settings.
local function ReminderStillCurrent(reminders, uid, entry)
    local profile = ns.DB()
    local encounter = ns.CurrentEncounter()
    local startedAt = ns.PullContext()
    return function()
        return RaidRemindersAllowed() and ns.DB() == profile
            and ns.InEncounter() and ns.CurrentEncounter() == encounter
            and ns.PullContext() == startedAt
            and RaidRemindersTable(false, encounter) == reminders
            and reminders[uid] == entry and ns.IsReminderEnabled(entry)
    end
end

-- BigWigs only, deliberately -- OnBigWigsEvent is the only caller (OnDBMEvent never
-- calls this). sid/duration/barIdentity are exactly what it already extracted and
-- issecretvalue-checked for ns.HandleBigWigsAbility -- reused as-is, no new secret
-- handling needed. Every raidReminders entry for the current encounter whose trigger
-- matches this exact broadcast gets scheduled independently (a pull can reasonably want
-- more than one reminder off the same bar, e.g. one for the tank and one for the healer).
function ns.HandleRaidReminderAbility(sid, duration, barIdentity, retried)
    if type(sid) ~= "number" or sid <= 0 then return end
    if not RaidRemindersAllowed() then return end
    local enc = ns.CurrentEncounter and ns.CurrentEncounter()
    -- An engage broadcast can arrive before the main file's ENCOUNTER_START handler has set
    -- the encounter: retried next frame, with the time already elapsed taken off a bar.
    if not enc then
        if not retried then
            local at = GetTime()
            C_Timer.After(0, function()
                ns.HandleRaidReminderAbility(sid, duration and duration - (GetTime() - at),
                    barIdentity, true)
            end)
        end
        return
    end
    if not (ns.InEncounter and ns.InEncounter()) then return end
    local reminders = RaidRemindersTable(false, enc)
    if not reminders then return end

    for uid, entry in pairs(reminders) do
        local trig = entry.trigger
        if ns.IsReminderEnabled(entry) and trig and trig.spellID == sid then
            local wantsBar = trig.type == "bwtimer"
            local haveBar = type(duration) == "number" and duration > 0.5
            if wantsBar and haveBar then
                -- 0 is a real answer ("at the end of the bar"), so only a missing or
                -- negative lead falls back to the 3s default.
                local lead = (type(trig.leadTime) == "number" and trig.leadTime >= 0)
                    and trig.leadTime or 3
                -- A channel per reminder: on a shared one, a second reminder on the same bar
                -- reads as a duplicate of the first and supersedes it.
                ns.ScheduleBWFire("raid:" .. tostring(uid), sid, duration, barIdentity, lead, function()
                    FireRaidReminder(entry)
                end, nil, ReminderStillCurrent(reminders, uid, entry))
            elseif trig.type == "bwmsg" and not haveBar then
                FireRaidReminder(entry)
            end
        end
    end
end

-- "pull" triggers aren't anchored to any BigWigs broadcast, so they never reach
-- ns.HandleRaidReminderAbility above -- called once from ENCOUNTER_START instead
-- (NaowhUI_SmartReminders.lua), the exact same moment CheckCustomReminders' own
-- "pull" trigger already answers to, rather than a second concept of "when did we
-- pull."
function ns.CheckRaidReminderPullTriggers()
    if not (ns.InEncounter and ns.InEncounter()) then return end
    if not RaidRemindersAllowed() then return end
    local enc = ns.CurrentEncounter and ns.CurrentEncounter()
    if not enc then return end
    local reminders = RaidRemindersTable(false, enc)
    if not reminders then return end

    for uid, entry in pairs(reminders) do
        local trig = entry.trigger
        if ns.IsReminderEnabled(entry) and trig and trig.type == "pull" then
            local delay = (type(trig.delay) == "number" and trig.delay >= 0) and trig.delay or 0.01
            -- leadTime pulls the fire earlier so the display counts down TO the noted
            -- moment rather than starting at it.
            local lead = type(trig.leadTime) == "number" and trig.leadTime or 0
            ns.TrackReminderTimer("pull", math.max(delay - lead, 0.01),
                function() FireRaidReminder(entry) end, nil, ReminderStillCurrent(reminders, uid, entry))
        end
    end
end

-- Same walk for stage triggers, run every time the boss mods report a NEW stage number
-- (the main file's SetStage branches own the change detection and the cancel of any
-- timers still pending from the previous stage).
function ns.CheckRaidReminderStageTriggers(stage)
    if not (ns.InEncounter and ns.InEncounter()) then return end
    if not RaidRemindersAllowed() then return end
    local enc = ns.CurrentEncounter and ns.CurrentEncounter()
    if not enc then return end
    local reminders = RaidRemindersTable(false, enc)
    if not reminders then return end

    for uid, entry in pairs(reminders) do
        local trig = entry.trigger
        if ns.IsReminderEnabled(entry) and trig and trig.type == "stage" and trig.stage == stage then
            local delay = (type(trig.delay) == "number" and trig.delay >= 0) and trig.delay or 0.01
            local lead = type(trig.leadTime) == "number" and trig.leadTime or 0
            ns.TrackReminderTimer("stage", math.max(delay - lead, 0.01),
                function() FireRaidReminder(entry) end, nil, ReminderStillCurrent(reminders, uid, entry))
        end
    end
end

-- "aura" triggers aren't anchored to a BigWigs broadcast either -- called directly
-- from OnCombatLog (NaowhUI_SmartReminders.lua) on the same SPELL_AURA_APPLIED/
-- SPELL_AURA_REMOVED lines Custom Reminders' own aura trigger (CheckAuraReminder)
-- already answers to, same signature and same reasoning: reading straight off the
-- combat log reaches an aura on ANY tracked unit, including in restricted content
-- where C_UnitAuras' RequiresNonSecretAura gate can go quiet on exactly the aura this
-- needs to see. destGUID/spellID are already issecretvalue-checked by OnCombatLog
-- before this is ever called, same as every other reader on that line.
function ns.CheckRaidReminderAuraTriggers(kind, destGUID, spellID)
    if not (ns.InEncounter and ns.InEncounter()) then return end
    if not RaidRemindersAllowed() then return end
    local enc = ns.CurrentEncounter and ns.CurrentEncounter()
    if not enc then return end
    local reminders = RaidRemindersTable(false, enc)
    if not reminders then return end

    local isPlayer = destGUID == ns.PlayerGUID()
    local isBoss = not isPlayer and ns.bossGUIDs[destGUID] == true
    if not (isPlayer or isBoss) then return end

    for _, entry in pairs(reminders) do
        local trig = entry.trigger
        if trig and trig.type == "aura" and trig.spellID == spellID
           and (trig.auraEvent or "applied") == kind
           and (trig.target == "player") == isPlayer then
            FireRaidReminder(entry)
        end
    end
end

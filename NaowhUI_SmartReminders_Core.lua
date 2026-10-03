-------------------------------------------------------------------------------
--  NaowhUI_SmartReminders_Core.lua -- theme, chrome primitives, DB and profile plumbing.
--
--  Standalone addon: no EllesmereUI dependency. The options window, widget kit and
--  profile system are all its own (Widgets and Window files).
-------------------------------------------------------------------------------
local ADDON_NAME = ...

-- Must match the addon folder; the DB and saved positions key off it.
-- Renamed with the addon (was NaowhUI_TankReminder).
local MODULE_KEY = "NaowhSmartReminders"

local ns = {}
_G.NaowhUITankReminder = ns
ns.MODULE_KEY = MODULE_KEY

local locale = _G.NaowhSmartRemindersLocale or {}
function ns.L(key, ...)
    local text = locale[key]
    if text == nil or text == true then text = key end
    if select("#", ...) > 0 then return text:format(...) end
    return text
end

-- Bumped by hand on every code change that goes to a tester, and printed beside the TOC
-- version everywhere a build is reported. The TOC version only moves on release, so it
-- cannot tell a working checkout from the release it was branched off -- which cost two
-- rounds of diagnosis on reports whose traces turned out to be from an unreloaded
-- client. This moves whenever the Lua does, so a header naming a stamp the reporter was
-- not sent means the files changed under a running client and the capture predates them.
ns.CODE_BUILD = "1.4.26"

-- Naowh's own scheme: dark grey with his blue (#0091ed) as the single accent.
ns.THEME = {
    bg     = { r = 0x0e / 255, g = 0x0f / 255, b = 0x11 / 255 },  -- window backdrop
    panel  = { r = 0x1a / 255, g = 0x1c / 255, b = 0x1f / 255 },  -- panels, modals, controls
    line   = { r = 0x2e / 255, g = 0x31 / 255, b = 0x36 / 255 },  -- borders, dividers, tracks
    fg     = { r = 0xf0 / 255, g = 0xf1 / 255, b = 0xf3 / 255 },  -- primary text
    muted  = { r = 0x9a / 255, g = 0x9e / 255, b = 0xa6 / 255 },  -- secondary text
    grey   = { r = 0x34 / 255, g = 0x37 / 255, b = 0x3d / 255 },  -- selected-row neutral fill
    accent     = { r = 0x00 / 255, g = 0x91 / 255, b = 0xed / 255 },
    accentSoft = { r = 0x4d / 255, g = 0xb5 / 255, b = 0xf5 / 255 },
}

-- A secret-tainted message is DROPPED by the display, silently and with nothing logged, so
-- a diagnostic built from live combat data can vanish line by line while looking for all the
-- world like code that never ran. Caught here once rather than at every call site.
--
-- tostring() is not a way out: on a secret it returns a SECRET STRING rather than raising,
-- and the taint rides through format and concatenation to the display. issecretvalue() is
-- the only thing that answers plainly, and it must be asked BEFORE the value is coerced.
function ns.Print(msg)
    if issecretvalue and issecretvalue(msg) then
        msg = "|cff0091ed(withheld: this line contained a secret value)|r"
    end
    print("|cff0091edNaowhUI|r " .. tostring(msg))
end

-------------------------------------------------------------------------------
--  House chrome
-------------------------------------------------------------------------------
-- Every panel this addon draws is built from these primitives, so the whole look is
-- decided here and in ns.THEME. The widget factory in the Widgets file builds its rows
-- from the same pieces.

-- The UI font: the Naowh face when NaowhUI_Media (or anything else) has registered it
-- with LibSharedMedia, the client default otherwise. Resolved once -- media addons load
-- before us via OptionalDeps, and nothing builds UI before login.
local uiFontPath
function ns.UIFontPath()
    if not uiFontPath then
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        uiFontPath = (LSM and LSM:Fetch("font", "Naowh", true)) or STANDARD_TEXT_FONT
    end
    return uiFontPath
end

function ns.Font(parent, size, flags, color)
    local c = color or ns.THEME.fg
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(ns.UIFontPath(), size, flags or "")
    fs:SetTextColor(c.r, c.g, c.b, 1)
    return fs
end

-- Four 1px edges on a child frame one level up, so the border draws over the panel's own
-- background but under its content. Returns { _frame, SetColor } -- _frame so a caller can
-- hide the whole border (the learn-tag does), SetColor for hover restyles.
function ns.Border(frame, color, alpha)
    local c = color or ns.THEME.line
    local a = alpha or 1
    local bf = CreateFrame("Frame", nil, frame)
    bf:SetAllPoints()
    bf:SetFrameLevel(math.min(frame:GetFrameLevel() + 1, 9999))
    local edges = {}
    for i = 1, 4 do
        local t = bf:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(c.r, c.g, c.b, a)
        edges[i] = t
    end
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)
    return {
        _frame = bf,
        SetColor = function(_, r, g, b, a2)
            for i = 1, 4 do edges[i]:SetColorTexture(r, g, b, a2 or 1) end
        end,
    }
end

function ns.Solid(parent, layer, color, alpha)
    local c = color or ns.THEME.panel
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(c.r, c.g, c.b, alpha or 1)
    return t
end

-- btn.label is exposed so a reused button can be re-labelled on each open.
function ns.Button(parent, text, w, h, onClick)
    local T = ns.THEME
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w, h)
    local bg = ns.Solid(btn, "BACKGROUND", T.panel, 0.9)
    bg:SetAllPoints()
    local border = ns.Border(btn)
    local lbl = ns.Font(btn, 12, nil)
    lbl:SetPoint("CENTER")
    lbl:SetText(ns.L(text))
    btn.label = lbl
    btn:SetScript("OnClick", function() if onClick then onClick() end end)
    btn:SetScript("OnEnter", function()
        bg:SetColorTexture(T.panel.r, T.panel.g, T.panel.b, 1)
        border:SetColor(T.accent.r, T.accent.g, T.accent.b, 1)
    end)
    btn:SetScript("OnLeave", function()
        bg:SetColorTexture(T.panel.r, T.panel.g, T.panel.b, 0.9)
        border:SetColor(T.line.r, T.line.g, T.line.b, 1)
    end)
    return btn
end

function ns.SetButtonText(btn, text)
    if not (btn and btn.label) then return end
    btn.label:SetText(ns.L(text))
end

-- The house tooltip lives in the Widgets file (ns.UI); resolved at hover time since that
-- file loads after this one.
-- "Protection" alone names two classes, and a list that mixes them -- a pack covering every
-- class, the raid reminder target picker -- reads as a puzzle. GetSpecializationInfoByID's
-- seventh return is the localized class name, which is what Blizzard's own ClubFinder pairs
-- it with. Falls back to the bare spec name, then to the id, so an unknown id still prints.
function ns.SpecName(specID)
    local id = tonumber(specID)
    if not id then return tostring(specID) end
    local ok, _, name, _, _, _, _, className = pcall(GetSpecializationInfoByID, id)
    if not (ok and name) then return "Spec " .. id end
    if className and className ~= "" then return name .. " " .. className end
    return name
end

function ns.Tooltip(frame, title, body)
    -- Composed at HOVER time, not attach time: the tooltip accepts a function and
    -- resolves it on show, and a body that is itself a function can answer from data that
    -- did not exist yet when the row was built -- spell text loads async.
    local function Compose()
        local b = body
        if type(b) == "function" then b = b() end
        if b and b ~= "" then
            return "|cff0091ed" .. title .. "|r\n" .. b
        end
        return title
    end
    -- Hooked, not set: ns.Button already owns OnEnter/OnLeave for its hover highlight, and
    -- SetScript here silently replaced it -- every button carrying a tooltip stopped
    -- lighting up on hover.
    frame:HookScript("OnEnter", function(self)
        local UI = ns.UI
        if UI and UI.ShowWidgetTooltip then
            UI.ShowWidgetTooltip(self, Compose, { anchor = "cursor", justify = "LEFT" })
        end
    end)
    frame:HookScript("OnLeave", function()
        local UI = ns.UI
        if UI and UI.HideWidgetTooltip then UI.HideWidgetTooltip() end
    end)
end

-- Modals stack: the reminder editor opens from inside the instance modal, and with both
-- on the same strata, creation order decided who was on top. Frame:Raise() looks like the
-- fix, but it reorders a frame against ALL of UIParent's direct children -- the whole
-- client's addon ecosystem, not just our own popups -- so the level it lands on is
-- unbounded and can already sit well above any fixed number by the time a session has
-- opened a few dialogs elsewhere. A private counter, incremented only by our own modals
-- and starting low, makes each newly opened modal outrank the last one at a level this
-- file controls. The 150 ceiling predates the move to MenuUtil menus (which Blizzard
-- hosts on its own strata, above any of this); it stays because bounded is the point.
local nextModalLevel = 10

-- One live modal per key. Callers build their contents fresh on every open, so without
-- an identity the same button pressed twice leaves two live copies stacked on screen --
-- reported on the pack importer, but true of every dialog here. Retiring the previous
-- copy under the same key is all that is needed: WoW frames cannot be destroyed, and
-- hiding an orphaned one is as close to releasing it as the API allows.
--
-- Nested dialogs keep DIFFERENT keys (the reminder editor opens from inside the instance
-- modal and both must stay up), so this never closes a parent to open its child.
local liveModals = {}

-- A dimmed modal shell: click-off to dismiss, house border and panel fill. Returns the
-- dimmer (show/hide this) and the panel to fill. `key` names the dialog; pass one unless
-- several copies are genuinely meant to coexist.
function ns.MakeModal(width, height, key)
    if key and liveModals[key] then
        liveModals[key]:Hide()
        liveModals[key] = nil
    end
    local dimmer = CreateFrame("Frame", nil, UIParent)
    dimmer:SetAllPoints(UIParent)
    dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
    -- A floating panel, not a screen-blocking modal: mouse stays off the full-screen
    -- anchor so the Dungeon Journal and everything else underneath is still clickable and
    -- undimmed while this is open. Only the panel itself (below) captures the mouse.
    dimmer:EnableMouse(false)
    local panel = CreateFrame("Frame", nil, dimmer)
    panel:SetSize(width, height)
    panel:SetPoint("CENTER")
    panel:SetScale(ns.UIScale())
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:EnableMouse(true)
    local bg = ns.Solid(panel, "BACKGROUND", ns.THEME.panel, 1)
    bg:SetAllPoints()
    ns.Border(panel)

    -- Draggable from any empty background area, the same way EllesmereUI's own windows
    -- move -- a click that lands on a button or edit box is intercepted by that child
    -- first, so this only ever engages on the parts of the panel nothing else claimed.
    -- Not saved: most of these popups are rebuilt fresh on every open (see their own
    -- comments), so there is nowhere sensible to persist a position across that, and it
    -- would look odd for a small popup to inherit wherever a much larger one was dragged.
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Escape closes the topmost open modal, same as any other WoW window. Not
    -- UISpecialFrames -- that needs a fixed global name per frame, and MakeModal hands out
    -- a fresh nameless one on every call, with several stacking at once (the reminder
    -- editor opens from inside the instance modal). Each dimmer's own OnKeyDown instead:
    -- ESCAPE hides this one and stops there (SetPropagateKeyboardInput(false)), so a
    -- second ESC press reaches whatever modal is stacked underneath rather than closing
    -- both at once. Any other key falls through untouched.
    -- SetPropagateKeyboardInput is protected, so a modal opened in combat is refused it and
    -- the addon is flagged for calling a protected function. The keyboard is not taken at
    -- all there rather than taken without propagation control, which would swallow every
    -- keybind for as long as the modal stayed open. The cost is that ESC will not close a
    -- modal opened mid-fight; its close button still does.
    dimmer:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown() then return end
        if key == "ESCAPE" then
            self:Hide()
            self:SetPropagateKeyboardInput(false)
            -- Restored once this key is consumed: a cached modal shown again in combat
            -- cannot change it, and would swallow every keybind while open.
            C_Timer.After(0, function()
                if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
            end)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    dimmer:SetScript("OnShow", function(self)
        if not InCombatLockdown() then
            self:EnableKeyboard(true)
            self:SetPropagateKeyboardInput(true)
        end
        -- The counter only ever climbed, so the panel level (this + 5) crossed 200 on the
        -- nineteenth modal opened in a session -- and 200 is the hardcoded dropdown level
        -- the comment above is about. Past that, dropdowns render BEHIND the panel that
        -- opened them, which is the exact failure the counter exists to prevent. Stacking
        -- only needs to order the modals currently on screen, and nesting never gets deep,
        -- so winding back to the base is safe: anything still open sits below, and the one
        -- being shown goes above it.
        if nextModalLevel > 150 then nextModalLevel = 10 end
        nextModalLevel = nextModalLevel + 10
        self:SetFrameLevel(nextModalLevel)
        panel:SetFrameLevel(nextModalLevel + 5)
    end)
    dimmer:Hide()

    if key then liveModals[key] = dimmer end
    return dimmer, panel
end

-------------------------------------------------------------------------------
--  SavedVariables and profiles
-------------------------------------------------------------------------------
-- The addon's own DB. Profiles are account-wide with a per-character active pointer;
-- SettingsRoot hands back the active profile's root, and TRDB layers its defaults onto
-- root.tankReminder from there. A switch hands TRDB a different table identity, which is
-- what re-runs its weak-keyed defaults fill.
local activeRoot

local function CharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

local function DB()
    local sv = _G.NaowhUI_SmartRemindersDB
    if type(sv) ~= "table" then
        sv = { dbVersion = 1 }
        _G.NaowhUI_SmartRemindersDB = sv
    end
    if type(sv.profiles) ~= "table" then sv.profiles = {} end
    if type(sv.charActive) ~= "table" then sv.charActive = {} end
    return sv
end

function ns.SettingsRoot()
    if activeRoot then return activeRoot end
    local sv = DB()
    local name = sv.charActive[CharKey()]
    if type(name) ~= "string" or type(sv.profiles[name]) ~= "table" then
        -- A character with no assignment, or one pointing at a deleted profile, takes the
        -- account default. That is "Default" until a new profile is made, which claims it --
        -- so a character logged into for the first time afterwards joins the rest rather
        -- than landing on an empty profile nobody chose.
        name = type(name) == "string" and name or sv.defaultProfile or "Default"
        if type(sv.profiles[name]) ~= "table" and type(sv.defaultProfile) == "string" then
            name = sv.defaultProfile
        end
        sv.charActive[CharKey()] = name
    end
    if type(sv.profiles[name]) ~= "table" then sv.profiles[name] = {} end
    activeRoot = sv.profiles[name]
    return activeRoot
end

-- Account-wide, deliberately outside the profile tables: the options window's scale
-- follows the monitor it is being read on, so it must not travel in an exported pack or
-- change under someone when they switch profile.
function ns.AccountSettings()
    local sv = DB()
    if type(sv.account) ~= "table" then sv.account = {} end
    return sv.account
end

-- A personal opt-out, not part of any shared profile or reminder pack.
function ns.HealerRemindersEnabled()
    return ns.AccountSettings().healerRemindersEnabled ~= false
end

function ns.IsReminderEnabled(reminder, preview)
    return reminder ~= nil and (preview or reminder.enabled ~= false)
        and (reminder.healerReminder ~= true or ns.HealerRemindersEnabled())
end

function ns.SetHealerRemindersEnabled(enabled)
    ns.AccountSettings().healerRemindersEnabled = enabled and true or false
    if ns.ApplyReminderFilter then ns.ApplyReminderFilter() end
end

-- Stored as a percent, used as a multiplier. Clamped on read as well as on write: a zero
-- or negative scale hides the window with no way left to open the control that fixes it.
function ns.UIScale()
    local pct = tonumber(ns.AccountSettings().windowScale) or 100
    if pct < 50 then pct = 50 elseif pct > 150 then pct = 150 end
    return pct / 100
end

function ns.ActiveProfileName()
    ns.SettingsRoot()
    return DB().charActive[CharKey()]
end

-- Every character this account has logged in with the addon loaded, and which profile each
-- is on right now. For a preview shown before a change is made -- "this account profile move
-- will affect these characters" -- there is nothing more current to read: a character never
-- logged into on this account is not in charActive yet and cannot be named in advance.
function ns.KnownCharacters()
    local sv = DB()
    local out = {}
    for char, profile in pairs(sv.charActive) do
        out[#out + 1] = { char = char, profile = profile }
    end
    table.sort(out, function(a, b) return a.char:lower() < b.char:lower() end)
    return out
end

function ns.ListProfiles()
    local out = {}
    for name in pairs(DB().profiles) do out[#out + 1] = name end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

-- The stored settings of any profile, loaded or not, for the exporter. Read-only by
-- intent: the caller copies out of it. Returns nil for a profile that has never been
-- written to, which is a profile carrying nothing rather than an error.
-- Which profile belongs to which spec, account-wide rather than inside a profile: it has to
-- survive switching away from whichever profile is loaded, and it describes the whole set.
-- Written by a whole-file import that was told to, and by a manual switch, so the map learns
-- what the player actually chooses rather than fighting them.
function ns.SpecProfileMap()
    local sv = DB()
    if type(sv.specProfile) ~= "table" then sv.specProfile = {} end
    return sv.specProfile
end

function ns.SetSpecProfile(specID, name)
    if not specID or specID == 0 then return end
    ns.SpecProfileMap()[tostring(specID)] = name
end

-- Off unless asked for. Switching someone's profile out from under them on a spec change is
-- the kind of helpfulness that reads as a bug, so it stays a choice.
function ns.AutoSpecProfile(set)
    local sv = DB()
    if set ~= nil then sv.autoSpecProfile = set and true or nil end
    return sv.autoSpecProfile == true
end

-- Called on login and on a spec change. Returns true when it actually switched, so a caller
-- can tell whether the settings underneath it have moved.
function ns.ApplySpecProfile(specID)
    if not ns.AutoSpecProfile() then return false end
    if not specID or specID == 0 then return false end
    local sv = DB()
    local want = ns.SpecProfileMap()[tostring(specID)]
    -- A map entry pointing at a profile that has since been deleted is ignored rather than
    -- recreating it: the player deleted it on purpose.
    if not want or type(sv.profiles[want]) ~= "table" then return false end
    if sv.charActive[CharKey()] == want then return false end
    return (ns.SwitchProfile(want)) and true or false
end

function ns.ProfileSettings(name)
    local p = DB().profiles[name]
    return type(p) == "table" and type(p.tankReminder) == "table" and p.tankReminder or nil
end

-- Creates the profile if it is new. Used by a whole-file import, which has to land several
-- profiles at once without switching to each in turn.
function ns.EnsureProfile(name)
    local sv = DB()
    if type(sv.profiles[name]) ~= "table" then sv.profiles[name] = {} end
    if type(sv.profiles[name].tankReminder) ~= "table" then
        sv.profiles[name].tankReminder = {}
    end
    return sv.profiles[name].tankReminder
end

function ns.SwitchProfile(name)
    local sv = DB()
    if type(sv.profiles[name]) ~= "table" then return false, "no such profile" end
    sv.charActive[CharKey()] = name
    activeRoot = nil
    -- The map learns from a deliberate switch, so choosing a profile while auto-switching is
    -- on means "this one, for this spec" rather than a choice that is undone at the next
    -- spec change. Recorded even with auto off, so turning it on later already knows.
    local spec = ns.CurrentSpec and ns.CurrentSpec()
    if spec and spec > 0 then ns.SetSpecProfile(spec, name) end
    ns.QueueReapply()
    return true
end

-- allowExisting is for the callers that have already asked the player to confirm replacing a
-- profile of this name. Without it a taken name is refused, which is the right default: an
-- overwrite loses whatever was stored under it, on every character standing in it.
local function ValidName(name, allowExisting)
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
    if name == "" then return nil, "the name is empty" end
    if not allowExisting and DB().profiles[name] then return nil, "that name is taken" end
    return name
end

-- Whether a name is already spoken for, so the UI can offer the overwrite rather than
-- discovering it from a failed save.
function ns.ProfileExists(name)
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
    return name ~= "" and type(DB().profiles[name]) == "table"
end

-- A new profile becomes the account's: every character switches to it, and any logged into
-- later starts there too. Asked for outright -- making a profile on one character and then
-- finding the other nine still on the old one is the kind of thing that has cost real
-- confusion tonight, twice, with an export taken from the wrong profile each time.
--
-- Per-character choices are still possible: switching a character afterwards moves only that
-- one, and only until the next profile is created.
-- Point the whole account at one profile: every character now, and any logged into later.
-- What an installer wants after landing a curator's pack, and what CreateProfile does for a
-- profile it just made.
function ns.SetAccountProfile(name)
    local sv = DB()
    if type(sv.profiles[name]) ~= "table" then return false, "no such profile" end
    sv.defaultProfile = name
    for char in pairs(sv.charActive) do sv.charActive[char] = name end
    sv.charActive[CharKey()] = name
    -- Auto spec switching runs on every login and spec change, and a map still pointing at
    -- the profile this one replaces puts the character straight back on it before anyone
    -- sees the change -- reported after an account-wide import, where only the importing
    -- character's own spec had been remapped and every alt landed back on the old profile.
    -- "One profile for the account" and "a profile per spec" are answers to the same
    -- question, so the second is switched off rather than overwritten: the map itself is
    -- left exactly as it was, and turning switching back on restores it whole. Reported so
    -- the caller can say it happened rather than leaving it to be discovered.
    local turnedOff = sv.autoSpecProfile == true
    sv.autoSpecProfile = nil
    activeRoot = nil
    ns.QueueReapply()
    return true, turnedOff
end

function ns.CreateProfile(name, overwrite)
    local err
    name, err = ValidName(name, overwrite)
    if not name then return false, err end
    local sv = DB()
    sv.profiles[name] = {}
    sv.defaultProfile = name
    for char in pairs(sv.charActive) do sv.charActive[char] = name end
    activeRoot = nil
    ns.QueueReapply()
    return true
end

local function DeepCopy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = type(v) == "table" and DeepCopy(v) or v
    end
    return out
end

function ns.CopyProfile(src, name, overwrite)
    local sv = DB()
    if type(sv.profiles[src]) ~= "table" then return false, "no such profile" end
    local err
    name, err = ValidName(name, overwrite)
    if not name then return false, err end
    sv.profiles[name] = DeepCopy(sv.profiles[src])
    -- Overwriting the profile in use replaces the very table the cached root points at, so
    -- the cache is dropped rather than left describing what was there a moment ago.
    if name == sv.charActive[CharKey()] then
        activeRoot = nil
        ns.QueueReapply()
    end
    return true
end

-- Reset any profile, not only the one in use. The live half -- hiding the alert, dropping
-- the slot cache, re-registering events -- only applies when the profile being reset is the
-- one this character is standing in; for any other, clearing its stored settings is the
-- whole job and it rebuilds from defaults the next time it is loaded.
function ns.ResetProfileNamed(name)
    local sv = DB()
    if type(sv.profiles[name]) ~= "table" then return false, "no such profile" end
    if name == sv.charActive[CharKey()] then
        if ns.Reset then ns.Reset() end
        return true
    end
    sv.profiles[name].tankReminder = nil
    return true
end

function ns.DeleteProfile(name)
    local sv = DB()
    if type(sv.profiles[name]) ~= "table" then return false, "no such profile" end
    local count = 0
    for _ in pairs(sv.profiles) do count = count + 1 end
    if count <= 1 then return false, "the last profile cannot be deleted" end
    local wasMine = sv.charActive[CharKey()] == name
    sv.profiles[name] = nil
    -- Every character pointed at it falls back to the account default, or to any surviving
    -- profile if that was the one deleted -- "Default" may not exist at all once profiles
    -- have been renamed around. A replacement becomes the default too, or a character logged
    -- into later would start on a new, empty Default.
    local fallback = sv.defaultProfile or "Default"
    if type(sv.profiles[fallback]) ~= "table" then
        fallback = next(sv.profiles)
        sv.defaultProfile = fallback
    end
    for char, active in pairs(sv.charActive) do
        if active == name then sv.charActive[char] = fallback end
    end
    if wasMine then
        activeRoot = nil
        ns.QueueReapply()
    end
    return true
end

-------------------------------------------------------------------------------
--  Re-apply on anything that swaps the active settings out from under us
-------------------------------------------------------------------------------
-- Coalesced: one user action can request several reapplies in one go, and re-running the
-- rebuild per request would rebuild the slot list three times for one click.
local reapplyPending

function ns.QueueReapply()
    -- Invalidate old-profile work immediately, even if two switches share a frame.
    if ns.PruneCustomReminderTimers then ns.PruneCustomReminderTimers() end
    if ns.PrunePendingBWFires then ns.PrunePendingBWFires() end
    if reapplyPending then return end
    reapplyPending = true
    C_Timer.After(0, function()
        reapplyPending = false
        if ns.Apply then ns.Apply() end
        -- Profile changes do not reopen the options window, so its OnShow preview
        -- callback will not run. Restore it after Apply has rebuilt/hidden the slots.
        if ns.RefreshDefensivePreview then ns.RefreshDefensivePreview() end
    end)
end

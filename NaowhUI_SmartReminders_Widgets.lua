-------------------------------------------------------------------------------
--  NaowhUI_SmartReminders_Widgets.lua -- the widget kit behind every options row.
--
--  ns.UI carries the member names the page builders already call (Widgets, RefreshPage,
--  BuildDropdownControl, ShowWidgetTooltip, ...), so the pages themselves did not have to
--  be rewritten when the addon went standalone -- they took `local EUI = ns.UI` and kept
--  their bodies. The window lifecycle members (RefreshPage, RegisterOnShow/OnHide,
--  ClearContentHeader) are filled in by the Window file, which loads after this one.
-------------------------------------------------------------------------------
local ns = _G.NaowhUITankReminder
local T = ns.THEME

local UI = {}
ns.UI = UI

UI.CONTENT_PAD = 45
UI.COGS_ICON = "Interface\\AddOns\\NaowhSmartReminders\\Media\\cog.tga"

function UI.L(text) return ns.L(text) end

-------------------------------------------------------------------------------
--  Tooltip
-------------------------------------------------------------------------------
local tooltipFrame

local function GetTooltipFrame()
    if tooltipFrame then return tooltipFrame end
    tooltipFrame = CreateFrame("Frame", nil, UIParent)
    tooltipFrame:SetFrameStrata("TOOLTIP")
    tooltipFrame:SetClampedToScreen(true)
    tooltipFrame:SetSize(250, 40)
    local bg = ns.Solid(tooltipFrame, "BACKGROUND", T.panel, 0.98)
    bg:SetAllPoints()
    ns.Border(tooltipFrame)
    tooltipFrame.text = ns.Font(tooltipFrame, 10, nil)
    tooltipFrame.text:SetPoint("TOPLEFT", 8, -8)
    tooltipFrame.text:SetPoint("TOPRIGHT", -8, -8)
    tooltipFrame.text:SetWordWrap(true)
    tooltipFrame.text:SetSpacing(3)
    tooltipFrame:Hide()
    return tooltipFrame
end

-- opts (optional): { anchor = "cursor"|"below"|"left"|"right", justify, width, force }
function UI.ShowWidgetTooltip(label, text, opts)
    -- Suppress in M+/raid/PvP combat: frame APIs return secret values in tainted
    -- execution; opts.force bypasses.
    if not (opts and opts.force) then
        local _, iType = IsInInstance()
        if iType == "party" and C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
           and C_ChallengeMode.IsChallengeModeActive() then return end
        if (iType == "raid" or iType == "pvp" or iType == "arena") and InCombatLockdown() then return end
    end
    -- text may be a function for dynamic content; resolved after the suppression checks
    -- so it is never called when nothing will show.
    if type(text) == "function" then text = text() end
    if not text or text == "" then return end
    local tt = GetTooltipFrame()
    local MAX_W = 250
    tt:SetWidth((opts and opts.width) or MAX_W)
    tt.text:SetJustifyH((opts and opts.justify) or "CENTER")
    tt.text:SetText(text)
    tt:ClearAllPoints()
    if opts and opts.anchor == "cursor" then
        local scale = tt:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        tt:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", cx / scale, cy / scale + 4)
    elseif opts and opts.anchor == "below" then
        tt:SetPoint("TOP", label, "BOTTOM", 0, -4)
    elseif opts and opts.anchor == "left" then
        tt:SetPoint("RIGHT", label, "LEFT", -4, 0)
    elseif opts and opts.anchor == "right" then
        tt:SetPoint("LEFT", label, "RIGHT", 4, 0)
    else
        tt:SetPoint("BOTTOM", label, "TOP", 0, 4)
    end
    -- Shown BEFORE measuring: font geometry is wrong on hidden frames. Width shrinks to
    -- the natural single line when it fits; string metrics can be secret in restricted
    -- content, in which case the caps stand.
    tt:Show()
    if not (opts and opts.width) then
        local sw = tt.text:GetStringWidth()
        if not (issecretvalue and issecretvalue(sw)) then
            tt:SetWidth(math.min(sw + 16, MAX_W))
        end
    end
    tt:SetHeight(10)
    local textH = tt.text:GetStringHeight()
    if issecretvalue and issecretvalue(textH) then
        tt:SetHeight(26)
    else
        tt:SetHeight(textH + 16)
    end
end

function UI.HideWidgetTooltip()
    if tooltipFrame then tooltipFrame:Hide() end
end

-------------------------------------------------------------------------------
--  Bare controls
-------------------------------------------------------------------------------
-- A pill switch: round knob in a rounded track. WoW has no rounded-rectangle primitive, so
-- the pill and the knob are drawn art, tinted with SetVertexColor, not flat colour
-- rectangles cut to shape with a mask. Masking was the original approach and could not
-- work at this size: a mask gets roughly one pixel of gradient at 20px, so the ends came
-- out stepped no matter which mask texture fed it. These carry their own antialiased edge,
-- rendered 4x-supersampled and inset far enough that the ramp fits inside the texture.
--
-- toggle_track.tga is drawn 128x64, the same 2:1 ratio as W:H below, so it scales without
-- distorting the round ends. Changing W/H away from 2:1 means redrawing it.
local TRACK_TEX = "Interface\\AddOns\\NaowhSmartReminders\\Media\\toggle_track.tga"
local KNOB_TEX = "Interface\\AddOns\\NaowhSmartReminders\\Media\\toggle_knob.tga"

-- w/h/knobSize are optional overrides for a spot needing a smaller switch (a dense grid
-- row, say) -- omitted, they reproduce the original fixed 40x20/14 size exactly. Knob size
-- and the edge inset scale off the given height at the same ratio the original fixed
-- numbers held (70% and 15%), so a smaller switch keeps the same proportions rather than
-- an oversized knob crowding a shrunk track.
function UI.BuildToggleControl(parent, frameLevel, get, set, w, h, knobSize)
    local W, H = w or 40, h or 20
    local KNOB = knobSize or math.floor(H * 0.7 + 0.5)
    local INSET = math.max(2, math.floor(H * 0.15 + 0.5))
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(W, H)
    if frameLevel then t:SetFrameLevel(frameLevel) end

    -- Textures snap to the pixel grid by default, which forces these curved edges onto
    -- whole pixels and throws away the antialiasing the art carries -- the actual reason
    -- the switch read as jagged, not the mask or the art it went through before. Blizzard's
    -- own NineSlice does the same two calls on every piece for the same reason.
    local function Smooth(tex)
        tex:SetTexelSnappingBias(0)
        tex:SetSnapToPixelGrid(false)
    end

    local track = t:CreateTexture(nil, "BACKGROUND")
    track:SetTexture(TRACK_TEX)
    track:SetAllPoints()
    Smooth(track)

    local knob = t:CreateTexture(nil, "ARTWORK")
    knob:SetTexture(KNOB_TEX)
    knob:SetSize(KNOB, KNOB)
    Smooth(knob)

    local on = false
    local function PaintTrack(c, a)
        track:SetVertexColor(c.r, c.g, c.b, a)
    end

    local function Paint(state)
        on = state and true or false
        knob:ClearAllPoints()
        if on then
            PaintTrack(T.accent, 1)
            knob:SetVertexColor(1, 1, 1, 1)
            knob:SetPoint("RIGHT", t, "RIGHT", -INSET, 0)
        else
            PaintTrack(T.line, 1)
            knob:SetVertexColor(T.muted.r, T.muted.g, T.muted.b, 1)
            knob:SetPoint("LEFT", t, "LEFT", INSET, 0)
        end
    end

    -- Off has no border to light up the way ns.Button's hover does, so the track itself
    -- carries it: the lighter accent when on, the neutral row fill when off.
    t:SetScript("OnEnter", function()
        PaintTrack(on and T.accentSoft or T.grey, 1)
    end)
    t:SetScript("OnLeave", function()
        PaintTrack(on and T.accent or T.line, 1)
    end)

    local function Snap() Paint(get() and true or false) end
    t:SetScript("OnClick", function()
        set(not (get() and true or false))
        Snap()
    end)
    Snap()
    t._refreshValue = Snap
    return t, Paint, Snap
end

function UI.BuildDropdownControl(parent, ddW, fLevel, values, order, get, set)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(ddW or 160, 24)
    if fLevel then btn:SetFrameLevel(fLevel) end
    local bg = ns.Solid(btn, "BACKGROUND", T.panel, 1)
    bg:SetAllPoints()
    local border = ns.Border(btn)
    local lbl = ns.Font(btn, 12, nil)
    lbl:SetPoint("LEFT", 8, 0)
    lbl:SetPoint("RIGHT", -18, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    local arrow = ns.Font(btn, 10, nil, T.muted)
    arrow:SetPoint("RIGHT", -7, 0)
    arrow:SetText("v")
    local function Keys()
        if order then return order end
        local out = {}
        for k in pairs(values) do out[#out + 1] = k end
        table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
        return out
    end
    btn._refreshLabel = function()
        local v = get()
        lbl:SetText(values[v] or tostring(v or ""))
    end
    -- An anchored dropdown, not a context menu, and it closes itself.
    --
    -- Three separate things had to line up here, and each one alone looked like the whole
    -- bug, which is why this took three passes:
    --
    --   * MenuManagerMixin:OpenContextMenu positions with InputUtil.AnchorRegionToCursor,
    --     so the list opened wherever the pointer happened to be and appeared to follow it
    --     around. OpenMenu with an anchor is the dropdown case.
    --   * The manager closes menus on GLOBAL_MOUSE_DOWN, and that lands AFTER this script,
    --     so toggling on OnClick always found the menu already gone and opened a fresh one.
    --   * It skips that close only when the moused-over frame answers
    --     HandlesGlobalMouseEvent (Menu.lua). That is how Blizzard's own DropdownButton
    --     keeps the press for itself; without it the manager and this handler fight over
    --     the same click and the menu either reopens or sticks.
    btn.HandlesGlobalMouseEvent = function(_, buttonName, event)
        return event == "GLOBAL_MOUSE_DOWN" and buttonName == "LeftButton"
    end

    local function MenuOpen()
        return btn._menu and btn._menu.IsShown and btn._menu:IsShown()
    end

    btn:SetScript("OnMouseDown", function()
        if MenuOpen() then
            btn._menu:Close()
            btn._menu = nil
            return
        end
        if not (MenuUtil and MenuUtil.CreateRootMenuDescription and MenuVariants
            and Menu and Menu.GetManager and AnchorUtil) then return end
        local desc = MenuUtil.CreateRootMenuDescription(MenuVariants.GetDefaultMenuMixin())
        if not desc then return end
        -- Scrolling is opt-in on Blizzard's own menu (BaseMenuDescriptionMixin:IsScrollable
        -- reads false until something calls this): unset, the menu just grows to fit every
        -- entry with nothing to scroll it, which for a long list -- every LibSharedMedia
        -- sound, every spec across an account -- ran off the bottom of the screen with no
        -- way to reach the rest. Below this height it is a no-op (useScroll only engages
        -- once content actually exceeds it), so a five-entry dropdown looks exactly as it
        -- did; every dropdown in the addon goes through this one control, so fixed once here
        -- rather than per call site.
        if desc.SetScrollMode then desc:SetScrollMode(420) end
        for _, k in ipairs(Keys()) do
            local key = k
            desc:CreateRadio(values[key] or tostring(key),
                function() return get() == key end,
                function()
                    set(key)
                    btn._refreshLabel()
                end)
        end
        btn._menu = Menu.GetManager():OpenMenu(btn, desc,
            AnchorUtil.CreateAnchor("TOPLEFT", btn, "BOTTOMLEFT", 0, -2))
    end)
    btn:SetScript("OnEnter", function()
        border:SetColor(T.accent.r, T.accent.g, T.accent.b, 1)
    end)
    btn:SetScript("OnLeave", function()
        border:SetColor(T.line.r, T.line.g, T.line.b, 1)
    end)
    btn._refreshLabel()
    btn._refreshValue = btn._refreshLabel
    btn:SetScript("OnHide", function()
        if btn._menu then btn._menu:Close(); btn._menu = nil end
    end)
    return btn, lbl
end

function UI.BuildSliderCore(parent, trackW, trackH, thumbSz, inputW, inputH, inputFontSz,
                            inputAlpha, minV, maxV, step, get, set)
    step = step or 1
    local function Clamp(v)
        v = tonumber(v)
        if not v then return nil end
        v = math.floor((v - minV) / step + 0.5) * step + minV
        if v < minV then v = minV elseif v > maxV then v = maxV end
        return v
    end

    local track = CreateFrame("Frame", nil, parent)
    track:SetSize(trackW, math.max(trackH, thumbSz))
    track:EnableMouse(true)
    local rail = ns.Solid(track, "BACKGROUND", T.line, 1)
    rail:SetPoint("LEFT", 0, 0)
    rail:SetPoint("RIGHT", 0, 0)
    rail:SetHeight(trackH)
    local fill = ns.Solid(track, "BORDER", T.accent, 1)
    fill:SetPoint("LEFT", 0, 0)
    fill:SetHeight(trackH)
    local thumb = ns.Solid(track, "ARTWORK", T.fg, 1)
    thumb:SetSize(thumbSz, thumbSz)

    local valBox = CreateFrame("EditBox", nil, parent)
    valBox:SetSize(inputW, inputH)
    valBox:SetAutoFocus(false)
    valBox:SetFontObject("GameFontHighlight")
    valBox:SetTextInsets(4, 4, 0, 0)
    valBox:SetJustifyH("CENTER")
    valBox:SetAlpha(inputAlpha or 1)
    local boxBg = ns.Solid(valBox, "BACKGROUND", T.bg, 1)
    boxBg:SetAllPoints()
    ns.Border(valBox)

    local function Paint()
        local v = Clamp(get()) or minV
        local frac = (maxV > minV) and (v - minV) / (maxV - minV) or 0
        fill:SetWidth(math.max(0.001, frac * trackW))
        thumb:ClearAllPoints()
        thumb:SetPoint("CENTER", track, "LEFT", frac * trackW, 0)
        valBox:SetText(tostring(v))
        valBox:SetCursorPosition(0)
    end

    local function FromCursor()
        local scale = track:GetEffectiveScale()
        local cx = GetCursorPosition() / scale
        local left = track:GetLeft()
        if not left then return end
        local frac = (cx - left) / trackW
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        local v = Clamp(minV + frac * (maxV - minV))
        if v ~= nil and v ~= get() then
            set(v)
        end
        Paint()
    end

    -- The drag ends when the BUTTON comes up, wherever the cursor happens to be. Relying
    -- on OnMouseUp alone strands the drag when the release lands outside the track, which
    -- for a 120px slider is most of the time -- the value would keep following the mouse
    -- around the screen until the next click.
    local function OnDragUpdate()
        if not IsMouseButtonDown("LeftButton") then
            track:SetScript("OnUpdate", nil)
            Paint()
            return
        end
        FromCursor()
    end
    track:SetScript("OnMouseDown", function()
        FromCursor()
        track:SetScript("OnUpdate", OnDragUpdate)
    end)
    track:SetScript("OnMouseUp", function()
        track:SetScript("OnUpdate", nil)
        Paint()
    end)
    track:SetScript("OnHide", function()
        track:SetScript("OnUpdate", nil)
    end)

    local function Commit()
        if UI.rebindingRows then return end
        local v = Clamp(valBox:GetText())
        if v ~= nil then set(v) end
        Paint()
        valBox:ClearFocus()
    end
    valBox:SetScript("OnEnterPressed", Commit)
    valBox:SetScript("OnEditFocusLost", function() Commit() end)
    valBox:SetScript("OnEscapePressed", function()
        Paint()
        valBox:ClearFocus()
    end)

    Paint()
    track._refreshValue = Paint
    return track, valBox, Paint
end

-------------------------------------------------------------------------------
--  Row factory (the W: dialect every options page is written in)
-------------------------------------------------------------------------------
local W = {}
UI.Widgets = W

local ROW_H, HEADER_H = 50, 40

-- Only enabled for pages whose rows have stable identities. Config objects stay
-- attached to their controls; rebuilding updates their callbacks and dropdown data.
function UI.BeginReusableRows(parent)
    parent._rowCache = parent._rowCache or {}
    parent._rowUses = {}
    UI.rebindingRows = true
    for _, rows in pairs(parent._rowCache) do
        for _, row in ipairs(rows) do row:Hide() end
    end
    UI.rebindingRows = nil
end

local function CachedRow(parent, key)
    if not parent._rowCache then return nil end
    local index = (parent._rowUses[key] or 0) + 1
    parent._rowUses[key] = index
    local rows = parent._rowCache[key]
    if not rows then rows = {}; parent._rowCache[key] = rows end
    local row = rows[index]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        rows[index] = row
    end
    row:ClearAllPoints()
    row:Show()
    return row
end

local function UpdateConfig(dst, src)
    if dst == src then return end
    -- Dropdowns retain these table identities in their menu callbacks.
    local values, order = dst.values, dst.order
    for k in pairs(dst) do dst[k] = nil end
    for k, v in pairs(src) do dst[k] = v end
    for _, key in ipairs({ "values", "order" }) do
        local prior = key == "values" and values or order
        if type(prior) == "table" and type(src[key]) == "table" then
            if prior ~= src[key] then
                for k in pairs(prior) do prior[k] = nil end
                for k, v in pairs(src[key]) do prior[k] = v end
            end
            dst[key] = prior
        end
    end
end

local function BuildRegionControl(rgn, cfg)
    local function Get() return cfg.getValue() end
    local function Set(...) return cfg.setValue(...) end
    if cfg.type == "toggle" then
        local disabled = type(cfg.disabled) == "function" and cfg.disabled()
        local toggle = UI.BuildToggleControl(rgn, rgn:GetFrameLevel() + 2,
            Get, Set)
        toggle:SetPoint("RIGHT", rgn, "RIGHT", -20, 0)
        if disabled then
            toggle:SetAlpha(0.3)
            toggle:EnableMouse(false)
        end
        return toggle, disabled
    elseif cfg.type == "dropdown" then
        local dd = UI.BuildDropdownControl(rgn, cfg.width or 160, rgn:GetFrameLevel() + 2,
            cfg.values, cfg.order, Get, Set)
        dd:SetPoint("RIGHT", rgn, "RIGHT", -20, 0)
        return dd
    elseif cfg.type == "slider" then
        local track, valBox = UI.BuildSliderCore(rgn, 120, 4, 12, 40, 22, 12, 1,
            cfg.min or 0, cfg.max or 100, cfg.step or 1, Get, Set)
        valBox:SetPoint("RIGHT", rgn, "RIGHT", -20, 0)
        track:SetPoint("RIGHT", valBox, "LEFT", -8, 0)
        return track
    elseif cfg.type == "colorpicker" then
        -- Never actually wired up: two callers already pass this exact shape (Text Color
        -- in both the custom and Ability Reminder editors), getValue returning r,g,b,a and
        -- setValue taking the same, matching W:ColorPicker's own signature -- but nothing
        -- in this switch ever matched "colorpicker", so BuildRegionControl fell through and
        -- returned nil: no control, just the bare "Text Color" label with nothing under it
        -- to click.
        local swatch = UI.BuildColorSwatchControl(rgn, Get, Set, cfg.hasAlpha)
        swatch:SetPoint("RIGHT", rgn, "RIGHT", -20, 0)
        return swatch
    end
end

local function BuildRegion(row, cfg, left, width)
    local rgn = CreateFrame("Frame", nil, row)
    rgn:SetPoint("TOPLEFT", row, "TOPLEFT", left, 0)
    rgn:SetSize(width, ROW_H)

    local control, disabled = BuildRegionControl(rgn, cfg)
    rgn._control = control

    local lbl = ns.Font(rgn, 14, nil)
    lbl:SetPoint("LEFT", rgn, "LEFT", 20, 0)
    if control then
        lbl:SetPoint("RIGHT", control, "LEFT", -8, 0)
    else
        lbl:SetPoint("RIGHT", rgn, "RIGHT", -20, 0)
    end
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    lbl:SetText(cfg.text or "")
    if disabled then lbl:SetAlpha(0.3) end

    rgn._cfg = cfg
    rgn._refresh = function(newCfg)
        UpdateConfig(cfg, newCfg)
        local off = type(cfg.disabled) == "function" and cfg.disabled()
        lbl:SetText(cfg.text or "")
        lbl:SetAlpha(off and 0.3 or 1)
        if control then
            if cfg.type == "toggle" then
                control:SetAlpha(off and 0.3 or 1)
                control:EnableMouse(not off)
            end
            if control._refreshValue then control._refreshValue() end
        end
    end

    local tip = disabled and cfg.disabledTooltip or cfg.tooltip
    if tip then
        local hit = CreateFrame("Button", nil, rgn)
        hit:SetPoint("TOPLEFT", lbl, "TOPLEFT", -4, 4)
        hit:SetPoint("BOTTOMRIGHT", lbl, "BOTTOMRIGHT", 4, -4)
        hit:SetScript("OnEnter", function(self)
            local off = type(cfg.disabled) == "function" and cfg.disabled()
            UI.ShowWidgetTooltip(self, off and cfg.disabledTooltip or cfg.tooltip,
                { anchor = "cursor", justify = "LEFT" })
        end)
        hit:SetScript("OnLeave", function() UI.HideWidgetTooltip() end)
    end
    return rgn
end

function W:DualRow(parent, yOffset, leftCfg, rightCfg)
    local key = "row:" .. leftCfg.type .. ":" .. (leftCfg.text or "") .. ":"
        .. (rightCfg and (rightCfg.type .. ":" .. (rightCfg.text or "")) or "")
    local row = CachedRow(parent, key) or CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.CONTENT_PAD, yOffset)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -UI.CONTENT_PAD, yOffset)

    -- Alternating band; the counter lives on the parent and SectionHeader resets it, so
    -- every section starts on a lit row.
    local count = (parent._nsuiRowCount or 0) + 1
    parent._nsuiRowCount = count
    if row._leftRegion then
        row._leftRegion._refresh(leftCfg)
        if rightCfg then row._rightRegion._refresh(rightCfg) end
        if row._band then row._band:SetShown(count % 2 == 1) end
        return row, ROW_H
    end
    if count % 2 == 1 or parent._rowCache then
        local band = ns.Solid(row, "BACKGROUND", T.panel, 0.35)
        band:SetAllPoints()
        band:SetShown(count % 2 == 1)
        row._band = band
    end

    local w = row:GetWidth()
    if w <= 0 then
        -- Anchored-both-sides width is not resolved until layout runs; derive it. The
        -- final fallback is the options window's content width.
        w = (parent:GetWidth() or 0) - UI.CONTENT_PAD * 2
        if w <= 0 then w = 910 end
    end
    if rightCfg then
        local half = w / 2
        row._leftRegion = BuildRegion(row, leftCfg, 0, half)
        row._rightRegion = BuildRegion(row, rightCfg, half, half)
        local divider = ns.Solid(row, "ARTWORK", T.line, 0.6)
        divider:SetPoint("TOP", row, "TOP", 0, -8)
        divider:SetPoint("BOTTOM", row, "BOTTOM", 0, 8)
        divider:SetWidth(1)
    else
        row._leftRegion = BuildRegion(row, leftCfg, 0, w)
    end
    return row, ROW_H
end

function W:SectionHeader(parent, text, yOffset)
    parent._nsuiRowCount = 0
    local f = CachedRow(parent, "header:" .. text) or CreateFrame("Frame", nil, parent)
    f:SetHeight(HEADER_H)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.CONTENT_PAD, yOffset)
    f:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -UI.CONTENT_PAD, yOffset)
    if f._headerBuilt then return f, HEADER_H end
    f._headerBuilt = true
    local lbl = ns.Font(f, 12, nil, T.accent)
    lbl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 8)
    lbl:SetText(text)
    local sep = ns.Solid(f, "ARTWORK", T.line, 1)
    sep:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    sep:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    sep:SetHeight(1)
    return f, HEADER_H
end

function W:Button(parent, text, yOffset, onClick)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.CONTENT_PAD, yOffset)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -UI.CONTENT_PAD, yOffset)
    local btn = ns.Button(row, text, 200, 26, onClick)
    btn:SetPoint("LEFT", row, "LEFT", 20, 0)
    return row, ROW_H
end

-- The swatch alone, sized to drop into either a full row (W:ColorPicker below) or a
-- DualRow region (BuildRegionControl's "colorpicker" slot) -- one Blizzard color picker
-- wiring, not two copies of it drifting apart.
function UI.BuildColorSwatchControl(parent, get, set, hasAlpha)
    local swatchBtn = CreateFrame("Button", nil, parent)
    swatchBtn:SetSize(40, 20)
    ns.Border(swatchBtn)
    local swatch = ns.Solid(swatchBtn, "BACKGROUND", T.fg, 1)
    swatch:SetAllPoints()
    local function PaintSwatch()
        local r, g, b = get()
        swatch:SetColorTexture(r or 1, g or 1, b or 1, 1)
    end
    PaintSwatch()
    swatchBtn._refreshValue = PaintSwatch

    swatchBtn:SetScript("OnClick", function()
        local r, g, b, a = get()
        local function Apply()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            local na = hasAlpha and ColorPickerFrame:GetColorAlpha() or 1
            set(nr, ng, nb, na)
            PaintSwatch()
        end
        ColorPickerFrame:SetupColorPickerAndShow({
            r = r or 1, g = g or 1, b = b or 1,
            opacity = a or 1,
            hasOpacity = hasAlpha and true or false,
            swatchFunc = Apply,
            opacityFunc = Apply,
            cancelFunc = function()
                set(r or 1, g or 1, b or 1, a or 1)
                PaintSwatch()
            end,
        })
    end)
    return swatchBtn
end

function W:ColorPicker(parent, text, yOffset, get, set, hasAlpha)
    local row = CachedRow(parent, "color:" .. text) or CreateFrame("Frame", nil, parent)
    row._colorGet, row._colorSet = get, set
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.CONTENT_PAD, yOffset)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -UI.CONTENT_PAD, yOffset)

    local count = (parent._nsuiRowCount or 0) + 1
    parent._nsuiRowCount = count
    if row._swatch then
        row._swatch._refreshValue()
        if row._band then row._band:SetShown(count % 2 == 1) end
        return row, ROW_H
    end
    if count % 2 == 1 or parent._rowCache then
        local band = ns.Solid(row, "BACKGROUND", T.panel, 0.35)
        band:SetAllPoints()
        band:SetShown(count % 2 == 1)
        row._band = band
    end

    local lbl = ns.Font(row, 14, nil)
    lbl:SetPoint("LEFT", row, "LEFT", 20, 0)
    lbl:SetText(text)

    local swatchBtn = UI.BuildColorSwatchControl(row,
        function() return row._colorGet() end,
        function(...) return row._colorSet(...) end, hasAlpha)
    row._swatch = swatchBtn
    swatchBtn:SetPoint("RIGHT", row, "RIGHT", -20, 0)
    return row, ROW_H
end

-------------------------------------------------------------------------------
--  Sounds
-------------------------------------------------------------------------------
-- Bundled English voice clips work without an optional SharedMedia provider.
-- Stable keys are shared by preview, native aura registrations and exported rules.
local bundledVoices = {
    { key = "voice:dispel-me", text = "Dispel me", file = "dispel-me.ogg" },
    { key = "voice:move-out", text = "Move out", file = "move-out.ogg" },
    { key = "voice:use-a-defensive", text = "Use a defensive", file = "use-a-defensive.ogg" },
}
local voicePath = "Interface\\AddOns\\NaowhSmartReminders\\Media\\Voice\\"
function UI.BuildAlertSoundTables()
    local paths, names, order = {}, { none = "None" }, { "none" }
    for _, voice in ipairs(bundledVoices) do
        paths[voice.key] = voicePath .. voice.file
        names[voice.key] = "Voice: " .. voice.text .. " (English)"
        order[#order + 1] = voice.key
    end
    return paths, names, order
end

function UI.AppendSharedMediaSounds(paths, names, order)
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if not LSM then return end
    local list = LSM:HashTable("sound")
    if not list then return end
    local sorted = {}
    for name in pairs(list) do sorted[#sorted + 1] = name end
    table.sort(sorted, function(a, b) return a:lower() < b:lower() end)
    for _, name in ipairs(sorted) do
        local key = "sm:" .. name
        if not names[key] then
            paths[key] = list[name]
            names[key] = name
            order[#order + 1] = key
        end
    end
end

function UI._PlayLSMSound(v)
    if v == nil or v == 1 then return end
    if type(v) == "string" then
        PlaySoundFile(v, "Master")
    elseif type(v) == "number" then
        PlaySound(v, "Master")
    end
end

-- Resolves a stored soundKey to a playable path. Built once and dropped whenever SharedMedia
-- registers another sound (boss mods register theirs when they load, often after login).
-- Rebuilding on a miss instead re-sorted every sound on every callout once a pack was removed.
local soundPaths
local soundProvider
local function SoundRegistered(_, mediatype)
    if mediatype == "sound" then
        soundPaths = nil
        if ns and ns.Integrations then ns.Integrations.Refresh() end
    end
end

function UI.SoundPathFor(key)
    if not key or key == "none" then return nil end
    -- Dedicated files keep racial gating separate from previews and other sounds.
    if key == "voice:stoneform-ready" then return voicePath .. "stoneform-ready.ogg" end
    if key == "voice:stoneform-preview" then return voicePath .. "stoneform-preview.ogg" end
    if key == "voice:shadowmeld-ready" then return voicePath .. "shadowmeld-ready.ogg" end
    if key == "voice:shadowmeld-preview" then return voicePath .. "shadowmeld-preview.ogg" end
    for _, voice in ipairs(bundledVoices) do
        if key == voice.key then return voicePath .. voice.file end
    end
    local provider = LibStub and LibStub("LibSharedMedia-3.0", true)
    -- A missing optional provider is not a cached miss. It may load later.
    if not provider then return nil end
    if provider ~= soundProvider then
        if soundProvider then
            soundProvider.UnregisterCallback(UI, "LibSharedMedia_Registered")
        end
        provider.RegisterCallback(UI, "LibSharedMedia_Registered", SoundRegistered)
        soundProvider = provider
        soundPaths = nil
    end
    if not soundPaths then
        local paths, names, order = UI.BuildAlertSoundTables()
        UI.AppendSharedMediaSounds(paths, names, order)
        soundPaths = paths
    end
    return soundPaths[key]
end

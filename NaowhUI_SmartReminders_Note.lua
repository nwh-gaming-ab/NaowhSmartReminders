-------------------------------------------------------------------------------
--  NaowhUI_SmartReminders_Note.lua -- the Custom Reminders tab.
--
--  Instance and boss pickers over the same reminder sections the boss pages use
--  (ns.BuildBossReminderSections), so every reminder for a boss is authored and
--  managed from one place. The MRT note importer that briefly lived here was
--  removed at the owner's direction -- authoring goes through the editors.
-------------------------------------------------------------------------------
local ns = _G.NaowhUITankReminder
if not ns then return end

local selInstIdx = 1
local selBossIdx = {}   -- keyed by instance id

function ns.BuildCustomRemindersPage(parent, yOffset)
    local EUI = ns.UI
    local W = EUI.Widgets
    if EUI.ClearContentHeader then EUI:ClearContentHeader() end
    local y = yOffset or -6
    local PADX = EUI.CONTENT_PAD or 45

    local pageHead = ns.Font(parent, 14, nil, ns.THEME.accent)
    pageHead:SetPoint("TOP", parent, "TOP", 0, y)
    pageHead:SetText("ABILITY REMINDERS")
    y = y - 24

    local hint = ns.Font(parent, 11, nil, ns.THEME.muted)
    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", PADX, y)
    hint:SetPoint("RIGHT", parent, "RIGHT", -PADX, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Every reminder for the selected boss in one place. Phase Start "
        .. "triggers need BigWigs or DBM and only fire on bosses whose module "
        .. "announces phases. Any Combat, at the end of the Instance list, is for "
        .. "reminders that count from entering combat instead of from a boss, so they "
        .. "work on trash and out in the world too.")
    y = y - 36

    -- The five reminder anchors are profile-wide rather than per boss, so this sits above
    -- the boss list and before the journal check -- it stays reachable even on the first
    -- open, when the Dungeon Journal has not answered yet.
    if ns.ShowRaidReminderAnchorConfig then
        local anchorBtn = ns.Button(parent, "Customize Anchors", 200, 26, function()
            ns.ShowRaidReminderAnchorConfig()
        end)
        anchorBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", PADX, y)
        ns.Tooltip(anchorBtn, "Customize Anchors",
            "Place and size each reminder display -- Message, Timer, Icon, Bar and Circle. "
            .. "An alignment grid appears while you are in there. This window steps aside "
            .. "and comes back when you press Exit Config.")
        y = y - 36
    end

    local data = ns.ScrapeBosses and ns.ScrapeBosses()
    if not (data and data.instances and #data.instances > 0) then
        local wait = ns.Font(parent, 12, nil, ns.THEME.muted)
        wait:SetPoint("TOPLEFT", parent, "TOPLEFT", PADX, y)
        wait:SetText("The Dungeon Journal has not answered yet -- reopen this tab in a moment.")
        return y - 24
    end

    -- All journal instances, plus one synthetic bucket for encounters that only exist in
    -- saved data (an old season's boss with reminders still stored).
    local instList = {}
    for i = 1, #data.instances do instList[#instList + 1] = data.instances[i] end
    do
        local known = {}
        for _, inst in ipairs(instList) do
            for _, b in ipairs(inst.bosses) do known[tostring(b.encounterID)] = true end
        end
        local db = ns.DB()
        local extras = {}
        for _, field in ipairs({ "raidReminders", "customReminders" }) do
            if type(db[field]) == "table" then
                for encStr in pairs(db[field]) do
                    if not known[encStr] and tonumber(encStr) and tonumber(encStr) > 0 then
                        extras[encStr] = true
                    end
                end
            end
        end
        -- Observed timings live at the SavedVariables root, not in the profile, so they
        -- need their own pass or an old tier's recordings become unreachable here.
        local sv = _G.NaowhUI_SmartRemindersDB
        if type(sv) == "table" and type(sv.observed) == "table" then
            for encStr in pairs(sv.observed) do
                if encStr ~= "v" and not known[encStr]
                    and tonumber(encStr) and tonumber(encStr) > 0 then
                    extras[encStr] = true
                end
            end
        end
        local extraBosses = {}
        for encStr in pairs(extras) do
            extraBosses[#extraBosses + 1] =
                { name = "Encounter " .. encStr, encounterID = tonumber(encStr) }
        end
        table.sort(extraBosses, function(a, b) return a.encounterID < b.encounterID end)
        if #extraBosses > 0 then
            instList[#instList + 1] =
                { id = "savedOnly", name = "Saved (not in journal)", bosses = extraBosses }
        end
    end

    if selInstIdx > #instList then selInstIdx = 1 end
    local inst = instList[selInstIdx]
    local bIdx = selBossIdx[inst.id] or 1
    if bIdx > #inst.bosses then bIdx = 1 end
    local boss = inst.bosses[bIdx]

    local instValues, instOrder = {}, {}
    for i = 1, #instList do instValues[i] = instList[i].name; instOrder[i] = i end
    local bossValues, bossOrder = {}, {}
    for i = 1, #inst.bosses do bossValues[i] = inst.bosses[i].name; bossOrder[i] = i end

    local _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Instance", width = 220,
          values = instValues, order = instOrder,
          getValue = function() return selInstIdx end,
          setValue = function(v)
              selInstIdx = v
              EUI:RefreshPage(true)
          end },
        { type = "dropdown", text = "Boss", width = 220,
          values = bossValues, order = bossOrder,
          getValue = function() return bIdx end,
          setValue = function(v)
              selBossIdx[inst.id] = v
              EUI:RefreshPage(true)
          end }
    ); y = y - h - 6

    if not boss then return y end

    -- The same sections the boss pages use, rendered inline.
    local listBox = CreateFrame("Frame", nil, parent)
    listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", PADX, y)
    listBox:SetPoint("RIGHT", parent, "RIGHT", -PADX, 0)
    local okSec, usedY = pcall(ns.BuildBossReminderSections, listBox, boss.encounterID,
        inst.isRaid or false, 0,
        { EUI = EUI, onChanged = function() EUI:RefreshPage(true) end })
    if not okSec then
        local errText = ns.Font(listBox, 11, nil, { r = 1, g = 0.35, b = 0.35 })
        errText:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, 0)
        errText:SetText("Failed to build the reminder lists: " .. tostring(usedY))
        usedY = -24
    end
    listBox:SetHeight(math.abs(usedY) + 4)
    y = y + usedY - 10

    return y
end

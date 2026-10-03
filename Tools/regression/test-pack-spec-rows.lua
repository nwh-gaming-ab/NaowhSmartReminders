-- The spec grid both pack dialogs draw: what order the rows come out in, what each one
-- says and what colour it wears. Import and Merge share one copy of this, so anything
-- here is a claim about both windows.
local f = assert(io.open(arg[1] or "NaowhUI_SmartReminders_Packs.lua", "rb"))
local source = f:read("*a"):gsub("\r\n", "\n"); f:close()
local function Slice(a, b)
    local first = assert(source:find(a, 1, true), a)
    return source:sub(first, assert(source:find(b, first + #a, true), b) - 1)
end

-- Three classes is enough to prove the ordering: two of them share a spec name, which is
-- the case the colour and the grouping exist for.
local CLASSES = {
    { name = "Warrior", token = "WARRIOR" },
    { name = "Paladin", token = "PALADIN" },
    { name = "Death Knight", token = "DEATHKNIGHT" },
}
local SPECS = {
    [71] = { "Arms", "Warrior", "DAMAGER" },
    [73] = { "Protection", "Warrior", "TANK" },
    [65] = { "Holy", "Paladin", "HEALER" },
    [66] = { "Protection", "Paladin", "TANK" },
    [250] = { "Blood", "Death Knight", "TANK" },
}
local COLORS = {
    WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
    PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
    DEATHKNIGHT = { r = 0.77, g = 0.12, b = 0.23 },
}
local THEME_FG = { r = 0.9, g = 0.9, b = 0.9 }

local function Fixture()
    local env = {
        GetNumClasses = function() return #CLASSES end,
        GetClassInfo = function(i)
            local c = CLASSES[i]
            return c and c.name, c and c.token
        end,
        GetSpecializationInfoByID = function(id)
            local s = SPECS[id]
            if not s then return nil end
            return id, s[1], "", "", s[3], 0, s[2]
        end,
        RAID_CLASS_COLORS = COLORS,
    }
    setmetatable(env, { __index = _G })
    local chunk = assert(loadstring("local ns = ...\n"
        .. Slice("local ROLE_LABEL =", "-- Built once and reused.")
        .. "\nreturn SortSpecs, PaintSpecLabel"))
    setfenv(chunk, env)
    return chunk({ THEME = { fg = THEME_FG } })
end

-- The rows carry whatever ns.PackSpecs handed over: a key and a display name.
local function Spec(key, name) return { key = key, name = name } end

local function Label()
    local l = {}
    l.SetText = function(_, v) l.text = v end
    l.SetTextColor = function(_, r, g, b) l.colour = { r, g, b } end
    return l
end

local count = 0
local function Case(name, fn) fn(); count = count + 1; print("PASS " .. name) end

Case("specs come out by class order, then tank, healer, damage", function()
    local SortSpecs = Fixture()
    local sorted = SortSpecs({
        Spec(65, "Holy Paladin"), Spec(250, "Blood Death Knight"),
        Spec(71, "Arms Warrior"), Spec(73, "Protection Warrior"),
        Spec(66, "Protection Paladin"),
    })
    local order = {}
    for i = 1, #sorted do order[i] = sorted[i].key end
    assert(order[1] == 73 and order[2] == 71, "Warrior is class 1, and its tank leads")
    assert(order[3] == 66 and order[4] == 65, "then Paladin, tank before healer")
    assert(order[5] == 250, "Death Knight last, the order GetClassInfo walks")
end)

Case("a class's specs stay adjacent rather than scattering alphabetically", function()
    local SortSpecs = Fixture()
    local sorted = SortSpecs({ Spec(250, "Blood Death Knight"), Spec(71, "Arms Warrior"),
        Spec(73, "Protection Warrior") })
    assert(sorted[1].className == "Warrior" and sorted[2].className == "Warrior",
        "alphabetically Blood led, which put the other Warrior spec two rows away")
end)

Case("a row reads as the spec and its role, not the class", function()
    local SortSpecs, PaintSpecLabel = Fixture()
    local sorted = SortSpecs({ Spec(73, "Protection Warrior"), Spec(65, "Holy Paladin") })
    local a, b = Label(), Label()
    PaintSpecLabel(a, sorted[1])
    PaintSpecLabel(b, sorted[2])
    assert(a.text == "Protection (Tank)", "got " .. tostring(a.text))
    assert(b.text == "Holy (Healer)", "got " .. tostring(b.text))
end)

Case("the class is what the row is coloured with", function()
    local SortSpecs, PaintSpecLabel = Fixture()
    local sorted = SortSpecs({ Spec(66, "Protection Paladin") })
    local l = Label()
    PaintSpecLabel(l, sorted[1])
    assert(l.colour[1] == COLORS.PALADIN.r and l.colour[3] == COLORS.PALADIN.b,
        "Protection belongs to two classes, so the colour is what tells them apart")
end)

Case("a spec this client cannot resolve keeps its plain name", function()
    local SortSpecs, PaintSpecLabel = Fixture()
    -- A pack built on a newer patch, carrying a spec that does not exist here yet.
    local sorted = SortSpecs({ Spec(9999, "Some New Spec") })
    local l = Label()
    PaintSpecLabel(l, sorted[1])
    assert(l.text == "Some New Spec")
    assert(l.colour[1] == THEME_FG.r, "and the theme's own colour rather than none")
end)

Case("a whole-file pack's profile rows are left as they are", function()
    local _, PaintSpecLabel = Fixture()
    local l = Label()
    -- Profile rows never go through SortSpecs: they are names, not spec ids.
    PaintSpecLabel(l, { key = "Naowh Shared", name = "Naowh Shared" })
    assert(l.text == "Naowh Shared")
    assert(l.colour[1] == THEME_FG.r)
end)

print(count .. " pack spec row regressions passed")

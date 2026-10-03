-- Handing work back to the curator whose profile it is. The no-resharing refusal exists to
-- stop somebody redistributing a curator's pack, and it catches a contributor handing
-- changes back to that same curator, which is the one case it gets wrong.
local root = arg[1] or "."

local function Fixture()
    local e = { db = { tankReminder = {} }, printed = {} }
    local ns = {}
    ns.DB = function() return e.db end
    ns.Print = function(m) e.printed[#e.printed + 1] = m end
    ns.Integrations = { ValidRule = function() return true end }
    ns.UI = { Widgets = {} }
    ns.THEME = { accent = {}, muted = {}, fg = {}, panel = {}, bg = {}, line = {} }
    ns.ListProfiles = function() return {} end
    ns.SettingDefault = function() return nil end

    -- A stand-in codec. The real libraries are not loaded offline, and what these cases
    -- care about is what goes into the payload and comes back out, not how it is packed.
    local vault = {}
    local env = setmetatable({ NaowhUITankReminder = ns,
        UnitName = function() return "Contributor" end,
        date = function() return "2026-09-17" end,
        CreateFrame = function() return { SetScript = function() end } end,
        LibStub = function(name)
            if name == "LibSerialize" then
                return {
                    Serialize = function(_, v)
                        vault[#vault + 1] = v; return "S" .. #vault
                    end,
                    Deserialize = function(_, str)
                        local k = tonumber(tostring(str):match("^S(%d+)$"))
                        if not k or not vault[k] then return false, "bad string" end
                        return true, vault[k]
                    end,
                }
            elseif name == "LibDeflate" then
                local same = function(_, v) return v end
                return { CompressDeflate = same, DecompressDeflate = same,
                    EncodeForPrint = same, DecodeForPrint = same }
            end
        end,
    }, { __index = _G })
    env._G = env
    local chunk = assert(loadfile(root .. "/NaowhUI_SmartReminders_Packs.lua"))
    setfenv(chunk, env); chunk()
    e.ns, e.env = ns, env
    return e
end

-- Enough saved settings that there is something to export at all.
local function Fill(e)
    e.db.presets = { ["250"] = { p1 = { list = { 100 } } } }
    e.db.activePreset = { ["250"] = "p1" }
end

local count = 0
local function Case(name, fn) fn(); count = count + 1; print("PASS " .. name) end

Case("a profile of your own exports either way", function()
    local e = Fixture(); Fill(e)
    local plain = e.ns.ExportPack("Mine", "Contributor")
    assert(type(plain) == "string" and #plain > 0)
    local shared = e.ns.ExportPack("Mine", "Contributor", true)
    assert(type(shared) == "string" and #shared > 0)
end)

Case("an imported profile is still refused by the ordinary export", function()
    local e = Fixture(); Fill(e)
    e.db.importedPack = { name = "Naowh", author = "Robin" }
    local str, why = e.ns.ExportPack("Mine", "Contributor")
    assert(str == nil and type(why) == "string")
    assert(why:find("Naowh", 1, true) and why:find("Robin", 1, true))
    -- and it does NOT name the command that bypasses it: anyone who hit this refusal was
    -- being told how to get round it, which is how a licensed pack left as a licence-free
    -- string. Contributors are told the command directly instead.
    assert(not why:find("/nutank share", 1, true))
end)

Case("the contributor export is allowed, and says what it came from", function()
    local e = Fixture(); Fill(e)
    e.db.importedPack = { name = "Naowh", author = "Robin" }
    local str = e.ns.ExportPack("Contributed changes", "Contributor", true)
    assert(type(str) == "string")
    local payload = e.ns.DecodePack(str)
    assert(payload, "the string it produces must decode")
    assert(payload.derivedFrom and payload.derivedFrom.name == "Naowh"
        and payload.derivedFrom.author == "Robin",
        "a returned pack has to declare whose it started as")
    assert(payload.author == "Contributor")
end)

Case("the preview names the pack this one was built on", function()
    local e = Fixture(); Fill(e)
    e.db.importedPack = { name = "Naowh", author = "Robin" }
    local str = e.ns.ExportPack("Contributed changes", "Contributor", true)
    local _, describe = e.ns.DecodePack(str)
    assert(type(describe) == "string")
    -- Stated, not addressed to the reader: whoever opens a pack is not always the
    -- curator it names.
    assert(describe:find("Built on", 1, true), describe)
    assert(describe:find("Naowh", 1, true))
end)

Case("an ordinary pack says nothing about being derived", function()
    local e = Fixture(); Fill(e)
    local str = e.ns.ExportPack("Mine", "Contributor")
    local payload, describe = e.ns.DecodePack(str)
    assert(payload.derivedFrom == nil)
    assert(not describe:find("Worked on from", 1, true))
end)

Case("a profile with nothing in it still refuses, imported or not", function()
    local e = Fixture()
    e.db.importedPack = { name = "Naowh", author = "Robin" }
    local str, why = e.ns.ExportPack("Contributed changes", "Contributor", true)
    assert(str == nil and why:find("nothing to export", 1, true))
end)

print(count .. " contributor export regressions passed")

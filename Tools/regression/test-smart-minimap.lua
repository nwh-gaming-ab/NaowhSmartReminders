local f = assert(io.open(arg[1], "rb"))
local source = f:read("*a"); f:close()
local chunk = assert(source:match("(local launcherEvents = CreateFrame.*)"))
for _, saved in ipairs({{}, {minimap={minimapPos=47,hide=true}}}) do
    local event, object, registered, clicked
    local original = saved.minimap
    local ns = { AccountSettings=function() return saved end,
        ToggleOptionsWindow=function() clicked=true end }
    local frame = {
        SetScript=function(_,_,fn) event=fn end,
        RegisterEvent=function(_,name) assert(name=="PLAYER_LOGIN" and event) end,
        UnregisterEvent=function(_,name) assert(name=="PLAYER_LOGIN") end,
    }
    local libs = {
        ["LibDataBroker-1.1"]={NewDataObject=function(_,name,data)
            assert(name=="NaowhSmartReminders"); object=data; return data end},
        ["LibDBIcon-1.0"]={Register=function(_,name,data,db)
            assert(name=="NaowhSmartReminders" and data==object and db==saved.minimap)
            registered=true end},
    }
    local env = setmetatable({ns=ns,CreateFrame=function() return frame end,
        LibStub=function(name) return assert(libs[name]) end}, {__index=_G})
    assert(load(chunk,"launcher","t",env))()
    assert(not registered)
    event(frame)
    assert(registered and object.type=="launcher")
    if original then assert(saved.minimap==original and original.minimapPos==47 and original.hide)
    else assert(saved.minimap.minimapPos==220) end
    object.OnClick(); assert(clicked)
    local lines=0
    object.OnTooltipShow({AddLine=function(_,text) assert(type(text)=="string"); lines=lines+1 end})
    assert(lines==3)
end
print("PASS: login registration, fresh/saved position, click and tooltip")

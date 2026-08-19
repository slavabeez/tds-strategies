local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")

local LP = Players.LocalPlayer

local CFG = {
    Speed          = 45,
    ClimbSpeed     = 40,
    ArriveDist     = 2.0,
    ClearanceAbove = 7,
    MaxClimb       = 80,
    ScanUp         = 150,
    LookAhead      = 6,
    PostRemoteWait = 2,
    StuckTimeout   = 15,
    Loop           = false,
    ShowPath       = true,
    PlatformStand  = true,
}

local ALLOWED = {
    LaunderBriefcase         = "SmuggleService",
    SellSmuggledGoods        = "SmuggleService",
    PurchaseWorldBuyableItem = "WorldBuyableItemService",
}

local function getChar() return LP.Character end
local function getHRP()
    local c = getChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function resolvePath(path)
    if type(path) ~= "string" then return nil end
    local cur = game
    for token in string.gmatch(path, "[^%.]+") do
        if not cur then return nil end
        local nxt = cur:FindFirstChild(token)
        if not nxt and cur == game then
            local ok, srv = pcall(game.GetService, game, token)
            if ok then nxt = srv end
        end
        cur = nxt
    end
    return cur
end

local function makeRef(inst)
    if typeof(inst) ~= "Instance" then return nil end
    local chain, cur = {}, inst
    while cur and cur ~= game do
        local parent = cur.Parent
        local idx = 0
        if parent then
            for i, c in ipairs(parent:GetChildren()) do
                if c == cur then idx = i break end
            end
        end
        table.insert(chain, 1, { n = cur.Name, i = idx, c = cur.ClassName })
        cur = parent
    end
    if #chain == 0 then return nil end
    return chain
end

local function resolveRef(chain)
    if type(chain) ~= "table" then return nil end
    local cur = game
    for _, e in ipairs(chain) do
        if not cur then return nil end
        local kids = cur:GetChildren()
        local pick = kids[e.i]
        if not (pick and pick.Name == e.n and pick.ClassName == e.c) then
            pick = cur:FindFirstChild(e.n)
        end
        if not pick and cur == game then
            local ok, srv = pcall(game.GetService, game, e.n)
            if ok then pick = srv end
        end
        cur = pick
    end
    return cur
end

local function refToString(chain)
    if type(chain) ~= "table" then return "?" end
    local names = {}
    for _, e in ipairs(chain) do table.insert(names, e.n) end
    return table.concat(names, ".")
end

local function fullName(inst)
    local ok, n = pcall(function() return inst:GetFullName() end)
    return ok and n or nil
end

local PRESETS = {
    {
        title      = "Launder Briefcase",
        remotePath = "ReplicatedStorage.__remotes.SmuggleService.LaunderBriefcase",
        args = function()
            local f = workspace:FindFirstChild("LaunderPrompts")
            local c = f and f:GetChildren()[2]
            return { c and c:FindFirstChild("PromptPart") }, 1
        end,
    },
    {
        title      = "Sell Smuggled Goods",
        remotePath = "ReplicatedStorage.__remotes.SmuggleService.SellSmuggledGoods",
        args = function()
            return { resolvePath("Workspace.NPC.Seller4") }, 1
        end,
    },
    {
        title      = "Buy Fake Diamond Ring",
        remotePath = "ReplicatedStorage.__remotes.WorldBuyableItemService.PurchaseWorldBuyableItem",
        args = function()
            return { resolvePath("Workspace.WorldBuyableItems.CivilianArea.Fake Diamond Ring") }, 1
        end,
    },
    {
        title      = "Buy Mona Lisa Painting",
        remotePath = "ReplicatedStorage.__remotes.WorldBuyableItemService.PurchaseWorldBuyableItem",
        args = function()
            return { resolvePath("Workspace.WorldBuyableItems.CivilianArea.Mona Lisa Painting") }, 1
        end,
    },
}

local steps   = {}
local playing = false

local lastFired = nil
local hookOk    = false

do
    local ok = pcall(function()
        local getnamecall = getnamecallmethod
        local iscaller    = checkcaller
        local newcc       = newcclosure or function(f) return f end
        if not getnamecall then error("no getnamecallmethod") end

        local function allowedRemote(self)
            if typeof(self) ~= "Instance" then return false end
            local parent = self.Parent
            if not parent then return false end
            return ALLOWED[self.Name] == parent.Name
        end

        local function capture(self, method, ...)
            if method ~= "FireServer" and method ~= "InvokeServer" then return end
            if iscaller and iscaller() then return end
            if not allowedRemote(self) then return end
            lastFired = { remote = self, method = method, args = table.pack(...) }
        end

        if hookmetamethod then
            local old
            old = hookmetamethod(game, "__namecall", newcc(function(self, ...)
                pcall(capture, self, getnamecall(), ...)
                return old(self, ...)
            end))
            hookOk = true
        else
            local mt = getrawmetatable(game)
            setreadonly(mt, false)
            local old = mt.__namecall
            mt.__namecall = newcc(function(self, ...)
                pcall(capture, self, getnamecall(), ...)
                return old(self, ...)
            end)
            setreadonly(mt, true)
            hookOk = true
        end
    end)
    if not ok then hookOk = false end
end

local vizFolder = workspace:FindFirstChild("__PathBotViz")
if vizFolder then vizFolder:Destroy() end
vizFolder = Instance.new("Folder")
vizFolder.Name = "__PathBotViz"
vizFolder.Parent = workspace

local routeFolder = Instance.new("Folder"); routeFolder.Name = "Route";   routeFolder.Parent = vizFolder
local planFolder  = Instance.new("Folder"); planFolder.Name  = "Planned"; planFolder.Parent  = vizFolder

local function newPart(props, parent)
    local p = Instance.new("Part")
    p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
    p.Material = Enum.Material.Neon
    p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
    for k, v in pairs(props) do p[k] = v end
    p.Parent = parent
    return p
end

local function drawLine(a, b, color, thickness, parent)
    local d = (b - a)
    if d.Magnitude < 0.05 then return end
    newPart({
        Size         = Vector3.new(thickness, thickness, d.Magnitude),
        CFrame       = CFrame.lookAt(a:Lerp(b, 0.5), b),
        Color        = color,
        Transparency = 0.25,
    }, parent)
end

local function drawNode(pos, color, size, label, parent)
    local p = newPart({
        Shape        = Enum.PartType.Ball,
        Size         = Vector3.new(size, size, size),
        CFrame       = CFrame.new(pos),
        Color        = color,
        Transparency = 0.15,
    }, parent)
    if label then
        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.new(0, 70, 0, 20)
        bb.StudsOffset = Vector3.new(0, 1.6, 0)
        bb.AlwaysOnTop = true
        bb.Parent = p
        local t = Instance.new("TextLabel")
        t.Size = UDim2.new(1, 0, 1, 0)
        t.BackgroundTransparency = 1
        t.Font = Enum.Font.GothamBold
        t.TextSize = 13
        t.TextColor3 = color
        t.TextStrokeTransparency = 0.4
        t.Text = label
        t.Parent = bb
    end
    return p
end

local function clearFolder(f)
    for _, c in ipairs(f:GetChildren()) do c:Destroy() end
end

local COL_MOVE   = Color3.fromRGB(0, 200, 255)
local COL_REMOTE = Color3.fromRGB(255, 170, 0)
local COL_PLAN   = Color3.fromRGB(60, 255, 120)

local function drawRoute()
    clearFolder(routeFolder)
    if not CFG.ShowPath then return end
    local prev = nil
    for i, s in ipairs(steps) do
        local col = (s.type == "remote") and COL_REMOTE or COL_MOVE
        drawNode(s.pos, col, (s.type == "remote") and 2.2 or 1.4, tostring(i), routeFolder)
        if prev then drawLine(prev, s.pos, COL_MOVE, 0.3, routeFolder) end
        prev = s.pos
    end
    if CFG.Loop and #steps > 1 then
        drawLine(steps[#steps].pos, steps[1].pos, COL_MOVE, 0.3, routeFolder)
    end
end

local function drawPlan(points, from)
    clearFolder(planFolder)
    if not CFG.ShowPath then return end
    local prev = from
    for _, p in ipairs(points) do
        drawLine(prev, p, COL_PLAN, 0.45, planFolder)
        prev = p
    end
end

local function rayParams()
    local p = RaycastParams.new()
    local ok = pcall(function() p.FilterType = Enum.RaycastFilterType.Exclude end)
    if not ok then p.FilterType = Enum.RaycastFilterType.Blacklist end
    local ignore = { vizFolder }
    local c = getChar(); if c then table.insert(ignore, c) end
    p.FilterDescendantsInstances = ignore
    p.IgnoreWater = true
    return p
end

local function blocked(a, b)
    local d = b - a
    if d.Magnitude < 0.05 then return false end
    return workspace:Raycast(a, d, rayParams()) ~= nil
end

local function topOnSegment(a, b)
    local baseY  = math.max(a.Y, b.Y)
    local best   = baseY
    local dist   = (b - a).Magnitude
    local n      = math.clamp(math.floor(dist / 3), 2, 60)
    local params = rayParams()
    for i = 0, n do
        local p   = a:Lerp(b, i / n)
        local org = Vector3.new(p.X, baseY + CFG.ScanUp, p.Z)
        local res = workspace:Raycast(org, Vector3.new(0, -(CFG.ScanUp * 2 + 50), 0), params)
        if res and res.Position.Y > best then best = res.Position.Y end
    end
    return best
end

local function planPath(a, b)
    local up = Vector3.new(0, 1.5, 0)
    if not blocked(a + up, b + up) then
        return { b }
    end
    local y = topOnSegment(a, b) + CFG.ClearanceAbove
    y = math.min(y, math.max(a.Y, b.Y) + CFG.MaxClimb)
    y = math.max(y, a.Y + 2, b.Y + 2)
    return {
        Vector3.new(a.X, y, a.Z),
        Vector3.new(b.X, y, b.Z),
        b,
    }
end

local function flyTo(target)
    local t0 = os.clock()
    while playing do
        local dt  = RunService.Heartbeat:Wait()
        local hrp = getHRP()
        if not hrp then
            task.wait(0.2)
            t0 = os.clock()
        else
            local pos   = hrp.Position
            local delta = target - pos
            local dist  = delta.Magnitude
            if dist <= CFG.ArriveDist then return true end
            if os.clock() - t0 > CFG.StuckTimeout then return false end

            local dir   = delta.Unit
            local ahead = workspace:Raycast(pos, dir * CFG.LookAhead, rayParams())
            local newPos
            if ahead then
                newPos = pos + Vector3.new(0, CFG.ClimbSpeed * dt, 0)
            else
                newPos = pos + dir * math.min(CFG.Speed * dt, dist)
            end

            local flat = Vector3.new(delta.X, 0, delta.Z)
            if flat.Magnitude > 0.15 then
                hrp.CFrame = CFrame.lookAt(newPos, newPos + flat.Unit)
            else
                hrp.CFrame = CFrame.new(newPos) * (hrp.CFrame - hrp.CFrame.Position)
            end
            hrp.AssemblyLinearVelocity = Vector3.zero
        end
    end
    return false
end

local function travelTo(target)
    local hrp = getHRP()
    if not hrp then return false end
    local pts = planPath(hrp.Position, target)
    drawPlan(pts, hrp.Position)
    for _, p in ipairs(pts) do
        if not playing then return false end
        if not flyTo(p) then return false end
    end
    return true
end

local function stepRemote(s)
    local r = s.remote
    if typeof(r) ~= "Instance" or not r.Parent then
        r = resolveRef(s.remoteRef) or resolvePath(s.remotePath)
        s.remote = r
    end
    return r
end

local function buildArgs(s)
    local packed = s.args or { n = 0 }
    local out = table.create(packed.n)
    for i = 1, packed.n do
        local v   = packed[i]
        local ref = s.argRefs and s.argRefs[i]
        if ref and (typeof(v) ~= "Instance" or not v.Parent) then
            v = resolveRef(ref)
            packed[i] = v
        end
        out[i] = v
    end
    return out, packed.n
end

local function fireStep(s)
    local remote = stepRemote(s)
    if not remote then return false, "remote не найден: " .. tostring(s.remotePath) end
    local args, n = buildArgs(s)
    local ok, err = pcall(function()
        if s.method == "InvokeServer" then
            return remote:InvokeServer(table.unpack(args, 1, n))
        end
        return remote:FireServer(table.unpack(args, 1, n))
    end)
    return ok, err
end

local function guiParent()
    local ok, h = pcall(function() return gethui() end)
    if ok and h then return h end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then return cg end
    return LP:WaitForChild("PlayerGui")
end

local oldGui = guiParent():FindFirstChild("PathBotGui")
if oldGui then oldGui:Destroy() end

local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local gui = mk("ScreenGui", {
    Name = "PathBotGui",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent())
pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)

local main = mk("Frame", {
    Size = UDim2.new(0, 330, 0, 480),
    Position = UDim2.new(0, 30, 0.5, -240),
    BackgroundColor3 = Color3.fromRGB(24, 26, 32),
    BorderSizePixel = 0,
    Active = true,
}, gui)
mk("UICorner", { CornerRadius = UDim.new(0, 10) }, main)
mk("UIStroke", { Color = Color3.fromRGB(60, 65, 80), Thickness = 1 }, main)

local bar = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundColor3 = Color3.fromRGB(33, 36, 45),
    BorderSizePixel = 0,
}, main)
mk("UICorner", { CornerRadius = UDim.new(0, 10) }, bar)
mk("TextLabel", {
    Size = UDim2.new(1, -70, 1, 0), Position = UDim2.new(0, 12, 0, 0),
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 14,
    TextColor3 = Color3.fromRGB(235, 235, 245), TextXAlignment = Enum.TextXAlignment.Left,
    Text = "PathBot",
}, bar)

local btnMin = mk("TextButton", {
    Size = UDim2.new(0, 28, 0, 24), Position = UDim2.new(1, -62, 0, 5),
    BackgroundColor3 = Color3.fromRGB(55, 60, 72), BorderSizePixel = 0,
    Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Color3.fromRGB(230, 230, 240),
    Text = "-",
}, bar)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, btnMin)

local btnClose = mk("TextButton", {
    Size = UDim2.new(0, 28, 0, 24), Position = UDim2.new(1, -32, 0, 5),
    BackgroundColor3 = Color3.fromRGB(120, 45, 50), BorderSizePixel = 0,
    Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Color3.fromRGB(255, 225, 225),
    Text = "X",
}, bar)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, btnClose)

local body = mk("Frame", {
    Size = UDim2.new(1, -16, 1, -42), Position = UDim2.new(0, 8, 0, 38),
    BackgroundTransparency = 1,
}, main)

do
    local dragging, dragStart, startPos
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, main.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
                      or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                      startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
end

local function button(text, y, w, x, color)
    local b = mk("TextButton", {
        Size = UDim2.new(w, -4, 0, 28), Position = UDim2.new(x, 0, 0, y),
        BackgroundColor3 = color or Color3.fromRGB(45, 50, 62), BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium, TextSize = 12,
        TextColor3 = Color3.fromRGB(235, 235, 245), Text = text,
    }, body)
    mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    return b
end

local bRecPos    = button("+ Позиция  (F1)",   0,  0.5,  0,    Color3.fromRGB(38, 78, 96))
local bRecRemote = button("+ Remote  (F2)",    0,  0.5,  0.5,  Color3.fromRGB(96, 70, 25))
local bPresets   = button("+ Действие  v",     32, 0.5,  0,    Color3.fromRGB(70, 60, 40))
local bWait      = button("+ Пауза",           32, 0.5,  0.5,  Color3.fromRGB(50, 50, 62))
local bPlay      = button("> Играть  (F3)",    64, 0.5,  0,    Color3.fromRGB(35, 95, 55))
local bStop      = button("[] Стоп",           64, 0.5,  0.5,  Color3.fromRGB(110, 45, 45))
local bClear     = button("Очистить",          96, 0.34, 0)
local bCopy      = button("Копировать",        96, 0.33, 0.34)
local bPaste     = button("Вставить",          96, 0.33, 0.67)

local function toggle(text, y, x, w, key, onChange)
    local b = mk("TextButton", {
        Size = UDim2.new(w, -4, 0, 24), Position = UDim2.new(x, 0, 0, y),
        BackgroundColor3 = Color3.fromRGB(40, 44, 55), BorderSizePixel = 0,
        Font = Enum.Font.Gotham, TextSize = 11,
        TextColor3 = Color3.fromRGB(210, 210, 225), Text = "",
    }, body)
    mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    local function upd()
        b.Text = (CFG[key] and "[+] " or "[ ] ") .. text
        b.BackgroundColor3 = CFG[key] and Color3.fromRGB(45, 70, 60) or Color3.fromRGB(40, 44, 55)
    end
    b.MouseButton1Click:Connect(function()
        CFG[key] = not CFG[key]
        upd()
        if onChange then onChange() end
    end)
    upd()
    return b
end

toggle("Зациклить", 128, 0, 0.5, "Loop", function() drawRoute() end)
toggle("Траектория", 128, 0.5, 0.5, "ShowPath", function()
    if not CFG.ShowPath then clearFolder(routeFolder); clearFolder(planFolder) end
    drawRoute()
end)

mk("TextLabel", {
    Size = UDim2.new(0.4, 0, 0, 24), Position = UDim2.new(0, 2, 0, 156),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
    TextColor3 = Color3.fromRGB(190, 190, 205), TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Скорость:",
}, body)
local boxSpeed = mk("TextBox", {
    Size = UDim2.new(0.22, 0, 0, 24), Position = UDim2.new(0.4, 0, 0, 156),
    BackgroundColor3 = Color3.fromRGB(40, 44, 55), BorderSizePixel = 0,
    Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Color3.fromRGB(235, 235, 245),
    Text = tostring(CFG.Speed), ClearTextOnFocus = false,
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, boxSpeed)
boxSpeed.FocusLost:Connect(function()
    local v = tonumber(boxSpeed.Text)
    if v and v > 0 then CFG.Speed = v end
    boxSpeed.Text = tostring(CFG.Speed)
end)

mk("TextLabel", {
    Size = UDim2.new(0.2, 0, 0, 24), Position = UDim2.new(0.63, 0, 0, 156),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
    TextColor3 = Color3.fromRGB(190, 190, 205), TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Пауза:",
}, body)
local boxWait = mk("TextBox", {
    Size = UDim2.new(0.17, 0, 0, 24), Position = UDim2.new(0.83, 0, 0, 156),
    BackgroundColor3 = Color3.fromRGB(40, 44, 55), BorderSizePixel = 0,
    Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Color3.fromRGB(235, 235, 245),
    Text = tostring(CFG.PostRemoteWait), ClearTextOnFocus = false,
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, boxWait)

local boxName = mk("TextBox", {
    Size = UDim2.new(0.44, -4, 0, 24), Position = UDim2.new(0, 0, 0, 186),
    BackgroundColor3 = Color3.fromRGB(40, 44, 55), BorderSizePixel = 0,
    Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Color3.fromRGB(235, 235, 245),
    PlaceholderText = "имя пресета", Text = "", ClearTextOnFocus = false,
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, boxName)

local bSave = mk("TextButton", {
    Size = UDim2.new(0.28, -4, 0, 24), Position = UDim2.new(0.44, 0, 0, 186),
    BackgroundColor3 = Color3.fromRGB(45, 85, 70), BorderSizePixel = 0,
    Font = Enum.Font.GothamMedium, TextSize = 11,
    TextColor3 = Color3.fromRGB(235, 245, 240), Text = "Сохранить",
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, bSave)

local bFiles = mk("TextButton", {
    Size = UDim2.new(0.28, -4, 0, 24), Position = UDim2.new(0.72, 0, 0, 186),
    BackgroundColor3 = Color3.fromRGB(50, 55, 80), BorderSizePixel = 0,
    Font = Enum.Font.GothamMedium, TextSize = 11,
    TextColor3 = Color3.fromRGB(225, 230, 250), Text = "Пресеты v",
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, bFiles)

local list = mk("ScrollingFrame", {
    Size = UDim2.new(1, 0, 1, -248), Position = UDim2.new(0, 0, 0, 216),
    BackgroundColor3 = Color3.fromRGB(18, 20, 25), BorderSizePixel = 0,
    ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0),
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, list)
mk("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local presetPanel = mk("Frame", {
    Size = UDim2.new(1, 0, 0, #PRESETS * 26 + 6), Position = UDim2.new(0, 0, 0, 62),
    BackgroundColor3 = Color3.fromRGB(30, 33, 41), BorderSizePixel = 0,
    Visible = false, ZIndex = 5,
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, presetPanel)
mk("UIStroke", { Color = Color3.fromRGB(90, 80, 50), Thickness = 1 }, presetPanel)

local filesPanel = mk("ScrollingFrame", {
    Size = UDim2.new(1, 0, 1, -248), Position = UDim2.new(0, 0, 0, 216),
    BackgroundColor3 = Color3.fromRGB(28, 31, 40), BorderSizePixel = 0,
    ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0),
    Visible = false, ZIndex = 5,
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, filesPanel)
mk("UIStroke", { Color = Color3.fromRGB(70, 80, 120), Thickness = 1 }, filesPanel)
mk("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, filesPanel)

local status = mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 1, -28),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
    TextColor3 = Color3.fromRGB(150, 200, 170), TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, Text = "готов",
}, body)

local function setStatus(t, good)
    status.Text = t
    status.TextColor3 = (good == false) and Color3.fromRGB(230, 130, 130)
                                        or Color3.fromRGB(150, 200, 170)
end

local function stepLabel(i, s)
    if s.type == "remote" then
        return string.format("%d. %s  (+%ss)", i, s.title or "REMOTE", tostring(CFG.PostRemoteWait))
    elseif s.type == "wait" then
        return string.format("%d. ПАУЗА %.1f сек", i, s.time or 2)
    end
    return string.format("%d. POS  %d, %d, %d", i,
        math.floor(s.pos.X), math.floor(s.pos.Y), math.floor(s.pos.Z))
end

local function copyStep(s)
    local c = {
        type       = s.type,
        pos        = s.pos,
        time       = s.time,
        title      = s.title,
        method     = s.method,
        remote     = s.remote,
        remotePath = s.remotePath,
        remoteRef  = s.remoteRef,
    }
    if s.args then
        local a = { n = s.args.n }
        for i = 1, s.args.n do a[i] = s.args[i] end
        c.args = a
    end
    if s.argRefs then
        local r = {}
        for i, v in pairs(s.argRefs) do r[i] = v end
        c.argRefs = r
    end
    return c
end

local clipStep = nil

local function refreshList()
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    for i, s in ipairs(steps) do
        local row = mk("Frame", {
            Size = UDim2.new(1, -8, 0, 22), BackgroundColor3 = Color3.fromRGB(30, 33, 41),
            BorderSizePixel = 0, LayoutOrder = i,
        }, list)
        mk("UICorner", { CornerRadius = UDim.new(0, 4) }, row)
        mk("TextLabel", {
            Size = UDim2.new(1, -70, 1, 0), Position = UDim2.new(0, 6, 0, 0),
            BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = (s.type == "remote") and COL_REMOTE
                       or (s.type == "wait") and Color3.fromRGB(190, 190, 200)
                       or Color3.fromRGB(150, 210, 235),
            Text = stepLabel(i, s), TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)

        local dup = mk("TextButton", {
            Size = UDim2.new(0, 20, 0, 18), Position = UDim2.new(1, -66, 0, 2),
            BackgroundColor3 = Color3.fromRGB(40, 60, 80), BorderSizePixel = 0,
            Font = Enum.Font.GothamBold, TextSize = 10,
            TextColor3 = Color3.fromRGB(210, 230, 255), Text = "++",
        }, row)
        mk("UICorner", { CornerRadius = UDim.new(0, 4) }, dup)

        local cp = mk("TextButton", {
            Size = UDim2.new(0, 20, 0, 18), Position = UDim2.new(1, -44, 0, 2),
            BackgroundColor3 = Color3.fromRGB(55, 55, 70), BorderSizePixel = 0,
            Font = Enum.Font.GothamBold, TextSize = 10,
            TextColor3 = Color3.fromRGB(225, 225, 240), Text = "C",
        }, row)
        mk("UICorner", { CornerRadius = UDim.new(0, 4) }, cp)

        local del = mk("TextButton", {
            Size = UDim2.new(0, 20, 0, 18), Position = UDim2.new(1, -22, 0, 2),
            BackgroundColor3 = Color3.fromRGB(80, 40, 45), BorderSizePixel = 0,
            Font = Enum.Font.GothamBold, TextSize = 11,
            TextColor3 = Color3.fromRGB(255, 210, 210), Text = "x",
        }, row)
        mk("UICorner", { CornerRadius = UDim.new(0, 4) }, del)

        dup.MouseButton1Click:Connect(function()
            table.insert(steps, i + 1, copyStep(s))
            refreshList(); drawRoute()
            setStatus("шаг " .. i .. " продублирован")
        end)
        cp.MouseButton1Click:Connect(function()
            clipStep = copyStep(s)
            setStatus("шаг " .. i .. " скопирован, жми «Вставить»")
        end)
        del.MouseButton1Click:Connect(function()
            table.remove(steps, i)
            refreshList(); drawRoute()
        end)
    end
    list.CanvasSize = UDim2.new(0, 0, 0, #steps * 24 + 4)
end

boxWait.FocusLost:Connect(function()
    local v = tonumber(boxWait.Text)
    if v and v >= 0 then CFG.PostRemoteWait = v end
    boxWait.Text = tostring(CFG.PostRemoteWait)
    refreshList()
end)

local minimized = false
btnMin.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    main.Size = minimized and UDim2.new(0, 330, 0, 34) or UDim2.new(0, 330, 0, 480)
    btnMin.Text = minimized and "+" or "-"
end)

local function addPosition()
    local hrp = getHRP()
    if not hrp then setStatus("нет персонажа", false) return end
    table.insert(steps, { type = "move", pos = hrp.Position })
    refreshList(); drawRoute()
    setStatus("записана точка #" .. #steps)
end

local function addRemoteFromLast()
    if not hookOk then
        setStatus("хук remote не поддерживается executor'ом, используй «+ Действие»", false)
        return
    end
    if not lastFired then
        setStatus("сделай в игре одно из 3 разрешённых действий", false)
        return
    end
    local hrp = getHRP()
    local argRefs = {}
    for i = 1, lastFired.args.n do
        argRefs[i] = makeRef(lastFired.args[i]) or false
    end
    local argName = argRefs[1] and refToString(argRefs[1]):match("[^%.]+$") or ""
    table.insert(steps, {
        type       = "remote",
        pos        = hrp and hrp.Position or Vector3.new(),
        title      = lastFired.remote.Name .. (argName ~= "" and (" > " .. argName) or ""),
        remote     = lastFired.remote,
        remotePath = fullName(lastFired.remote),
        remoteRef  = makeRef(lastFired.remote),
        method     = lastFired.method,
        args       = lastFired.args,
        argRefs    = argRefs,
    })
    refreshList(); drawRoute()
    setStatus("записан remote: " .. lastFired.remote.Name)
end

local function addPreset(p)
    local hrp = getHRP()
    local remote = resolvePath(p.remotePath)
    local vals, n = p.args()
    local args, argRefs = { n = n }, {}
    for i = 1, n do
        args[i]    = vals[i]
        argRefs[i] = makeRef(vals[i]) or false
    end
    table.insert(steps, {
        type       = "remote",
        pos        = hrp and hrp.Position or Vector3.new(),
        title      = p.title,
        remote     = remote,
        remotePath = p.remotePath,
        remoteRef  = makeRef(remote),
        method     = "FireServer",
        args       = args,
        argRefs    = argRefs,
    })
    refreshList(); drawRoute()
    if remote and args[1] then
        setStatus("добавлено: " .. p.title)
    else
        setStatus("добавлено: " .. p.title .. " (объект не найден сейчас)", false)
    end
end

for i, p in ipairs(PRESETS) do
    local b = mk("TextButton", {
        Size = UDim2.new(1, -8, 0, 22), Position = UDim2.new(0, 4, 0, (i - 1) * 26 + 4),
        BackgroundColor3 = Color3.fromRGB(45, 50, 62), BorderSizePixel = 0,
        Font = Enum.Font.Gotham, TextSize = 11, ZIndex = 6,
        TextColor3 = Color3.fromRGB(235, 225, 200), Text = p.title,
    }, presetPanel)
    mk("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
    b.MouseButton1Click:Connect(function()
        addPreset(p)
        presetPanel.Visible = false
    end)
end

bPresets.MouseButton1Click:Connect(function()
    presetPanel.Visible = not presetPanel.Visible
end)

local function addWait()
    local hrp = getHRP()
    table.insert(steps, { type = "wait", time = CFG.PostRemoteWait,
                          pos = hrp and hrp.Position or Vector3.new() })
    refreshList(); drawRoute()
end

bRecPos.MouseButton1Click:Connect(addPosition)
bRecRemote.MouseButton1Click:Connect(addRemoteFromLast)
bWait.MouseButton1Click:Connect(addWait)

bClear.MouseButton1Click:Connect(function()
    steps = {}
    refreshList()
    clearFolder(routeFolder); clearFolder(planFolder)
    setStatus("маршрут очищен")
end)

local function serialize()
    local out = {}
    for _, s in ipairs(steps) do
        local e = {
            type = s.type,
            pos  = { s.pos.X, s.pos.Y, s.pos.Z },
            time = s.time,
        }
        if s.type == "remote" then
            e.title      = s.title
            e.method     = s.method
            e.remotePath = s.remotePath
            e.remoteRef  = s.remoteRef
            e.argsN      = s.args and s.args.n or 0
            e.args       = {}
            for i = 1, e.argsN do
                local v, ref = s.args[i], s.argRefs and s.argRefs[i]
                if ref then
                    e.args[i] = { t = "Instance", v = ref }
                elseif typeof(v) == "Vector3" then
                    e.args[i] = { t = "Vector3", v = { v.X, v.Y, v.Z } }
                elseif type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
                    e.args[i] = { t = "raw", v = v }
                else
                    e.args[i] = { t = "nil" }
                end
            end
        end
        table.insert(out, e)
    end
    return HttpService:JSONEncode(out)
end

local function deserialize(json)
    local ok, data = pcall(function() return HttpService:JSONDecode(json) end)
    if not ok or type(data) ~= "table" then return false end
    local new = {}
    for _, e in ipairs(data) do
        local s = {
            type = e.type,
            pos  = Vector3.new(e.pos[1], e.pos[2], e.pos[3]),
            time = e.time,
        }
        if e.type == "remote" then
            s.title      = e.title
            s.method     = e.method or "FireServer"
            s.remotePath = e.remotePath
            s.remoteRef  = e.remoteRef
            s.remote     = resolveRef(e.remoteRef) or resolvePath(e.remotePath)
            local n      = e.argsN or 0
            local args, refs = { n = n }, {}
            for i = 1, n do
                local a = (e.args or {})[i]
                if a and a.t == "Instance" then
                    args[i], refs[i] = resolveRef(a.v), a.v
                elseif a and a.t == "Vector3" then
                    args[i], refs[i] = Vector3.new(a.v[1], a.v[2], a.v[3]), false
                elseif a and a.t == "raw" then
                    args[i], refs[i] = a.v, false
                else
                    args[i], refs[i] = nil, false
                end
            end
            s.args, s.argRefs = args, refs
        end
        table.insert(new, s)
    end
    steps = new
    refreshList(); drawRoute()
    return true
end

local FOLDER = "PathBot"

local function fsReady()
    if not (writefile and readfile and isfile) then return false end
    if isfolder and makefolder and not isfolder(FOLDER) then
        pcall(makefolder, FOLDER)
    end
    return true
end

local function sanitize(name)
    name = tostring(name or ""):gsub('[/\\:*?"<>|]', "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    return name
end

local function savePreset(name)
    if not fsReady() then setStatus("executor не поддерживает файлы", false) return end
    name = sanitize(name)
    if name == "" then name = "route_" .. os.date("%H%M%S") end
    if #steps == 0 then setStatus("маршрут пуст, нечего сохранять", false) return end
    local path = FOLDER .. "/" .. name .. ".json"
    local ok = pcall(writefile, path, serialize())
    if ok then
        boxName.Text = name
        setStatus("сохранено: " .. path)
    else
        setStatus("не удалось сохранить " .. path, false)
    end
end

local function loadPreset(path)
    local ok, json = pcall(readfile, path)
    if ok and json and deserialize(json) then
        setStatus("загружено: " .. path .. " (" .. #steps .. " шагов)")
    else
        setStatus("не удалось прочитать " .. path, false)
    end
end

local function listPresets()
    if not (listfiles and fsReady()) then return {} end
    local ok, files = pcall(listfiles, FOLDER)
    if not ok or type(files) ~= "table" then return {} end
    local out = {}
    for _, f in ipairs(files) do
        if tostring(f):sub(-5) == ".json" then table.insert(out, f) end
    end
    table.sort(out)
    return out
end

local function refreshFiles()
    for _, c in ipairs(filesPanel:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    local files = listPresets()
    for i, path in ipairs(files) do
        local short = tostring(path):match("[^/\\]+$") or path
        short = short:gsub("%.json$", "")
        local row = mk("Frame", {
            Size = UDim2.new(1, -8, 0, 24), BackgroundColor3 = Color3.fromRGB(38, 42, 54),
            BorderSizePixel = 0, LayoutOrder = i, ZIndex = 6,
        }, filesPanel)
        mk("UICorner", { CornerRadius = UDim.new(0, 4) }, row)
        local load = mk("TextButton", {
            Size = UDim2.new(1, -26, 1, 0), Position = UDim2.new(0, 0, 0, 0),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7,
            TextColor3 = Color3.fromRGB(225, 230, 250), Text = "  " .. short,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
        local del = mk("TextButton", {
            Size = UDim2.new(0, 20, 0, 18), Position = UDim2.new(1, -23, 0, 3),
            BackgroundColor3 = Color3.fromRGB(80, 40, 45), BorderSizePixel = 0,
            Font = Enum.Font.GothamBold, TextSize = 11, ZIndex = 7,
            TextColor3 = Color3.fromRGB(255, 210, 210), Text = "x",
        }, row)
        mk("UICorner", { CornerRadius = UDim.new(0, 4) }, del)
        load.MouseButton1Click:Connect(function()
            loadPreset(path)
            boxName.Text = short
            filesPanel.Visible = false
        end)
        del.MouseButton1Click:Connect(function()
            if delfile then pcall(delfile, path) end
            refreshFiles()
            setStatus("удалён пресет " .. short)
        end)
    end
    if #files == 0 then
        local row = mk("Frame", {
            Size = UDim2.new(1, -8, 0, 24), BackgroundTransparency = 1,
            LayoutOrder = 1, ZIndex = 6,
        }, filesPanel)
        mk("TextLabel", {
            Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ZIndex = 7,
            Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Color3.fromRGB(170, 170, 190),
            Text = "  пресетов пока нет",
            TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
    end
    filesPanel.CanvasSize = UDim2.new(0, 0, 0, math.max(#files, 1) * 26 + 4)
end

bSave.MouseButton1Click:Connect(function()
    savePreset(boxName.Text)
    if filesPanel.Visible then refreshFiles() end
end)

bFiles.MouseButton1Click:Connect(function()
    filesPanel.Visible = not filesPanel.Visible
    if filesPanel.Visible then
        presetPanel.Visible = false
        refreshFiles()
    end
end)

boxName.FocusLost:Connect(function(enter)
    if enter then savePreset(boxName.Text) end
end)

bCopy.MouseButton1Click:Connect(function()
    local json = serialize()
    local ok = pcall(function() setclipboard(json) end)
    if not ok then pcall(function() toclipboard(json) end) end
    pcall(function() writefile("PathBot_route.json", json) end)
    setStatus("маршрут скопирован (PathBot_route.json)")
end)

bPaste.MouseButton1Click:Connect(function()
    if clipStep then
        table.insert(steps, copyStep(clipStep))
        refreshList(); drawRoute()
        setStatus("шаг вставлен в конец")
        return
    end
    local json
    pcall(function() json = (getclipboard or readclipboard)() end)
    if (not json or json == "") then
        pcall(function() json = readfile("PathBot_route.json") end)
    end
    if json and deserialize(json) then
        setStatus("загружено шагов: " .. #steps)
    else
        setStatus("нечего вставлять", false)
    end
end)

local function beginFlight()
    local hum = getHum()
    if hum and CFG.PlatformStand then hum.PlatformStand = true end
end

local function endFlight()
    local hum = getHum()
    if hum then hum.PlatformStand = false end
    clearFolder(planFolder)
end

local function stopRoute()
    playing = false
    bPlay.Text = "> Играть  (F3)"
    endFlight()
    setStatus("стоп")
end

local function playRoute()
    if playing then return end
    if #steps == 0 then setStatus("маршрут пуст", false) return end
    playing = true
    bPlay.Text = "> Играет..."
    beginFlight()

    task.spawn(function()
        repeat
            for i, s in ipairs(steps) do
                if not playing then break end
                setStatus(string.format("шаг %d/%d", i, #steps))

                if s.pos then
                    if not travelTo(s.pos) and playing then
                        setStatus("не дошёл до точки " .. i .. ", иду дальше", false)
                    end
                end
                if not playing then break end

                if s.type == "remote" then
                    local ok, err = fireStep(s)
                    if not ok then
                        setStatus("ошибка remote: " .. tostring(err), false)
                    else
                        setStatus(string.format("%s отправлен, пауза %.1f с",
                            s.title or "remote", CFG.PostRemoteWait))
                    end
                    local t = 0
                    while playing and t < CFG.PostRemoteWait do
                        t = t + RunService.Heartbeat:Wait()
                        local hrp = getHRP()
                        if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
                    end
                elseif s.type == "wait" then
                    local t = 0
                    while playing and t < (s.time or 2) do
                        t = t + RunService.Heartbeat:Wait()
                    end
                end
            end
        until (not playing) or (not CFG.Loop)

        playing = false
        bPlay.Text = "> Играть  (F3)"
        endFlight()
        setStatus("готово")
    end)
end

bPlay.MouseButton1Click:Connect(playRoute)
bStop.MouseButton1Click:Connect(stopRoute)

btnClose.MouseButton1Click:Connect(function()
    stopRoute()
    task.wait(0.1)
    vizFolder:Destroy()
    gui:Destroy()
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.F1 then
        addPosition()
    elseif input.KeyCode == Enum.KeyCode.F2 then
        addRemoteFromLast()
    elseif input.KeyCode == Enum.KeyCode.F3 then
        if playing then stopRoute() else playRoute() end
    end
end)

LP.CharacterAdded:Connect(function()
    task.wait(1)
    if playing then beginFlight() end
end)

refreshList()
setStatus(hookOk and "готов, ловлю только 3 разрешённых remote"
                  or "готов, хук недоступен - используй «+ Действие»")
print("[PathBot] F1 - точка, F2 - remote, F3 - старт/стоп")

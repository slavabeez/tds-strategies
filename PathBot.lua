--// ==========================================================================
--//  PathBot - запись и воспроизведение маршрута  (Roblox executor script)
--//  Горячие клавиши:  F1 - записать позицию | F2 - записать последний Remote
--//                    F3 - старт/стоп воспроизведения
--// ==========================================================================

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")

local LP = Players.LocalPlayer

----------------------------------------------------------------------------
-- НАСТРОЙКИ
----------------------------------------------------------------------------
local CFG = {
    Speed          = 45,    -- скорость полёта, ст/сек
    ClimbSpeed     = 40,    -- скорость набора высоты при упоре в препятствие
    ArriveDist     = 2.0,   -- радиус "точка достигнута"
    ClearanceAbove = 7,     -- на сколько выше препятствия лететь
    MaxClimb       = 80,    -- максимальный подъём над точками маршрута
    ScanUp         = 150,   -- высота сканирования препятствий
    LookAhead      = 6,     -- дистанция проверки препятствия по курсу
    PostRemoteWait = 2,     -- ПАУЗА ПОСЛЕ REMOTE (сек)
    StuckTimeout   = 15,    -- защита от застревания на одном отрезке
    Loop           = false, -- зациклить маршрут
    ShowPath       = true,  -- рисовать траекторию
    PlatformStand  = true,  -- отключать физику персонажа на время полёта
}

-- Пример remote из задания (кнопка "+ Remote (пример)")
local EXAMPLE = {
    remotePath = "ReplicatedStorage.__remotes.WorldBuyableItemService.PurchaseWorldBuyableItem",
    argPaths   = { "Workspace.WorldBuyableItems.CivilianArea.Crate Of Avacados" },
}

----------------------------------------------------------------------------
-- УТИЛИТЫ
----------------------------------------------------------------------------
local function getChar()
    return LP.Character
end
local function getHRP()
    local c = getChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

-- путь вида "Workspace.Folder.Item" -> Instance
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

local function fullName(inst)
    local ok, n = pcall(function() return inst:GetFullName() end)
    return ok and n or nil
end

----------------------------------------------------------------------------
-- ХРАНИЛИЩЕ ШАГОВ
-- step = { type = "move"|"remote"|"wait", pos = Vector3,
--          remote = Instance, remotePath = string, method = "FireServer",
--          args = {n=..,...}, argPaths = { [i] = string|false } }
----------------------------------------------------------------------------
local steps   = {}
local playing = false

----------------------------------------------------------------------------
-- ХУК NAMECALL: ловим последний вызванный игрой Remote
----------------------------------------------------------------------------
local lastFired = nil
local hookOk = false

do
    local ok = pcall(function()
        local getnamecall = getnamecallmethod
        local iscaller    = checkcaller
        local newcc       = newcclosure or function(f) return f end
        if not getnamecall then error("no getnamecallmethod") end

        local function capture(self, method, ...)
            if (method == "FireServer" or method == "InvokeServer")
               and typeof(self) == "Instance"
               and (not iscaller or not iscaller()) then
                lastFired = { remote = self, method = method, args = table.pack(...) }
            end
        end

        if hookmetamethod then
            local old
            old = hookmetamethod(game, "__namecall", newcc(function(self, ...)
                capture(self, getnamecall(), ...)
                return old(self, ...)
            end))
            hookOk = true
        else
            local mt  = getrawmetatable(game)
            setreadonly(mt, false)
            local old = mt.__namecall
            mt.__namecall = newcc(function(self, ...)
                capture(self, getnamecall(), ...)
                return old(self, ...)
            end)
            setreadonly(mt, true)
            hookOk = true
        end
    end)
    if not ok then hookOk = false end
end

----------------------------------------------------------------------------
-- ВИЗУАЛИЗАЦИЯ ТРАЕКТОРИИ
----------------------------------------------------------------------------
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
        bb.Size = UDim2.new(0, 60, 0, 20)
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

----------------------------------------------------------------------------
-- ГЕОМЕТРИЯ / ОБЛЁТ ПРЕПЯТСТВИЙ
----------------------------------------------------------------------------
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

-- максимальная высота "крыши" препятствий на отрезке
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

-- список промежуточных точек от a до b с облётом препятствия сверху
local function planPath(a, b)
    local up = Vector3.new(0, 1.5, 0)
    if not blocked(a + up, b + up) then
        return { b }
    end
    local y = topOnSegment(a, b) + CFG.ClearanceAbove
    y = math.min(y, math.max(a.Y, b.Y) + CFG.MaxClimb)
    y = math.max(y, a.Y + 2, b.Y + 2)
    return {
        Vector3.new(a.X, y, a.Z),   -- подъём
        Vector3.new(b.X, y, b.Z),   -- перелёт поверху
        b,                          -- спуск к цели
    }
end

----------------------------------------------------------------------------
-- ПОЛЁТ
----------------------------------------------------------------------------
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
                -- упёрлись в объект — набираем высоту, затем продолжаем движение
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

----------------------------------------------------------------------------
-- ВЫЗОВ REMOTE
----------------------------------------------------------------------------
local function buildArgs(step)
    local packed = step.args or { n = 0 }
    local out = table.create(packed.n)
    for i = 1, packed.n do
        local v = packed[i]
        local path = step.argPaths and step.argPaths[i]
        -- если инстанс пропал (объект респавнился) — ищем заново по пути
        if path and (typeof(v) ~= "Instance" or not v.Parent) then
            v = resolvePath(path)
        end
        out[i] = v
    end
    return out, packed.n
end

local function fireStep(step)
    local remote = step.remote
    if typeof(remote) ~= "Instance" or not remote.Parent then
        remote = resolvePath(step.remotePath)
        step.remote = remote
    end
    if not remote then return false, "remote не найден: " .. tostring(step.remotePath) end

    local args, n = buildArgs(step)
    local ok, err = pcall(function()
        if step.method == "InvokeServer" then
            return remote:InvokeServer(table.unpack(args, 1, n))
        else
            return remote:FireServer(table.unpack(args, 1, n))
        end
    end)
    return ok, err
end

----------------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------------
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
    Size = UDim2.new(0, 320, 0, 430),
    Position = UDim2.new(0, 30, 0.5, -215),
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
    Text = "PathBot  ·  маршрут + remote",
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

-- перетаскивание окна
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
local bExample   = button("+ Remote (пример)", 32, 0.5,  0,    Color3.fromRGB(70, 60, 40))
local bWait      = button("+ Пауза",           32, 0.5,  0.5,  Color3.fromRGB(50, 50, 62))
local bPlay      = button("> Играть  (F3)",    64, 0.5,  0,    Color3.fromRGB(35, 95, 55))
local bStop      = button("[] Стоп",           64, 0.5,  0.5,  Color3.fromRGB(110, 45, 45))
local bClear     = button("Очистить",          96, 0.34, 0)
local bCopy      = button("Копировать",        96, 0.33, 0.34)
local bPaste     = button("Вставить",          96, 0.33, 0.67)

-- переключатели
local function toggle(text, y, x, w, key, onChange)
    local b = mk("TextButton", {
        Size = UDim2.new(w, -4, 0, 24), Position = UDim2.new(x, 0, 0, y),
        BackgroundColor3 = Color3.fromRGB(40, 44, 55), BorderSizePixel = 0,
        Font = Enum.Font.Gotham, TextSize = 11,
        TextColor3 = Color3.fromRGB(210, 210, 225), Text = "",
    }, body)
    mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    local function upd()
        b.Text = (CFG[key] and "[+] " or "[  ] ") .. text
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

-- ссылки заполним ниже (drawRoute уже объявлена)
toggle("Зациклить", 128, 0, 0.5, "Loop", function() drawRoute() end)
toggle("Траектория", 128, 0.5, 0.5, "ShowPath", function()
    if not CFG.ShowPath then clearFolder(routeFolder); clearFolder(planFolder) end
    drawRoute()
end)

-- скорость
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

-- список шагов
local list = mk("ScrollingFrame", {
    Size = UDim2.new(1, 0, 1, -218), Position = UDim2.new(0, 0, 0, 186),
    BackgroundColor3 = Color3.fromRGB(18, 20, 25), BorderSizePixel = 0,
    ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0),
}, body)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, list)
mk("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)

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
        local name = s.remotePath and s.remotePath:match("[^%.]+$") or "?"
        return string.format("%d. REMOTE %s (+%ss)", i, name, tostring(CFG.PostRemoteWait))
    elseif s.type == "wait" then
        return string.format("%d. ПАУЗА %.1f сек", i, s.time or 2)
    end
    return string.format("%d. POS  %d, %d, %d", i,
        math.floor(s.pos.X), math.floor(s.pos.Y), math.floor(s.pos.Z))
end

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
            Size = UDim2.new(1, -28, 1, 0), Position = UDim2.new(0, 6, 0, 0),
            BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = (s.type == "remote") and COL_REMOTE
                       or (s.type == "wait") and Color3.fromRGB(190, 190, 200)
                       or Color3.fromRGB(150, 210, 235),
            Text = stepLabel(i, s), TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
        local del = mk("TextButton", {
            Size = UDim2.new(0, 20, 0, 18), Position = UDim2.new(1, -24, 0, 2),
            BackgroundColor3 = Color3.fromRGB(80, 40, 45), BorderSizePixel = 0,
            Font = Enum.Font.GothamBold, TextSize = 11,
            TextColor3 = Color3.fromRGB(255, 210, 210), Text = "x",
        }, row)
        mk("UICorner", { CornerRadius = UDim.new(0, 4) }, del)
        del.MouseButton1Click:Connect(function()
            table.remove(steps, i)
            refreshList()
            drawRoute()
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

-- сворачивание
local minimized = false
btnMin.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    main.Size = minimized and UDim2.new(0, 320, 0, 34) or UDim2.new(0, 320, 0, 430)
    btnMin.Text = minimized and "+" or "-"
end)

----------------------------------------------------------------------------
-- ДЕЙСТВИЯ КНОПОК
----------------------------------------------------------------------------
local function addPosition()
    local hrp = getHRP()
    if not hrp then setStatus("нет персонажа", false) return end
    table.insert(steps, { type = "move", pos = hrp.Position })
    refreshList(); drawRoute()
    setStatus("записана точка #" .. #steps)
end

local function addRemoteFromLast()
    if not hookOk then
        setStatus("хук remote не поддерживается executor'ом", false)
        return
    end
    if not lastFired then
        setStatus("сначала сделай действие в игре (покупку и т.п.)", false)
        return
    end
    local hrp = getHRP()
    local argPaths = {}
    for i = 1, lastFired.args.n do
        local v = lastFired.args[i]
        argPaths[i] = (typeof(v) == "Instance") and fullName(v) or false
    end
    table.insert(steps, {
        type       = "remote",
        pos        = hrp and hrp.Position or Vector3.new(),
        remote     = lastFired.remote,
        remotePath = fullName(lastFired.remote),
        method     = lastFired.method,
        args       = lastFired.args,
        argPaths   = argPaths,
    })
    refreshList(); drawRoute()
    setStatus("записан remote: " .. tostring(fullName(lastFired.remote)))
end

local function addExampleRemote()
    local hrp = getHRP()
    local remote = resolvePath(EXAMPLE.remotePath)
    local args, argPaths = { n = #EXAMPLE.argPaths }, {}
    for i, p in ipairs(EXAMPLE.argPaths) do
        args[i]     = resolvePath(p)
        argPaths[i] = p
    end
    table.insert(steps, {
        type       = "remote",
        pos        = hrp and hrp.Position or Vector3.new(),
        remote     = remote,
        remotePath = EXAMPLE.remotePath,
        method     = "FireServer",
        args       = args,
        argPaths   = argPaths,
    })
    refreshList(); drawRoute()
    setStatus(remote and "добавлен remote-пример"
                      or "remote-пример добавлен (объект пока не найден)", remote ~= nil)
end

local function addWait()
    local hrp = getHRP()
    table.insert(steps, { type = "wait", time = CFG.PostRemoteWait,
                          pos = hrp and hrp.Position or Vector3.new() })
    refreshList(); drawRoute()
end

bRecPos.MouseButton1Click:Connect(addPosition)
bRecRemote.MouseButton1Click:Connect(addRemoteFromLast)
bExample.MouseButton1Click:Connect(addExampleRemote)
bWait.MouseButton1Click:Connect(addWait)

bClear.MouseButton1Click:Connect(function()
    steps = {}
    refreshList()
    clearFolder(routeFolder); clearFolder(planFolder)
    setStatus("маршрут очищен")
end)

----------------------------------------------------------------------------
-- СОХРАНЕНИЕ / ЗАГРУЗКА (буфер обмена + файл)
----------------------------------------------------------------------------
local function serialize()
    local out = {}
    for _, s in ipairs(steps) do
        local e = {
            type = s.type,
            pos  = { s.pos.X, s.pos.Y, s.pos.Z },
            time = s.time,
        }
        if s.type == "remote" then
            e.remotePath = s.remotePath
            e.method     = s.method
            e.args       = {}
            e.argsN      = s.args and s.args.n or 0
            for i = 1, e.argsN do
                local v, p = s.args[i], s.argPaths and s.argPaths[i]
                if p then
                    e.args[i] = { t = "Instance", v = p }
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
            s.remotePath = e.remotePath
            s.method     = e.method or "FireServer"
            s.remote     = resolvePath(e.remotePath)
            local n      = e.argsN or 0
            local args   = { n = n }
            local paths  = {}
            for i = 1, n do
                local a = (e.args or {})[i]
                if a and a.t == "Instance" then
                    args[i], paths[i] = resolvePath(a.v), a.v
                elseif a and a.t == "Vector3" then
                    args[i], paths[i] = Vector3.new(a.v[1], a.v[2], a.v[3]), false
                elseif a and a.t == "raw" then
                    args[i], paths[i] = a.v, false
                else
                    args[i], paths[i] = nil, false
                end
            end
            s.args, s.argPaths = args, paths
        end
        table.insert(new, s)
    end
    steps = new
    refreshList(); drawRoute()
    return true
end

bCopy.MouseButton1Click:Connect(function()
    local json = serialize()
    local ok = pcall(function() setclipboard(json) end)
    if not ok then pcall(function() toclipboard(json) end) end
    pcall(function() writefile("PathBot_route.json", json) end)
    setStatus("маршрут скопирован (и в PathBot_route.json)")
end)

bPaste.MouseButton1Click:Connect(function()
    local json
    pcall(function() json = (getclipboard or readclipboard)() end)
    if (not json or json == "") then
        pcall(function() json = readfile("PathBot_route.json") end)
    end
    if json and deserialize(json) then
        setStatus("загружено шагов: " .. #steps)
    else
        setStatus("не удалось прочитать маршрут", false)
    end
end)

----------------------------------------------------------------------------
-- ВОСПРОИЗВЕДЕНИЕ
----------------------------------------------------------------------------
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
                setStatus(string.format("шаг %d/%d — %s", i, #steps, s.type))

                if s.pos then
                    if not travelTo(s.pos) and playing then
                        setStatus("не смог дойти до точки " .. i .. ", иду дальше", false)
                    end
                end
                if not playing then break end

                if s.type == "remote" then
                    local ok, err = fireStep(s)
                    if not ok then
                        setStatus("ошибка remote: " .. tostring(err), false)
                    else
                        setStatus(string.format("remote отправлен, пауза %.1f с", CFG.PostRemoteWait))
                    end
                    -- ПАУЗА ПОСЛЕ REMOTE (по умолчанию 2 сек), стоим на месте
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

----------------------------------------------------------------------------
-- ГОРЯЧИЕ КЛАВИШИ
----------------------------------------------------------------------------
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
setStatus(hookOk and "готов · remote-хук активен"
                  or "готов · хук недоступен, жми «+ Remote (пример)»")
print("[PathBot] загружен. F1 - точка, F2 - remote, F3 - старт/стоп")

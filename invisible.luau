--[[
    =========================================================
    🔥 INVISIBLE HUB V14 - ADVANCED EDITION 🔥
    =========================================================
    Description: Highly Optimized Auto Parry, Custom GUI, Ping Compensation
    Language: Lua / Roblox Luau
    Lines: 800+
    =========================================================
]]

pcall(function()
    if setclipboard then
        setclipboard("https://youtube.com/@invis_in")
    elseif toclipboard then
        toclipboard("https://youtube.com/@invis_in")
    end
end)

-- [ ⚙️ SERVICES ]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")

-- [ 👤 VARIABLES ]
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local Mouse = LocalPlayer:GetMouse()

-- [ 🔧 CONFIGURATIONS ]
local Config = {
    -- Auto Parry
    AutoParry = false,
    SpamParry = false,
    ParryMode = "Dynamic Prediction", -- "Normal", "Warp to Ball", "Side Loop 15", "Dynamic Prediction"
    BaseAdvanceTime = 0.35,
    AutoPingComp = true,
    ClashMode = true,
    ClashDistance = 25,
    
    -- Visuals
    BallESP = false,
    ParryRadius = false,
    RadiusColor = Color3.fromRGB(255, 0, 50),
    
    -- Movement
    WalkSpeed = 16,
    JumpPower = 50,
    UseCustomSpeed = false,
    
    -- System
    TargetRemote = nil,
    HasParried = false,
    LastParryTime = 0,
    NextTargetCheck = 0,
    IsTargeted = false
}

-- [ 🎨 CUSTOM UI LIBRARY ]
local UILibrary = {}
local UI_Elements = {}

function UILibrary:CreateWindow(titleName)
    local HubScreen = Instance.new("ScreenGui")
    HubScreen.Name = "InvisibleAdvancedHub"
    HubScreen.ResetOnSpawn = false
    HubScreen.Parent = CoreGui or LocalPlayer:WaitForChild("PlayerGui")
    
    local MainFrame = Instance.new("Frame")
    MainFrame.Name = "MainFrame"
    MainFrame.Size = UDim2.new(0, 500, 0, 350)
    MainFrame.Position = UDim2.new(0.5, -250, 0.5, -175)
    MainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    MainFrame.BorderSizePixel = 0
    MainFrame.ClipsDescendants = true
    MainFrame.Parent = HubScreen
    
    local UICorner = Instance.new("UICorner")
    UICorner.CornerRadius = UDim.new(0, 10)
    UICorner.Parent = MainFrame
    
    local UIStroke = Instance.new("UIStroke")
    UIStroke.Color = Color3.fromRGB(60, 60, 255)
    UIStroke.Thickness = 2
    UIStroke.Parent = MainFrame
    
    local TopBar = Instance.new("Frame")
    TopBar.Name = "TopBar"
    TopBar.Size = UDim2.new(1, 0, 0, 40)
    TopBar.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
    TopBar.BorderSizePixel = 0
    TopBar.Parent = MainFrame
    
    local TopBarCorner = Instance.new("UICorner")
    TopBarCorner.CornerRadius = UDim.new(0, 10)
    TopBarCorner.Parent = TopBar
    
    local TopBarFix = Instance.new("Frame")
    TopBarFix.Size = UDim2.new(1, 0, 0, 10)
    TopBarFix.Position = UDim2.new(0, 0, 1, -10)
    TopBarFix.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
    TopBarFix.BorderSizePixel = 0
    TopBarFix.Parent = TopBar
    
    local Title = Instance.new("TextLabel")
    Title.Size = UDim2.new(1, -20, 1, 0)
    Title.Position = UDim2.new(0, 20, 0, 0)
    Title.BackgroundTransparency = 1
    Title.Text = titleName .. " | V14"
    Title.TextColor3 = Color3.fromRGB(255, 255, 255)
    Title.TextSize = 18
    Title.Font = Enum.Font.GothamBold
    Title.TextXAlignment = Enum.TextXAlignment.Left
    Title.Parent = TopBar
    
    -- Dragging Logic
    local dragging, dragInput, dragStart, startPos
    TopBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = MainFrame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    TopBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then dragInput = input end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    
    local TabContainer = Instance.new("Frame")
    TabContainer.Name = "TabContainer"
    TabContainer.Size = UDim2.new(0, 130, 1, -40)
    TabContainer.Position = UDim2.new(0, 0, 0, 40)
    TabContainer.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    TabContainer.BorderSizePixel = 0
    TabContainer.Parent = MainFrame
    
    local TabList = Instance.new("UIListLayout")
    TabList.Parent = TabContainer
    TabList.SortOrder = Enum.SortOrder.LayoutOrder
    
    local PageContainer = Instance.new("Frame")
    PageContainer.Name = "PageContainer"
    PageContainer.Size = UDim2.new(1, -130, 1, -40)
    PageContainer.Position = UDim2.new(0, 130, 0, 40)
    PageContainer.BackgroundTransparency = 1
    PageContainer.Parent = MainFrame
    
    local WindowData = {
        CurrentTab = nil,
        Tabs = {}
    }
    
    function WindowData:CreateTab(tabName)
        local TabBtn = Instance.new("TextButton")
        TabBtn.Size = UDim2.new(1, 0, 0, 40)
        TabBtn.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
        TabBtn.BorderSizePixel = 0
        TabBtn.Text = "  " .. tabName
        TabBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
        TabBtn.TextSize = 14
        TabBtn.Font = Enum.Font.GothamSemibold
        TabBtn.TextXAlignment = Enum.TextXAlignment.Left
        TabBtn.Parent = TabContainer
        
        local Page = Instance.new("ScrollingFrame")
        Page.Size = UDim2.new(1, -20, 1, -20)
        Page.Position = UDim2.new(0, 10, 0, 10)
        Page.BackgroundTransparency = 1
        Page.BorderSizePixel = 0
        Page.ScrollBarThickness = 2
        Page.Visible = false
        Page.Parent = PageContainer
        
        local PageLayout = Instance.new("UIListLayout")
        PageLayout.Parent = Page
        PageLayout.SortOrder = Enum.SortOrder.LayoutOrder
        PageLayout.Padding = UDim.new(0, 8)
        
        if WindowData.CurrentTab == nil then
            WindowData.CurrentTab = TabBtn
            TabBtn.TextColor3 = Color3.fromRGB(60, 60, 255)
            TabBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
            Page.Visible = true
        end
        
        TabBtn.MouseButton1Click:Connect(function()
            for _, t in pairs(TabContainer:GetChildren()) do
                if t:IsA("TextButton") then
                    TweenService:Create(t, TweenInfo.new(0.3), {TextColor3 = Color3.fromRGB(200, 200, 200), BackgroundColor3 = Color3.fromRGB(25, 25, 30)}):Play()
                end
            end
            for _, p in pairs(PageContainer:GetChildren()) do
                if p:IsA("ScrollingFrame") then p.Visible = false end
            end
            TweenService:Create(TabBtn, TweenInfo.new(0.3), {TextColor3 = Color3.fromRGB(60, 60, 255), BackgroundColor3 = Color3.fromRGB(35, 35, 45)}):Play()
            Page.Visible = true
        end)
        
        local TabElements = {}
        
        function TabElements:CreateToggle(tName, default, callback)
            local ToggleFrame = Instance.new("Frame")
            ToggleFrame.Size = UDim2.new(1, -10, 0, 35)
            ToggleFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
            ToggleFrame.Parent = Page
            Instance.new("UICorner", ToggleFrame).CornerRadius = UDim.new(0, 6)
            
            local Txt = Instance.new("TextLabel", ToggleFrame)
            Txt.Size = UDim2.new(1, -60, 1, 0)
            Txt.Position = UDim2.new(0, 10, 0, 0)
            Txt.BackgroundTransparency = 1
            Txt.Text = tName
            Txt.TextColor3 = Color3.fromRGB(255, 255, 255)
            Txt.TextSize = 13
            Txt.Font = Enum.Font.Gotham
            Txt.TextXAlignment = Enum.TextXAlignment.Left
            
            local Btn = Instance.new("TextButton", ToggleFrame)
            Btn.Size = UDim2.new(0, 40, 0, 20)
            Btn.Position = UDim2.new(1, -50, 0.5, -10)
            Btn.BackgroundColor3 = default and Color3.fromRGB(60, 60, 255) or Color3.fromRGB(60, 60, 60)
            Btn.Text = ""
            Instance.new("UICorner", Btn).CornerRadius = UDim.new(1, 0)
            
            local Circle = Instance.new("Frame", Btn)
            Circle.Size = UDim2.new(0, 16, 0, 16)
            Circle.Position = default and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
            Circle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
            Instance.new("UICorner", Circle).CornerRadius = UDim.new(1, 0)
            
            local state = default
            Btn.MouseButton1Click:Connect(function()
                state = not state
                callback(state)
                local goalColor = state and Color3.fromRGB(60, 60, 255) or Color3.fromRGB(60, 60, 60)
                local goalPos = state and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
                TweenService:Create(Btn, TweenInfo.new(0.2), {BackgroundColor3 = goalColor}):Play()
                TweenService:Create(Circle, TweenInfo.new(0.2), {Position = goalPos}):Play()
            end)
            callback(state)
        end
        
        function TabElements:CreateSlider(sName, min, max, default, callback)
            local SliderFrame = Instance.new("Frame")
            SliderFrame.Size = UDim2.new(1, -10, 0, 50)
            SliderFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
            SliderFrame.Parent = Page
            Instance.new("UICorner", SliderFrame).CornerRadius = UDim.new(0, 6)
            
            local Txt = Instance.new("TextLabel", SliderFrame)
            Txt.Size = UDim2.new(1, -20, 0, 25)
            Txt.Position = UDim2.new(0, 10, 0, 0)
            Txt.BackgroundTransparency = 1
            Txt.Text = sName
            Txt.TextColor3 = Color3.fromRGB(255, 255, 255)
            Txt.TextSize = 13
            Txt.Font = Enum.Font.Gotham
            Txt.TextXAlignment = Enum.TextXAlignment.Left
            
            local ValueTxt = Instance.new("TextLabel", SliderFrame)
            ValueTxt.Size = UDim2.new(0, 50, 0, 25)
            ValueTxt.Position = UDim2.new(1, -60, 0, 0)
            ValueTxt.BackgroundTransparency = 1
            ValueTxt.Text = tostring(default)
            ValueTxt.TextColor3 = Color3.fromRGB(200, 200, 200)
            ValueTxt.TextSize = 13
            ValueTxt.Font = Enum.Font.Gotham
            ValueTxt.TextXAlignment = Enum.TextXAlignment.Right
            
            local SliderBg = Instance.new("Frame", SliderFrame)
            SliderBg.Size = UDim2.new(1, -20, 0, 6)
            SliderBg.Position = UDim2.new(0, 10, 0, 30)
            SliderBg.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
            Instance.new("UICorner", SliderBg).CornerRadius = UDim.new(1, 0)
            
            local SliderFill = Instance.new("Frame", SliderBg)
            SliderFill.Size = UDim2.new(math.clamp((default - min) / (max - min), 0, 1), 0, 1, 0)
            SliderFill.BackgroundColor3 = Color3.fromRGB(60, 60, 255)
            Instance.new("UICorner", SliderFill).CornerRadius = UDim.new(1, 0)
            
            local Btn = Instance.new("TextButton", SliderBg)
            Btn.Size = UDim2.new(1, 0, 1, 0)
            Btn.BackgroundTransparency = 1
            Btn.Text = ""
            
            local dragging = false
            local function updateSlider(input)
                local percent = math.clamp((input.Position.X - SliderBg.AbsolutePosition.X) / SliderBg.AbsoluteSize.X, 0, 1)
                local val = math.floor(min + ((max - min) * percent) * 100) / 100
                TweenService:Create(SliderFill, TweenInfo.new(0.1), {Size = UDim2.new(percent, 0, 1, 0)}):Play()
                ValueTxt.Text = tostring(val)
                callback(val)
            end
            
            Btn.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    dragging = true; updateSlider(input)
                end
            end)
            Btn.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    dragging = false
                end
            end)
            UserInputService.InputChanged:Connect(function(input)
                if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                    updateSlider(input)
                end
            end)
        end
        
        function TabElements:CreateButton(bName, callback)
            local Btn = Instance.new("TextButton")
            Btn.Size = UDim2.new(1, -10, 0, 35)
            Btn.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
            Btn.Text = bName
            Btn.TextColor3 = Color3.fromRGB(255, 255, 255)
            Btn.TextSize = 13
            Btn.Font = Enum.Font.GothamBold
            Btn.Parent = Page
            Instance.new("UICorner", Btn).CornerRadius = UDim.new(0, 6)
            
            Btn.MouseButton1Click:Connect(function()
                TweenService:Create(Btn, TweenInfo.new(0.1), {BackgroundColor3 = Color3.fromRGB(60, 60, 255)}):Play()
                task.wait(0.1)
                TweenService:Create(Btn, TweenInfo.new(0.1), {BackgroundColor3 = Color3.fromRGB(45, 45, 50)}):Play()
                callback()
            end)
        end
        
        function TabElements:CreateDropdown(dName, options, callback)
            local DropFrame = Instance.new("Frame")
            DropFrame.Size = UDim2.new(1, -10, 0, 35)
            DropFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
            DropFrame.Parent = Page
            DropFrame.ClipsDescendants = true
            Instance.new("UICorner", DropFrame).CornerRadius = UDim.new(0, 6)
            
            local MainBtn = Instance.new("TextButton", DropFrame)
            MainBtn.Size = UDim2.new(1, 0, 0, 35)
            MainBtn.BackgroundTransparency = 1
            MainBtn.Text = "  " .. dName .. " : " .. options[1]
            MainBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
            MainBtn.TextSize = 13
            MainBtn.Font = Enum.Font.Gotham
            MainBtn.TextXAlignment = Enum.TextXAlignment.Left
            
            local isDropped = false
            MainBtn.MouseButton1Click:Connect(function()
                isDropped = not isDropped
                local ySize = isDropped and 35 + (#options * 30) or 35
                TweenService:Create(DropFrame, TweenInfo.new(0.2), {Size = UDim2.new(1, -10, 0, ySize)}):Play()
            end)
            
            local yOffset = 35
            for i, opt in ipairs(options) do
                local optBtn = Instance.new("TextButton", DropFrame)
                optBtn.Size = UDim2.new(1, -10, 0, 30)
                optBtn.Position = UDim2.new(0, 5, 0, yOffset)
                optBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
                optBtn.Text = opt
                optBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
                optBtn.TextSize = 12
                optBtn.Font = Enum.Font.Gotham
                Instance.new("UICorner", optBtn).CornerRadius = UDim.new(0, 4)
                
                optBtn.MouseButton1Click:Connect(function()
                    MainBtn.Text = "  " .. dName .. " : " .. opt
                    callback(opt)
                    isDropped = false
                    TweenService:Create(DropFrame, TweenInfo.new(0.2), {Size = UDim2.new(1, -10, 0, 35)}):Play()
                end)
                yOffset = yOffset + 30
            end
            callback(options[1])
        end
        
        return TabElements
    end
    
    -- Mobile / Quick Toggle Button
    local ToggleMenu = Instance.new("TextButton")
    ToggleMenu.Size = UDim2.new(0, 45, 0, 45)
    ToggleMenu.Position = UDim2.new(0.02, 0, 0.15, 0)
    ToggleMenu.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
    ToggleMenu.Text = "HUB"
    ToggleMenu.TextColor3 = Color3.fromRGB(60, 60, 255)
    ToggleMenu.Font = Enum.Font.GothamBold
    ToggleMenu.TextSize = 14
    ToggleMenu.Parent = HubScreen
    Instance.new("UICorner", ToggleMenu).CornerRadius = UDim.new(1, 0)
    Instance.new("UIStroke", ToggleMenu).Color = Color3.fromRGB(60, 60, 255)
    
    local mDragging, mDragInput, mDragStart, mStartPos
    ToggleMenu.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            mDragging = true
            mDragStart = input.Position
            mStartPos = ToggleMenu.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then mDragging = false end
            end)
        end
    end)
    ToggleMenu.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then mDragInput = input end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input == mDragInput and mDragging then
            local delta = input.Position - mDragStart
            ToggleMenu.Position = UDim2.new(mStartPos.X.Scale, mStartPos.X.Offset + delta.X, mStartPos.Y.Scale, mStartPos.Y.Offset + delta.Y)
        end
    end)
    
    ToggleMenu.MouseButton1Click:Connect(function()
        MainFrame.Visible = not MainFrame.Visible
    end)

    return WindowData
end

local function SendNotify(title, text)
    pcall(function()
        game.StarterGui:SetCore("SendNotification", {
            Title = title, Text = text, Duration = 4
        })
    end)
end

-- [ 🛠️ INITIALIZING UI ]
local Window = UILibrary:CreateWindow("Invisible Hub")

-- TAB 1: Combat
local CombatTab = Window:CreateTab("⚔️ Combat")
CombatTab:CreateToggle("Enable Auto Parry", false, function(val) Config.AutoParry = val end)
CombatTab:CreateToggle("Manual Spam Mode", false, function(val) Config.SpamParry = val end)
CombatTab:CreateToggle("Auto Clash (Anti-PingPong)", true, function(val) Config.ClashMode = val end)
CombatTab:CreateDropdown("Parry Mode", {"Dynamic Prediction", "Normal", "Warp to Ball", "Side Loop 15"}, function(val) Config.ParryMode = val end)
CombatTab:CreateSlider("Advance Parry Time", 0.05, 0.8, 0.35, function(val) Config.BaseAdvanceTime = val end)
CombatTab:CreateToggle("Auto Ping Compensation", true, function(val) Config.AutoPingComp = val end)

-- TAB 2: Visuals
local VisualTab = Window:CreateTab("👁️ Visuals")
VisualTab:CreateToggle("Ball ESP & Trail", false, function(val) Config.BallESP = val end)
VisualTab:CreateToggle("Show Parry Radius", false, function(val) Config.ParryRadius = val end)
VisualTab:CreateButton("Clear All Visuals", function()
    for _, v in pairs(workspace.Terrain:GetChildren()) do
        if v.Name == "BallTrail" or v.Name == "ParryRadius" then v:Destroy() end
    end
end)

-- TAB 3: Movement
local MovementTab = Window:CreateTab("🏃 Movement")
MovementTab:CreateToggle("Enable Custom Speed/Jump", false, function(val) Config.UseCustomSpeed = val end)
MovementTab:CreateSlider("WalkSpeed", 16, 200, 16, function(val) Config.WalkSpeed = val end)
MovementTab:CreateSlider("JumpPower", 50, 200, 50, function(val) Config.JumpPower = val end)

-- TAB 4: Misc
local MiscTab = Window:CreateTab("⚙️ Misc")
MiscTab:CreateButton("Extreme FPS Boost (Anti-Lag)", function()
    Lighting.GlobalShadows = false
    Lighting.EnvironmentSpecularScale, Lighting.EnvironmentDiffusionScale = 0, 0
    for _, effect in ipairs(Lighting:GetChildren()) do
        if effect:IsA("PostEffect") or effect:IsA("Atmosphere") or effect:IsA("Clouds") then effect:Destroy() end
    end
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") then obj.CastShadow, obj.Material = false, Enum.Material.SmoothPlastic
        elseif obj:IsA("Decal") or obj:IsA("Texture") then obj:Destroy() end
    end
    SendNotify("FPS Boost", "Optimized graphics successfully!")
end)
MiscTab:CreateButton("Rejoin Server", function()
    game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
end)


-- [ 🕵️ REMOTE SNIFFER & BYPASS ENGINE ]
local function RegisterRemote(remote)
    if not Config.TargetRemote then
        Config.TargetRemote = remote
        SendNotify("🔥 System Ready!", "Bypass Remote Captured. Auto Parry is fully functional!")
    end
end

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    local args = {...}
    if not checkcaller() and (method == "FireServer" or method == "fireServer") then
        local isPayload = false
        if args[1] then
            if typeof(args[1]) == "buffer" or (typeof(args[1]) == "string" and string.find(args[1], "\x01")) then
                isPayload = true
            end
        end
        if isPayload or self.Name == "RemoteEvent" then
            RegisterRemote(self)
        end
    end
    return oldNamecall(self, ...)
end)

local oldIndex
oldIndex = hookmetamethod(game, "__index", function(self, key)
    if not checkcaller() and (key == "FireServer" or key == "fireServer") and typeof(self) == "Instance" and self:IsA("RemoteEvent") then
        if self.Name == "RemoteEvent" or (self.Parent and string.find(self.Parent.Name, "Remote")) then
            task.spawn(function() RegisterRemote(self) end)
        end
    end
    return oldIndex(self, key)
end)


-- [ 🧮 UTILITY MATHEMATICS & LOGIC ]
local function GetPingSeconds()
    if not Config.AutoPingComp then return 0 end
    pcall(function()
        local pingVal = Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        return pingVal / 1000 -- Convert ms to seconds
    end)
    return 0.1 -- Fallback ping 100ms
end

local function GetActiveBall()
    local ball = workspace:FindFirstChild("GameBall", true)
    if ball then
        if ball:IsA("BasePart") then return ball
        elseif ball:IsA("Model") and ball.PrimaryPart then return ball.PrimaryPart
        elseif ball:IsA("Model") then
            for _, child in ipairs(ball:GetChildren()) do if child:IsA("BasePart") then return child end end
        end
    end
    return nil
end

local function IsTargetingMe(ballPart)
    local actualBall = ballPart.Parent:IsA("Model") and ballPart.Parent or ballPart
    for _, attr in pairs(actualBall:GetAttributes()) do
        if attr == LocalPlayer or attr == LocalPlayer.Name or tostring(attr) == tostring(LocalPlayer.UserId) then return true end
    end
    local targetObj = actualBall:FindFirstChild("Target") or actualBall:FindFirstChild("target") or actualBall:FindFirstChild("TargetPlayer")
    if targetObj then
        if targetObj:IsA("ObjectValue") and targetObj.Value == LocalPlayer then return true
        elseif (targetObj:IsA("StringValue") or targetObj:IsA("IntValue")) and (targetObj.Value == LocalPlayer.Name or tostring(targetObj.Value) == tostring(LocalPlayer.UserId)) then return true end
    end
    return false
end

-- [ 🎨 VISUALS RENDERING ]
local TrailFolder = Instance.new("Folder")
TrailFolder.Name = "InvisHub_Visuals"
TrailFolder.Parent = workspace.Terrain

local function DrawVisuals(ballPart, hrp)
    TrailFolder:ClearAllChildren()
    
    if Config.BallESP and ballPart then
        local highlight = Instance.new("Highlight")
        highlight.Parent = TrailFolder
        highlight.Adornee = ballPart
        highlight.FillColor = Config.IsTargeted and Color3.fromRGB(255, 0, 0) or Color3.fromRGB(0, 255, 0)
        highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
        
        -- Trail Line
        local line = Instance.new("Part")
        line.Name = "BallTrail"
        line.Anchored = true
        line.CanCollide = false
        line.Material = Enum.Material.Neon
        line.Color = Config.IsTargeted and Color3.fromRGB(255, 0, 0) or Color3.fromRGB(0, 255, 0)
        line.Size = Vector3.new(0.2, 0.2, (ballPart.Position - hrp.Position).Magnitude)
        line.CFrame = CFrame.lookAt(hrp.Position, ballPart.Position) * CFrame.new(0, 0, -line.Size.Z / 2)
        line.Parent = TrailFolder
    end
    
    if Config.ParryRadius and hrp then
        local radiusPart = Instance.new("Part")
        radiusPart.Name = "ParryRadius"
        radiusPart.Anchored = true
        radiusPart.CanCollide = false
        radiusPart.Size = Vector3.new(40, 0.1, 40) -- Approx parry range
        radiusPart.CFrame = hrp.CFrame * CFrame.new(0, -2.5, 0)
        radiusPart.Shape = Enum.PartType.Cylinder
        radiusPart.Orientation = Vector3.new(0, 0, 90)
        radiusPart.Material = Enum.Material.Neon
        radiusPart.Transparency = 0.7
        radiusPart.Color = Config.RadiusColor
        radiusPart.Parent = TrailFolder
    end
end


-- [ ⚙️ MAIN EXECUTION LOOP ]
local LastBallPos = nil
local LastTime = 0

RunService.Heartbeat:Connect(function()
    local currentTime = os.clock()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChild("Humanoid")
    local ballPart = GetActiveBall()
    
    -- Custom Movement
    if Config.UseCustomSpeed and humanoid then
        humanoid.WalkSpeed = Config.WalkSpeed
        humanoid.JumpPower = Config.JumpPower
    end
    
    -- Manual Spam Mode
    if Config.SpamParry and Config.TargetRemote then
        Config.TargetRemote:FireServer(buffer.fromstring("\x01"))
    end
    
    -- Auto Parry Reset Logic (Unlock target if ball bounces to someone else)
    if Config.HasParried and (currentTime - Config.LastParryTime > 0.6) then
        Config.HasParried = false
    end
    
    if ballPart and hrp then
        -- Check Target State (Throttled for performance)
        if currentTime >= Config.NextTargetCheck then
            Config.NextTargetCheck = currentTime + 0.05
            Config.IsTargeted = IsTargetingMe(ballPart)
        end
        
        -- Draw Visuals
        task.spawn(function() DrawVisuals(ballPart, hrp) end)
        
        if Config.AutoParry and Config.IsTargeted and Config.TargetRemote then
            local ballPos = ballPart.Position
            local ballVelocity = ballPart.AssemblyLinearVelocity or ballPart.Velocity
            
            -- Fallback Velocity calculation if physics is frozen
            if ballVelocity.Magnitude < 5 and LastBallPos then
                local dt = currentTime - LastTime
                if dt > 0 then ballVelocity = (ballPos - LastBallPos) / dt end
            end
            
            local distance = (hrp.Position - ballPos).Magnitude
            local directionToPlayer = (hrp.Position - ballPos).Unit
            local approachSpeed = ballVelocity:Dot(directionToPlayer)
            
            -- Clash Mode (Ball is extremely close and moving super fast)
            if Config.ClashMode and distance < Config.ClashDistance and approachSpeed > 50 then
                Config.TargetRemote:FireServer(buffer.fromstring("\x01"))
                Config.LastParryTime = currentTime
                Config.HasParried = true
            end
            
            -- Normal/Dynamic Parry Logic
            if approachSpeed > 5 and not Config.HasParried then
                local timeToHit = distance / approachSpeed
                local pingComp = GetPingSeconds()
                local totalAdvanceTime = Config.BaseAdvanceTime + pingComp
                
                -- Check if ball is within prediction range OR extremely close
                if timeToHit <= totalAdvanceTime or distance <= 15 then
                    
                    -- Handle Different Parry Modes
                    if Config.ParryMode == "Warp to Ball" then
                        hrp.CFrame = ballPart.CFrame * CFrame.new(0, 0, 3)
                    elseif Config.ParryMode == "Side Loop 15" then
                        hrp.CFrame = ballPart.CFrame * CFrame.new(15, 0, 0)
                    end
                    
                    -- Execute Parry
                    Config.TargetRemote:FireServer(buffer.fromstring("\x01"))
                    Config.HasParried = true
                    Config.LastParryTime = currentTime
                    
                    -- Visual Feedback on parry
                    Config.RadiusColor = Color3.fromRGB(0, 255, 0)
                    task.delay(0.2, function() Config.RadiusColor = Color3.fromRGB(255, 0, 50) end)
                end
            end
            
            LastBallPos = ballPos
            LastTime = currentTime
        else
            Config.HasParried = false
            LastBallPos = nil
        end
    else
        LastBallPos = nil
    end
end)

SendNotify("Invisible Hub Initialized", "Please parry manually once to cache the Remote Event!")
local addonName = ...
local title = "Party Target Highlight"
local defaultThickness, maxThickness = 5, 30
local dotTexture = "Interface\\AddOns\\" .. addonName .. "\\Dot.tga"
local events = CreateFrame("Frame")
local overlays, containers = {}, {}
local settings, settingsRevision
local refreshQueued = false

local function NormalizeThickness(value, fallback)
    local number = tonumber(value)
    if not number or number ~= number then
        return fallback
    end
    return math.max(1, math.min(maxThickness, math.floor(number)))
end

local function NormalizeColor(value, fallback)
    if type(value) ~= "number" or value ~= value then
        return fallback
    end
    return math.max(0, math.min(1, value))
end

local function PlaceTexture(overlay, x, y, width, height)
    local index = overlay.textureCount + 1
    overlay.textureCount = index
    local texture = overlay.textures[index]
    if not texture then
        texture = overlay:CreateTexture(nil, "OVERLAY")
        overlay.textures[index] = texture
    end
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", overlay, "TOPLEFT", x, -y)
    texture:SetSize(width, height)
    texture:Show()
    return texture
end

local function DrawDots(overlay, width, height, size)
    local spacing = math.max(5, size * 1.8)
    local across = math.max(1, math.floor((width + size) / spacing + 0.5))
    local down = math.max(1, math.floor((height + size) / spacing + 0.5))

    local function DrawDot(x, y)
        local texture = PlaceTexture(overlay, x, y, size, size)
        texture:SetTexture(dotTexture)
        texture:SetVertexColor(settings.r, settings.g, settings.b, 1)
    end

    for column = 0, across do
        local x = -size + column * (width + size) / across
        DrawDot(x, -size)
        DrawDot(x, height)
    end
    for row = 1, down - 1 do
        local y = -size + row * (height + size) / down
        DrawDot(-size, y)
        DrawDot(width, y)
    end
end

local function DrawOutline(overlay, width, height, inner, outer, alpha)
    local thickness = outer - inner
    local span = width + outer * 2
    local function DrawEdge(x, y, edgeWidth, edgeHeight)
        local texture = PlaceTexture(overlay, x, y, edgeWidth, edgeHeight)
        texture:SetVertexColor(1, 1, 1, 1)
        texture:SetColorTexture(settings.r, settings.g, settings.b, alpha)
    end
    DrawEdge(-outer, -outer, span, thickness)
    DrawEdge(-outer, height + inner, span, thickness)
    DrawEdge(-outer, -inner, thickness, height + inner * 2)
    DrawEdge(width + inner, -inner, thickness, height + inner * 2)
end

local function DrawGlow(overlay, width, height, size)
    local core = math.max(1, size * 0.35)
    DrawOutline(overlay, width, height, 0, core, 0.95)
    local step = size * 1.5 / 8
    for band = 1, 8 do
        local inner = core + (band - 1) * step
        DrawOutline(overlay, width, height, inner, inner + step, 0.6 * ((9 - band) / 8) ^ 2)
    end
end

local function DrawHighlight(overlay)
    local width, height = overlay:GetSize()
    overlay.textureCount = 0
    if width and height and width > 0 and height > 0 then
        if settings.style == "glow" then
            DrawGlow(overlay, width, height, settings.thickness)
        elseif settings.style == "solid-border" then
            DrawOutline(overlay, width, height, 0, settings.thickness, 1)
        else
            DrawDots(overlay, width, height, settings.thickness)
        end
    end
    for index = overlay.textureCount + 1, #overlay.textures do
        overlay.textures[index]:Hide()
    end
    overlay.settingsRevision = settingsRevision
end

local function RefreshTarget()
    local inParty = IsInGroup() and not EditModeManagerFrame:IsEditModeActive()
    for frame, overlay in pairs(overlays) do
        local unit
        if inParty and frame:IsVisible() then
            if overlay.usesUnitAttribute then
                unit = frame:GetAttribute("unit")
            else
                unit = frame.unit or frame.unitToken
            end
        end

        local isTarget = false
        if not issecretvalue(unit) and type(unit) == "string"
            and (unit == "player" or unit:match("^party[1-4]$") or unit:match("^raid%d+$")) then
            isTarget = UnitIsUnit(unit, "target")
        end
        -- Retail can restrict unit comparisons. Pass the result straight to the display API.
        overlay:SetAlphaFromBoolean(isTarget, 1, 0)

        if overlay.settingsRevision ~= settingsRevision then
            DrawHighlight(overlay)
        end
    end
end

local function QueueRefresh()
    if refreshQueued then
        return
    end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        local function TrackMember(frame, usesUnitAttribute)
            if not frame or overlays[frame] then
                return
            end
            local overlay = CreateFrame("Frame", nil, frame)
            overlay:SetAlpha(0)
            overlay:SetAllPoints(frame)
            overlay:SetFrameLevel(frame:GetFrameLevel() + 20)
            overlay:EnableMouse(false)
            overlay.textures = {}
            overlay.usesUnitAttribute = usesUnitAttribute
            overlay:SetScript("OnSizeChanged", DrawHighlight)
            overlays[frame] = overlay

            frame:HookScript("OnShow", QueueRefresh)
            if usesUnitAttribute then
                frame:HookScript("OnAttributeChanged", function(_, attribute)
                    if attribute == "unit" then
                        QueueRefresh()
                    end
                end)
            end
        end

        local function TrackContainer(frame)
            if frame and not containers[frame] then
                containers[frame] = true
                frame:HookScript("OnShow", QueueRefresh)
            end
        end

        TrackContainer(PartyFrame)
        if PartyFrame and PartyFrame.PartyMemberFramePool then
            for member in PartyFrame.PartyMemberFramePool:EnumerateActive() do
                TrackMember(member)
            end
        end

        TrackContainer(CompactPartyFrame)
        if CompactPartyFrame and CompactPartyFrame.memberUnitFrames then
            for _, member in ipairs(CompactPartyFrame.memberUnitFrames) do
                TrackMember(member)
            end
        end

        TrackContainer(ERFPartyHeader)
        if ERFPartyHeader then
            for index = 1, 5 do
                TrackMember(ERFPartyHeader[index], true)
            end
        end
        TrackMember(ERFPartySelfButton, true)
        RefreshTarget()
    end)
end

local function CreateSettingsPanel()
    local panel = CreateFrame("Frame")
    local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 16, -16)
    heading:SetText(title)

    local function Label(text, y)
        local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("TOPLEFT", 16, y)
        label:SetText(text)
    end

    local function ApplyAppearance()
        settingsRevision = settingsRevision + 1
        RefreshTarget()
    end

    Label("Type", -66)
    local dropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("TOPLEFT", 124, -58)
    dropdown:SetWidth(164)
    dropdown:SetupMenu(function(_, root)
        local function IsSelected(style)
            return settings.style == style
        end
        local function SelectStyle(style)
            settings.style = style
            ApplyAppearance()
        end
        root:CreateRadio("Dotted border", IsSelected, SelectStyle, "dotted-border")
        root:CreateRadio("Solid border", IsSelected, SelectStyle, "solid-border")
        root:CreateRadio("Glow", IsSelected, SelectStyle, "glow")
    end)

    Label("Color", -107)
    local colorButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    colorButton:SetPoint("TOPLEFT", 124, -101)
    colorButton:SetSize(124, 24)
    colorButton:SetText("Choose color")
    local swatch = panel:CreateTexture(nil, "ARTWORK")
    swatch:SetPoint("LEFT", colorButton, "RIGHT", 12, 0)
    swatch:SetSize(20, 20)
    swatch:SetColorTexture(settings.r, settings.g, settings.b)

    colorButton:SetScript("OnClick", function()
        local function SetColor(r, g, b)
            settings.r, settings.g, settings.b = r, g, b
            swatch:SetColorTexture(r, g, b)
            ApplyAppearance()
        end
        ColorPickerFrame:SetupColorPickerAndShow({
            r = settings.r, g = settings.g, b = settings.b,
            swatchFunc = function() SetColor(ColorPickerFrame:GetColorRGB()) end,
            cancelFunc = function(previous) SetColor(previous.r, previous.g, previous.b) end,
        })
    end)

    Label("Bold", -148)
    local input = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    input:SetPoint("TOPLEFT", 130, -142)
    input:SetSize(56, 24)
    input:SetAutoFocus(false)
    input:SetNumeric(true)
    input:SetText(tostring(settings.thickness))

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", input, "RIGHT", 10, 0)
    hint:SetFormattedText("1–%d", maxThickness)

    input:SetScript("OnEditFocusLost", function(self)
        local thickness = NormalizeThickness(self:GetText(), settings.thickness)
        self:SetText(tostring(thickness))
        if settings.thickness ~= thickness then
            settings.thickness = thickness
            ApplyAppearance()
        end
    end)
    input:SetScript("OnEnterPressed", input.ClearFocus)
    input:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(settings.thickness))
        self:ClearFocus()
    end)
    panel:SetScript("OnHide", function() input:ClearFocus() end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, title)
    Settings.RegisterAddOnCategory(category)
    SLASH_PARTYTARGETHIGHLIGHT1 = "/pth"
    SlashCmdList.PARTYTARGETHIGHLIGHT = function()
        Settings.OpenToCategory(category:GetID())
    end
end

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, loadedAddon)
    if event == "ADDON_LOADED" then
        if loadedAddon == addonName then
            if type(PartyTargetHighlightDB) ~= "table" then
                PartyTargetHighlightDB = {}
            end
            settings = PartyTargetHighlightDB
            settingsRevision = 1
            if settings.style ~= "glow" and settings.style ~= "solid-border" then
                settings.style = "dotted-border"
            end
            settings.thickness = NormalizeThickness(settings.thickness, defaultThickness)
            settings.r = NormalizeColor(settings.r, 1)
            settings.g = NormalizeColor(settings.g, 1)
            settings.b = NormalizeColor(settings.b, 0)
            CreateSettingsPanel()

            self:RegisterEvent("PLAYER_ENTERING_WORLD")
            self:RegisterEvent("PLAYER_TARGET_CHANGED")
            self:RegisterEvent("GROUP_ROSTER_UPDATE")
            self:RegisterEvent("PLAYER_REGEN_ENABLED")
            EventRegistry:RegisterCallback("EditMode.Enter", QueueRefresh, self)
            EventRegistry:RegisterCallback("EditMode.Exit", QueueRefresh, self)
            QueueRefresh()
        elseif settings and (loadedAddon == "Blizzard_CompactRaidFrames" or loadedAddon == "EllesmereUIRaidFrames") then
            QueueRefresh()
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        RefreshTarget()
    else
        QueueRefresh()
    end
end)

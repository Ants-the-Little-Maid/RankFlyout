-- Round minimap button (same build as Schmoovin Man's, which has run on Forever).
-- Left-click opens the spell picker, right-click opens a settings menu, and
-- dragging moves it around the minimap's edge.

local _, ns = ...

local BUTTON_SIZE = 31
local RADIUS_OUTSIDE_EDGE = 5
local ICON = "Interface\\Icons\\INV_Misc_Book_09"

local button

local DIR_LABELS = { UP = "Up", DOWN = "Down", LEFT = "Left", RIGHT = "Right" }
local DIR_ORDER = { "UP", "DOWN", "LEFT", "RIGHT" }

-- Uses the game's own menu system (Blizzard_Menu).
local function BuildMenu(owner, root)
	local db = ns.db
	root:CreateTitle("Rank in File")
	root:CreateButton("Open spell picker", function() ns.TogglePicker() end)
	root:CreateDivider()
	root:CreateCheckbox("Floating buttons", function()
		return db.float ~= false
	end, function()
		ns.SetFloat(db.float == false)
	end)
	root:CreateCheckbox("Lock floating buttons", function()
		return db.locked
	end, function()
		ns.SetLocked(not db.locked)
	end)
	local dirs = root:CreateButton("Rank menu opens")
	for _, dir in ipairs(DIR_ORDER) do
		dirs:CreateRadio(DIR_LABELS[dir], function()
			return (db.direction or "UP") == dir
		end, function()
			ns.SetDirection(dir)
		end)
	end
	root:CreateDivider()
	root:CreateButton("Hide minimap button", function()
		db.minimap.hide = true
		ns.UpdateMinimapButton()
		ns.Print("minimap button hidden. /rf minimap on brings it back.")
	end)
end

local function OpenMenu(owner)
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(owner, BuildMenu)
	else
		ns.TogglePicker()
	end
end

local function Reposition()
	local angle = math.rad(ns.db.minimap.angle)
	local radius = Minimap:GetWidth() / 2 + RADIUS_OUTSIDE_EDGE
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function FollowCursor()
	local centerX, centerY = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	ns.db.minimap.angle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
	Reposition()
end

function ns.UpdateMinimapButton()
	if not button then return end
	button:SetShown(not ns.db.minimap.hide)
end

ns.OnLoaded(function()
	button = CreateFrame("Button", "RankInFileMinimapButton", Minimap)
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(17, 17)
	icon:SetPoint("TOPLEFT", 7, -6)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", function(self, mouseButton)
		GameTooltip:Hide()
		if mouseButton == "RightButton" then
			OpenMenu(self)
		else
			ns.TogglePicker()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", FollowCursor)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Rank in File")
		GameTooltip:AddLine("Left-click: spell picker", 1, 1, 1)
		GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
		GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)

	Reposition()
	ns.UpdateMinimapButton()
end)

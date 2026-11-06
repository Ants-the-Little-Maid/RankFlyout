-- Spell picker: a spellbook-style window listing the player's known spells.
-- Clicking or dragging a spell makes (or reuses) its Rank Flyout button and puts
-- that button's macro on the cursor, ready to click into an action bar slot.
-- Spells can also be dropped onto the window from the spellbook or the bars.
-- Nothing here is secure: making macros is refused in combat by the core.

local _, ns = ...

local BANK = Enum.SpellBookSpellBank.Player
local SPELL_ITEM = Enum.SpellBookItemType.Spell

local FRAME_W, FRAME_H = 440, 500
local COLS, ROWS = 2, 6
local PER_PAGE = COLS * ROWS
local ENTRY_W, ENTRY_H = 205, 40
local ENTRY_GAP_X, ENTRY_GAP_Y = 8, 2
local GRID_TOP = -28

local frame            -- built on first open
local entries = {}     -- entry buttons on the page
local page = 1
local skillLines = {}  -- tab index -> skill line index

local function RankNumber(sub)
	if type(sub) ~= "string" then return nil end
	return tonumber(sub:match("(%d+)"))
end

-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------

-- Skill lines that have at least one active spell, in spellbook order.
local function ScanSkillLines()
	wipe(skillLines)
	for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
		if info and not info.shouldHide and not info.offSpecID and info.numSpellBookItems > 0 then
			for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
				local item = C_SpellBook.GetSpellBookItemInfo(slot, BANK)
				if item and item.itemType == SPELL_ITEM and not item.isPassive then
					skillLines[#skillLines + 1] = { index = line, name = info.name, icon = info.iconID }
					break
				end
			end
		end
	end
end

-- One entry per spell name in a skill line, holding its highest known rank.
local function CollectFamilies(lineIndex, rankedOnly)
	local list, byName = {}, {}
	local info = C_SpellBook.GetSpellBookSkillLineInfo(lineIndex)
	if not info then return list end
	for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
		local item = C_SpellBook.GetSpellBookItemInfo(slot, BANK)
		if item and item.itemType == SPELL_ITEM and not item.isPassive then
			local fam = byName[item.name]
			if not fam then
				fam = { name = item.name, count = 0 }
				byName[item.name] = fam
				list[#list + 1] = fam
			end
			fam.count = fam.count + 1
			local sub = item.subName
			if not sub or sub == "" then sub = C_Spell.GetSpellSubtext(item.actionID) end
			local rank = RankNumber(sub)
			if not fam.topID or (rank or 0) >= (fam.topRank or 0) then
				fam.topID, fam.topRank, fam.icon = item.actionID, rank, item.iconID
			end
			if rank and (not fam.lowRank or rank < fam.lowRank) then fam.lowRank = rank end
		end
	end
	if rankedOnly then
		local filtered = {}
		for _, fam in ipairs(list) do
			if fam.count > 1 then filtered[#filtered + 1] = fam end
		end
		return filtered
	end
	return list
end

local function RankSummary(fam)
	if fam.count > 1 and fam.lowRank and fam.topRank then
		return ("Ranks %d-%d"):format(fam.lowRank, fam.topRank)
	elseif fam.topRank then
		return ("Rank %d"):format(fam.topRank)
	end
	return fam.count > 1 and (fam.count .. " ranks") or ""
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local function PickUp(spellID)
	if ns.PickUpSpell(spellID) then
		frame.hint:SetText("|cff20ff20Macro on your cursor:|r click an action bar slot to place it.")
	end
end

local function TakeCursorSpell()
	local kind, slot, _, spellID = GetCursorInfo()
	if kind ~= "spell" then return end
	if not spellID and slot then
		local info = C_SpellBook.GetSpellBookItemInfo(slot, BANK)
		spellID = info and info.actionID
	end
	if spellID then
		ClearCursor()
		PickUp(spellID)
	end
end

-------------------------------------------------------------------------------
-- Entries
-------------------------------------------------------------------------------

local function Entry_OnClick(self, mouseButton)
	if not self.fam then return end
	if GetCursorInfo() then
		TakeCursorSpell() -- clicking with a spell held works like dropping it
		return
	end
	if mouseButton == "RightButton" then
		local index = ns.FindFamily(self.fam.name)
		if index and ns.RemoveButton(index) then
			ns.Print(self.fam.name .. " removed, with its macro.")
		end
	else
		PickUp(self.fam.topID)
	end
end

local function Entry_OnEnter(self)
	if not self.fam then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetSpellByID(self.fam.topID)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Click or drag: put on an action bar", 0.6, 0.8, 1)
	if ns.FindFamily(self.fam.name) then
		GameTooltip:AddLine("Right-click: remove from Rank Flyout", 0.6, 0.8, 1)
	end
	GameTooltip:Show()
end

local function CreateEntry(parent, i)
	local e = CreateFrame("Button", nil, parent)
	e:SetSize(ENTRY_W, ENTRY_H)
	local col = (i - 1) % COLS
	local row = math.floor((i - 1) / COLS)
	e:SetPoint("TOPLEFT", parent, "TOPLEFT", 6 + col * (ENTRY_W + ENTRY_GAP_X), GRID_TOP - row * (ENTRY_H + ENTRY_GAP_Y))
	e:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	e:RegisterForDrag("LeftButton")
	e:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	local border = e:CreateTexture(nil, "BACKGROUND")
	border:SetSize(38, 38)
	border:SetPoint("LEFT", 1, 0)
	border:SetColorTexture(0, 0, 0, 1)

	e.icon = e:CreateTexture(nil, "ARTWORK")
	e.icon:SetSize(36, 36)
	e.icon:SetPoint("CENTER", border)
	e.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	e.check = e:CreateTexture(nil, "OVERLAY")
	e.check:SetSize(16, 16)
	e.check:SetPoint("BOTTOMRIGHT", e.icon, "BOTTOMRIGHT", 3, -3)
	e.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")

	e.name = e:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	e.name:SetPoint("TOPLEFT", e.icon, "TOPRIGHT", 7, -2)
	e.name:SetPoint("RIGHT", e, "RIGHT", -2, 0)
	e.name:SetJustifyH("LEFT")
	e.name:SetWordWrap(false)

	e.sub = e:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	e.sub:SetPoint("BOTTOMLEFT", e.icon, "BOTTOMRIGHT", 7, 2)
	e.sub:SetJustifyH("LEFT")

	e.status = e:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
	e.status:SetPoint("BOTTOMRIGHT", e, "BOTTOMRIGHT", -2, 2)
	e.status:SetJustifyH("RIGHT")

	e:SetScript("OnClick", Entry_OnClick)
	e:SetScript("OnDragStart", function(self) if self.fam then PickUp(self.fam.topID) end end)
	e:SetScript("OnReceiveDrag", TakeCursorSpell)
	e:SetScript("OnEnter", Entry_OnEnter)
	e:SetScript("OnLeave", GameTooltip_Hide)
	return e
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

local function SelectedLine()
	local tab = frame.selectedTab or 1
	local line = skillLines[tab] or skillLines[1]
	return line and line.index
end

local function RefreshTabs()
	for i, line in ipairs(skillLines) do
		local tab = frame.Tabs[i]
		if not tab then
			tab = CreateFrame("Button", "RankFlyoutPickerFrameTab" .. i, frame, "PanelTopTabButtonTemplate")
			tab:SetID(i)
			tab:SetScript("OnClick", function(self)
				PanelTemplates_SetTab(frame, self:GetID())
				page = 1
				frame:Refresh()
			end)
			frame.Tabs[i] = tab
			if i == 1 then tab:SetPoint("BOTTOMLEFT", frame.Inset, "TOPLEFT", 8, -1) end
		end
		tab:SetText(line.name)
		tab:Show()
		PanelTemplates_TabResize(tab, 0)
	end
	for i = #skillLines + 1, #frame.Tabs do frame.Tabs[i]:Hide() end
	PanelTemplates_SetNumTabs(frame, #skillLines)
	if not frame.selectedTab or frame.selectedTab > #skillLines then
		-- Start on the first class school rather than General when there is one.
		frame.selectedTab = #skillLines >= 2 and 2 or 1
	end
	if #skillLines > 0 then PanelTemplates_SetTab(frame, frame.selectedTab) end
end

local function Refresh()
	if not frame or not frame:IsShown() then return end
	ScanSkillLines()
	RefreshTabs()

	local lineIndex = SelectedLine()
	local fams = lineIndex and CollectFamilies(lineIndex, ns.db.pickerRankedOnly) or {}
	local pages = math.max(1, math.ceil(#fams / PER_PAGE))
	page = math.min(math.max(page, 1), pages)

	for i = 1, PER_PAGE do
		local e = entries[i]
		local fam = fams[(page - 1) * PER_PAGE + i]
		e.fam = fam
		if fam then
			e.icon:SetTexture(fam.icon)
			e.name:SetText(fam.name)
			e.sub:SetText(RankSummary(fam))
			local index = ns.FindFamily(fam.name)
			e.check:SetShown(index ~= nil)
			e.status:SetText(index and ("Button " .. index) or "")
			e:Show()
		else
			e:Hide()
		end
	end

	frame.empty:SetShown(#fams == 0)
	frame.pageText:SetFormattedText("Page %d / %d", page, pages)
	frame.prev:SetEnabled(page > 1)
	frame.next:SetEnabled(page < pages)
	frame.rankedOnly:SetChecked(ns.db.pickerRankedOnly and true or false)
	frame.float:SetChecked(ns.db.float ~= false)
	frame.lock:SetChecked(ns.db.locked and true or false)
	frame.dir:SetText("Menu opens: " .. (ns.db.direction or "UP"):lower())
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

local function CheckBox(parent, label, onClick)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	cb.label:SetPoint("LEFT", cb, "RIGHT", 1, 0)
	cb.label:SetText(label)
	cb:SetScript("OnClick", function(self) onClick(self:GetChecked()) end)
	return cb
end

local DIR_ORDER = { "UP", "RIGHT", "DOWN", "LEFT" }

local function Build()
	frame = CreateFrame("Frame", "RankFlyoutPickerFrame", UIParent, "ButtonFrameTemplate")
	frame:SetSize(FRAME_W, FRAME_H)
	frame:SetPoint("CENTER", -200, 40)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetScript("OnReceiveDrag", TakeCursorSpell)
	frame:Hide()
	frame.Tabs = {}
	frame.Refresh = Refresh
	frame.entries = entries -- for the smoke test

	if frame.SetTitle then frame:SetTitle("Rank Flyout") end
	pcall(function()
		frame:SetPortraitToClassIcon(select(2, UnitClass("player")))
	end)
	table.insert(UISpecialFrames, frame:GetName()) -- Escape closes it

	local inset = frame.Inset

	local help = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", 8, -9)
	help:SetPoint("RIGHT", -8, 0)
	help:SetJustifyH("LEFT")
	help:SetText("Click or drag a spell onto an action bar. Right-click the bar slot to swap ranks.")

	for i = 1, PER_PAGE do entries[i] = CreateEntry(inset, i) end

	frame.empty = inset:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	frame.empty:SetPoint("TOP", 0, -120)
	frame.empty:SetText("No spells here.")

	-- Pager
	local pagerY = GRID_TOP - ROWS * (ENTRY_H + ENTRY_GAP_Y) - 6
	frame.prev = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
	frame.prev:SetSize(28, 22)
	frame.prev:SetText("<")
	frame.prev:SetPoint("TOPRIGHT", inset, "TOP", -60, pagerY)
	frame.prev:SetScript("OnClick", function() page = page - 1; Refresh() end)
	frame.next = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
	frame.next:SetSize(28, 22)
	frame.next:SetText(">")
	frame.next:SetPoint("TOPLEFT", inset, "TOP", 60, pagerY)
	frame.next:SetScript("OnClick", function() page = page + 1; Refresh() end)
	frame.pageText = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.pageText:SetPoint("CENTER", inset, "TOP", 0, pagerY - 11)
	inset:EnableMouseWheel(true)
	inset:SetScript("OnMouseWheel", function(_, delta) page = page - delta; Refresh() end)

	-- Drop zone
	local drop = CreateFrame("Button", nil, inset)
	drop:SetPoint("TOPLEFT", inset, "TOPLEFT", 8, pagerY - 30)
	drop:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -8, pagerY - 30)
	drop:SetHeight(40)
	local dropBg = drop:CreateTexture(nil, "BACKGROUND")
	dropBg:SetAllPoints()
	dropBg:SetColorTexture(1, 1, 1, 0.06)
	drop:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	local dropText = drop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	dropText:SetPoint("CENTER")
	dropText:SetText("Drop a spell here from your spellbook or action bars")
	drop:SetScript("OnReceiveDrag", TakeCursorSpell)
	drop:SetScript("OnClick", TakeCursorSpell)

	frame.hint = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.hint:SetPoint("TOP", drop, "BOTTOM", 0, -6)
	frame.hint:SetText("")

	frame.rankedOnly = CheckBox(inset, "Only spells with more than one rank", function(on)
		ns.db.pickerRankedOnly = on
		page = 1
		Refresh()
	end)
	frame.rankedOnly:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", 6, 4)

	-- Bottom bar: global settings shared with the slash commands.
	frame.float = CheckBox(frame, "Floating buttons", function(on) ns.SetFloat(on); Refresh() end)
	frame.float:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 1)
	frame.lock = CheckBox(frame, "Lock", function(on) ns.SetLocked(on); Refresh() end)
	frame.lock:SetPoint("LEFT", frame.float.label, "RIGHT", 12, 0)
	frame.dir = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	frame.dir:SetSize(130, 22)
	frame.dir:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 3)
	frame.dir:SetScript("OnClick", function()
		local current = ns.db.direction or "UP"
		for i, d in ipairs(DIR_ORDER) do
			if d == current then
				ns.SetDirection(DIR_ORDER[i % #DIR_ORDER + 1])
				break
			end
		end
		Refresh()
	end)

	frame:SetScript("OnShow", function()
		frame.hint:SetText("")
		Refresh()
	end)
end

function ns.TogglePicker()
	if not frame then Build() end
	frame:SetShown(not frame:IsShown())
end

ns.OnChanged(Refresh)

-- Rank Flyout: buttons that hold one rank of a spell, with a secure pop-out
-- menu for swapping ranks. Target: WoW Forever (interface 16001).
--
-- How it reaches the action bars
--   Dragging a Rank Flyout button picks up a per-character macro:
--       #showtooltip Frostbolt(Rank 3)
--       /click [btn:2] RankFlyoutButton1 RightButton; RankFlyoutButton1
--   Dropped on any bar slot, that slot's own hotkey fires the button, and
--   right-clicking the slot opens the rank menu next to it.
--
-- Security model
--   * Each main button is a SecureActionButtonTemplate ("type" = "spell").
--     useOnKeyDown is false because /click sends a single click with down = false.
--   * Rank choice is changed by restricted (secure) snippets, so it works in combat.
--   * Rank list, macros, positions and anchors only change out of combat; changes
--     that arrive in combat wait for PLAYER_REGEN_ENABLED.

local ADDON_NAME, ns = ...

local MAX_BUTTONS = 12
local BUTTON_SIZE = 36
local RANK_SIZE = 30
local RANK_GAP = 3
local FLYOUT_GAP = 9 -- leaves room for the arrow tab
local EMPTY_ICON = 134400 -- Interface\Icons\INV_Misc_QuestionMark
local MACRO_ICON = 134400 -- question mark = let #showtooltip pick the icon
local BANK = Enum.SpellBookSpellBank.Player
local SPELL_ITEM = Enum.SpellBookItemType.Spell
local MAX_ACCOUNT_MACROS = Constants.MacroConsts.MAX_ACCOUNT_MACROS
local MAX_CHARACTER_MACROS = Constants.MacroConsts.MAX_CHARACTER_MACROS

local db
local buttons = {}      -- [index] = main button
local pending = {}      -- work deferred until combat ends: rebuild, macros, anchors

local function Print(msg)
	print("|cff66ccffRank Flyout:|r " .. msg)
end
ns.Print = Print
ns.MAX_BUTTONS = MAX_BUTTONS

-- Other files (picker, minimap) listen for changes to buttons or the spellbook.
-- Calls are batched into one notification per frame.
local listeners, changeQueued = {}, false
function ns.OnChanged(func) listeners[#listeners + 1] = func end
function ns.Changed()
	if changeQueued then return end
	changeQueued = true
	C_Timer.After(0, function()
		changeQueued = false
		for _, func in ipairs(listeners) do func() end
	end)
end
local loadedCallbacks = {}
function ns.OnLoaded(func) loadedCallbacks[#loadedCallbacks + 1] = func end

-------------------------------------------------------------------------------
-- Spellbook scan
-------------------------------------------------------------------------------

local function RankNumber(subName)
	if type(subName) ~= "string" then return nil end
	return tonumber(subName:match("(%d+)"))
end

-- Every learned, non-passive spellbook entry whose name matches, lowest rank first.
-- Lower ranks are normal spellbook items; Blizzard's spellbook only hides them
-- (ShowAllSpellRanks CVar), so they are always present in this scan.
local function CollectRanks(familyName)
	local ranks, seen = {}, {}
	for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
		if lineInfo and not lineInfo.offSpecID then
			local first = lineInfo.itemIndexOffset + 1
			local last = lineInfo.itemIndexOffset + lineInfo.numSpellBookItems
			for slot = first, last do
				local info = C_SpellBook.GetSpellBookItemInfo(slot, BANK)
				if info and info.itemType == SPELL_ITEM and not info.isPassive
					and info.name == familyName and not seen[info.actionID] then
					seen[info.actionID] = true
					local sub = info.subName
					if not sub or sub == "" then
						sub = C_Spell.GetSpellSubtext(info.actionID) or ""
					end
					ranks[#ranks + 1] = {
						spellID = info.actionID,
						sub = sub,
						rank = RankNumber(sub),
						order = #ranks + 1,
					}
				end
			end
		end
	end
	table.sort(ranks, function(a, b)
		if a.rank and b.rank and a.rank ~= b.rank then return a.rank < b.rank end
		return a.order < b.order
	end)
	return ranks
end

local function RankLabel(entry)
	if not entry then return "" end
	return entry.rank and tostring(entry.rank) or ""
end

local function CurrentEntry(btn)
	local spellID = tonumber(btn:GetAttribute("spell"))
	if not spellID or not btn.ranks then return nil, spellID end
	for _, entry in ipairs(btn.ranks) do
		if entry.spellID == spellID then return entry, spellID end
	end
	return nil, spellID
end

-------------------------------------------------------------------------------
-- Macros (out of combat only)
-------------------------------------------------------------------------------

local function MacroTag(index)
	return ("RankFlyoutButton%d RightButton;"):format(index)
end

-- Finds this button's macro by its /click line, so renames and re-sorting are fine.
local function FindMacro(index)
	local tag = MacroTag(index)
	local numAccount, numCharacter = GetNumMacros()
	for i = MAX_ACCOUNT_MACROS + 1, MAX_ACCOUNT_MACROS + numCharacter do
		local _, _, body = GetMacroInfo(i)
		if body and body:find(tag, 1, true) then return i end
	end
	for i = 1, numAccount do
		local _, _, body = GetMacroInfo(i)
		if body and body:find(tag, 1, true) then return i end
	end
end

local function MacroContent(btn)
	local cfg = db.buttons[btn.index]
	local family = cfg and cfg.family or ""
	local entry = CurrentEntry(btn)
	local show = family
	if entry and entry.sub ~= "" then
		show = ("%s(%s)"):format(family, entry.sub)
	end
	-- The macro name is shown on the bar slot, so use the rank ("Rank 3").
	local name = (entry and entry.sub ~= "" and entry.sub) or family
	if name == "" then name = "Rank Flyout" end
	name = name:sub(1, 16)
	local body = ("#showtooltip %s\n/click [btn:2] RankFlyoutButton%d RightButton; RankFlyoutButton%d")
		:format(show, btn.index, btn.index)
	return name, body
end

-- Updates this button's macro. With create = true, makes one if it is missing.
-- Returns the macro index, or nil.
local function SyncMacro(btn, create)
	if InCombatLockdown() then
		pending.macros = true
		return nil
	end
	local name, body = MacroContent(btn)
	local index = FindMacro(btn.index)
	if index then
		local oldName, _, oldBody = GetMacroInfo(index)
		if oldName ~= name or oldBody ~= body then
			index = EditMacro(index, name, MACRO_ICON, body)
		end
		return index
	end
	if not create then return nil end

	local numAccount, numCharacter = GetNumMacros()
	if numCharacter < MAX_CHARACTER_MACROS then
		return CreateMacro(name, MACRO_ICON, body, true)
	elseif numAccount < MAX_ACCOUNT_MACROS then
		return CreateMacro(name, MACRO_ICON, body, false)
	end
	Print("your macro slots are full. Delete a macro and try again.")
	return nil
end

local function DeleteButtonMacro(index)
	local m = FindMacro(index)
	if m then DeleteMacro(m) end
end

-------------------------------------------------------------------------------
-- Finding the bar slot that holds a button's macro
-------------------------------------------------------------------------------

local BAR_BUTTONS = {}
do
	local prefixes = {
		"ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
		"MultiBarRightButton", "MultiBarLeftButton",
		"MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
	}
	for _, prefix in ipairs(prefixes) do
		for i = 1, 12 do BAR_BUTTONS[#BAR_BUTTONS + 1] = prefix .. i end
	end
	-- Common bar addons.
	for i = 1, 180 do BAR_BUTTONS[#BAR_BUTTONS + 1] = "BT4Button" .. i end
	for i = 1, 180 do BAR_BUTTONS[#BAR_BUTTONS + 1] = "DominosActionButton" .. i end
end

local function SlotOf(frame)
	local slot = frame.action or frame._state_action
	if type(slot) ~= "number" and frame.GetAttribute then
		slot = tonumber(frame:GetAttribute("action"))
	end
	return type(slot) == "number" and slot or nil
end

-- GetActionInfo on a macro slot returns the macro index, or (subType "spell")
-- the spell the macro shows. Accept either, checking the slot's name too.
local function FindBarButton(btn)
	local macroIndex = FindMacro(btn.index)
	if not macroIndex then return nil end
	local macroName = GetMacroInfo(macroIndex)
	local rankIDs = {}
	for _, entry in ipairs(btn.ranks or {}) do rankIDs[entry.spellID] = true end

	for _, frameName in ipairs(BAR_BUTTONS) do
		local frame = _G[frameName]
		if frame and frame:IsVisible() then
			local slot = SlotOf(frame)
			if slot then
				local kind, id, subType = GetActionInfo(slot)
				if kind == "macro" then
					if subType == "spell" then
						if rankIDs[id] and GetActionText(slot) == macroName then return frame end
					elseif id == macroIndex then
						return frame
					end
				end
			end
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Display helpers (insecure; only touch textures, text and cooldown frames)
-------------------------------------------------------------------------------

local function Skin(btn, size)
	btn:SetSize(size, size)

	local border = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	border:SetColorTexture(0, 0, 0, 1)

	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

	btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
	btn.cooldown:SetAllPoints()

	btn.rankText = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	btn.rankText:SetPoint("BOTTOMRIGHT", -2, 2)
end

local function UpdateCooldown(btn, spellID)
	-- Same pattern as Blizzard's ActionButton_ApplyCooldown: isActive is never
	-- secret, and the start/duration values go straight to the widget.
	local info = spellID and C_Spell.GetSpellCooldown(spellID)
	if info and info.isActive then
		btn.cooldown:SetCooldown(info.startTime, info.duration, info.modRate)
	else
		btn.cooldown:Clear()
	end
end

local function UpdateUsable(btn, spellID)
	local r, g, b = 1, 1, 1
	if spellID then
		local ok = pcall(function()
			local usable, noMana = C_Spell.IsSpellUsable(spellID)
			if noMana then
				r, g, b = 0.5, 0.5, 1
			elseif not usable then
				r, g, b = 0.4, 0.4, 0.4
			end
			if C_Spell.SpellHasRange(spellID) and UnitExists("target") then
				if C_Spell.IsSpellInRange(spellID, "target") == false then
					r, g, b = 0.8, 0.1, 0.1
				end
			end
		end)
		if not ok then r, g, b = 1, 1, 1 end
	end
	btn.icon:SetVertexColor(r, g, b)
end

local function ShortKey(key)
	key = key:upper()
	key = key:gsub("SHIFT%-", "s"):gsub("CTRL%-", "c"):gsub("ALT%-", "a")
	key = key:gsub("MOUSEWHEELUP", "MwU"):gsub("MOUSEWHEELDOWN", "MwD")
	key = key:gsub("BUTTON", "M"):gsub("NUMPAD", "N")
	return key
end

local function UpdateHotkey(btn)
	local key = GetBindingKey("CLICK " .. btn:GetName() .. ":LeftButton")
	btn.hotkey:SetText(key and ShortKey(key) or "")
end

local function UpdateMain(btn)
	local entry, spellID = CurrentEntry(btn)
	if spellID then
		btn.icon:SetTexture(C_Spell.GetSpellTexture(spellID) or EMPTY_ICON)
	else
		btn.icon:SetTexture(EMPTY_ICON)
	end
	btn.rankText:SetText(RankLabel(entry))
	UpdateCooldown(btn, spellID)
	UpdateUsable(btn, spellID)
	UpdateHotkey(btn)

	-- Highlight the chosen rank in the open menu.
	for _, rb in ipairs(btn.rankButtons) do
		rb.selected:SetShown(rb:IsShown() and rb.spellID == spellID)
	end
end

local function ForEachShown(func)
	for _, btn in pairs(buttons) do
		if btn:IsShown() then func(btn) end
	end
end

-------------------------------------------------------------------------------
-- Secure snippets
-------------------------------------------------------------------------------

local header = CreateFrame("Frame", "RankFlyoutHeader", UIParent, "SecureHandlerBaseTemplate")

-- Main button: right-click opens/closes the menu instead of casting.
-- Left-click casts as normal and closes the menu if it is open.
local MAIN_PRECLICK = [[
	local flyout = self:GetFrameRef("flyout")
	if button == "RightButton" then
		if not down and self:GetAttribute("rf-count") > 1 then
			if flyout:IsShown() then flyout:Hide() else flyout:Show() end
		end
		return false
	end
	if not down and flyout:IsShown() then
		flyout:Hide()
	end
]]

-- Arrow tab: toggles the menu.
local ARROW_ONCLICK = [[
	local flyout = self:GetFrameRef("flyout")
	if flyout:IsShown() then flyout:Hide() else flyout:Show() end
]]

-- Rank button: left-click makes this rank the main button's spell.
-- Right-click casts this rank once without changing the main button.
local RANK_PRECLICK = [[
	if button == "LeftButton" then
		if not down then
			self:GetFrameRef("main"):SetAttribute("spell", self:GetAttribute("spell"))
			self:GetFrameRef("flyout"):Hide()
		end
		return false
	end
	if not down then
		self:GetFrameRef("flyout"):Hide()
	end
]]

-------------------------------------------------------------------------------
-- Button construction (out of combat only)
-------------------------------------------------------------------------------

local function ShowSpellTooltip(owner, spellID, extraLines)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	if spellID then
		GameTooltip:SetSpellByID(spellID)
	else
		GameTooltip:SetText("Rank Flyout")
		GameTooltip:AddLine("Drop a spell from your spellbook here.", 1, 1, 1, true)
	end
	for _, line in ipairs(extraLines or {}) do
		GameTooltip:AddLine(line, 0.6, 0.8, 1)
	end
	GameTooltip:Show()
end

local function SaveChoice(btn, spellID)
	local cfg = db.buttons[btn.index]
	if not cfg then return end
	cfg.spellID = spellID
	local ranks = btn.ranks
	cfg.top = ranks and #ranks > 0 and ranks[#ranks].spellID == spellID or false
end

local AssignSpell -- forward declaration

local function CreateRankButton(main)
	local i = #main.rankButtons + 1
	local rb = CreateFrame("Button", main:GetName() .. "Rank" .. i, main.flyout, "SecureActionButtonTemplate")
	Skin(rb, RANK_SIZE)
	rb:RegisterForClicks("AnyUp", "AnyDown")
	rb:SetAttribute("type", "spell")

	rb.selected = rb:CreateTexture(nil, "OVERLAY")
	rb.selected:SetPoint("TOPLEFT", -3, 3)
	rb.selected:SetPoint("BOTTOMRIGHT", 3, -3)
	rb.selected:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	rb.selected:SetBlendMode("ADD")
	rb.selected:Hide()

	SecureHandlerSetFrameRef(rb, "main", main)
	SecureHandlerSetFrameRef(rb, "flyout", main.flyout)
	SecureHandlerWrapScript(rb, "OnClick", header, RANK_PRECLICK)

	rb:SetScript("OnEnter", function(self)
		ShowSpellTooltip(self, self.spellID, { "Left-click: use this rank", "Right-click: cast this rank once" })
	end)
	rb:SetScript("OnLeave", GameTooltip_Hide)

	main.rankButtons[i] = rb
	return rb
end

local function CreateMainButton(index)
	local b = CreateFrame("Button", "RankFlyoutButton" .. index, UIParent, "SecureActionButtonTemplate")
	b.index = index
	b.rankButtons = {}
	Skin(b, BUTTON_SIZE)
	b:SetMovable(true)
	b:SetClampedToScreen(true)
	b:RegisterForClicks("AnyUp", "AnyDown")
	b:RegisterForDrag("LeftButton")
	b:SetAttribute("type", "spell")
	b:SetAttribute("rf-count", 0)
	-- /click from a macro sends one click with down = false; act on that.
	b:SetAttribute("useOnKeyDown", false)

	b.hotkey = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
	b.hotkey:SetPoint("TOPRIGHT", -2, -2)

	-- Menu container. Parented to UIParent so it can sit beside a bar slot even
	-- when the floating button is hidden; protected so restricted code may
	-- show/hide it in combat.
	local flyout = CreateFrame("Frame", "RankFlyoutMenu" .. index, UIParent, "SecureFrameTemplate")
	flyout:SetFrameStrata("DIALOG")
	flyout:Hide()
	flyout.bg = flyout:CreateTexture(nil, "BACKGROUND")
	flyout.bg:SetAllPoints()
	flyout.bg:SetColorTexture(0, 0, 0, 0.55)
	b.flyout = flyout
	flyout:HookScript("OnShow", function() UpdateMain(b) end)

	-- Arrow tab on the edge facing the menu.
	local arrow = CreateFrame("Button", nil, b, "SecureHandlerClickTemplate")
	arrow:RegisterForClicks("AnyUp")
	arrow.tex = arrow:CreateTexture(nil, "OVERLAY")
	arrow.tex:SetAllPoints()
	arrow.tex:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
	arrow:SetHighlightTexture("Interface\\Buttons\\Arrow-Up-Up", "ADD")
	SecureHandlerSetFrameRef(arrow, "flyout", flyout)
	arrow:SetAttribute("_onclick", ARROW_ONCLICK)
	b.arrow = arrow

	SecureHandlerSetFrameRef(b, "flyout", flyout)
	SecureHandlerWrapScript(b, "OnClick", header, MAIN_PRECLICK)

	b:HookScript("OnAttributeChanged", function(self, name, value)
		if name == "spell" then
			SaveChoice(self, tonumber(value))
			UpdateMain(self)
			SyncMacro(self, false)
		end
	end)

	b:SetScript("OnDragStart", function(self)
		if InCombatLockdown() then return end
		if IsShiftKeyDown() then
			if not db.locked then self:StartMoving() end
			return
		end
		-- Plain drag: pick up this button's macro to drop on an action bar.
		if not (db.buttons[self.index] and db.buttons[self.index].family) then return end
		local m = SyncMacro(self, true)
		if m then PickupMacro(m) end
	end)
	b:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		local cfg = db.buttons[self.index]
		if cfg then cfg.point = { point, relPoint, x, y } end
	end)
	b:SetScript("OnReceiveDrag", function(self)
		local kind, slot, _, spellID = GetCursorInfo()
		if kind ~= "spell" then return end
		if not spellID and slot then
			local info = C_SpellBook.GetSpellBookItemInfo(slot, BANK)
			spellID = info and info.actionID
		end
		if spellID then
			ClearCursor()
			AssignSpell(self.index, spellID)
		end
	end)
	b:SetScript("OnEnter", function(self)
		local _, spellID = CurrentEntry(self)
		local lines = { "Right-click or arrow: choose rank", "Drag: put on an action bar" }
		if not db.locked then lines[#lines + 1] = "Shift-drag: move" end
		ShowSpellTooltip(self, spellID, lines)
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)

	buttons[index] = b
	return b
end

-------------------------------------------------------------------------------
-- Layout (out of combat only)
-------------------------------------------------------------------------------

local DIRECTIONS = {
	UP    = { anchor = "BOTTOM", rel = "TOP",    dx = 0,  dy = 1,  arrowRot = 0 },
	DOWN  = { anchor = "TOP",    rel = "BOTTOM", dx = 0,  dy = -1, arrowRot = math.pi },
	LEFT  = { anchor = "RIGHT",  rel = "LEFT",   dx = -1, dy = 0,  arrowRot = math.pi / 2 },
	RIGHT = { anchor = "LEFT",   rel = "RIGHT",  dx = 1,  dy = 0,  arrowRot = -math.pi / 2 },
}

-- The menu opens beside the bar slot holding this button's macro if there is
-- one on screen, otherwise beside the floating button.
local function AnchorFlyout(b)
	if InCombatLockdown() then
		pending.anchors = true
		return
	end
	local dir = DIRECTIONS[db.direction] or DIRECTIONS.UP
	local target = FindBarButton(b) or b
	b.flyout:ClearAllPoints()
	b.flyout:SetPoint(dir.anchor, target, dir.rel, 0, 0)
	b.flyout:SetScale(db.scale) -- parented to UIParent, so it needs its own scale
	b.anchoredTo = target
end

local function LayoutFlyout(b, count)
	local dir = DIRECTIONS[db.direction] or DIRECTIONS.UP
	local flyout, arrow = b.flyout, b.arrow
	local length = count * RANK_SIZE + (count + 1) * RANK_GAP
	local width = RANK_SIZE + 2 * RANK_GAP

	if dir.dx == 0 then
		flyout:SetSize(width, length + FLYOUT_GAP)
	else
		flyout:SetSize(length + FLYOUT_GAP, width)
	end

	-- Highest rank sits next to the button, lower ranks further out.
	for i = 1, count do
		local rb = b.rankButtons[i]
		local offset = FLYOUT_GAP + RANK_GAP + (i - 1) * (RANK_SIZE + RANK_GAP)
		rb:ClearAllPoints()
		rb:SetPoint(dir.anchor, flyout, dir.anchor, dir.dx * offset, dir.dy * offset)
	end

	arrow:ClearAllPoints()
	if dir.dx == 0 then
		arrow:SetSize(16, 10)
	else
		arrow:SetSize(10, 16)
	end
	arrow:SetPoint("CENTER", b, dir.rel, dir.dx * 3, dir.dy * 3)
	arrow.tex:SetRotation(dir.arrowRot)
	arrow:GetHighlightTexture():SetRotation(dir.arrowRot)
	arrow:SetShown(count > 1)

	AnchorFlyout(b)
end

local function PlaceButton(b, cfg)
	b:ClearAllPoints()
	if cfg.point then
		b:SetPoint(cfg.point[1], UIParent, cfg.point[2], cfg.point[3], cfg.point[4])
	else
		b:SetPoint("CENTER", UIParent, "CENTER", (b.index - 1) * (BUTTON_SIZE + 6), -120)
	end
	b:SetScale(db.scale)

	-- "Hidden" floating buttons stay shown but invisible and click-through, so
	-- /click and key bindings still reach them.
	local float = db.float ~= false
	b:SetAlpha(float and 1 or 0)
	b:EnableMouse(float)
	b.arrow:EnableMouse(float)
end

local function Rebuild(index)
	local cfg = db.buttons[index]
	local b = buttons[index]
	if not cfg then
		if b then
			b.flyout:Hide()
			b:Hide()
		end
		return
	end
	b = b or CreateMainButton(index)

	local ranks = cfg.family and CollectRanks(cfg.family) or {}
	b.ranks = ranks
	local count = #ranks

	-- Pick the rank to hold: saved choice if still known, else the highest.
	-- If the player had the highest rank chosen, follow newly learned ranks.
	local chosen
	if count > 0 then
		chosen = ranks[count].spellID
		if cfg.spellID and not cfg.top then
			for _, entry in ipairs(ranks) do
				if entry.spellID == cfg.spellID then chosen = entry.spellID break end
			end
		end
	end

	for i = 1, count do
		local rb = b.rankButtons[i] or CreateRankButton(b)
		local entry = ranks[count - i + 1] -- highest first
		rb.spellID = entry.spellID
		rb:SetAttribute("spell", entry.spellID)
		rb.icon:SetTexture(C_Spell.GetSpellTexture(entry.spellID) or EMPTY_ICON)
		rb.rankText:SetText(RankLabel(entry))
		rb:Show()
	end
	for i = count + 1, #b.rankButtons do
		b.rankButtons[i].spellID = nil
		b.rankButtons[i]:Hide()
	end

	b:SetAttribute("rf-count", count)
	PlaceButton(b, cfg)
	b:Show()
	LayoutFlyout(b, count)

	b:SetAttribute("spell", chosen)
	SaveChoice(b, chosen)
	UpdateMain(b)
	SyncMacro(b, false)
	ns.Changed()
end

local function RebuildAll()
	if InCombatLockdown() then
		pending.rebuild = true
		return
	end
	pending.rebuild = nil
	for i = 1, MAX_BUTTONS do
		Rebuild(i)
	end
end

local function AnchorAll()
	for i = 1, MAX_BUTTONS do
		if buttons[i] and db.buttons[i] then AnchorFlyout(buttons[i]) end
	end
end

local anchorQueued = false
local function QueueAnchorAll()
	if anchorQueued then return end
	anchorQueued = true
	C_Timer.After(0.1, function()
		anchorQueued = false
		AnchorAll()
	end)
end

-- quiet: skip the chat message (the picker explains itself).
AssignSpell = function(index, spellID, quiet)
	if InCombatLockdown() then
		Print("can't change buttons in combat.")
		return false
	end
	local name = C_Spell.GetSpellName(spellID)
	if not name then
		Print("couldn't find that spell.")
		return false
	end
	local cfg = db.buttons[index] or {}
	db.buttons[index] = cfg
	cfg.family = name
	cfg.spellID = nil
	cfg.top = true
	Rebuild(index)
	local n = #buttons[index].ranks
	if n == 0 then
		Print(name .. " isn't in your spellbook.")
	elseif not quiet then
		Print(("button %d now holds %s (%d rank%s known). Drag it onto an action bar to use it there.")
			:format(index, name, n, n == 1 and "" or "s"))
	end
	return n > 0
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function FreeIndex()
	for i = 1, MAX_BUTTONS do
		if not db.buttons[i] then return i end
	end
end

local function FindSpellID(text)
	local info = C_Spell.GetSpellInfo(text)
	return info and info.spellID
end

-------------------------------------------------------------------------------
-- Shared actions (used by slash commands, the spell picker and the minimap menu)
-------------------------------------------------------------------------------

ns.CollectRanks = CollectRanks
ns.CurrentEntry = CurrentEntry
ns.DIRECTIONS = DIRECTIONS

function ns.GetButton(index) return buttons[index] end

-- Index of the button holding this spell family, if any.
function ns.FindFamily(name)
	for i = 1, MAX_BUTTONS do
		local cfg = db.buttons[i]
		if cfg and cfg.family == name then return i end
	end
end

-- Makes (or reuses) the button for a spell and puts its macro on the cursor.
function ns.PickUpSpell(spellID)
	if InCombatLockdown() then
		Print("can't make macros in combat.")
		return
	end
	local name = C_Spell.GetSpellName(spellID)
	if not name then return end
	local index = ns.FindFamily(name)
	if not index then
		index = FreeIndex()
		if not index then
			Print("all " .. MAX_BUTTONS .. " buttons are in use. Remove one first.")
			return
		end
		if not AssignSpell(index, spellID, true) then
			db.buttons[index] = nil
			Rebuild(index)
			return
		end
	end
	local m = SyncMacro(buttons[index], true)
	if m then
		PickupMacro(m)
		return index
	end
end

function ns.RemoveButton(n)
	if InCombatLockdown() then
		Print("can't change buttons in combat.")
		return false
	end
	if not db.buttons[n] then return false end
	DeleteButtonMacro(n)
	db.buttons[n] = nil
	Rebuild(n)
	ns.Changed()
	return true
end

function ns.SetFloat(on)
	if InCombatLockdown() then Print("can't change buttons in combat.") return end
	db.float = on and true or false
	RebuildAll()
end

function ns.SetLocked(on)
	db.locked = on and true or false
	ns.Changed()
end

function ns.SetDirection(dir)
	if InCombatLockdown() then Print("can't change buttons in combat.") return end
	if DIRECTIONS[dir] then
		db.direction = dir
		RebuildAll()
	end
end

local HELP = {
	"/rf spells - open the spell picker (or click the minimap button)",
	"/rf add [spell name] - new button (or drop a spell on an empty one)",
	"Drag a button onto an action bar to use it from there.",
	"  On the bar: click or hotkey casts, right-click opens the rank menu.",
	"/rf macro <n> - pick up button n's macro to place on a bar",
	"/rf float on | off - show or hide the floating buttons",
	"/rf set <n> <spell name> - change what button n holds",
	"/rf remove <n> - remove button n and its macro",
	"/rf list - show your buttons",
	"/rf lock | unlock - stop or allow Shift-drag moving",
	"/rf dir up | down | left | right - which way the menu opens",
	"/rf scale <0.5-2> - button size",
	"/rf reset - move buttons back to the middle",
	"/rf minimap on | off - show or hide the minimap button",
}

local function HandleSlash(msg)
	local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()

	local outOfCombatOnly = {
		add = true, set = true, remove = true, dir = true, scale = true,
		reset = true, macro = true, float = true,
	}
	if outOfCombatOnly[cmd] and InCombatLockdown() then
		Print("can't change buttons in combat.")
		return
	end

	if cmd == "add" then
		local index = FreeIndex()
		if not index then
			Print("all " .. MAX_BUTTONS .. " buttons are in use.")
			return
		end
		if rest ~= "" then
			local spellID = FindSpellID(rest)
			if not spellID then
				Print("couldn't find a spell called \"" .. rest .. "\".")
				return
			end
			AssignSpell(index, spellID)
		else
			db.buttons[index] = {}
			Rebuild(index)
			Print(("button %d added. Drop a spell from your spellbook on it."):format(index))
		end
	elseif cmd == "set" then
		local n, name = rest:match("^(%d+)%s+(.+)$")
		n = tonumber(n)
		local spellID = name and FindSpellID(name)
		if not n or not db.buttons[n] then
			Print("usage: /rf set <button number> <spell name>")
		elseif not spellID then
			Print("couldn't find that spell.")
		else
			AssignSpell(n, spellID)
		end
	elseif cmd == "remove" then
		local n = tonumber(rest)
		if n and ns.RemoveButton(n) then
			Print(("button %d and its macro removed."):format(n))
		else
			Print("usage: /rf remove <button number>")
		end
	elseif cmd == "spells" then
		if ns.TogglePicker then ns.TogglePicker() end
	elseif cmd == "minimap" then
		if rest == "on" or rest == "off" then
			db.minimap.hide = rest == "off"
			if ns.UpdateMinimapButton then ns.UpdateMinimapButton() end
			Print(rest == "on" and "minimap button shown." or "minimap button hidden. /rf minimap on brings it back.")
		else
			Print("usage: /rf minimap on | off")
		end
	elseif cmd == "macro" then
		local n = tonumber(rest)
		local b = n and buttons[n]
		if not (b and db.buttons[n] and db.buttons[n].family) then
			Print("usage: /rf macro <button number> (the button needs a spell)")
			return
		end
		local m = SyncMacro(b, true)
		if m then
			PickupMacro(m)
			Print("macro on your cursor - click an action bar slot to place it.")
		end
	elseif cmd == "float" then
		if rest == "on" or rest == "off" then
			db.float = rest == "on"
			RebuildAll()
			Print(db.float and "floating buttons shown." or "floating buttons hidden. /rf float on brings them back.")
		else
			Print("usage: /rf float on | off")
		end
	elseif cmd == "list" then
		local any = false
		for i = 1, MAX_BUTTONS do
			local cfg = db.buttons[i]
			if cfg then
				any = true
				local b = buttons[i]
				local entry = b and CurrentEntry(b)
				local onBar = b and b.anchoredTo and b.anchoredTo ~= b
				Print(("%d: %s%s%s"):format(i, cfg.family or "(empty)",
					entry and entry.rank and (" - rank " .. entry.rank) or "",
					onBar and " (on a bar)" or ""))
			end
		end
		if not any then Print("no buttons yet. Try /rf add") end
	elseif cmd == "lock" or cmd == "unlock" then
		ns.SetLocked(cmd == "lock")
		Print(db.locked and "buttons locked." or "buttons unlocked - Shift-drag to move.")
	elseif cmd == "dir" then
		local dir = rest:upper()
		if DIRECTIONS[dir] then
			db.direction = dir
			RebuildAll()
			Print("menu opens " .. rest:lower() .. ".")
		else
			Print("usage: /rf dir up | down | left | right")
		end
	elseif cmd == "scale" then
		local s = tonumber(rest)
		if s and s >= 0.5 and s <= 2 then
			db.scale = s
			RebuildAll()
		else
			Print("usage: /rf scale <0.5 to 2>")
		end
	elseif cmd == "reset" then
		for _, cfg in pairs(db.buttons) do cfg.point = nil end
		db.float = true
		RebuildAll()
	else
		for _, line in ipairs(HELP) do Print(line) end
	end
end

SLASH_RANKFLYOUT1 = "/rankflyout"
SLASH_RANKFLYOUT2 = "/rf"
SlashCmdList.RANKFLYOUT = HandleSlash

BINDING_HEADER_RANKFLYOUT = "Rank Flyout"
for i = 1, MAX_BUTTONS do
	_G["BINDING_NAME_CLICK RankFlyoutButton" .. i .. ":LeftButton"] = "Rank Flyout button " .. i
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")

local rangeElapsed = 0
local function OnUpdate(_, elapsed)
	rangeElapsed = rangeElapsed + elapsed
	if rangeElapsed < 0.2 then return end
	rangeElapsed = 0
	ForEachShown(function(b)
		local _, spellID = CurrentEntry(b)
		UpdateUsable(b, spellID)
	end)
end

events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then return end
		self:UnregisterEvent("ADDON_LOADED")
		RankFlyoutDB = RankFlyoutDB or {}
		db = RankFlyoutDB
		db.buttons = db.buttons or {}
		db.direction = db.direction or "UP"
		db.scale = db.scale or 1
		if db.locked == nil then db.locked = false end
		if db.float == nil then db.float = true end
		db.minimap = db.minimap or {}
		db.minimap.angle = db.minimap.angle or 200
		ns.db = db
		for _, func in ipairs(loadedCallbacks) do func() end

		self:RegisterEvent("PLAYER_LOGIN")
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("SPELLS_CHANGED")
		self:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
		self:RegisterEvent("UPDATE_BINDINGS")
		self:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
		self:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
		self:RegisterEvent("UPDATE_MACROS")
		self:SetScript("OnUpdate", OnUpdate)
	elseif event == "PLAYER_LOGIN" or event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_SKILL_LINE" then
		RebuildAll()
		ns.Changed() -- the picker refreshes even if the rebuild waits for combat to end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pending.rebuild then
			pending.rebuild, pending.macros, pending.anchors = nil, nil, nil
			RebuildAll() -- also syncs macros and anchors
		else
			if pending.macros then
				pending.macros = nil
				for i = 1, MAX_BUTTONS do
					if buttons[i] and db.buttons[i] then SyncMacro(buttons[i], false) end
				end
			end
			if pending.anchors then
				pending.anchors = nil
				AnchorAll()
			end
		end
	elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED"
		or event == "UPDATE_MACROS" or event == "PLAYER_ENTERING_WORLD" then
		QueueAnchorAll()
	elseif event == "SPELL_UPDATE_COOLDOWN" then
		ForEachShown(function(b)
			local _, spellID = CurrentEntry(b)
			UpdateCooldown(b, spellID)
		end)
	elseif event == "UPDATE_BINDINGS" then
		ForEachShown(UpdateHotkey)
	end
end)

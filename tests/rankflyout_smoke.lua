-- Smoke test for Rank Flyout with a stubbed WoW API (Lua 5.1 / fengari).
-- Run from the addon folder:  lua tests/rankflyout_smoke.lua .
-- (A host can instead set the global ADDON_DIR before running it.)
-- It checks the spellbook scan, rebuild, macros, picker, minimap, slash commands
-- and the secure snippets' logic. It does NOT prove the real client's secure
-- environment accepts them.

ADDON_DIR = ADDON_DIR or (...) or "."
local out = print
local loadstring = loadstring or load -- fengari is Lua 5.3
local passed, failed = 0, 0
local function check(cond, name)
	if cond then passed = passed + 1 else failed = failed + 1; out("FAIL: " .. name) end
end

---------------------------------------------------------------- stub widgets
local inCombat = false
local frames = {}
local wraps = {}      -- [frame] = preBody
local function noop() end

local Frame = {}
Frame.__index = function(t, k)
	local v = rawget(Frame, k)
	if v ~= nil then return v end
	-- Unknown widget methods (capitalised) are no-ops; unknown fields stay nil.
	if type(k) == "string" and k:match("^%u") then return noop end
	return nil
end

local function NewFrame(kind, name, parent, template)
	local f = setmetatable({ kind = kind, name = name, parent = parent, template = template or "",
		attrs = {}, scripts = {}, hooks = {}, shown = true, refs = {} }, Frame)
	if name then _G[name] = f end
	frames[#frames + 1] = f
	if f.template == "ButtonFrameTemplate" then f.Inset = NewFrame("Frame", nil, f) end
	return f
end

function Frame:GetName() return self.name end
function Frame:SetAttribute(k, v)
	self.attrs[k] = v
	for _, h in ipairs(self.hooks.OnAttributeChanged or {}) do h(self, k, v) end
end
function Frame:GetAttribute(k) return self.attrs[k] end
function Frame:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end
	for _, h in ipairs(self.hooks.OnShow or {}) do h(self) end end
function Frame:Hide() self.shown = false end
function Frame:SetShown(s) if s then self:Show() else self:Hide() end end
function Frame:IsShown() return self.shown end
function Frame:SetScript(k, fn) self.scripts[k] = fn end
function Frame:HookScript(k, fn) self.hooks[k] = self.hooks[k] or {}; table.insert(self.hooks[k], fn) end
function Frame:CreateTexture() return NewFrame("Texture") end
function Frame:CreateFontString() local fs = NewFrame("FontString"); fs.SetText = function(s, t) s.text = t end; return fs end
function Frame:GetHighlightTexture() return NewFrame("Texture") end
function Frame:GetPoint() return "CENTER", nil, "CENTER", 10, 20 end
function Frame:SetTexture(t) self.texture = t end
function Frame:RegisterEvent(e) local ev = rawget(self, "events") or {}; self.events = ev; ev[e] = true end
function Frame:UnregisterEvent(e) local ev = rawget(self, "events"); if ev then ev[e] = nil end end
-- Secret values: the client errors when addon (tainted) code passes one to a
-- function marked AllowedWhenUntainted, such as Cooldown:SetCooldown.
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
function issecretvalue(v) return rawequal(v, SECRET) end
function Frame:SetCooldown(s, d, m)
	if issecretvalue(s) or issecretvalue(d) or issecretvalue(m) then
		error("SetCooldown: secret value passed from tainted code")
	end
	self.cd = { s, d }
end
function Frame:SetVertexColor(r, g, b) self.tint = { r, g, b } end
function Frame:Clear() self.cd = nil end
function Frame:SetSize(w, h) self.w, self.h = w, h end
function Frame:SetPoint(p, rel, rp) if type(rel) == "table" then self.anchor = rel end end
function Frame:IsVisible() return self.shown end
function Frame:SetAlpha(a) self.alpha = a end
function Frame:EnableMouse(e) self.mouse = e end
function Frame:SetText(t) self.text = t end
function Frame:SetFormattedText(f, ...) self.text = f:format(...) end
function Frame:SetChecked(c) self.checked = c end
function Frame:GetChecked() return self.checked end
function Frame:SetEnabled(e) self.enabled = e end
function Frame:SetID(id) self.id = id end
function Frame:GetID() return self.id end
function Frame:GetWidth() return self.w or 140 end
function Frame:SetScale(s) self.scale = s end

function CreateFrame(kind, name, parent, template) return NewFrame(kind, name, parent, template) end
UIParent = NewFrame("Frame", "UIParent")
GameTooltip = NewFrame("GameTooltip", "GameTooltip")
GameTooltip_Hide = noop
Minimap = NewFrame("Minimap", "Minimap")
UISpecialFrames = {}
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function UnitClass() return "Mage", "MAGE" end
function PanelTemplates_SetTab(f, id) f.selectedTab = id end
function PanelTemplates_SetNumTabs(f, n) f.numTabs = n end
PanelTemplates_TabResize = noop

function SecureHandlerSetFrameRef(frame, label, ref) frame.refs[label] = ref end
function SecureHandlerWrapScript(frame, script, header, pre) wraps[frame] = pre end

SlashCmdList = {}
C_Timer = { After = function(_, fn) fn() end }
Constants = { MacroConsts = { MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 30 } }

-- Macros: account 1..120, character 121..150, kept in creation order here.
local macros = {}          -- [index] = { name, icon, body }
local pickedUp
function GetNumMacros()
	local a, c = 0, 0
	for i in pairs(macros) do if i > 120 then c = c + 1 else a = a + 1 end end
	return a, c
end
function GetMacroInfo(i) local m = macros[i]; if m then return m.name, m.icon, m.body end end
function CreateMacro(name, icon, body, perChar)
	assert(not inCombat, "CreateMacro in combat")
	local i = perChar and 121 or 1
	while macros[i] do i = i + 1 end
	macros[i] = { name = name, icon = icon, body = body }
	return i
end
function EditMacro(i, name, icon, body)
	assert(not inCombat, "EditMacro in combat")
	macros[i] = { name = name, icon = icon, body = body }
	return i
end
function DeleteMacro(i) assert(not inCombat, "DeleteMacro in combat"); macros[i] = nil end
function PickupMacro(i) assert(not inCombat, "PickupMacro in combat"); pickedUp = i end

-- Action bar: slot 5 on ActionButton5; macro slots report the shown spell.
local barSlots = {}        -- [slot] = macroIndex
function GetActionInfo(slot)
	local m = barSlots[slot]
	if not m then return nil end
	return "macro", 205, "spell" -- macro shows Frostbolt Rank 2 in this test
end
function GetActionText(slot) local m = barSlots[slot]; return m and macros[m] and macros[m].name end
function InCombatLockdown() return inCombat end
function IsShiftKeyDown() return false end
function UnitExists() return true end
function GetBindingKey(cmd) if cmd == "CLICK RankFlyoutButton1:LeftButton" then return "SHIFT-BUTTON4" end end
local cursor
function GetCursorInfo() if cursor then return "spell", 3, "spell", cursor end end
function ClearCursor() cursor = nil end
local printed = {}
function print(...) local s = table.concat({ ... }, " "); printed[#printed + 1] = s end

---------------------------------------------------------------- stub spells
Enum = { SpellBookSpellBank = { Player = 0 }, SpellBookItemType = { Spell = 1, Flyout = 2 } }
local book = {
	{ name = "Fireball",  actionID = 133, sub = "Rank 1" },
	{ name = "Frostbolt", actionID = 116, sub = "Rank 1" },
	{ name = "Frostbolt", actionID = 205, sub = "Rank 2" },
	{ name = "Frostbolt", actionID = 837, sub = "Rank 3" },
	{ name = "Frost Armor", actionID = 168, sub = "", passive = false },
	{ name = "Frostbolt Passive", actionID = 999, sub = "", passive = true },
}
local spellByID = {}
local function index() spellByID = {}; for _, s in ipairs(book) do spellByID[s.actionID] = s end end
index()

C_SpellBook = {
	GetNumSpellBookSkillLines = function() return 2 end,
	GetSpellBookSkillLineInfo = function(i)
		if i == 1 then return { itemIndexOffset = 0, numSpellBookItems = 0 } end
		return { itemIndexOffset = 0, numSpellBookItems = #book }
	end,
	GetSpellBookItemInfo = function(slot)
		local s = book[slot]
		if not s then return nil end
		return { name = s.name, actionID = s.actionID, spellID = s.actionID, subName = s.sub,
			itemType = 1, isPassive = s.passive or false, iconID = 1 }
	end,
}
C_Spell = {
	GetSpellSubtext = function(id) return spellByID[id] and spellByID[id].sub end,
	GetSpellTexture = function(id) return 1000 + id end,
	GetSpellName = function(id) return spellByID[id] and spellByID[id].name end,
	GetSpellInfo = function(name)
		for i = #book, 1, -1 do if book[i].name == name then return { spellID = book[i].actionID } end end
	end,
	GetSpellCooldown = function(id) return { isActive = id == 837, startTime = 5, duration = 8, modRate = 1 } end,
	IsSpellUsable = function() return true, false end,
	SpellHasRange = function() return true end,
	IsSpellInRange = function() return true end,
}

---------------------------------------------------------------- secure snippet runner
-- Runs a wrapped preBody like the restricted environment would: `self` is a
-- handle, `button` and `down` are locals.
local function Handle(f)
	return {
		GetFrameRef = function(_, l) return Handle(f.refs[l]) end,
		GetAttribute = function(_, k) return f:GetAttribute(k) end,
		SetAttribute = function(_, k, v) f:SetAttribute(k, v) end,
		IsShown = function() return f:IsShown() end,
		Show = function() f:Show() end,
		Hide = function() f:Hide() end,
	}
end
local function RunSnippet(body, frame, button, down)
	local chunk = assert(loadstring("local self, button, down = ...\n" .. body))
	return chunk(Handle(frame), button, down)
end
local function Click(frame, button)
	local pre = wraps[frame]
	if pre then
		local r1 = RunSnippet(pre, frame, button, true)
		local r2 = RunSnippet(pre, frame, button, false)
		return r1, r2
	end
end

---------------------------------------------------------------- load addon
local ns = {}
for _, file in ipairs({ "RankFlyout.lua", "Picker.lua", "Minimap.lua" }) do
	local chunk = assert(loadfile((ADDON_DIR or ".") .. "/" .. file))
	chunk("RankFlyout", ns)
end
local events
for _, f in ipairs(frames) do
	local ev = rawget(f, "events")
	if ev and ev.ADDON_LOADED then events = f end
end
check(events ~= nil, "event frame registered ADDON_LOADED")
events.scripts.OnEvent(events, "ADDON_LOADED", "RankFlyout")
check(type(RankFlyoutDB) == "table", "saved variables created")
events.scripts.OnEvent(events, "PLAYER_LOGIN")
check(RankFlyoutButton1 == nil, "no buttons before /rf add")

-- add by name
SlashCmdList.RANKFLYOUT("add Frostbolt")
local b = RankFlyoutButton1
check(b ~= nil and b:IsShown(), "button 1 created")
check(b:GetAttribute("type") == "spell", "main button type is spell")
check(b:GetAttribute("spell") == 837, "defaults to highest rank (837)")
check(b:GetAttribute("rf-count") == 3, "three ranks found, passive ignored")
check(b.rankText.text == "3", "rank label shows 3")
check(b.hotkey.text == "sM4", "hotkey abbreviated")
check(b.cooldown.cd and b.cooldown.cd[2] == 8, "cooldown applied for active spell")
check(RankFlyoutDB.buttons[1].top == true, "follow-highest flag set")
check(b.rankButtons[1]:GetAttribute("spell") == 837 and b.rankButtons[3]:GetAttribute("spell") == 116,
	"menu lists highest first")
check(b.arrow.shown, "arrow shown with several ranks")

-- right-click main toggles menu, never casts
check(not b.flyout:IsShown(), "menu starts hidden")
local r1, r2 = Click(b, "RightButton")
check(r1 == false and r2 == false, "right-click on main is cancelled")
check(b.flyout:IsShown(), "right-click opens menu")
Click(b, "RightButton")
check(not b.flyout:IsShown(), "second right-click closes menu")

-- choose rank 1 from the menu (in combat)
inCombat = true
Click(b, "RightButton")
local r1b, r2b = Click(b.rankButtons[3], "LeftButton")
check(r1b == false and r2b == false, "left-click on a rank does not cast")
check(b:GetAttribute("spell") == 116, "rank 1 selected in combat")
check(not b.flyout:IsShown(), "menu closes after choosing")
check(b.rankText.text == "1", "label updated to rank 1")
check(RankFlyoutDB.buttons[1].spellID == 116 and RankFlyoutDB.buttons[1].top == false, "choice saved")

-- right-click a rank casts once without swapping
Click(b, "RightButton")
local c1 = Click(b.rankButtons[2], "RightButton")
check(c1 == nil, "right-click on a rank is allowed to cast")
check(b:GetAttribute("spell") == 116, "main button unchanged by one-off cast")

-- left-click main casts and closes menu
Click(b, "RightButton")
local m1 = Click(b, "LeftButton")
check(m1 == nil, "left-click on main is allowed to cast")
check(not b.flyout:IsShown(), "left-click closes open menu")

-- learning a new rank in combat waits, then keeps the lower choice
table.insert(book, { name = "Frostbolt", actionID = 8406, sub = "Rank 4" }); index()
events.scripts.OnEvent(events, "SPELLS_CHANGED")
check(b:GetAttribute("rf-count") == 3, "no rebuild in combat")
inCombat = false
events.scripts.OnEvent(events, "PLAYER_REGEN_ENABLED")
check(b:GetAttribute("rf-count") == 4, "rebuilt after combat")
check(b:GetAttribute("spell") == 116, "lower-rank choice kept")

-- follow highest when the top rank was chosen
b:SetAttribute("spell", 8406)
table.insert(book, { name = "Frostbolt", actionID = 8407, sub = "Rank 5" }); index()
events.scripts.OnEvent(events, "SPELLS_CHANGED")
check(b:GetAttribute("spell") == 8407, "follows a newly learned top rank")

-- empty button + drop a spell
SlashCmdList.RANKFLYOUT("add")
local b2 = RankFlyoutButton2
check(b2 and b2:GetAttribute("spell") == nil, "empty second button")
check(not b2.arrow.shown, "no arrow without ranks")
local r = Click(b2, "RightButton")
check(not b2.flyout:IsShown(), "right-click does nothing with no ranks")
cursor = 133
b2.scripts.OnReceiveDrag(b2)
check(b2:GetAttribute("spell") == 133 and cursor == nil, "dropping Fireball assigns it")
check(not b2.arrow.shown, "single rank hides arrow")

-- combat blocks changes
inCombat = true
SlashCmdList.RANKFLYOUT("remove 2")
check(b2:IsShown(), "remove refused in combat")
inCombat = false
SlashCmdList.RANKFLYOUT("remove 2")
check(not b2:IsShown() and RankFlyoutDB.buttons[2] == nil, "remove works out of combat")

-- direction / scale / unknown spell / help
SlashCmdList.RANKFLYOUT("dir left")
check(RankFlyoutDB.direction == "LEFT", "direction saved")
SlashCmdList.RANKFLYOUT("scale 1.5")
check(b.scale == 1.5, "scale applied")
local before = #printed
SlashCmdList.RANKFLYOUT("add Pyroblast")
check(printed[#printed]:find("couldn't find"), "unknown spell reported")
SlashCmdList.RANKFLYOUT("")
check(#printed > before + 5, "help printed")
SlashCmdList.RANKFLYOUT("list")

check(_G["BINDING_NAME_CLICK RankFlyoutButton1:LeftButton"] ~= nil, "binding names defined")

---------------------------------------------------------------- macro route
check(b:GetAttribute("useOnKeyDown") == false, "main button acts on the /click (down = false)")
check(b.flyout.parent == UIParent, "menu parented to UIParent")

-- plain drag picks up a new character macro
b:SetAttribute("spell", 205) -- choose Rank 2
pickedUp = nil
b.scripts.OnDragStart(b)
local mi = pickedUp
check(mi and mi > 120, "drag created a character macro and picked it up")
check(macros[mi].name == "Rank 2", "macro named after the rank")
check(macros[mi].body == "#showtooltip Frostbolt(Rank 2)\n/click [btn:2] RankFlyoutButton1 RightButton; RankFlyoutButton1",
	"macro body: tooltip for the rank, click / right-click lines")

-- dragging again reuses the same macro
pickedUp = nil
b.scripts.OnDragStart(b)
check(pickedUp == mi, "second drag reuses the macro")

-- rank change out of combat edits the macro right away
b:SetAttribute("spell", 116)
check(macros[mi].name == "Rank 1" and macros[mi].body:find("Frostbolt%(Rank 1%)"), "macro follows rank change")

-- rank change in combat waits until combat ends
inCombat = true
Click(b, "RightButton")
local r4
for _, rb in ipairs(b.rankButtons) do if rb.spellID == 837 then r4 = rb end end
Click(r4, "LeftButton")
check(b:GetAttribute("spell") == 837, "swap in combat still works")
check(macros[mi].name == "Rank 1", "macro untouched during combat")
inCombat = false
events.scripts.OnEvent(events, "PLAYER_REGEN_ENABLED")
check(macros[mi].name == "Rank 3", "macro synced after combat")

-- macro placed on a bar: menu anchors to that slot
b:SetAttribute("spell", 205)
ActionButton5 = NewFrame("CheckButton", "ActionButton5")
ActionButton5.action = 5
barSlots[5] = mi
events.scripts.OnEvent(events, "ACTIONBAR_SLOT_CHANGED", 5)
check(b.flyout.anchor == ActionButton5, "menu opens beside the bar slot")

-- bar right-click: /click RankFlyoutButton1 RightButton (one click, down = false)
local function SlashClick(button)
	local pre = wraps[b]
	return RunSnippet(pre, b, button, false)
end
SlashClick("RightButton")
check(b.flyout:IsShown(), "right-click on bar slot opens menu")
SlashClick("LeftButton")
check(not b.flyout:IsShown(), "click on bar slot closes menu and casts")

-- a slot holding someone else's macro with the same spell is ignored
barSlots[5] = nil
macros[7] = { name = "Nuke", icon = 1, body = "#showtooltip\n/cast Frostbolt" }
barSlots[5] = 7
events.scripts.OnEvent(events, "ACTIONBAR_SLOT_CHANGED", 5)
check(b.flyout.anchor == b, "other macros don't capture the menu")

-- float off: invisible, click-through, still shown for /click
SlashCmdList.RANKFLYOUT("float off")
check(b:IsShown() and b.alpha == 0 and b.mouse == false, "float off hides the button but keeps it clickable")
SlashCmdList.RANKFLYOUT("float on")
check(b.alpha == 1 and b.mouse == true, "float on restores it")

-- /rf macro in combat refused; /rf remove deletes the macro
inCombat = true
pickedUp = nil
SlashCmdList.RANKFLYOUT("macro 1")
check(pickedUp == nil, "/rf macro refused in combat")
inCombat = false
SlashCmdList.RANKFLYOUT("macro 1")
check(pickedUp == mi, "/rf macro picks up the macro")
SlashCmdList.RANKFLYOUT("remove 1")
check(macros[mi] == nil and macros[7] ~= nil, "remove deletes only this button's macro")

---------------------------------------------------------------- minimap + spell picker
local mm = RankFlyoutMinimapButton
check(mm ~= nil and mm:IsShown(), "minimap button created")
mm.scripts.OnClick(mm, "LeftButton")
local pf = RankFlyoutPickerFrame
check(pf ~= nil and pf:IsShown(), "minimap left-click opens the picker")
check(pf.numTabs == 1, "one tab (the empty General line is skipped)")
local es = pf.entries
check(es[1].fam and es[1].fam.name == "Fireball", "first entry Fireball")
check(es[2].fam and es[2].fam.name == "Frostbolt" and es[2].sub.text == "Ranks 1-5", "Frostbolt shows Ranks 1-5")
check(es[3].fam and es[3].fam.name == "Frost Armor" and not es[4]:IsShown(), "three spells listed, passives skipped")
check(es[2].fam.topID == 8407, "entry uses the highest rank")

-- click a spell: makes a button, macro on cursor, entry marked
pickedUp = nil
es[2].scripts.OnClick(es[2], "LeftButton")
local idx = ns.FindFamily("Frostbolt")
check(idx ~= nil, "clicking a spell makes a Rank Flyout button")
check(pickedUp and macros[pickedUp].body:find("RankFlyoutButton" .. idx .. " RightButton;", 1, true), "its macro is on the cursor")
check(es[2].status.text == "Button " .. idx and es[2].check.shown, "entry marked as added")
check(pf.hint.text:find("click an action bar slot"), "hint tells you to place it")

-- clicking again reuses the same button and macro
local firstMacro = pickedUp
pickedUp = nil
es[2].scripts.OnDragStart(es[2])
check(pickedUp == firstMacro and ns.FindFamily("Frostbolt") == idx, "dragging the same spell reuses its button")

-- drop a spell from the spellbook onto the window
cursor = 133
pickedUp = nil
pf.scripts.OnReceiveDrag(pf)
check(ns.FindFamily("Fireball") ~= nil and pickedUp ~= nil and cursor == nil, "dropping Fireball makes its macro")

-- filter to spells with several ranks
pf.rankedOnly.scripts.OnClick(pf.rankedOnly)
-- (stub GetChecked returns nil, so set the state the way a real click would)
ns.db.pickerRankedOnly = true; pf:Refresh()
check(es[1].fam.name == "Frostbolt" and not es[2]:IsShown(), "ranked-only filter keeps only Frostbolt")
ns.db.pickerRankedOnly = false; pf:Refresh()

-- right-click removes
es[1].scripts.OnClick(es[1], "RightButton")
check(ns.FindFamily("Fireball") == nil and not es[1].check.shown, "right-click removes Fireball and its macro")

-- in combat nothing is created
inCombat = true
pickedUp = nil
es[3].scripts.OnClick(es[3], "LeftButton")
check(pickedUp == nil and ns.FindFamily("Frost Armor") == nil, "picker refuses in combat")
inCombat = false

-- settings in the bottom bar
pf.dir.scripts.OnClick(pf.dir)
check(ns.db.direction ~= "LEFT" and pf.dir.text:find("Menu opens"), "direction button cycles")
pf.float.checked = false
pf.float.scripts.OnClick(pf.float)
check(ns.db.float == false and ns.GetButton(idx).alpha == 0, "floating checkbox hides buttons")
ns.SetFloat(true)

-- slash commands still work; new ones added
SlashCmdList.RANKFLYOUT("spells")
check(not pf:IsShown(), "/rf spells toggles the picker")
SlashCmdList.RANKFLYOUT("minimap off")
check(not mm:IsShown() and ns.db.minimap.hide, "/rf minimap off hides it")
SlashCmdList.RANKFLYOUT("minimap on")
check(mm:IsShown(), "/rf minimap on shows it")
mm.scripts.OnClick(mm, "RightButton")
check(pf:IsShown(), "right-click without a menu system falls back to the picker")

---------------------------------------------------------------- secret values (instances)
-- 0.3.0 threw a Lua error on every SPELL_UPDATE_COOLDOWN inside instances,
-- because restricted cooldown times are secret and went straight to SetCooldown.
local sb = ns.GetButton(ns.FindFamily("Frostbolt"))
local realCooldown, realUsable = C_Spell.GetSpellCooldown, C_Spell.IsSpellUsable
inCombat = true
C_Spell.GetSpellCooldown = function()
	return { isActive = true, isEnabled = true, startTime = SECRET, duration = SECRET, modRate = SECRET }
end
local okEvent, errEvent = pcall(events.scripts.OnEvent, events, "SPELL_UPDATE_COOLDOWN")
check(okEvent, "secret cooldown times raise no error: " .. tostring(errEvent))
check(sb.cooldown.cd == nil, "secret cooldown without duration objects clears the swipe")

-- With the duration-object API (the path the real client takes).
local durationObject = {}
C_Spell.GetSpellCooldownDuration = function() return durationObject end
function Frame:SetCooldownFromDurationObject(d) self.cd = { "duration", d } end
okEvent, errEvent = pcall(events.scripts.OnEvent, events, "SPELL_UPDATE_COOLDOWN")
check(okEvent and sb.cooldown.cd and sb.cooldown.cd[2] == durationObject,
	"secret cooldown shown through a duration object")

-- Plain times keep the SetCooldown path even when duration objects exist.
C_Spell.GetSpellCooldown = function() return { isActive = true, startTime = 5, duration = 8, modRate = 1 } end
events.scripts.OnEvent(events, "SPELL_UPDATE_COOLDOWN")
check(sb.cooldown.cd and sb.cooldown.cd[2] == 8, "plain cooldown still uses SetCooldown")

-- Unexpected display errors are reported once, not on every event.
local reports = {}
geterrorhandler = function() return function(msg) reports[#reports + 1] = msg end end
local realFromDuration = Frame.SetCooldownFromDurationObject
Frame.SetCooldownFromDurationObject = function() error("boom") end
C_Spell.GetSpellCooldown = function()
	return { isActive = true, startTime = SECRET, duration = SECRET, modRate = SECRET }
end
for _ = 1, 3 do events.scripts.OnEvent(events, "SPELL_UPDATE_COOLDOWN") end
check(#reports == 1 and reports[1]:find("boom") and sb.cooldown.cd == nil,
	"unexpected cooldown error cleared the swipe and was reported once")
geterrorhandler, Frame.SetCooldownFromDurationObject = nil, realFromDuration
C_Spell.GetSpellCooldownDuration, Frame.SetCooldownFromDurationObject = nil, nil

-- Secret usability and range answers leave the icon untinted.
C_Spell.IsSpellUsable = function() return SECRET, SECRET end
sb.icon.tint = nil
local okTick, errTick = pcall(events.scripts.OnUpdate, events, 1)
check(okTick, "range tick with secret answers raises no error: " .. tostring(errTick))
check(sb.icon.tint and sb.icon.tint[1] == 1 and sb.icon.tint[3] == 1, "secret usability leaves the icon white")
C_Spell.IsSpellUsable = function() return false, true end
events.scripts.OnUpdate(events, 1)
check(sb.icon.tint and sb.icon.tint[1] == 0.5, "out-of-mana tint still works")
C_Spell.GetSpellCooldown, C_Spell.IsSpellUsable = realCooldown, realUsable
inCombat = false

__RESULT = ("%d passed, %d failed"):format(passed, failed)
__FAILED = failed

out("smoke: " .. __RESULT)
if arg and failed > 0 then os.exit(1) end -- standalone interpreter (CI)

-- Smoke test for Rank in File with a stubbed WoW API (Lua 5.1 / fengari).
-- Run from the addon folder:  lua tests/rankinfile_smoke.lua .
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
local playerGUID = "Player-A"
function UnitGUID() return playerGUID end
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
local bindings = { ["SHIFT-BUTTON4"] = "CLICK RankInFileButton1:LeftButton" } -- [key] = command
local savedBindingSet
function GetBindingKey(cmd)
	local keys = {}
	for key, c in pairs(bindings) do if c == cmd then keys[#keys + 1] = key end end
	table.sort(keys)
	return unpack(keys)
end
function SetBinding(key, cmd) assert(not inCombat, "SetBinding in combat"); bindings[key] = cmd end
function GetCurrentBindingSet() return 2 end
function SaveBindings(set) savedBindingSet = set end
unpack = unpack or table.unpack -- fengari is Lua 5.3
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
for _, file in ipairs({ "RankInFile.lua", "Picker.lua", "Minimap.lua" }) do
	local chunk = assert(loadfile((ADDON_DIR or ".") .. "/" .. file))
	chunk("RankInFile", ns)
end
local events
for _, f in ipairs(frames) do
	local ev = rawget(f, "events")
	if ev and ev.ADDON_LOADED then events = f end
end
check(events ~= nil, "event frame registered ADDON_LOADED")
events.scripts.OnEvent(events, "ADDON_LOADED", "RankInFile")
check(type(RankInFileDB) == "table" and type(RankInFileCharDB) == "table", "saved variables created")
events.scripts.OnEvent(events, "PLAYER_LOGIN")
check(RankInFileButton1 == nil, "no buttons before /rf add")

-- A new login: the addon loads afresh with this character's saved buttons
-- (account settings carry over).
local function NewSession(charDB, guid)
	RankInFileCharDB, playerGUID = charDB, guid
	ns = {}
	for _, file in ipairs({ "RankInFile.lua", "Picker.lua", "Minimap.lua" }) do
		assert(loadfile((ADDON_DIR or ".") .. "/" .. file))("RankInFile", ns)
	end
	for _, f in ipairs(frames) do
		local ev = rawget(f, "events")
		if ev and ev.ADDON_LOADED then events = f end
	end
	events.scripts.OnEvent(events, "ADDON_LOADED", "RankInFile")
	events.scripts.OnEvent(events, "PLAYER_LOGIN")
end

-- add by name
SlashCmdList.RANKINFILE("add Frostbolt")
local b = RankInFileButton1
check(b ~= nil and b:IsShown(), "button 1 created")
check(b:GetAttribute("type") == "spell", "main button type is spell")
check(b:GetAttribute("spell") == 837, "defaults to highest rank (837)")
check(b:GetAttribute("rf-count") == 3, "three ranks found, passive ignored")
check(b.rankText.text == "3", "rank label shows 3")
check(b.hotkey.text == "sM4", "hotkey abbreviated")
check(b.cooldown.cd and b.cooldown.cd[2] == 8, "cooldown applied for active spell")
check(RankInFileCharDB.buttons[1].top == true, "follow-highest flag set")
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
check(RankInFileCharDB.buttons[1].spellID == 116 and RankInFileCharDB.buttons[1].top == false, "choice saved")

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
SlashCmdList.RANKINFILE("add")
local b2 = RankInFileButton2
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
SlashCmdList.RANKINFILE("remove 2")
check(b2:IsShown(), "remove refused in combat")
inCombat = false
SlashCmdList.RANKINFILE("remove 2")
check(not b2:IsShown() and RankInFileCharDB.buttons[2] == nil, "remove works out of combat")

-- direction / scale / unknown spell / help
SlashCmdList.RANKINFILE("dir left")
check(RankInFileDB.direction == "LEFT", "direction saved")
SlashCmdList.RANKINFILE("scale 1.5")
check(b.scale == 1.5, "scale applied")
local before = #printed
SlashCmdList.RANKINFILE("add Pyroblast")
check(printed[#printed]:find("couldn't find"), "unknown spell reported")
SlashCmdList.RANKINFILE("")
check(#printed > before + 5, "help printed")
SlashCmdList.RANKINFILE("list")

check(_G["BINDING_NAME_CLICK RankInFileButton1:LeftButton"] ~= nil, "binding names defined")

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
check(macros[mi].body == "#showtooltip Frostbolt(Rank 2)\n/click [btn:2] RankInFileButton1 RightButton; RankInFileButton1",
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

-- bar right-click: /click RankInFileButton1 RightButton (one click, down = false)
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
SlashCmdList.RANKINFILE("float off")
check(b:IsShown() and b.alpha == 0 and b.mouse == false, "float off hides the button but keeps it clickable")
SlashCmdList.RANKINFILE("float on")
check(b.alpha == 1 and b.mouse == true, "float on restores it")

-- /rf macro in combat refused; /rf remove deletes the macro
inCombat = true
pickedUp = nil
SlashCmdList.RANKINFILE("macro 1")
check(pickedUp == nil, "/rf macro refused in combat")
inCombat = false
SlashCmdList.RANKINFILE("macro 1")
check(pickedUp == mi, "/rf macro picks up the macro")
SlashCmdList.RANKINFILE("remove 1")
check(macros[mi] == nil and macros[7] ~= nil, "remove deletes only this button's macro")

---------------------------------------------------------------- minimap + spell picker
local mm = RankInFileMinimapButton
check(mm ~= nil and mm:IsShown(), "minimap button created")
mm.scripts.OnClick(mm, "LeftButton")
local pf = RankInFilePickerFrame
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
check(idx ~= nil, "clicking a spell makes a Rank in File button")
check(pickedUp and macros[pickedUp].body:find("RankInFileButton" .. idx .. " RightButton;", 1, true), "its macro is on the cursor")
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
SlashCmdList.RANKINFILE("spells")
check(not pf:IsShown(), "/rf spells toggles the picker")
SlashCmdList.RANKINFILE("minimap off")
check(not mm:IsShown() and ns.db.minimap.hide, "/rf minimap off hides it")
SlashCmdList.RANKINFILE("minimap on")
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

---------------------------------------------------------------- moving over from Rank Flyout
local function count(text)
	local n = 0
	for _, line in ipairs(printed) do if line:find(text, 1, true) then n = n + 1 end end
	return n
end
local function canonical(n, rank)
	return ("#showtooltip Frostbolt(%s)\n/click [btn:2] RankInFileButton%d RightButton; RankInFileButton%d"):format(rank, n, n)
end
local function legacy(show, n)
	return ("#showtooltip %s\n/click [btn:2] RankFlyoutButton%d RightButton; RankFlyoutButton%d"):format(show, n, n)
end
-- Log in as another character: its own character macros and key bindings,
-- with the account's macros and settings.
local function LogInAs(charDB, guid, charMacros, keys)
	for i in pairs(macros) do if i > 120 then macros[i] = nil end end
	for i, m in pairs(charMacros or {}) do macros[i] = m end
	for k in pairs(bindings) do bindings[k] = nil end
	for k, v in pairs(keys or {}) do bindings[k] = v end
	NewSession(charDB, guid)
end
for i = 1, ns.MAX_BUTTONS do if RankInFileCharDB.buttons[i] then ns.RemoveButton(i) end end
RankInFileDB.float = true
RankInFileCharDB.moved = nil
-- Button 3 is already taken in Rank in File, so old button 3 has to move elsewhere.
RankInFileCharDB.buttons[3] = { family = "Frost Armor", top = true }
events.scripts.OnEvent(events, "SPELLS_CHANGED")
local LEGACY_FROST = "#showtooltip Frostbolt(Rank 2)\n/click [btn:2] RankFlyoutButton3 RightButton; RankFlyoutButton3"
-- Real macro indices are contiguous: account 1.., character 121..
for i in pairs(macros) do macros[i] = nil end
macros[1] = { name = "Nuke", icon = 1, body = "#showtooltip\n/cast Frostbolt" }
macros[121] = { name = "Rank 2", icon = 135846, body = LEGACY_FROST } -- icon as GetMacroInfo may report it
macros[122] = { name = "Fireball", icon = 134400,
	body = "#showtooltip Fireball\n/click [btn:2] RankFlyoutButton5 RightButton; RankFlyoutButton5" }
bindings["F"] = "CLICK RankFlyoutButton3:LeftButton"
savedBindingSet = nil
playerGUID = "Player-A"

-- The old addon still loaded: leave everything alone, and say so once.
RankFlyoutHeader = {}
ns.MigrateFromRankFlyout()
ns.MigrateFromRankFlyout()
check(macros[121].body == LEGACY_FROST and count("Rank Flyout is still enabled") == 1,
	"nothing moves while Rank Flyout is still loaded, and the warning shows once")
RankFlyoutHeader = nil

-- In combat it waits for combat to end.
inCombat = true
ns.MigrateFromRankFlyout()
check(macros[121].body == LEGACY_FROST and RankInFileCharDB.buttons[1] == nil, "nothing moves in combat")
inCombat = false
events.scripts.OnEvent(events, "PLAYER_REGEN_ENABLED")

local fb = ns.GetButton(1)
check(RankInFileCharDB.buttons[1] and RankInFileCharDB.buttons[1].family == "Frostbolt", "old button 3 moves to a free button (1)")
check(fb and fb:GetAttribute("spell") == 205 and RankInFileCharDB.buttons[1].top == false,
	"its old rank (Rank 2) is kept, not the highest")
check(macros[121].body == canonical(1, "Rank 2"), "old macro now clicks the new button, in the same macro slot")
check(macros[121].icon == 134400, "moved macro keeps the question-mark icon so #showtooltip picks it")
check(RankInFileCharDB.buttons[5] and RankInFileCharDB.buttons[5].family == "Fireball"
	and macros[122].body:find("RankInFileButton5 RightButton; RankInFileButton5", 1, true),
	"a single-rank spell keeps its old number when free")
check(RankInFileCharDB.buttons[3].family == "Frost Armor", "the existing button 3 is untouched")
check(macros[1].body == "#showtooltip\n/cast Frostbolt", "unrelated macros untouched")
check(bindings["F"] == "CLICK RankInFileButton1:LeftButton" and savedBindingSet == 2,
	"key binding follows its macro to button 1 and is saved")
check(RankInFileDB.float == false, "floating buttons hidden")
check(count("moved 2 bar macros and 1 key binding") == 1, "player told what moved")

-- A key binding that loads later still follows the remembered move.
bindings["G"] = "CLICK RankFlyoutButton3:LeftButton"
events.scripts.OnEvent(events, "UPDATE_BINDINGS")
check(bindings["G"] == "CLICK RankInFileButton1:LeftButton", "late key binding follows the move too")

-- Nothing left to move: running again changes nothing and says nothing.
local before = #printed
events.scripts.OnEvent(events, "UPDATE_MACROS")
check(#printed == before and macros[121].body == canonical(1, "Rank 2"), "running again is harmless")

-- Another character, B: its own buttons, none of A's. Its macros load after
-- login and move to its own buttons, keeping their old numbers.
local charA, charB = RankInFileCharDB, {}
LogInAs(charB, "Player-B")
check(next(charB.buttons) == nil and ns.GetButton(1) == nil, "a new character starts with its own empty set, not A's")
macros[2] = { name = "Rank 1", icon = 134400, body = legacy("Frostbolt(Rank 1)", 7) } -- an account macro
macros[121] = { name = "Frost Armor", icon = 134400, body = legacy("Frost Armor", 2) }
macros[122] = { name = "Old", icon = 134400, body = "#showtooltip\n/click [btn:2] RankFlyoutButton9 RightButton; RankFlyoutButton9" }
macros[123] = { name = "Rank 1", icon = 134400, body = legacy("Frostbolt(Rank 1)", 7) } -- a second macro for old button 7
events.scripts.OnEvent(events, "UPDATE_MACROS")
local fb7 = ns.GetButton(7)
check(fb7 and fb7:GetAttribute("spell") == 116 and macros[2].body == canonical(7, "Rank 1")
	and macros[123].body == canonical(7, "Rank 1"), "B's Frostbolt keeps its old number and its own rank (Rank 1)")
check(macros[121].body:find("RankInFileButton2 RightButton; RankInFileButton2", 1, true), "B's Frost Armor keeps number 2")
check(charB.moved[7] == 7 and charB.moved[2] == 2 and charA.moved[3] == 1, "moves remembered per character")
check(macros[122].body:find("RankFlyoutButton9", 1, true) and count("couldn't be moved") == 1,
	"an unreadable old macro is left alone, and the player is told once")
bindings["H"] = "CLICK RankFlyoutButton7:LeftButton"
events.scripts.OnEvent(events, "UPDATE_BINDINGS")
check(bindings["H"] == "CLICK RankInFileButton7:LeftButton", "B's key binding follows its own move")

-- The character macro follows a rank change. The account macro is shared by
-- every character, whose button 7 differs, so it is left alone.
fb7:SetAttribute("spell", 837)
check(macros[123].name == "Rank 3" and macros[2].name == "Rank 1",
	"character macros follow rank changes; the shared account macro is left alone")

-- The two macros sit in two bar slots. Out of combat, right-clicking either
-- opens the menu beside it; in combat the menu stays where it was.
do
	ActionButton6 = NewFrame("CheckButton", "ActionButton6")
	ActionButton6.action = 6
	barSlots[5], barSlots[6] = 2, 123
	events.scripts.OnEvent(events, "ACTIONBAR_SLOT_CHANGED", 6)
	check(fb7.flyout.anchor == ActionButton5, "the menu waits beside the first slot holding the macro")
	local function rightClick() for _, h in ipairs(fb7.hooks.PreClick or {}) do h(fb7, "RightButton") end end
	ActionButton6.IsMouseOver = function() return true end
	rightClick()
	check(fb7.flyout.anchor == ActionButton6, "right-clicking the other slot opens the menu beside it")
	events.scripts.OnEvent(events, "ACTIONBAR_SLOT_CHANGED", 9)
	check(fb7.flyout.anchor == ActionButton6, "a bar update leaves the menu beside the slot last right-clicked")
	ActionButton6.IsMouseOver, ActionButton5.IsMouseOver = nil, function() return true end
	inCombat = true
	rightClick()
	check(fb7.flyout.anchor == ActionButton6, "in combat the menu stays where it was")
	inCombat = false
	rightClick()
	check(fb7.flyout.anchor == ActionButton5, "out of combat it follows the clicked slot again")
	ActionButton5.IsMouseOver, ActionButton6.IsMouseOver = nil, function() return true end
	rightClick()
	barSlots[6] = nil
	events.scripts.OnEvent(events, "ACTIONBAR_SLOT_CHANGED", 6)
	check(fb7.flyout.anchor == ActionButton5, "once that slot no longer holds the macro, the menu goes back to the first")
	ActionButton6.IsMouseOver = nil
	barSlots[5] = nil
end

ns.RemoveButton(7)
check(macros[123] == nil and macros[2] ~= nil and macros[121] ~= nil,
	"removing a button deletes its character macros, not the shared account macro")
check(charB.moved[7] == nil and charB.moved[2] == 2, "the removed button's old Rank Flyout number is forgotten")

-- Back on A: its buttons and chosen ranks are as A left them.
LogInAs(charA, "Player-A")
check(ns.GetButton(1):GetAttribute("spell") == 205 and charA.buttons[1].top == false
	and charA.buttons[5].family == "Fireball" and charA.buttons[7] == nil,
	"A's buttons and ranks are untouched by B")

-- A third character, C: brackets in a spell's name, two old buttons for one
-- spell, and key bindings that load before the macros do.
book[#book + 1] = { name = "Faerie Fire (Feral)", actionID = 16857, sub = "Rank 1" }
book[#book + 1] = { name = "Faerie Fire (Feral)", actionID = 17390, sub = "Rank 2" }
index()
LogInAs({}, "Player-C", nil, {
	J = "CLICK RankFlyoutButton11:LeftButton", -- old button 11 had no macro
	K = "CLICK RankFlyoutButton6:LeftButton",
})
check(bindings["K"] == "CLICK RankFlyoutButton6:LeftButton", "a key binding waits for its macro to move")
macros[121] = { name = "Rank 1", icon = 134400, body = legacy("Faerie Fire (Feral)(Rank 1)", 4) }
macros[122] = { name = "Rank 1", icon = 134400, body = legacy("Frostbolt(Rank 1)", 6) }
macros[123] = { name = "Rank 3", icon = 134400, body = legacy("Frostbolt(Rank 3)", 8) }
macros[124] = { name = "Faerie Fire", icon = 134400, body = legacy("Faerie Fire (Feral)", 10) }
events.scripts.OnEvent(events, "UPDATE_MACROS")
local b4, b6, b8 = ns.GetButton(4), ns.GetButton(6), ns.GetButton(8)
check(RankInFileCharDB.buttons[4] and RankInFileCharDB.buttons[4].family == "Faerie Fire (Feral)"
	and b4:GetAttribute("spell") == 16857, "a spell with brackets in its name keeps them, and its rank")
check(RankInFileCharDB.buttons[10] and RankInFileCharDB.buttons[10].family == "Faerie Fire (Feral)",
	"a bracketed spell name with no rank is read whole")
check(b6 and b8 and b6:GetAttribute("spell") == 116 and b8:GetAttribute("spell") == 837,
	"two old buttons for one spell stay apart, each with its own rank")
check(bindings["K"] == "CLICK RankInFileButton6:LeftButton", "the waiting key binding moves with its macro")
check(bindings["J"] == "CLICK RankFlyoutButton11:LeftButton", "a key on an old button with no macro is left alone")

-- While the spellbook doesn't list a button's spell (say it is still loading),
-- the button's chosen rank is kept.
do
	local saved = {}
	for i = #book, 1, -1 do
		if book[i].name == "Frostbolt" then table.insert(saved, 1, table.remove(book, i)) end
	end
	index()
	events.scripts.OnEvent(events, "SPELLS_CHANGED")
	check(RankInFileCharDB.buttons[6].spellID == 116 and RankInFileCharDB.buttons[6].top == false,
		"a spellbook without the spell keeps the chosen rank")
	for _, s in ipairs(saved) do book[#book + 1] = s end
	index()
	events.scripts.OnEvent(events, "SPELLS_CHANGED")
	check(b6:GetAttribute("spell") == 116, "once the spell is back, the chosen rank is still held")
end

-- If WoW stores a macro slightly differently from what was written, syncing
-- edits each macro once rather than looping.
do
	local realEdit, edits = EditMacro, 0
	EditMacro = function(i, name, icon, body) edits = edits + 1; return realEdit(i, name .. "~", icon, body) end
	b6:SetAttribute("spell", 205)
	EditMacro = realEdit
	check(edits == 1, "a macro WoW stores differently is edited once per sync, not repeatedly (" .. edits .. ")")
end

-- Macro names are cut to 16 bytes without splitting a character.
do
	local cyr = ("\208\155"):rep(7) .. " " .. ("\209\129"):rep(6) -- 7 letters, space, 6 letters
	book[#book + 1] = { name = cyr, actionID = 4242, sub = "" }
	index()
	pickedUp = nil
	ns.PickUpSpell(4242)
	check(pickedUp and macros[pickedUp] and macros[pickedUp].name == ("\208\155"):rep(7) .. " ",
		"a long non-English name is cut between letters")
end

-- With the character macro slots full, no account macro is made instead.
do
	local filled = {}
	for i = 121, 150 do
		if not macros[i] then macros[i] = { name = "x", icon = 1, body = "/say hi" }; filled[#filled + 1] = i end
	end
	local function accountMacros()
		local n = 0
		for i = 1, 120 do if macros[i] then n = n + 1 end end
		return n
	end
	local before = accountMacros()
	pickedUp = nil
	ns.PickUpSpell(133)
	check(pickedUp == nil and accountMacros() == before and count("character macro slots are full") == 1,
		"with the character macro slots full, no account macro is made")
	for _, i in ipairs(filled) do macros[i] = nil end
end

---------------------------------------------------------------- buttons from 0.4.0 (one set for the account)
do
	RankInFileDB.buttons = {
		[1] = { family = "Frostbolt", spellID = 205, top = false, point = { "CENTER", "CENTER", 5, 6 } },
		[2] = { family = "Fireball", top = true },
		[3] = { family = "Wrath", top = true }, -- spells these characters don't know
		[4] = { family = "Healing Touch", top = true },
	}
	RankInFileDB.movedButtons = { ["Player-E"] = { [3] = 2 } }
	RankInFileDB.shared040Taken = true -- left behind by 0.4.1
	local charD, charE = {}, {}

	-- D logs in before its spellbook has loaded.
	local realLines = C_SpellBook.GetNumSpellBookSkillLines
	C_SpellBook.GetNumSpellBookSkillLines = function() return 0 end
	LogInAs(charD, "Player-D")
	local shared = RankInFileDB.shared040
	check(RankInFileDB.buttons == nil and shared and shared[1].family == "Frostbolt"
		and RankInFileDB.shared040Taken == nil, "0.4.0's account-wide buttons are kept aside for handing out")
	check(next(charD.buttons) == nil, "nothing is taken by spell before the spellbook loads")
	C_SpellBook.GetNumSpellBookSkillLines = realLines
	events.scripts.OnEvent(events, "SPELLS_CHANGED")
	check(charD.buttons[1] and charD.buttons[2] and ns.GetButton(1):GetAttribute("spell") == 205,
		"once it loads, a character takes the 0.4.0 buttons for spells it knows, with their ranks")
	check(charD.buttons[3] == nil and charD.buttons[4] == nil, "but not buttons for spells it doesn't know")
	check(charD.buttons[1] ~= shared[1] and charD.buttons[1].point ~= shared[1].point,
		"it takes copies, so its changes stay its own")

	LogInAs(charE, "Player-E", {
		[121] = { name = "Wrath", icon = 134400,
			body = "#showtooltip Wrath\n/click [btn:2] RankInFileButton3 RightButton; RankInFileButton3" },
	}, {
		L = "CLICK RankInFileButton4:LeftButton",
		M = "CLICK RankFlyoutButton3:LeftButton", -- moved to button 2 under 0.4.0, but loaded late
	})
	check(charE.buttons[1] and charE.buttons[2], "another character also takes the buttons for spells it knows")
	check(charE.buttons[3] and charE.buttons[4],
		"and the ones its macros and key bindings click, even for spells it hasn't learned")
	check(charE.moved and charE.moved[3] == 2 and RankInFileDB.movedButtons == nil,
		"its 0.4.0 Rank Flyout moves come along")
	check(bindings["M"] == "CLICK RankInFileButton2:LeftButton", "so a late Rank Flyout key binding still follows them")
	ns.RemoveButton(4)
	events.scripts.OnEvent(events, "UPDATE_BINDINGS")
	check(charE.buttons[4] == nil, "a button it removes isn't taken back")

	-- Every 0.4.0 button is now taken or removed: a catch-up reads the macros
	-- once (for Rank Flyout ones), not again looking for 0.4.0 buttons.
	local realInfo, reads = GetMacroInfo, 0
	GetMacroInfo = function(i) reads = reads + 1; return realInfo(i) end
	events.scripts.OnEvent(events, "UPDATE_BINDINGS")
	GetMacroInfo = realInfo
	local na, nc = GetNumMacros()
	check(reads == na + nc, "once every 0.4.0 button is settled, it stops looking (" .. reads .. " macro reads)")

	-- A rebuild draws each button once (not again through the attribute change).
	local realCooldown, calls = C_Spell.GetSpellCooldown, 0
	C_Spell.GetSpellCooldown = function(id) calls = calls + 1; return realCooldown(id) end
	events.scripts.OnEvent(events, "SPELLS_CHANGED")
	C_Spell.GetSpellCooldown = realCooldown
	check(calls == 2, "a rebuild draws each button with a known spell once (" .. calls .. ")")
end
LogInAs(charA, "Player-A")

-- A burst of macro updates (a rebuild edits several macros) gets one look.
do
	local realAfter, queued = C_Timer.After, {}
	C_Timer.After = function(_, fn) queued[#queued + 1] = fn end
	for _ = 1, 5 do events.scripts.OnEvent(events, "UPDATE_MACROS") end
	C_Timer.After = realAfter
	check(#queued == 2, "a burst of macro updates is checked once, and anchored once (" .. #queued .. " timers)")
	for _, fn in ipairs(queued) do fn() end
end

__RESULT =("%d passed, %d failed"):format(passed, failed)
__FAILED = failed

out("smoke: " .. __RESULT)
if arg and failed > 0 then os.exit(1) end -- standalone interpreter (CI)

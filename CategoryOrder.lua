-- BagSort - CategoryOrder.lua
-- The category panel, a two column master/detaul view

local ADDON_NAME, ns = ...
local BagSort = ns.BagSort

local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI then return end

local Type, Version = "BagSortCategoryOrder", 1
local BankType = "BagSortBankCategoryOrder"
local bagAlreadyRegistered  = (AceGUI:GetWidgetVersion(Type) or 0) >= Version
local bankAlreadyRegistered = (AceGUI:GetWidgetVersion(BankType) or 0) >= Version
if bagAlreadyRegistered and bankAlreadyRegistered then return end

-- doubled since we have two scopes
local BagScope = {
    GetOrder             = function() return ns.CategoryOrder() end,
    GetCategorySettings  = function(key) return ns.GetCategorySettings(key) end,
    SetCategorySettings  = function(key, patch) ns.SetCategorySettings(key, patch) end,
    ResetOrder           = function() ns.ResetCategoryOrder() end,
    ResetSettings        = function() ns.ResetCategorySettings() end,
}
local BankScope = {
    GetOrder             = function() return ns.BankCategoryOrder() end,
    GetCategorySettings  = function(key) return ns.BankGetCategorySettings(key) end,
    SetCategorySettings  = function(key, patch) ns.SetBankCategorySettings(key, patch) end,
    ResetOrder           = function() ns.ResetBankCategoryOrder() end,
    ResetSettings        = function() ns.ResetBankCategorySettings() end,
}

-- session-only memory of where the panel was left
local LastPanelState = {
    [BagScope]  = {},
    [BankScope] = {},
}

local ROW_HEIGHT        = 20
local ROW_SPACING       = 2
local STEP              = ROW_HEIGHT + ROW_SPACING
local LABEL_SPACE       = 18  -- room above the rows for the option name

local LIST_WIDTH        = 250     -- left column, row list
local LIST_WIDTH_MIN    = 150     -- left column minimal width
local LIST_WIDTH_MAX    = 500     -- left column maximal width

local DETAIL_WIDTH_MIN  = 4 + 220 + 12 + 70 + 8 * 2
local STEP_BUTTON_SIZE  = 14    -- up/down buttons (on hover)
local HOVER_HIDE_DELAY  = 0.05  -- see HoverLeave
local LIST_MIN_HEIGHT   = 260   -- floor for the row list when nothing stretches it
local SCROLLBAR_RESERVE = 28    -- horizontal room the scrollbar needs beside the list
local SPLITTER_WIDTH    = 6     -- draggable seam between the row list and the detail panel
local LIST_TOP_GAP      = 8     -- headroom between the widget's own label and the row list below it
local WHEEL_STEP        = 3     -- rows scrolled per mouse wheel notch
local BOX_PADDING       = 8     -- inset between a bordered box's edge and its content
local DROP_LINE_HEIGHT  = 2     -- the drag-drop insertion indicator, see CreateDropLine
local DETAIL_HEIGHT     = 560   -- tall enough for a custom category's extra controls

local ITEM_ROW_HEIGHT   = 16    -- custom category item list height
local ITEM_ROW_SPACING  = 2     -- custom category item list spacing
local ITEM_STEP         = ITEM_ROW_HEIGHT + ITEM_ROW_SPACING

local BOX_BORDER = {
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function ApplyBorder(borderFrame)
    borderFrame:SetBackdrop(BOX_BORDER)
    borderFrame:SetBackdropBorderColor(1, 1, 1, 0.5)
end

-- insertion-line indicator for both category and item list
local function CreateDropLine(parent)
    local line = parent:CreateTexture(nil, "OVERLAY")
    line:SetHeight(DROP_LINE_HEIGHT)
    line:SetColorTexture(1, 0.82, 0, 0.9)
    line:Hide()
    return line
end

local function Split(text)
    local keys = {}
    for key in tostring(text or ""):gmatch("[^,%s]+") do keys[#keys + 1] = key end
    return keys
end


-- ========= --
-- Scrolling --
-- ========= --

-- native ScrollFrame + Slider, as AceGUI's ScrollFrame container assumes every scroll child to be an AceGUI widget
local function UpdateScrollRange(self)
    local viewHeight = self.scrollFrame:GetHeight()
    local contentHeight = self.listFrame:GetHeight()
    local maxScroll = math.max(0, contentHeight - viewHeight)

    -- set before SetMinMaxValues
    self.suppressScrollStash = true
    self.scrollFrame:UpdateScrollChildRect()
    self.scrollBar:SetMinMaxValues(0, maxScroll)

    if maxScroll <= 0 then
        self.scrollBar:Hide()
        self.scrollFrame:SetVerticalScroll(0)
        self.scrollBar:SetValue(0)
    else
        self.scrollBar:Show()
        local current = math.min(self.scrollFrame:GetVerticalScroll(), maxScroll)
        self.scrollFrame:SetVerticalScroll(current)
        self.scrollBar:SetValue(current)
    end
    self.suppressScrollStash = nil
end

-- where the top row "index" sits, measured from the top
local function RowOffset(index)
    return -((index - 1) * STEP)
end

local function PlaceRow(self, row, index)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.listFrame, "TOPLEFT", 0, RowOffset(index))
    row:SetPoint("TOPRIGHT", self.listFrame, "TOPRIGHT", 0, RowOffset(index))
end

-- rewrites the position in front of every label
local function Renumber(self)
    for index, key in ipairs(self.order) do
        local row = self.rowsByKey[key]
        if row then row.number:SetText(index .. ".") end
    end
end

-- put every row where its entry in self.order says
local function LayoutRows(self, except)
    for index, key in ipairs(self.order) do
        local row = self.rowsByKey[key]
        if row and row ~= except then PlaceRow(self, row, index) end
    end
    Renumber(self)
end


-- ======== --
-- Dragging --
-- ======== --

-- index the cursor is over, clamped to the list
local function IndexUnderCursor(self)
    local scale = self.listFrame:GetEffectiveScale()
    if not scale or scale == 0 then return 1 end
    local _, cursorY = GetCursorPosition()
    cursorY = cursorY / scale

    local top = self.listFrame:GetTop()
    if not top then return 1 end
    local index = math.floor((top - cursorY) / STEP) + 1
    if index < 1 then index = 1 end
    if index > #self.order then index = #self.order end
    return index
end

local function MoveEntry(self, from, to)
    local key = table.remove(self.order, from)
    table.insert(self.order, to, key)
end

-- write self.order back to the profile if it actually changed
local function CommitOrder(self)
    local order = table.concat(self.order, ",")
    if order ~= self.text then
        self.text = order
        self:Fire("OnEnterPressed", order)
    end
end

-- WoW hands OnEnter/OnLeave to whatever is topmost under the cursor
local function HoverEnter(row)
    if row.hoverTimer then
        BagSort:CancelTimer(row.hoverTimer)
        row.hoverTimer = nil
    end
    local widget = row.widget
    local dragging = widget.dragRow or (widget.detail and widget.detail.itemDragging)
    if not dragging and not CursorHasItem() then
        row.highlight:Show()
    end

    if row.widget.disabled then return end
    local index, count = row.getPosition(row)
    if not index then return end
    row.upBtn:SetFrameLevel(row:GetFrameLevel() + 1)
    row.downBtn:SetFrameLevel(row:GetFrameLevel() + 1)
    row.upBtn:SetShown(index > 1)
    row.downBtn:SetShown(index < count)
end

-- hide a highlight and its step buttons
local function HoverLeave(row)
    row.hoverTimer = BagSort:ScheduleTimer(function()
        row.hoverTimer = nil
        row.highlight:Hide()
        row.upBtn:Hide()
        row.downBtn:Hide()
    end, HOVER_HIDE_DELAY)
end

-- up/down buttons on hover
local function MoveStep(self, key, delta)
    if self.disabled then return end
    local index
    for i, k in ipairs(self.order) do
        if k == key then index = i; break end
    end
    if not index then return end
    local target = index + delta
    if target < 1 or target > #self.order then return end
    MoveEntry(self, index, target)
    LayoutRows(self)
    CommitOrder(self)
end

local function DragUpdate(self)
    local row = self.dragRow
    if not row then return end

    local scale = self.listFrame:GetEffectiveScale()
    local top = self.listFrame:GetTop()
    if scale and scale ~= 0 and top then
        local _, cursorY = GetCursorPosition()
        local y = cursorY / scale - top + self.dragGrab
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.listFrame, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", self.listFrame, "TOPRIGHT", 0, y)
    end

    self.dragIndex = IndexUnderCursor(self)

    -- the dragged row has no longer a slot when it lands
    local lineIndex = self.dragIndex
    if self.dragIndex > self.dragFrom then lineIndex = self.dragIndex + 1 end
    local lineY = RowOffset(lineIndex) + ROW_SPACING / 2
    self.dropIndicator:ClearAllPoints()
    self.dropIndicator:SetPoint("TOPLEFT", self.listFrame, "TOPLEFT", 0, lineY)
    self.dropIndicator:SetPoint("TOPRIGHT", self.listFrame, "TOPRIGHT", 0, lineY)
    self.dropIndicator:Show()
end

local function DragStop(self)
    local row = self.dragRow
    if not row then return end

    self.listFrame:SetScript("OnUpdate", nil)
    row:SetFrameLevel(self.listFrame:GetFrameLevel() + 1)
    row.dragging:Hide()
    self.dropIndicator:Hide()
    if self.dragIndex ~= self.dragFrom then
        MoveEntry(self, self.dragFrom, self.dragIndex)
    end
    self.dragRow, self.dragFrom, self.dragIndex = nil, nil, nil
    LayoutRows(self)
    CommitOrder(self)
end

local function DragStart(self, row)
    if self.disabled or self.dragRow then return end

    local index
    for i, key in ipairs(self.order) do
        if key == row.key then
            index = i
            break
        end
    end
    if not index then return end

    -- how far down the row the cursor grabbed it
    local scale, rowTop = self.listFrame:GetEffectiveScale(), row:GetTop()
    local frameTop = self.listFrame:GetTop()
    local grab = 0
    if scale and scale ~= 0 and rowTop and frameTop then
        local _, cursorY = GetCursorPosition()
        grab = rowTop - cursorY / scale
    end

    self.dragRow, self.dragFrom, self.dragIndex, self.dragGrab = row, index, index, grab
    row:SetFrameLevel(self.listFrame:GetFrameLevel() + 5)
    row.dragging:Show()
    self.listFrame:SetScript("OnUpdate", function() DragUpdate(self) end)
end


-- ============ --
-- Detail Panel --
-- ============ --

local SORT_FIELD_VALUES  -- key -> label, built lazily once ns.SortFieldOrder exists
local SORT_FIELD_ORDER

local function SortFieldLists()
    if not SORT_FIELD_VALUES then
        SORT_FIELD_ORDER = ns.SortFieldOrder and ns.SortFieldOrder() or {}
        SORT_FIELD_VALUES = {}
        for _, field in ipairs(SORT_FIELD_ORDER) do
            SORT_FIELD_VALUES[field] = ns.SortFieldLabel(field)
        end
    end
    return SORT_FIELD_VALUES, SORT_FIELD_ORDER
end

-- greys out disabled categories, colors special categories
local function NonStandardColor(key)
    if key == ns.JUNK_CATEGORY_KEY or key == ns.EMPTY_CATEGORY_KEY then
        return 0.62, 0.62, 0.62
    end
    if key == ns.HEARTHSTONE_CATEGORY_KEY then
        return 0.6, 1, 1
    end
    if key == ns.GEARSET_CATEGORY_KEY then
        return 0.4, 0.6, 1
    end
    if key == ns.SOULBOUND_CATEGORY_KEY then
        return 0.5, 1, 0.5
    end
    return nil
end

-- detail text for special categories
local SENTINEL_DETAIL = {
    [ns.JUNK_CATEGORY_KEY]        = "Claims poor quality items ahead of their own category.",
    [ns.EMPTY_CATEGORY_KEY]       = "Gathers the free slots wherever it sits - the categories above it fill "
        .. "the bags from the front, the ones below it from the back.",
    [ns.HEARTHSTONE_CATEGORY_KEY] = "Claims the hearthstones and the flight master's whistle by item id.",
    [ns.GEARSET_CATEGORY_KEY]     = "Claims anything saved in one of this character's equipment sets.",
    [ns.SOULBOUND_CATEGORY_KEY]   = "Claims any armor or weapon bound to this character.",
    [ns.DEFAULT_CATEGORY_KEY]     = "Catches all items whose own category is disabled.",
}

-- SetFontObject alone does not guarantee the label color
local HIGHLIGHT_COLOR = { 1, 1, 1 }
local DISABLED_COLOR  = { 0.5, 0.5, 0.5 }

local function RefreshRowAppearance(self, row)
    local settings = self.scope.GetCategorySettings(row.key)
    local categoryDisabled = row.key ~= ns.DEFAULT_CATEGORY_KEY and not settings.enabled
    local disabled = self.disabled or categoryDisabled

    if disabled then
        row.label:SetFontObject("GameFontDisable")
        row.number:SetFontObject("GameFontDisableSmall")
    else
        row.label:SetFontObject("GameFontHighlight")
        row.number:SetFontObject("GameFontHighlightSmall")
    end

    local r, g, b
    if not disabled then
        r, g, b = NonStandardColor(row.key)
    end
    if not r then
        local c = disabled and DISABLED_COLOR or HIGHLIGHT_COLOR
        r, g, b = c[1], c[2], c[3]
    end
    row.label:SetTextColor(r, g, b)

    if categoryDisabled then
        row.strike:SetWidth(math.max(row.label:GetStringWidth(), 1))
        row.strike:Show()
    else
        row.strike:Hide()
    end

    row.reverseMark:SetShown(settings.reverse)
end

-- write one update and ask the profile to be rebuilt
local function WriteSetting(self, field, value)
    if not self.selectedKey then return end
    self.scope.SetCategorySettings(self.selectedKey, { [field] = value })

    if field == "enabled" or field == "reverse" then
        local row = self.rowsByKey[self.selectedKey]
        if row then RefreshRowAppearance(self, row) end
    end
end

local function CompactSections(parent, sections)
    local prev
    for _, s in ipairs(sections) do
        if s.shown then
            if not s.static then
                s.top:ClearAllPoints()
                if prev then
                    s.top:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", s.dx or 0, s.dy or -10)
                else
                    s.top:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
                end
                if s.wide then s.top:SetPoint("RIGHT", parent, "RIGHT", 0, 0) end
            end
            prev = s.bottom or s.top
        end
    end
end


-- left of the label: row edge -> grip -> gap -> number -> gap
local ROW_LEFT_FIXED = 4 + 6 + 24 + 8
-- right of the label: label -> gap -> reverse mark -> gap -> up button -> gap -> down button -> row edge
local ROW_RIGHT_FIXED = 4 + 6 + STEP_BUTTON_SIZE + 2 + STEP_BUTTON_SIZE + 4

-- shorten text to fit within maxWidth
local function TruncateToWidth(fontString, text, maxWidth)
    if maxWidth < 0 then maxWidth = 0 end
    fontString:SetText(text)
    if fontString:GetStringWidth() <= maxWidth then return text end

    local ellipsis = "..."
    local lo, hi, best = 0, #text, ellipsis
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local candidate = text:sub(1, mid) .. ellipsis
        fontString:SetText(candidate)
        if fontString:GetStringWidth() <= maxWidth then
            best = candidate
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return best
end

local RefreshDetail

-- small step button, plain instead of a template so it fits fontString
local function CreateStepButton(row, glyph)
    local btn = CreateFrame("Button", nil, row)
    btn:SetSize(STEP_BUTTON_SIZE, STEP_BUTTON_SIZE)
    btn:RegisterForClicks("LeftButtonUp")
    btn:Hide()

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.15)

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetAllPoints()
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:SetText(glyph)

    return btn
end

local function ItemRowOffset(index)
    return -((index - 1) * ITEM_STEP)
end

local function ItemPlaceRow(self, row, index)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.detail.itemsListFrame, "TOPLEFT", 0, ItemRowOffset(index))
    row:SetPoint("TOPRIGHT", self.detail.itemsListFrame, "TOPRIGHT", 0, ItemRowOffset(index))
end

local function ItemLayoutRows(self, items, except)
    for index, itemID in ipairs(items) do
        local row = self.detail.itemRowsByID[itemID]
        if row and row ~= except then ItemPlaceRow(self, row, index) end
    end
end

local function ItemUpdateScrollRange(self)
    local d = self.detail
    local maxScroll = math.max(0, d.itemsListFrame:GetHeight() - d.itemsScrollFrame:GetHeight())

    d.itemsScrollFrame:UpdateScrollChildRect()
    d.itemsScrollBar:SetMinMaxValues(0, maxScroll)

    if maxScroll <= 0 then
        d.itemsScrollBar:Hide()
        d.itemsScrollFrame:SetVerticalScroll(0)
        d.itemsScrollBar:SetValue(0)
    else
        d.itemsScrollBar:Show()
        local current = math.min(d.itemsScrollFrame:GetVerticalScroll(), maxScroll)
        d.itemsScrollFrame:SetVerticalScroll(current)
        d.itemsScrollBar:SetValue(current)
    end
end

-- this row's own 1-based index and the item list's current length
local function ItemRowPosition(row)
    local items = ns.CustomCategoryItems(row.widget.selectedKey)
    for i, id in ipairs(items) do
        if id == row.itemID then return i, #items end
    end
end

-- the index the cursor is over, clamped to the list
local function ItemIndexUnderCursor(self, count)
    local listFrame = self.detail.itemsListFrame
    local scale = listFrame:GetEffectiveScale()
    if not scale or scale == 0 then return 1 end
    local _, cursorY = GetCursorPosition()
    cursorY = cursorY / scale

    local top = listFrame:GetTop()
    if not top then return 1 end
    local index = math.floor((top - cursorY) / ITEM_STEP) + 1
    if index < 1 then index = 1 end
    if index > count then index = count end
    return index
end

local function ShowItemDropLine(self, dragFrom)
    local d = self.detail
    local items = ns.CustomCategoryItems(self.selectedKey)
    local target = ItemIndexUnderCursor(self, #items)
    local lineIndex = target
    if dragFrom and target > dragFrom then lineIndex = target + 1 end
    local lineY = ItemRowOffset(lineIndex) + ITEM_ROW_SPACING / 2
    d.dropIndicator:ClearAllPoints()
    d.dropIndicator:SetPoint("TOPLEFT", d.itemsListFrame, "TOPLEFT", 0, lineY)
    d.dropIndicator:SetPoint("TOPRIGHT", d.itemsListFrame, "TOPRIGHT", 0, lineY)
    d.dropIndicator:Show()
end

local function DropHoverEnter(self)
    local d = self.detail
    if d.dropHoverTimer then
        BagSort:CancelTimer(d.dropHoverTimer)
        d.dropHoverTimer = nil
    end
    if self.disabled or d.itemDragging then return end
    d.itemsListFrame:SetScript("OnUpdate", function()
        if CursorHasItem() then ShowItemDropLine(self) else d.dropIndicator:Hide() end
    end)
end

local function DropHoverLeave(self)
    local d = self.detail
    d.dropHoverTimer = BagSort:ScheduleTimer(function()
        d.dropHoverTimer = nil
        if not d.itemDragging then
            d.itemsListFrame:SetScript("OnUpdate", nil)
            d.dropIndicator:Hide()
        end
    end, HOVER_HIDE_DELAY)
end

local function CreateItemRow(self)
    local row = CreateFrame("Button", nil, self.detail.itemsListFrame)
    row.widget = self
    row.getPosition = ItemRowPosition
    row:SetHeight(ITEM_ROW_HEIGHT)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnEnter", function() HoverEnter(row); DropHoverEnter(self) end)
    row:SetScript("OnLeave", function() HoverLeave(row); DropHoverLeave(self) end)
    row:SetScript("OnReceiveDrag", function() self.detail.DropItem(row.itemID) end)
    row:SetScript("OnMouseUp", function() self.detail.DropItem(row.itemID) end)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.05)

    local highlight = row:CreateTexture(nil, "ARTWORK")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.10)
    highlight:Hide()
    row.highlight = highlight

    -- shown only while this row is on the cursor
    local dragging = row:CreateTexture(nil, "ARTWORK")
    dragging:SetAllPoints()
    dragging:SetColorTexture(1, 0.82, 0, 0.25)
    dragging:Hide()
    row.dragging = dragging

    local downBtn = CreateStepButton(row, "v")
    downBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    downBtn:SetScript("OnClick", function()
        ns.MoveCustomCategoryItem(self.selectedKey, row.itemID, 1)
        RefreshDetail(self)
    end)
    downBtn:SetScript("OnEnter", function() HoverEnter(row); DropHoverEnter(self) end)
    downBtn:SetScript("OnLeave", function() HoverLeave(row); DropHoverLeave(self) end)
    row.downBtn = downBtn

    local upBtn = CreateStepButton(row, "^")
    upBtn:SetPoint("RIGHT", downBtn, "LEFT", -2, 0)
    upBtn:SetScript("OnClick", function()
        ns.MoveCustomCategoryItem(self.selectedKey, row.itemID, -1)
        RefreshDetail(self)
    end)
    upBtn:SetScript("OnEnter", function() HoverEnter(row); DropHoverEnter(self) end)
    upBtn:SetScript("OnLeave", function() HoverLeave(row); DropHoverLeave(self) end)
    row.upBtn = upBtn

    local remove = CreateFrame("Button", nil, row)
    remove:SetSize(14, 14)
    remove:SetPoint("LEFT", row, "LEFT", 0, 0)
    local removeText = remove:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    removeText:SetAllPoints()
    removeText:SetJustifyH("CENTER")
    removeText:SetText("x")
    remove:SetScript("OnClick", function()
        ns.RemoveCustomCategoryItem(self.selectedKey, row.itemID)
        RefreshDetail(self)
    end)
    row.remove = remove

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", remove, "RIGHT", 4, 0)
    label:SetPoint("RIGHT", upBtn, "LEFT", -4, 0)
    label:SetJustifyH("LEFT")
    row.label = label

    row:SetScript("OnDragStart", function()
        if self.disabled then return end
        row.dragging:Show()
        row:SetFrameLevel(self.detail.itemsListFrame:GetFrameLevel() + 5)
        self.detail.itemDragging = true

        local from
        for i, id in ipairs(ns.CustomCategoryItems(self.selectedKey)) do
            if id == row.itemID then from = i; break end
        end

        local listFrame = self.detail.itemsListFrame
        local scale, rowTop = listFrame:GetEffectiveScale(), row:GetTop()
        local grab = 0
        if scale and scale ~= 0 and rowTop then
            local _, cursorY = GetCursorPosition()
            grab = rowTop - cursorY / scale
        end

        listFrame:SetScript("OnUpdate", function()
            local scale2, top = listFrame:GetEffectiveScale(), listFrame:GetTop()
            if scale2 and scale2 ~= 0 and top then
                local _, cursorY = GetCursorPosition()
                local y = cursorY / scale2 - top + grab
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, y)
                row:SetPoint("TOPRIGHT", listFrame, "TOPRIGHT", 0, y)
            end
            ShowItemDropLine(self, from)
        end)
    end)
    row:SetScript("OnDragStop", function()
        row.dragging:Hide()
        row:SetFrameLevel(self.detail.itemsListFrame:GetFrameLevel() + 1)
        self.detail.itemDragging = false
        self.detail.itemsListFrame:SetScript("OnUpdate", nil)
        self.detail.dropIndicator:Hide()
        if self.disabled then return end

        local items = ns.CustomCategoryItems(self.selectedKey)
        local from
        for i, id in ipairs(items) do
            if id == row.itemID then from = i; break end
        end
        if not from then return end

        local to = ItemIndexUnderCursor(self, #items)
        if to ~= from then
            table.remove(items, from)
            table.insert(items, to, row.itemID)
            ns.SetCustomCategoryItems(self.selectedKey, items)
            RefreshDetail(self)
        else
            ItemPlaceRow(self, row, from)
        end
    end)

    return row
end

local function TruncateRowLabel(row)
    local available = row.widget.listWidth - ROW_LEFT_FIXED - row.grip:GetStringWidth()
        - ROW_RIGHT_FIXED - row.reverseMark:GetStringWidth()
    row.label:SetText(TruncateToWidth(row.label, ns.CategoryName(row.key), available))
end

function RefreshDetail(self)
    local key = self.selectedKey
    if not key then
        self.detail.placeholder:Show()
        self.detail.title:Hide()
        self.detail.enabledCheck.frame:Hide()
        self.detail.reverseCheck.frame:Hide()
        self.detail.unusableSoulboundCheck.frame:Hide()
        self.detail.lowLevelCheck.frame:Hide()
        self.detail.lowLevelThresholdInput.frame:Hide()
        self.detail.primaryDropdown.frame:Hide()
        self.detail.secondaryDropdown.frame:Hide()
        self.detail.tertiaryDropdown.frame:Hide()
        self.detail.description:Hide()
        self.detail.nameLabel:Hide()
        self.detail.nameBox:Hide()
        self.detail.deleteButton:Hide()
        self.detail.itemsBorder:Hide()
        self.detail.itemsLabel:Hide()
        for _, row in pairs(self.detail.itemRowsByID) do row:Hide() end
        self.detail.addLabel:Hide()
        self.detail.addBox:Hide()
        return
    end

    local isCustom = ns.IsCustomCategory(key)

    self.detail.placeholder:Hide()
    self.detail.title:SetShown(not isCustom)
    self.detail.title:SetText(ns.CategoryName(key))

    local settings = self.scope.GetCategorySettings(key)
    local isDefault = (key == ns.DEFAULT_CATEGORY_KEY)
    local isEmpty = (key == ns.EMPTY_CATEGORY_KEY)

    local enabledCheck = self.detail.enabledCheck
    enabledCheck.frame:Show()
    enabledCheck:SetValue(isDefault or settings.enabled)
    enabledCheck:SetDisabled(self.disabled or isDefault)

    local reverseCheck = self.detail.reverseCheck
    reverseCheck.frame:SetShown(not isEmpty)
    reverseCheck:SetValue(settings.reverse)
    reverseCheck:SetDisabled(self.disabled)

    local isJunk = (key == ns.JUNK_CATEGORY_KEY)
    local unusableSoulboundCheck = self.detail.unusableSoulboundCheck
    unusableSoulboundCheck.frame:SetShown(isJunk)
    unusableSoulboundCheck:SetValue(settings.includeUnusableSoulbound)
    unusableSoulboundCheck:SetDisabled(self.disabled)

    local lowLevelCheck = self.detail.lowLevelCheck
    lowLevelCheck.frame:SetShown(isJunk)
    lowLevelCheck:SetValue(settings.includeLowLevel)
    lowLevelCheck:SetDisabled(self.disabled)

    local lowLevelThresholdInput = self.detail.lowLevelThresholdInput
    lowLevelThresholdInput.frame:SetShown(isJunk and settings.includeLowLevel)
    lowLevelThresholdInput:SetText(tostring(settings.lowLevelThreshold or 50))
    lowLevelThresholdInput:SetDisabled(self.disabled)

    local primaryDropdown = self.detail.primaryDropdown
    primaryDropdown.frame:SetShown(not isEmpty and not isCustom)
    primaryDropdown:SetValue(settings.primary)
    primaryDropdown:SetDisabled(self.disabled)

    local secondaryDropdown = self.detail.secondaryDropdown
    secondaryDropdown.frame:SetShown(not isEmpty and not isCustom)
    secondaryDropdown:SetValue(settings.secondary)
    secondaryDropdown:SetDisabled(self.disabled)

    local tertiaryDropdown = self.detail.tertiaryDropdown
    tertiaryDropdown.frame:SetShown(not isEmpty and not isCustom)
    tertiaryDropdown:SetValue(settings.tertiary)
    tertiaryDropdown:SetDisabled(self.disabled)

    local description = self.detail.description
    local text = SENTINEL_DETAIL[key]
    description:SetShown(text ~= nil)
    if text then description:SetText(text) end

    self.detail.nameLabel:SetShown(isCustom)
    self.detail.nameBox:SetShown(isCustom)
    self.detail.deleteButton:SetShown(isCustom)
    self.detail.itemsBorder:SetShown(isCustom)
    self.detail.itemsLabel:SetShown(isCustom)
    self.detail.addLabel:SetShown(isCustom)
    self.detail.addBox:SetShown(isCustom)

    if isCustom then
        self.detail.nameBox:SetText(ns.CustomCategoryName(key) or "")

        local items = ns.CustomCategoryItems(key)
        self.detail.itemsLabel:SetText(("%d %s"):format(#items, #items == 1 and "Item" or "Items"))
        self.detail.itemsEmptyText:SetShown(#items == 0)

        local rowsByID, spare = self.detail.itemRowsByID, self.detail.itemRowSpare
        local seen = {}
        for _, itemID in ipairs(items) do
            local row = rowsByID[itemID]
            if not row then
                row = table.remove(spare) or CreateItemRow(self)
                row.itemID = itemID
                row.remove.itemID = itemID
                rowsByID[itemID] = row
            end
            local meta = ns.ItemMeta(itemID)
            row.label:SetText(("%s  (%d)"):format(meta and meta.name or ("Item #" .. itemID), itemID))
            row:Show()
            seen[itemID] = true
        end
        for itemID, row in pairs(rowsByID) do
            if not seen[itemID] then
                row:Hide()
                row.itemID = nil
                row.remove.itemID = nil
                rowsByID[itemID] = nil
                spare[#spare + 1] = row
            end
        end

        ItemLayoutRows(self, items)
        self.detail.itemsListFrame:SetHeight(#items > 0 and #items * ITEM_STEP or 1)
        ItemUpdateScrollRange(self)
    else
        for itemID, row in pairs(self.detail.itemRowsByID) do
            row:Hide()
            row.itemID = nil
            row.remove.itemID = nil
            self.detail.itemRowSpare[#self.detail.itemRowSpare + 1] = row
            self.detail.itemRowsByID[itemID] = nil
        end
    end

    local d = self.detail
    CompactSections(d.parent, {
        { top = d.title, static = true, shown = not isCustom },
        { top = d.nameLabel, bottom = d.nameBox, shown = isCustom, dx = 2, dy = -6 },
        { top = enabledCheck.frame, shown = true, dx = -2, dy = -10 },
        { top = reverseCheck.frame, shown = not isEmpty, dx = 0, dy = 0 },
        { top = unusableSoulboundCheck.frame, shown = isJunk, dx = 0, dy = 0, wide = true },
        { top = lowLevelCheck.frame, shown = isJunk, dx = 0, dy = 0, wide = true },
        { top = lowLevelThresholdInput.frame, shown = isJunk and settings.includeLowLevel, dx = 2, dy = -10 },
        { top = primaryDropdown.frame, bottom = tertiaryDropdown.frame,
          shown = not isEmpty and not isCustom, dx = 2, dy = -10 },
        { top = description, shown = text ~= nil, dx = -2, dy = -12, wide = true },
        { top = d.addLabel, bottom = d.addBox, shown = isCustom, dx = 2, dy = -10, wide = true },
    })
end

local function SelectRow(self, key)
    if self.selectedKey == key then return end
    self.selectedKey = key
    LastPanelState[self.scope].selectedKey = key
    for rowKey, row in pairs(self.rowsByKey) do
        row.selectedBg:SetShown(rowKey == key)
    end
    RefreshDetail(self)
end

local function ToggleEnabled(self, row)
    if row.key == ns.DEFAULT_CATEGORY_KEY then return end

    local enabled = self.scope.GetCategorySettings(row.key).enabled
    self.scope.SetCategorySettings(row.key, { enabled = not enabled })

    RefreshRowAppearance(self, row)
    if self.selectedKey == row.key then RefreshDetail(self) end
end

local function BuildDetail(self, parent)
    local detail = {}

    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    title:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    title:SetJustifyH("LEFT")
    title:SetHeight(22)
    detail.title = title

    local placeholder = parent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    placeholder:SetPoint("CENTER", parent, "CENTER", 0, 0)
    placeholder:SetJustifyH("CENTER")
    placeholder:SetText("Select a category on the left.")
    detail.placeholder = placeholder

    local nameLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -6)
    nameLabel:SetText("Name")
    detail.nameLabel = nameLabel

    local nameBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    nameBox:SetAutoFocus(false)
    nameBox:SetSize(220, 20)
    nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 4, -4)
    nameBox:SetScript("OnEnterPressed", function(box)
        ns.RenameCustomCategory(self.selectedKey, box:GetText())
        box:ClearFocus()
        RefreshDetail(self)
        local row = self.rowsByKey[self.selectedKey]
        if row then TruncateRowLabel(row) end
    end)
    detail.nameBox = nameBox

    local deleteButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    deleteButton:SetSize(70, 20)
    deleteButton:SetPoint("LEFT", nameBox, "RIGHT", 12, 0)
    deleteButton:SetText("Delete")
    deleteButton:SetScript("OnClick", function()
        ns.RemoveCustomCategory(self.selectedKey)
        self.selectedKey = nil
        LastPanelState[self.scope].selectedKey = nil
        self:SetText(table.concat(self.scope.GetOrder(), ","))
    end)
    detail.deleteButton = deleteButton

    local enabledCheck = AceGUI:Create("CheckBox")
    enabledCheck.frame:SetParent(parent)
    enabledCheck.frame:ClearAllPoints()
    enabledCheck:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", -2, -6)
    enabledCheck:SetLabel("Enabled")
    enabledCheck:SetWidth(150)
    enabledCheck:SetCallback("OnValueChanged", function(_, _, value)
        WriteSetting(self, "enabled", value and true or false)
    end)
    detail.enabledCheck = enabledCheck

    local reverseCheck = AceGUI:Create("CheckBox")
    reverseCheck.frame:SetParent(parent)
    reverseCheck.frame:ClearAllPoints()
    reverseCheck:SetPoint("TOPLEFT", enabledCheck.frame, "BOTTOMLEFT", 0, 0)
    reverseCheck:SetLabel("Reverse Order")
    reverseCheck:SetWidth(150)
    reverseCheck:SetCallback("OnValueChanged", function(_, _, value)
        WriteSetting(self, "reverse", value and true or false)
    end)
    detail.reverseCheck = reverseCheck

    local unusableSoulboundCheck = AceGUI:Create("CheckBox")
    unusableSoulboundCheck.frame:SetParent(parent)
    unusableSoulboundCheck.frame:ClearAllPoints()
    unusableSoulboundCheck:SetPoint("TOPLEFT", reverseCheck.frame, "BOTTOMLEFT", 0, 0)
    unusableSoulboundCheck:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    unusableSoulboundCheck:SetLabel("Include unusable soulbound items")
    unusableSoulboundCheck:SetCallback("OnValueChanged", function(_, _, value)
        WriteSetting(self, "includeUnusableSoulbound", value and true or false)
    end)
    detail.unusableSoulboundCheck = unusableSoulboundCheck

    local lowLevelCheck = AceGUI:Create("CheckBox")
    lowLevelCheck.frame:SetParent(parent)
    lowLevelCheck.frame:ClearAllPoints()
    lowLevelCheck:SetPoint("TOPLEFT", unusableSoulboundCheck.frame, "BOTTOMLEFT", 0, 0)
    lowLevelCheck:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    lowLevelCheck:SetLabel("Include low level soulbound")
    lowLevelCheck:SetCallback("OnValueChanged", function(_, _, value)
        WriteSetting(self, "includeLowLevel", value and true or false)
    end)
    detail.lowLevelCheck = lowLevelCheck

    local lowLevelThresholdInput = AceGUI:Create("EditBox")
    lowLevelThresholdInput.frame:SetParent(parent)
    lowLevelThresholdInput.frame:ClearAllPoints()
    lowLevelThresholdInput:SetPoint("TOPLEFT", lowLevelCheck.frame, "BOTTOMLEFT", 2, -4)
    lowLevelThresholdInput:SetLabel("Levels below the equipped item in that slot")
    lowLevelThresholdInput:SetWidth(200)
    lowLevelThresholdInput:SetCallback("OnEnterPressed", function(_, _, value)
        local num = tonumber(value or "")
        if num and num >= 0 then
            WriteSetting(self, "lowLevelThreshold", num)
        end
    end)
    detail.lowLevelThresholdInput = lowLevelThresholdInput

    local values, order = SortFieldLists()

    local primaryDropdown = AceGUI:Create("Dropdown")
    primaryDropdown.frame:SetParent(parent)
    primaryDropdown.frame:ClearAllPoints()
    primaryDropdown:SetPoint("TOPLEFT", reverseCheck.frame, "BOTTOMLEFT", 2, -10)
    primaryDropdown:SetLabel("Primary sort")
    primaryDropdown:SetWidth(200)
    primaryDropdown:SetList(values, order)
    primaryDropdown:SetCallback("OnValueChanged", function(_, _, value)
        WriteSetting(self, "primary", value)
    end)
    detail.primaryDropdown = primaryDropdown

    local secondaryDropdown = AceGUI:Create("Dropdown")
    secondaryDropdown.frame:SetParent(parent)
    secondaryDropdown.frame:ClearAllPoints()
    secondaryDropdown:SetPoint("TOPLEFT", primaryDropdown.frame, "BOTTOMLEFT", 0, -4)
    secondaryDropdown:SetLabel("Secondary sort")
    secondaryDropdown:SetWidth(200)
    secondaryDropdown:SetList(values, order)
    secondaryDropdown:SetCallback("OnValueChanged", function(_, _, value)
        WriteSetting(self, "secondary", value)
    end)
    detail.secondaryDropdown = secondaryDropdown

    local tertiaryDropdown = AceGUI:Create("Dropdown")
    tertiaryDropdown.frame:SetParent(parent)
    tertiaryDropdown.frame:ClearAllPoints()
    tertiaryDropdown:SetPoint("TOPLEFT", secondaryDropdown.frame, "BOTTOMLEFT", 0, -4)
    tertiaryDropdown:SetLabel("Tertiary sort")
    tertiaryDropdown:SetWidth(200)
    tertiaryDropdown:SetList(values, order)
    tertiaryDropdown:SetCallback("OnValueChanged", function(_, _, value)
        WriteSetting(self, "tertiary", value)
    end)
    detail.tertiaryDropdown = tertiaryDropdown

    local description = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", tertiaryDropdown.frame, "BOTTOMLEFT", -2, -12)
    description:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    description:SetJustifyH("LEFT")
    description:SetJustifyV("TOP")
    description:SetWordWrap(true)
    description:Hide()
    detail.description = description

    -- custom catgegories: item list and how to add to it
    local addLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    addLabel:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 2, -10)
    addLabel:SetJustifyH("LEFT")
    addLabel:SetText("Add an item - type its item id and press Enter, or drop it into the list below")
    detail.addLabel = addLabel

    local addBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    addBox:SetAutoFocus(false)
    addBox:SetSize(230, 20)
    addBox:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 4, -4)
    addBox:SetScript("OnEnterPressed", function(box)
        local text = box:GetText() or ""
        local itemID = text:match("item:(%d+)") or tonumber(text)
        if itemID then
            ns.AddCustomCategoryItem(self.selectedKey, itemID)
            box:SetText("")
            RefreshDetail(self)
        end
        box:ClearFocus()
    end)
    detail.addBox = addBox

    local itemsLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemsLabel:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    itemsLabel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    itemsLabel:SetJustifyH("RIGHT")
    detail.itemsLabel = itemsLabel

    local itemsBorder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    itemsBorder:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", -4, -14)
    itemsBorder:SetPoint("BOTTOMRIGHT", itemsLabel, "TOPRIGHT", 0, 4)
    ApplyBorder(itemsBorder)
    detail.itemsBorder = itemsBorder

    -- shown only while the category has no items
    local itemsEmptyText = itemsBorder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    itemsEmptyText:SetPoint("CENTER", itemsBorder, "CENTER", 0, 0)
    itemsEmptyText:SetText("Drag items here")
    itemsEmptyText:Hide()
    detail.itemsEmptyText = itemsEmptyText

    local function DropItem(before)
        if CursorHasItem() then
            local cursorType, itemID = GetCursorInfo()
            if cursorType == "item" and itemID then
                ns.AddCustomCategoryItem(self.selectedKey, itemID, before)
                RefreshDetail(self)
            end
            ClearCursor()
        end
    end
    detail.DropItem = DropItem
    itemsBorder:EnableMouse(true)
    itemsBorder:SetScript("OnReceiveDrag", function() DropItem() end)
    itemsBorder:SetScript("OnMouseUp", function() DropItem() end)
    itemsBorder:SetScript("OnEnter", function() DropHoverEnter(self) end)
    itemsBorder:SetScript("OnLeave", function() DropHoverLeave(self) end)

    -- stretch to fill whatever width the detail panel has
    local itemsScrollFrame = CreateFrame("ScrollFrame", nil, itemsBorder)
    itemsScrollFrame:SetPoint("TOPLEFT", itemsBorder, "TOPLEFT", BOX_PADDING, -BOX_PADDING)
    itemsScrollFrame:SetPoint("BOTTOMRIGHT", itemsBorder, "BOTTOMRIGHT", -(SCROLLBAR_RESERVE + BOX_PADDING),
        BOX_PADDING)
    itemsScrollFrame:EnableMouseWheel(true)
    itemsScrollFrame:SetScript("OnReceiveDrag", function() DropItem() end)
    itemsScrollFrame:SetScript("OnMouseUp", function() DropItem() end)
    itemsScrollFrame:SetScript("OnEnter", function() DropHoverEnter(self) end)
    itemsScrollFrame:SetScript("OnLeave", function() DropHoverLeave(self) end)
    detail.itemsScrollFrame = itemsScrollFrame

    local itemsListFrame = CreateFrame("Frame", nil, itemsScrollFrame)
    itemsListFrame:SetPoint("TOPLEFT")
    itemsListFrame:SetSize(itemsScrollFrame:GetWidth(), 1)
    itemsScrollFrame:SetScrollChild(itemsListFrame)
    itemsScrollFrame:SetScript("OnSizeChanged", function(_, width) itemsListFrame:SetWidth(width) end)
    detail.itemsListFrame = itemsListFrame

    detail.dropIndicator = CreateDropLine(itemsListFrame)

    local itemsScrollBar = CreateFrame("Slider", nil, itemsBorder, "UIPanelScrollBarTemplate")
    itemsScrollBar:SetPoint("TOPLEFT", itemsScrollFrame, "TOPRIGHT", 4, -16)
    itemsScrollBar:SetPoint("BOTTOMLEFT", itemsScrollFrame, "BOTTOMRIGHT", 4, 16)
    itemsScrollBar:SetMinMaxValues(0, 0)
    itemsScrollBar:SetValueStep(1)
    itemsScrollBar:SetValue(0)
    itemsScrollBar:SetWidth(16)
    itemsScrollBar:Hide()
    itemsScrollBar:SetScript("OnValueChanged", function(_, value)
        itemsScrollFrame:SetVerticalScroll(value)
    end)
    detail.itemsScrollBar = itemsScrollBar

    itemsScrollFrame:SetScript("OnMouseWheel", function(sf, delta)
        local _, maxScroll = itemsScrollBar:GetMinMaxValues()
        local target = math.min(math.max(sf:GetVerticalScroll() - delta * ITEM_STEP * WHEEL_STEP, 0), maxScroll)
        sf:SetVerticalScroll(target)
        itemsScrollBar:SetValue(target)
    end)

    detail.itemRowsByID = {}
    detail.itemRowSpare = {}
    detail.parent = parent
    return detail
end


-- ==== --
-- Rows --
-- ==== --

local function Row_OnDragStart(row) DragStart(row.widget, row) end
local function Row_OnDragStop(row)  DragStop(row.widget) end

-- drop on another row ends the drag
local function Row_OnReceiveDrag(row) DragStop(row.widget) end

local function Row_OnClick(row, button)
    if button == "RightButton" then
        ToggleEnabled(row.widget, row)
    else
        SelectRow(row.widget, row.key)
    end
end

local function Row_OnEnter(row) HoverEnter(row) end
local function Row_OnLeave(row) HoverLeave(row) end

-- scrolling shifts rows past a cursor that has not moved
local function SuppressHoverDuringScroll(self)
    for _, row in pairs(self.rowsByKey) do
        if row.hoverTimer then
            BagSort:CancelTimer(row.hoverTimer)
            row.hoverTimer = nil
        end
        row.highlight:Hide()
        row.upBtn:Hide()
        row.downBtn:Hide()
        if row ~= self.dragRow then row:EnableMouse(false) end
    end
    self.scrollFrame:SetScript("OnUpdate", function(f)
        f:SetScript("OnUpdate", nil)
        for _, row in pairs(self.rowsByKey) do
            row:EnableMouse(not self.disabled)
        end
    end)
end

-- this row's own 1-based index and the category order's current length
local function CategoryRowPosition(row)
    for i, key in ipairs(row.widget.order) do
        if key == row.key then return i, #row.widget.order end
    end
end

local function CreateRow(self)
    local row = CreateFrame("Button", nil, self.listFrame)
    row.widget = self
    row.getPosition = CategoryRowPosition
    row:SetHeight(ROW_HEIGHT)
    row:RegisterForDrag("LeftButton")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnDragStart", Row_OnDragStart)
    row:SetScript("OnDragStop", Row_OnDragStop)
    row:SetScript("OnReceiveDrag", Row_OnReceiveDrag)
    row:SetScript("OnClick", Row_OnClick)
    row:SetScript("OnEnter", Row_OnEnter)
    row:SetScript("OnLeave", Row_OnLeave)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.05)
    row.bg = bg

    local selectedBg = row:CreateTexture(nil, "BORDER")
    selectedBg:SetAllPoints()
    selectedBg:SetColorTexture(0.35, 0.55, 1, 0.25)
    selectedBg:Hide()
    row.selectedBg = selectedBg

    local highlight = row:CreateTexture(nil, "ARTWORK")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.10)
    highlight:Hide()
    row.highlight = highlight

    -- shown only while the row is on the cursor, so the dragged row stands out from the ones it is passing
    local dragging = row:CreateTexture(nil, "ARTWORK")
    dragging:SetAllPoints()
    dragging:SetColorTexture(1, 0.82, 0, 0.25)
    dragging:Hide()
    row.dragging = dragging

    local grip = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    grip:SetPoint("LEFT", row, "LEFT", 4, 0)
    grip:SetText("::")
    row.grip = grip

    local number = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    number:SetPoint("LEFT", grip, "RIGHT", 6, 0)
    number:SetWidth(24)
    number:SetJustifyH("RIGHT")
    row.number = number

    -- step up/down, only shown while hovering
    local downBtn = CreateStepButton(row, "v")
    downBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    downBtn:SetScript("OnClick", function() MoveStep(row.widget, row.key, 1) end)
    downBtn:SetScript("OnEnter", function() HoverEnter(row) end)
    downBtn:SetScript("OnLeave", function() HoverLeave(row) end)
    row.downBtn = downBtn

    local upBtn = CreateStepButton(row, "^")
    upBtn:SetPoint("RIGHT", downBtn, "LEFT", -2, 0)
    upBtn:SetScript("OnClick", function() MoveStep(row.widget, row.key, -1) end)
    upBtn:SetScript("OnEnter", function() HoverEnter(row) end)
    upBtn:SetScript("OnLeave", function() HoverLeave(row) end)
    row.upBtn = upBtn

    -- marks a category sorted in reverse
    local reverseMark = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    reverseMark:SetPoint("RIGHT", upBtn, "LEFT", -6, 0)
    reverseMark:SetText("®")
    reverseMark:Hide()
    row.reverseMark = reverseMark

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", number, "RIGHT", 8, 0)
    label:SetPoint("RIGHT", reverseMark, "LEFT", -4, 0)
    label:SetJustifyH("LEFT")
    row.label = label

    -- disabled category strikethrough
    local strike = row:CreateTexture(nil, "OVERLAY")
    strike:SetHeight(1)
    strike:SetPoint("LEFT", label, "LEFT", 0, 0)
    strike:SetColorTexture(0.6, 0.6, 0.6, 0.9)
    strike:Hide()
    row.strike = strike

    return row
end


-- ======= --
-- Methods --
-- ======= --

local methods = {
    ["OnAcquire"] = function(self)
        -- rows anchor to both sided of the frame, so the list is only ever as wide as the panel
        self:SetFullWidth(true)
        self:SetFullHeight(true)
        self:SetLabel()
        self:SetDisabled(false)
        self:SetText("")
        local last = LastPanelState[self.scope]
        self.selectedKey = last.selectedKey
        self.pendingScrollY = last.scrollY or 0
    end,

    ["OnRelease"] = function(self)
        self.listFrame:SetScript("OnUpdate", nil)               -- a category row's drag (DragStart)
        self.detail.itemsListFrame:SetScript("OnUpdate", nil)   -- an item row's drag, and the drop preview
        self.splitter:SetScript("OnUpdate", nil)                -- the splitter's drag
        self.frame:SetScript("OnUpdate", nil)                   -- the OnShow handler's scroll-range one-shot
        self.scrollFrame:SetScript("OnUpdate", nil)             -- SuppressHoverDuringScroll's re-enable one-shot
        self.dragRow, self.dragFrom, self.dragIndex = nil, nil, nil
        self.dropIndicator:Hide()
        self.detail.itemDragging = false
        self.detail.dropIndicator:Hide()
        self.selectedKey = nil
        self:SetText("")
        self:SetLabel()
        self:SetDisabled(false)
    end,

    ["SetLabel"] = function(self, text)
        if text and text ~= "" then
            self.labelText:SetText(text)
            self.labelText:Show()
            self.labelHeight = LABEL_SPACE
        else
            self.labelText:SetText("")
            self.labelText:Hide()
            self.labelHeight = 0
        end
        self.labelText:SetHeight(self.labelHeight)
        self:Relayout()
    end,

    ["SetText"] = function(self, text)
        self.text = text or ""
        self.order = Split(self.text)

        local used = {}
        for index, key in ipairs(self.order) do
            local row = self.rowsByKey[key]
            if not row then
                row = table.remove(self.spare) or CreateRow(self)
                row.key = key
                TruncateRowLabel(row)
                row.selectedBg:SetShown(key == self.selectedKey)
                self.rowsByKey[key] = row
            end
            row:SetFrameLevel(self.listFrame:GetFrameLevel() + 1)
            row:Show()
            used[key] = true
        end

        for key, row in pairs(self.rowsByKey) do
            if not used[key] then
                row:Hide()
                row.key = nil
                self.rowsByKey[key] = nil
                self.spare[#self.spare + 1] = row
            end
        end

        if self.selectedKey and not used[self.selectedKey] then
            self.selectedKey = nil
            LastPanelState[self.scope].selectedKey = nil
        end
        RefreshDetail(self)

        self:SetDisabled(self.disabled)
        self:Relayout()

        if self.pendingScrollY and #self.order > 0 then
            local target = self.pendingScrollY
            self.pendingScrollY = nil
            local _, maxScroll = self.scrollBar:GetMinMaxValues()
            local clamped = math.min(target, maxScroll)
            self.scrollFrame:SetVerticalScroll(clamped)
            self.scrollBar:SetValue(clamped)
        end
    end,

    ["GetText"] = function(self)
        return table.concat(self.order, ",")
    end,

    ["SetDisabled"] = function(self, disabled)
        self.disabled = disabled and true or false
        self.addRow:EnableMouse(not self.disabled)
        self.addRow.label:SetFontObject(self.disabled and "GameFontDisableSmall" or "GameFontHighlightSmall")
        for _, row in pairs(self.rowsByKey) do
            row:EnableMouse(not self.disabled)
            RefreshRowAppearance(self, row)
        end
        RefreshDetail(self)
    end,

    ["Relayout"] = function(self)
        LayoutRows(self)
        local rows = #self.order
        PlaceRow(self, self.addRow, rows + 1)
        self.listFrame:SetHeight((rows + 1) * STEP)
        UpdateScrollRange(self)

        local top = self.labelHeight + LIST_TOP_GAP
        self:SetHeight(top + math.max(LIST_MIN_HEIGHT, self.detailHeight or 0))
    end,

    ["SetListWidth"] = function(self, width)
        local maxWidth = LIST_WIDTH_MAX
        local room = self.frame:GetWidth()
        if room and room > 0 then
            maxWidth = math.min(maxWidth, room - DETAIL_WIDTH_MIN - SCROLLBAR_RESERVE - BOX_PADDING * 2)
        end
        width = math.floor(math.max(LIST_WIDTH_MIN, math.min(maxWidth, width)) + 0.5)
        if width == self.listWidth then return end
        self.listWidth = width

        self.listBorder:SetWidth(width + SCROLLBAR_RESERVE + BOX_PADDING * 2)
        self.scrollFrame:SetWidth(width)
        self.listFrame:SetWidth(width)
        for _, row in pairs(self.rowsByKey) do
            TruncateRowLabel(row)
        end
    end,
}


-- =========== --
-- Constructor --
-- =========== --

local function Constructor(widgetType, scope)
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local labelText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labelText:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    labelText:SetJustifyH("LEFT")
    labelText:SetHeight(LABEL_SPACE)

    local listBorder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    listBorder:SetPoint("TOPLEFT", labelText, "BOTTOMLEFT", 0, -LIST_TOP_GAP)
    listBorder:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    listBorder:SetWidth(LIST_WIDTH + SCROLLBAR_RESERVE + BOX_PADDING * 2)
    ApplyBorder(listBorder)

    local scrollFrame = CreateFrame("ScrollFrame", nil, listBorder)
    scrollFrame:SetPoint("TOPLEFT", listBorder, "TOPLEFT", BOX_PADDING, -BOX_PADDING)
    scrollFrame:SetPoint("BOTTOMLEFT", listBorder, "BOTTOMLEFT", BOX_PADDING, BOX_PADDING)
    scrollFrame:SetWidth(LIST_WIDTH)
    scrollFrame:EnableMouseWheel(true)

    local listFrame = CreateFrame("Frame", nil, scrollFrame)
    listFrame:SetPoint("TOPLEFT")
    listFrame:SetSize(LIST_WIDTH, 1)
    scrollFrame:SetScrollChild(listFrame)

    local dropIndicator = CreateDropLine(listFrame)

    local splitter = CreateFrame("Button", nil, frame)
    splitter:SetWidth(SPLITTER_WIDTH)
    splitter:SetPoint("TOPLEFT", listBorder, "TOPRIGHT", -SPLITTER_WIDTH / 2, 0)
    splitter:SetPoint("BOTTOMLEFT", listBorder, "BOTTOMRIGHT", -SPLITTER_WIDTH / 2, 0)
    splitter:EnableMouse(true)
    splitter:RegisterForDrag("LeftButton")

    local splitterHighlight = splitter:CreateTexture(nil, "HIGHLIGHT")
    splitterHighlight:SetAllPoints()
    splitterHighlight:SetColorTexture(1, 1, 1, 0.15)

    local splitterBar = splitter:CreateTexture(nil, "ARTWORK")
    splitterBar:SetPoint("TOP", splitter, "TOP", 0, 0)
    splitterBar:SetPoint("BOTTOM", splitter, "BOTTOM", 0, 0)
    splitterBar:SetWidth(2)
    splitterBar:SetColorTexture(1, 1, 1, 0.25)

    local addRow = CreateFrame("Button", nil, listFrame)
    addRow:SetHeight(ROW_HEIGHT)

    local addRowHighlight = addRow:CreateTexture(nil, "ARTWORK")
    addRowHighlight:SetAllPoints()
    addRowHighlight:SetColorTexture(1, 1, 1, 0.10)
    addRowHighlight:Hide()
    addRow:SetScript("OnEnter", function() addRowHighlight:Show() end)
    addRow:SetScript("OnLeave", function() addRowHighlight:Hide() end)

    local addRowLabel = addRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    addRowLabel:SetPoint("LEFT", addRow, "LEFT", 4, 0)
    addRowLabel:SetText("+ Add Custom Category")
    addRow.label = addRowLabel

    local scrollBar = CreateFrame("Slider", nil, listBorder, "UIPanelScrollBarTemplate")
    scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 4, -16)
    scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 4, 16)
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValueStep(1)
    scrollBar:SetValue(0)
    scrollBar:SetWidth(16)
    scrollBar:Hide()

    local detailFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    detailFrame:SetPoint("TOPLEFT", listBorder, "TOPRIGHT", 0, 0)
    detailFrame:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    detailFrame:SetPoint("BOTTOM", frame, "BOTTOM", 0, 0)
    ApplyBorder(detailFrame)

    local detailContent = CreateFrame("Frame", nil, detailFrame)
    detailContent:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", BOX_PADDING, -BOX_PADDING)
    detailContent:SetPoint("BOTTOMRIGHT", detailFrame, "BOTTOMRIGHT", -BOX_PADDING, BOX_PADDING)

    local widget = {
        frame        = frame,
        labelText    = labelText,
        labelHeight  = LABEL_SPACE,
        addRow       = addRow,
        listBorder   = listBorder,
        splitter     = splitter,
        listWidth    = LIST_WIDTH,
        scrollFrame  = scrollFrame,
        scrollBar    = scrollBar,
        listFrame    = listFrame,
        dropIndicator = dropIndicator,
        detailFrame  = detailFrame,
        order        = {},
        rowsByKey    = {},
        spare        = {},
        text         = "",
        type         = widgetType,
        scope        = scope,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end

    scrollFrame:SetScript("OnMouseWheel", function(sf, delta)
        local _, maxScroll = scrollBar:GetMinMaxValues()
        local current = sf:GetVerticalScroll()
        local target = math.min(math.max(current - delta * STEP * WHEEL_STEP, 0), maxScroll)
        sf:SetVerticalScroll(target)
        scrollBar:SetValue(target)
        LastPanelState[widget.scope].scrollY = target
        SuppressHoverDuringScroll(widget)
    end)
    scrollBar:SetScript("OnValueChanged", function(_, value)
        scrollFrame:SetVerticalScroll(value)
        if not widget.suppressScrollStash then
            LastPanelState[widget.scope].scrollY = value
        end
        SuppressHoverDuringScroll(widget)
    end)

    splitter:SetScript("OnDragStart", function()
        if widget.disabled then return end
        local scale = frame:GetEffectiveScale()
        local startX = (scale and scale ~= 0) and (select(1, GetCursorPosition()) / scale) or 0
        local startWidth = widget.listWidth
        splitter:SetScript("OnUpdate", function()
            local s = frame:GetEffectiveScale()
            if not s or s == 0 then return end
            local x = select(1, GetCursorPosition()) / s
            widget:SetListWidth(startWidth + (x - startX))
        end)
    end)
    splitter:SetScript("OnDragStop", function()
        splitter:SetScript("OnUpdate", nil)
    end)

    addRow:SetScript("OnClick", function()
        local key = ns.AddCustomCategory()
        widget:SetText(table.concat(widget.scope.GetOrder(), ","))
        SelectRow(widget, key)
    end)

    widget.detail = BuildDetail(widget, detailContent)
    widget.detailHeight = DETAIL_HEIGHT

    frame:SetScript("OnShow", function()
        local viewport = widget.parent and widget.parent.scrollframe
        if not viewport then return end

        listBorder:SetPoint("BOTTOMLEFT", viewport, "BOTTOMLEFT", 0, 0)
        detailFrame:SetPoint("BOTTOM", viewport, "BOTTOM", 0, 0)

        frame:SetScript("OnUpdate", function(f)
            f:SetScript("OnUpdate", nil)
            UpdateScrollRange(widget)
        end)
    end)

    return AceGUI:RegisterAsWidget(widget)
end

if not bagAlreadyRegistered then
    AceGUI:RegisterWidgetType(Type, function() return Constructor(Type, BagScope) end, Version)
end
if not bankAlreadyRegistered then
    AceGUI:RegisterWidgetType(BankType, function() return Constructor(BankType, BankScope) end, Version)
end

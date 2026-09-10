-- BagSort - Core.lua

-- Sorting runs in three steps, one game action per timer tick:
--   1. stack   : pour partial stacks of the same item together
--   2. layout  : decide the target slot for every stack (pure Lua, no actions)
--   3. commit  : swap items into place, walking the slot list from first to last

local ADDON_NAME, ns = ...

local BagSort = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")
ns.BagSort = BagSort

local Container = C_Container
local Item = C_Item

local BACKPACK    = (Enum and Enum.BagIndex and Enum.BagIndex.Backpack) or 0
local REAGENT_BAG = (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5
local BAG_SLOT_FLAG_DISABLE_AUTO_SORT = Enum and Enum.BagSlotFlags and Enum.BagSlotFlags.DisableAutoSort

local function BagCleanupIgnored(bagID)
    if bagID == BACKPACK then
        return Container.GetBackpackAutosortDisabled and Container.GetBackpackAutosortDisabled() and true or false
    end
    if not (Container.GetBagSlotFlag and BAG_SLOT_FLAG_DISABLE_AUTO_SORT) then return false end
    return Container.GetBagSlotFlag(bagID, BAG_SLOT_FLAG_DISABLE_AUTO_SORT) and true or false
end

local function LastNormalBag() return NUM_BAG_SLOTS or 4 end

-- =========================================================================
-- Categories (the item classes, in the order they are laid out)
-- =========================================================================

local CATEGORY_CLASS = {}          -- member name -> class id
local DEFAULT_CATEGORY_ORDER = {}  -- those names, class id ascending, "Default" last
do
    local classes = (Enum and Enum.ItemClass) or {}
    for key, classID in pairs(classes) do
        if type(classID) == "number" and not key:find("Obsolete") then
            CATEGORY_CLASS[key] = classID
            DEFAULT_CATEGORY_ORDER[#DEFAULT_CATEGORY_ORDER + 1] = key
        end
    end
    table.sort(DEFAULT_CATEGORY_ORDER, function(a, b)
        return CATEGORY_CLASS[a] < CATEGORY_CLASS[b]
    end)
end

local DEFAULT_CATEGORY_KEY = "Default"
local JUNK_CATEGORY_KEY    = "Junk"
local EMPTY_CATEGORY_KEY   = "Empty"
ns.DEFAULT_CATEGORY_KEY = DEFAULT_CATEGORY_KEY
ns.JUNK_CATEGORY_KEY    = JUNK_CATEGORY_KEY
ns.EMPTY_CATEGORY_KEY   = EMPTY_CATEGORY_KEY
DEFAULT_CATEGORY_ORDER[#DEFAULT_CATEGORY_ORDER + 1] = DEFAULT_CATEGORY_KEY
DEFAULT_CATEGORY_ORDER[#DEFAULT_CATEGORY_ORDER + 1] = EMPTY_CATEGORY_KEY
DEFAULT_CATEGORY_ORDER[#DEFAULT_CATEGORY_ORDER + 1] = JUNK_CATEGORY_KEY

-- special category: Hearthstone
local HEARTHSTONE_CATEGORY_KEY = "Hearthstone"
ns.HEARTHSTONE_CATEGORY_KEY = HEARTHSTONE_CATEGORY_KEY
local HEARTHSTONE_ITEM_IDS = {
    [6948]   = true, -- Hearthstone
    [140192] = true, -- Dalaran Hearthstone
    [110560] = true, -- Garrison Hearthstone
    [141605] = true, -- Flight Master's Whistle
}
table.insert(DEFAULT_CATEGORY_ORDER, 1, HEARTHSTONE_CATEGORY_KEY)

-- special category: Items in gear sets
local GEARSET_CATEGORY_KEY = "GearSet"
ns.GEARSET_CATEGORY_KEY = GEARSET_CATEGORY_KEY
table.insert(DEFAULT_CATEGORY_ORDER, 2, GEARSET_CATEGORY_KEY)

-- special category: soulbound gear
local SOULBOUND_CATEGORY_KEY = "SoulboundGear"
ns.SOULBOUND_CATEGORY_KEY = SOULBOUND_CATEGORY_KEY
table.insert(DEFAULT_CATEGORY_ORDER, 3, SOULBOUND_CATEGORY_KEY)

local ARMOR_CLASS  = Enum and Enum.ItemClass and Enum.ItemClass.Armor
local WEAPON_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Weapon

-- main armor for teach character class
local ARMOR_TYPE_BY_CLASS = {
	WARRIOR     = 4, -- plate
	PALADIN     = 4, -- plate
	HUNTER      = 3, -- mail
	ROGUE       = 2, -- leather
	PRIEST      = 1, -- cloth
	DEATHKNIGHT = 4, -- plate
	SHAMAN      = 3, -- mail
	MAGE        = 1, -- cloth
	WARLOCK     = 1, -- cloth
	MONK        = 2, -- leather
	DRUID       = 2, -- leather
	DEMONHUNTER = 2, -- leather
	EVOKER      = 3, -- mail
}

local function CharacterMainArmorType()
	local _, class = UnitClass("player")
	return class and ARMOR_TYPE_BY_CLASS[class]
end

-- equip locations that have armor type restrictions
local ARMOR_TYPE_RESTRICTED_EQUIP_LOCS = {
	INVTYPE_HEAD     = true,
	INVTYPE_SHOULDER = true,
	INVTYPE_CHEST    = true,
	INVTYPE_ROBE     = true,
	INVTYPE_WAIST    = true,
	INVTYPE_LEGS     = true,
	INVTYPE_FEET     = true,
	INVTYPE_WRIST    = true,
	INVTYPE_HAND     = true,
}

local function IsUnusableSoulboundArmor(classID, subclassID, bound, equipLoc)
	if not bound or classID ~= ARMOR_CLASS then return false end
	if not ARMOR_TYPE_RESTRICTED_EQUIP_LOCS[equipLoc] then return false end
	if not (subclassID and subclassID >= 1 and subclassID <= 4) then return false end
	local mainArmorType = CharacterMainArmorType()
	return mainArmorType and subclassID ~= mainArmorType
end

-- provisional answers
local provisional = {}
local function Provisional(cache, key, value)
    cache[key] = value
    provisional[#provisional + 1] = { cache, key }
    return value
end

local function ForgetProvisional()
    for _, entry in ipairs(provisional) do entry[1][entry[2]] = nil end
    provisional = {}
end
ns.ForgetProvisional = ForgetProvisional

-- per-category sort settings

local expansionCache = {}
local function ItemExpansion(itemID)
    local known = expansionCache[itemID]
    if known ~= nil then return known end
    if not Item.GetItemInfo then return -1 end
    local expansionID = select(15, Item.GetItemInfo(itemID))
    -- Not cached by the client yet. Held at -1 for the rest of this sort, asked again on the next one.
    if expansionID == nil then return Provisional(expansionCache, itemID, -1) end
    expansionCache[itemID] = tonumber(expansionID) or -1
    return expansionCache[itemID]
end

local sellPriceCache = {}
local function ItemSellPrice(itemID)
    local known = sellPriceCache[itemID]
    if known ~= nil then return known end
    if not Item.GetItemInfo then return 0 end
    local sellPrice = select(11, Item.GetItemInfo(itemID))
    if sellPrice == nil then return Provisional(sellPriceCache, itemID, 0) end
    sellPriceCache[itemID] = tonumber(sellPrice) or 0
    return sellPriceCache[itemID]
end

local subclassNameCache = {}
local function ItemSubclassName(classID, subclassID)
    local key = classID .. ":" .. subclassID
    local known = subclassNameCache[key]
    if known ~= nil then return known end
    if not Item.GetItemSubClassInfo then return "" end
    local name = Item.GetItemSubClassInfo(classID, subclassID)
    if name == nil then return Provisional(subclassNameCache, key, "") end
    subclassNameCache[key] = name
    return name
end

local DISABLED_SORT_FIELD = "disabled"

local SORT_FIELD_ORDER = { DISABLED_SORT_FIELD, "type", "quality", "name", "ilvl", "value", "itemid", "expansion" }
local SORT_FIELD_LABEL = {
    disabled  = "Disabled",
    type      = "Item Type",
    quality   = "Item Quality",
    name      = "Item Name",
    ilvl      = "Item Level",
    value     = "Item Value",
    itemid    = "Item ID",
    expansion = "Expansion",
}
local SORT_FIELDS = {
    type      = { ascending = true,  get = function(it, m)
        return ItemSubclassName(m.classID, m.subclassID or 0):lower()
    end },
    quality   = { ascending = false, get = function(it, m) return it.quality or 0 end },
    name      = { ascending = true,  get = function(it, m) return (m.name or ""):lower() end },
    ilvl      = { ascending = false, get = function(it, m) return it.ilvl or 0 end },
    value     = { ascending = false, get = function(it, m) return ItemSellPrice(it.itemID) end },
    itemid    = { ascending = true,  get = function(it, m) return it.itemID or 0 end },
    expansion = { ascending = false, get = function(it, m) return ItemExpansion(it.itemID) end },
}

function ns.SortFieldOrder() return SORT_FIELD_ORDER end
function ns.SortFieldLabel(field) return SORT_FIELD_LABEL[field] or field end

local DEFAULT_CATEGORY_SETTINGS = {
    enabled   = true,
    reverse   = false,
    primary   = "type",
    secondary = "quality",
    tertiary  = "ilvl",
}

-- per-category sort order overrides for a default profile
local BUILTIN_CATEGORY_SETTINGS = {
    [JUNK_CATEGORY_KEY] = { primary = "value", secondary = DISABLED_SORT_FIELD, tertiary = DISABLED_SORT_FIELD, includeUnusableSoulbound = false, includeLowLevel = false, lowLevelThreshold = 50 },
    [HEARTHSTONE_CATEGORY_KEY] = {
        primary = "itemid", secondary = DISABLED_SORT_FIELD, tertiary = DISABLED_SORT_FIELD,
    },
    Consumable = { primary = "expansion", secondary = "type", tertiary = "quality" },
}

-- per-category overrides for the bank for a default profile
local BUILTIN_BANK_CATEGORY_SETTINGS = {
    [SOULBOUND_CATEGORY_KEY] = { primary = "expansion", secondary = "type", tertiary = "ilvl" },
}


-- =============== --
-- Saved variables --
-- =============== --

local defaults = {
    profile = {
        -- behaviour
        stackOrder           = "largest", -- largest = biggest stack of an item first, smallest = reverse
        verbose              = false,     -- print messages in chat
        debugMessages        = false,     -- print debugging messages

        -- bags
        bagOrder             = "rtl",     -- rtl = last bag first, ltr = backpack first
        slotOrder            = "rtl",     -- rtl = highest slot downwards, ltr = slot 1 upwards
        fillSpecialBags      = true,      -- move fitting items from the generic bags into the reagent/profession bags
        reagentBag           = true,      -- also sort the reagent bag (as its own container)
        honorBagCleanupFlag  = true,      -- ignore bags that are marked "ignore for cleanup"

        -- bank
        bankTabOrder         = "ltr",     -- ltr = tab 1 first, rtl = last available tab first
        bankSlotOrder        = "ltr",     -- ltr = slot 1 upwards, highest slow downwards
        honorBankTabSettings = true,      -- try to honor Blizzard bank tab settings
        bankCategoryGap      = false,     -- try leave one slot between categories (if space permits)

        -- bag categories and order
        categoryOrder        = {},
        categorySettings     = {},

        -- bank categories and order
        bankCategoryOrder    = {},
        bankCategorySettings = {},

        -- custom categories
        customCategories     = {},
        nextCustomCategoryID = 0,
    }
}

local function DB()
    return BagSort.db.profile
end

local function Debug(msg, ...)
    if DB().verbose then BagSort:Printf(msg, ...) end
end

local function DebugDetail(msg, ...)
    if DB().debugMessages then BagSort:Printf(msg, ...) end
end


-- ================ --
-- Item information --
-- ================ --

-- turns the profile category settings into a usable order
local function NormalizeOrder(dbKey)
    local saved = DB()[dbKey]
    if type(saved) ~= "table" then saved = {} end
    local custom = DB().customCategories or {}

    local seen, order = {}, {}
    for _, key in ipairs(saved) do
        local known = CATEGORY_CLASS[key] or key == DEFAULT_CATEGORY_KEY
            or key == JUNK_CATEGORY_KEY or key == EMPTY_CATEGORY_KEY
            or key == HEARTHSTONE_CATEGORY_KEY or key == GEARSET_CATEGORY_KEY
            or key == SOULBOUND_CATEGORY_KEY or custom[key] ~= nil
        if known and not seen[key] then
            seen[key] = true
            order[#order + 1] = key
        end
    end
    for _, key in ipairs(DEFAULT_CATEGORY_ORDER) do
        if not seen[key] then
            seen[key] = true
            order[#order + 1] = key
        end
    end

    -- custom category deleted from the profile is dropped
    local newCustom = {}
    for key, def in pairs(custom) do
        if not seen[key] then newCustom[#newCustom + 1] = { key = key, seq = def.seq or 0 } end
    end
    table.sort(newCustom, function(a, b) return a.seq < b.seq end)
    for _, entry in ipairs(newCustom) do
        seen[entry.key] = true
        order[#order + 1] = entry.key
    end

    return order
end

-- category setttings
local function CategorySettingsFor(dbKey, key)
    local saved = DB()[dbKey]
    local override = type(saved) == "table" and saved[key] or nil
    local builtin = (dbKey == "bankCategorySettings" and BUILTIN_BANK_CATEGORY_SETTINGS[key]) or BUILTIN_CATEGORY_SETTINGS[key]
    local settings = {}
    for field, value in pairs(DEFAULT_CATEGORY_SETTINGS) do
        settings[field] = value
    end
    if builtin then
        for field, value in pairs(builtin) do settings[field] = value end
    end
    if override then
        -- An override can name a field DEFAULT_CATEGORY_SETTINGS has no entry for - includeUnusableSoulbound,
        -- includeLowLevel, lowLevelThreshold only ever reach the profile through Junk's own builtin, never
        -- through the shared defaults, so a loop that only walked DEFAULT_CATEGORY_SETTINGS silently dropped
        -- every override for them: the value round-tripped to disk but never back into settings.
        for field in pairs(settings) do
            if override[field] ~= nil then settings[field] = override[field] end
        end
    end
    return settings
end

function ns.GetCategorySettings(key)
    return CategorySettingsFor("categorySettings", key)
end

function ns.BankGetCategorySettings(key)
    return CategorySettingsFor("bankCategorySettings", key)
end

-- make bag and bank get each their own copy of the current state
local Scopes = {
    bag  = {},
    bank = {},
}

-- gear set slots
local gearSetSlots = {}

-- asking a gear set for its locations can crash a Mac client when the item is invalid or the client has no local data
local function MacCrashRisk(EquipmentSet, setID)
    if not (IsMacClient and IsMacClient()) then return false end
    if not (EquipmentSet.GetItemIDs and Item.GetItemInfoInstant) then return true end
    for _, itemID in pairs(EquipmentSet.GetItemIDs(setID) or {}) do
        if itemID and itemID ~= 0 and not Item.GetItemInfoInstant(itemID) then return true end
    end
    return false
end

-- bag/slot for one packed location out of C_EquipmentSet.GetItemLocations - nil for anything that is not in a bag
local function GearSetBagSlot(location)
    if type(location) ~= "number" or location <= 1 then return nil end
    if EquipmentManager_GetLocationData then
        local data = EquipmentManager_GetLocationData(location)
        if data and data.isBags then return data.bag, data.slot end
    elseif EquipmentManager_UnpackLocation then
        local _, _, bags, _, slot, bag = EquipmentManager_UnpackLocation(location)
        if bags then return bag, slot end
    end
    return nil
end

local function RebuildGearSetSlots()
    gearSetSlots = {}
    local EquipmentSet = C_EquipmentSet
    if not (EquipmentSet and EquipmentSet.GetEquipmentSetIDs and EquipmentSet.GetItemLocations) then return end
    for _, setID in ipairs(EquipmentSet.GetEquipmentSetIDs() or {}) do
        if not MacCrashRisk(EquipmentSet, setID) then
            for _, location in pairs(EquipmentSet.GetItemLocations(setID) or {}) do
                local bag, slot = GearSetBagSlot(location)
                if bag and slot then gearSetSlots[bag * 1000 + slot] = true end
            end
        end
    end
end

-- fills one Scopes[scope] table from the profile under orderKey/settingsKey.
local function RebuildScope(scope, orderKey, settingsKey)
    local S = Scopes[scope]
    local classRank, classSettings = {}, {}
    local order = NormalizeOrder(orderKey)

    local rankOf = {}
    for i, key in ipairs(order) do rankOf[key] = i end
    local defaultRank     = rankOf[DEFAULT_CATEGORY_KEY]
    local defaultSettings = CategorySettingsFor(settingsKey, DEFAULT_CATEGORY_KEY)

    -- custom categories
    local customCategories = {}
    for key, def in pairs(DB().customCategories or {}) do
        local settings = CategorySettingsFor(settingsKey, key)
        if settings.enabled and rankOf[key] then
            local posOf = {}
            for i, itemID in ipairs(def.items) do posOf[itemID] = i end
            customCategories[#customCategories + 1] =
                { rank = rankOf[key], settings = settings, posOf = posOf, seq = def.seq or 0 }
        end
    end
    table.sort(customCategories, function(a, b) return a.seq < b.seq end)
    S.customCategories = customCategories

    for key, classID in pairs(CATEGORY_CLASS) do
        local settings = CategorySettingsFor(settingsKey, key)
        if settings.enabled then
            classRank[classID] = rankOf[key]
            classSettings[classID] = settings
        else
            classRank[classID] = defaultRank
            classSettings[classID] = defaultSettings
        end
    end
    S.classRank, S.classSettings = classRank, classSettings
    S.defaultRank, S.defaultSettings = defaultRank, defaultSettings

    local junk = CategorySettingsFor(settingsKey, JUNK_CATEGORY_KEY)
    S.junkEnabled = junk.enabled and rankOf[JUNK_CATEGORY_KEY] ~= nil
    S.junkRank, S.junkSettings = rankOf[JUNK_CATEGORY_KEY], junk

    local hearthstone = CategorySettingsFor(settingsKey, HEARTHSTONE_CATEGORY_KEY)
    S.hearthstoneEnabled = hearthstone.enabled and rankOf[HEARTHSTONE_CATEGORY_KEY] ~= nil
    S.hearthstoneRank, S.hearthstoneSettings = rankOf[HEARTHSTONE_CATEGORY_KEY], hearthstone

    local gearSet = CategorySettingsFor(settingsKey, GEARSET_CATEGORY_KEY)
    S.gearSetEnabled = gearSet.enabled and rankOf[GEARSET_CATEGORY_KEY] ~= nil
    S.gearSetRank, S.gearSetSettings = rankOf[GEARSET_CATEGORY_KEY], gearSet

    local soulbound = CategorySettingsFor(settingsKey, SOULBOUND_CATEGORY_KEY)
    S.soulboundEnabled = soulbound.enabled and rankOf[SOULBOUND_CATEGORY_KEY] ~= nil
    S.soulboundRank, S.soulboundSettings = rankOf[SOULBOUND_CATEGORY_KEY], soulbound

    -- where free slots go
    local empty = CategorySettingsFor(settingsKey, EMPTY_CATEGORY_KEY)
    S.emptyRank = empty.enabled and rankOf[EMPTY_CATEGORY_KEY] or nil
end

local function RebuildClassRank()
    RebuildScope("bag", "categoryOrder", "categorySettings")
    RebuildScope("bank", "bankCategoryOrder", "bankCategorySettings")
end

-- name the client shows for a default class
local categoryNames = {}

-- custom category names
local SENTINEL_NAME = {
    [DEFAULT_CATEGORY_KEY]      = "Default",
    [JUNK_CATEGORY_KEY]         = "Junk",
    [EMPTY_CATEGORY_KEY]        = "Empty Slots",
    [HEARTHSTONE_CATEGORY_KEY]  = "Hearthstone",
    [GEARSET_CATEGORY_KEY]      = "Gear Set",
    [SOULBOUND_CATEGORY_KEY]    = "Soulbound Gear",
}

local function CategoryName(key)
    if SENTINEL_NAME[key] then return SENTINEL_NAME[key] end
    local custom = DB().customCategories and DB().customCategories[key]
    if custom then return custom.name end
    local name = categoryNames[key]
    if not name then
        local classID = CATEGORY_CLASS[key]
        if classID and Item.GetItemClassInfo then
            name = Item.GetItemClassInfo(classID)
        end
        name = name or key
        categoryNames[key] = name
    end
    return name
end
ns.CategoryName = CategoryName

-- option panel methods, as the option panel does not use the profile itself
function ns.CategoryOrder()
    return NormalizeOrder("categoryOrder")
end

function ns.BankCategoryOrder()
    return NormalizeOrder("bankCategoryOrder")
end

function ns.DefaultCategoryOrder()
    local copy = {}
    for i, key in ipairs(DEFAULT_CATEGORY_ORDER) do copy[i] = key end
    return copy
end

local band = bit and bit.band

local CONTAINER_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Container
local QUIVER_CLASS    = Enum and Enum.ItemClass and Enum.ItemClass.Quiver

local metaCache = {}

-- items whose class are not cached on the client
local UNKNOWN_CLASS = 99

local function ItemMeta(itemID, name)
    local m = metaCache[itemID]
    if not m then
        m = {}
        metaCache[itemID] = m
    end
    if not m.classKnown then
        local _, _, _, equipLoc, _, classID, subclassID = Item.GetItemInfoInstant(itemID)
        if classID then
            m.classID, m.subclassID, m.equipLoc, m.classKnown = classID, subclassID or 0, equipLoc or "", true
        else
            m.classID, m.subclassID, m.equipLoc = UNKNOWN_CLASS, 0, ""
            Provisional(m, "classKnown", true)
        end
    end
    if not m.nameKnown then
        m.name = name or (Item.GetItemNameByID and Item.GetItemNameByID(itemID))
        if m.name ~= nil then m.nameKnown = true else Provisional(m, "nameKnown", true) end
    end
    if not m.familyKnown and Item.GetItemFamily then
        m.family = tonumber(Item.GetItemFamily(itemID))
        if m.family ~= nil then m.familyKnown = true else Provisional(m, "familyKnown", true) end
    end
    return m
end

-- reagent cache and items the client refused to move into a bag
local reagentCache = {}
local refused = {}

local function IsCraftingReagent(itemID)
    local known = reagentCache[itemID]
    if known ~= nil then return known end
    if not Item.GetItemInfo then return false end
    local isReagent = select(17, Item.GetItemInfo(itemID))
    if isReagent == nil then return Provisional(reagentCache, itemID, false) end
    reagentCache[itemID] = isReagent and true or false
    return reagentCache[itemID]
end

local function RefusedKey(itemID, bag, family)
    return itemID .. ":" .. bag .. ":" .. (family or 0)
end

-- check if an item fits into a specific bag
local function FitsBag(it, bag, family)
    family = family or 0
    if bag ~= REAGENT_BAG and family == 0 then return false end
    if refused[RefusedKey(it.itemID, bag, family)] then return false end
    local meta = ItemMeta(it.itemID, it.name)
    -- A bag carries a family of its own but never goes inside another bag.
    if meta.classID == CONTAINER_CLASS or meta.classID == QUIVER_CLASS then return false end
    if band and family ~= 0 and meta.family and meta.family ~= 0
    and band(meta.family, family) ~= 0 then
        return true
    end
    if bag == REAGENT_BAG then return IsCraftingReagent(it.itemID) end
    return false
end

local function StackSignature(itemID, ilvl, quality, bound, name)
    local sig = itemID .. ":" .. ilvl .. ":" .. quality
    if gearSet then sig = sig .. ":g" end
    if not bound then return sig end
    local meta = ItemMeta(itemID, name)
    if meta.classID == ARMOR_CLASS or meta.classID == WEAPON_CLASS then return sig .. ":b" end
    return sig
end

local maxStackCache = {}

local function MaxStack(bag, slot, itemID)
    local known = maxStackCache[itemID]
    if known ~= nil then return known end
    if ItemLocation and Item.GetItemMaxStackSize then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and Item.DoesItemExist and Item.DoesItemExist(loc) then
            local ms = tonumber((Item.GetItemMaxStackSize(loc)))
            if ms and ms > 0 then
                maxStackCache[itemID] = ms
                return ms
            end
        end
    end
    if Item.GetItemMaxStackSizeByID then
        local ms = tonumber((Item.GetItemMaxStackSizeByID(itemID)))
        if ms and ms > 0 then
            maxStackCache[itemID] = ms
            return ms
        end
    end
    return Provisional(maxStackCache, itemID, 1)
end

local function ItemLevel(link)
    if not link or not Item.GetDetailedItemLevelInfo then return 0 end
    return tonumber((Item.GetDetailedItemLevelInfo(link))) or 0
end

-- what goes where
local EQUIP_LOC_SLOTS = {
    INVTYPE_HEAD           = { 1 },
    INVTYPE_NECK           = { 2 },
    INVTYPE_SHOULDER       = { 3 },
    INVTYPE_CLOAK          = { 15 },
    INVTYPE_CHEST          = { 5 },
    INVTYPE_ROBE           = { 5 },
    INVTYPE_WAIST          = { 6 },
    INVTYPE_LEGS           = { 7 },
    INVTYPE_FEET           = { 8 },
    INVTYPE_WRIST          = { 9 },
    INVTYPE_HAND           = { 10 },
    INVTYPE_FINGER         = { 11, 12 },
    INVTYPE_TRINKET        = { 13, 14 },
    INVTYPE_WEAPON         = { 16, 17 },
    INVTYPE_2HWEAPON       = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND  = { 17 },
    INVTYPE_SHIELD         = { 17 },
    INVTYPE_HOLDABLE       = { 17 },
    INVTYPE_RANGED         = { 16 },
    INVTYPE_RANGEDRIGHT    = { 16 },
    INVTYPE_THROWN         = { 16 },
    INVTYPE_RELIC          = { 18 },
}

local function EquippedItemLevelForEquipLoc(equipLoc)
    local slots = EQUIP_LOC_SLOTS[equipLoc]
    if not slots or not GetInventoryItemLink then
        DebugDetail("ilvl: equipLoc %s has no equip slot(s) - no comparison", tostring(equipLoc))
        return nil
    end
    local lowest
    for _, slotID in ipairs(slots) do
        local link = GetInventoryItemLink("player", slotID)
        if link then
            local ilvl = ItemLevel(link)
            DebugDetail("ilvl: slot %d worn %s - ilvl %d", slotID, link, ilvl)
            if ilvl and ilvl > 0 and (not lowest or ilvl < lowest) then
                lowest = ilvl
            end
        else
            DebugDetail("ilvl: slot %d is empty", slotID)
        end
    end
    DebugDetail("ilvl: equipLoc %s - lowest worn ilvl %s", tostring(equipLoc), tostring(lowest))
    return lowest
end

local function IsLowLevelSoulbound(itemID, ilvl, bound, gearSet, threshold, equipLoc)
    if not bound then
        DebugDetail("ilvl: item %d is not bound - skipped", itemID)
        return false
    end
    if not ilvl or ilvl == 0 then
        DebugDetail("ilvl: item %d has no item level - skipped", itemID)
        return false
    end
    if gearSet then
        DebugDetail("ilvl: item %d is in a gear set - skipped", itemID)
        return false
    end
    local equipped = EquippedItemLevelForEquipLoc(equipLoc)
    if not equipped then
        DebugDetail("ilvl: item %d (ilvl %d) - nothing worn to compare against", itemID, ilvl)
        return false
    end
    local result = ilvl < equipped - threshold
    DebugDetail("ilvl: item %d (ilvl %d) vs worn %d, threshold %d, cutoff %d -> %s", itemID, ilvl, equipped,
        threshold, equipped - threshold, result and "JUNK" or "keep")
    return result
end

local function FieldValue(fieldKey, it, meta)
    local field = SORT_FIELDS[fieldKey]
    if not field then return nil, false end
    return field.get(it, meta), field.ascending
end

local function EffectiveRank(itemID, classID, quality, bound, gearSet, subclassID, ilvl, equipLoc, S)
    DebugDetail("ilvl: item %d, class %s:%s, quality %d, bound %s, ilvl %d - junkEnabled %s, includeLowLevel %s, threshold %s",
        itemID, tostring(classID), tostring(subclassID), quality or -1, tostring(bound), ilvl or -1,
        tostring(S.junkEnabled), tostring(S.junkEnabled and S.junkSettings.includeLowLevel),
        tostring(S.junkEnabled and S.junkSettings.lowLevelThreshold))

    -- player's own custom categories win over every other category
    for _, custom in ipairs(S.customCategories) do
        local pos = custom.posOf[itemID]
        if pos then return custom.rank, custom.settings, pos end
    end

    if S.hearthstoneEnabled and HEARTHSTONE_ITEM_IDS[itemID] then return S.hearthstoneRank, S.hearthstoneSettings end
    if S.gearSetEnabled and gearSet then return S.gearSetRank, S.gearSetSettings end
    if S.junkEnabled and S.junkSettings.includeUnusableSoulbound and IsUnusableSoulboundArmor(classID, subclassID, bound, equipLoc) then
        return S.junkRank, S.junkSettings
    end
    if S.junkEnabled and S.junkSettings.includeLowLevel and IsLowLevelSoulbound(itemID, ilvl, bound, gearSet, S.junkSettings.lowLevelThreshold, equipLoc) then
        return S.junkRank, S.junkSettings
    end
    if S.soulboundEnabled and bound and (classID == ARMOR_CLASS or classID == WEAPON_CLASS) then
        return S.soulboundRank, S.soulboundSettings
    end
    if S.junkEnabled and quality == 0 then return S.junkRank, S.junkSettings end
    return S.classRank[classID] or S.defaultRank, S.classSettings[classID] or S.defaultSettings
end

local function SortKey(it, S)
    local meta = ItemMeta(it.itemID, it.name)
    local rank, settings, customPos = EffectiveRank(it.itemID, meta.classID, it.quality, it.bound, it.gearSet, meta.subclassID, it.ilvl, meta.equipLoc, S)
    if customPos then
        return { it = it, rank = rank, v1 = customPos, a1 = not settings.reverse }
    end
    local reverse = settings.reverse and true or false
    local v1, asc1 = FieldValue(settings.primary,   it, meta)
    local v2, asc2 = FieldValue(settings.secondary, it, meta)
    local v3, asc3 = FieldValue(settings.tertiary,  it, meta)
    return {
        it = it, rank = rank,
        v1 = v1, v2 = v2, v3 = v3,
        a1 = asc1 ~= reverse, a2 = asc2 ~= reverse, a3 = asc3 ~= reverse,
    }
end

local function SortKeys(items, S)
    local keyOf = {}
    for _, it in ipairs(items) do keyOf[it] = SortKey(it, S) end
    return keyOf
end

local function KeyLess(ka, kb, stackOrder)
    if ka.rank ~= kb.rank then return ka.rank < kb.rank end
    if ka.v1 ~= kb.v1 then return (ka.v1 < kb.v1) == ka.a1 end
    if ka.v2 ~= kb.v2 then return (ka.v2 < kb.v2) == ka.a2 end
    if ka.v3 ~= kb.v3 then return (ka.v3 < kb.v3) == ka.a3 end

    local a, b = ka.it, kb.it
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    if a.count ~= b.count then
        if stackOrder == "smallest" then return a.count < b.count end
        return a.count > b.count
    end
    return a.index < b.index
end


-- ========== --
-- Containers --
-- ========== --

local function BagFamily(bag)
    local _, family = Container.GetContainerNumFreeSlots(bag)
    return family or 0
end

local function BuildGroups()
    local db = DB()
    local bags = {}
    for bag = BACKPACK, LastNormalBag() do
        if bag ~= REAGENT_BAG and not (db.honorBagCleanupFlag and BagCleanupIgnored(bag)) then
            bags[#bags + 1] = bag
        end
    end
    if db.bagOrder == "rtl" then
        for i = 1, math.floor(#bags / 2) do
            bags[i], bags[#bags - i + 1] = bags[#bags - i + 1], bags[i]
        end
    end

    local generic, special = { family = 0, generic = true }, {}
    for _, bag in ipairs(bags) do
        if Container.GetContainerNumSlots(bag) > 0 then
            local family = BagFamily(bag)
            if family == 0 then
                generic[#generic + 1] = bag
            else
                special[#special + 1] = { bag, family = family, restricted = true }
            end
        end
    end

    local groups = {}
    for _, g in ipairs(special) do groups[#groups + 1] = g end
    if db.reagentBag and Container.GetContainerNumSlots(REAGENT_BAG) > 0
    and not (db.honorBagCleanupFlag and BagCleanupIgnored(REAGENT_BAG)) then
        -- The reagent bag reports no family, it is restricted all the same.
        groups[#groups + 1] = { REAGENT_BAG, family = BagFamily(REAGENT_BAG), restricted = true }
    end
    if #generic > 0 then groups[#groups + 1] = generic end
    return groups
end


-- ==== --
-- Bank --
-- ==== --

local Bank = C_Bank
local BankType = Enum and Enum.BankType

local function BankTabBagIDs(prefix, count)
    local ids = {}
    for i = 1, count do
        local bagID = Enum and Enum.BagIndex and Enum.BagIndex[prefix .. i]
        if bagID then ids[#ids + 1] = bagID end
    end
    return ids
end

local CHARACTER_BANK_TABS = BankTabBagIDs("CharacterBankTab_", 6)
local ACCOUNT_BANK_TABS   = BankTabBagIDs("AccountBankTab_", 5)

local function BankTabBags(bankType)
    if BankType and bankType == BankType.Account then return ACCOUNT_BANK_TABS end
    return CHARACTER_BANK_TABS
end

local FALLBACK_DEPOSIT_FLAG_VALUE = {
    DisableAutoSort      = 0x001, -- "Ignore this tab"
    ClassEquipment       = 0x002,
    ClassConsumables     = 0x004,
    ClassProfessionGoods = 0x008,
    ClassJunk            = 0x010,
    ClassQuestItems      = 0x020,
    ExcludeJunkSell      = 0x040, -- not a placement category, left out of ItemCategoryBits
    ClassReagents        = 0x080,
    ExpansionCurrent     = 0x100,
    ExpansionLegacy      = 0x200,
}

local BANK_DEPOSIT_FLAG_VALUE = {}  -- name -> bit value
local BANK_DEPOSIT_FLAG_ORDER = {}  -- names, bit value ascending
do
    local flags = (Enum and Enum.BankTabDepositFlag) or {}
    for key, value in pairs(flags) do
        if type(value) == "number" then
            BANK_DEPOSIT_FLAG_VALUE[key] = value
        end
    end
    if not next(BANK_DEPOSIT_FLAG_VALUE) then
        for key, value in pairs(FALLBACK_DEPOSIT_FLAG_VALUE) do
            BANK_DEPOSIT_FLAG_VALUE[key] = value
        end
    end
    for key in pairs(BANK_DEPOSIT_FLAG_VALUE) do
        BANK_DEPOSIT_FLAG_ORDER[#BANK_DEPOSIT_FLAG_ORDER + 1] = key
    end
    table.sort(BANK_DEPOSIT_FLAG_ORDER, function(a, b)
        return BANK_DEPOSIT_FLAG_VALUE[a] < BANK_DEPOSIT_FLAG_VALUE[b]
    end)
end

local function TabIsIgnored(depositFlags)
    local bit_ = BANK_DEPOSIT_FLAG_VALUE.DisableAutoSort
    return band and bit_ and depositFlags and band(depositFlags, bit_) ~= 0 or false
end

local bor  = bit and bit.bor
local bxor = bit and bit.bxor

local CONSUMABLE_CLASS   = CATEGORY_CLASS.Consumable
local TRADESKILL_CLASS   = CATEGORY_CLASS.Tradegoods
local QUEST_CLASS        = CATEGORY_CLASS.Questitem
local REAGENT_CLASS      = CATEGORY_CLASS.Reagent

local currentExpansion
local function CurrentExpansion()
    if currentExpansion == nil then
        local max
        for key, value in pairs(_G) do
            if type(value) == "number" and type(key) == "string"
            and key:match("^LE_EXPANSION_[%u_]+$") and not key:match("^LE_EXPANSION_LEVEL_") then
                if not max or value > max then max = value end
            end
        end
        currentExpansion = max or false
    end
    return currentExpansion or nil
end

local function ItemCategoryBits(it, meta)
    if not (band and bor) then return 0 end
    local F = BANK_DEPOSIT_FLAG_VALUE
    local bits = 0
    if F.ClassEquipment and (meta.classID == ARMOR_CLASS or meta.classID == WEAPON_CLASS) then
        bits = bor(bits, F.ClassEquipment)
    end
    if F.ClassConsumables and meta.classID == CONSUMABLE_CLASS then
        bits = bor(bits, F.ClassConsumables)
    end
    if F.ClassProfessionGoods and meta.classID == TRADESKILL_CLASS then
        bits = bor(bits, F.ClassProfessionGoods)
    end
    if F.ClassJunk and (it.quality or 1) == 0 then
        bits = bor(bits, F.ClassJunk)
    end
    if F.ClassQuestItems and meta.classID == QUEST_CLASS then
        bits = bor(bits, F.ClassQuestItems)
    end
    if F.ClassReagents and (meta.classID == REAGENT_CLASS or IsCraftingReagent(it.itemID)) then
        bits = bor(bits, F.ClassReagents)
    end
    local current = (F.ExpansionCurrent or F.ExpansionLegacy) and CurrentExpansion()
    if current then
        local expansion = ItemExpansion(it.itemID)
        if expansion >= 0 then
            if expansion == current then
                if F.ExpansionCurrent then bits = bor(bits, F.ExpansionCurrent) end
            elseif F.ExpansionLegacy then
                bits = bor(bits, F.ExpansionLegacy)
            end
        end
    end
    return bits
end

local EXPANSION_MASK = bor and bor(BANK_DEPOSIT_FLAG_VALUE.ExpansionCurrent or 0, BANK_DEPOSIT_FLAG_VALUE.ExpansionLegacy or 0) or 0

local function FitsBankTab(it, meta, depositFlags)
    if not (band and bxor and depositFlags and depositFlags ~= 0) then return false end
    local bits = ItemCategoryBits(it, meta)

    local expansionFlags = band(depositFlags, EXPANSION_MASK)
    if expansionFlags ~= 0 and band(bits, expansionFlags) == 0 then return false end

    local classFlags = bxor(depositFlags, expansionFlags)
    if classFlags ~= 0 and band(bits, classFlags) == 0 then return false end

    return expansionFlags ~= 0 or classFlags ~= 0
end

local NON_PLACEMENT_DEPOSIT_FLAGS = { DisableAutoSort = true, ExcludeJunkSell = true }

local function DepositFlagSpecificity(depositFlags)
    if not (band and depositFlags and depositFlags ~= 0) then return 0 end
    local count = 0
    for _, name in ipairs(BANK_DEPOSIT_FLAG_ORDER) do
        if not NON_PLACEMENT_DEPOSIT_FLAGS[name] and band(depositFlags, BANK_DEPOSIT_FLAG_VALUE[name]) ~= 0 then
            count = count + 1
        end
    end
    return count
end
ns.DepositFlagSpecificity = DepositFlagSpecificity

local NON_PLACEMENT_FLAG_MASK = BANK_DEPOSIT_FLAG_VALUE.ExcludeJunkSell or 0

local function PlacementFlags(depositFlags)
    if not (band and bxor) or NON_PLACEMENT_FLAG_MASK == 0 then return depositFlags end
    return bxor(depositFlags, band(depositFlags, NON_PLACEMENT_FLAG_MASK))
end

local function FetchBankTabs(bankType, skipBagOrder)
    local tabBags = BankTabBags(bankType)
    local tabs = {}
    local data = Bank and Bank.FetchPurchasedBankTabData and Bank.FetchPurchasedBankTabData(bankType)
    if type(data) == "table" then
        for i, tabData in ipairs(data) do
            local bagID = tabBags[i]
            if bagID and Container.GetContainerNumSlots(bagID) > 0 then
                tabs[#tabs + 1] =
                    { bagID = bagID, depositFlags = PlacementFlags(tonumber(tabData.depositFlags) or 0) }
            end
        end
    else
        for _, bagID in ipairs(tabBags) do
            if Container.GetContainerNumSlots(bagID) > 0 then
                tabs[#tabs + 1] = { bagID = bagID, depositFlags = false }
            end
        end
    end

    if not skipBagOrder and DB().bankTabOrder == "rtl" then
        for i = 1, math.floor(#tabs / 2) do
            tabs[i], tabs[#tabs - i + 1] = tabs[#tabs - i + 1], tabs[i]
        end
    end

    return tabs
end

local function BuildBankGroups(bankType)
    local db = DB()
    local tabs = FetchBankTabs(bankType)

    if not db.honorBankTabSettings then
        local one = {}
        for _, t in ipairs(tabs) do one[#one + 1] = t.bagID end
        return #one > 0 and { one } or {}
    end

    local groups = {}
    local order, byFlags = {}, {}
    for _, t in ipairs(tabs) do
        if t.depositFlags == false then
            groups[#groups + 1] = { t.bagID }
        elseif not TabIsIgnored(t.depositFlags) then
            local list = byFlags[t.depositFlags]
            if not list then
                list = {}
                byFlags[t.depositFlags] = list
                order[#order + 1] = t.depositFlags
            end
            list[#list + 1] = t.bagID
        end
    end
    for _, flags in ipairs(order) do groups[#groups + 1] = byFlags[flags] end
    return groups
end

-- try to read which bank panel is actually on screen
local function BankPanelShown(frame)
    return frame ~= nil and frame.IsShown ~= nil and frame:IsShown() and true or false
end

local function BankUsable(bt)
    return Bank and Bank.CanUseBank and bt ~= nil and Bank.CanUseBank(bt) and true or false
end

local function SelectedBankTabBag(bankType, value)
    local tabBagID = tonumber(value)
    if not tabBagID then return nil end
    for _, bagID in ipairs(BankTabBags(bankType)) do
        if bagID == tabBagID then return tabBagID end
    end
    return nil
end

local function ActiveBankPanel()
    local panel = _G.BankPanel
    if not panel then
        local frame = _G.BankFrame
        panel = frame and frame.BankPanel
    end
    if not BankPanelShown(panel) then return nil end

    local bankType
    if panel.GetActiveBankType then
        -- pcall because this is Blizzard Lua on a frame another addon may have replaced or half-initialized -
        -- unlike the C functions elsewhere in this file, its existence is no promise that calling it is safe.
        local ok, value = pcall(panel.GetActiveBankType, panel)
        if ok then bankType = value end
    end
    if bankType == nil then bankType = panel.bankType end
    if bankType == nil then return nil end

    return bankType, SelectedBankTabBag(bankType, panel.selectedTabID)
end

-- ElvUI draws its own bank and hides Blizzard's, so the BankPanel probe above cannot see it
local function ActiveElvUIBank()
    local frame = _G.ElvUI_BankContainerFrame
    if not BankPanelShown(frame) then return nil end

    local bankType = frame.bankType
    if bankType == nil then return nil end

    local engine = _G.ElvUI
    local E = type(engine) == "table" and engine[1]
    local bags = type(E) == "table" and E.Bags
    if type(bags) ~= "table" then return bankType end   -- window is ElvUI's, but which tab cannot be told

    -- combined view
    local db = bags.db
    local combinedKey = (BankType and bankType == BankType.Account) and "warbandCombined" or "bankCombined"
    if type(db) == "table" and db[combinedKey] then return bankType end

    return bankType, SelectedBankTabBag(bankType, bags.BankTab)
end

-- the bag id of the single tab the bank window is showing, when it could be read. nil means sort
-- the whole bank, which is what a UI drawing every tab at once (Baganator's combined view) wants anyway.
local function DetectBankType()
    local accountUsable   = BankUsable(BankType and BankType.Account)
    local characterUsable = BankUsable(BankType and BankType.Character)
    if not (accountUsable or characterUsable) then return nil end

    local elvType, elvTab = ActiveElvUIBank()
    if elvType ~= nil then return elvType, false, elvTab end

    local panelType, panelTab = ActiveBankPanel()
    if panelType ~= nil then return panelType, false, panelTab end

    if BankPanelShown(_G.AccountBankPanel) then return BankType.Account end
    if BankPanelShown(_G.CharacterBankPanel) then return BankType.Character end

    if accountUsable and not characterUsable then return BankType.Account end
    if characterUsable and not accountUsable then return BankType.Character end
    return nil, true
end

local function GuildBankOpen()
    if BankType and BankType.Guild ~= nil then return BankUsable(BankType.Guild) end
    return BankPanelShown(_G.GuildBankFrame)
end

-- every bag oid that is a bank tab
local BANK_TAB_BAG = {}
for _, bagID in ipairs(CHARACTER_BANK_TABS) do BANK_TAB_BAG[bagID] = true end
for _, bagID in ipairs(ACCOUNT_BANK_TABS)   do BANK_TAB_BAG[bagID] = true end

local bagPositions = {}
local function BagPositions(bag, slotOrder)
    local slots = Container.GetContainerNumSlots(bag)
    local cached = bagPositions[bag]
    if cached and cached.slots == slots and cached.order == slotOrder then return cached.list end

    local list = {}
    if slotOrder == "rtl" then
        for slot = slots, 1, -1 do list[#list + 1] = { bag = bag, slot = slot } end
    else
        for slot = 1, slots do list[#list + 1] = { bag = bag, slot = slot } end
    end
    bagPositions[bag] = { list = list, slots = slots, order = slotOrder }
    return list
end

-- flatten a group into a single ordered list of slots
local function Positions(group)
    local db, positions = DB(), {}
    local slotOrder = BANK_TAB_BAG[group[1]] and db.bankSlotOrder or db.slotOrder
    for _, bag in ipairs(group) do
        for _, p in ipairs(BagPositions(bag, slotOrder)) do positions[#positions + 1] = p end
    end
    return positions
end

-- virtual state
local virtualState

local function VirtualSnapshot(bag, slot)
    local bagState = virtualState[bag]
    return bagState and bagState[slot]
end

local function VirtualSet(bag, slot, entry)
    local bagState = virtualState[bag]
    if not bagState then bagState = {}; virtualState[bag] = bagState end
    bagState[slot] = entry
end

local function Scan(positions)
    local items, locked = {}, false
    if not virtualState then RebuildGearSetSlots() end
    for i = 1, #positions do
        local p = positions[i]
        if virtualState then
            local snap = VirtualSnapshot(p.bag, p.slot)
            if snap then
                items[#items + 1] = {
                    index = i, bag = p.bag, slot = p.slot,
                    itemID = snap.itemID, name = snap.name, count = snap.count, quality = snap.quality,
                    ilvl = snap.ilvl, bound = snap.bound, gearSet = snap.gearSet,
                    maxStack = snap.maxStack, sig = snap.sig,
                }
            end
        else
            local info = Container.GetContainerItemInfo(p.bag, p.slot)
            -- tonumber() scrubs values that could be secret in 12.0
            -- everything below does arithmetic or comparisons on them
            local itemID = info and tonumber(info.itemID)
            if itemID then
                if info.isLocked then locked = true end
                local count = tonumber(info.stackCount) or 1
                local ilvl  = ItemLevel(info.hyperlink)
                local quality = tonumber(info.quality) or 1
                local bound = info.isBound and true or false
                local gearSet = gearSetSlots[p.bag * 1000 + p.slot] or false
                items[#items + 1] = {
                    index    = i,
                    bag      = p.bag,
                    slot     = p.slot,
                    itemID   = itemID,
                    name     = info.itemName,
                    count    = count,
                    quality  = quality,
                    ilvl     = ilvl,
                    bound    = bound,
                    gearSet  = gearSet,
                    maxStack = MaxStack(p.bag, p.slot, itemID),
                    sig      = StackSignature(itemID, ilvl, quality, bound, gearSet, info.itemName),
                }
            end
        end
    end
    return items, locked
end

function ns.SetVirtualState(v) virtualState = v end
ns.VirtualSnapshot, ns.VirtualSet = VirtualSnapshot, VirtualSet
ns.Positions, ns.Scan = Positions, Scan

-- Bridge for Sort.lua, a separate chunk that cannot see this file's locals.
ns.DB, ns.Debug, ns.DebugDetail, ns.Scopes = DB, Debug, DebugDetail, Scopes
ns.ItemMeta, ns.ItemLevel, ns.MaxStack = ItemMeta, ItemLevel, MaxStack
ns.SortKeys, ns.KeyLess = SortKeys, KeyLess
ns.FitsBag, ns.FitsBankTab, ns.RefusedKey, ns.refused = FitsBag, FitsBankTab, RefusedKey, refused
ns.BuildGroups, ns.BuildBankGroups, ns.BagFamily = BuildGroups, BuildBankGroups, BagFamily
ns.BankType, ns.BankTabBags, ns.TabIsIgnored, ns.FetchBankTabs = BankType, BankTabBags, TabIsIgnored, FetchBankTabs
ns.DetectBankType, ns.GuildBankOpen = DetectBankType, GuildBankOpen


-- ========= --
-- Lifecycle --
-- ========= --

function BagSort:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("BagSortDB", defaults, true)

    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileUpdate")
    self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileUpdate")
    self.db.RegisterCallback(self, "OnProfileReset", "OnProfileUpdate")

    RebuildClassRank()
    ns.SetupOptions()

    self:RegisterChatCommand("sort", "SlashCommand")
    self:RegisterChatCommand("bagsort", "SlashCommand")
end

function BagSort:OnEnable()
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
end

-- changing settings aborts a running sort
function BagSort:OnProfileUpdate()
    if BagSort:IsSorting() then ns.StopSort("stopped, the settings changed.") end
    RebuildClassRank()
    ns.RefreshOptions()
end

-- used by the bag tab of the options panel
local function ApplyCategoryOrder(order)
    if BagSort:IsSorting() then ns.StopSort("stopped, the category order changed.") end
    DB().categoryOrder = order
    RebuildClassRank()
end

function ns.SetCategoryOrder(order)
    if type(order) ~= "table" then return end
    ApplyCategoryOrder(order)
end

function ns.ResetCategoryOrder()
    ApplyCategoryOrder(ns.DefaultCategoryOrder())
end

-- used by the detail panel of a bag category
function ns.SetCategorySettings(key, patch)
    if type(key) ~= "string" or type(patch) ~= "table" then return end
    if BagSort:IsSorting() then ns.StopSort("stopped, the category settings changed.") end

    local db = DB()
    db.categorySettings = db.categorySettings or {}
    local saved = db.categorySettings[key] or {}
    for field in pairs(patch) do
        if patch[field] ~= nil then saved[field] = patch[field] end
    end
    db.categorySettings[key] = saved

    RebuildClassRank()
end

-- used by the defaults button
function ns.ResetCategorySettings()
    if BagSort:IsSorting() then ns.StopSort("stopped, the category settings changed.") end
    DB().categorySettings = {}
    RebuildClassRank()
end

-- used by the bank tab
local function ApplyBankCategoryOrder(order)
    if BagSort:IsSorting() then ns.StopSort("stopped, the category order changed.") end
    DB().bankCategoryOrder = order
    RebuildClassRank()
end

function ns.SetBankCategoryOrder(order)
    if type(order) ~= "table" then return end
    ApplyBankCategoryOrder(order)
end

function ns.ResetBankCategoryOrder()
    ApplyBankCategoryOrder(ns.DefaultCategoryOrder())
end

function ns.SetBankCategorySettings(key, patch)
    if type(key) ~= "string" or type(patch) ~= "table" then return end
    if BagSort:IsSorting() then ns.StopSort("stopped, the category settings changed.") end

    local db = DB()
    db.bankCategorySettings = db.bankCategorySettings or {}
    local saved = db.bankCategorySettings[key] or {}
    -- See the matching comment in ns.SetCategorySettings above.
    for field in pairs(patch) do
        if patch[field] ~= nil then saved[field] = patch[field] end
    end
    db.bankCategorySettings[key] = saved

    RebuildClassRank()
end

function ns.ResetBankCategorySettings()
    if BagSort:IsSorting() then ns.StopSort("stopped, the category settings changed.") end
    DB().bankCategorySettings = {}
    RebuildClassRank()
end


-- ================= --
-- Custom categories
-- ================= --

function ns.IsCustomCategory(key)
    local custom = DB().customCategories
    return custom ~= nil and custom[key] ~= nil
end

-- add custom category
function ns.AddCustomCategory()
    if BagSort:IsSorting() then ns.StopSort("stopped, the category order changed.") end
    local db = DB()
    db.customCategories = db.customCategories or {}
    db.nextCustomCategoryID = (db.nextCustomCategoryID or 0) + 1
    local key = "Custom" .. db.nextCustomCategoryID
    db.customCategories[key] = { name = "Custom Category " .. db.nextCustomCategoryID, items = {}, seq = db.nextCustomCategoryID }
    RebuildClassRank()
    return key
end

-- deletes the category
function ns.RemoveCustomCategory(key)
    local db = DB()
    local custom = db.customCategories
    if not (custom and custom[key]) then return end
    if BagSort:IsSorting() then ns.StopSort("stopped, the category order changed.") end
    custom[key] = nil

    if db.categorySettings then db.categorySettings[key] = nil end
    if db.bankCategorySettings then db.bankCategorySettings[key] = nil end

    for _, orderKey in ipairs({ "categoryOrder", "bankCategoryOrder" }) do
        local order = db[orderKey]
        if type(order) == "table" then
            for i = #order, 1, -1 do
                if order[i] == key then table.remove(order, i) end
            end
        end
    end

    if not next(custom) then db.nextCustomCategoryID = 0 end
    RebuildClassRank()
end

function ns.RenameCustomCategory(key, name)
    local custom = DB().customCategories
    local def = custom and custom[key]
    if not def then return end
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
    if name ~= "" then def.name = name end
end

function ns.CustomCategoryName(key)
    local custom = DB().customCategories
    local def = custom and custom[key]
    return def and def.name
end

function ns.AddCustomCategoryItem(key, itemID, before)
    itemID = tonumber(itemID)
    local custom = DB().customCategories
    local def = custom and custom[key]
    if not (def and itemID) then return end
    if BagSort:IsSorting() then ns.StopSort("stopped, the category order changed.") end

    -- make sure an item is only in one category
    for _, otherDef in pairs(custom) do
        for i, id in ipairs(otherDef.items) do
            if id == itemID then
                table.remove(otherDef.items, i)
                break
            end
        end
    end

    local index
    if before then
        for i, id in ipairs(def.items) do
            if id == before then index = i; break end
        end
    end
    table.insert(def.items, index or (#def.items + 1), itemID)
    RebuildClassRank()
end

function ns.RemoveCustomCategoryItem(key, itemID)
    itemID = tonumber(itemID)
    local def = DB().customCategories and DB().customCategories[key]
    if not (def and itemID) then return end
    for i, id in ipairs(def.items) do
        if id == itemID then
            if BagSort:IsSorting() then ns.StopSort("stopped, the category order changed.") end
            table.remove(def.items, i)
            RebuildClassRank()
            return
        end
    end
end

function ns.MoveCustomCategoryItem(key, itemID, delta)
    local def = DB().customCategories and DB().customCategories[key]
    if not def then return end
    local index
    for i, id in ipairs(def.items) do
        if id == itemID then index = i; break end
    end
    if not index then return end
    local target = index + delta
    if target < 1 or target > #def.items then return end
    if BagSort:IsSorting() then ns.StopSort("stopped, the category order changed.") end
    table.remove(def.items, index)
    table.insert(def.items, target, itemID)
    RebuildClassRank()
end

function ns.SetCustomCategoryItems(key, order)
    local def = DB().customCategories and DB().customCategories[key]
    if not (def and type(order) == "table") then return end
    if BagSort:IsSorting() then ns.StopSort("stopped, the category order changed.") end

    local seen, list = {}, {}
    for _, itemID in ipairs(order) do
        for _, id in ipairs(def.items) do
            if id == itemID and not seen[itemID] then
                seen[itemID] = true
                list[#list + 1] = itemID
                break
            end
        end
    end
    for _, id in ipairs(def.items) do
        if not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    def.items = list
    RebuildClassRank()
end

function ns.CustomCategoryItems(key)
    local def = DB().customCategories and DB().customCategories[key]
    local list = {}
    if not def then return list end
    for i, itemID in ipairs(def.items) do list[i] = itemID end
    return list
end


-- ========= --
-- Debugging --
-- ========= --

local function Report(name, value)
    print(("  %-36s %s"):format(name, value and "ok" or "|cffff4040MISSING|r"))
end

-- prints everything
function BagSort:Diagnose()
    self:Print("diagnostics")
    print("  client interface: " .. tostring(select(4, GetBuildInfo())))
    print("  AceAddon-3.0 / AceDB-3.0 / AceConfig-3.0: "
        .. tostring(select(2, LibStub("AceAddon-3.0"))) .. " / "
        .. tostring(select(2, LibStub("AceDB-3.0"))) .. " / "
        .. tostring(select(2, LibStub("AceConfig-3.0"))))
    print("  profile: " .. tostring(self.db:GetCurrentProfile()))
    Report("C_Container.GetContainerNumSlots", Container.GetContainerNumSlots)
    Report("C_Container.GetContainerNumFreeSlots", Container.GetContainerNumFreeSlots)
    Report("C_Container.GetContainerItemInfo", Container.GetContainerItemInfo)
    Report("C_Container.PickupContainerItem", Container.PickupContainerItem)
    Report("C_Container.SplitContainerItem", Container.SplitContainerItem)
    Report("C_Container.GetBagSlotFlag", Container.GetBagSlotFlag)
    Report("C_Container.GetBackpackAutosortDisabled", Container.GetBackpackAutosortDisabled)
    Report("Enum.BagSlotFlags.DisableAutoSort", BAG_SLOT_FLAG_DISABLE_AUTO_SORT)
    Report("C_Item.GetItemInfoInstant", Item.GetItemInfoInstant)
    Report("C_Item.GetItemMaxStackSize", Item.GetItemMaxStackSize)
    Report("C_Item.GetItemMaxStackSizeByID", Item.GetItemMaxStackSizeByID)
    Report("C_Item.GetItemNameByID", Item.GetItemNameByID)
    Report("C_Item.GetItemFamily", Item.GetItemFamily)
    Report("C_Item.GetItemInfo (reagent flag)", Item.GetItemInfo)
    Report("C_Item.GetItemClassInfo (category names)", Item.GetItemClassInfo)
    Report("bit.band", band)
    Report("C_Item.GetDetailedItemLevelInfo", Item.GetDetailedItemLevelInfo)
    Report("C_EquipmentSet.GetEquipmentSetIDs", C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs)
    Report("C_EquipmentSet.GetItemIDs", C_EquipmentSet and C_EquipmentSet.GetItemIDs)
    Report("ItemLocation", ItemLocation)
    Report("CursorHasItem", CursorHasItem)
    Report("C_Bank.FetchPurchasedBankTabData", Bank and Bank.FetchPurchasedBankTabData)
    Report("Enum.BankType", BankType)
    Report("Enum.BagIndex.CharacterBankTab_1", CHARACTER_BANK_TABS[1])
    Report("Enum.BagIndex.AccountBankTab_1", ACCOUNT_BANK_TABS[1])
    Report("_G.BankPanel", _G.BankPanel or (_G.BankFrame and _G.BankFrame.BankPanel))
    print(("  bank tab deposit flags known: %s"):format(
        #BANK_DEPOSIT_FLAG_ORDER > 0 and table.concat(BANK_DEPOSIT_FLAG_ORDER, ", ") or "none"))
    print(("  C_Bank.CanUseBank: character %s, account %s, guild %s")
        :format(tostring(BankUsable(BankType and BankType.Character)),
                tostring(BankUsable(BankType and BankType.Account)),
                tostring(BankUsable(BankType and BankType.Guild))))

    -- what the bank window itself says
    do
        local panel = _G.BankPanel or (_G.BankFrame and _G.BankFrame.BankPanel)
        if not panel then
            print("  bank panel: not found (neither _G.BankPanel nor _G.BankFrame.BankPanel)")
        else
            local activeType
            if panel.GetActiveBankType then
                local ok, value = pcall(panel.GetActiveBankType, panel)
                activeType = ok and value or ("error: " .. tostring(value))
            end
            print(("  bank panel: shown %s, GetActiveBankType %s, .bankType %s, .selectedTabID %s")
                :format(tostring(BankPanelShown(panel)), tostring(activeType),
                        tostring(panel.bankType), tostring(panel.selectedTabID)))
            local panelType, panelTab = ActiveBankPanel()
            print(("    reads as: bank type %s, tab bag id %s")
                :format(tostring(panelType), tostring(panelTab)))
        end
    end

    -- what an ElvUI bank window is like
    do
        local frame = _G.ElvUI_BankContainerFrame
        local engine = _G.ElvUI
        local E = type(engine) == "table" and engine[1]
        local bags = type(E) == "table" and E.Bags
        if not (frame or bags) then
            print("  ElvUI bank: not installed (no _G.ElvUI_BankContainerFrame, no ElvUI[1].Bags)")
        else
            local db = type(bags) == "table" and bags.db
            print(("  ElvUI bank: frame %s, shown %s, .bankType %s, Bags.BankTab %s")
                :format(frame and "found" or "MISSING", tostring(BankPanelShown(frame)),
                        tostring(frame and frame.bankType), tostring(type(bags) == "table" and bags.BankTab)))
            print(("    combined view: bankCombined %s, warbandCombined %s")
                :format(tostring(type(db) == "table" and db.bankCombined),
                        tostring(type(db) == "table" and db.warbandCombined)))
            local elvType, elvTab = ActiveElvUIBank()
            print(("    reads as: bank type %s, tab bag id %s")
                :format(tostring(elvType), tostring(elvTab)))
        end
    end

    local detected, ambiguous, detectedTab = DetectBankType()
    print(("  bank detected now: %s (ambiguous: %s), tab bag id: %s, guild bank open: %s")
        :format(tostring(detected), tostring(ambiguous and true or false),
                tostring(detectedTab), tostring(GuildBankOpen())))

    -- per-tab data for bank view
    for _, bt in ipairs({ { "character", BankType and BankType.Character },
                           { "account",   BankType and BankType.Account } }) do
        local label, thisType = bt[1], bt[2]
        if BankUsable(thisType) then
            print(("  %s bank tabs:"):format(label))
            local tabBags = BankTabBags(thisType)
            print(("    bag ids (Enum.BagIndex): %s"):format(table.concat(tabBags, ", ")))
            print(("    C_Bank.FetchNumPurchasedBankTabs: %s")
                :format(tostring(Bank and Bank.FetchNumPurchasedBankTabs and Bank.FetchNumPurchasedBankTabs(thisType))))
            local data = Bank and Bank.FetchPurchasedBankTabData and Bank.FetchPurchasedBankTabData(thisType)
            print(("    C_Bank.FetchPurchasedBankTabData: %s entries")
                :format(type(data) == "table" and #data or tostring(data)))
            if type(data) == "table" then
                for i, tabData in ipairs(data) do
                    local keys = {}
                    for k in pairs(tabData) do keys[#keys + 1] = tostring(k) end
                    table.sort(keys)
                    print(("      [%d] fields: %s"):format(i, table.concat(keys, ", ")))
                    local flags = tonumber(tabData.depositFlags) or 0
                    local names = {}
                    for _, name in ipairs(BANK_DEPOSIT_FLAG_ORDER) do
                        if band and band(flags, BANK_DEPOSIT_FLAG_VALUE[name]) ~= 0 then
                            names[#names + 1] = name
                        end
                    end
                    print(("      [%d] depositFlags %d decodes to: %s")
                        :format(i, flags, #names > 0 and table.concat(names, ", ") or "(none)"))
                end
            end
            for i, bagID in ipairs(tabBags) do
                local slots = Container.GetContainerNumSlots(bagID)
                print(("    bag %d (tab %d): %d slots"):format(bagID, i, slots))
                if slots > 0 then
                    local okScan, tabItems = pcall(Scan, Positions({ bagID }))
                    if okScan then
                        for i = 1, math.min(#tabItems, 8) do
                            local it = tabItems[i]
                            local meta = ItemMeta(it.itemID, it.name)
                            local bits = ItemCategoryBits(it, meta)
                            local names = {}
                            for _, name in ipairs(BANK_DEPOSIT_FLAG_ORDER) do
                                if band and band(bits, BANK_DEPOSIT_FLAG_VALUE[name]) ~= 0 then
                                    names[#names + 1] = name
                                end
                            end
                            print(("      %s -> %s"):format(tostring(meta.name),
                                #names > 0 and table.concat(names, ", ") or "(no category matched)"))
                        end
                    end
                end
            end
        end
    end

    print("  top-level globals with \"bank\" in the name:")
    local bankGlobals = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and name:lower():find("bank")
        and type(value) == "table" and value.IsShown and value.GetObjectType and value.GetParent then
            local ok, parent = pcall(value.GetParent, value)
            if ok and parent == UIParent then
                bankGlobals[#bankGlobals + 1] = name
            end
        end
    end
    table.sort(bankGlobals)
    for _, name in ipairs(bankGlobals) do
        local frame = _G[name]
        local ok, shown = pcall(frame.IsShown, frame)
        print(("    %s - shown: %s"):format(name, ok and tostring(shown) or "error"))
    end

    local names = {}
    for i, key in ipairs(ns.CategoryOrder()) do names[i] = CategoryName(key) end
    print("  category order: " .. table.concat(names, ", "))
    local bankNames = {}
    for i, key in ipairs(ns.BankCategoryOrder()) do bankNames[i] = CategoryName(key) end
    print("  bank category order: " .. table.concat(bankNames, ", "))

    local groups = BuildGroups()
    print(("  container groups: %d"):format(#groups))
    for gi, group in ipairs(groups) do
        local parts = {}
        for _, bag in ipairs(group) do
            parts[#parts + 1] = ("bag %d: %d slots, family %d")
                :format(bag, Container.GetContainerNumSlots(bag), BagFamily(bag))
        end
        print(("  group %d - %s"):format(gi, table.concat(parts, " | ")))
    end
    if #groups == 0 then return end

    local generic
    for _, group in ipairs(groups) do
        if group.generic then generic = group break end
    end
    if generic then
        local okScan, genericItems = pcall(Scan, Positions(generic))
        if okScan then
            for _, group in ipairs(groups) do
                if group.restricted then
                    local fits = 0
                    for _, it in ipairs(genericItems) do
                        if FitsBag(it, group[1], group.family) then fits = fits + 1 end
                    end
                    print(("  bag %d (family %d) would take %d of %d item(s) from the generic bags")
                        :format(group[1], group.family or 0, fits, #genericItems))
                end
            end
            for i = 1, math.min(#genericItems, 8) do
                local it = genericItems[i]
                local meta = ItemMeta(it.itemID, it.name)
                local takers = {}
                for _, group in ipairs(groups) do
                    if group.restricted and FitsBag(it, group[1], group.family) then
                        takers[#takers + 1] = "bag " .. group[1]
                    end
                end
                print(("    %s (id %d, class %d, family %s, reagent %s) -> %s")
                    :format(tostring(meta.name), it.itemID, meta.classID, tostring(meta.family),
                            tostring(IsCraftingReagent(it.itemID)),
                            #takers > 0 and table.concat(takers, ", ") or "stays"))
            end
        end
    end

    local positions = Positions(groups[1])

    -- raw field names
    for _, p in ipairs(positions) do
        local info = Container.GetContainerItemInfo(p.bag, p.slot)
        if info then
            local keys = {}
            for k in pairs(info) do keys[#keys + 1] = k end
            table.sort(keys)
            print("  container info fields: " .. table.concat(keys, ", "))
            break
        end
    end

    local ok, items, locked = pcall(Scan, positions)
    if not ok then
        print("  scan failed: " .. tostring(items))
        return
    end
    print(("  group 1: %d slots, %d items, locked: %s"):format(#positions, #items, tostring(locked)))
    for i = 1, math.min(#items, 5) do
        local it = items[i]
        local meta = ItemMeta(it.itemID, it.name)
        print(("    slot %d bag %d.%d  id %d  x%d of %d  q%d  ilvl %d  class %d.%d  %s")
            :format(it.index, it.bag, it.slot, it.itemID, it.count, it.maxStack,
                    it.quality, it.ilvl, meta.classID, meta.subclassID, tostring(meta.name)))
    end

    local okMerge, merges = pcall(ns.PlanMerges, items, positions)
    print("  step 1 merges: " .. (okMerge and #merges or ("failed - " .. tostring(merges))))
    if okMerge and #merges == 0 then
        local okLayout, swaps = pcall(ns.PlanLayout, items, positions, Scopes.bag)
        print("  step 2 moves:  " .. (okLayout and #swaps or ("failed - " .. tostring(swaps))))
    end
end


-- ============= --
-- Slash command --
-- ============= --

function BagSort:ShowHelp()
    local db = DB()
    self:Print("commands:")
    print("  /sort                      -- sort the bags, or the bank if one is open")
    print("  /sort bags                 -- sort the bags, even if a bank is open too")
    print("  /sort character            -- sort the Character Bank directly")
    print("  /sort account              -- sort the Warband Bank directly")
    print("  /sort stop                 -- cancel a running sort")
    print("  /sort order ltr|rtl        -- bag order, now: " .. db.bagOrder)
    print("  /sort slots ltr|rtl        -- bag slot order, now: " .. db.slotOrder)
    print("  /sort taborder ltr|rtl     -- bank tab order, now: " .. db.bankTabOrder)
    print("  /sort bankslots ltr|rtl    -- bank slot order, now: " .. db.bankSlotOrder)
    print("  /sort stacks largest|smallest -- which stack of an item leads, now: " .. db.stackOrder)
    print("  /sort reagent on|off       -- sort the reagent bag, now: " .. (db.reagentBag and "on" or "off"))
    print("  /sort fill on|off          -- move matching items into the reagent and")
    print("                                profession bags, now: " .. (db.fillSpecialBags and "on" or "off"))
    print("  /sort verbose on|off       -- progress messages, now: " .. (db.verbose and "on" or "off"))
    print("  /sort banktabs on|off      -- honor bank tab settings, now: "
        .. (db.honorBankTabSettings and "on" or "off"))
    print("  /sort bankgap on|off       -- one empty bank slot between categories, space "
        .. "permitting, now: " .. (db.bankCategoryGap and "on" or "off"))
    print("  /sort cleanupflag on|off   -- honor \"Ignore this bag\" on cleanup, now: "
        .. (db.honorBagCleanupFlag and "on" or "off"))
    print("  /sort debug                -- print what the addon sees in your bags")
    print("  /sort config               -- open the options panel")
    print("  /sort profile <name>       -- switch profile, now: " .. self.db:GetCurrentProfile())
    print("  /sort reset                -- back to the default settings")
    print("  rtl = last bag first / highest slot first (the default), ltr = the other way round")
end

local function OnOff(value)
    if value == "on" or value == "1" or value == "yes" then return true end
    if value == "off" or value == "0" or value == "no" then return false end
    return nil
end

function BagSort:SlashCommand(msg)
    local db = DB()
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    cmd, rest = (cmd or ""):lower(), (rest or "")

    if cmd == "" then
        self:Sort()

    elseif cmd == "stop" or cmd == "cancel" then
        self:Stop()

    elseif cmd == "order" then
        local value = rest:lower()
        if value == "ltr" or value == "rtl" then
            db.bagOrder = value
            self:Printf("bag order: %s.", value)
            ns.RefreshOptions()
        else
            self:Printf("usage: /sort order ltr|rtl (now: %s)", db.bagOrder)
        end

    elseif cmd == "slots" or cmd == "slot" then
        local value = rest:lower()
        if value == "ltr" or value == "rtl" then
            db.slotOrder = value
            self:Printf("slot order: %s.", value)
            ns.RefreshOptions()
        else
            self:Printf("usage: /sort slots ltr|rtl (now: %s)", db.slotOrder)
        end

    elseif cmd == "taborder" or cmd == "tabs" then
        local value = rest:lower()
        if value == "ltr" or value == "rtl" then
            db.bankTabOrder = value
            self:Printf("bank tab order: %s.", value == "ltr" and "tab 1 first" or "last tab first")
            ns.RefreshOptions()
        else
            self:Printf("usage: /sort taborder ltr|rtl (now: %s)", db.bankTabOrder)
        end

    elseif cmd == "bankslots" or cmd == "bankslot" then
        local value = rest:lower()
        if value == "ltr" or value == "rtl" then
            db.bankSlotOrder = value
            self:Printf("bank slot order: %s.", value)
            ns.RefreshOptions()
        else
            self:Printf("usage: /sort bankslots ltr|rtl (now: %s)", db.bankSlotOrder)
        end

    elseif cmd == "stacks" or cmd == "stack" then
        local value = rest:lower()
        if value == "largest" or value == "smallest" then
            db.stackOrder = value
            self:Printf("stack order: %s first.", value)
            ns.RefreshOptions()
        else
            self:Printf("usage: /sort stacks largest|smallest (now: %s)", db.stackOrder)
        end

    elseif cmd == "reagent" then
        local value = OnOff(rest:lower())
        if value == nil then
            self:Printf("usage: /sort reagent on|off (now: %s)", db.reagentBag and "on" or "off")
        else
            db.reagentBag = value
            self:Printf("reagent bag: %s.", value and "sorted" or "left alone")
            ns.RefreshOptions()
        end

    elseif cmd == "bankgap" then
        local value = OnOff(rest:lower())
        if value == nil then
            self:Printf("usage: /sort bankgap on|off (now: %s)", db.bankCategoryGap and "on" or "off")
        else
            db.bankCategoryGap = value
            self:Printf("one empty bank slot between categories: %s.", value and "on" or "off")
            ns.RefreshOptions()
        end

    elseif cmd == "cleanupflag" then
        local value = OnOff(rest:lower())
        if value == nil then
            self:Printf("usage: /sort cleanupflag on|off (now: %s)", db.honorBagCleanupFlag and "on" or "off")
        else
            db.honorBagCleanupFlag = value
            self:Printf("honoring \"Ignore this bag\" on cleanup: %s.", value and "on" or "off")
            ns.RefreshOptions()
        end

    elseif cmd == "fill" then
        local value = OnOff(rest:lower())
        if value == nil then
            self:Printf("usage: /sort fill on|off (now: %s)", db.fillSpecialBags and "on" or "off")
        else
            db.fillSpecialBags = value
            self:Printf("filling the reagent and profession bags: %s.", value and "on" or "off")
            ns.RefreshOptions()
        end

    elseif cmd == "bags" or cmd == "bag" then
        self:SortBags()

    elseif cmd == "character" or cmd == "account" or cmd == "warband" then
        local bt = (cmd == "character") and (BankType and BankType.Character) or (BankType and BankType.Account)
        if BagSort:IsSorting() then
            self:Print("already sorting - /sort stop to cancel.")
        elseif GuildBankOpen() then
            self:Print("guild bank sorting is not supported.")
        elseif not BankUsable(bt) then
            self:Printf("the %s bank is not open.", cmd == "character" and "Character" or "Warband")
        else
            self:SortBankType(bt)
        end

    elseif cmd == "banktabs" then
        local value = OnOff(rest:lower())
        if value == nil then
            self:Printf("usage: /sort banktabs on|off (now: %s)", db.honorBankTabSettings and "on" or "off")
        else
            db.honorBankTabSettings = value
            self:Printf("honor bank tab settings: %s.", value and "on" or "off")
            ns.RefreshOptions()
        end

    elseif cmd == "debug" then
        self:Diagnose()

    elseif cmd == "verbose" then
        local value = OnOff(rest:lower())
        if value == nil then
            self:Printf("usage: /sort verbose on|off (now: %s)", db.verbose and "on" or "off")
        else
            db.verbose = value
            self:Printf("verbose: %s.", value and "on" or "off")
            ns.RefreshOptions()
        end

    elseif cmd == "config" or cmd == "options" then
        ns.OpenOptions()

    elseif cmd == "profile" then
        if rest == "" then
            self:Printf("current profile: %s.", self.db:GetCurrentProfile())
        else
            self.db:SetProfile(rest)
            self:Printf("profile: %s.", self.db:GetCurrentProfile())
        end

    elseif cmd == "reset" then
        self.db:ResetProfile()
        self:Print("settings reset.")

    else
        self:ShowHelp()
    end
end

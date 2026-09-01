-- BagSort - Options.lua
-- AceConfig, AceConfigDialog, AceDBOptions

local ADDON_NAME, ns = ...
local BagSort = ns.BagSort

local AceConfig         = LibStub("AceConfig-3.0")
local AceConfigDialog   = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
local AceDBOptions      = LibStub("AceDBOptions-3.0")

-- 
-- the last part of the option path is the key in the profile
local function Get(info)
    return BagSort.db.profile[info[#info]]
end

local function Set(info, value)
    BagSort.db.profile[info[#info]] = value
end

local options = {
    type = "group",
    name = "BagSort",
    childGroups = "tab",
    args = {
        general = {
            type = "group",
            order = 10,
            name = "General",
            args = {
                sortNow = {
                    type = "execute",
                    order = 1,
                    name = "Sort now",
                    desc = "Start sorting as if using the /sort command: the bags, or the bank if one is open.",
                    func = function() BagSort:Sort() end,
                    disabled = function() return BagSort:IsSorting() or InCombatLockdown() end,
                },
                stop = {
                    type = "execute",
                    order = 2,
                    name = "Stop",
                    desc = "Cancels a sort that is running.",
                    func = function() BagSort:Stop() end,
                    disabled = function() return not BagSort:IsSorting() end,
                },
                intro = {
                    type = "description",
                    order = 3,
                    name = "Bags are sorted as one big bag, except for restricted bags like reagent bag or profession "
                        .. "bags. They are sorted on their own.\n",
                },
                hint = {
                    type = "description",
                    order = 4,
                    name = "\nType /sort for the command line version.\n",
                },
                behaviour = {
                    type = "group",
                    order = 10,
                    inline = true,
                    name = "Behaviour",
                    args = {
                        stackOrder = {
                            type = "toggle",
                            order = 1,
                            width = "full",
                            name = "Put smallest stack first",
                            desc = "When an item has more than one stack, which stack leads the group. "
                                .. "Off leads with the largest stack (default).",
                            get = function() return BagSort.db.profile.stackOrder == "smallest" end,
                            set = function(_, value)
                                BagSort.db.profile.stackOrder = value and "smallest" or "largest"
                            end,
                        },
                        verbose = {
                            type = "toggle",
                            order = 2,
                            width = "full",
                            name = "Verbose messages",
                            desc = "Writes BagSort messages to the chat.",
                            get = Get,
                            set = Set,
                        },
                        debugMessages = {
                            type = "toggle",
                            order = 3,
                            width = "full",
                            name = "Debug messages",
                            desc = "Writes the debugging messages to the chat.",
                            get = Get,
                            set = Set,
                        },
                    },
                },
                bags = {
                    type = "group",
                    order = 11,
                    inline = true,
                    name = "Bags",
                    args = {
                        bagOrder = {
                            type = "select",
                            order = 1,
                            name = "Bag order",
                            desc = "Which bag is filled first.",
                            values = {
                                ltr = "Backpack first",
                                rtl = "Last bag first (default)",
                            },
                            sorting = { "ltr", "rtl" },
                            get = Get,
                            set = Set,
                        },
                        slotOrder = {
                            type = "select",
                            order = 2,
                            name = "Bag slot order",
                            desc = "Which slot inside a bag is filled first.",
                            values = {
                                ltr = "First slot downwards",
                                rtl = "Last slot upwards (default)",
                            },
                            sorting = { "ltr", "rtl" },
                            get = Get,
                            set = Set,
                        },
                        fillSpecialBags = {
                            type = "toggle",
                            order = 3,
                            width = "full",
                            name = "Fill reagent and profession bags",
                            desc = "Moves items out of the normal bags into a bag that takes them if there is space. "
                                .. "Crafting reagents go into the reagent bag, herbs into a herb bag, and so on. "
                                .. "Off sorts every bag where it stands.",
                            get = Get,
                            set = Set,
                        },
                        reagentBag = {
                            type = "toggle",
                            order = 4,
                            width = "full",
                            name = "Sort the reagent bag",
                            desc = "Sorts the reagent bag as well.",
                            get = Get,
                            set = Set,
                        },
                        honorBagCleanupFlag = {
                            type = "toggle",
                            order = 5,
                            width = "full",
                            name = "Honor \"Ignore this bag > Cleanup\" setting",
                            desc = "A bag that has set \"Ignore this bag > Cleanup\" set (from its own right-click "
                                .. "menu) is left out of the sort entirely.",
                            get = Get,
                            set = Set,
                        },
                    },
                },
                bank = {
                    type = "group",
                    order = 12,
                    inline = true,
                    name = "Bank",
                    args = {
                        bankTabOrder = {
                            type = "select",
                            order = 1,
                            name = "Bank tab order",
                            desc = "Which bank tab is filled first. Only tabs you have bought count, so \"Last tab\" "
                                .. "starts at the last existing tab.",
                            values = {
                                ltr = "First tab (default)",
                                rtl = "Last tab",
                            },
                            sorting = { "ltr", "rtl" },
                            get = Get,
                            set = Set,
                        },
                        bankSlotOrder = {
                            type = "select",
                            order = 2,
                            name = "Bank slot order",
                            desc = "Which slot inside a bank tab is filled first.",
                            values = {
                                ltr = "First slot downwards (default)",
                                rtl = "Last slot upwards",
                            },
                            sorting = { "ltr", "rtl" },
                            get = Get,
                            set = Set,
                        },
                        honorBankTabSettings = {
                            type = "toggle",
                            order = 3,
                            width = "full",
                            name = "Try to honor bank tab settings",
                            desc = "Try to keep each tab's deposit filter settings as much as possible. Two tabs with "
                                .. "the same settings are sorted as one big group. Tabs set to \"Ignore this tab\" "
                                .. "are left alone. Items matching these filters are moved into these tabs, if there "
                                .. "is enough space.",
                            get = Get,
                            set = Set,
                        },
                        bankCategoryGap = {
                            type = "toggle",
                            order = 4,
                            width = "full",
                            name = "Leave empty slot between categories",
                            desc = "Leaves empty slots between categories in the bank when there is enough space.",
                            get = Get,
                            set = Set,
                        },
                    },
                },
            },
        },
        bag = {
            type = "group",
            order = 20,
            name = "Bag",
            args = {
                note = {
                    type = "description",
                    order = 1,
                    fontSize = "medium",
                    name = "Drag categories into the order you want them to be in your bags. Select a category to "
                        .. "change how items inside it are sorted.\n",
                },
                categoryOrder = {
                    type = "input",
                    order = 10,
                    width = "full",
                    dialogControl = "BagSortCategoryOrder",
                    name = "",
                    get = function()
                        return table.concat(ns.CategoryOrder(), ",")
                    end,
                    set = function(_, value)
                        local order = {}
                        for key in tostring(value or ""):gmatch("[^,%s]+") do
                            order[#order + 1] = key
                        end
                        ns.SetCategoryOrder(order)
                    end,
                },
            },
        },
        bank = {
            type = "group",
            order = 30,
            name = "Bank",
            args = {
                note = {
                    type = "description",
                    order = 1,
                    fontSize = "medium",
                    name = "Drag categories into the order you want them to be in your bank. Select a category to "
                        .. "change how items inside it are sorted.\n",
                },
                categoryOrder = {
                    type = "input",
                    order = 10,
                    width = "full",
                    dialogControl = "BagSortBankCategoryOrder",
                    name = "",
                    get = function()
                        return table.concat(ns.BankCategoryOrder(), ",")
                    end,
                    set = function(_, value)
                        local order = {}
                        for key in tostring(value or ""):gmatch("[^,%s]+") do
                            order[#order + 1] = key
                        end
                        ns.SetBankCategoryOrder(order)
                    end,
                },
            },
        },
        about = {
            type = "group",
            order = 100,
            name = "About",
            args = {
                info = {
                    type = "description",
                    order = 1,
                    fontSize = "medium",
                    name = function()
                        local Meta = C_AddOns and C_AddOns.GetAddOnMetadata
                        local function Field(key) return Meta and Meta(ADDON_NAME, key) or nil end
                        local title   = Field("Title") or ADDON_NAME
                        local version = Field("Version") or "unknown"
                        local author  = Field("Author") or "unknown"
                        local notes   = Field("Notes") or ""
                        return ("|cffffd200%s|r  (version %s)\nby %s\n\n%s\n"):format(title, version, author, notes)
                    end,
                },
                commands = {
                    type = "description",
                    order = 10,
                    fontSize = "medium",
                    name = "/sort with no arguments sorts the bags, or the bank if one is open.\n",
                },
                integrations = {
                    type = "description",
                    order = 20,
                    fontSize = "medium",
                    name = function()
                        local baganator = (Baganator and Baganator.API and Baganator.API.RegisterContainerSort)
                            and "|cff20ff20detected|r" or "|cff808080not detected|r"
                        local ldb = (LibStub and LibStub("LibDataBroker-1.1", true))
                            and "|cff20ff20available|r" or "|cff808080not available|r"
                        return ("Baganator sort integration: %s\nLibDataBroker data feed: %s\n"):format(baganator, ldb)
                    end,
                },
            },
        },
    },
}

-- This runs from BagSort:OnInitialize, once the database exists.
function ns.SetupOptions()
    options.args.profiles = AceDBOptions:GetOptionsTable(BagSort.db)
    options.args.profiles.order = 90

    options.args.profiles.args.resetCategories = {
        order = 5,
        type = "execute",
        name = "Reset Categories",
        desc = "Puts the Bag and Bank category order, and every category's own settings, back to their defaults.",
        func = function()
            ns.ResetCategoryOrder()
            ns.ResetCategorySettings()
            ns.ResetBankCategoryOrder()
            ns.ResetBankCategorySettings()
            ns.RefreshOptions()
        end,
    }

    AceConfig:RegisterOptionsTable(ADDON_NAME, options)
    AceConfigDialog:AddToBlizOptions(ADDON_NAME, "BagSort")
end

-- push changes made through /sort commands into an open options panel
function ns.RefreshOptions()
    AceConfigRegistry:NotifyChange(ADDON_NAME)
end

function ns.OpenOptions()
    AceConfigDialog:SetDefaultSize(ADDON_NAME, 800, 600)
    AceConfigDialog:Open(ADDON_NAME)
end

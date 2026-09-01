-- BagSort - Broker.lua
local ADDON_NAME, ns = ...
local BagSort = ns.BagSort

local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
if not LDB then return end

LDB:NewDataObject(ADDON_NAME, {
    type = "launcher",
    icon = "Interface\\Icons\\INV_Misc_Bag_08",
    label = "BagSort",
    text = "BagSort",
    OnClick = function(_, button)
        if button == "RightButton" then
            ns.OpenOptions()
        else
            BagSort:Sort()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("BagSort")
        tooltip:AddLine("|cffffffffLeft-click:|r sort the bags, or the open bank")
        tooltip:AddLine("|cffffffffRight-click:|r open the options")
    end,
})

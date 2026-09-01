-- BagSort - Baganator.lua
-- Registers BagSort as a selectable sort method in Baganator, through its public function
local ADDON_NAME, ns = ...
local BagSort = ns.BagSort

if not (Baganator and Baganator.API and Baganator.API.RegisterContainerSort) then return end

local function OnBaganatorSort(_isReverse, containerType, tabIndex)
    local Constants = Baganator.API.Constants.ContainerType
    if containerType == Constants.Backpack then
        BagSort:SortBags()
    elseif containerType == Constants.CharacterBank and Enum and Enum.BankType then
        BagSort:SortBankType(Enum.BankType.Character, tabIndex)
    elseif containerType == Constants.WarbandBank and Enum and Enum.BankType then
        BagSort:SortBankType(Enum.BankType.Account, tabIndex)
    else
        BagSort:Print("does not know how to sort that container.")
    end
end

Baganator.API.RegisterContainerSort("BagSort", "bagsort", OnBaganatorSort)

# BagSort

A World of Warcraft Retail addon to sort bags, your character and warband banks into a configurable order.
It treats the all the bags as a single combined bag, except for the reagent bag and potential tradeskill bags. 


## Install

Copy the directory BagSort into your World of Warcraft 'AddOns' directory, for example:

  D:\Games\World of Warcraft\_retail_\Interface\AddOns\BagSort

The BagSort.toc file should sit inside the BagSort directory. Enter "/console reloadui" if World of Warcraft is
already running.


## Use

    /sort                   sort the currently open bank, or the bags if no bank is open
    /sort config            open configuration window (also available in the options panel)

    /sort character         sort the whole character bank
    /sort account           sort the whole warband bank

### Banks

The default Blizzard interface shows only one tab at a time, so the addon sorts only the currently visible tab.
Use "/sort character" or "/sort account" to sort all the tabs of the respective bank.

If the addons detects that all bank tabs are visible (Baganator, ElvUI) as one big bank, it will automatically
sort all the visible tabs.

### Categories

You can reorder the categories how items are sorted in the bags or bank (either by drag and drop, or by up/down),
or disable a category completely. Items  from a disabled category all land into the "Default" category if they are
not claimed by a different category. 

Every category can be configured individually how items in that category should be sorted.

### Custom Categories

In addition to reordering the categories, you can add custom categories and drop items into them. These custom
categories claim items before any other categories, so you can override category-based sorting to have some items
at fixed positions. Items in these custom categories can also be sorted by hand.


## Other Addons

This addon has been tested and made compatible with other addons:

   * Databroker: Simple DataBroker support: Left click to sort like the "/sort" command, right click to open options.
   * Baganator: Hooks into Baganator as a selectable sort routine. Bank sorting is dependent if a tab is visible, 
     or the whole bank is visible. 
   * ElvUI: Detection logic if a single bank tab, or the whole bank is currently visible.

Not tested with any other addons.


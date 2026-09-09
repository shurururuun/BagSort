-- BagSort - Sort.lua
-- Planning and execution of a sort run, in three steps:
--   1. stack   : pour partial stacks of the same item together
--   2. layout  : decide the target slot for every stack (pure Lua, no actions)
--   3. commit  : swap items into place, walking the slot list from first to last
-- Every container group is processed on its own. All generic bags form one big virtual bag, and each
-- family-restricted bag (reagent bag, herb bag, ...) is an extra container sorted by itself, because the game
-- refuses foreign items there.

local ADDON_NAME, ns = ...

local BagSort = ns.BagSort
local Container = C_Container

local BankType = ns.BankType

local DB, Debug, Scopes = ns.DB, ns.Debug, ns.Scopes
local DebugDetail = ns.DebugDetail
local ItemMeta, ItemLevel, MaxStack = ns.ItemMeta, ns.ItemLevel, ns.MaxStack
local SortKeys, KeyLess = ns.SortKeys, ns.KeyLess
local StackSignature = ns.StackSignature
local FitsBag, FitsBankTab, RefusedKey, refused = ns.FitsBag, ns.FitsBankTab, ns.RefusedKey, ns.refused
local BuildGroups, BuildBankGroups, BagFamily = ns.BuildGroups, ns.BuildBankGroups, ns.BagFamily
local BankTabBags, TabIsIgnored, FetchBankTabs = ns.BankTabBags, ns.TabIsIgnored, ns.FetchBankTabs
local DetectBankType, GuildBankOpen = ns.DetectBankType, ns.GuildBankOpen
local DepositFlagSpecificity = ns.DepositFlagSpecificity
local Positions, Scan, SetVirtualState = ns.Positions, ns.Scan, ns.SetVirtualState
local VirtualSnapshot, VirtualSet = ns.VirtualSnapshot, ns.VirtualSet
local RebuildGearSetItems, ForgetProvisional = ns.RebuildGearSetItems, ns.ForgetProvisional

local MAX_PASSES   = 20    -- scan/plan rounds per container group before giving up
local LOCK_RETRIES = 40    -- ticks to wait for the server to unlock a slot
local TICK_INTERVAL = 0.1  -- seconds between two run steps - only used during the planning

-- failsafe watchdog settings
local WATCHDOG_INTERVAL = 1
local STALL_SAMPLES = 2
local STALL_NUDGES  = 2


-- ============================= --
-- Step 1 - merge partial stacks --
-- ============================= --

local function PlanMerges(items, positions)
    local groups = {}
    for _, it in ipairs(items) do
        if it.maxStack > 1 and it.count < it.maxStack then
            local list = groups[it.itemID]
            if not list then list = {}; groups[it.itemID] = list end
            list[#list + 1] = it
        end
    end

    local moves = {}
    for _, list in pairs(groups) do
        if #list > 1 then
            -- fullest stack first, so the smallest ones get emptied out
            table.sort(list, function(x, y)
                if x.count ~= y.count then return x.count > y.count end
                return x.index < y.index
            end)
            local head, tail = 1, #list
            while head < tail do
                local dst, src = list[head], list[tail]
                local room = dst.maxStack - dst.count
                if room <= 0 then
                    head = head + 1
                else
                    local amount = math.min(room, src.count)
                    local sp, dp = positions[src.index], positions[dst.index]
                    moves[#moves + 1] = {
                        sBag = sp.bag, sSlot = sp.slot, itemID = src.itemID, sCount = src.count,
                        dBag = dp.bag, dSlot = dp.slot, dItemID = dst.itemID, dCount = dst.count,
                        amount = amount, split = (amount < src.count),
                    }
                    dst.count = dst.count + amount
                    src.count = src.count - amount
                    if src.count == 0 then tail = tail - 1 end
                    if dst.count >= dst.maxStack then head = head + 1 end
                end
            end
        end
    end
    return moves
end


-- ======================================================================== --
-- Step 1b - put items that fit in a restricted bag out of the generic bags --
-- ======================================================================== --

local function PlanRelocations(items, positions, srcItems, srcPositions, fits)
    local taken = {}
    for _, it in ipairs(items) do taken[it.index] = true end

    local free = {}
    for i = 1, #positions do
        if not taken[i] then free[#free + 1] = positions[i] end
    end

    local room = {}  -- itemID -> stacks with space left
    for _, it in ipairs(items) do
        if it.count < it.maxStack then
            local list = room[it.itemID]
            if not list then list = {}; room[it.itemID] = list end
            list[#list + 1] = it
        end
    end

    local moves, nextFree = {}, 1
    for _, it in ipairs(srcItems) do
        if fits(it) then
            local sp = srcPositions[it.index]
            local into
            for _, stack in ipairs(room[it.itemID] or {}) do
                if stack.maxStack - stack.count >= it.count then into = stack break end
            end
            if into then
                moves[#moves + 1] = {
                    sBag = sp.bag, sSlot = sp.slot, itemID = it.itemID, sCount = it.count,
                    dBag = into.bag, dSlot = into.slot, dItemID = into.itemID, dCount = into.count,
                    relocation = true,
                }
                into.count = into.count + it.count
            elseif free[nextFree] then
                local fp = free[nextFree]
                nextFree = nextFree + 1
                moves[#moves + 1] = {
                    sBag = sp.bag, sSlot = sp.slot, itemID = it.itemID, sCount = it.count,
                    dBag = fp.bag, dSlot = fp.slot,
                    relocation = true,
                }
            end
        end
    end
    return moves
end

-- ================================ --
-- Step 2 - build the target layout --
-- ================================ --

local function PlanLayout(items, positions, S)
    local stackOrder = DB().stackOrder
    local keyOf = SortKeys(items, S)

    local sorted = {}
    for i, it in ipairs(items) do sorted[i] = it end
    table.sort(sorted, function(a, b) return KeyLess(keyOf[a], keyOf[b], stackOrder) end)

    -- where empty slots go
    local slotAt, nFront = {}, #sorted
    if S.emptyRank then
        nFront = 0
        for _, it in ipairs(sorted) do
            if keyOf[it].rank >= S.emptyRank then break end
            nFront = nFront + 1
        end
    end
    local gap = #positions - #sorted

    -- boundaries for bank categories gap
    local boundaries = 0
    if S == Scopes.bank and DB().bankCategoryGap then
        for rank = 2, #sorted do
            if keyOf[sorted[rank]].rank ~= keyOf[sorted[rank - 1]].rank then boundaries = boundaries + 1 end
        end
        if boundaries == 0 or boundaries > gap then boundaries = 0 end
    end

    if boundaries > 0 then
        local extra, slot = gap - boundaries, 0
        for rank = 1, #sorted do
            if rank == nFront + 1 then slot = slot + extra end
            if rank > 1 and keyOf[sorted[rank]].rank ~= keyOf[sorted[rank - 1]].rank then slot = slot + 1 end
            slot = slot + 1
            slotAt[rank] = slot
        end
    else
        for rank = 1, #sorted do
            slotAt[rank] = rank <= nFront and rank or rank + gap
        end
    end

    -- interchangeable stacks
    local descending = stackOrder ~= "smallest"
    local pool = {}
    for _, it in ipairs(items) do
        local list = pool[it.sig]
        if not list then list = {}; pool[it.sig] = list end
        list[#list + 1] = it
    end
    for _, list in pairs(pool) do
        if #list > 1 then
            table.sort(list, function(x, y)
                if descending then return x.count < y.count end
                return x.count > y.count
            end)
        end
    end
    local function Take(sig, preferred)
        local list = pool[sig]
        if not list or #list == 0 then return nil end
        if preferred then
            for i, it in ipairs(list) do
                if it == preferred then return table.remove(list, i) end
            end
        end
        return table.remove(list)
    end

    local at = {}  -- slot index -> stack
    for _, it in ipairs(items) do at[it.index] = it end

    -- only keep stacks with the right size
    local assign = {}  -- slot index -> wanted stack
    for rank = 1, #sorted do
        local i = slotAt[rank]
        local cur = at[i]
        if cur and cur.sig == sorted[rank].sig and cur.count == sorted[rank].count then
            assign[i] = Take(cur.sig, cur)
        end
    end
    for rank = 1, #sorted do
        local i = slotAt[rank]
        if not assign[i] then assign[i] = Take(sorted[rank].sig) end
    end

    local posOf = {}  -- stack -> slot index
    for _, it in ipairs(items) do posOf[it] = it.index end

    -- reverse of assign
    local slotOf = {}
    for i, it in pairs(assign) do slotOf[it] = i end

    -- any slot holding nothing
    local function EmptySlot()
        for j = 1, #positions do
            if not at[j] then return j end
        end
    end

    local moves = {}
    local function Move(from, to)
        local moving, sitting = at[from], at[to]
        local sp, dp = positions[from], positions[to]
        moves[#moves + 1] = {
            sBag = sp.bag, sSlot = sp.slot, itemID = moving.itemID, sCount = moving.count,
            dBag = dp.bag, dSlot = dp.slot,
            dItemID = sitting and sitting.itemID or nil,
            dCount  = sitting and sitting.count or nil,
        }
        at[to], at[from] = moving, sitting
        posOf[moving] = to
        if sitting then posOf[sitting] = from end
    end

    -- detect a swap chain and try to avoid it
    local dirty, toStage, freePool = {}, {}, {}
    for i, want in pairs(assign) do
        if at[i] ~= want then
            dirty[#dirty + 1] = i
            if at[i] then toStage[#toStage + 1] = i end
        end
    end
    for j = 1, #positions do
        if not at[j] and not assign[j] then freePool[#freePool + 1] = j end
    end
    if #toStage > 0 and #toStage <= #freePool then
        for k, i in ipairs(toStage) do Move(i, freePool[k]) end
        for _, i in ipairs(dirty) do
            local want = assign[i]
            if at[i] ~= want then Move(posOf[want], i) end
        end
        return moves
    end

    -- not enough space to park everything, but still some room
    if #freePool > 0 and #toStage > #freePool then
        local every = math.ceil(#toStage / #freePool)
        local parked = 0
        for n = every, #toStage, every do
            parked = parked + 1
            if parked > #freePool then break end
            Move(toStage[n], freePool[parked])
        end
    end

    -- Walk forwards, so the first target slot is filled first: once a slot holds its target stack it is never
    -- touched again - no other slot wants that stack - so every swap needs exactly one move either way. slotAt is
    -- increasing, so this is still front to back; it just steps over the gap. A stack sitting inside the range
    -- Empty wants left clear is never a target slot's "want", so it is picked up by whichever later slot does
    -- want it, and the gap is empty once the walk ends.
    for rank = 1, #sorted do
        local i = slotAt[rank]
        local want = assign[i]
        if at[i] ~= want then
            -- don't try to make the same item trade places
            local sitting = at[i]
            if sitting and sitting.itemID == want.itemID then
                local spare = EmptySlot()
                if spare then
                    Move(i, spare)
                else
                    -- nowhere to park it
                    local k = slotOf[sitting]
                    assign[i], assign[k] = sitting, want
                    slotOf[sitting], slotOf[want] = i, k
                    want = sitting
                end
            end
            if at[i] ~= want then Move(posOf[want], i) end
        end
    end
    return moves
end

-- ============== --
-- The run itself --
-- ============== --

-- pendingResume is a zero-argument function re-invoking whichever entry point is waiting for combat to end
-- beginResume is that same closure between Begin() and StartRun(), which hangs it on the run as run.resume
local run, pendingResume, beginResume = nil, nil, nil

-- the frame a commit listens for BAG_UPDATE_DELAYED on (see BatchWaitForSettle)
local settleFrame

-- takes the settle listener off the frame, whether it was the event or the fallback timer that got there first,
-- or the run ending underneath both
local function StopWaitingForSettle()
    if settleFrame then
        settleFrame:UnregisterAllEvents()
        settleFrame:SetScript("OnEvent", nil)
    end
    if run and run.batchSettleTimer then
        BagSort:CancelTimer(run.batchSettleTimer)
        run.batchSettleTimer = nil
    end
end

local function Finish(reason)
    local moves = run and run.moves or 0
    local waves = run and run.waves or 0
    local elapsed = run and run.started and (GetTime() - run.started) or 0
    if run and run.timer then BagSort:CancelTimer(run.timer) end
    if run and run.watchdog then BagSort:CancelTimer(run.watchdog) end
    StopWaitingForSettle()
    run = nil
    if reason then
        BagSort:Print(reason)
    elseif DB().verbose then
        BagSort:Printf("done, %d move%s in %d commit wave%s (one round trip each), %.2fs",
            moves, moves == 1 and "" or "s", waves, waves == 1 and "" or "s", elapsed)
    else
        BagSort:Printf("done, %d move%s.", moves, moves == 1 and "" or "s")
    end
    ns.RefreshOptions()
end

-- combat has started, so interrupt anything going on
local function InterruptForCombat()
    pendingResume = run.resume
    return Finish("stopped, you entered combat - sorting again when it ends.")
end

local function SlotLocked(bag, slot)
    local info = Container.GetContainerItemInfo(bag, slot)
    return (info and info.isLocked) and true or false
end

local function SlotHolds(bag, slot, itemID, count)
    local info = Container.GetContainerItemInfo(bag, slot)
    local found = info and tonumber(info.itemID)
    if itemID == nil then return found == nil end
    if found ~= itemID then return false end
    return (tonumber(info.stackCount) or 1) == count
end

local function WaitForLocks()
    run.waits = run.waits + 1
    if run.waits > LOCK_RETRIES then Finish("stopped, the bags stayed locked.") end
    return true
end

local function Replan()
    run.queue = nil
    run.pendingReplan = nil
    run.phase = run.relocating and "bankrelocate" or "plan"
end

local function NextGroup()
    run.gi = run.gi + 1
    if run.gi > #run.groups then return Finish() end
    run.pass = 0
    run.positions = Positions(run.groups[run.gi])
    run.family = run.groups[run.gi].family or 0
    run.restricted = run.groups[run.gi].restricted or false
    Replan()
end


-- =========================================== --
-- Step 1c - bank category relocation pre-pass --
-- =========================================== --

-- what a bank tab claims on its turn
local function TabClaims(tab, poolPositions, bagFlags)
    local bagID, flags = tab.bagID, tab.depositFlags
    local family = BagFamily(bagID)
    return function(it)
        if refused[RefusedKey(it.itemID, bagID, family)] then return false end
        local meta = ItemMeta(it.itemID, it.name)
        if flags ~= 0 then return FitsBankTab(it, meta, flags) end
        return not FitsBankTab(it, meta, bagFlags[poolPositions[it.index].bag])
    end
end

-- runs once before any tab's own layout
local function PlanBankRelocate()
    while run.relocTabs[run.relocIndex] and run.relocTabs[run.relocIndex].depositFlags == false do
        run.bankSettledBagSet[run.relocTabs[run.relocIndex].bagID] = true
        run.relocIndex = run.relocIndex + 1
    end

    local tab = run.relocTabs[run.relocIndex]
    if not tab then
        run.relocating = false
        run.phase = "plan"
        return
    end

    run.pass = run.pass + 1
    if run.pass > MAX_PASSES then
        BagSort:Printf("bank tab bag %d did not settle relocation after %d passes, moving on.",
            tab.bagID, MAX_PASSES)
        run.bankSettledBagSet[tab.bagID] = true
        run.relocIndex = run.relocIndex + 1
        run.pass = 0
        if not run.relocTabs[run.relocIndex] then
            run.relocating = false
            run.phase = "plan"
        end
        return
    end

    local destPositions = Positions({ tab.bagID })
    local items, locked = Scan(destPositions)
    if locked then return WaitForLocks() end
    run.waits = 0

    -- every other tab is a candidate source, including ones already processed
    local otherBags = {}
    for _, t in ipairs(run.relocSources) do
        if t.bagID ~= tab.bagID and t.depositFlags ~= tab.depositFlags then otherBags[#otherBags + 1] = t.bagID end
    end
    if #otherBags > 0 then
        local poolPositions = Positions(otherBags)
        local allSrcItems, srcLocked = Scan(poolPositions)
        if srcLocked then return WaitForLocks() end

        local bagFlags = {}
        for _, t in ipairs(run.relocSources) do bagFlags[t.bagID] = t.depositFlags end

        local srcItems = {}
        for _, it in ipairs(allSrcItems) do
            local srcBag = poolPositions[it.index].bag
            local claimedAlready = run.bankSettledBagSet[srcBag]
                and FitsBankTab(it, ItemMeta(it.itemID, it.name), bagFlags[srcBag])
            if not claimedAlready then
                srcItems[#srcItems + 1] = it
            end
        end

        local incoming = PlanRelocations(items, destPositions, srcItems, poolPositions,
            TabClaims(tab, poolPositions, bagFlags))
        if #incoming > 0 then
            Debug("bank relocation: moving %d item(s) into tab bag %d", #incoming, tab.bagID)
            run.queue, run.phase = incoming, "commit"
            return
        end
    end

    -- nothing left to pull into this tab - settle it and move to the next
    run.bankSettledBagSet[tab.bagID] = true
    run.relocIndex = run.relocIndex + 1
    run.pass = 0
    if not run.relocTabs[run.relocIndex] then
        run.relocating = false
        run.phase = "plan"
    end
end


-- ================= --
-- The combined plan --
-- ================= --

-- keep virtual state in step with a move PlanAll() has decided on
local function ApplyVirtualMove(mv)
    local src = VirtualSnapshot(mv.sBag, mv.sSlot)
    local dst = VirtualSnapshot(mv.dBag, mv.dSlot)
    if src and dst and dst.itemID == src.itemID then
        local amount = mv.split and mv.amount or src.count
        local left = src.count - amount
        VirtualSet(mv.sBag, mv.sSlot, left > 0 and {
            itemID = src.itemID, name = src.name, count = left, quality = src.quality,
            ilvl = src.ilvl, bound = src.bound, maxStack = src.maxStack, sig = src.sig,
        } or nil)
        VirtualSet(mv.dBag, mv.dSlot, {
            itemID = dst.itemID, name = dst.name, count = dst.count + amount, quality = dst.quality,
            ilvl = dst.ilvl, bound = dst.bound, maxStack = dst.maxStack, sig = dst.sig,
        })
    else
        VirtualSet(mv.dBag, mv.dSlot, src)
        VirtualSet(mv.sBag, mv.sSlot, dst)
    end
end

-- build the whole move queue
local function PlanAll()
    local queue = {}
    local function AddMoves(moves)
        for _, mv in ipairs(moves) do
            queue[#queue + 1] = mv
            ApplyVirtualMove(mv)
        end
    end

    -- seed the snapshot from a scan of every slot touched
    SetVirtualState({})
    local positionSets = {}
    if run.relocating then
        for _, t in ipairs(run.relocSources) do positionSets[#positionSets + 1] = { t.bagID } end
    end
    for _, g in ipairs(run.groups) do positionSets[#positionSets + 1] = g end
    for _, posSet in ipairs(positionSets) do
        for _, p in ipairs(Positions(posSet)) do
            local info = Container.GetContainerItemInfo(p.bag, p.slot)
            local itemID = info and tonumber(info.itemID)
            if itemID then
                local ilvl = ItemLevel(info.hyperlink)
                local quality = tonumber(info.quality) or 1
                local bound = info.isBound and true or false
                VirtualSet(p.bag, p.slot, {
                    itemID = itemID, name = info.itemName, count = tonumber(info.stackCount) or 1,
                    quality = quality, ilvl = ilvl, bound = bound,
                    maxStack = MaxStack(p.bag, p.slot, itemID),
                    sig = StackSignature(itemID, ilvl, quality, bound, info.itemName),
                })
            end
        end
    end

    -- bank category relocation pre-pass, tab by tab
    if run.relocating then
        local settledBagSet, bagFlags = {}, {}
        for _, t in ipairs(run.relocSources) do bagFlags[t.bagID] = t.depositFlags end
        for _, tab in ipairs(run.relocTabs) do
            if tab.depositFlags ~= false then
                local destPositions = Positions({ tab.bagID })
                local items = Scan(destPositions)
                local otherBags = {}
                for _, t in ipairs(run.relocSources) do
                    if t.bagID ~= tab.bagID and t.depositFlags ~= tab.depositFlags then
                        otherBags[#otherBags + 1] = t.bagID
                    end
                end
                if #otherBags > 0 then
                    local poolPositions = Positions(otherBags)
                    local allSrcItems = Scan(poolPositions)
                    local srcItems = {}
                    for _, it in ipairs(allSrcItems) do
                        local srcBag = poolPositions[it.index].bag
                        local claimedAlready = settledBagSet[srcBag]
                            and FitsBankTab(it, ItemMeta(it.itemID, it.name), bagFlags[srcBag])
                        if not claimedAlready then srcItems[#srcItems + 1] = it end
                    end
                    AddMoves(PlanRelocations(items, destPositions, srcItems, poolPositions,
                        TabClaims(tab, poolPositions, bagFlags)))
                end
            end
            settledBagSet[tab.bagID] = true
        end
    end

    -- every container group, in turn: merge stacks, pull in items
    local genericPositions
    for _, g in ipairs(run.groups) do
        if g.generic then genericPositions = Positions(g) end
    end
    for _, g in ipairs(run.groups) do
        local positions = Positions(g)
        AddMoves(PlanMerges(Scan(positions), positions))

        if g.restricted and genericPositions and DB().fillSpecialBags then
            local items = Scan(positions)
            local srcItems = Scan(genericPositions)
            local bag, family = g[1], g.family or 0
            AddMoves(PlanRelocations(items, positions, srcItems, genericPositions, function(it)
                return FitsBag(it, bag, family)
            end))
        end

        AddMoves(PlanLayout(Scan(positions), positions, Scopes[run.scope or "bag"]))
    end

    SetVirtualState(nil)
    return queue
end

local function Plan()
    local items, locked = Scan(run.positions)
    if locked then return WaitForLocks() end
    run.waits = 0

    run.pass = run.pass + 1
    if run.pass > MAX_PASSES then
        BagSort:Printf("bag group %d did not settle after %d passes, skipping it.", run.gi, MAX_PASSES)
        return NextGroup()
    end

    local merges = PlanMerges(items, run.positions)
    if #merges > 0 then
        Debug("group %d: merging %d stack(s)", run.gi, #merges)
        run.queue, run.phase = merges, "commit"
        return
    end

    -- merging first means the slots it freed are available to move into
    if run.restricted and run.generic and DB().fillSpecialBags then
        local srcItems, srcLocked = Scan(run.generic)
        if srcLocked then return WaitForLocks() end
        local bag = run.groups[run.gi][1]
        local incoming = PlanRelocations(items, run.positions, srcItems, run.generic, function(it)
            return FitsBag(it, bag, run.family)
        end)
        if #incoming > 0 then
            Debug("group %d: moving %d item(s) into bag %d", run.gi, #incoming, bag)
            run.queue, run.phase = incoming, "commit"
            return
        end
    end

    local swaps = PlanLayout(items, run.positions, Scopes[run.scope or "bag"])
    if #swaps > 0 then
        Debug("group %d: %d move(s) to sort %d item(s)", run.gi, #swaps, #items)
        run.queue, run.phase = swaps, "commit"
        return
    end

    NextGroup()
end


-- ========================= --
-- Step 3 - commit the moves --
-- ========================= --

-- execute every move that is safe to do right now in one go
local function ExecuteMove(mv)
    if SlotLocked(mv.sBag, mv.sSlot) or SlotLocked(mv.dBag, mv.dSlot) then
        return false, nil, "locked"
    end
    if not SlotHolds(mv.sBag, mv.sSlot, mv.itemID, mv.sCount)
    or not SlotHolds(mv.dBag, mv.dSlot, mv.dItemID, mv.dCount) then
        return false, nil, "stale"
    end

    if CursorHasItem() then ClearCursor() end

    if mv.split then
        Container.SplitContainerItem(mv.sBag, mv.sSlot, mv.amount)
    else
        Container.PickupContainerItem(mv.sBag, mv.sSlot)
    end
    if not CursorHasItem() then
        return false, nil, "nopickup"
    end

    Container.PickupContainerItem(mv.dBag, mv.dSlot)
    if CursorHasItem() then
        ClearCursor()
        -- listen to the client for what a restricted bag takes
        if mv.relocation then
            refused[RefusedKey(mv.itemID, mv.dBag, BagFamily(mv.dBag))] = true
            Debug("bag %d does not take item %d", mv.dBag, mv.itemID)
        end
        Debug("could not drop into bag %d slot %d, replanning", mv.dBag, mv.dSlot)
        return false, true
    end

    return true
end

-- fires for every move in the queue that is ready, in order
local function CommitBatchQueue(queue)
    run.waves = run.waves + 1
    local remaining, dropped = {}, false
    local landed, why = 0, { locked = 0, stale = 0, nopickup = 0 }
    for i, mv in ipairs(queue) do
        local ok, refusal, reason = ExecuteMove(mv)
        if ok then
            run.moves = run.moves + 1
            landed = landed + 1
        elseif refusal then
            dropped = true
            for j = i + 1, #queue do remaining[#remaining + 1] = queue[j] end
            break
        else
            if reason then why[reason] = why[reason] + 1 end
            remaining[#remaining + 1] = mv
        end
    end
    -- a refusal breaks the batch where it landed and starts a replan
    DebugDetail("wave %d: %d of %d moved, %d left (%d locked, %d not ready yet, %d would not pick up)%s",
        run.waves, landed, #queue, #remaining, why.locked, why.stale, why.nopickup,
        dropped and " - refused, replanning" or "")
    for i = 1, #queue do queue[i] = nil end
    for i, mv in ipairs(remaining) do queue[i] = mv end
    return dropped, landed
end

local CommitBatchStep

-- wait for the bags to report the moves
local function BatchWaitForSettle()
    if run.batchWaiting then return end
    run.batchWaiting = true

    if not settleFrame then settleFrame = CreateFrame("Frame") end

    local function Resume()
        StopWaitingForSettle()
        if not run then return end
        run.batchWaiting = false
        CommitBatchStep()
    end

    settleFrame:RegisterEvent("BAG_UPDATE_DELAYED")
    settleFrame:SetScript("OnEvent", Resume)
    run.batchSettleTimer = BagSort:ScheduleTimer(Resume, 1)
end

-- process run.queue to completion as Plan() generated it
CommitBatchStep = function()
    if not run then return end

    -- a replan to see the moves that already went to the server
    if run.pendingReplan then
        run.pendingReplan = nil
        return Replan()
    end

    local before = #run.queue
    local dropped, landed = CommitBatchQueue(run.queue)
    local function ReplanWhenSettled()
        if landed > 0 then
            run.pendingReplan = true
            return BatchWaitForSettle()
        end
        return Replan()
    end
    if dropped then return ReplanWhenSettled() end

    if #run.queue > 0 then
        if #run.queue < before then
            run.batchLockWaits = 0
        else
            run.batchLockWaits = (run.batchLockWaits or 0) + 1
            if run.batchLockWaits > LOCK_RETRIES then return Finish("stopped, the bags stayed locked.") end
        end
        return BatchWaitForSettle()
    end

    run.batchLockWaits = 0
    ReplanWhenSettled()
end

-- fires when the bank panel is no longer visible (closed, switched tabs)
local function BankStillOpen()
    if GuildBankOpen() then return false end
    local group = run.groups[run.gi]
    if not group then return true end -- NextGroup() finishes the run itself
    for _, bag in ipairs(group) do
        if Container.GetContainerNumSlots(bag) <= 0 then return false end
    end
    return true
end

-- on Tick step wrapping PlanAll()
local function PlanAllStep()
    local queue = PlanAll()
    if #queue > 0 then
        run.queue, run.phase = queue, "commit"
    else
        run.phase = run.relocating and "bankrelocate" or "plan"
    end
end

function BagSort:Tick()
    if not run then return end
    if InCombatLockdown() then return InterruptForCombat() end
    if run.scope == "bank" and not BankStillOpen() then return Finish("stopped, the bank closed.") end

    -- commit paces itself off of bag-update events, not this timer
    local phaseFn = Plan
    if run.phase == "commit" then
        if run.batchWaiting then return end
        phaseFn = CommitBatchStep
    elseif run.phase == "bankrelocate" then phaseFn = PlanBankRelocate
    elseif run.phase == "planall" then phaseFn = PlanAllStep end

    -- throw errors to chat even without showing script errors
    local ok, err = pcall(phaseFn)
    SetVirtualState(nil)
    if not ok then
        self:Printf("|cffff4040error|r %s", tostring(err))
        self:Print("run /sort debug and report the output.")
        if run then Finish("stopped after an error.") end
    end
end


-- ======== --
-- Failsafe --
-- ======== --

-- everything about the run that changes
local function RunState()
    return table.concat({
        run.phase, run.gi, run.pass, run.relocIndex or 0, run.moves, run.queue and #run.queue or -1,
    }, ":")
end

-- failsafe, one sample per second
local function WatchdogStep(self)
    if not run then return end
    if InCombatLockdown() then return end  -- Tick() ends the run itself, and it runs ten times as often

    if run.moves ~= run.stallMoves then
        run.stallMoves, run.stalls, run.nudges = run.moves, 0, 0
        run.stallState = RunState()
        return
    end
    local state = RunState()
    if state ~= run.stallState then
        run.stallState, run.stalls = state, 0
        return
    end

    run.stalls = run.stalls + 1
    if run.stalls < STALL_SAMPLES then return end
    run.stalls = 0
    run.nudges = (run.nudges or 0) + 1
    if run.nudges > STALL_NUDGES then
        return Finish("stopped, the sort was not getting anywhere. Try /sort again.")
    end

    Debug("nothing happened for %ds in phase %s - restarting the run's timer and replanning",
        STALL_SAMPLES * WATCHDOG_INTERVAL, run.phase)
    StopWaitingForSettle()
    run.batchWaiting = false
    SetVirtualState(nil)
    if CursorHasItem() then ClearCursor() end
    if run.timer then self:CancelTimer(run.timer) end
    run.timer = self:ScheduleRepeatingTimer("Tick", TICK_INTERVAL)
    Replan()
end

-- Tick() wraps its own step because an error thrown on a timer would otherwise never be seen:
-- AceTimer runs the callback and only re-arms a repeating timer after it returns
function BagSort:Watchdog()
    local ok, err = pcall(WatchdogStep, self)
    if not ok then
        self:Printf("|cffff4040error|r %s", tostring(err))
        self:Print("run /sort debug and report the output.")
        if run then Finish("stopped after an error.") end
    end
end

-- ================ --
-- Public Interface --
-- ================ --

-- shared tail of BagSort:Sort() and BagSort:SortBankType()
local function StartRun(groups, scope, bankType, relocate, onlyTabBagID)
    if #groups == 0 then
        if bankType then
            local tabs = FetchBankTabs(bankType)
            BagSort:Printf("no bank tabs to sort (%d tab(s) accessible right now, "
                .. "honor bank tab settings: %s).", #tabs, tostring(DB().honorBankTabSettings))
        else
            BagSort:Print("no bags to sort.")
        end
        return
    end
    if CursorHasItem() then ClearCursor() end

    -- every filtered tab gets processed before the catch-all, with specific tabs going first
    local relocTabs, relocSources = {}, {}
    if relocate then
        local filtered, catchAll = {}, {}
        for i, t in ipairs(FetchBankTabs(bankType, true)) do
            if not TabIsIgnored(t.depositFlags) then
                relocSources[#relocSources + 1] = t
                if t.depositFlags == 0 then
                    catchAll[#catchAll + 1] = t
                else
                    t.tabOrder = i
                    filtered[#filtered + 1] = t
                end
            end
        end
        table.sort(filtered, function(a, b)
            local sa, sb = DepositFlagSpecificity(a.depositFlags), DepositFlagSpecificity(b.depositFlags)
            if sa ~= sb then return sa > sb end
            return a.tabOrder < b.tabOrder
        end)
        for _, t in ipairs(filtered) do relocTabs[#relocTabs + 1] = t end
        for _, t in ipairs(catchAll) do relocTabs[#relocTabs + 1] = t end

        -- tabs only pull item into the tab, so only that tab takes a turn
        if onlyTabBagID then
            local only = {}
            for _, t in ipairs(relocTabs) do
                if t.bagID == onlyTabBagID and t.depositFlags ~= 0 then only[#only + 1] = t end
            end
            relocTabs = only
        end
    end
    local relocating = relocate and #relocTabs > 0

    -- run that plans the whole relocations and moves for all groups
    run = { groups = groups, gi = 1, pass = 0, moves = 0, waves = 0, waits = 0, phase = "planall",
            started = GetTime(),
            scope = scope, bankType = bankType, resume = beginResume,
            relocTabs = relocTabs, relocSources = relocSources, relocIndex = 1, relocating = relocating,
            bankSettledBagSet = {},
            -- the failsafe's own bookkeeping, see BagSort:Watchdog
            stallMoves = 0, stalls = 0, nudges = 0 }
    run.positions = Positions(groups[1])
    run.family = groups[1].family or 0
    run.restricted = groups[1].restricted or false

    -- generic bags are where restricted bags pull items from
    for _, group in ipairs(groups) do
        if group.generic then run.generic = Positions(group) break end
    end
    run.timer = BagSort:ScheduleRepeatingTimer("Tick", TICK_INTERVAL)
    run.watchdog = BagSort:ScheduleRepeatingTimer("Watchdog", WATCHDOG_INTERVAL)
    Debug("sorting %d container group(s)%s", #groups,
        bankType and (bankType == BankType.Account and " (Warband bank)" or " (Character bank)") or "")
    ns.RefreshOptions()
end

-- shared entry check, if a sort is already going or we are in combat
local function Begin(resume)
    if run then
        BagSort:Print("already sorting - /sort stop to cancel.")
        return false
    end
    if InCombatLockdown() then
        pendingResume = resume
        BagSort:Print("in combat, sorting when it ends.")
        return false
    end
    RebuildGearSetItems()
    ForgetProvisional()
    beginResume = resume
    return true
end

-- run for a single bank tab, without the entry preamble
local function BankTabRun(bankType, bagID)
    if not bagID or Container.GetContainerNumSlots(bagID) <= 0 then
        BagSort:Print("that bank tab is not accessible right now.")
        return
    end

    -- leave bank tabs wiuth "Ignore this tab" alone
    if DB().honorBankTabSettings then
        for _, t in ipairs(FetchBankTabs(bankType)) do
            if t.bagID == bagID and TabIsIgnored(t.depositFlags) then
                return BagSort:Print("that bank tab is set to \"Ignore this tab\" - untick that, or "
                    .. "/sort banktabs off, to sort it anyway.")
            end
        end
    end
    StartRun({ { bagID } }, "bank", bankType, DB().honorBankTabSettings, bagID)
end

function BagSort:Sort()
    if not Begin(function() BagSort:Sort() end) then return end

    if GuildBankOpen() then
        self:Print("guild bank sorting is not supported.")
        return
    end

    -- a "/sort" without arguments sorts whatever is on the screen right now, bank taking priority over bags
    local bankType, ambiguous, tabBagID = DetectBankType()
    if ambiguous then
        self:Print("both the Character and Warband bank are open and BagSort "
            .. "cannot tell which one is on screen - use /sort character or "
            .. "/sort account, or Baganator's own sort dropdown if you have it.")
        return
    end
    if bankType then
        -- Blizzard bank window shows only one tab at a time
        if tabBagID then
            BankTabRun(bankType, tabBagID)
        else
            StartRun(BuildBankGroups(bankType), "bank", bankType, DB().honorBankTabSettings)
        end
    else
        StartRun(BuildGroups(), "bag", nil)
    end
end

-- sort one bank tab, named by its bag id
function BagSort:SortBankTab(bankType, bagID)
    if not Begin(function() BagSort:SortBankTab(bankType, bagID) end) then return end
    BankTabRun(bankType, bagID)
end

-- sort player bags specifically
function BagSort:SortBags()
    if not Begin(function() BagSort:SortBags() end) then return end
    StartRun(BuildGroups(), "bag", nil)
end

-- sort a specific bank directly
function BagSort:SortBankType(bankType, tabIndex)
    if not Begin(function() BagSort:SortBankType(bankType, tabIndex) end) then return end
    if tabIndex then
        return BankTabRun(bankType, BankTabBags(bankType)[tabIndex])
    end
    StartRun(BuildBankGroups(bankType), "bank", bankType, DB().honorBankTabSettings)
end

function BagSort:Stop()
    pendingResume = nil
    if run then
        Finish("stopped.")
    else
        self:Print("not sorting.")
    end
end

function BagSort:IsSorting()
    return run ~= nil
end

function BagSort:PLAYER_REGEN_DISABLED()
    if run then
        InterruptForCombat()
    else
        ns.RefreshOptions()
    end
end

function BagSort:PLAYER_REGEN_ENABLED()
    local resume = pendingResume
    pendingResume = nil
    if resume then
        resume()
    else
        ns.RefreshOptions()
    end
end

ns.StopSort = Finish
ns.PlanMerges = PlanMerges
ns.PlanLayout = PlanLayout

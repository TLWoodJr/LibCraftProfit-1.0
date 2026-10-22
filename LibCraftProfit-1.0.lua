-- LibCraftProfit-1.0: crafting cost and profit. Shared by ProfessionProfit
-- and RecipeProfit, embedded via LibStub. Prices lean on Auctionator (AH and
-- vendor); its own AH searches fill the gaps (quotes, see QuickScan) and
-- give every listing of a reagent (order books, see ScanBooks) for what
-- buying several really costs. The addon using it saves them (SetBookStore).
--
-- Recipe shape used throughout:
--   { made = n, productID = itemID | nil,
--     reagents = { { id = itemID | nil, count = n, name = string | nil }, ... } }
--
-- Pricing and searching take opts.noVendor: treat vendor-sold items like
-- any other (price them from the AH, search for them) - for players who'd
-- rather not visit a vendor. By default a vendor's price always wins.
--
-- Callbacks (lib.RegisterCallback(owner, event, handler)):
--   "PricesUpdated"  AH results came in (Auctionator has stored new prices).

local MAJOR, MINOR = "LibCraftProfit-1.0", 5
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)

local CALLER = "LibCraftProfit" -- the name Auctionator's API is called with
lib.AH_CUT = 0.05               -- auction house cut taken from a sale
lib.STALE_DAYS = 7              -- an AH price last seen longer ago counts as stale

local function auctionator()
  return Auctionator and Auctionator.API and Auctionator.API.v1
end

function lib.IsAvailable()
  return auctionator() ~= nil
end

function lib.Money(copper)
  copper = math.floor(copper + 0.5)
  local sign = copper < 0 and "-" or ""
  copper = math.abs(copper)
  if copper == 0 then return "0|cffeda55fc|r" end
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "|cffffd700g|r" end
  if s > 0 then parts[#parts + 1] = s .. "|cffc7c7cfs|r" end
  if c > 0 then parts[#parts + 1] = c .. "|cffeda55fc|r" end
  return sign .. table.concat(parts, " ")
end

------------------------------------------------------------------------------
-- Prices
------------------------------------------------------------------------------

local function call(name, itemID)
  local api = auctionator()
  if not (api and api[name] and itemID) then return nil end
  local ok, value = pcall(api[name], CALLER, itemID)
  if ok then return value end
end

-- Price a vendor sells the item for, if any.
function lib.VendorPrice(itemID)
  local price = call("GetVendorPriceByItemID", itemID)
  return price and price > 0 and price or nil
end

-- Latest AH price Auctionator has seen.
function lib.AHPrice(itemID)
  local price = call("GetAuctionPriceByItemID", itemID)
  return price and price > 0 and price or nil
end

-- Days since the item was last seen on the AH (0 = today); nil if never seen
-- or more than 21 days ago (Auctionator doesn't say beyond that).
function lib.PriceAge(itemID)
  return call("GetAuctionAgeByItemID", itemID)
end

-- How many days old an AH price is, when that's more than STALE_DAYS (22
-- stands for "over 21"); nil when it's fresh or there's no price.
function lib.StaleDays(itemID)
  if not lib.AHPrice(itemID) then return nil end
  local age = lib.PriceAge(itemID)
  if not age then return 22 end
  return age > lib.STALE_DAYS and age or nil
end

-- "9 days old" / "over 21 days old", for a StaleDays() value.
function lib.StaleText(days)
  return (days > 21 and "over 21" or days) .. " days old"
end

-- A vendor's price, unless opts.noVendor.
local function vendorPrice(itemID, opts)
  if opts and opts.noVendor then return nil end
  return lib.VendorPrice(itemID)
end

-- What one unit of a reagent costs to buy: price, "vendor" | "book" | "AH".
function lib.BuyPrice(itemID, opts)
  local vendor = vendorPrice(itemID, opts)
  if vendor then return vendor, "vendor" end
  return lib.SellPrice(itemID)
end

-- Profit of one craft in copper (rounded down to the whole copper): what
-- `made` items sell for after the AH cut, minus the reagent cost.
function lib.ExactProfit(sell, made, cost)
  return math.floor(sell * made * (1 - lib.AH_CUT) - cost)
end

-- The same, rounded down to the whole silver like Auctionator shows it -
-- for display next to Auctionator's numbers only; calculate with ExactProfit.
function lib.CraftProfit(sell, made, cost)
  return math.floor(lib.ExactProfit(sell, made, cost) / 100) * 100
end

------------------------------------------------------------------------------
-- Order books: every listing of an item (price and quantity), so buying
-- N of something costs what N really cost - not N times the one cheapest
-- listing. Recorded from any item or commodity search (ours, Auctionator's,
-- the AH's own buy screen).
------------------------------------------------------------------------------

lib.MARKET_UNITS = 20    -- the "market price": average of the cheapest 20 units
lib.UNDERCUT = 0.8       -- a listing below 80% of the market price is an undercut
lib.BOOK_MAX_AGE = 2 * 86400 -- older order books are ignored (prices drift)
local MORE_UNITS = 500   -- load listings until this many units (or all of them)

lib.books = lib.books or {} -- itemID -> { t = time, full = bool, rows = { { p, q }, ... } } cheapest first

-- Keep order books across /reload in a table from your saved variables.
-- Books already recorded this session are moved into it; old ones dropped.
function lib.SetBookStore(store)
  for id, book in pairs(lib.books) do
    if not store[id] or store[id].t < book.t then store[id] = book end
  end
  local cutoff = time() - lib.BOOK_MAX_AGE
  for id, book in pairs(store) do
    if type(book) ~= "table" or not book.t or book.t < cutoff then store[id] = nil end
  end
  lib.books = store
end

-- The order book of an item, if one recorded recently.
function lib.Book(itemID)
  local book = itemID and lib.books[itemID]
  if book and time() - book.t <= lib.BOOK_MAX_AGE then return book end
end

-- The cheapest listing of an item on the AH: price, "AH" from Auctionator's
-- last seen price, else "book" from our own recent search; nil if neither.
function lib.SellPrice(itemID)
  local ah = lib.AHPrice(itemID)
  if ah then return ah, "AH" end
  local book = lib.Book(itemID)
  if book and book.rows[1] then return book.rows[1][1], "book" end
end

local function recordBook(itemID)
  local n = C_AuctionHouse.GetNumCommoditySearchResults and C_AuctionHouse.GetNumCommoditySearchResults(itemID)
  if not n then return end
  local rows = {}
  for i = 1, n do
    local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    -- Your own auctions aren't for sale to you.
    local q = info and (info.quantity or 0) - (info.numOwnerItems or 0)
    if q and q > 0 and info.unitPrice then rows[#rows + 1] = { info.unitPrice, q } end
  end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  local full = C_AuctionHouse.HasFullCommoditySearchResults and C_AuctionHouse.HasFullCommoditySearchResults(itemID)
  lib.books[itemID] = { t = time(), full = full and true or false, rows = rows }
end

-- The same for an item that isn't a commodity (gear and the like), from an
-- item search: each auction's buyout per unit. Returns how many listings
-- were recorded. An empty answer records nothing: a search by the plain
-- item ID can miss items the AH keys by item level, so it can't prove that
-- none are listed.
local function recordItemBook(itemKey)
  local itemID = itemKey and itemKey.itemID
  local n = itemID and C_AuctionHouse.GetNumItemSearchResults and C_AuctionHouse.GetNumItemSearchResults(itemKey)
  if not n then return 0 end
  local rows = {}
  for i = 1, n do
    local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    local q = info and info.quantity or 0
    if q > 0 and info.buyoutAmount and not info.containsOwnerItem then
      rows[#rows + 1] = { info.buyoutAmount / q, q }
    end
  end
  if #rows == 0 then return 0 end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  local full = C_AuctionHouse.HasFullItemSearchResults and C_AuctionHouse.HasFullItemSearchResults(itemKey)
  lib.books[itemID] = { t = time(), full = full and true or false, rows = rows }
  return #rows
end

-- What buying `quantity` of an item costs: total, info. info.src is
-- "vendor", "book" (walked a recent order book), "AH" (Auctionator's single
-- cheapest price) or "quote" (our quick scan's cheapest price, when
-- Auctionator has none); info.short = true when the book doesn't list that
-- many (the rest is priced at its dearest listing). nil when there's no
-- price at all, or a recent order book shows none for sale.
function lib.BuyCost(itemID, quantity, opts)
  local vendor = vendorPrice(itemID, opts)
  if vendor then return vendor * quantity, { src = "vendor" } end
  local book = lib.Book(itemID)
  if book and book.quote then
    local ah = lib.AHPrice(itemID)
    if ah then return ah * quantity, { src = "AH" } end
    if book.rows[1] then return book.rows[1][1] * quantity, { src = "quote" } end
    return nil, { src = "quote" }
  end
  if book then
    if #book.rows == 0 then return nil, { src = "book" } end
    local left, total, last = quantity, 0, 0
    for _, row in ipairs(book.rows) do
      local take = math.min(left, row[2])
      total, left, last = total + take * row[1], left - take, row[1]
      if left == 0 then break end
    end
    return total + left * last, { src = "book", short = left > 0 or nil }
  end
  local ah = lib.AHPrice(itemID)
  if ah then return ah * quantity, { src = "AH" } end
end

-- Undercut check from the order book: returns cheapest, market price (the
-- average of the cheapest MARKET_UNITS units) and how many units are listed
-- below UNDERCUT x market - or nil when there's no book or no undercut.
function lib.Undercut(itemID)
  local book = lib.Book(itemID)
  if not (book and book.rows[1]) or book.quote then return nil end
  local left, total, units = lib.MARKET_UNITS, 0, 0
  for _, row in ipairs(book.rows) do
    local take = math.min(left, row[2])
    total, units, left = total + take * row[1], units + take, left - take
    if left == 0 then break end
  end
  local market = total / units
  local below = 0
  for _, row in ipairs(book.rows) do
    if row[1] >= market * lib.UNDERCUT then break end
    below = below + row[2]
  end
  if below == 0 then return nil end
  return book.rows[1][1], market, below
end

-- Prices a recipe in place, for `crafts` crafts (default 1). Sets on each
-- reagent: price (average per unit for the amount needed), src, stale
-- (days), short, undercut ({ cheapest, market, below }); on the recipe:
-- cost (per craft), missing (reagents without a price), staleCount,
-- shortCount, undercut (a reagent is undercut), sell, productStale (days),
-- productUndercut, profit (exact copper, for all calculations),
-- displayProfit (Auctionator's rounding, for showing beside Auctionator),
-- margin (profit / cost), incomplete. opts: noVendor. Returns the recipe.
function lib.Evaluate(recipe, crafts, opts)
  crafts = crafts or 1
  local cost, missing, staleCount, shortCount, undercut = 0, 0, 0, 0, false
  for _, reagent in ipairs(recipe.reagents) do
    local total, info
    local amount = reagent.count * crafts
    if reagent.id then total, info = lib.BuyCost(reagent.id, amount, opts) end
    reagent.price = total and total / amount or nil
    reagent.src = info and info.src
    reagent.short = info and info.short
    reagent.stale = reagent.src == "AH" and lib.StaleDays(reagent.id) or nil
    local cheapest, market, below = nil, nil, nil
    if reagent.src == "book" then cheapest, market, below = lib.Undercut(reagent.id) end
    reagent.undercut = cheapest and { cheapest = cheapest, market = market, below = below } or nil
    if total then cost = cost + total / crafts else missing = missing + 1 end
    if reagent.stale then staleCount = staleCount + 1 end
    if reagent.short then shortCount = shortCount + 1 end
    if reagent.undercut then undercut = true end
  end
  recipe.cost, recipe.missing, recipe.staleCount, recipe.shortCount, recipe.undercut =
    cost, missing, staleCount, shortCount, undercut

  recipe.sell, recipe.productStale, recipe.productUndercut = nil, nil, nil
  recipe.profit, recipe.displayProfit, recipe.margin = nil, nil, nil
  if recipe.productID then
    local sellSrc
    recipe.sell, sellSrc = lib.SellPrice(recipe.productID)
    recipe.productStale = sellSrc == "AH" and lib.StaleDays(recipe.productID) or nil
    local cheapest, market, below = lib.Undercut(recipe.productID)
    recipe.productUndercut = cheapest and { cheapest = cheapest, market = market, below = below } or nil
    if recipe.sell then
      recipe.profit = lib.ExactProfit(recipe.sell, recipe.made or 1, cost)
      recipe.displayProfit = lib.CraftProfit(recipe.sell, recipe.made or 1, cost)
      recipe.margin = cost > 0 and recipe.profit / cost or nil
    end
  end
  recipe.incomplete = missing > 0 or staleCount > 0 or shortCount > 0 or recipe.productStale ~= nil
  return recipe
end

------------------------------------------------------------------------------
-- Searching the AH
------------------------------------------------------------------------------

local function ahOpen()
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown())
end

-- Searches the AH for the latest price of each item, as one Auctionator
-- multi-search (results show in its Shopping tab). Skips vendor-sold items
-- (their vendor price is always used) and, unless opts.force, items already
-- seen today. items: { { id = itemID | nil, name = itemName }, ... }.
-- opts.caller: your addon's name; opts.noVendor: search vendor-sold too. Returns how many names were searched, or
-- nil + reason.
function lib.Search(items, opts)
  opts = opts or {}
  local api = auctionator()
  if not (api and api.MultiSearchExact) then return nil, "Auctionator isn't loaded." end
  if not ahOpen() then return nil, "Open the auction house first." end
  local names, seen = {}, {}
  for _, item in ipairs(items) do
    local name = item.name
    -- Auctionator rejects terms with ; or ^ in them.
    if name and name ~= "" and not name:find("[;^\"]") and not seen[name] then
      local skip = item.id and (vendorPrice(item.id, opts) or (not opts.force and lib.PriceAge(item.id) == 0))
      if not skip then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  if #names == 0 then return 0 end
  local ok, err = pcall(api.MultiSearchExact, opts.caller or CALLER, names)
  if not ok then return nil, tostring(err) end
  return #names
end

-- Order-book scan: one search per item, one at a time, as the AH allows. Searches for items whose AH details aren't cached are ignored by
-- the game, so each waits for its details first; an answer with no results
-- is asked again once (the AH sometimes sends an empty answer by mistake).
local SEARCH_TIMEOUT, CACHE_TRIES = 5, 10
local bookScan

-- Scan timing goes to DevLog when it's installed (/devlog to view), for
-- tuning: each item as it's answered, and a summary at the end.
local function log(...)
  if DevLog then DevLog.Log(MAJOR, ...) end
end

local function itemName(id)
  return ((C_Item and C_Item.GetItemInfo or GetItemInfo)(id)) or "?"
end

local function newStats()
  return { start = GetTime(), searches = 0, emptyRetries = 0, timeouts = 0, morePages = 0,
    throttleWait = 0, infoWait = 0, answers = {}, items = {} }
end

local function finishBooks(reason)
  local scan = bookScan
  if not scan then return end
  bookScan = nil
  local st = scan.stats
  local seconds = GetTime() - st.start
  log(("scan %s: %d of %d items in %.0fs (%.1fs each)"):format(reason, scan.done, #scan.queue, seconds,
    seconds / math.max(scan.done, 1)))
  log(("  %d searches: %d retried after an empty answer, %d timed out, %d extra pages"):format(
    st.searches, st.emptyRetries, st.timeouts, st.morePages))
  log(("  waited %.0fs for the AH to accept a search, %.0fs for item info"):format(st.throttleWait, st.infoWait))
  log("  answers", st.answers)
  table.sort(st.items, function(a, b) return a.seconds > b.seconds end)
  for i = 1, math.min(10, #st.items) do
    local item = st.items[i]
    log(("  slow: %s (%d) %s %.1fs"):format(itemName(item.id), item.id, item.how, item.seconds))
  end
  if scan.onDone then pcall(scan.onDone, reason, scan.done, #scan.queue) end
end

local nextBook
-- how: "commodity" | "item" | "item, none listed" | "timed out"
local function bookAnswered(id, how)
  local scan = bookScan
  local stats = scan.stats
  stats.answers[how] = (stats.answers[how] or 0) + 1
  local started = scan.started and scan.started[id]
  if started then
    local seconds = GetTime() - started
    stats.items[#stats.items + 1] = { id = id, how = how, seconds = seconds }
    log(("%d/%d %s (%d): %s, %.1fs"):format(scan.index, #scan.queue, itemName(id), id, how, seconds))
  end
  scan.waiting = nil
  scan.done = scan.done + 1
  if scan.onProgress then pcall(scan.onProgress, scan.index, #scan.queue) end
  nextBook()
end

nextBook = function()
  local scan = bookScan
  if not scan or scan.waiting then return end
  if not ahOpen() then finishBooks("closed") return end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    scan.throttledSince = scan.throttledSince or GetTime()
    if not scan.retryPending then -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY normally resumes us
      scan.retryPending = true
      C_Timer.After(0.5, function()
        if bookScan == scan then scan.retryPending = false; nextBook() end
      end)
    end
    return
  end
  if scan.throttledSince then
    scan.stats.throttleWait = scan.stats.throttleWait + GetTime() - scan.throttledSince
    scan.throttledSince = nil
  end
  local id = scan.queue[scan.index + 1]
  if not id then finishBooks("done") return end
  local key = C_AuctionHouse.MakeItemKey(id)
  if not C_AuctionHouse.GetItemKeyInfo(key) then -- asks the game for the details
    scan.stats.infoWait = scan.stats.infoWait + 0.3
    scan.cacheTries = (scan.cacheTries or 0) + 1
    if scan.cacheTries <= CACHE_TRIES then
      C_Timer.After(0.3, function() if bookScan == scan then nextBook() end end)
      return
    end
  end
  scan.cacheTries = nil
  scan.index = scan.index + 1
  local waiting = { id = id, retried = scan.waitingRetry == id }
  scan.waiting, scan.waitingRetry = waiting, nil
  scan.started[id] = scan.started[id] or GetTime()
  scan.stats.searches = scan.stats.searches + 1
  C_AuctionHouse.SendSearchQuery(key, { { sortOrder = 0, reverseSort = false } }, false) -- sortOrder 0: price
  C_Timer.After(SEARCH_TIMEOUT, function()
    if bookScan ~= scan or scan.waiting ~= waiting then return end
    scan.stats.timeouts = scan.stats.timeouts + 1
    log(("timed out: %s (%d)%s"):format(itemName(id), id, waiting.retried and "" or ", asking again"))
    if not waiting.retried then -- ask once more
      scan.waiting, scan.waitingRetry, scan.index = nil, id, scan.index - 1
      nextBook()
    else
      bookAnswered(id, "timed out")
    end
  end)
end

local function onCommodityResults(itemID)
  recordBook(itemID)
  local scan = bookScan
  if not (scan and scan.waiting and scan.waiting.id == itemID) then return end
  local has = C_AuctionHouse.HasSearchResults(C_AuctionHouse.MakeItemKey(itemID))
  local full = C_AuctionHouse.HasFullCommoditySearchResults(itemID)
  local quantity = C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID) or 0
  if (not has or (not full and quantity == 0)) and not scan.waiting.retried then
    scan.stats.emptyRetries = scan.stats.emptyRetries + 1
    scan.waiting, scan.waitingRetry, scan.index = nil, itemID, scan.index - 1 -- the empty-answer glitch
    nextBook()
  elseif not full and quantity < MORE_UNITS and C_AuctionHouse.RequestMoreCommoditySearchResults then
    scan.stats.morePages = scan.stats.morePages + 1
    C_AuctionHouse.RequestMoreCommoditySearchResults(itemID) -- answered by another results event
  else
    bookAnswered(itemID, "commodity")
  end
end

-- Records the order book of each item (skips vendor-sold items): commodities
-- by commodity search, anything else by item search. Runs in the background;
-- the AH's browse list isn't touched. Needs the AH open (opts.noVendor:
-- vendor-sold ones too). opts.onProgress(done, total), opts.onDone(reason,
-- done, total), reason "done" | "closed" | "cancelled". Returns the number of
-- items to search, or nil + reason.
function lib.ScanBooks(itemIDs, opts)
  opts = opts or {}
  if bookScan or quickScan then return nil, "Another scan is already running." end
  if not (C_AuctionHouse and C_AuctionHouse.SendSearchQuery and C_AuctionHouse.MakeItemKey) then
    return nil, "This client's auction house has no item search."
  end
  if not ahOpen() then return nil, "Open the auction house first." end
  local queue, seen = {}, {}
  for _, id in ipairs(itemIDs) do
    if id and not seen[id] and not vendorPrice(id, opts) then
      seen[id] = true
      queue[#queue + 1] = id
    end
  end
  if #queue == 0 then return 0 end
  bookScan = { queue = queue, index = 0, done = 0, onProgress = opts.onProgress, onDone = opts.onDone,
    started = {}, stats = newStats() }
  log(("scan started: %d items"):format(#queue))
  nextBook()
  return #queue
end

function lib.IsScanningBooks() return bookScan ~= nil end
function lib.CancelBookScan() finishBooks("cancelled") end

------------------------------------------------------------------------------
-- Quick scan: up to QUICK_BATCH items per search (SearchForItemKeys), for
-- each item's cheapest price and how many are listed - not every listing.
-- Each is recorded as a "quote": a one-row book (rows = { { cheapest,
-- quantity } }, or none when nobody lists it) with quote = true. A quote
-- never replaces a full book under an hour old, and doesn't count for
-- undercuts. The answers arrive as the AH's browse results, so this
-- REPLACES the browse list on screen; put the player's search back after.
------------------------------------------------------------------------------

local QUICK_BATCH, QUICK_TIMEOUT, QUICK_PAGES, QUICK_RETRIES = 25, 10, 10, 3
local quickScan

local function finishQuick(reason)
  local q = quickScan
  if not q then return end
  quickScan = nil
  local seconds = GetTime() - q.start
  log(("quick scan %s: %d of %d items in %.1fs, %d searches (%d resent), %d listed, %d none listed, %d no answer")
    :format(reason, q.pos, #q.queue, seconds, q.searches, q.resent, q.listed, q.unlisted, q.missed))
  if q.onDone then pcall(q.onDone, reason, q.pos, #q.queue) end
end

local function recordQuote(itemID, price, quantity, now)
  local old = lib.books[itemID]
  if old and not old.quote and now - old.t < 3600 then return end -- keep a recent full book
  lib.books[itemID] = { t = now, full = true, quote = true, rows = price and { { price, quantity } } or {} }
end

local sendQuick

local function quickBatchDone(timedOut)
  local q = quickScan
  if not (q and q.batch) then return end
  local batch = q.batch
  local inBatch = {}
  for _, id in ipairs(batch) do inBatch[id] = true end
  -- The results must be ours: another search (the AH's own, another
  -- addon's) can land instead. Then wait a moment and ask again.
  if not timedOut then
    for _, res in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
      local id = res.itemKey and res.itemKey.itemID
      if id and not inBatch[id] then
        q.batch = nil
        q.tries = (q.tries or 0) + 1
        if q.tries <= QUICK_RETRIES then
          q.resent = q.resent + 1
          log("quick scan: other results arrived, asking again")
          C_Timer.After(1.5, function() if quickScan == q then sendQuick() end end)
          return
        end
        timedOut = true -- keep getting other results: leave this batch unpriced
        break
      end
    end
  end
  q.tries = nil

  local cheapest, quantity = {}, {}
  if not timedOut then
    for _, res in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
      local id = res.itemKey and res.itemKey.itemID
      if id and inBatch[id] and res.minPrice and res.minPrice > 0 then
        if not cheapest[id] or res.minPrice < cheapest[id] then cheapest[id] = res.minPrice end
        quantity[id] = (quantity[id] or 0) + (res.totalQuantity or 0)
      end
    end
  end
  local now = time()
  for _, id in ipairs(batch) do
    if cheapest[id] then
      recordQuote(id, cheapest[id], quantity[id], now)
      q.listed = q.listed + 1
    elseif timedOut then
      q.missed = q.missed + 1 -- no answer: keep what we had
    else
      recordQuote(id, nil, 0, now) -- nobody is selling it
      q.unlisted = q.unlisted + 1
    end
  end
  log(("quick batch %d-%d: %s in %.1fs"):format(q.pos + 1, q.pos + #batch,
    timedOut and "no answer" or "answered", GetTime() - q.sentAt))
  q.pos = q.pos + #batch
  q.batch = nil
  if q.onProgress then pcall(q.onProgress, q.pos, #q.queue) end
  C_Timer.After(0.2, function() if quickScan == q then sendQuick() end end)
end

sendQuick = function()
  local q = quickScan
  if not q or q.batch then return end
  if not ahOpen() then finishQuick("closed") return end
  if q.pos >= #q.queue then finishQuick("done") return end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    if not q.retryPending then -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY normally resumes us
      q.retryPending = true
      C_Timer.After(0.5, function()
        if quickScan == q then q.retryPending = false; sendQuick() end
      end)
    end
    return
  end
  local batch, keys = {}, {}
  for i = q.pos + 1, math.min(q.pos + QUICK_BATCH, #q.queue) do
    batch[#batch + 1] = q.queue[i]
    keys[#keys + 1] = C_AuctionHouse.MakeItemKey(q.queue[i])
  end
  q.batch, q.pages, q.sentAt = batch, 0, GetTime()
  q.searches = q.searches + 1
  local sorts = {}
  if Enum and Enum.AuctionHouseSortOrder then
    sorts[1] = { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }
  end
  C_AuctionHouse.SearchForItemKeys(keys, sorts)
  C_Timer.After(QUICK_TIMEOUT, function()
    if quickScan == q and q.batch == batch then quickBatchDone(true) end
  end)
end

-- Browse results came in: wait a moment for the rest, load any further
-- pages, then read them.
local quickToken = 0
local function onQuickResults()
  local q = quickScan
  if not (q and q.batch) then return end
  quickToken = quickToken + 1
  local token = quickToken
  C_Timer.After(0.5, function()
    if token ~= quickToken or quickScan ~= q or not q.batch then return end
    if not C_AuctionHouse.HasFullBrowseResults() and q.pages < QUICK_PAGES then
      q.pages = q.pages + 1
      C_AuctionHouse.RequestMoreBrowseResults() -- answered by another results event
      return
    end
    quickBatchDone(false)
  end)
end

-- Prices each item (skips vendor-sold ones unless opts.noVendor) with
-- batched searches. Needs the AH open, and no other scan running.
-- opts.onProgress(done, total), opts.onDone(reason, done, total), reason
-- "done" | "closed" | "cancelled". Returns the number of items to price, or
-- nil + reason.
function lib.QuickScan(itemIDs, opts)
  opts = opts or {}
  if quickScan or bookScan then return nil, "Another scan is already running." end
  if not (C_AuctionHouse and C_AuctionHouse.SearchForItemKeys and C_AuctionHouse.MakeItemKey) then
    return nil, "This client's auction house can't search for several items at once."
  end
  if not ahOpen() then return nil, "Open the auction house first." end
  local queue, seen = {}, {}
  for _, id in ipairs(itemIDs) do
    if id and not seen[id] and not vendorPrice(id, opts) then
      seen[id] = true
      queue[#queue + 1] = id
    end
  end
  if #queue == 0 then return 0 end
  quickScan = { queue = queue, pos = 0, start = GetTime(), searches = 0, resent = 0, listed = 0, unlisted = 0,
    missed = 0, onProgress = opts.onProgress, onDone = opts.onDone }
  log(("quick scan started: %d items"):format(#queue))
  sendQuick()
  return #queue
end

function lib.IsQuickScanning() return quickScan ~= nil end
function lib.CancelQuickScan() finishQuick("cancelled") end

------------------------------------------------------------------------------
-- Events. "PricesUpdated" fires a moment after AH results arrive, once
-- Auctionator has had the chance to store them.
------------------------------------------------------------------------------

lib.frame = lib.frame or CreateFrame("Frame")
lib.frame:UnregisterAllEvents()
for _, event in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_ITEM_LIST_UPDATE",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_CLOSED" }) do
  pcall(lib.frame.RegisterEvent, lib.frame, event)
end
local pending = false
lib.frame:SetScript("OnEvent", function(_, event, arg)
  if event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    nextBook()
    sendQuick()
    return
  elseif event == "AUCTION_HOUSE_CLOSED" then
    finishBooks("closed")
    finishQuick("closed")
    return
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    onQuickResults()
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    onCommodityResults(arg)
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and type(arg) == "table" then
    -- Not a commodity: its auctions' buyouts make the book.
    local listed = recordItemBook(arg)
    local scan = bookScan
    if scan and scan.waiting and arg.itemID == scan.waiting.id then
      bookAnswered(arg.itemID, listed > 0 and "item" or "item, none listed")
    end
  end
  if pending then return end
  pending = true
  C_Timer.After(1, function()
    pending = false
    lib.callbacks:Fire("PricesUpdated")
  end)
end)

-- LibCraftProfit-1.0: crafting cost and profit from Auctionator's prices.
-- Shared by ProfessionProfit and RecipeProfit, embedded via LibStub. It keeps
-- no saved data: Auctionator owns the prices (AH and vendor).
--
-- Recipe shape used throughout:
--   { made = n, productID = itemID | nil,
--     reagents = { { id = itemID | nil, count = n, name = string | nil }, ... } }
--
-- Callbacks (lib.RegisterCallback(owner, event, handler)):
--   "PricesUpdated"  AH results came in (Auctionator has stored new prices).

local MAJOR, MINOR = "LibCraftProfit-1.0", 1
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

-- What one unit of a reagent costs to buy: price, "vendor" | "AH".
function lib.BuyPrice(itemID)
  local vendor = lib.VendorPrice(itemID)
  if vendor then return vendor, "vendor" end
  local ah = lib.AHPrice(itemID)
  if ah then return ah, "AH" end
end

-- Profit of one craft, in exact copper: what `made` items sell for after
-- the AH cut, minus the reagent cost.
function lib.ExactProfit(sell, made, cost)
  return sell * made * (1 - lib.AH_CUT) - cost
end

-- The same, rounded down to the whole silver like Auctionator shows it.
function lib.CraftProfit(sell, made, cost)
  return math.floor(math.floor(lib.ExactProfit(sell, made, cost)) / 100) * 100
end

-- Prices a recipe in place. Sets on each reagent: price, src, stale (days);
-- on the recipe: cost, missing (reagents without a price), staleCount, sell,
-- productStale (days), profit, margin, incomplete. Returns the recipe.
function lib.Evaluate(recipe)
  local cost, missing, staleCount = 0, 0, 0
  for _, reagent in ipairs(recipe.reagents) do
    local price, src
    if reagent.id then price, src = lib.BuyPrice(reagent.id) end
    reagent.price, reagent.src = price, src
    reagent.stale = src == "AH" and lib.StaleDays(reagent.id) or nil
    if price then cost = cost + price * reagent.count else missing = missing + 1 end
    if reagent.stale then staleCount = staleCount + 1 end
  end
  recipe.cost, recipe.missing, recipe.staleCount = cost, missing, staleCount

  recipe.sell, recipe.productStale, recipe.profit, recipe.margin = nil, nil, nil, nil
  if recipe.productID then
    recipe.sell = lib.AHPrice(recipe.productID)
    recipe.productStale = lib.StaleDays(recipe.productID)
    if recipe.sell then
      recipe.profit = lib.CraftProfit(recipe.sell, recipe.made or 1, cost)
      recipe.margin = cost > 0 and recipe.profit / cost or nil
    end
  end
  recipe.incomplete = missing > 0 or staleCount > 0 or recipe.productStale ~= nil
  return recipe
end

------------------------------------------------------------------------------
-- Searching the AH (through Auctionator, which stores what it finds)
------------------------------------------------------------------------------

local function ahOpen()
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown())
end

-- Searches the AH for the latest price of each item, as one Auctionator
-- multi-search (results show in its Shopping tab). Skips vendor-sold items
-- (their vendor price is always used) and, unless opts.force, items already
-- seen today. items: { { id = itemID | nil, name = itemName }, ... }.
-- opts.caller: your addon's name. Returns how many names were searched, or
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
      local skip = item.id and (lib.VendorPrice(item.id) or (not opts.force and lib.PriceAge(item.id) == 0))
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

------------------------------------------------------------------------------
-- "PricesUpdated": fired a moment after AH results arrive, once Auctionator
-- has had the chance to store them.
------------------------------------------------------------------------------

lib.frame = lib.frame or CreateFrame("Frame")
lib.frame:UnregisterAllEvents()
for _, event in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_ITEM_LIST_UPDATE" }) do
  pcall(lib.frame.RegisterEvent, lib.frame, event)
end
local pending = false
lib.frame:SetScript("OnEvent", function()
  if pending then return end
  pending = true
  C_Timer.After(1, function()
    pending = false
    lib.callbacks:Fire("PricesUpdated")
  end)
end)

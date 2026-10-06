# LibCraftProfit-1.0

Crafting cost and profit from [Auctionator](https://www.curseforge.com/wow/addons/auctionator)'s prices, shared by
[ProfessionProfit](https://github.com/TLWoodJr/ProfessionProfit) and [RecipeProfit](https://github.com/TLWoodJr/RecipeProfit).
Embedded with LibStub; holds no saved data (Auctionator owns the prices).

```lua
local Lib = LibStub("LibCraftProfit-1.0")
Lib.Evaluate(recipe)          -- recipe = { made, productID, reagents = { { id, count, name }, ... } }
Lib.BuyPrice(itemID)          -- price, "vendor" | "AH"
Lib.Search(items, { caller = "MyAddon" })  -- one Auctionator multi-search for { { id, name }, ... }
Lib.RegisterCallback(owner, "PricesUpdated", handler)
```

## Embedding

`.pkgmeta`:

```yaml
externals:
  Libs/LibStub: https://repos.wowace.com/wow/libstub/trunk
  Libs/CallbackHandler-1.0: https://repos.wowace.com/wow/callbackhandler/trunk/CallbackHandler-1.0
  Libs/LibCraftProfit-1.0: https://github.com/TLWoodJr/LibCraftProfit-1.0
```

TOC:

```
## Dependencies: Auctionator
## OptionalDeps: LibCraftProfit-1.0
Libs\LibStub\LibStub.lua
Libs\CallbackHandler-1.0\CallbackHandler-1.0.lua
Libs\LibCraftProfit-1.0\lib.xml
```

## Development

Clone this repo into `Interface/AddOns/LibCraftProfit-1.0`. It loads as its own addon, before the addons that list it in
`OptionalDeps`, and LibStub keeps the copy with the highest `MINOR` - so bump `MINOR` with every change you push.

if onServer() then
    local Azimuth = include("azimuthlib-basic")
    local PVPScannerConfig = Azimuth.loadConfig("PVPScanner", {
      ["UpgradeWeight"] = {default = 0.5, min = 0, max = 1000, comment = "Relative chance of getting this upgrade from 0.0 to 1000."}
    })
    UpgradeGenerator.add("data/scripts/systems/pvpscanner.lua", PVPScannerConfig.UpgradeWeight)
else -- just in case
    UpgradeGenerator.add("data/scripts/systems/pvpscanner.lua", 0.5)
end
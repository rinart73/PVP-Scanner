package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/systems/?.lua"
include("basesystem")
include("stringutility")
include("randomext")
include("utility")
include("callable")
local Azimuth = include("azimuthlib-basic")
if not Azimuth then return end
local Log, config

-- optimization so that energy requirement doesn't have to be read every frame
FixedEnergyRequirement = true

--data
local seed, rarity, permanent
local isScanning = false
local scanningProgress = 0
local playerList
local foundPlayers = {}
local additionalEnergyUsage = 0
local myRandom  = Random(Seed(appTimeMs()))
local origProductionRate = 0

--UI
local uiInitialized = false
local window
local nameList = {}
local coordList = {}
local labelcontent = {}
local scanButton
local progressBar
local oldLabelList = {}
local fakeUpdateCounter = 0

local old_initialize = initialize
function initialize(seed, rarity, permanent_in)
    old_initialize(seed, rarity, permanent_in)
    -- load config
    local configOptions = {
      _version = {default = "1.2", comment = "Config version. Don't touch"},
      LogLevel = {default = 2, min = 0, max = 4, format = "floor", comment = "0 - Disable, 1 - Errors, 2 - Warnings, 3 - Info, 4 - Debug."}
    }
    if onClient() then
        configOptions["UIRows"] = {default = 15, min = 1, max = 100, format = "floor", comment = "Amount of UI rows for displaying players."}
    else
        configOptions["GeneratedEnergyDebuff"] = {default = 0.5, min = 0, max = 1, comment = "Reduce energy generation while scanning. 1 to disable."}
        configOptions["ShieldDurabilityDebuff"] = {default = 0.5, min = 0, max = 1, comment = "Reduce shield current durability when scanning starts. 1 to disable."}
        configOptions["HyperspaceCooldownDebuff"] = {default = 50, min = 0, format = "floor", comment = "Apply hyperspace cooldown when scanning starts. 0 to disable."}
        configOptions["ScanningTime"] = {default = 25, min = 1, max = 100, comment = "How long in seconds scanning will take."}
        configOptions["PVPZoneRange"] = {default = -1, min = -1, comment = "System only detects players in PVP area. Here you can specify PVP area radius from center of galaxy. -1 means that system can detect players anywhere."}
        -- Currently disabled because of the 'Server().folder' bug
        --configOptions["UpgradeWeight"] = {default = 0.5, min = 0, max = 1000, comment = "Relative chance of getting this upgrade from 0.0 to 1000."}
    end
    local isModified
    config, isModified = Azimuth.loadConfig("PVPScanner", configOptions)
    if isModified then
        Azimuth.saveConfig("PVPScanner", config, configOptions)
    end
    Log = Azimuth.logs("PVPScanner", config.LogLevel)

    -- If scanner was started and then the game was closed or sector was unloaded, we'll need to remove energy production debuff
    if onServer() then
        restoreProductionRate()
    end
end

function onInstalled(pSeed, pRarity, pPermanent)
    seed, rarity, permanent = pSeed, pRarity, pPermanent
    if onServer() then
        -- When user get moved in other sector while scanning, search MUST be stopped
        Entity():registerCallback("onJump", "stopScanning")
    else
        -- Just update the button tooltip
        if scanButton then
            scanButton.tooltip = string.format("Scan up to %i sectors away."%_t, getPlayerScannerRange(seed, rarity, permanent))
        end
    end
end

function onUninstalled(seed, rarity, permanent)
    if onServer() and isScanning then
        restoreProductionRate()
    end
end

function interactionPossible(playerIndex, option)
    return Player(playerIndex).craft.index == Entity().index
end

-- create all required UI elements for the client side
function initUI()
    -- UI should be created immediately, we can update button tooltip later
    local res = getResolution()
    local size = vec2(800, 600)

    local menu = ScriptUI()
    window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    menu:registerWindow(window, "Scan for players"%_t)

    window.caption = "Player Scanner"%_t
    window.showCloseButton = 1
    window.moveable = 1

    local size = window.size

    local scanButtonSize = 200
    local y = 20
    local buttonRect = Rect(size.x / 2 - scanButtonSize / 2 - 15, y, size.x / 2 + scanButtonSize / 2 - 15, y + 35)
    scanButton = window:createButton(buttonRect, "Start Scanning"%_t, "onStartScanning")
    if seed then
        scanButton.tooltip = string.format("Scan up to %i sectors away."%_t, getPlayerScannerRange(seed, rarity, permanent))
    end
    y = y + 45

    local rect = Rect(size.x / 2 - scanButtonSize - 15, size.y - 20 - 25, size.x / 2 + scanButtonSize - 15, size.y - 20)
    progressBar = window:createNumbersBar(rect)
    progressBar:setRange(0, 1) -- Receive ScanningTime later from server

    uiInitialized = true
    -- Create player rows
    local nameLabelSizeX = 400
    local coordLabelSize = 150
    local oldnameLabel, nameLabel, coordLabel
    for i = 1, config.UIRows do
        oldnameLabel = window:createLabel(vec2(10, y+1), "", 15)
        oldnameLabel.color = ColorARGB(0.9, 0.1, 0.5, 0.1)
        oldnameLabel.size = vec2(nameLabelSizeX, 25)
        oldnameLabel.wordBreak = false

        nameLabel = window:createLabel(vec2(10, y), "", 15)
        nameLabel.color = ColorARGB(1.0, 0.1, 0.8, 0.1)
        nameLabel.size = vec2(nameLabelSizeX, 25)
        nameLabel.caption = ""
        nameLabel.wordBreak = false

        coordLabel = window:createLabel(vec2(nameLabelSizeX + 10 + 20, y), "", 15)
        coordLabel.tooltip = nil
        coordLabel.mouseDownFunction = ""
        coordLabel.size = vec2(coordLabelSize, 25)
        coordLabel.mouseDownFunction = "onCoordClicked"

        oldLabelList[#oldLabelList+1] = oldnameLabel
        nameList[#nameList+1] = nameLabel
        coordList[#coordList+1] = coordLabel
        y = y + 35
    end
end

function getName(seed, rarity)
    return "Player Scanner"%_t
end

function getIcon(seed, rarity)
    return "data/textures/icons/aggressive.png"
end

function getEnergy(seed, rarity, permanent)
    math.randomseed(seed)
    local scannerRange = getPlayerScannerRange(seed, rarity, permanent)
    local energy = scannerRange * 1e8 + scannerRange * 1e6 * (math.random() + 0.5)
    return energy * 4.5 ^ rarity.value + additionalEnergyUsage
end

function getPrice(seed, rarity)
    math.randomseed(seed)
    local scannerRange = getPlayerScannerRange(seed, rarity, false)
    local price = scannerRange * 1e4 + scannerRange * 1e4 * (math.random() + 0.5)
    return price * 2.5 ^ rarity.value
end

function getPlayerBonusScannerRange(seed, rarity, permanent)
    if not permanent then return 0 end

    math.randomseed(seed)
    local range = math.floor((3 * rarity.value + 2 + math.random() * 3) / 2)
    if range < 0 then
        range = 0
    end
    return range
end

function getPlayerScannerRange(seed, rarity, permanent)
    math.randomseed(seed)
    local range = 3 * rarity.value + 3 + math.floor(math.random() * 2.5 + 0.5)
    if range <= 0 then
        range = 1
    end
    return range + getPlayerBonusScannerRange(seed, rarity, permanent)
end

function getTooltipLines(seed, rarity, permanent)
    local texts = {}
    local bonuses = {}

    table.insert(texts, {ltext = "Player scanning range"%_t, rtext = getPlayerScannerRange(seed, rarity, permanent), icon = "data/textures/icons/rss.png", boosted = permanent})
    table.insert(bonuses, {ltext = "Player scanning range"%_t, rtext = "+"..getPlayerBonusScannerRange(seed, rarity, true), icon = "data/textures/icons/rss.png"})

    return texts, bonuses
end

function getDescriptionLines(seed, rarity, permanent)
    return
    {
      {ltext = "Adds a scanner for Players."%_t, rtext = "", icon = ""}
    }
end

-- Reduce update rate. We don't want to kill server performance
if onClient() then

  function getUpdateInterval()
      return 0.25
  end

else -- onServer

  function getUpdateInterval()
      return 1
  end

end

-- Moving name and coordinates 'decoding' to the serverside, otherwise it's super easy to cheat
function updateServer(timestep)
    if not isScanning then return end

    -- scan lasts longer when there is not enough energy
    local energySystem = EnergySystem()
    local step = timestep
    if energySystem.consumableEnergy == 0 then
        -- multiplier value depending on energy: 0.05 - 1
        local multiplier = math.max(1 - ((energySystem.requiredEnergy - energySystem.productionRate) / (origProductionRate * 0.5)), 0.05)
        multiplier = math.min(multiplier, 1)
        step = timestep * multiplier
    end
    scanningProgress = scanningProgress + step
    if scanningProgress >= config.ScanningTime then
        -- stop scanning
        stopScanning()
        scanningProgress = config.ScanningTime
    end
    local percProgress = scanningProgress / config.ScanningTime

    local foundIndex, dX, dY
    if playerList then
        for i, playerData in ipairs(playerList) do
            if playerList[i].foundIndex then
                foundIndex = playerList[i].foundIndex

                foundPlayers[foundIndex].name = getRandomName(playerData.name, foundPlayers[foundIndex].name, percProgress)
                dX, dY = getRandomCoord(playerData.x, playerData.y, foundPlayers[foundIndex].x, foundPlayers[foundIndex].y, percProgress)
                foundPlayers[foundIndex].x = dX
                foundPlayers[foundIndex].y = dY
                foundPlayers[foundIndex].correct = (dX == playerData.x and dY == playerData.y)
                foundPlayers[foundIndex].correctName = foundPlayers[foundIndex].name == playerData.name

                Log.Debug("updateServer - decode: %s (%i:%i)", foundPlayers[foundIndex].name, dX, dY)
            elseif findPlayer(i, percProgress) then
                foundPlayers[#foundPlayers+1] = {}
                playerList[i].foundIndex = #foundPlayers
                foundIndex = playerList[i].foundIndex
                
                foundPlayers[foundIndex].name = getRandomName(playerData.name, nil, percProgress)
                dX, dY = getRandomCoord(playerData.x, playerData.y, nil, nil, percProgress)
                foundPlayers[foundIndex].x = dX
                foundPlayers[foundIndex].y = dY
                foundPlayers[foundIndex].correct = (dX == playerData.x and dY == playerData.y)
                foundPlayers[foundIndex].correctName = foundPlayers[foundIndex].name == playerData.name

                Player(playerData.index):sendChatMessage("", 2, "Another ship located your position!"%_t)
                Log.Debug("updateServer - register: %s (%i:%i)", foundPlayers[foundIndex].name, dX, dY)
            end
        end
    end
    if percProgress >= 1 then
        -- notify ship pilots on finish
        for _, playerId in pairs({Entity():getPilotIndices()}) do
            invokeClientFunction(Player(playerId), "receivePlayersInRange", foundPlayers, scanningProgress, config.ScanningTime, origProductionRate)
        end
    end
end

-- Moving name and coordinates 'decoding' to the serverside, otherwise it's super easy to cheat
function updateClient(timestep)
    if Player().craft.index ~= Entity().index then return end
    if not isScanning then return end

    -- request decoded data
    if fakeUpdateCounter == 0 then
        invokeServerFunction("getPlayersInRange")
    else -- perform fake updates between real ones to make 'decoding' look smoother
        fakeUpdate(timestep)
    end

    fakeUpdateCounter = fakeUpdateCounter + timestep
    if fakeUpdateCounter >= 1 then
        fakeUpdateCounter = 0
    end
end

function fakeUpdate(timestep)
    local energySystem = EnergySystem()
    local step = timestep
    if energySystem.consumableEnergy == 0 then
        -- multiplier value depending on energy: 0.05 - 1
        local multiplier = math.max(1 - ((energySystem.requiredEnergy - energySystem.productionRate) / (origProductionRate * 0.5)), 0.05)
        multiplier = math.min(multiplier, 1)
        step = timestep * multiplier
    end
    scanningProgress = scanningProgress + step
    
    local percProgress = scanningProgress / config.ScanningTime

    Log.Debug("Fake update")
    -- update UI
    progressBar:clear()
    progressBar:setRange(0, config.ScanningTime)
    progressBar:addEntry(scanningProgress, string.format("Progress: %i%%"%_t, round(percProgress * 100, 2)), ColorARGB(0.9, 1 - percProgress, percProgress, 0.1))

    if foundPlayers then
        local oldnameLabel, nameLabel, coordLabel, pseudoName, playerName, pseudoX, pseudoY, dX, dY
        for i, playerData in ipairs(foundPlayers) do
            local coordIndex = coordList[i].index

            oldnameLabel = oldLabelList[i]
            nameLabel = nameList[i]
            coordLabel = coordList[i]

            if playerData.correctName then
                playerName = playerData.name
                oldnameLabel.caption = ""
            else
                playerName = getRandomName(playerData.name, nil, 0.7 + percProgress / 5)
                oldnameLabel.caption = playerData.name
            end
            nameLabel.caption = playerData.name

            if playerData.correct then -- no need to make everything complicated if RNG found the coordinates already
                dX, dY = playerData.x, playerData.y
                coordLabel.color = ColorRGB(0.3, 0.9, 0.1)
            else
                dX, dY = getRandomCoord(playerData.x, playerData.y, nil, nil, 0.7 + percProgress / 5)
                coordLabel.color = ColorRGB(1.0, 1.0, 1.0)
            end
            coordLabel.caption = "("..dX..":"..dY..")"
            coordLabel.tooltip = string.format("Click to show %s on Galaxy Map"%_t, playerName)

            if labelcontent[coordIndex] then
                labelcontent[coordIndex].x = dX
                labelcontent[coordIndex].y = dY
            end

            oldnameLabel.visible = true
            nameLabel.visible = true
            coordLabel.visible = true
        end
        -- hide other rows
        for i = #foundPlayers+1, config.UIRows do
            oldLabelList[i].visible = false
            nameList[i].visible = false
            coordList[i].visible = false
        end
    end
end

function findPlayer(i, percProgress)
    return myRandom:getFloat(0.0, 1.0)-0.7 > (0.5-percProgress)
end

function getRandomCoord(pX, pY, lastX, lastY, percProgress)
    lastX = lastX or myRandom:getInt(-500,500)
    lastY = lastY or myRandom:getInt(-500,500)
    local x, y
    if percProgress > 0.2 then
        if pX ~= lastX then
            local dist = math.min(50, math.sqrt(pX^2 - lastX^2))
            dist = dist * (1 - percProgress)
            x = myRandom:getInt(pX - dist, pX + dist)
        else
            x = pX
        end

        if pY ~= lastY then
            local dist = math.min(50, math.sqrt(pY^2-lastY^2))
            dist = dist * (1 - percProgress)
            y = myRandom:getInt(pY - dist, pY + dist)
        else
            y = pY
        end
    else
        x,y = myRandom:getInt(-500,500), myRandom:getInt(-500,500)
    end

    return x, y
end

function getRandomName(name, lastName, percProgress)
    if percProgress >= 1.0 then
        return name
    end
	
    lastName = lastName or ""
    local newName = ""
    for i=1, 25 do
        if percProgress > 0.2 then
            local nameChar = name:byte(i) or 32 -- " "
            local lastNameChar = lastName:byte(i) or myRandom:getInt(48,57)
            if lastNameChar ~= nameChar then
                if percProgress + myRandom:getFloat(0.0, 0.4) >= 1 then
                    newName = newName..string.char(nameChar)
                else
                    local char = myRandom:getInt(48,57)
                    newName = newName..string.char(char)
                end
            else
                newName = newName..string.char(nameChar)
            end
        end
    end
    return newName
end

function restoreProductionRate()
    local entity = Entity()
    local scannerDebuffKey = entity:getValue("pvpScannerDebuff")
    if scannerDebuffKey then
        removeBonus(scannerDebuffKey)
        entity:setValue("pvpScannerDebuff") -- remove value
    end
end

function startScanning()
    Log.Debug("startScanning")
    if isScanning then return end
    if onServer() then
        local player = Player(callingPlayer)
        local entity = Entity()
        if player.craft.index ~= entity.index then return end

        -- Apply debuffs
        -- Modifying productionRate directly is a bad idea. Let's use multiplier. We still need origProductionRate for calculations
        local energySystem = EnergySystem()
        origProductionRate = energySystem.productionRate
        if config.GeneratedEnergyDebuff < 1 then
            local scannerDebuffKey = addMultiplier(StatsBonuses.GeneratedEnergy, config.GeneratedEnergyDebuff)
            entity:setValue("pvpScannerDebuff", scannerDebuffKey)
        end
        -- Apply debuffs immediately
        local entity = Entity()
        if entity.shieldDurability and config.ShieldDurabilityDebuff < 1 then
            local damage = entity.shieldDurability * config.ShieldDurabilityDebuff
            entity:damageShield(damage, entity.translationf, player.craftIndex)
        end
        if config.HyperspaceCooldownDebuff > 0 then
            entity.hyperspaceCooldown = math.max(entity.hyperspaceCooldown, config.HyperspaceCooldownDebuff)
        end

        -- find players
        scanningProgress = 0
        foundPlayers = {}
        playerList = {}
        local onlineplayers = {Server():getOnlinePlayers()}
        local range = getPlayerScannerRange(seed, rarity, permanent)
        local playerposX, playerposY = Sector():getCoordinates()

        local pX, pY, dist, distToCore
        for _, player in pairs(onlineplayers) do
            if player then
                pX, pY = player:getSectorCoordinates()
                if not (pX == playerposX and pY == playerposY) then -- Exclude players in current sector
                    dist = math.sqrt((playerposX - pX)^2 + (playerposY - pY)^2)
                    distToCore = length(vec2(pX, pY))
                    -- Show only players in the module range
                    if dist <= range and (config.PVPZoneRange < 0 or distToCore <= config.PVPZoneRange) then
                        playerList[#playerList+1] = {index = player.index, name = player.name, x = pX, y = pY}
                    end
                end
            end
        end

        broadcastInvokeClientFunction("onStartScanning", nil, true) -- sync UI
    end

    myRandom = Random(Seed(appTimeMs()))
    isScanning = true
    fakeUpdateCounter = 0
end
callable(nil, "startScanning")

function stopScanning(broadcast)
    Log.Debug("stopScanning")
    if not isScanning then return end
    if onServer() then
        -- Never trust client
        if not callingPlayer or Player(callingPlayer).craft.index == Entity().index then
            callingPlayer = nil
            restoreProductionRate()

            broadcastInvokeClientFunction("onStopScanning", nil, true) -- sync UI
        end
    end
    isScanning = false
end
callable(nil, "stopScanning")

function onStartScanning(button, isInvoked)
    Log.Debug("onStartScanning")
    -- This function may be executed when already scanning. This should be skipped.
    if not isScanning then
        if scanButton then
            scanButton.onPressedFunction = "onStopScanning"
            scanButton.caption = "Stop Scanning"%_t
            progressBar:clear()
        end
        scanningProgress = 0
        foundPlayers = {}
        startScanning()
        if not isInvoked then
            invokeServerFunction("startScanning")
        end
        -- Clear old data
        labelcontent = {}
    end
end

function onStopScanning(button, isInvoked)
    Log.Debug("onStopScanning")
    if scanButton then
        scanButton.onPressedFunction = "onStartScanning"
        scanButton.caption = "Start Scanning"%_t
    end
    stopScanning()
    if not isInvoked then
        invokeServerFunction("stopScanning")
    end
end

function getPlayersInRange() -- Now this function will be called every second by client and will send 'decoded' data
    if not isScanning then return end
    local player = Player(callingPlayer)
    if player.craft.index ~= Entity().index then return end

    invokeClientFunction(player, "receivePlayersInRange", foundPlayers, scanningProgress, config.ScanningTime, origProductionRate)
end
callable(nil, "getPlayersInRange")

-- Now we're using this function to process 'decoded' data every second
function receivePlayersInRange(decodedPlayers, scanProgress, scanTime, origProduction)
    foundPlayers = decodedPlayers
    scanningProgress = scanProgress
    config.ScanningTime = scanTime
    origProductionRate = origProduction
    -- update UI
    local percProgress = scanningProgress / config.ScanningTime
    progressBar:clear()
    progressBar:setRange(0, config.ScanningTime)
    progressBar:addEntry(scanningProgress, string.format("Progress: %i%%"%_t, round(percProgress * 100, 2)), ColorARGB(0.9, 1 - percProgress, percProgress, 0.1))

    Log.Debug("Real update")
    if foundPlayers then
        local oldnameLabel, nameLabel, coordLabel
        for i, playerData in ipairs(foundPlayers) do
            local coordIndex = coordList[i].index

            oldnameLabel = oldLabelList[i]
            nameLabel = nameList[i]
            coordLabel = coordList[i]

            if percProgress < 1 and labelcontent[coordIndex] then
                oldnameLabel.caption = labelcontent[coordIndex].name
            end
            if percProgress >= 1 or playerData.correctName then
                oldnameLabel.caption = ""
            end
            nameLabel.caption = playerData.name
            coordLabel.caption = "("..playerData.x..":"..playerData.y..")"
            coordLabel.tooltip = string.format("Click to show %s on Galaxy Map"%_t, playerData.name)
            coordLabel.color = playerData.correct and ColorRGB(0.3, 0.9, 0.1) or ColorRGB(1.0, 1.0, 1.0)

            labelcontent[coordIndex] = {x = playerData.x, y = playerData.y, name = playerData.name, correct = playerData.correct, playerData.index}

            oldnameLabel.visible = true
            nameLabel.visible = true
            coordLabel.visible = true
        end
        -- hide other rows
        for i = #foundPlayers+1, config.UIRows do
            oldLabelList[i].visible = false
            nameList[i].visible = false
            coordList[i].visible = false
        end
    end
end

function onCoordClicked(labelIndex)
    local x, y = labelcontent[labelIndex].x, labelcontent[labelIndex].y
    GalaxyMap():show(x, y)
end
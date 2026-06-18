local QBCore = exports['qb-core']:GetCoreObject()

-- Without this, math.random() is deterministic per resource start - every
-- restart would pick the exact same "random" location/dropoff first
math.randomseed(os.time())

-- Track cooldowns per player and active mission state per source (the
-- source here is always the player who STARTED the mission - other players
-- helping out always pass that owner's source as missionOwner)
local playerCooldowns = {}
local missionState = {}

-- Cash owed for a finished delivery, keyed by citizenid, collected later from
-- the Starter NPC instead of being paid out at the dropoff
local pendingPayouts = {}

-- =====================
-- UTILITY
-- =====================

local function GetDifficultyByName(name)
    for _, d in ipairs(Config.Difficulties) do
        if d.name == name then return d end
    end
    return nil
end

local function PickRandomDifficulty()
    return Config.Difficulties[math.random(1, #Config.Difficulties)]
end

local function CountOnDutyPolice()
    local count = 0
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        if Player.PlayerData.job.name == "police" and Player.PlayerData.job.onduty then
            count = count + 1
        end
    end
    return count
end

local function CountOnlinePlayers()
    local count = 0
    for _ in pairs(QBCore.Functions.GetQBPlayers()) do
        count = count + 1
    end
    return count
end

local function RelayToOthers(exceptSrc, event, payload)
    for _, playerId in ipairs(GetPlayers()) do
        local pid = tonumber(playerId)
        if pid and pid ~= exceptSrc then
            TriggerClientEvent(event, pid, payload)
        end
    end
end

-- =====================
-- MISSION START
-- =====================

RegisterNetEvent("mv-convoyheist:server:requestStart", function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    if missionState[src] then
        TriggerClientEvent("QBCore:Notify", src, "You already have an active mission!", "error", 5000)
        return
    end

    local citizenId = Player.PlayerData.citizenid
    local now = os.time()
    if playerCooldowns[citizenId] and (now - playerCooldowns[citizenId]) < Config.Cooldown then
        local remaining = Config.Cooldown - (now - playerCooldowns[citizenId])
        TriggerClientEvent("QBCore:Notify", src, "You must wait " .. math.ceil(remaining / 60) .. " more minute(s) before starting a new mission.", "error", 5000)
        return
    end

    if CountOnlinePlayers() < Config.MinPlayers then
        TriggerClientEvent("QBCore:Notify", src, "Not enough players online to start this mission.", "error", 5000)
        return
    end

    if CountOnDutyPolice() < Config.MinPoliceCount then
        TriggerClientEvent("QBCore:Notify", src, "Not enough police online to start this mission.", "error", 5000)
        return
    end

    if Config.StartCost > 0 then
        if Player.PlayerData.money["cash"] < Config.StartCost then
            TriggerClientEvent("QBCore:Notify", src, "You can't afford to start this mission ($" .. Config.StartCost .. ").", "error", 5000)
            return
        end
        Player.Functions.RemoveMoney("cash", Config.StartCost, "gang-heist-start")
    end

    local diffData = PickRandomDifficulty()
    local locationIndex = diffData.locationIndex or math.random(1, #Config.Locations)
    local dropoffIndex = math.random(1, #Config.Dropoff.locations)
    local dropoff = Config.Dropoff.locations[dropoffIndex].coords

    playerCooldowns[citizenId] = now
    missionState[src] = {
        difficulty = diffData.name,
        locationIndex = locationIndex,
        dropoffIndex = dropoffIndex,
        trackerActive = true,
        vehicleNetId = nil,
        stage = 1,
    }

    TriggerClientEvent("mv-convoyheist:client:missionAllowed", src, {
        difficulty = diffData.name,
        locationIndex = locationIndex,
        dropoff = dropoff,
        dropoffIndex = dropoffIndex,
    })
end)

-- =====================
-- MISSION CANCEL
-- =====================

RegisterNetEvent("mv-convoyheist:server:cancelMission", function()
    local src = source
    if not missionState[src] then
        TriggerClientEvent("QBCore:Notify", src, "You don't have an active mission to cancel.", "error", 5000)
        return
    end

    missionState[src] = nil
    TriggerClientEvent("mv-convoyheist:client:cancelMission", src)
end)

-- =====================
-- SHARING MISSION ENTITIES WITH OTHER PLAYERS
-- =====================

RegisterNetEvent("mv-convoyheist:server:broadcastMissionEntities", function(payload)
    local src = source
    local mission = missionState[src]
    if not mission then return end

    mission.vehicleNetId = payload.vehicleNetId

    payload.missionOwner = src
    RelayToOthers(src, "mv-convoyheist:client:registerSharedEntities", payload)
end)

RegisterNetEvent("mv-convoyheist:server:broadcastDropoffEntities", function(payload)
    local src = source
    local mission = missionState[src]
    if not mission then return end

    payload.missionOwner = src
    RelayToOthers(src, "mv-convoyheist:client:registerSharedDropoff", payload)
end)

-- =====================
-- VEHICLE TRACKER
-- =====================

RegisterNetEvent("mv-convoyheist:server:trackerPing", function(coords)
    local src = source
    local mission = missionState[src]
    if not mission or not mission.trackerActive then return end

    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        if Player.PlayerData.job.name == "police" and Player.PlayerData.job.onduty then
            TriggerClientEvent("QBCore:Notify", Player.PlayerData.source, Config.Tracker.pingMessage, "error", 4000)
            TriggerClientEvent("mv-convoyheist:client:trackerBlip", Player.PlayerData.source, coords)
        end
    end
end)

RegisterNetEvent("mv-convoyheist:server:trackerRemoved", function(missionOwner)
    local src = source
    missionOwner = missionOwner or src
    local mission = missionState[missionOwner]
    if not mission or not mission.trackerActive then return end

    if Config.Tracker.requiredItem and Config.Tracker.requiredItem ~= "" then
        if not QBCore.Functions.HasItem(src, Config.Tracker.requiredItem) then return end
        if Config.Tracker.consumeItem then
            exports['qb-inventory']:RemoveItem(src, Config.Tracker.requiredItem, 1, false, "mv-convoyheist:server:trackerRemoved")
            TriggerClientEvent("qb-inventory:client:ItemBox", src, QBCore.Shared.Items[Config.Tracker.requiredItem], "remove")
        end
    end

    mission.trackerActive = false
    mission.stage = 3
    TriggerClientEvent("mv-convoyheist:client:setTaskStage", missionOwner, 3)
    TriggerClientEvent("mv-convoyheist:client:onTrackerRemoved", missionOwner)
end)

if Config.Tracker.requiredItem and Config.Tracker.requiredItem ~= "" then
    QBCore.Functions.CreateUseableItem(Config.Tracker.requiredItem, function(source)
        TriggerClientEvent("mv-convoyheist:client:useHackDevice", source)
    end)
end

-- =====================
-- CONTRACT COMPLETE (vehicle handed over to the contact NPC)
-- =====================

RegisterNetEvent("mv-convoyheist:server:completeContract", function(missionOwner)
    local src = source
    missionOwner = missionOwner or src
    local mission = missionState[missionOwner]
    if not mission then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if Player and Config.Dropoff.reward.cash > 0 then
        local citizenId = Player.PlayerData.citizenid
        pendingPayouts[citizenId] = (pendingPayouts[citizenId] or 0) + Config.Dropoff.reward.cash
        TriggerClientEvent("QBCore:Notify", src, "Contract complete! Go collect your cash from the contact.", "success", 5000)
    else
        TriggerClientEvent("QBCore:Notify", src, "Contract complete!", "success", 5000)
    end

    missionState[missionOwner] = nil
    TriggerClientEvent("mv-convoyheist:client:runDeparture", missionOwner)
end)

-- =====================
-- CASH COLLECTION (Starter NPC, after a finished delivery)
-- =====================

RegisterNetEvent("mv-convoyheist:server:requestCollectCash", function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenId = Player.PlayerData.citizenid
    local amount = pendingPayouts[citizenId]

    if not amount or amount <= 0 then
        TriggerClientEvent("QBCore:Notify", src, Config.StarterNPC.noPayoutMessage, "error", 5000)
        return
    end

    pendingPayouts[citizenId] = nil
    Player.Functions.AddMoney("cash", amount, "gang-heist-payout")
    TriggerClientEvent("mv-convoyheist:client:cashCollected", src, amount)
end)

-- =====================
-- POLICE NOTIFICATION (initial zone alert)
-- =====================

RegisterNetEvent("mv-convoyheist:server:notifyPolice", function(coords)
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        if Player.PlayerData.job.name == "police" and Player.PlayerData.job.onduty then
            TriggerClientEvent("QBCore:Notify", Player.PlayerData.source, Config.PoliceNotify.message, "error", 10000)
            TriggerClientEvent("mv-convoyheist:client:addPoliceBlip", Player.PlayerData.source, coords)
        end
    end
end)

-- =====================
-- CLEANUP
-- =====================

AddEventHandler("playerDropped", function()
    local src = source
    missionState[src] = nil
end)

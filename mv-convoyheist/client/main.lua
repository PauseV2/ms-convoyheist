local QBCore = exports['qb-core']:GetCoreObject()

math.randomseed(GetGameTimer())

-- State (all of this describes a mission that THIS client started; a client
-- that's merely helping someone else's mission never touches these)
local missionActive = false
local currentLocation = nil
local currentDifficulty = nil
local currentDropoffIndex = nil
local spawnedNPCs = {}
local spawnedVehicle = nil
local vehiclePlate = nil
local vehicleNetId = nil
local trackerActive = false
local dropoffCoords = nil
local dropoffRevealed = false
local dropoffNPCs = {}
local policeBlip = nil
local missionBlip = nil
local dropoffBlip = nil
local zoneEntered = false
local starterNPCHandle = nil
local starterBlip = nil

-- Task HUD (only ever shown for a mission this client started)
local taskHudVisible = true
local currentStage = 0

-- Bookkeeping for helping out on OTHER players' missions
local remoteGuards = {}         -- [ped] = { owner = src, index = i }
local remoteContacts = {}       -- [contactPed] = { owner = src }
local remoteVehicleOwners = {}  -- [vehicleNetId] = ownerSrc
local remoteMissionVehicle = {} -- [ownerSrc] = vehicleNetId

-- =====================
-- UTILITY
-- =====================

local function Notify(msg, type)
    QBCore.Functions.Notify(msg, type or "primary", 5000)
end

local function WaitForNetworked(entity)
    while not NetworkGetEntityIsNetworked(entity) do
        Wait(0)
    end
end

-- Loads a model with a bounded wait so a typo'd/missing model name can never
-- freeze the script forever. Returns the model hash on success, nil on failure.
local function LoadModel(model)
    local hash = GetHashKey(model)
    if not IsModelValid(hash) then
        Notify("Missing model in config: " .. tostring(model), "error")
        return nil
    end

    RequestModel(hash)
    local attempts = 0
    while not HasModelLoaded(hash) and attempts < 200 do
        Wait(10)
        attempts = attempts + 1
    end

    if not HasModelLoaded(hash) then
        Notify("Model failed to load: " .. tostring(model), "error")
        return nil
    end
    return hash
end

local function PlaySyncedAnim(ped, dict, anim, duration, flags, lockZ)
    RequestAnimDict(dict)
    local attempts = 0
    while not HasAnimDictLoaded(dict) and attempts < 100 do
        Wait(10)
        attempts = attempts + 1
    end
    if not HasAnimDictLoaded(dict) then return false end -- bad/missing dict - skip instead of freezing the script forever
    TaskPlayAnim(ped, dict, anim, 3.0, 3.0, duration, flags or 49, 0, false, false, lockZ or false)
    return true
end

-- =====================
-- GUARD AI SAFETY
-- Peds created with CreatePed do NOT inherit the gang relationship data
-- their model ships with - that data only applies to peds spawned by the
-- game's own population system. A CreatePed'd ped gets a generic default
-- relationship group, so there is nothing telling our guards they're
-- friendly to each other; the moment one fires, the others perceive the
-- gunfire/hated-target event and can flag each other as hostile. Hence an
-- explicit relationship group, set up once and assigned to every guard.
-- =====================

local GUARD_RELATIONSHIP_GROUP = `convoyheist_guard`
local guardRelationshipReady = false

local function EnsureGuardRelationshipGroup()
    if guardRelationshipReady then return end
    AddRelationshipGroup("convoyheist_guard")
    SetRelationshipBetweenGroups(0, GUARD_RELATIONSHIP_GROUP, GUARD_RELATIONSHIP_GROUP) -- 0 = Companion: guards never fight each other
    SetRelationshipBetweenGroups(5, GUARD_RELATIONSHIP_GROUP, `PLAYER`) -- 5 = Hate, both directions
    SetRelationshipBetweenGroups(5, `PLAYER`, GUARD_RELATIONSHIP_GROUP)
    guardRelationshipReady = true
end

-- Re-applies every flag that stops guards from fighting each other. Cheap
-- and non-disruptive - safe to call every tick without interrupting
-- whatever the ped is currently doing.
local function SecureGuardPed(ped)
    if not DoesEntityExist(ped) or IsEntityDead(ped) then return end
    EnsureGuardRelationshipGroup()
    SetPedRelationshipGroupHash(ped, GUARD_RELATIONSHIP_GROUP)
    SetCanAttackFriendly(ped, false, false) -- belt-and-suspenders: don't let stray shots turn guards on each other
    SetPedCombatAttributes(ped, 46, true) -- BF_AlwaysFight: don't flee/back down once engaged
    SetBlockingOfNonTemporaryEvents(ped, true) -- stop a guard from autonomously reacting to perceiving a teammate's gunfire
    -- No SetEntityOnlyDamagedByPlayer anymore - guards can take damage from
    -- crossfire/each other again, by request.
end

-- Finds the nearest REAL player (any player streamed in on this client,
-- not just the mission owner) to a given point
local function FindNearestPlayerPed(fromCoords, maxRadius)
    local closestPed, closestDist = nil, maxRadius
    for _, playerId in ipairs(GetActivePlayers()) do
        local targetPed = GetPlayerPed(playerId)
        if targetPed and targetPed ~= 0 and DoesEntityExist(targetPed) and not IsEntityDead(targetPed) then
            local dist = #(fromCoords - GetEntityCoords(targetPed))
            if dist < closestDist then
                closestPed = targetPed
                closestDist = dist
            end
        end
    end
    return closestPed
end

-- Forces the guard onto whichever real player is nearest. Unlike
-- TaskCombatHatedTargetsAroundPed (a re-scan/re-assign task that visibly
-- reset the ped's aim every time it was reissued), repeating TaskCombatPed
-- with the SAME target ped is a no-op for an already-engaged guard - so
-- this is safe to run every tick for instant on-sight aggression without
-- ever interrupting sustained fire, and it covers every nearby player, not
-- just whoever started the mission.
local function UpdateGuardCombat(ped)
    if not DoesEntityExist(ped) or IsEntityDead(ped) then return end
    local target = FindNearestPlayerPed(GetEntityCoords(ped), 100.0)
    if target then
        TaskCombatPed(ped, target, 0, 0)
    end
end

-- Runs forever on every client (helpers included), independent of whether
-- this client started a mission, since a guard's network control can
-- migrate to any nearby player
CreateThread(function()
    while true do
        Wait(250)
        for _, npcData in ipairs(spawnedNPCs) do
            SecureGuardPed(npcData.ped)
            UpdateGuardCombat(npcData.ped)
        end
        for ped in pairs(remoteGuards) do
            SecureGuardPed(ped)
            UpdateGuardCombat(ped)
        end
    end
end)

-- =====================
-- TASK HUD
-- =====================

local function ShowTask(stage)
    local text = Config.TaskHUD.messages[stage]
    if not text then return end
    currentStage = stage
    taskHudVisible = true
    SendNUIMessage({ action = "showTask", text = text, key = Config.TaskHUD.toggleKey })
end

local function HideTask()
    currentStage = 0
    SendNUIMessage({ action = "hideTask" })
end

RegisterCommand("mv_convoyheist_toggletask", function()
    if currentStage == 0 then return end
    taskHudVisible = not taskHudVisible
    SendNUIMessage({ action = "setTaskVisibility", visible = taskHudVisible })
end, false)
RegisterKeyMapping("mv_convoyheist_toggletask", "Toggle convoy heist task HUD", "keyboard", Config.TaskHUD.toggleKey)

RegisterNetEvent("mv-convoyheist:client:setTaskStage", function(stage)
    ShowTask(stage)
end)

-- =====================
-- STARTER NPC
-- =====================

local function SpawnStarterNPC()
    local npcData = Config.StarterNPC
    local hash = LoadModel(npcData.model)
    if not hash then return end

    starterNPCHandle = CreatePed(4, hash, npcData.coords.x, npcData.coords.y, npcData.coords.z - 1.0, npcData.coords.w, false, true)
    SetEntityAsMissionEntity(starterNPCHandle, true, true)
    SetBlockingOfNonTemporaryEvents(starterNPCHandle, true)
    SetPedCanRagdoll(starterNPCHandle, false)
    FreezeEntityPosition(starterNPCHandle, true)
    SetPedFleeAttributes(starterNPCHandle, 0, false)
    SetPedCombatAttributes(starterNPCHandle, 17, true)

    starterBlip = AddBlipForCoord(npcData.coords.x, npcData.coords.y, npcData.coords.z)
    SetBlipSprite(starterBlip, 280)
    SetBlipColour(starterBlip, 5)
    SetBlipScale(starterBlip, 0.8)
    SetBlipAsShortRange(starterBlip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(npcData.label)
    EndTextCommandSetBlipName(starterBlip)

    exports['qb-target']:AddTargetEntity(starterNPCHandle, {
        options = {
            {
                type = "client",
                event = "mv-convoyheist:client:requestStart",
                icon = npcData.targetIcon,
                label = npcData.targetLabel,
            },
            {
                type = "client",
                event = "mv-convoyheist:client:requestCollectCash",
                icon = npcData.collectCashIcon,
                label = npcData.collectCashLabel,
            },
            {
                type = "client",
                event = "mv-convoyheist:client:requestCancel",
                icon = npcData.cancelIcon,
                label = npcData.cancelLabel,
                canInteract = function()
                    return missionActive
                end,
            },
        },
        distance = npcData.targetDistance,
    })
end

-- =====================
-- SUBTITLE-STYLE DIALOGUE
-- Plays a list of lines one at a time as on-screen subtitles; ENTER advances
-- to the next line. Once the lines run out, onComplete fires (used to pop
-- the Accept/Decline qb-menu choice).
-- =====================

local dialogueActive = false
local dialogueLines = {}
local dialogueIndex = 0
local dialogueSpeaker = nil
local dialogueOnComplete = nil

local function AdvanceDialogue()
    if not dialogueActive then return end
    dialogueIndex = dialogueIndex + 1
    local text = dialogueLines[dialogueIndex]

    if not text then
        dialogueActive = false
        SendNUIMessage({ action = "hideDialogue" })
        local onComplete = dialogueOnComplete
        dialogueOnComplete = nil
        if onComplete then onComplete() end
        return
    end

    SendNUIMessage({ action = "showDialogue", speaker = dialogueSpeaker, text = text })
end

local function StartDialogue(speaker, lines, onComplete)
    dialogueActive = true
    dialogueLines = lines
    dialogueIndex = 0
    dialogueSpeaker = speaker
    dialogueOnComplete = onComplete
    AdvanceDialogue()
end

RegisterCommand("mv_convoyheist_advancedialogue", function()
    AdvanceDialogue()
end, false)
RegisterKeyMapping("mv_convoyheist_advancedialogue", "Advance convoy heist dialogue", "keyboard", "RETURN")

local function OpenStarterConversation()
    local convo = Config.StarterConversation
    StartDialogue(convo.speaker, convo.lines, function()
        exports['qb-menu']:openMenu({
            {
                header = convo.acceptLabel,
                txt = convo.acceptText,
                params = { event = "mv-convoyheist:client:confirmStart" },
            },
            {
                header = convo.declineLabel,
                txt = convo.declineText,
                params = { event = "qb-menu:client:closeMenu" },
            },
        })
    end)
end

local function OpenCancelConversation()
    local convo = Config.CancelConversation
    StartDialogue(convo.speaker, convo.lines, function()
        exports['qb-menu']:openMenu({
            {
                header = convo.confirmLabel,
                txt = convo.confirmText,
                params = { event = "mv-convoyheist:client:confirmCancel" },
            },
            {
                header = convo.backLabel,
                txt = convo.backText,
                params = { event = "qb-menu:client:closeMenu" },
            },
        })
    end)
end

RegisterNetEvent("mv-convoyheist:client:requestStart", function()
    if missionActive then
        Notify("You already have an active mission!", "error")
        return
    end
    OpenStarterConversation()
end)

RegisterNetEvent("mv-convoyheist:client:confirmStart", function()
    TriggerServerEvent("mv-convoyheist:server:requestStart")
end)

RegisterNetEvent("mv-convoyheist:client:requestCancel", function()
    if not missionActive then return end
    OpenCancelConversation()
end)

RegisterNetEvent("mv-convoyheist:client:confirmCancel", function()
    TriggerServerEvent("mv-convoyheist:server:cancelMission")
end)

RegisterNetEvent("mv-convoyheist:client:requestCollectCash", function()
    TriggerServerEvent("mv-convoyheist:server:requestCollectCash")
end)

-- Plays the give/take anim on the player and the Starter NPC together, with
-- a cash prop attached to the player's hand for the duration
local function PlayCashCollectEmote()
    if not starterNPCHandle or not DoesEntityExist(starterNPCHandle) then return end
    local emote = Config.CashCollectEmote
    local playerPed = PlayerPedId()

    TaskTurnPedToFaceEntity(playerPed, starterNPCHandle, 1000)
    Wait(250)

    PlaySyncedAnim(playerPed, emote.dict, emote.playerAnim, emote.duration, 49)
    PlaySyncedAnim(starterNPCHandle, emote.dict, emote.npcAnim, emote.duration, 49)

    local prop = nil
    local propHash = LoadModel(emote.prop.model)
    if propHash then
        prop = CreateObject(propHash, 0.0, 0.0, 0.0, true, true, false)
        local boneIndex = GetPedBoneIndex(playerPed, emote.prop.bone)
        AttachEntityToEntity(prop, playerPed, boneIndex,
            emote.prop.offset.x, emote.prop.offset.y, emote.prop.offset.z,
            emote.prop.rotation.x, emote.prop.rotation.y, emote.prop.rotation.z,
            true, true, false, true, 2, true)
    end

    SetTimeout(emote.duration, function()
        ClearPedTasks(playerPed)
        if DoesEntityExist(starterNPCHandle) then
            ClearPedTasks(starterNPCHandle)
        end
        if prop and DoesEntityExist(prop) then
            DeleteEntity(prop)
        end
    end)
end

RegisterNetEvent("mv-convoyheist:client:cashCollected", function(amount)
    PlayCashCollectEmote()
    Notify("You collected $" .. amount .. " from your contact.", "success")
end)

-- =====================
-- POLICE NOTIFICATION (initial zone alert)
-- =====================

local function NotifyPolice(coords)
    TriggerServerEvent("mv-convoyheist:server:notifyPolice", coords)
end

local function AddPoliceBlip(coords)
    if policeBlip then RemoveBlip(policeBlip) end
    policeBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(policeBlip, Config.PoliceNotify.blipSprite)
    SetBlipColour(policeBlip, Config.PoliceNotify.blipColor)
    SetBlipScale(policeBlip, Config.PoliceNotify.blipScale)
    if Config.PoliceNotify.blipFlash then
        SetBlipFlashes(policeBlip, true)
    end
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(Config.PoliceNotify.blipLabel)
    EndTextCommandSetBlipName(policeBlip)

    SetTimeout(Config.PoliceNotify.blipTimeout, function()
        if policeBlip then
            RemoveBlip(policeBlip)
            policeBlip = nil
        end
    end)
end

RegisterNetEvent("mv-convoyheist:client:addPoliceBlip", function(coords)
    AddPoliceBlip(coords)
end)

RegisterNetEvent("mv-convoyheist:client:trackerBlip", function(coords)
    if policeBlip then RemoveBlip(policeBlip) end
    policeBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(policeBlip, Config.Tracker.blipSprite)
    SetBlipColour(policeBlip, Config.Tracker.blipColor)
    SetBlipScale(policeBlip, Config.Tracker.blipScale)
    SetBlipFlashes(policeBlip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName("Tracked Vehicle")
    EndTextCommandSetBlipName(policeBlip)

    SetTimeout(Config.Tracker.blipTimeout, function()
        if policeBlip then
            RemoveBlip(policeBlip)
            policeBlip = nil
        end
    end)
end)

-- =====================
-- NPC SPAWNING (guards spawned in a ring around the vehicle)
-- =====================

-- Evenly spaces `count` points around a circle of `radius` meters centered
-- on centerCoords, with a little random jitter per point, snapped to the
-- ground at that x/y
local function GenerateGuardSpawnPoints(centerCoords, count, radius)
    local points = {}
    local angleStep = (2 * math.pi) / count

    for i = 1, count do
        local angle = (i - 1) * angleStep + (math.random() * angleStep * 0.5)
        local x = centerCoords.x + math.cos(angle) * radius
        local y = centerCoords.y + math.sin(angle) * radius

        local found, groundZ = GetGroundZFor_3dCoord(x, y, centerCoords.z + 50.0, false)
        local z = found and groundZ or centerCoords.z
        local heading = math.random(0, 359) + 0.0

        points[#points + 1] = vector4(x, y, z, heading)
    end

    return points
end

local function SpawnGuardNPCs(location, diffData)
    spawnedNPCs = {}

    local hash = LoadModel(Config.Guards.model)
    if not hash then return end

    local spawnPoints = GenerateGuardSpawnPoints(location.vehicle.coords, Config.Guards.count, Config.Guards.spawnRadius)

    for i, coords in ipairs(spawnPoints) do
        local ped = CreatePed(4, hash, coords.x, coords.y, coords.z, coords.w, true, true)
        if not DoesEntityExist(ped) then
            -- A model can pass LoadModel's checks but still fail to produce
            -- a real ped (this happened with both "s_m_y_cop_01" and
            -- "fbi"). Calling further natives on an invalid handle can
            -- throw and silently abort the rest of StartMission - skip
            -- this guard instead of risking that.
            goto continue
        end

        SetEntityAsMissionEntity(ped, true, true)
        SetEntityMaxHealth(ped, diffData.npcHealth + 100)
        SetEntityHealth(ped, diffData.npcHealth + 100)
        SetPedArmour(ped, diffData.npcArmor)
        SetPedAccuracy(ped, diffData.npcAccuracy)

        GiveWeaponToPed(ped, GetHashKey(diffData.npcWeapon), 999, false, true)
        SetPedDropsWeaponsWhenDead(ped, true)
        SecureGuardPed(ped)

        SetPedCombatAttributes(ped, 0, true) -- BF_CanUseCover
        SetPedCombatRange(ped, 2)
        SetPedHearingRange(ped, 40.0)
        SetPedSeeingRange(ped, 60.0)
        SetPedAlertness(ped, 3)
        SetPedFleeAttributes(ped, 0, false)

        -- Must come AFTER the perception ranges above - issuing the combat
        -- task while seeing/hearing range was still at the engine default
        -- meant the very first target scan could miss the player entirely
        UpdateGuardCombat(ped)

        spawnedNPCs[#spawnedNPCs + 1] = { ped = ped, index = i }
        WaitForNetworked(ped)

        ::continue::
    end
end

-- =====================
-- VEHICLE SPAWNING
-- =====================

local function SpawnMissionVehicle(location)
    local vehData = location.vehicle
    local hash = LoadModel(vehData.model)
    if not hash then return end

    spawnedVehicle = CreateVehicle(hash, vehData.coords.x, vehData.coords.y, vehData.coords.z, vehData.coords.w, true, false)
    SetEntityAsMissionEntity(spawnedVehicle, true, true)
    SetVehicleDoorsLocked(spawnedVehicle, 1) -- Unlocked - no guard/key mechanic right now, being rebuilt
    SetVehicleEngineOn(spawnedVehicle, false, true, false)

    WaitForNetworked(spawnedVehicle)
    vehicleNetId = NetworkGetNetworkIdFromEntity(spawnedVehicle)
    vehiclePlate = QBCore.Functions.GetPlate(spawnedVehicle)
end

-- =====================
-- BROADCASTING MISSION ENTITIES TO OTHER PLAYERS
-- qb-target registrations are local to each client, so without this, only
-- the mission starter would ever see a third-eye option on the vehicle's
-- tracker hack from inside it.
-- =====================

local function BroadcastMissionEntities()
    local guardPayload = {}
    for _, n in ipairs(spawnedNPCs) do
        if DoesEntityExist(n.ped) then
            guardPayload[#guardPayload + 1] = { netId = NetworkGetNetworkIdFromEntity(n.ped), index = n.index }
        end
    end

    TriggerServerEvent("mv-convoyheist:server:broadcastMissionEntities", {
        vehicleNetId = vehicleNetId,
        guards = guardPayload,
    })
end

RegisterNetEvent("mv-convoyheist:client:registerSharedEntities", function(payload)
    local owner = payload.missionOwner
    if payload.vehicleNetId then
        remoteVehicleOwners[payload.vehicleNetId] = owner
        remoteMissionVehicle[owner] = payload.vehicleNetId
    end

    for _, g in ipairs(payload.guards or {}) do
        local ped = NetworkGetEntityFromNetworkId(g.netId)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            remoteGuards[ped] = { owner = owner, index = g.index }
        end
    end
end)

RegisterNetEvent("mv-convoyheist:client:registerSharedDropoff", function(payload)
    local owner = payload.missionOwner
    local ped = NetworkGetEntityFromNetworkId(payload.contactNetId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    remoteContacts[ped] = { owner = owner }
    exports['qb-target']:AddTargetEntity(ped, {
        options = {
            {
                type = "client",
                event = "mv-convoyheist:client:remoteHandoverVehicle",
                icon = Config.Dropoff.targetIcon,
                label = Config.Dropoff.targetLabel,
                canInteract = function()
                    local vehNetId = remoteMissionVehicle[owner]
                    local vehicle = vehNetId and NetworkGetEntityFromNetworkId(vehNetId)
                    return vehicle and vehicle ~= 0 and DoesEntityExist(vehicle)
                        and #(GetEntityCoords(vehicle) - GetEntityCoords(ped)) < Config.Dropoff.vehicleProximity
                end,
            },
        },
        distance = Config.Dropoff.interactDistance,
    })
end)

-- =====================
-- DROPOFF / VEHICLE HANDOVER
-- =====================

local function SpawnDropoffNPCs(dropoffData)
    dropoffNPCs = {}

    for _, npcData in ipairs(dropoffData.npcs) do
        local model = npcData.model or "a_m_y_business_01"
        local hash = LoadModel(model)

        if hash then
            local coords = npcData.coords
            local ped = CreatePed(4, hash, coords.x, coords.y, coords.z - 1.0, coords.w, true, true)
            SetEntityAsMissionEntity(ped, true, true)
            SetEntityInvincible(ped, true)
            SetPedCanRagdoll(ped, false)
            SetBlockingOfNonTemporaryEvents(ped, true)
            SetPedFleeAttributes(ped, 0, false)
            SetPedCombatAttributes(ped, 17, true) -- never fight back, same as the starter NPC
            SetPedSeeingRange(ped, 0.0)
            SetPedHearingRange(ped, 0.0)
            SetPedAlertness(ped, 0)
            SetPedRelationshipGroupHash(ped, GetHashKey("CIVMALE"))
            FreezeEntityPosition(ped, true)
            TaskStartScenarioInPlace(ped, "WORLD_HUMAN_STAND_IMPATIENT", 0, true)

            local entry = { ped = ped, role = npcData.role }
            dropoffNPCs[#dropoffNPCs + 1] = entry
            WaitForNetworked(ped)

            if npcData.role == "contact" then
                exports['qb-target']:AddTargetEntity(ped, {
                    options = {
                        {
                            type = "client",
                            event = "mv-convoyheist:client:handoverVehicle",
                            icon = Config.Dropoff.targetIcon,
                            label = Config.Dropoff.targetLabel,
                            canInteract = function()
                                return dropoffRevealed and spawnedVehicle and DoesEntityExist(spawnedVehicle)
                                    and #(GetEntityCoords(spawnedVehicle) - vector3(coords.x, coords.y, coords.z)) < Config.Dropoff.vehicleProximity
                            end,
                        },
                    },
                    distance = Config.Dropoff.interactDistance,
                })

                TriggerServerEvent("mv-convoyheist:server:broadcastDropoffEntities", {
                    contactNetId = NetworkGetNetworkIdFromEntity(ped),
                })
            end
        end
    end
end

local function RevealDropoff()
    local dropoffData = Config.Dropoff.locations[currentDropoffIndex]
    if not dropoffData then
        Notify("Error: no dropoff data for index " .. tostring(currentDropoffIndex), "error")
        return
    end

    dropoffRevealed = true
    Notify("Tracker disabled! Dropoff location revealed.", "success")
    SpawnDropoffNPCs(dropoffData)

    dropoffBlip = AddBlipForCoord(dropoffCoords.x, dropoffCoords.y, dropoffCoords.z)
    SetBlipSprite(dropoffBlip, Config.Dropoff.blipSprite)
    SetBlipColour(dropoffBlip, Config.Dropoff.blipColor)
    SetBlipScale(dropoffBlip, 0.9)
    SetBlipRoute(dropoffBlip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(Config.Dropoff.blipLabel)
    EndTextCommandSetBlipName(dropoffBlip)
end

local function GetDropoffNPC(role)
    for _, entry in ipairs(dropoffNPCs) do
        if entry.role == role then return entry.ped end
    end
    return nil
end

local function DriveDeliveryVehicleAway(vehicle, npcPeds)
    local maxSeats = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle))
    local driver = npcPeds[1]

    for _, ped in ipairs(npcPeds) do
        FreezeEntityPosition(ped, false)
        SetBlockingOfNonTemporaryEvents(ped, true)
    end

    TaskEnterVehicle(driver, vehicle, 20000, -1, 2.0, 1, 0)
    for i = 2, math.min(#npcPeds, maxSeats) do
        TaskEnterVehicle(npcPeds[i], vehicle, 20000, i - 2, 2.0, 1, 0)
    end

    -- Wait for them to actually walk over and get in before driving off
    local attempts = 0
    while not IsPedInVehicle(driver, vehicle, false) and attempts < 200 do
        Wait(100)
        attempts = attempts + 1
    end

    for _, ped in ipairs(npcPeds) do
        SetEntityInvincible(ped, true)
    end

    SetVehicleDoorsLocked(vehicle, 2)
    TaskVehicleDriveWander(driver, vehicle, 25.0, 786603)

    SetTimeout(Config.Dropoff.despawnDelay, function()
        for _, ped in ipairs(npcPeds) do
            if DoesEntityExist(ped) then DeleteEntity(ped) end
        end
        if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
    end)
end

-- Runs the actual handover anim + reward trigger - works the same whether
-- this is our own contact or one shared from another player's mission
local function PlayHandoverAndComplete(missionOwner)
    local playerPed = PlayerPedId()
    local handover = Config.Dropoff.handoverAnim
    CreateThread(function()
        PlaySyncedAnim(playerPed, handover.dict, handover.giveAnim, handover.duration, 49)
    end)
    TriggerServerEvent("mv-convoyheist:server:completeContract", missionOwner)
end

RegisterNetEvent("mv-convoyheist:client:handoverVehicle", function()
    if not missionActive or not dropoffRevealed then return end
    if not spawnedVehicle or not DoesEntityExist(spawnedVehicle) then return end

    local contactPed = GetDropoffNPC("contact")
    if not contactPed then return end

    exports['qb-target']:RemoveTargetEntity(contactPed)
    PlayHandoverAndComplete(nil) -- nil = "my own mission", server resolves to source
end)

RegisterNetEvent("mv-convoyheist:client:remoteHandoverVehicle", function(data)
    local entity = data.entity
    local entry = entity and remoteContacts[entity]
    if not entry then return end

    exports['qb-target']:RemoveTargetEntity(entity)
    PlayHandoverAndComplete(entry.owner)
end)

-- This always runs on whoever started the mission, regardless of who
-- actually clicked the contact NPC, since only the starter's client has
-- network control over the dropoff peds/vehicle and the local mission state
RegisterNetEvent("mv-convoyheist:client:runDeparture", function()
    if not missionActive then return end

    local contactPed = GetDropoffNPC("contact")
    if not contactPed then return end

    local vehicle = spawnedVehicle
    local npcPeds = { contactPed } -- contact drives, escorts ride along
    for _, entry in ipairs(dropoffNPCs) do
        if entry.role ~= "contact" then
            npcPeds[#npcPeds + 1] = entry.ped
        end
    end

    spawnedVehicle = nil
    dropoffNPCs = {}
    missionActive = false
    trackerActive = false
    HideTask()

    if missionBlip then RemoveBlip(missionBlip) missionBlip = nil end
    if policeBlip then RemoveBlip(policeBlip) policeBlip = nil end
    if dropoffBlip then RemoveBlip(dropoffBlip) dropoffBlip = nil end

    for _, npcData in ipairs(spawnedNPCs) do
        if DoesEntityExist(npcData.ped) then
            DeleteEntity(npcData.ped)
        end
    end
    spawnedNPCs = {}

    DriveDeliveryVehicleAway(vehicle, npcPeds)

    zoneEntered = false
    dropoffRevealed = false
    dropoffCoords = nil
    vehiclePlate = nil
    vehicleNetId = nil
    currentLocation = nil
    currentDifficulty = nil
    currentDropoffIndex = nil
end)

-- =====================
-- TRACKER / HACK MINIGAME
-- =====================

local function StartTrackerLoop()
    CreateThread(function()
        while missionActive and trackerActive do
            Wait(Config.Tracker.notifyInterval)
            if not missionActive or not trackerActive then break end
            if spawnedVehicle and DoesEntityExist(spawnedVehicle) then
                TriggerServerEvent("mv-convoyheist:server:trackerPing", GetEntityCoords(spawnedVehicle))
            end
        end
    end)
end

-- Returns the vehicle the player is currently in if it's a tracked mission
-- vehicle, plus the mission owner (nil = our own mission)
local function ResolveTrackedVehicle()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil, nil end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if not DoesEntityExist(vehicle) then return nil, nil end

    if spawnedVehicle and vehicle == spawnedVehicle then
        return vehicle, nil
    end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    local owner = remoteVehicleOwners[netId]
    if owner then return vehicle, owner end

    return nil, nil
end

local function TryHackTracker()
    local vehicle, missionOwner = ResolveTrackedVehicle()
    if not vehicle then return end

    if Config.Tracker.requiredItem and Config.Tracker.requiredItem ~= "" and not QBCore.Functions.HasItem(Config.Tracker.requiredItem) then
        Notify("You need a hacking device to do this.", "error")
        return
    end

    local result = exports['qb-minigames']:KeyMinigame(Config.Tracker.keyMinigameAmount)
    local success = result and not result.quit and result.faults <= Config.Tracker.keyMinigameMaxFaults

    if success then
        TriggerServerEvent("mv-convoyheist:server:trackerRemoved", missionOwner)
    else
        Notify("Hack failed. Try again.", "error")
    end
end

RegisterNetEvent("mv-convoyheist:client:useHackDevice", function()
    TryHackTracker()
end)

RegisterCommand("mv_convoyheist_hacktracker", TryHackTracker, false)
RegisterKeyMapping("mv_convoyheist_hacktracker", "Hack vehicle tracker", "keyboard", Config.Tracker.hackKey)

-- Always runs on the mission owner, regardless of who did the hacking
RegisterNetEvent("mv-convoyheist:client:onTrackerRemoved", function()
    trackerActive = false
    RevealDropoff()
end)

-- =====================
-- CLEANUP (abort mid-mission, never used for a completed handover)
-- =====================

local function CleanupMission()
    missionActive = false
    trackerActive = false
    zoneEntered = false
    dropoffRevealed = false
    dropoffCoords = nil
    HideTask()

    for _, entry in ipairs(dropoffNPCs) do
        if DoesEntityExist(entry.ped) then
            exports['qb-target']:RemoveTargetEntity(entry.ped)
            DeleteEntity(entry.ped)
        end
    end
    dropoffNPCs = {}

    for _, npcData in ipairs(spawnedNPCs) do
        if DoesEntityExist(npcData.ped) then
            DeleteEntity(npcData.ped)
        end
    end
    spawnedNPCs = {}

    if spawnedVehicle and DoesEntityExist(spawnedVehicle) then
        DeleteEntity(spawnedVehicle)
    end
    spawnedVehicle = nil
    vehiclePlate = nil
    vehicleNetId = nil

    if policeBlip then
        RemoveBlip(policeBlip)
        policeBlip = nil
    end

    if missionBlip then
        RemoveBlip(missionBlip)
        missionBlip = nil
    end

    if dropoffBlip then
        RemoveBlip(dropoffBlip)
        dropoffBlip = nil
    end

    currentLocation = nil
    currentDifficulty = nil
    currentDropoffIndex = nil
end

-- =====================
-- MAIN MISSION LOOP
-- =====================

local function StartMission(difficultyName, locationIndex, dropoff, dropoffIndex)
    if missionActive then
        Notify("A mission is already active.", "error")
        return
    end

    currentDifficulty = nil
    for _, d in ipairs(Config.Difficulties) do
        if d.name == difficultyName then
            currentDifficulty = d
            break
        end
    end
    if not currentDifficulty then return end

    currentLocation = Config.Locations[locationIndex]
    if not currentLocation then return end
    currentDropoffIndex = dropoffIndex

    missionActive = true
    zoneEntered = false
    trackerActive = true
    dropoffRevealed = false
    dropoffCoords = dropoff

    Notify("Mission started! Head to the marked location and deal with the guards.", "success")
    ShowTask(1)

    SpawnMissionVehicle(currentLocation)
    SpawnGuardNPCs(currentLocation, currentDifficulty)
    BroadcastMissionEntities()
    StartTrackerLoop()

    missionBlip = AddBlipForCoord(currentLocation.vehicle.coords.x, currentLocation.vehicle.coords.y, currentLocation.vehicle.coords.z)
    SetBlipSprite(missionBlip, 161)
    SetBlipColour(missionBlip, 1)
    SetBlipScale(missionBlip, 0.9)
    SetBlipAsShortRange(missionBlip, false)
    SetBlipFlashes(missionBlip, true)
    SetBlipRoute(missionBlip, true)
    SetBlipRouteColour(missionBlip, 1) -- explicit color so the route line can't render invisible on a dark map skin
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName("Gang Heist")
    EndTextCommandSetBlipName(missionBlip)

    CreateThread(function()
        while missionActive do
            Wait(250)
            local playerCoords = GetEntityCoords(PlayerPedId())

            if not zoneEntered then
                local distToZone = #(playerCoords - currentLocation.zoneCenter)
                if distToZone < currentLocation.zoneRadius then
                    zoneEntered = true
                    NotifyPolice(currentLocation.zoneCenter)
                    AddPoliceBlip(currentLocation.zoneCenter)
                    Notify("Police have been alerted to your location!", "error")
                    ShowTask(2)
                end
            end
        end
    end)
end

-- =====================
-- STARTER NPC THREAD
-- =====================

CreateThread(function()
    SpawnStarterNPC()
end)

-- =====================
-- EVENTS
-- =====================

RegisterNetEvent("mv-convoyheist:client:missionAllowed", function(data)
    StartMission(data.difficulty, data.locationIndex, data.dropoff, data.dropoffIndex)
end)

RegisterNetEvent("mv-convoyheist:client:cancelMission", function()
    CleanupMission()
    Notify("Mission cancelled.", "error")
end)

-- =====================
-- RESOURCE STOP
-- Without this, restarting the resource leaves the starter NPC and any
-- mission entities in the world with qb-target options pointing at a dead
-- script environment, which spams "Execution of function reference in
-- script host failed" until the server restarts.
-- =====================

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    CleanupMission()
    SendNUIMessage({ action = "hideDialogue" })

    -- Also strip targets registered while helping out on someone ELSE's
    -- mission - otherwise their qb-target entries survive the restart
    -- pointing at a dead script environment, which can hard-crash a native
    -- the next time qb-target's raycast evaluates that stale closure
    for contact in pairs(remoteContacts) do
        if DoesEntityExist(contact) then
            exports['qb-target']:RemoveTargetEntity(contact)
        end
    end
    remoteContacts = {}
    remoteGuards = {}

    if starterNPCHandle and DoesEntityExist(starterNPCHandle) then
        exports['qb-target']:RemoveTargetEntity(starterNPCHandle)
        DeleteEntity(starterNPCHandle)
    end

    if starterBlip then
        RemoveBlip(starterBlip)
    end
end)

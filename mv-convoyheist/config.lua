Config = {}

----------------------------------------------------------------
-- STARTER NPC (third-eye interaction only, no [E] press, no menu)Tge
----------------------------------------------------------------
Config.StarterNPC = {
    model = "u_m_y_party_01",
    coords = vector4(105.06, -932.98, 29.81, 251.65), -- Place the contact NPC here
    label = "Gang Heist Contact",
    targetIcon = "fas fa-mask",
    targetLabel = "Talk to Contact",
    targetDistance = 2.5,
    collectCashIcon = "fas fa-money-bill-wave",
    collectCashLabel = "Collect Cash",
    noPayoutMessage = "You haven't done any work for me.", -- Shown when there's nothing owed (mission not started, not finished, or already collected)
    cancelIcon = "fas fa-ban",
    cancelLabel = "Cancel Contract",
}

----------------------------------------------------------------
-- CASH COLLECT EMOTE
-- Plays on both the player and the Starter NPC together (synced) when a
-- payout is actually collected, with a cash prop attached to the player's
-- hand for the duration.
----------------------------------------------------------------
Config.CashCollectEmote = {
    dict = "mp_common",
    playerAnim = "givetake1_b", -- player receiving
    npcAnim = "givetake1_a",    -- npc giving
    duration = 3000,
    prop = {
        model = "bkr_prop_bkr_cashpile_01",
        bone = 0x6470, -- SKEL_R_HAND
        offset = vector3(0.0, 0.0, 0.0),
        rotation = vector3(0.0, 0.0, 0.0),
    },
}

----------------------------------------------------------------
-- STARTER CONVERSATION
-- Shown as on-screen subtitles before the mission actually starts, so
-- talking to the contact can't accidentally kick off a mission. Lines play
-- one at a time - press ENTER to advance. Once they're all read, a small
-- Accept/Decline choice is shown.
----------------------------------------------------------------
Config.StarterConversation = {
    speaker = "Contact",
    lines = {
        "You looking for work?",
        "Crew's sitting on a vehicle I need. Deal with them, then bring the vehicle back to me.",
        "Could have a tracker on it. Bring something to deal with that before the cops beat you there.",
    },
    acceptLabel = "Accept Contract",
    acceptText = "\"I'm in. Where do I start?\"",
    declineLabel = "Not Right Now",
    declineText = "\"Not today.\"",
}

----------------------------------------------------------------
-- CANCEL CONVERSATION
-- Shown when talking to the contact while a mission is already active for
-- you. Only appears once a contract has been started.
----------------------------------------------------------------
Config.CancelConversation = {
    speaker = "Contact",
    lines = {
        "Calling already? This better be good.",
    },
    confirmLabel = "Cancel Contract",
    confirmText = "\"I'm out, forget the job.\"",
    backLabel = "Nevermind",
    backText = "\"Just checking in. Still on it.\"",
}

----------------------------------------------------------------
-- GENERAL SETTINGS
----------------------------------------------------------------
Config.MinPlayers = 1      -- Minimum players online needed to start the mission
Config.MinPoliceCount = 0  -- Minimum on-duty police needed to start the mission (0 = no requirement)
Config.StartCost = 0       -- Cash cost to start the mission (0 = free)
Config.Cooldown = 600       -- Cooldown per player between missions (seconds)

----------------------------------------------------------------
-- TASK HUD
-- Persistent top-right "Current Task" widget, visible only to the player
-- who started the mission. Press toggleKey to hide/show it.
----------------------------------------------------------------
Config.TaskHUD = {
    toggleKey = "G",
    messages = {
        "Go to the location and take out the guards.",
        "Get in the vehicle and remove the GPS tracker.",
        "Deliver the vehicle to the dropoff point.",
    },
}

----------------------------------------------------------------
-- GUARDS
-- Spawned in a ring around the mission vehicle at a random angle (not
-- hand-placed coordinates) - count/spawnRadius apply at every location.
-- Using a real gang ped (East Side Ballas) for the look only - peds
-- created with CreatePed do NOT inherit their model's native gang
-- relationship data (that only applies to peds spawned by the game's own
-- population system), so client/main.lua explicitly assigns every guard
-- to a dedicated "convoyheist_guard" relationship group (Companion to
-- itself, Hate toward the player) instead of relying on the model alone.
-- Per-difficulty stats (health/armor/accuracy/weapon) are on each entry
-- in Config.Difficulties below.
----------------------------------------------------------------
Config.Guards = {
    count = 3,
    spawnRadius = 10.0, -- meters from the vehicle
    model = "g_m_y_ballaeast_01",
}

----------------------------------------------------------------
-- DIFFICULTY
-- One is picked at random (uniform chance) when the mission starts - players
-- never choose. locationIndex ties each difficulty to a fixed entry in
-- Config.Locations below (so the same difficulty always uses the same
-- location); leave it nil to pick a random location instead.
----------------------------------------------------------------
Config.Difficulties = {
    {
        name = "easy",
        label = "Easy",
        locationIndex = 1, -- Easy always uses Config.Locations[1]
        npcHealth = 100,
        npcArmor = 50,
        npcAccuracy = 20,
        npcWeapon = "WEAPON_ASSAULTRIFLE",
    },
    {
        name = "hard",
        label = "Hard",
        locationIndex = 2, -- Hard always uses Config.Locations[2]
        npcHealth = 200,
        npcArmor = 100,
        npcAccuracy = 60,
        npcWeapon = "WEAPON_ASSAULTRIFLE",
    },
}

----------------------------------------------------------------
-- LOCATIONS
-- One is picked at random (via the difficulty above). Guards spawn around
-- vehicle.coords per Config.Guards above - no hand-placed guard coords here.
----------------------------------------------------------------
Config.Locations = {
    [1] = {
        label = "Construction Site..",
        vehicle = {
            model = "vstr",
            coords = vector4(-926.56, 401.57, 78.55, 247.62),
        },
        zoneCenter = vector3(-915.42, 377.98, 80.34), -- Used to trigger the initial police alert
        zoneRadius = 80.0,
    },
    [2] = {
        label = "Location 2 - Warehouse",
        vehicle = {
            model = "Torero",
            coords = vector4(1000.34, -1533.16, 29.37, 89.41),
        },
        zoneCenter = vector3(970.24, -1534.65, 30.81),
        zoneRadius = 80.0,
    },
}

----------------------------------------------------------------
-- DROPOFF
-- One of 3 locations is picked at random when the mission starts, but it
-- only becomes visible (and its 3 NPCs only spawn in) once the tracker is
-- hacked off. Drive the vehicle up to the "contact" NPC and use the third
-- eye on them to hand the vehicle over. Exactly one npc per location must
-- have role = "contact" - that is the only one with a target option.
----------------------------------------------------------------
Config.Dropoff = {
    locations = {
        {
            coords = vector4(-1354.95, 735.65, 184.44, 64.98), -- Blip / where the contact stands
            npcs = {
                --{ coords = vector4(-3028.36, 1892.28, 18.7, 170.44), role = "escort",  model = "csb_vincent" },
                { coords = vector4(-1354.95, 735.65, 184.44, 64.98), role = "contact", model = "u_m_y_party_01" },
                --{ coords = vector4(-3028.36, 1892.28, 18.7, 170.44), role = "escort",  model = "csb_thornton" },
            },
        },
        {
            coords = vector4(-271.12, 2196.46, 129.79, 207.77),
            npcs = {
                --{ coords = vector4(-3028.36, 1892.28, 18.7, 170.44), role = "escort",  model = "csb_vincent" },
                { coords = vector4(-271.12, 2196.46, 129.79, 207.77), role = "contact", model = "u_m_y_party_01" },
                --{ coords = vector4(-3028.36, 1892.28, 18.7, 170.44), role = "escort",  model = "csb_thornton" },
            },
        },
        {
            coords = vector4(-3182.54, 1293.58, 14.59, 207.74),
            npcs = {
                --{ coords = vector4(-3028.36, 1892.28, 18.7, 170.44), role = "escort",  model = "csb_vincent" },
                { coords = vector4(-3182.54, 1293.58, 14.59, 207.74), role = "contact", model = "u_m_y_party_01" },
                --{ coords = vector4(-3028.36, 1892.28, 18.7, 170.44), role = "escort",  model = "csb_thornton" },
            },
        },
    },
    interactDistance = 2.5,    -- Third-eye distance on the contact NPC
    vehicleProximity = 12.0,   -- How close the vehicle must be to the contact to allow the handover
    targetLabel = "Hand Over Vehicle",
    targetIcon = "fas fa-handshake",
    handoverAnim = { dict = "mp_common", giveAnim = "givetake1_a", takeAnim = "givetake1_b", duration = 3000 }, -- Cosmetic only, plays on the player without delaying cash/departure
    despawnDelay = 20000,   -- How long (ms) after driving off before the vehicle + NPCs are removed
    blipSprite = 1,
    blipColor = 2,
    blipLabel = "Vehicle Dropoff",
    reward = { cash = 10000 }, -- Bonus cash for handing over the vehicle (0 = disabled)
}

----------------------------------------------------------------
-- VEHICLE TRACKER
-- Police get a position ping on an interval until a player inside the
-- vehicle wins the hacking minigame to disable it.
----------------------------------------------------------------
Config.Tracker = {
    hackKey = "H",            -- Key used while inside the vehicle to start the hack (also usable via the item below)
    requiredItem = "hackdevice", -- Item needed to hack the tracker, set to nil/"" to allow hacking with no item
    consumeItem = false,      -- Set to true to remove the item from inventory on a successful hack
    notifyInterval = 6000,    -- How often (ms) police receive a position ping
    keyMinigameAmount = 6,    -- qb-minigames KeyMinigame: how many arrow-key prompts to clear
    keyMinigameMaxFaults = 2, -- How many wrong/missed key presses are still allowed to count as a success
    pingMessage = "Tracking signal received from the stolen vehicle.",
    blipSprite = 161,
    blipColor = 1,
    blipScale = 0.8,
    blipTimeout = 7000, -- How long each ping blip stays on the map before the next ping
}

----------------------------------------------------------------
-- POLICE NOTIFICATION
-- One-time alert sent the moment a player enters the heist zone.
----------------------------------------------------------------
Config.PoliceNotify = {
    message = "10-71 Shots fired and armed suspects reported. Respond immediately!",
    blipSprite = 161,
    blipColor = 1,
    blipScale = 0.8,
    blipLabel = "Gang Heist",
    blipFlash = true,
    blipTimeout = 60000, -- How long the police blip stays on the map (ms)
}

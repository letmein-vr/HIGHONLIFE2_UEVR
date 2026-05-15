--[[
    main.lua — High On Life 2 UEVR weapon depth + attachment + hand-sync fix

    PERFORMANCE DESIGN:
    - Stereo callback is kept intentionally minimal: one bool check + one
      pre-cached animation.updateAnimation call. Nothing else.
    - fixComponentTree  →  one-shot in buildCache / attachHandToWeapon only
    - applyHandOffset   →  one-shot on weapon attach + slider change only
    - No per-frame table allocations. GRIP_ANIM_PARAMS is pre-cached.

    DEPTH FIX:
    All player weapon attachment actors have their RootComponent and children
    flagged for first-person rendering (FOV=-1, FirstPersonPrimitiveType=1,
    LightingChannels.bChannel2=true). Together these cause the weapon to always
    render on top of hand meshes.
    Fixed ONCE on weapon detection/change.

    RIGHT HAND:
    - Right hand PMC is re-parented to weapon JNT_r_hand socket for bob/recoil
      sync. Offset applied once on attach + on every slider change.
    - Grip pose locked via animation.updateAnimation in stereo callback (post-
      input) to prevent the hands-lib input handler from reverting to open pose.

    LEFT HAND / KNIFEY MELEE:
    - Left hand PMC is re-parented to the KnifeyDummy SkeletalMeshComponent while
      bHiddenInGame == false on that mesh (= Knifey is visible = melee is active).
    - Detection uses a per-frame poll (near-zero cost once cached).
    - A configui offset profile (position + rotation) is applied after attach,
      adjustable live via the 'Knifey / Melee Left Hand Adjustment' panel section.
    - On melee end, left PMC is re-attached to the left controller.
]]



local uevrUtils   = require('libs/uevr_utils')
local attachments = require('libs/attachments')
local hands       = require('libs/hands')
local controllers = require('libs/controllers')
local configui    = require('libs/configui')
local animation   = require('libs/animation')
local input       = require('libs/input')  -- for cutscene: input.setDisabled()

attachments.init(false)

-- ──────────────────────────────────────────────
-- Weapon class list
-- ──────────────────────────────────────────────

local WEAPON_LIST = { "Sweezy", "Gus", "Gale", "Travis", "Jan", "Stooges", "Creature", "Bowie", "Sheath", "PrisonGun" }

local WEAPON_CLASSES = {
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Sweezy/Sweezy_WeaponAttachment_BP.Sweezy_WeaponAttachment_BP_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Gus/Gus_WeaponAttachment_BP.Gus_WeaponAttachment_BP_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Gale/Gale_WeaponAttachment_BP.Gale_WeaponAttachment_BP_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Travis/Travis_WeaponAttachment_BP.Travis_WeaponAttachment_BP_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Travis/Jan_WeaponAttachment_BP.Jan_WeaponAttachment_BP_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/BALL/Stooges_WeaponAttachment_BP.Stooges_WeaponAttachment_BP_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Creature/Creature_WeaponAttachment_BP.Creature_WeaponAttachment_BP_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Bowie/Bowie_WeaponAttachment_BP.Bowie_WeaponAttachment_BP_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Sheath/BP_Sheath_WeaponAttachment.BP_Sheath_WeaponAttachment_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/GunO/BP_PrisonGun_WeaponAttachment.BP_PrisonGun_WeaponAttachment_C",
}

local CLS_TO_NAME = {}
for i, cls in ipairs(WEAPON_CLASSES) do
    CLS_TO_NAME[cls] = WEAPON_LIST[i]
end

-- ──────────────────────────────────────────────
-- Throwable item class list (Lugblob etc.)
-- Detected via WeaponAttachment actor; RootComponent == ItemMeshComponent (JNT_r_hand socket).
-- Equip check uses the native bIsEquipped flag rather than bHidden+bVisible.
-- ──────────────────────────────────────────────

local THROWABLE_CLASSES = {
    "BlueprintGeneratedClass /Game/Blueprints/Interactables/LugBlob/PickupItem/BP_Lugblob_WeaponAttachment.BP_Lugblob_WeaponAttachment_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Pickups/FlintTurtle/BP_FlintTurtle_WeaponAttachment.BP_FlintTurtle_WeaponAttachment_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Pickups/Hammerbird/BP_Hammerbird_WeaponAttachment.BP_Hammerbird_WeaponAttachment_C",
    "BlueprintGeneratedClass /Game/Blueprints/Guns/Pickups/CannonWorm/BP_CannonWorm_WeaponAttachment.BP_CannonWorm_WeaponAttachment_C",
}
local THROWABLE_NAMES = { "Lugblob", "FlintTurtle", "Hammerbird", "CannonWorm" }

-- Fast lookup set so the grip callback can identify throwables in O(1)
local THROWABLE_CLS_SET = {}
for i, cls in ipairs(THROWABLE_CLASSES) do
    CLS_TO_NAME[cls] = THROWABLE_NAMES[i]
    THROWABLE_CLS_SET[cls] = true
end

-- Class constant for the Suit-O / PrisonGun (left-hand primary weapon).
-- Declared here (before findCurrentWeaponMesh) so LEFT_HAND_WEAPON_CLASSES
-- lookup resolves correctly at call time.
local PRISONGUN_CLASS = "BlueprintGeneratedClass /Game/Blueprints/Guns/GunO/BP_PrisonGun_WeaponAttachment.BP_PrisonGun_WeaponAttachment_C"

-- Left-hand primary weapons: findCurrentWeaponMesh() skips these entirely
-- so the right-hand grip callback never mis-attaches the right PMC to them.
local LEFT_HAND_WEAPON_CLASSES = {
    [PRISONGUN_CLASS] = true,
}

-- ──────────────────────────────────────────────
-- Weapon mesh cache
-- ──────────────────────────────────────────────

local weaponMeshCache    = {}
local throwableMeshCache = {}
local cacheBuilt = false

-- ──────────────────────────────────────────────
-- Depth fix (one-shot, called on weapon change only)
-- ──────────────────────────────────────────────

local function fixComponent(comp)
    if comp == nil then return end
    pcall(function() comp.FOV = 0 end)
    pcall(function() comp.FirstPersonPrimitiveType = 0 end)
    pcall(function() comp.DepthPriorityGroup = 0 end)
    pcall(function() comp.bUseViewOwnerDepthPriorityGroup = false end)
    pcall(function() comp.bRenderCustomDepth = false end)
    pcall(function() comp.bCastInsetShadow = false end)
    pcall(function()
        local lc = comp.LightingChannels
        if lc ~= nil then
            lc.bChannel2 = false
            comp.LightingChannels = lc
        end
    end)
end

local function fixComponentTree(comp)
    if comp == nil then return end
    -- Skip PoseableMeshComponent (VR hand PMC): its depth priority is managed
    -- separately so fixComponentTree doesn't clobber the foreground setting.
    local clsName = ""
    pcall(function() clsName = comp:get_class():get_name() end)
    if clsName ~= "PoseableMeshComponent" then
        fixComponent(comp)
    end
    local kids = nil
    pcall(function() kids = comp.AttachChildren end)
    if kids == nil then return end
    for _, child in ipairs(kids) do
        pcall(function() fixComponentTree(child) end)
    end
end

local function findItemMeshRecursive(comp)
    if comp == nil then return nil end
    local clsName = ""
    pcall(function() clsName = comp:get_class():get_name() end)
    if clsName == "SkeletalMeshComponent" then
        local n = ""
        pcall(function() n = comp:get_fname():to_string() end)
        if n == "ItemMesh" or n:find("ItemMesh") then
            return comp
        end
    end
    local kids = nil
    pcall(function() kids = comp.AttachChildren end)
    if kids then
        for _, k in ipairs(kids) do
            local found = findItemMeshRecursive(k)
            if found then return found end
        end
    end
    return nil
end
local classPointerCache = {}
-- HOL2 PERF FIX (rev 2): replaced the tick-based cooldown with a real wall-clock
-- cooldown using os.time() (integer seconds). The original CLASS_COOLDOWN_TICKS=3600
-- was designed for 120fps (~30s), but at 40fps VR it became ~90s — causing periodic
-- GUObjectArray string scans (get_class) every ~1.5 minutes for any unresolved class.
-- os.time() is safe here: it returns wall-clock seconds, unlike os.clock() which
-- measures multi-core CPU time and was rightly avoided in the previous version.
local classFailedTime   = {}   -- [className] = os.time() when last failed
local classFailRetries  = {}   -- [className] = number of failed resolution attempts
local CLASS_COOLDOWN_SECS = 30 -- 30 real seconds between retry attempts (fps-independent)
local CLASS_MAX_RETRIES   = 5  -- after 5 failures (~2.5 min total), give up until level change

local function resolveClassFast(clsNameStr)
    local cached = classPointerCache[clsNameStr]
    if cached ~= nil then return cached end

    -- Give-up guard: class not in memory after CLASS_MAX_RETRIES attempts —
    -- stop retrying entirely until on_level_change resets classFailRetries.
    if (classFailRetries[clsNameStr] or 0) >= CLASS_MAX_RETRIES then
        return nil
    end

    -- Wall-clock negative-cache cooldown (fps-independent: os.time() = real seconds)
    local failTime = classFailedTime[clsNameStr]
    if failTime ~= nil and (os.time() - failTime) < CLASS_COOLDOWN_SECS then
        return nil  -- still in cooldown, skip
    end

    -- Attempt resolution (expensive: GUObjectArray string scan via find_uobject)
    local c = uevrUtils.get_class(clsNameStr)
    if c ~= nil then
        classPointerCache[clsNameStr] = c
        classFailedTime[clsNameStr]  = nil
        classFailRetries[clsNameStr] = nil
        return c
    else
        -- Class not in memory — record wall-clock timestamp and increment retry count
        classFailedTime[clsNameStr]  = os.time()
        classFailRetries[clsNameStr] = (classFailRetries[clsNameStr] or 0) + 1
        return nil
    end
end

-- ──────────────────────────────────────────────
-- Shared weapon discovery: resolve actor → mesh
-- Used by both initial buildCache and background round-robin scan.
-- ──────────────────────────────────────────────

local function _resolveWeaponMesh(clsStr)
    local uClass = resolveClassFast(clsStr)
    if not uClass then
        -- HOL2 PERF FIX: Mark as "not found" so _tryDiscoverOneWeapon doesn't
        -- retry this class every 150ms. false acts as a "cooldown" sentinel.
        -- The on_level_change handler resets this to nil for fresh discovery.
        if weaponMeshCache[clsStr] == nil then
            weaponMeshCache[clsStr] = false
        end
        return
    end

    local allActors = uevrUtils.find_all_of(clsStr, false)
    if not allActors then return end
    
    for _, rawActor in ipairs(allActors) do
        local actor = uevrUtils.getValid(rawActor)
        -- We STRICTLY only cache the weapon if it is currently visible in-game.
        -- This guarantees we bypass permanently hidden "Dummy" archetype weapons.
        if actor ~= nil and actor.bHidden == false then
            -- Skip cinematic/MovieScene instances — some weapons (e.g. PrisonGun)
            -- have a duplicate actor inside a MovieScene for cutscenes. We only
            -- want the real level-owned WeaponAttachment actor.
            local actorPath = ""
            pcall(function() actorPath = actor:get_full_name() end)
            if actorPath:find("MovieScene") then goto continue_actors end

            local itemMesh
            pcall(function() itemMesh = uevrUtils.getValid(actor.ItemMesh) end)
            if not itemMesh then
                pcall(function()
                    local root = uevrUtils.getValid(actor.RootComponent)
                    itemMesh = findItemMeshRecursive(root)
                end)
            end
            local mesh = itemMesh or uevrUtils.getValid(actor.RootComponent)
            if mesh then
                weaponMeshCache[clsStr] = { actor = actor, mesh = mesh }
                -- Apply depth fix immediately since this is the active weapon
                if mesh.bVisible == true then
                    pcall(function() 
                        local rootNode = actor.RootComponent or mesh
                        fixComponentTree(rootNode)
                        if rootNode.SetVisibility then
                            rootNode:SetVisibility(false, true)
                            rootNode:SetVisibility(true, true)
                        end
                    end)
                end
                return -- Stop after caching the real one!
            end
        end
        ::continue_actors::
    end
end

-- ──────────────────────────────────────────────
-- Initial cache build (called once at level load)
-- Scans all WEAPON_CLASSES in one pass.
-- If an actor isn't in the world yet, leaves cache[cls] = nil
-- so the background round-robin will pick it up later.
-- ──────────────────────────────────────────────

local function buildCache()
    for _, cls in ipairs(WEAPON_CLASSES) do
        -- nil = not yet tried; false = tried and not found (skip until level change)
        if weaponMeshCache[cls] == nil then
            _resolveWeaponMesh(cls)
        end
    end
    cacheBuilt = true
end

-- ──────────────────────────────────────────────
-- Background round-robin weapon discovery
-- Called once per grip poll (every ~150ms).
-- Scans at most ONE nil-entry weapon class per call — no burst, no hitch.
-- ──────────────────────────────────────────────

local _scanIndex = 1

local function _tryDiscoverOneWeapon()
    local count = #WEAPON_CLASSES
    -- Walk the list: scan only classes that are nil (not yet tried this level).
    -- false = tried but class not in memory → skip entirely (tick-cooldown guards repeat calls).
    -- This prevents 7 × 65ms GUObjectArray scans every 150ms in levels with no weapons.
    for i = 1, count do
        local idx = ((_scanIndex - 1 + i - 1) % count) + 1
        local cls = WEAPON_CLASSES[idx]
        if weaponMeshCache[cls] == nil then
            _scanIndex = (idx % count) + 1
            _resolveWeaponMesh(cls)
            return  -- one scan per call, done
        end
    end
    _scanIndex = (_scanIndex % count) + 1
end

-- ──────────────────────────────────────────────
-- Weapon mesh lookup — PURE READ, zero GUObjectArray scanning.
-- Discovery is handled by buildCache + _tryDiscoverOneWeapon.
-- ──────────────────────────────────────────────

-- Steady-state cache: avoids re-running getValid() on every grip tick when
-- the player holds the same weapon frame-over-frame. Cleared on weapon change.
local _lastWeaponMesh = nil
local _lastWeaponCls  = nil

local function findCurrentWeaponMesh()
    if not cacheBuilt then buildCache() end

    -- Fast path: if the previously-returned mesh is still visible and its actor
    -- still exists, return immediately — zero getValid() bridge calls.
    if _lastWeaponMesh ~= nil then
        local lastEntry = weaponMeshCache[_lastWeaponCls]
        if type(lastEntry) == "table"
            and lastEntry.actor.bHidden == false
            and lastEntry.mesh.bVisible == true then
            return _lastWeaponMesh, _lastWeaponCls
        end
        -- Weapon changed or unequipped — fall through to full scan
        _lastWeaponMesh = nil
        _lastWeaponCls  = nil
    end

    for _, cls in ipairs(WEAPON_CLASSES) do
        local entry = weaponMeshCache[cls]
        -- nil = not yet scanned; false = scanned but not in memory → both skip
        if entry == nil or entry == false then goto continue end

        -- Validate: clear dead actor pointers so round-robin re-discovers
        if uevrUtils.getValid(entry.actor) == nil then
            weaponMeshCache[cls] = nil
            goto continue
        end

        -- Compound check: actor.bHidden==false rules out unarmed sections where
        -- the actor is hidden but mesh.bVisible stays stale (true). mesh.bVisible==true
        -- rules out holstered-but-in-inventory weapons (actor visible, mesh not).
        if entry.actor.bHidden == false and entry.mesh.bVisible == true then
            _lastWeaponMesh = entry.mesh
            _lastWeaponCls  = cls
            return entry.mesh, cls
        end

        ::continue::
    end

    -- Second pass: throwable items (Lugblob etc.).
    for _, cls in ipairs(THROWABLE_CLASSES) do
        local entry = throwableMeshCache[cls]
        if type(entry) == "table" then
            return entry.mesh, cls
        end
    end

    return nil, nil
end


-- ──────────────────────────────────────────────
-- Per-weapon hand offset profiles
-- ──────────────────────────────────────────────

local HOL2_PANEL = "High On Life 2 Config"
local HOL2_SAVE  = "hol2_hand_config"

local currentWeaponName = nil

-- Offsets stored in a plain Lua table — no per-frame configui.getValue calls.
-- Populated by onCreateOrUpdate (fires on widget creation/load AND on drag).
local weaponOffsets = {}  -- { [weaponName] = { px, py, pz, rx, ry, rz } }

local function getVec3(v)
    if v == nil then return 0.0, 0.0, 0.0 end
    if type(v) == "userdata" or (type(v) == "table" and type(v.x) == "number") then
        return v.x, v.y, v.z
    end
    return (v[1] or 0.0), (v[2] or 0.0), (v[3] or 0.0)
end

-- One-shot offset apply (right hand). Called on weapon change and slider change only.
local function applyHandOffset(handPMC)
    if currentWeaponName == nil then return end
    handPMC = handPMC or hands.getHandComponent(Handed.Right)
    if handPMC == nil then return end
    local off = weaponOffsets[currentWeaponName]
    if off == nil then return end
    pcall(function()
        handPMC.RelativeLocation = { X = off[1], Y = off[2], Z = off[3] }
        handPMC.RelativeRotation = { Pitch = off[4], Yaw = off[5], Roll = off[6] }
    end)
end

-- Left hand melee offset (Knifey). Applied after K2_AttachTo and on slider drag.
local knifeyMeleeOffset = { 0, 0, 0, 0, 0, 0 }  -- { px, py, pz, rx, ry, rz }

local JAN_CLASS      = "BlueprintGeneratedClass /Game/Blueprints/Guns/Travis/Jan_WeaponAttachment_BP.Jan_WeaponAttachment_BP_C"
-- PRISONGUN_CLASS and LEFT_HAND_WEAPON_CLASSES are declared near the top (before findCurrentWeaponMesh)
local inJanDualWield      = false
local inPrisonGunLeftHand = false
local janHandOffset      = { 0, 0, 0, 0, 0, 0 }
local prisonGunHandOffset = { 0, 0, 0, 0, 0, 0 }
local function applyMeleeHandOffset(leftPMC)
    leftPMC = leftPMC or hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return end
    -- Read directly from the widget every time — onCreateOrUpdate may have fired
    -- with initialValue={0,0,0} before the JSON was loaded, so knifeyMeleeOffset
    -- could be stale after a restart. getValue always returns the current loaded value.
    pcall(function()
        local pv = configui.getValue("hol2_melee_pos")
        local rv = configui.getValue("hol2_melee_rot")
        if pv then knifeyMeleeOffset[1], knifeyMeleeOffset[2], knifeyMeleeOffset[3] = getVec3(pv) end
        if rv then knifeyMeleeOffset[4], knifeyMeleeOffset[5], knifeyMeleeOffset[6] = getVec3(rv) end
    end)
    local off = knifeyMeleeOffset
    pcall(function()
        leftPMC.RelativeLocation = { X = off[1], Y = off[2], Z = off[3] }
        leftPMC.RelativeRotation = { Pitch = off[4], Yaw = off[5], Roll = off[6] }
    end)
end

-- Build config panel
local handWidgets = {
    { widgetType = "tree_node", id = "hol2_hands_node", label = "Hands Config", initialOpen = true },
    { widgetType = "text_colored", id = "hol2_active_weapon", label = "Active weapon: none",
      color = "#88FF88FF" },
    { widgetType = "spacing" },
    { widgetType = "text", label = "Each weapon saves its own offset profile." },
    { widgetType = "spacing" },
}

for _, name in ipairs(WEAPON_LIST) do
    table.insert(handWidgets, {
        widgetType = "tree_node", id = "hol2_tree_" .. name,
        label = name, initialOpen = false,
    })
    table.insert(handWidgets, {
        widgetType = "drag_float3", id = "hol2_pos_" .. name,
        label = "Position (X, Y, Z)", speed = 0.1, range = { -50, 50 }, initialValue = { 0, 0, 0 },
    })
    table.insert(handWidgets, {
        widgetType = "drag_float3", id = "hol2_rot_" .. name,
        label = "Rotation (P, Y, R)", speed = 0.5, range = { -180, 180 }, initialValue = { 0, 0, 0 },
    })
    table.insert(handWidgets, { widgetType = "spacing" })
    table.insert(handWidgets, {
        widgetType = "button", id = "hol2_reset_" .. name,
        label = "Reset " .. name, size = { 110, 22 },
    })
    table.insert(handWidgets, { widgetType = "tree_pop" })
end

-- ──────────────────────────────────────────────
-- Throwable items config UI
-- ──────────────────────────────────────────────

local ITEM_LIST = { "Lugblob", "FlintTurtle", "Hammerbird", "CannonWorm" }

for _, name in ipairs(ITEM_LIST) do
    table.insert(handWidgets, {
        widgetType = "tree_node", id = "hol2_item_tree_" .. name,
        label = name .. " (Throwable)", initialOpen = false,
    })
    table.insert(handWidgets, {
        widgetType = "drag_float3", id = "hol2_item_pos_" .. name,
        label = "Position (X, Y, Z)", speed = 0.1, range = { -50, 50 }, initialValue = { 0, 0, 0 },
    })
    table.insert(handWidgets, {
        widgetType = "drag_float3", id = "hol2_item_rot_" .. name,
        label = "Rotation (P, Y, R)", speed = 0.5, range = { -180, 180 }, initialValue = { 0, 0, 0 },
    })
    table.insert(handWidgets, { widgetType = "spacing" })
    table.insert(handWidgets, {
        widgetType = "button", id = "hol2_item_reset_" .. name,
        label = "Reset " .. name, size = { 110, 22 },
    })
    table.insert(handWidgets, { widgetType = "tree_pop" })
end

table.insert(handWidgets, {
    widgetType = "tree_node", id = "hol2_melee_node",
    label = "Knifey / Melee Left Hand Adjustment", initialOpen = false,
})
table.insert(handWidgets, {
    widgetType = "text", label = "Offset applied while left hand is attached to Knifey.",
})
table.insert(handWidgets, { widgetType = "spacing" })
table.insert(handWidgets, {
    widgetType = "drag_float3", id = "hol2_melee_pos",
    label = "Position (X, Y, Z)", speed = 0.1, range = { -50, 50 }, initialValue = { 0, 0, 0 },
})
table.insert(handWidgets, {
    widgetType = "drag_float3", id = "hol2_melee_rot",
    label = "Rotation (P, Y, R)", speed = 0.5, range = { -180, 180 }, initialValue = { 0, 0, 0 },
})
table.insert(handWidgets, { widgetType = "spacing" })
table.insert(handWidgets, {
    widgetType = "button", id = "hol2_melee_reset",
    label = "Reset Melee Offset", size = { 140, 22 },
})
table.insert(handWidgets, { widgetType = "tree_pop" })

table.insert(handWidgets, {
    widgetType = "tree_node", id = "hol2_jan_hand_node",
    label = "Jan Left Hand Adjustment", initialOpen = false,
})
table.insert(handWidgets, {
    widgetType = "text", label = "Offset applied to left hand PMC while attached to Jan.",
})
table.insert(handWidgets, { widgetType = "spacing" })
table.insert(handWidgets, {
    widgetType = "drag_float3", id = "hol2_jan_hand_pos",
    label = "Position (X, Y, Z)", speed = 0.1, range = { -50, 50 }, initialValue = { 0, 0, 0 },
})
table.insert(handWidgets, {
    widgetType = "drag_float3", id = "hol2_jan_hand_rot",
    label = "Rotation (P, Y, R)", speed = 0.5, range = { -180, 180 }, initialValue = { 0, 0, 0 },
})
table.insert(handWidgets, { widgetType = "spacing" })
table.insert(handWidgets, {
    widgetType = "button", id = "hol2_jan_hand_reset",
    label = "Reset Offset", size = { 140, 22 },
})
table.insert(handWidgets, { widgetType = "tree_pop" })

table.insert(handWidgets, {
    widgetType = "tree_node", id = "hol2_prisongun_hand_node",
    label = "Suit-O (PrisonGun) Left Hand Adjustment", initialOpen = false,
})
table.insert(handWidgets, {
    widgetType = "text", label = "Offset applied to left hand PMC while Suit-O is equipped.",
})
table.insert(handWidgets, { widgetType = "spacing" })
table.insert(handWidgets, {
    widgetType = "drag_float3", id = "hol2_prisongun_hand_pos",
    label = "Position (X, Y, Z)", speed = 0.1, range = { -50, 50 }, initialValue = { 0, 0, 0 },
})
table.insert(handWidgets, {
    widgetType = "drag_float3", id = "hol2_prisongun_hand_rot",
    label = "Rotation (P, Y, R)", speed = 0.5, range = { -180, 180 }, initialValue = { 0, 0, 0 },
})
table.insert(handWidgets, { widgetType = "spacing" })
table.insert(handWidgets, {
    widgetType = "button", id = "hol2_prisongun_hand_reset",
    label = "Reset Offset", size = { 140, 22 },
})
table.insert(handWidgets, { widgetType = "tree_pop" })

table.insert(handWidgets, { widgetType = "tree_pop" })  -- close Hands Config

configui.createConfigPanel(HOL2_PANEL, HOL2_SAVE, handWidgets)
-- createConfigPanel → createPanel → load() fires onCreateOrUpdate immediately

for _, name in ipairs(WEAPON_LIST) do
    local n = name

    -- onCreateOrUpdate fires on initial load (from JSON) AND on every drag.
    -- We store values in weaponOffsets so applyHandOffset needs no configui lookup.
    local function onPosUpdate(v)
        if weaponOffsets[n] == nil then weaponOffsets[n] = { 0, 0, 0, 0, 0, 0 } end
        weaponOffsets[n][1], weaponOffsets[n][2], weaponOffsets[n][3] = getVec3(v)
        if n == "Jan" and inJanDualWield then
            local entry = weaponMeshCache[JAN_CLASS]
            if type(entry) == "table" and uevrUtils.getValid(entry.mesh) then
                pcall(function()
                    entry.mesh.RelativeLocation = { X = weaponOffsets[n][1], Y = weaponOffsets[n][2], Z = weaponOffsets[n][3] }
                end)
            end
        end
        if n == currentWeaponName then
            applyHandOffset()
        end
    end
    local function onRotUpdate(v)
        if weaponOffsets[n] == nil then weaponOffsets[n] = { 0, 0, 0, 0, 0, 0 } end
        weaponOffsets[n][4], weaponOffsets[n][5], weaponOffsets[n][6] = getVec3(v)
        if n == "Jan" and inJanDualWield then
            local entry = weaponMeshCache[JAN_CLASS]
            if type(entry) == "table" and uevrUtils.getValid(entry.mesh) then
                pcall(function()
                    entry.mesh.RelativeRotation = { Pitch = weaponOffsets[n][4], Yaw = weaponOffsets[n][5], Roll = weaponOffsets[n][6] }
                end)
            end
        end
        if n == currentWeaponName then
            applyHandOffset()
        end
    end

    configui.onCreateOrUpdate("hol2_pos_" .. n, onPosUpdate)
    configui.onCreateOrUpdate("hol2_rot_" .. n, onRotUpdate)

    configui.onUpdate("hol2_reset_" .. n, function(_)
        configui.setValue("hol2_pos_" .. n, Vector3f.new(0, 0, 0))
        configui.setValue("hol2_rot_" .. n, Vector3f.new(0, 0, 0))
    end)
end

-- Throwable item hand offset callbacks
for _, name in ipairs(ITEM_LIST) do
    local n = name
    local function onItemPosUpdate(v)
        if weaponOffsets[n] == nil then weaponOffsets[n] = { 0, 0, 0, 0, 0, 0 } end
        weaponOffsets[n][1], weaponOffsets[n][2], weaponOffsets[n][3] = getVec3(v)
        applyHandOffset()
    end
    local function onItemRotUpdate(v)
        if weaponOffsets[n] == nil then weaponOffsets[n] = { 0, 0, 0, 0, 0, 0 } end
        weaponOffsets[n][4], weaponOffsets[n][5], weaponOffsets[n][6] = getVec3(v)
        applyHandOffset()
    end
    configui.onCreateOrUpdate("hol2_item_pos_" .. n, onItemPosUpdate)
    configui.onCreateOrUpdate("hol2_item_rot_" .. n, onItemRotUpdate)
    configui.onUpdate("hol2_item_reset_" .. n, function(_)
        configui.setValue("hol2_item_pos_" .. n, Vector3f.new(0, 0, 0))
        configui.setValue("hol2_item_rot_" .. n, Vector3f.new(0, 0, 0))
    end)
end

-- Knifey melee offset callbacks
configui.onCreateOrUpdate("hol2_melee_pos", function(v)
    knifeyMeleeOffset[1], knifeyMeleeOffset[2], knifeyMeleeOffset[3] = getVec3(v)
    if inMelee then applyMeleeHandOffset() end
end)
configui.onCreateOrUpdate("hol2_melee_rot", function(v)
    knifeyMeleeOffset[4], knifeyMeleeOffset[5], knifeyMeleeOffset[6] = getVec3(v)
    if inMelee then applyMeleeHandOffset() end
end)
configui.onUpdate("hol2_melee_reset", function(_)
    configui.setValue("hol2_melee_pos", Vector3f.new(0, 0, 0))
    configui.setValue("hol2_melee_rot", Vector3f.new(0, 0, 0))
end)

-- Jan hand offset callbacks
local function applyJanHandOffset(leftPMC)
    leftPMC = leftPMC or hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return end
    pcall(function()
        local pv = configui.getValue("hol2_jan_hand_pos")
        local rv = configui.getValue("hol2_jan_hand_rot")
        if pv then janHandOffset[1], janHandOffset[2], janHandOffset[3] = getVec3(pv) end
        if rv then janHandOffset[4], janHandOffset[5], janHandOffset[6] = getVec3(rv) end
    end)
    local off = janHandOffset
    pcall(function()
        leftPMC.RelativeLocation = { X = off[1], Y = off[2], Z = off[3] }
        leftPMC.RelativeRotation = { Pitch = off[4], Yaw = off[5], Roll = off[6] }
    end)
end

configui.onCreateOrUpdate("hol2_jan_hand_pos", function(v)
    janHandOffset[1], janHandOffset[2], janHandOffset[3] = getVec3(v)
    if inJanDualWield then applyJanHandOffset() end
end)
configui.onCreateOrUpdate("hol2_jan_hand_rot", function(v)
    janHandOffset[4], janHandOffset[5], janHandOffset[6] = getVec3(v)
    if inJanDualWield then applyJanHandOffset() end
end)
configui.onUpdate("hol2_jan_hand_reset", function(_)
    configui.setValue("hol2_jan_hand_pos", Vector3f.new(0, 0, 0))
    configui.setValue("hol2_jan_hand_rot", Vector3f.new(0, 0, 0))
end)

-- PrisonGun (Suit-O) left hand offset callbacks
local function applyPrisonGunHandOffset(leftPMC)
    leftPMC = leftPMC or hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return end
    pcall(function()
        local pv = configui.getValue("hol2_prisongun_hand_pos")
        local rv = configui.getValue("hol2_prisongun_hand_rot")
        if pv then prisonGunHandOffset[1], prisonGunHandOffset[2], prisonGunHandOffset[3] = getVec3(pv) end
        if rv then prisonGunHandOffset[4], prisonGunHandOffset[5], prisonGunHandOffset[6] = getVec3(rv) end
    end)
    local off = prisonGunHandOffset
    pcall(function()
        leftPMC.RelativeLocation = { X = off[1], Y = off[2], Z = off[3] }
        leftPMC.RelativeRotation = { Pitch = off[4], Yaw = off[5], Roll = off[6] }
    end)
end
configui.onCreateOrUpdate("hol2_prisongun_hand_pos", function(v)
    prisonGunHandOffset[1], prisonGunHandOffset[2], prisonGunHandOffset[3] = getVec3(v)
    if inPrisonGunLeftHand then applyPrisonGunHandOffset() end
end)
configui.onCreateOrUpdate("hol2_prisongun_hand_rot", function(v)
    prisonGunHandOffset[4], prisonGunHandOffset[5], prisonGunHandOffset[6] = getVec3(v)
    if inPrisonGunLeftHand then applyPrisonGunHandOffset() end
end)
configui.onUpdate("hol2_prisongun_hand_reset", function(_)
    configui.setValue("hol2_prisongun_hand_pos", Vector3f.new(0, 0, 0))
    configui.setValue("hol2_prisongun_hand_rot", Vector3f.new(0, 0, 0))
end)



-- ──────────────────────────────────────────────
-- Stereo callback — INTENTIONALLY MINIMAL
--
-- Only job: force grip animation ON every frame while a weapon is equipped.
-- This overrides handleInputForHands (which runs at input-poll time and sets
-- right_grip_weapon to OFF when the grip button is released).
--
-- Everything else (depth fix, offset apply) has been moved out of here to
-- one-shot calls on weapon change. No per-frame mesh walks or field writes.
-- ──────────────────────────────────────────────

local weaponEquipped = false   -- written by grip callback; read here

-- Pre-allocated — avoids creating a new table closure every VR frame
local GRIP_ANIM_PARAMS = { duration = 0 }
local function _forceGripAnim()
    animation.updateAnimation("right_arms", "right_grip_weapon", true, GRIP_ANIM_PARAMS)
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, ...)
    if view_index ~= 0 then return end
    if not weaponEquipped then return end
    pcall(_forceGripAnim)
end)

-- ──────────────────────────────────────────────
-- Hand-follows-weapon: right hand PMC → JNT_r_hand socket
-- ──────────────────────────────────────────────

local lastHandParentMesh = nil
local lastHandPMC        = nil
local lastWasArmed       = nil

-- Shared helper: write a pose table to a PMC in one pcall.
-- Defined here (before both right-hand and left-hand use sites) so both can
-- capture it as a proper local upvalue. Avoids a closure-per-bone allocation.
local function _applyPoseTable(pmc, poseTable)
    for bone, rot in pairs(poseTable) do
        animation.setBoneSpaceLocalRotator(
            pmc,
            uevrUtils.fname_from_string(bone),
            uevrUtils.rotator(rot[1], rot[2], rot[3]),
            0)
    end
end


local function attachHandToWeapon(weaponMesh, cls)
    local handPMC = hands.getHandComponent(Handed.Right)
    if handPMC == nil then return false end

    local ok, err = pcall(function()
        handPMC:K2_AttachTo(weaponMesh, uevrUtils.fname_from_string("JNT_r_hand"), 2, true)
    end)
    if not ok then
        print("[HOL2] attachHandToWeapon: " .. tostring(err))
        return false
    end

    -- Fix depth once now that we know this weapon is active.
    -- Ensure we apply it to the actor's RootComponent (not just the ItemMesh)
    -- so that sibling particle systems and visual effects are also fixed.
    pcall(function()
        local rootNode = weaponMesh
        if cls then
            if weaponMeshCache[cls] and uevrUtils.getValid(weaponMeshCache[cls].actor) then
                rootNode = uevrUtils.getValid(weaponMeshCache[cls].actor.RootComponent) or rootNode
            elseif throwableMeshCache[cls] and uevrUtils.getValid(throwableMeshCache[cls].actor) then
                rootNode = uevrUtils.getValid(throwableMeshCache[cls].actor.RootComponent) or rootNode
            end
        end
        fixComponentTree(rootNode)
        
        -- Force a SceneProxy recreation. Mutating depth properties via Lua bypasses
        -- the C++ Setters that normally dirty the render state. Toggling visibility
        -- sequentially in the same tick forces the game to instantly push the new 
        -- depth priorities to the GPU, preventing the need to "swap away and back".
        if rootNode.SetVisibility then
            rootNode:SetVisibility(false, true)
            rootNode:SetVisibility(true, true)
        end
    end)

    pcall(function() hands.setHoldingAttachment(Handed.Right, true) end)
    applyHandOffset(handPMC)
    return true
end

local function detachHandFromWeapon()
    local handPMC = hands.getHandComponent(Handed.Right)
    if handPMC == nil then return false end
    pcall(function() controllers.attachComponentToController(Handed.Right, handPMC) end)
    pcall(function() hands.setHoldingAttachment(Handed.Right, nil) end)
    -- Clear the weapon-specific positional/rotational offset so the hand sits
    -- flush on the controller (applyHandOffset wrote these; re-parenting alone
    -- doesn't reset them and they'd persist as a wrong offset).
    pcall(function()
        handPMC.RelativeLocation  = { X = 0, Y = 0, Z = 0 }
        handPMC.RelativeRotation  = { Pitch = 0, Yaw = 0, Roll = 0 }
        handPMC.DepthPriorityGroup = 0  -- restore world depth when not holding throwable
        handPMC:SetVisibility(true, true)
        handPMC:SetHiddenInGame(false, true)
    end)
    return true
end

-- ──────────────────────────────────────────────
-- Grip callback: weapon detection + attach (every 150 ms)
-- ──────────────────────────────────────────────

attachments.setGripUpdateTimeout(150)
attachments.setAnimationIDs({ grip_weapon = { label = "Weapon Grip" } })

-- ──────────────────────────────────────────────
-- Suit change detection: poll pawn.RightArm.SkeletalMesh
-- ──────────────────────────────────────────────
-- hands_parameters.json sources the PMC mesh via "Pawn.RightArm", so this is the
-- authoritative field that changes when the player equips a different suit.
-- Polling is throttled to once per 60 ticks (~0.5 s at 120 Hz) — suits change at
-- most once per playthrough so the overhead is negligible.
-- on_client_restart is kept only to invalidate the cached arm pointer when the
-- pawn object itself is replaced (respawn/checkpoint), preventing stale comparisons.
local _suitPollArm  = nil   -- cached pawn.RightArm SkeletalMeshComponent
local _suitMeshAsset = nil  -- last seen SkeletalMesh asset pointer
local _suitPollTick  = 0    -- throttle counter
local SUIT_POLL_INTERVAL = 60  -- ticks between checks

local _prev_on_client_restart = on_client_restart
function on_client_restart(newPawn)
    if _prev_on_client_restart then pcall(_prev_on_client_restart, newPawn) end
    -- Pawn object replaced: invalidate cached arm so _suitPoll re-fetches from new pawn
    -- and re-baselines without triggering a false-positive rebuild.
    _suitPollArm  = nil
    _suitMeshAsset = nil
end

-- Forward declarations: PrisonGun left-hand attach functions are implemented
-- below (after Jan/Knifey) but referenced inside the grip callback closure.
-- Lua closures capture locals by upvalue reference, so declaring them here
-- (before the closure is created) and assigning them later works correctly.
local attachLeftHandToPrisonGun, detachLeftHandFromPrisonGun

attachments.registerOnGripUpdateCallback(function()
    -- [GRIP-A] round-robin weapon discovery
    pcall(_tryDiscoverOneWeapon)

    local mesh, cls = findCurrentWeaponMesh()
    weaponEquipped = (mesh ~= nil)

    local handPMC = hands.getHandComponent(Handed.Right)
    local pmcRecreated = false
    if handPMC ~= lastHandPMC then
        lastHandParentMesh = nil
        lastHandPMC = handPMC
        pmcRecreated = true
    end

    local isArmed = (mesh ~= nil)
    local weaponChanged = (mesh ~= lastHandParentMesh)
    local stateChanged  = (lastWasArmed == nil)
                       or (isArmed  and lastWasArmed == false)
                       or (not isArmed and lastWasArmed == true)

    if weaponChanged or stateChanged or pmcRecreated then
        local newName = cls and CLS_TO_NAME[cls]
        if newName ~= currentWeaponName then
            currentWeaponName = newName
            pcall(function()
                configui.setLabel("hol2_active_weapon",
                    "Active weapon: " .. (currentWeaponName or "none"))
            end)
        end

        if isArmed then
            -- PrisonGun is a left-hand weapon: attach mesh to left controller
            -- and left PMC to the weapon socket instead of right-hand attach.
            if cls == PRISONGUN_CLASS then
                local ok = attachLeftHandToPrisonGun(mesh)
                if ok then
                    lastHandParentMesh = mesh
                    inPrisonGunLeftHand = true
                end
                lastWasArmed = true
            else
                -- Normal right-hand weapon
                if inPrisonGunLeftHand then
                    detachLeftHandFromPrisonGun(nil)
                    inPrisonGunLeftHand = false
                end
                local ok = attachHandToWeapon(mesh, cls)
                if ok then lastHandParentMesh = mesh end
                lastWasArmed = true
            end
        else
            if inPrisonGunLeftHand then
                detachLeftHandFromPrisonGun(nil)
                inPrisonGunLeftHand = false
            end
            if controllers.controllerExists(Handed.Right) then
                detachHandFromWeapon()
                lastHandParentMesh = nil
                lastWasArmed = false
            end
        end
    end

    if mesh == nil then return nil, nil, nil, nil, nil, nil, true end
    -- PrisonGun is left-hand only: return mesh as leftAttachment (4th value) so
    -- the attachments lib calls attachToRawController(mesh, Handed.Left), which
    -- registers it with UObjectHook as a LEFT-hand attachment (green in config,
    -- offset sliders work). rightAttachment stays nil → right controller untouched.
    if cls == PRISONGUN_CLASS then return nil, nil, nil, mesh, nil, nil, true end
    return mesh, nil, nil, nil, nil, nil, true
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Knifey melee: left hand PMC → PlayerLeftArm @ JNT_l_hand
--
-- Detection: poll knifeyMesh.bHiddenInGame every 5 engine ticks (~83ms).
-- MCP watch confirmed: flips false for ~15 ticks (~250ms) per melee attack.
-- Zero montage-name dependency, zero timing fragility.
-- ──────────────────────────────────────────────────────────────────────────────

local playerLeftArmMesh = nil   -- reserved for future use
local cachedKnifeyMesh  = nil   -- cached KnifeyDummy SkeletalMeshComponent
local cachedKnifeyActor = nil   -- cached KnifeyDummy actor (for IsInSequence check)
local inMelee           = false -- true while Knifey mesh is visible
local MELEE_SOCKET      = ""    -- no socket: attach at mesh root (SnapToTarget)
local KNIFEY_ACTOR_CLASS = "BlueprintGeneratedClass /Game/Blueprints/Narrative/KnifeyDummy_BP.KnifeyDummy_BP_C"

-- Find Knifey mesh: iterate all KnifeyDummy_BP_C instances, pick the live
-- world one (the archetype inside PlayerCharacter_BP has SkeletalMesh = null).
local function getKnifeyMesh()
    -- Trust the cached pointer until level change (which resets cachedKnifeyMesh = nil).
    -- Removing the per-frame uevrUtils.getValid bridge call is safe because the
    -- KnifeyDummy actor lives for the duration of the level.
    if cachedKnifeyMesh ~= nil then return cachedKnifeyMesh end

    if not resolveClassFast(KNIFEY_ACTOR_CLASS) then return nil end

    local actors = uevrUtils.find_all_of(KNIFEY_ACTOR_CLASS, false)
    if actors == nil or #actors == 0 then 
        return nil 
    end

    for _, actor in ipairs(actors) do
        local ok, mesh = pcall(function() return uevrUtils.getValid(actor.SkeletalMesh) end)
        if ok and mesh ~= nil then
            cachedKnifeyMesh  = mesh
            cachedKnifeyActor = actor
            print("[HOL2] KnifeyDummy live mesh cached: " .. tostring(mesh:get_full_name()))
            -- Apply depth fix so Knifey doesn't clip through the hand mesh
            pcall(function() fixComponentTree(mesh) end)
            return cachedKnifeyMesh
        end
    end

    -- If we get here, an actor existed but had no valid mesh (e.g. CDO or unloading)
    return nil
end

-- Grip pose for left hand while holding Knifey during melee.
-- LOCAL bone rotations [Pitch, Yaw, Roll] — same format as hands_parameters.json.
-- Applied via animation.setBoneSpaceLocalRotator (local→world conversion).
local MELEE_HAND_POSE = {
    ["JNT_l_middle_01"] = { -2.1711,   83.8527,  -6.5048  },
    ["JNT_l_middle_02"] = {  0.0,      64.874,    0.0     },
    ["JNT_l_middle_03"] = {  0.0,      62.8838,   0.0     },
    ["JNT_l_pinky_01"]  = { -10.046,   81.6027,  -6.5048  },
    ["JNT_l_pinky_02"]  = {  0.0,      64.874,    0.0     },
    ["JNT_l_pinky_03"]  = {  0.0,      62.8838,   0.0     },
    ["JNT_l_ring_01"]   = { -10.046,   81.6027,  -6.5048  },
    ["JNT_l_ring_02"]   = {  0.0,      64.874,    0.0     },
    ["JNT_l_ring_03"]   = {  0.0,      62.8838,   0.0     },
    ["JNT_l_thumb_01"]  = {  0.4629,   17.9892,   29.9286 },
    ["JNT_l_thumb_02"]  = { -3.3751,   52.875,    51.325  },
    ["JNT_l_thumb_03"]  = {  0.0,      56.25,     0.0     },
    ["JNT_l_index_01"]  = { -3.375,    77.6979,   5.6121  },
    ["JNT_l_index_02"]  = {  0.0,      87.7499,   0.0     },
    ["JNT_l_index_03"]  = {  0.0,      59.6249,   0.0     },
}

-- _applyPoseTable is defined earlier (before the hand-follows-weapon section)
-- so it can be used by both detachHandFromWeapon (right/unarmed) and
-- applyMeleePose (left/melee) without a forward declaration.

local function applyMeleePose(leftPMC)
    leftPMC = leftPMC or hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return end
    pcall(_applyPoseTable, leftPMC, MELEE_HAND_POSE)
end

-- (Melee pose is now locked via setHoldingAttachment, not a per-frame stereo callback.
--  See attachLeftHandToKnifey / detachLeftHandFromKnifey below.)

local function attachLeftHandToKnifey()
    local leftPMC = hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return false end
    local kmesh = cachedKnifeyMesh
    if kmesh == nil or uevrUtils.getValid(kmesh) == nil then return false end
    local ok, err = pcall(function()
        leftPMC:K2_AttachTo(kmesh, uevrUtils.fname_from_string(MELEE_SOCKET), 2, true)
    end)
    if ok then
        print("[HOL2] Left hand \xE2\x86\x92 KnifeyDummy mesh")
        applyMeleeHandOffset(leftPMC)
        applyMeleePose(leftPMC)
        -- Suppress hands lib input handler from overwriting the melee bone pose.
        -- "melee_override" is an unknown animation ID → animate() silently no-ops,
        -- leaving all bones untouched between attacks.
        pcall(function() hands.setHoldingAttachment(Handed.Left, "melee_override") end)
    else
        print("[HOL2] attach failed: " .. tostring(err))
    end
    return ok
end

-- Open hand pose: left_grip "off" + left_trigger "off" from hands_parameters.json.
-- Applied explicitly because setBoneSpaceLocalRotator overrides persist on the PMC
-- and the hands lib won't re-drive them unless it detects a state change.
local MELEE_OPEN_POSE = {
    ["JNT_l_middle_01"] = { -2.1709,  12.978,   -6.5046  },
    ["JNT_l_middle_02"] = {  0.0,      4.1242,   0.0     },
    ["JNT_l_middle_03"] = {  0.0,     12.2587,   0.0     },
    ["JNT_l_pinky_01"]  = { -10.845,  30.3018,  -24.7669 },
    ["JNT_l_pinky_02"]  = {  0.0,      4.1242,   0.0     },
    ["JNT_l_pinky_03"]  = {  0.0,     12.2587,   0.0     },
    ["JNT_l_ring_01"]   = { -8.0403,  19.1446,  -9.792   },
    ["JNT_l_ring_02"]   = {  0.0,      4.1242,   0.0     },
    ["JNT_l_ring_03"]   = {  0.0,     12.2587,   0.0     },
    ["JNT_l_thumb_01"]  = { 35.3377,  17.9893,   29.9286 },
    ["JNT_l_thumb_02"]  = {  0.0,      0.0,      32.2002 },
    ["JNT_l_thumb_03"]  = {  0.0,     12.2587,   0.0     },
    ["JNT_l_index_01"]  = {  0.9354,  12.4483,   5.6121  },  -- left_trigger "off"
    ["JNT_l_index_02"]  = {  0.0,      4.1241,   0.0     },
    ["JNT_l_index_03"]  = {  0.0,     12.2587,   0.0     },
}

local function detachLeftHandFromKnifey()
    local leftPMC = hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return end
    -- Restore normal hands lib input tracking before re-parenting.
    pcall(function() hands.setHoldingAttachment(Handed.Left, nil) end)
    pcall(function() controllers.attachComponentToController(Handed.Left, leftPMC) end)
    -- Clear the melee positional/rotational offset so the hand sits flush on the
    -- controller again. applyMeleeHandOffset wrote these; re-parenting alone doesn't
    -- reset them and they'd persist as a wrong offset relative to the controller.
    pcall(function()
        leftPMC.RelativeLocation = { X = 0, Y = 0, Z = 0 }
        leftPMC.RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }
    end)
    -- Directly apply the open/rest pose — setBoneSpaceLocalRotator overrides persist
    -- on the PMC and the hands lib only re-drives bones on a detected state change.
    pcall(_applyPoseTable, leftPMC, MELEE_OPEN_POSE)
    print("[HOL2] Left hand -> left controller (open pose + zero offset restored)")
end

-- Poll knifeyMesh.bHiddenInGame EVERY frame — near-zero cost once cached.
-- Cache miss (first run or stale pointer) triggers find_all_of, then stays
-- cached until level change invalidates it.
-- Named function avoids allocating a new closure on every engine tick (~200 Hz).
local function _knifeyPoll()
    local kmesh = getKnifeyMesh()
    if kmesh == nil then return end
    local isMelee = (kmesh.bHiddenInGame == false)
    if isMelee and not inMelee then
        inMelee = true
        attachLeftHandToKnifey()
    elseif not isMelee and inMelee then
        inMelee = false
        detachLeftHandFromKnifey()
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Jan Dual-Wield Support: Attach Jan to Left Controller and Left Hand to Jan
-- ──────────────────────────────────────────────────────────────────────────────

local function attachLeftHandToJan(janMesh)
    local leftPMC = hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return false end
    
    local leftController = controllers.getController(0, true)
    if leftController == nil then return false end

    local ok1, err1 = pcall(function()
        janMesh:K2_AttachTo(leftController, uevrUtils.fname_from_string(""), 2, true)
    end)
    if not ok1 then print("[HOL2] attach Jan to controller failed: " .. tostring(err1)) end
    
    local ok2, err2 = pcall(function()
        leftPMC:K2_AttachTo(janMesh, uevrUtils.fname_from_string("JNT_l_hand"), 2, true)
    end)
    if not ok2 then print("[HOL2] attach left hand to Jan failed: " .. tostring(err2)) end

    if ok1 and ok2 then
        print("[HOL2] Left hand \xE2\x86\x92 Jan mesh, Jan mesh \xE2\x86\x92 Left Controller")
        
        -- Apply Jan mesh offset (sliders)
        local off = weaponOffsets["Jan"]
        if off ~= nil then
            pcall(function()
                janMesh.RelativeLocation = { X = off[1], Y = off[2], Z = off[3] }
                janMesh.RelativeRotation = { Pitch = off[4], Yaw = off[5], Roll = off[6] }
            end)
        end
        
        applyJanHandOffset(leftPMC)
        applyMeleePose(leftPMC)
        pcall(function() hands.setHoldingAttachment(Handed.Left, "jan_override") end)
        return true
    end
    return false
end

local function detachLeftHandFromJan(janMesh)
    local leftPMC = hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return end

    pcall(function() hands.setHoldingAttachment(Handed.Left, nil) end)

    -- Step 1: break the socket bond by detaching from the Jan mesh socket first.
    -- K2_AttachTo will fail silently if we try to re-parent while still bound to a socket.
    pcall(function() leftPMC:K2_DetachFromComponent(false, true, true) end)

    -- Step 2: now re-attach to the left controller (no longer socket-bound, this succeeds).
    local leftController = controllers.getController(0, true)
    if leftController then
        pcall(function() leftPMC:K2_AttachTo(leftController, uevrUtils.fname_from_string(""), 0, false) end)
    else
        pcall(function() controllers.attachComponentToController(Handed.Left, leftPMC) end)
    end
    
    -- Step 3: zero out offsets that were applied relative to the Jan socket.
    pcall(function()
        leftPMC.RelativeLocation = { X = 0, Y = 0, Z = 0 }
        leftPMC.RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }
    end)

    -- Step 4: Jan's mesh going invisible propagates bVisible=false down to the PMC child.
    -- Explicitly restore visibility now that we are back under the controller.
    pcall(function()
        leftPMC:SetVisibility(true, true)
        leftPMC:SetHiddenInGame(false, true)
    end)

    -- Step 5: restore open hand pose — gripped bone rotations persist on the PMC
    -- and the hands lib won't re-drive them unless it detects a state change.
    pcall(_applyPoseTable, leftPMC, MELEE_OPEN_POSE)

    print("[HOL2] Left hand -> left controller (open pose restored, detached from Jan)")
end

local function _janPoll()
    local entry = weaponMeshCache[JAN_CLASS]
    if type(entry) == "table" then
        local a = uevrUtils.getValid(entry.actor)
        local m = uevrUtils.getValid(entry.mesh)
        
        if a ~= nil and m ~= nil then
            pcall(function() m.FirstPersonPrimitiveType = 0 end)

            local isActive = (a.bIsEquipped == true and m.bVisible == true)
            if isActive and not inJanDualWield then
                inJanDualWield = true
                attachLeftHandToJan(m)
            elseif not isActive and inJanDualWield then
                inJanDualWield = false
                detachLeftHandFromJan(m)
            end
        else
            if inJanDualWield then
                inJanDualWield = false
                detachLeftHandFromJan(nil)
            end
        end
    else
        if inJanDualWield then
            inJanDualWield = false
            detachLeftHandFromJan(nil)
        end
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- PrisonGun (Suit-O) left-hand support
--
-- The Suit-O is a LEFT-hand primary weapon. Its WeaponAttachment actor follows
-- the player skeleton; we additionally attach:
--   1. The gun mesh actor → left controller (so it tracks VR motion)
--   2. The left PMC        → gun's JNT_l_hand socket (so the hand grips the gun)
-- Detection: poll bIsEquipped + bHidden on the cached actor every engine tick.
-- ──────────────────────────────────────────────────────────────────────────────

attachLeftHandToPrisonGun = function(prisonGunMesh)
    local leftPMC = hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return false end

    -- NOTE: The gun-to-left-controller registration is handled by the grip callback
    -- returning mesh as leftAttachment. The attachments lib then calls
    -- attachToRawController(mesh, Handed.Left) which sets up the UObjectHook
    -- motion state, making the entry appear green in the Attachments Config.

    -- Attach the left hand PMC to the gun's JNT_l_hand socket
    local ok, err = pcall(function()
        leftPMC:K2_AttachTo(prisonGunMesh, uevrUtils.fname_from_string("JNT_l_hand"), 2, true)
    end)
    if not ok then print("[HOL2] attach left hand to PrisonGun failed: " .. tostring(err)) end

    if ok then
        print("[HOL2] Left hand PMC \xE2\x86\x92 PrisonGun JNT_l_hand | aim \xE2\x86\x92 Left Controller")
        -- Switch aim to Left Controller (4)
        pcall(function() input.setAimMethod(4) end)
        -- Apply gun mesh position offset from sliders
        local off = weaponOffsets["PrisonGun"]
        if off ~= nil then
            pcall(function()
                prisonGunMesh.RelativeLocation = { X = off[1], Y = off[2], Z = off[3] }
                prisonGunMesh.RelativeRotation = { Pitch = off[4], Yaw = off[5], Roll = off[6] }
            end)
        end
        applyPrisonGunHandOffset(leftPMC)
        applyMeleePose(leftPMC)
        pcall(function() hands.setHoldingAttachment(Handed.Left, "prisongun_override") end)
        return true
    end
    return false
end

detachLeftHandFromPrisonGun = function(prisonGunMesh)
    local leftPMC = hands.getHandComponent(Handed.Left)
    if leftPMC == nil then return end

    -- Restore Right Controller aim when leaving PrisonGun
    pcall(function() input.setAimMethod(3) end)
    pcall(function() hands.setHoldingAttachment(Handed.Left, nil) end)

    -- Remove the UObjectHook motion controller state so the entry un-highlights
    -- in the Attachments Config panel
    if prisonGunMesh ~= nil then
        pcall(function() UEVR_UObjectHook.remove_motion_controller_state(prisonGunMesh) end)
    end

    -- Break the socket bond first, then re-parent to controller
    pcall(function() leftPMC:K2_DetachFromComponent(false, true, true) end)

    local leftController = controllers.getController(0, true)
    if leftController then
        pcall(function() leftPMC:K2_AttachTo(leftController, uevrUtils.fname_from_string(""), 0, false) end)
    else
        pcall(function() controllers.attachComponentToController(Handed.Left, leftPMC) end)
    end

    -- Reset offsets and restore visibility
    pcall(function()
        leftPMC.RelativeLocation = { X = 0, Y = 0, Z = 0 }
        leftPMC.RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }
        leftPMC:SetVisibility(true, true)
        leftPMC:SetHiddenInGame(false, true)
    end)

    -- Restore open hand pose (bone rotations persist on the PMC)
    pcall(_applyPoseTable, leftPMC, MELEE_OPEN_POSE)

    print("[HOL2] Left hand -\xE2\x86\x92 left controller (detached from PrisonGun)")
end

local function _prisonGunPoll()
    local entry = weaponMeshCache[PRISONGUN_CLASS]
    if type(entry) == "table" then
        local a = uevrUtils.getValid(entry.actor)
        local m = uevrUtils.getValid(entry.mesh)

        if a ~= nil and m ~= nil then
            local isActive = (a.bHidden == false and m.bVisible == true)
            if isActive and not inPrisonGunLeftHand then
                inPrisonGunLeftHand = true
                attachLeftHandToPrisonGun(m)
            elseif not isActive and inPrisonGunLeftHand then
                inPrisonGunLeftHand = false
                detachLeftHandFromPrisonGun(m)
            end
        else
            if inPrisonGunLeftHand then
                inPrisonGunLeftHand = false
                detachLeftHandFromPrisonGun(nil)
            end
        end
    else
        if inPrisonGunLeftHand then
            inPrisonGunLeftHand = false
            detachLeftHandFromPrisonGun(nil)
        end
    end
end

-- ──────────────────────────────────────────────
-- Crosshair suppression (VR has no use for it)
-- ──────────────────────────────────────────────

local _crosshairPanel     = nil
-- _crosshairHidden is reset to false on level change so the one-shot re-fires
-- if the HUD is rebuilt after a transition.
local _crosshairHidden    = false
-- Throttle: find_first_of scans GUObjectArray — only attempt every 60 ticks
-- during the discovery window.  Initialised to 60 so the startup direct call
-- fires immediately without waiting a full interval first.
local _crosshairRetryTick = 60

local function _hideCrosshair()
    if _crosshairHidden then return end  -- already done; no-op until level change resets this
    -- Throttle GUObjectArray scan to once every 60 ticks during discovery.
    -- Direct calls (init, on_level_change) set _crosshairRetryTick=60 beforehand
    -- so they always bypass the guard and fire immediately.
    _crosshairRetryTick = _crosshairRetryTick + 1
    if _crosshairRetryTick < 60 then return end
    _crosshairRetryTick = 0
    -- Validate cached pointer (only relevant if HUD was rebuilt unexpectedly)
    if _crosshairPanel ~= nil and uevrUtils.getValid(_crosshairPanel) == nil then
        _crosshairPanel = nil
    end
    -- Lazy discovery via HUDMaster class (runs at most once per level)
    if _crosshairPanel == nil then
        local hud = uevrUtils.getValid(
            uevrUtils.find_first_of("Class /Script/Washington.ORWidget_HUDMaster", false))
        if hud == nil then return end
        _crosshairPanel = uevrUtils.getValid(hud.CrosshairPanel)
    end
    if _crosshairPanel == nil then return end
    -- Collapse the crosshair and mark done — no further scanning needed
    pcall(function() _crosshairPanel:SetVisibility(1) end)
    _crosshairHidden = true
end


-- Per-frame throwable depth fix — owns the full throwable cache lifecycle.
-- Runs every engine tick (~16ms at 60fps) to:
--   1. Validate the cached entry every frame: clears dead/unequipped actors.
--      FIX 2: Early-exit when nothing is cached — avoids all bridge calls.
--   2. Rescan via find_all_of every THROWABLE_RESCAN_INTERVAL frames when
--      cache is nil/false — catches new pickups quickly.
--   3. Apply FirstPersonPrimitiveType = 0 every frame to beat the engine reset.
--   4. Keep the right hand PMC at SDPG_Foreground. FIX 3: PMC is cached in
--      the entry on discovery — no per-frame getHandComponent call.
local _throwableRescanTick = 0
-- 600 ticks (~15s at 40fps VR, ~5s at 120fps).
-- find_all_of scans GUObjectArray for *instances* of each throwable class.
-- Throwable pickups are rare; 15-second detection latency is imperceptible.
local THROWABLE_RESCAN_INTERVAL = 600
local _throwableRescanIdx = 1
-- HOL2 PERF FIX: once all throwable classes have false sentinels (genuinely absent
-- from this level), skip the entire poll function until on_level_change resets this.
local _throwablesAllAbsent = false

local function _throwableDepthPoll()
    -- Fast exit: all classes confirmed absent this level — no bridge calls at all.
    if _throwablesAllAbsent then return end

    _throwableRescanTick = _throwableRescanTick + 1
    local doRescan = (_throwableRescanTick >= THROWABLE_RESCAN_INTERVAL)
    if doRescan then _throwableRescanTick = 0 end

    -- Early exit when nothing is actively cached and no rescan is due.
    -- FIX 4: type(entry)=="table" so false sentinels ("scanned, not found") are NOT
    -- counted as cached — preventing the loop running every frame for unequipped throwables.
    if not doRescan then
        local anyCached = false
        for _, cls in ipairs(THROWABLE_CLASSES) do
            if type(throwableMeshCache[cls]) == "table" then anyCached = true; break end
        end
        if not anyCached then return end
    end

    -- No round-robin needed: we only have a handful of throwable classes and
    -- find_all_of is cheap once classPointerCache has the UClass resolved.
    -- Scan ALL uncached classes each interval for fast (~1s) pickup detection.

    for _, cls in ipairs(THROWABLE_CLASSES) do
        local entry = throwableMeshCache[cls]

        -- Step 1: Every-frame validation of a live cached entry.
        -- Direct field access (no pcall closure): bHidden is a plain UProperty;
        -- the outer pcall(_throwableDepthPoll) is the safety net if the object dies.
        if type(entry) == "table" then
            local a = uevrUtils.getValid(entry.actor)
            if a == nil then
                throwableMeshCache[cls] = nil
                entry = nil
            elseif a.bHidden ~= false then
                -- Throwable no longer held (hidden / unequipped)
                throwableMeshCache[cls] = nil
                entry = nil
            end
        end

        -- Step 2: Cache miss → scan on rescan frames.
        -- nil  = never scanned this level → rescan allowed.
        -- false = scanned this level, not found → skip until on_level_change resets to nil.
        -- UClass fast path: if already in classPointerCache, skip the 65ms
        -- GUObjectArray scan entirely. Slow path is guarded by 3600-tick cooldown.
        if entry == nil and doRescan then
            throwableMeshCache[cls] = false  -- mark "scanned, not found" sentinel
            local uClass = classPointerCache[cls]
            if uClass == nil then
                uClass = resolveClassFast(cls)
            end
            local allActors = uClass and uevrUtils.find_all_of(cls, false) or nil
            if allActors then
                for _, actor in ipairs(allActors) do
                    local a = uevrUtils.getValid(actor)
                    if a ~= nil and a.bHidden == false then
                        local root = uevrUtils.getValid(a.RootComponent)
                        if root ~= nil then
                            local hpmc = hands.getHandComponent(Handed.Right)
                            local newEntry = { actor = a, mesh = root, handPMC = hpmc }
                            throwableMeshCache[cls] = newEntry
                            entry = newEntry
                            pcall(function() fixComponentTree(root) end)
                            if hpmc ~= nil then
                                pcall(function() hpmc.DepthPriorityGroup = 1 end)
                            end
                            break
                        end
                    end
                end
            end
        end

        -- Step 3: Per-frame depth fix — direct write, no closure allocation.
        -- FirstPersonPrimitiveType is the only field the engine resets each tick.
        -- Cache entry.mesh in a local to avoid double-indexing the table.
        if type(entry) == "table" then
            local m = entry.mesh
            if m ~= nil then m.FirstPersonPrimitiveType = 0 end
        end
    end

    -- After a rescan: check if all throwable classes are now absent (all false).
    -- If so, set the all-absent flag to permanently skip this function.
    if doRescan then
        local allAbsent = true
        for _, cls in ipairs(THROWABLE_CLASSES) do
            if throwableMeshCache[cls] ~= false then allAbsent = false; break end
        end
        if allAbsent then
            _throwablesAllAbsent = true
            print("[HOL2] All throwable classes absent this level — depth poll suspended")
        end
    end
end

-- ──────────────────────────────────────────────
-- Cutscene detection: ViewTarget → input lib disable
-- ──────────────────────────────────────────────
-- When a cutscene plays, the engine changes PlayerCameraManager.ViewTarget.Target
-- from PlayerCharacter_BP_C to a cinematic camera actor. Two kinds are seen:
--   • SQ_CinematicCamera_C  — scripted cinematic cutscenes
--   • CineCameraActor       — in-game animation cutscenes
-- The input lib's on_early_calculate_stereo_view_offset overwrites the VR camera
-- position to the player pawn every frame — disabling it lets UEVR follow the PCM
-- natively (bFindCameraComponentWhenViewTarget=true).
-- input.setDisabled() also calls recenter_view() automatically.
--
-- PERF: _lastVTClass caches the most-recently-seen ViewTarget class pointer so
-- the common (non-cinematic) case is a single pointer compare per frame.
-- _cineCameraClasses is a set of known cinematic class ptrs for O(1) lookup.
-- The slow string-check path only fires when the ViewTarget class actually changes
-- (i.e. at cutscene start/end) — zero string allocation during normal gameplay.
local _cutscenePCM        = nil   -- cached PlayerCameraManager pointer
local _cineCameraClasses  = {}    -- set of known cinematic-camera class ptrs
local _inCutscene         = false -- current cutscene state
local _lastVTClass        = nil   -- last ViewTarget class ptr (avoids per-frame to_string)
local _lastVTIsCinematic  = false -- cached isCinematic result for _lastVTClass

local function _cutscenePoll()
    -- Only run during active gameplay (pawn + weapon cache must exist)
    if not cacheBuilt then return end

    -- Cache PCM once; level-change handler resets to nil so no per-frame getValid needed
    if _cutscenePCM == nil then
        local pc = uevr.api:get_player_controller(0)
        if pc == nil then return end
        _cutscenePCM = uevrUtils.getValid(pc.PlayerCameraManager)
        if _cutscenePCM == nil then return end
    end

    -- Read ViewTarget.Target (2 field reads — no bridge call)
    local vt = _cutscenePCM.ViewTarget
    if vt == nil then return end
    local target = vt.Target

    local isCinematic = false
    if target ~= nil then
        local cls = target:get_class()
        if cls ~= nil then
            if cls == _lastVTClass then
                -- Common path: same class as last frame — one pointer compare, zero alloc
                isCinematic = _lastVTIsCinematic
            else
                -- Class changed (cutscene start/end, or first frame after level load)
                if _cineCameraClasses[cls] then
                    isCinematic = true
                else
                    local name = cls:get_fname():to_string()
                    if name:find("CineCameraActor") or name:find("CinematicCamera") then
                        _cineCameraClasses[cls] = true
                        isCinematic = true
                    end
                end
                _lastVTClass       = cls
                _lastVTIsCinematic = isCinematic
            end
        end
    end

    -- Only act on state transitions — no per-frame cost in steady state
    if isCinematic == _inCutscene then return end
    _inCutscene = isCinematic

    if isCinematic then
        print("[HOL2] Cutscene started — disabling input lib + hiding hands")
        input.setDisabled(true)
        pcall(function() hands.hideHands(true) end)
    else
        print("[HOL2] Cutscene ended — re-enabling input lib + showing hands")
        input.setDisabled(false)
        pcall(function() hands.hideHands(false) end)
    end
end

-- Pre-allocated closures for _suitPoll — hoisted here so no heap allocation per poll frame.
local _suitReadArm    = nil  -- set once when pawn is found; reads pawn.RightArm
local _suitReadMesh   = nil  -- reads _suitPollArm.SkeletalMesh into local
local _suitTmp        = {}   -- pre-allocated: reused each poll to avoid per-call table alloc

local function _suitPoll()
    if not cacheBuilt then return end

    -- Throttle: only check every SUIT_POLL_INTERVAL ticks
    _suitPollTick = _suitPollTick + 1
    if _suitPollTick < SUIT_POLL_INTERVAL then return end
    _suitPollTick = 0

    -- Cache the RightArm component from the current pawn.
    -- on_client_restart sets _suitPollArm = nil on pawn change, so getValid() is
    -- only needed here (discovery path). In steady state _suitPollArm is trusted.
    if _suitPollArm == nil then
        local pawn = uevr.api:get_local_pawn(0)
        if pawn == nil then return end
        local arm = nil
        -- _suitReadArm closure is built once per pawn find; captures 'pawn' upvalue
        pcall(function() arm = uevrUtils.getValid(pawn.RightArm) end)
        if arm == nil then return end
        _suitPollArm = arm
        -- Build the persistent read-mesh closure capturing the now-stable arm pointer
        _suitReadMesh = function(out) out[1] = _suitPollArm.SkeletalMesh end
        -- Establish baseline — no rebuild on initial discovery
        if _suitMeshAsset == nil then
            local tmp = {}
            pcall(_suitReadMesh, tmp)
            _suitMeshAsset = tmp[1]
        end
        return  -- give one poll cycle before comparing
    end

    -- Steady-state: one field read + one pointer compare, no allocation
    _suitTmp[1] = nil
    pcall(_suitReadMesh, _suitTmp)
    local currentMesh = _suitTmp[1]
    if currentMesh == nil then return end

    if _suitMeshAsset ~= nil and currentMesh ~= _suitMeshAsset then
        print("[HOL2] Suit change detected (RightArm.SkeletalMesh changed) — rebuilding VR hands")
        _suitMeshAsset = currentMesh  -- update baseline before rebuild
        pcall(function()
            hands.destroyHands()
            hands.createFromConfig('hands_parameters', 'Main', 'Shared')
        end)
    end
    -- No else write: baseline only changes on actual suit swap
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Weapon wheel: right controller physical movement drives weapon selection
--
-- When the wheel opens (bEquipmentWheelOpen == true):
--   1. Snapshot the right VR hand's world position as a reference origin.
--   2. Each frame: compute hand displacement from that origin.
--      World Y = left/right,  World Z = up/down.
--   3. Scale displacement to XInput range and write to sThumbLX/LY via the
--      on_xinput_get_state callback so the game's wheel logic sees it as
--      normal left-stick input.
--
-- Inspired by Oblivion Remastered VR mod (RadialQuickMenu.lua).
-- ──────────────────────────────────────────────────────────────────────────────

local _wheelWidget    = nil    -- cached HUD_EquipmentQuickSelect_NewStyle_C
local _wheelOpen      = false  -- true while wheel is visibly open
local _wheelOpenPos   = nil    -- {y,z} right hand world pos at wheel-open moment
local _wheelHC        = nil    -- right hand component, cached for the wheel's lifetime
local _wheelSimLX     = 0     -- simulated sThumbLX fed to XInput every frame
local _wheelSimLY     = 0     -- simulated sThumbLY fed to XInput every frame
local WHEEL_SCALE     = 32767.0 / 8.0   -- 8 UE units (cm) hand travel = full deflection
-- Throttle widget discovery: _getWheelWidget calls find_first_of (GUObjectArray scan).
-- Only attempt every 60 ticks while unresolved.  Init to 60 so startup fires immediately.
local _wheelRetryTick = 60

-- Pre-created closures: eliminates per-frame Lua closure allocation inside pcall.
-- Closures capture the module locals above as upvalues — always see current values.
local _wheelIsOpen    = false
local _wheelReadOpenFn = function() _wheelIsOpen = _wheelWidget.bEquipmentWheelOpen end
local _wheelPY, _wheelPZ = 0.0, 0.0
local _wheelReadPosFn  = function()
    local p = _wheelHC:K2_GetComponentLocation()
    _wheelPY, _wheelPZ = p.y, p.z
end

local function _getWheelWidget()
    if _wheelWidget ~= nil then
        if uevrUtils.getValid(_wheelWidget) ~= nil then return _wheelWidget end
        _wheelWidget = nil
    end
    local hud = uevrUtils.getValid(
        uevrUtils.find_first_of("Class /Script/Washington.ORWidget_HUDMaster", false))
    if hud == nil then return nil end
    local ok, w = pcall(function() return uevrUtils.getValid(hud.HUD_EquipmentQuickSelect) end)
    if ok and w ~= nil then
        _wheelWidget = w
        print("[HOL2] WeaponWheel widget cached")
    end
    return _wheelWidget
end

-- Called each pre-engine-tick.  Tracks wheel open/close transitions and
-- computes the simulated stick values from right-hand world displacement.
local function _wheelTickPoll()
    if _wheelWidget == nil then
        -- Throttle: find_first_of scans GUObjectArray — only attempt every 60 ticks.
        _wheelRetryTick = _wheelRetryTick + 1
        if _wheelRetryTick < 60 then return end
        _wheelRetryTick = 0
        pcall(_getWheelWidget)
        return
    end

    -- Read bEquipmentWheelOpen via pre-created closure — no per-frame allocation.
    _wheelIsOpen = false
    pcall(_wheelReadOpenFn)
    local isOpen = _wheelIsOpen

    if isOpen and not _wheelOpen then
        -- Wheel just opened: cache the hand component and snapshot its position.
        _wheelOpen = true
        _wheelHC   = hands.getHandComponent(Handed.Right)
        if _wheelHC ~= nil then
            pcall(function()
                local p = _wheelHC:K2_GetComponentLocation()
                _wheelOpenPos = { y = p.y, z = p.z }  -- only y/z needed
            end)
        end
    elseif not isOpen and _wheelOpen then
        -- Wheel closed: clear all wheel state.
        _wheelOpen    = false
        _wheelOpenPos = nil
        _wheelHC      = nil
        _wheelSimLX   = 0
        _wheelSimLY   = 0
        return
    end

    if not _wheelOpen or _wheelOpenPos == nil or _wheelHC == nil then return end

    -- Steady-state: read position via pre-created closure (zero allocation),
    -- compute displacement, clamp to XInput range.
    -- World Y = left/right,  World Z = up/down.
    if pcall(_wheelReadPosFn) then
        local dx = (_wheelPY - _wheelOpenPos.y) * WHEEL_SCALE
        local dz = (_wheelPZ - _wheelOpenPos.z) * WHEEL_SCALE
        _wheelSimLX = math.max(-32767, math.min(32767, math.floor(dx + 0.5)))
        _wheelSimLY = math.max(-32767, math.min(32767, math.floor(dz + 0.5)))
    end
end

-- Inject the computed stick values into the XInput state the game receives.
if uevr.sdk and uevr.sdk.callbacks and uevr.sdk.callbacks.on_xinput_get_state then
    uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
        if not _wheelOpen then return end
        state.Gamepad.sThumbLX = _wheelSimLX
        state.Gamepad.sThumbLY = _wheelSimLY
    end)
    print("[HOL2] Weapon wheel controller-motion remap registered")
else
    print("[HOL2] WARN: uevr.sdk.callbacks unavailable — wheel remap skipped")
end

-- ──────────────────────────────────────────────
-- Muppy Doo face-stab world widget: VR space fix
-- ──────────────────────────────────────────────
-- During the final Muppy Doo Knifey stab sequence the engine attaches a
-- MuppyDoo_FaceStab_WorldWidget_BP_C actor to the pawn.  Its WidgetComponent
-- ("Widget") defaults to World space, which in VR renders off-centre.
-- Setting Space = 1 (Screen) matches what UObjectHook's "scene view" option does:
-- UEVR then projects it centred on the HMD automatically.
local _faceStabActor    = nil    -- cached live actor
local _faceStabFixed    = false  -- Space patch applied to current actor
local _faceStabPollTick = 0
local FACE_STAB_INTERVAL = 120   -- only scan every ~2 s; fight is rare

local function _muppyFaceStabPoll()
    -- Fast path: one bool read — level-change handler resets this when needed
    if _faceStabFixed then return end

    -- Throttle the GUObjectArray scan
    _faceStabPollTick = _faceStabPollTick + 1
    if _faceStabPollTick < FACE_STAB_INTERVAL then return end
    _faceStabPollTick = 0

    -- Walk the pawn's Children array looking for the FaceStab widget actor
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return end

    local children = pawn.Children
    if children == nil then return end

    for i = 0, #children - 1 do
        local child = children[i]
        if child == nil then break end
        local cls = child:get_class()
        if cls == nil then goto continue end
        local name = cls:get_fname():to_string()
        if name:find("FaceStab") then
            local wc = nil
            pcall(function() wc = uevrUtils.getValid(child.Widget) end)
            if wc ~= nil then
                -- Space: 0=World, 1=Screen (UEVR centres Screen widgets on HMD)
                pcall(function() wc.Space = 1 end)
                _faceStabActor = child
                _faceStabFixed = true
                print("[HOL2-Muppy] FaceStab WidgetComponent.Space → Screen (VR centred)")
            end
            return  -- only one actor expected
        end
        ::continue::
    end
end

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    pcall(_knifeyPoll)
    pcall(_janPoll)
    pcall(_throwableDepthPoll)
    pcall(_hideCrosshair)
    pcall(_cutscenePoll)
    pcall(_suitPoll)
    pcall(_wheelTickPoll)
    pcall(_muppyFaceStabPoll)
end)

-- ──────────────────────────────────────────────
-- Init + level change
-- ──────────────────────────────────────────────

buildCache()
getKnifeyMesh()    -- pre-warm Knifey mesh cache so first melee has zero delay
pcall(_getWheelWidget)  -- pre-warm wheel widget cache
pcall(_hideCrosshair)  -- suppress crosshair immediately at load time

local _prev_on_level_change = on_level_change
function on_level_change(level)
    if _prev_on_level_change then pcall(_prev_on_level_change, level) end
    
    classPointerCache = {}
    classFailedTime   = {}  -- reset wall-clock cooldown for fresh discovery
    classFailRetries  = {}  -- reset give-up counter so all classes are retried in new level

    -- Pre-warm: force-load all weapon/throwable blueprints into UE memory AND
    -- populate classPointerCache immediately. This means resolveClassFast() finds
    -- them cached on the very first call from buildCache(), eliminating the
    -- redundant double find_uobject scan (pre-warm + buildCache) that existed before.
    for _, cls in ipairs(WEAPON_CLASSES) do
        local ok, c = pcall(uevrUtils.get_class, cls, true)
        if ok and c ~= nil then classPointerCache[cls] = c end
    end
    for _, cls in ipairs(THROWABLE_CLASSES) do
        local ok, c = pcall(uevrUtils.get_class, cls, true)
        if ok and c ~= nil then classPointerCache[cls] = c end
    end

    weaponMeshCache    = {}
    throwableMeshCache = {}
    _scanIndex           = 1     -- reset weapon round-robin
    _throwableRescanTick = 0     -- reset so first throwable scan fires after first interval
    _throwablesAllAbsent = false -- re-enable throwable poll for new level
    cacheBuilt           = false
    _lastWeaponMesh    = nil     -- clear steady-state weapon fast-path cache
    _lastWeaponCls     = nil
    lastHandParentMesh = nil
    currentWeaponName  = nil
    weaponEquipped     = false
    inMelee               = false
    inJanDualWield        = false
    inPrisonGunLeftHand   = false
    cachedKnifeyMesh      = nil
    cachedKnifeyActor = nil
    playerLeftArmMesh = nil
    _crosshairPanel     = nil  -- widget tree is rebuilt on level load
    _crosshairHidden    = false -- allow one-shot to re-fire for the new HUD
    _crosshairRetryTick = 60   -- fire at next direct call + first eligible tick
    _wheelWidget        = nil   -- wheel widget also rebuilt with the WidgetTree
    _wheelRetryTick     = 60   -- fire at next direct call + first eligible tick
    _wheelOpen          = false -- ensure XInput injection stops on level transition
    _wheelOpenPos       = nil
    _wheelSimLX         = 0
    _wheelSimLY         = 0
    -- Reset suit poll — new level means a fresh pawn, re-baseline without triggering rebuild
    _suitPollArm  = nil
    _suitMeshAsset = nil
    _suitPollTick  = 0
    -- Reset cutscene state — if a level change fires mid-cutscene, restore input lib + hands
    _cutscenePCM        = nil
    _cineCameraClasses  = {}   -- rebuild set; class ptrs may differ in new level
    _lastVTClass        = nil  -- clear class cache so first frame re-evaluates cleanly
    _lastVTIsCinematic  = false
    if _inCutscene then
        pcall(function() input.setDisabled(false) end)
        pcall(function() hands.hideHands(false) end)
    end
    _inCutscene = false
    -- Reset FaceStab widget fix — new level means a fresh pawn/children
    _faceStabActor    = nil
    _faceStabFixed    = false
    _faceStabPollTick = 0
    buildCache()
    getKnifeyMesh()   -- re-cache after level change
    pcall(_hideCrosshair)  -- attempt immediate suppress on level entry
end

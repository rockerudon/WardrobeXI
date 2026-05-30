--[[
* WardrobeXI - appearance engine
*
* Changes the local player's model fields (race, face/hair, equipment models)
* using the proven approach from the Ashita "sexchange" / "singlerace" addons:
*
*   1. Write the desired values directly into the player entity
*      (player.Race, player.Look.*) and set player.ModelUpdateFlags = 0x10 to
*      force a re-render ("blink").
*
*   2. Also rewrite the relevant incoming packets (zone-in 0x0A, character
*      update 0x0D, appearance 0x51) so the server's periodic appearance
*      refreshes do not overwrite our override.
*
* DETECTION (the "Player" view) is read from AUTHORITATIVE sources, NOT from
* the rendered model:
*
*   - Equipment: AshitaCore inventory GetEquippedItem(slot) gives the real
*     equipped item id, regardless of any active model override. This is the
*     same method equipmon/luashitacast use.
*   - Race / Face: read from the player entity while no override is active
*     (when an override is active the entity shows the override).
--]]

require('common');
local chat   = require('chat');
local ffi    = require('ffi');
local models = require('data.models');

local appearance = T{};

-- Equipment slot order as stored in entity.Look and the appearance packets.
-- index 1..8 -> entity.Look field name.
local LOOK_SLOTS = T{
    'Head', 'Body', 'Hands', 'Legs', 'Feet', 'Main', 'Sub', 'Ranged',
};

-- Maps our model-slot index (1..8) to the FFXI inventory EquipmentSlot id used
-- by GetEquippedItem. (Main=0, Sub=1, Range=2, Ammo=3, Head=4, Body=5,
-- Hands=6, Legs=7, Feet=8, ...)
local INV_EQUIP_SLOT = T{
    [1] = 4,  -- Head
    [2] = 5,  -- Body
    [3] = 6,  -- Hands
    [4] = 7,  -- Legs
    [5] = 8,  -- Feet
    [6] = 0,  -- Main
    [7] = 1,  -- Sub
    [8] = 2,  -- Ranged
};

-- Active override the rest of the addon configures. -1 means "keep real".
local style = T{
    enabled = false,
    race    = -1,
    face    = -1,   -- hair/face byte
    equip   = T{ -1, -1, -1, -1, -1, -1, -1, -1, },
};

-- Cached REAL race/face/equip. Race/face/equip-models live in the entity,
-- which we overwrite when applying an override. So we snapshot the real values
-- whenever no override is active, persist them per-character, and use them for
-- detection and restore (surviving reloads even while an override is active).
--
-- equip holds the REAL RENDERED models (entity.Look slots). These already have
-- the game's multi-slot hiding applied (e.g. a body that covers hands/legs/feet
-- zeroes those slots), so using them on restore avoids clipping that would
-- happen if we rebuilt each slot from its individually-equipped item.
local real_cache = T{
    race  = nil,
    face  = nil,
    equip = nil,   -- T{8} of rendered model values, or nil if unknown
};

-- Reference to the addon settings table (set via appearance.bind_settings), so
-- the real race/face can be persisted across reloads.
local settings_ref = nil;

--[[
* Binds the addon settings table to the engine and seeds the real cache from
* the persisted values, if any.
--]]
function appearance.bind_settings(s)
    settings_ref = s;
    if (s.real ~= nil) then
        if (s.real.race[1] ~= nil and s.real.race[1] >= 0) then
            real_cache.race = s.real.race[1];
        end
        if (s.real.face[1] ~= nil and s.real.face[1] >= 0) then
            real_cache.face = s.real.face[1];
        end
    end
end

--[[
* Persists the current real cache into the bound settings table.
--]]
local function persist_real()
    if (settings_ref == nil or settings_ref.real == nil) then return; end
    if (real_cache.race ~= nil) then settings_ref.real.race[1] = real_cache.race; end
    if (real_cache.face ~= nil) then settings_ref.real.face[1] = real_cache.face; end
end

--========================================================================
-- Authoritative readers (the "Player" view)
--========================================================================

--[[
* Returns the real equipped item id for a model slot (1..8) by reading the
* inventory's equipment table, NOT the rendered model. Returns the item id, or
* 0 when nothing is equipped in that slot, or nil if unavailable.
--]]
local function read_equipped_item_id(slot)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then return nil; end

    local inv_slot = INV_EQUIP_SLOT[slot];
    if (inv_slot == nil) then return nil; end

    local eitem = inv:GetEquippedItem(inv_slot);
    if (eitem == nil or eitem.Index == 0) then
        return 0;  -- nothing equipped
    end

    local container = bit.band(eitem.Index, 0xFF00) / 0x0100;
    local index     = eitem.Index % 0x0100;
    local iitem     = inv:GetContainerItem(container, index);
    if (iitem == nil) then return 0; end

    local id = iitem.Id;
    if (id == nil or id == 0 or id == 65535) then
        return 0;
    end
    return id;
end

--[[
* Returns the player's real race id. Prefers the snapshot taken while no
* override was active; falls back to the live entity.
--]]
local function read_real_race()
    if (real_cache.race ~= nil) then return real_cache.race; end
    local player = GetPlayerEntity();
    if (player == nil) then return nil; end
    return player.Race;
end

--[[
* Returns the player's real face/hair value. Prefers the snapshot taken while
* no override was active; falls back to the live entity.
--]]
local function read_real_face()
    if (real_cache.face ~= nil) then return real_cache.face; end
    local player = GetPlayerEntity();
    if (player == nil) then return nil; end
    return player.Look.Hair;
end

--[[
* Snapshots the live entity's race/face into the real cache. Only safe to call
* while NO override is active (otherwise the entity holds our override).
--]]
local function snapshot_real()
    local player = GetPlayerEntity();
    if (player == nil) then return; end
    real_cache.race = player.Race;
    real_cache.face = player.Look.Hair;
    -- Capture the actually-rendered equipment models (already account for
    -- multi-slot gear hiding, so they restore without clipping).
    real_cache.equip = T{};
    for i, slot in ipairs(LOOK_SLOTS) do
        real_cache.equip[i] = player.Look[slot];
    end
    persist_real();
end

--========================================================================
-- Equipment model resolution (item id <-> encoded model value)
--========================================================================

--[[
* Resolves an item id to its encoded model value for the given equipment slot
* (1..8). Returns the encoded model, the slot's empty model for item id 0, or
* nil if the item has no known model in that slot.
--]]
function appearance.item_to_model(slot, item_id)
    if (slot < 1 or slot > 8) then return nil; end
    if (item_id == nil) then return nil; end
    if (item_id == 0) then
        return 4096 * slot;  -- bare slot model
    end
    local slot_table = models[slot];
    if (slot_table == nil) then return nil; end
    return slot_table[item_id];
end

-- Lazily-built, cached per-slot item lists for the UI.
-- equip_lists[slot] = T{ T{ id, name, model }, ... } sorted by name.
local equip_lists = nil;

--[[
* Builds the item list for a single slot (1..8) by walking the bundled model
* table and resolving each item id to its display name via the resource
* manager. Cached after first build.
--]]
local function build_slot_list(slot)
    if (equip_lists == nil) then equip_lists = T{}; end
    if (equip_lists[slot] ~= nil) then return; end

    local list   = T{};
    local seen   = {};
    local tbl    = models[slot];
    local resMgr = AshitaCore:GetResourceManager();
    if (resMgr ~= nil and tbl ~= nil) then
        for itemId, model in pairs(tbl) do
            local item = resMgr:GetItemById(itemId);
            if (item ~= nil and item.Name ~= nil and item.Name[1] ~= nil and item.Name[1] ~= '') then
                local nm = item.Name[1];
                if (seen[nm] == nil) then
                    seen[nm] = true;
                    list:append(T{ id = itemId, name = nm, model = model, });
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name; end);
    equip_lists[slot] = list;
end

--[[
* Returns the cached, name-sorted item list for a slot (1..8). Each entry is
* { id, name, model }.
--]]
function appearance.get_slot_items(slot)
    if (slot < 1 or slot > 8) then return T{}; end
    build_slot_list(slot);
    return equip_lists[slot] or T{};
end

--[[
* Returns a display name for an item id in a slot (1..8). Returns 'None' for an
* unequipped slot (id 0) and the item name otherwise, or nil if unknown.
--]]
function appearance.item_name(slot, item_id)
    if (item_id == nil) then return nil; end
    if (item_id == 0) then return 'None'; end
    local resMgr = AshitaCore:GetResourceManager();
    if (resMgr == nil) then return nil; end
    local item = resMgr:GetItemById(item_id);
    if (item ~= nil and item.Name ~= nil and item.Name[1] ~= nil and item.Name[1] ~= '') then
        return item.Name[1];
    end
    return nil;
end

-- Reverse model->name map per slot, built alongside the item lists for display.
local model_names = nil;

--[[
* Returns a representative display name for an encoded model value in a slot
* (used to label an explicit override). Returns 'None' for the bare model and a
* generic 'Model N' for unknown values. Multiple items can share a model; this
* returns one representative name.
--]]
function appearance.model_name(slot, model)
    if (model == nil or model < 0) then return nil; end
    if (model == 4096 * slot) then return 'None'; end
    build_slot_list(slot);
    if (model_names == nil) then model_names = T{}; end
    if (model_names[slot] == nil) then
        local map = {};
        local list = equip_lists[slot] or T{};
        for _, item in ipairs(list) do
            if (map[item.model] == nil) then
                map[item.model] = item.name;
            end
        end
        model_names[slot] = map;
    end
    local nm = model_names[slot][model];
    if (nm ~= nil) then return nm; end
    return ('Model %d'):fmt(model);
end

-- Reverse model->item id map per slot (a representative item for an encoded
-- model), built lazily for icon display of explicit overrides.
local model_items = nil;

--[[
* Returns a representative item id for an encoded model value in a slot, or nil
* (e.g. for the bare/empty model). Used to draw an icon for an explicit
* equipment override.
--]]
function appearance.model_item_id(slot, model)
    if (model == nil or model < 0) then return nil; end
    if (model == 4096 * slot) then return nil; end  -- bare slot, no item
    build_slot_list(slot);
    if (model_items == nil) then model_items = T{}; end
    if (model_items[slot] == nil) then
        local map = {};
        local list = equip_lists[slot] or T{};
        for _, item in ipairs(list) do
            if (map[item.model] == nil) then
                map[item.model] = item.id;
            end
        end
        model_items[slot] = map;
    end
    return model_items[slot][model];
end

--========================================================================
-- Detection getters used by the UI ("Player" view)
--========================================================================

--[[
* Returns the real equipped item id for a slot (1..8): the item the player
* actually has on, read from the inventory. 0 = nothing equipped.
--]]
function appearance.get_equipped_item_id(slot)
    return read_equipped_item_id(slot);
end

function appearance.get_real_race()
    return read_real_race();
end

function appearance.get_real_face()
    return read_real_face();
end

--========================================================================
-- Job detection (used by the Automation view)
--========================================================================

-- Job id -> abbreviation cache.
local job_abbr_cache = {};

--[[
* Returns the player's current main job id and sub job id (0 if none/unknown).
--]]
function appearance.get_jobs()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then return 0, 0; end
    return player:GetMainJob(), player:GetSubJob();
end

--[[
* Returns the 3-letter abbreviation for a job id (e.g. 'WAR'), or '---' for 0.
--]]
function appearance.job_abbr(job_id)
    if (job_id == nil or job_id == 0) then return '---'; end
    local cached = job_abbr_cache[job_id];
    if (cached ~= nil) then return cached; end
    local s = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', job_id);
    if (type(s) == 'string') then
        s = s:gsub('%z.*$', '');  -- trim trailing nulls
        if (s ~= '') then
            job_abbr_cache[job_id] = s;
            return s;
        end
    end
    return ('Job%d'):fmt(job_id);
end

--[[
* Refreshes the cached real race/face from the live entity, but ONLY while no
* override is active. Call this every frame so detection / restore always have
* the true values even after the player changes zones or character.
--]]
function appearance.refresh_real()
    if (style.enabled) then return; end
    snapshot_real();
end

--========================================================================
-- Override application
--========================================================================

--[[
* Updates the active style from the addon settings table.
* s.style = { enabled, race, face, equip[8] } (each a T{value}).
--]]
function appearance.set_style(s)
    style.enabled = s.style.enabled[1];
    style.race    = s.style.race[1];
    style.face    = s.style.face[1];
    for i = 1, 8 do
        style.equip[i] = s.style.equip[i] or -1;
    end
end

--[[
* Resolves the configured style into concrete values, filling "keep real" (-1)
* slots from the authoritative real appearance (equipped items / entity). Race
* and face fall back to the live entity; equipment falls back to the model of
* the equipped item. Returns { race, face, equip[8] } or nil.
--]]
local function resolve_style()
    local player = GetPlayerEntity();
    if (player == nil) then return nil; end

    -- Use the cached REAL race/face (the entity may already hold our override).
    local real_race = read_real_race() or player.Race;
    local real_face = read_real_face() or player.Look.Hair;

    local values = T{
        race = (style.race >= 0) and style.race or real_race,
        face = (style.face >= 0) and style.face or real_face,
        equip = T{},
    };

    -- Equip values are ITEM IDS: -1 = keep real, 0 = none/empty, >0 = item id.
    -- We convert to the visual model only here, at apply time.
    local have_cache = (real_cache.equip ~= nil);
    for i = 1, 8 do
        local v = style.equip[i];
        if (v == nil or v < 0) then
            -- Keep real: prefer the cached RENDERED model (accounts for
            -- multi-slot gear hiding); fall back to the equipped item's model.
            if (have_cache and real_cache.equip[i] ~= nil) then
                values.equip[i] = real_cache.equip[i];
            else
                local item_id = read_equipped_item_id(i);
                local model   = appearance.item_to_model(i, item_id or 0);
                values.equip[i] = model or player.Look[LOOK_SLOTS[i]];
            end
        elseif (v == 0) then
            values.equip[i] = 4096 * i;  -- bare / empty slot
        else
            local model = appearance.item_to_model(i, v);
            -- If the chosen item has no known model, leave the live look as-is.
            values.equip[i] = model or player.Look[LOOK_SLOTS[i]];
        end
    end

    -- FFXI "full body" rule: when the BODY model number (model % 0x1000) is
    -- >= 256, the game renders it as a full outfit and forces the hands, legs
    -- and feet slots to that same model number in their own slot ranges
    -- (Hands 0x3000, Legs 0x4000, Feet 0x5000). Replicate that so multi-slot
    -- gear (e.g. Kupo/Moogle Suit) does not clip with the bare base body.
    local body_model = values.equip[2];
    if (body_model ~= nil and body_model >= 0) then
        local body_number = body_model % 0x1000;
        if (body_number >= 256) then
            values.equip[3] = 0x3000 + body_number;  -- Hands
            values.equip[4] = 0x4000 + body_number;  -- Legs
            values.equip[5] = 0x5000 + body_number;  -- Feet
        end
    end

    return values;
end

--[[
* Writes resolved values into the player entity and forces a refresh.
--]]
local function write_player_values(values)
    local player = GetPlayerEntity();
    if (player == nil) then return false; end

    local changed = false;

    if (values.race ~= nil and player.Race ~= values.race) then
        player.Race = values.race;
        changed = true;
    end
    if (values.face ~= nil and player.Look.Hair ~= values.face) then
        player.Look.Hair = values.face;
        changed = true;
    end
    if (values.equip ~= nil) then
        for i, slot in ipairs(LOOK_SLOTS) do
            local v = values.equip[i];
            if (v ~= nil and player.Look[slot] ~= v) then
                player.Look[slot] = v;
                changed = true;
            end
        end
    end

    if (changed) then
        player.ModelUpdateFlags = 0x10;
    end
    return changed;
end

--========================================================================
-- Public API
--========================================================================

function appearance.initialize()
    -- Only snapshot the entity as "real" if NO override is enabled in settings;
    -- if an override is active the entity may still show a previous override
    -- (e.g. right after a reload), which would poison the real cache. When an
    -- override is active we rely on the persisted real and on capturing the
    -- real values from the server's original appearance packets.
    local override_enabled = (settings_ref ~= nil
        and settings_ref.style ~= nil
        and settings_ref.style.enabled[1]);
    if (not override_enabled) then
        snapshot_real();
    end
end

--[[
* Applies the configured style to the player entity, if enabled.
--]]
function appearance.apply_to_self(s)
    appearance.set_style(s);
    if (not style.enabled) then return false; end

    local values = resolve_style();
    if (values == nil) then return false; end
    return write_player_values(values);
end

--[[
* Restores the player's real appearance. Uses the cached REAL rendered models
* (which already account for multi-slot gear hiding, so no clipping) when
* available, falling back to the per-item models from the inventory.
--]]
function appearance.restore_self()
    local player = GetPlayerEntity();
    if (player == nil) then return false; end

    local values = T{
        race  = read_real_race() or player.Race,
        face  = read_real_face() or player.Look.Hair,
        equip = T{},
    };

    local have_cache = (real_cache.equip ~= nil);
    for i = 1, 8 do
        if (have_cache and real_cache.equip[i] ~= nil) then
            values.equip[i] = real_cache.equip[i];
        else
            -- Fallback: derive from the individually-equipped item.
            local item_id = read_equipped_item_id(i);
            local model   = appearance.item_to_model(i, item_id or 0);
            values.equip[i] = model or player.Look[LOOK_SLOTS[i]];
        end
    end

    return write_player_values(values);
end

--[[
* Captures the player's REAL race/face from the ORIGINAL (unmodified) incoming
* packet data. This is authoritative even while an override is active, so the
* cache stays correct after zoning or character changes. Call before rewriting.
--]]
function appearance.capture_real_from_packet(e)
    -- Reads the 8 rendered equip models (uint16) from the packet at base offset.
    local function read_equip(base)
        local eq = T{};
        for i = 0, 7 do
            eq[i + 1] = struct.unpack('H', e.data, base + i * 2 + 1);
        end
        return eq;
    end

    if (e.id == 0x000A) then
        real_cache.face  = struct.unpack('B', e.data, 0x44 + 1);
        real_cache.race  = struct.unpack('B', e.data, 0x45 + 1);
        real_cache.equip = read_equip(0x46);
        persist_real();
    elseif (e.id == 0x000D) then
        local party = AshitaCore:GetMemoryManager():GetParty();
        if (party == nil) then return; end
        local sid = struct.unpack('L', e.data, 0x04 + 1);
        local flag = struct.unpack('B', e.data, 0x0A + 1);
        if (sid == party:GetMemberServerId(0) and flag == 0x1F) then
            real_cache.face  = struct.unpack('B', e.data, 0x48 + 1);
            real_cache.race  = struct.unpack('B', e.data, 0x49 + 1);
            real_cache.equip = read_equip(0x4A);
            persist_real();
        end
    elseif (e.id == 0x0051) then
        real_cache.face  = struct.unpack('B', e.data, 0x04 + 1);
        real_cache.race  = struct.unpack('B', e.data, 0x05 + 1);
        real_cache.equip = read_equip(0x06);
        persist_real();
    end
end

--[[
* Packet handling entry point. Called from the addon's packet_in handler.
* Rewrites the player's appearance packets to apply the override when enabled.
--]]
function appearance.handle_packet(e)
    -- Always capture the real race/face from the untouched packet first.
    appearance.capture_real_from_packet(e);

    if (not style.enabled) then return; end

    local values = resolve_style();
    if (values == nil) then return; end

    -- Helper to write a uint16 equipment slot at a byte offset.
    local function write_equip(p, base)
        for i = 0, 7 do
            local v = values.equip[i + 1];
            if (v ~= nil and v >= 0) then
                p[base + i * 2]     = bit.band(v, 0xFF);
                p[base + i * 2 + 1] = bit.band(bit.rshift(v, 8), 0xFF);
            end
        end
    end

    -- 0x0A: Zone enter. Model block starts at 0x44 (face/hair, race, equip...).
    if (e.id == 0x000A) then
        local p = ffi.cast('uint8_t*', e.data_modified_raw);
        if (values.face >= 0) then p[0x44] = bit.band(values.face, 0xFF); end
        if (values.race >= 0) then p[0x45] = bit.band(values.race, 0xFF); end
        write_equip(p, 0x46);
        return;
    end

    -- 0x0D: Character update. Model block at 0x48 when update type byte is 0x1F.
    if (e.id == 0x000D) then
        local p = ffi.cast('uint8_t*', e.data_modified_raw);
        local sid = struct.unpack('L', e.data_modified, 0x04 + 0x1);
        if (sid == AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0) and p[0x0A] == 0x1F) then
            if (values.face >= 0) then p[0x48] = bit.band(values.face, 0xFF); end
            if (values.race >= 0) then p[0x49] = bit.band(values.race, 0xFF); end
            write_equip(p, 0x4A);
        end
        return;
    end

    -- 0x51: Character appearance. Model block at 0x04.
    if (e.id == 0x0051) then
        local p = ffi.cast('uint8_t*', e.data_modified_raw);
        if (values.face >= 0) then p[0x04] = bit.band(values.face, 0xFF); end
        if (values.race >= 0) then p[0x05] = bit.band(values.race, 0xFF); end
        write_equip(p, 0x06);
        return;
    end
end

return appearance;

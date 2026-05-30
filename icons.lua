--[[
* WardrobeXI - item icon loader
*
* Loads FFXI item icons from the in-memory item bitmaps exposed by the
* resource manager (the same approach the "equipmon" addon and XIUI use), and
* caches the resulting Direct3D textures so they can be drawn inside ImGui via
* imgui.Image.
*
* Usage:
*   local icons = require('icons');
*   local ptr = icons.get(itemId);     -- returns an imgui image pointer or nil
*   if (ptr ~= nil) then imgui.Image(ptr, { 16, 16 }); end
*
* Call icons.clear() on unload to drop the cached textures.
--]]

require('common');
local d3d = require('d3d8');
local ffi = require('ffi');

local C = ffi.C;
local d3d8dev = d3d.get_device();

local icons = T{};

-- itemId -> { texture = IDirect3DTexture8*, ptr = number } | false (no icon)
local cache = {};

--[[
* Loads an item's icon texture from its in-memory bitmap. Returns the texture
* object on success, or nil if the item has no usable icon data.
--]]
local function load_item_texture(item_id)
    if (item_id == nil or item_id == 0 or item_id == 65535) then
        return nil;
    end

    local item = AshitaCore:GetResourceManager():GetItemById(item_id);
    if (item == nil or item.Bitmap == nil or item.ImageSize == nil or item.ImageSize <= 0) then
        return nil;
    end

    local texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    local res = C.D3DXCreateTextureFromFileInMemoryEx(
        d3d8dev, item.Bitmap, item.ImageSize,
        0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
        C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
        C.D3DX_DEFAULT, C.D3DX_DEFAULT,
        0xFF000000, nil, nil, texture_ptr
    );
    if (res ~= C.S_OK) then
        return nil;
    end

    return d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', texture_ptr[0]));
end

--[[
* Returns an ImGui image pointer (number) for the given item id, loading and
* caching the texture on first use. Returns nil if there is no icon.
--]]
function icons.get(item_id)
    if (item_id == nil or item_id == 0 or item_id == 65535) then
        return nil;
    end

    local entry = cache[item_id];
    if (entry ~= nil) then
        if (entry == false) then return nil; end
        return entry.ptr;
    end

    local texture = load_item_texture(item_id);
    if (texture == nil) then
        cache[item_id] = false;  -- remember the miss so we do not retry forever
        return nil;
    end

    local ptr = tonumber(ffi.cast('uint32_t', texture));
    cache[item_id] = { texture = texture, ptr = ptr };
    return ptr;
end

--[[
* Drops all cached textures. Call on addon unload.
--]]
function icons.clear()
    cache = {};
end

return icons;

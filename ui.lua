--[[
* WardrobeXI - ImGui interface
*
* Three tabs (Glamourer-style):
*   - Player:     live view/edit of the current character. The race / face /
*                 equipment editor edits the live override (settings.style) and
*                 shows what you currently are / have equipped. Header has
*                 copy / paste / save-as-design buttons.
*   - Designs:    named appearance presets. A list with a "+" to create an
*                 empty design, and the SAME editor editing the selected
*                 design's stored values (all "not set" by default).
*   - Automation: rules that auto-apply a design based on the current main/sub
*                 job (FFXI has a subjob, unlike FFXIV).
*
* The race / face / equipment editor is shared between the Player and Designs
* tabs through a small "target" adapter (get/set race, face, equip[i]) plus a
* "mode" describing how to label the "keep" option:
*   - mode 'live'   : Player tab. "keep" shows the current/equipped value.
*   - mode 'design' : Designs tab. "keep" shows "(not set)".
--]]

require('common');
local imgui    = require('imgui');
local settings = require('settings');
local icons    = require('icons');
local designs  = require('designs');

local ui = T{};

-- Race ids -> display names. FFXI uses these model race ids.
local RACES = T{
    { id = 1,  name = 'Hume Male' },
    { id = 2,  name = 'Hume Female' },
    { id = 3,  name = 'Elvaan Male' },
    { id = 4,  name = 'Elvaan Female' },
    { id = 5,  name = 'Tarutaru Male' },
    { id = 6,  name = 'Tarutaru Female' },
    { id = 7,  name = 'Mithra' },
    { id = 8,  name = 'Galka' },
};

-- FFXI job ids -> abbreviation, for the automation job pickers.
local JOBS = T{
    { id = 0,  name = 'Any' },
    { id = 1,  name = 'WAR' }, { id = 2,  name = 'MNK' }, { id = 3,  name = 'WHM' },
    { id = 4,  name = 'BLM' }, { id = 5,  name = 'RDM' }, { id = 6,  name = 'THF' },
    { id = 7,  name = 'PLD' }, { id = 8,  name = 'DRK' }, { id = 9,  name = 'BST' },
    { id = 10, name = 'BRD' }, { id = 11, name = 'RNG' }, { id = 12, name = 'SAM' },
    { id = 13, name = 'NIN' }, { id = 14, name = 'DRG' }, { id = 15, name = 'SMN' },
    { id = 16, name = 'BLU' }, { id = 17, name = 'COR' }, { id = 18, name = 'PUP' },
    { id = 19, name = 'DNC' }, { id = 20, name = 'SCH' }, { id = 21, name = 'GEO' },
    { id = 22, name = 'RUN' },
};

-- Equipment slots, in entity.Look / packet order (index 1..8).
local EQUIP_SLOTS = T{
    'Head', 'Body', 'Hands', 'Legs', 'Feet', 'Main', 'Sub', 'Ranged',
};
local SEARCH_BUFFER_SIZE = 64;
local ICON_SIZE          = 32;

local ctx = T{
    enabled = { false },
    -- Per-slot search filter buffers, shared by whichever editor is open.
    equip_search = T{},
    -- Designs tab: new design name input + currently selected design index.
    new_design_name = { '' },
    selected_design = 0,   -- 0 = none selected
    -- Designs tab: resizable left list width (pixels) + name search filter.
    design_list_width = 150,
    design_search = { '' },
    initialized_from_settings = false,
};
for i = 1, 8 do
    ctx.equip_search[i] = { '' };
end

--========================================================================
-- Small helpers
--========================================================================

local function race_name(id)
    if (id == nil) then return nil; end
    for _, r in ipairs(RACES) do
        if (r.id == id) then return r.name; end
    end
    return nil;
end

local function job_label(id)
    for _, j in ipairs(JOBS) do
        if (j.id == id) then return j.name; end
    end
    return ('Job%d'):fmt(id);
end

local function sync_from_settings(s)
    ctx.enabled[1] = s.style.enabled[1];
    ctx.initialized_from_settings = true;
end

--========================================================================
-- Theme (neutral dark grey, matching the LingoXI config look)
--========================================================================

-- { ImGuiCol_, color } pairs pushed around the window.
local THEME_COLORS = T{
    { 'ImGuiCol_WindowBg',            { 0.10, 0.10, 0.10, 0.94 } },
    { 'ImGuiCol_ChildBg',             { 0.12, 0.12, 0.12, 0.60 } },
    { 'ImGuiCol_PopupBg',             { 0.10, 0.10, 0.10, 0.96 } },
    { 'ImGuiCol_Border',              { 0.30, 0.30, 0.30, 0.50 } },
    { 'ImGuiCol_FrameBg',             { 0.18, 0.18, 0.18, 0.82 } },
    { 'ImGuiCol_FrameBgHovered',      { 0.28, 0.28, 0.28, 0.88 } },
    { 'ImGuiCol_FrameBgActive',       { 0.36, 0.36, 0.36, 0.95 } },
    { 'ImGuiCol_TitleBg',             { 0.08, 0.08, 0.08, 1.00 } },
    { 'ImGuiCol_TitleBgActive',       { 0.14, 0.14, 0.14, 1.00 } },
    { 'ImGuiCol_Button',              { 0.24, 0.24, 0.24, 0.82 } },
    { 'ImGuiCol_ButtonHovered',       { 0.34, 0.34, 0.34, 0.90 } },
    { 'ImGuiCol_ButtonActive',        { 0.44, 0.44, 0.44, 0.96 } },
    { 'ImGuiCol_Header',              { 0.24, 0.24, 0.24, 0.82 } },
    { 'ImGuiCol_HeaderHovered',       { 0.34, 0.34, 0.34, 0.90 } },
    { 'ImGuiCol_HeaderActive',        { 0.44, 0.44, 0.44, 0.96 } },
    { 'ImGuiCol_ScrollbarBg',         { 0.05, 0.05, 0.05, 0.35 } },
    { 'ImGuiCol_ScrollbarGrab',       { 0.42, 0.42, 0.42, 0.72 } },
    { 'ImGuiCol_ScrollbarGrabHovered',{ 0.56, 0.56, 0.56, 0.86 } },
    { 'ImGuiCol_ScrollbarGrabActive', { 0.70, 0.70, 0.70, 0.96 } },
    { 'ImGuiCol_CheckMark',           { 0.82, 0.82, 0.82, 1.00 } },
    { 'ImGuiCol_SliderGrab',          { 0.58, 0.58, 0.58, 0.92 } },
    { 'ImGuiCol_SliderGrabActive',    { 0.78, 0.78, 0.78, 1.00 } },
    { 'ImGuiCol_Tab',                 { 0.18, 0.18, 0.18, 0.86 } },
    { 'ImGuiCol_TabHovered',          { 0.36, 0.36, 0.36, 0.90 } },
    { 'ImGuiCol_TabActive',           { 0.30, 0.30, 0.30, 1.00 } },
    { 'ImGuiCol_TextSelectedBg',      { 0.55, 0.55, 0.55, 0.45 } },
};

--[[
* Pushes the WardrobeXI theme. Returns the number of style colors pushed so the
* caller can pop the exact count.
--]]
local function push_theme()
    for _, c in ipairs(THEME_COLORS) do
        imgui.PushStyleColor(_G[c[1]], c[2]);
    end
    return #THEME_COLORS;
end

function ui.initialize(s, appearance)
    sync_from_settings(s);
end

--========================================================================
-- Target adapters (shared editor data source)
--
-- A target exposes:
--   t.mode               'live' | 'design'
--   t.id                 unique string used to namespace imgui ids
--   t.get_race()/set_race(v)
--   t.get_face()/set_face(v)
--   t.get_equip(i)/set_equip(i, v)
-- Values use -1 to mean "keep / not set".
--========================================================================

--[[
* Builds a target backed by the live override settings.style (Player tab).
--]]
local function live_target(s)
    return {
        mode = 'live',
        id   = 'live',
        get_race  = function() return s.style.race[1]; end,
        set_race  = function(v) s.style.race[1] = v; end,
        get_face  = function() return s.style.face[1]; end,
        set_face  = function(v) s.style.face[1] = v; end,
        get_equip = function(i) return s.style.equip[i]; end,
        set_equip = function(i, v) s.style.equip[i] = v; end,
    };
end

--[[
* Builds a target backed by a saved design table (Designs tab). The design
* stores plain values: design.race, design.face, design.equip[8].
--]]
local function design_target(d, idx)
    if (d.equip == nil) then d.equip = T{ -1, -1, -1, -1, -1, -1, -1, -1 }; end
    return {
        mode = 'design',
        id   = 'design_' .. idx,
        get_race  = function() return d.race or -1; end,
        set_race  = function(v) d.race = v; end,
        get_face  = function() return d.face or -1; end,
        set_face  = function(v) d.face = v; end,
        get_equip = function(i) return d.equip[i] or -1; end,
        set_equip = function(i, v) d.equip[i] = v; end,
    };
end

--========================================================================
-- Shared editor widgets
--========================================================================

--[[
* Race selector. For a live target, the "keep" option shows the detected
* current race; for a design it shows "(not set)".
--]]
local function render_race(t, appearance)
    local changed = false;
    local cur = t.get_race();

    local keep_text, preview;
    if (t.mode == 'live') then
        local nm = race_name(appearance.get_real_race());
        keep_text = nm and ('Keep current (' .. nm .. ')') or '(keep real)';
        if (cur ~= nil and cur >= 0) then
            preview = race_name(cur) or ('Race %d'):fmt(cur);
        else
            preview = nm and (nm .. ' (current)') or '(keep real)';
        end
    else
        keep_text = '(not set)';
        if (cur ~= nil and cur >= 0) then
            preview = race_name(cur) or ('Race %d'):fmt(cur);
        else
            preview = '(not set)';
        end
    end

    imgui.Text('Race');
    imgui.SameLine(70);
    imgui.PushItemWidth(-1);
    if (imgui.BeginCombo('##wxi_race_' .. t.id, preview, ImGuiComboFlags_None)) then
        if (imgui.Selectable(keep_text .. '##keep', cur == nil or cur < 0)) then
            t.set_race(-1); changed = true;
        end
        for _, r in ipairs(RACES) do
            if (imgui.Selectable(r.name .. '##r' .. r.id, cur == r.id)) then
                t.set_race(r.id); changed = true;
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
    return changed;
end

--[[
* Face selector.
--]]
local function render_face(t, appearance)
    local changed = false;
    local cur = t.get_face();

    local keep_text;
    if (t.mode == 'live') then
        local rf = appearance.get_real_face();
        keep_text = rf and ('Keep current (Face %d)'):fmt(rf) or '(keep real)';
    else
        keep_text = '(not set)';
    end

    local preview;
    if (cur ~= nil and cur >= 0) then
        preview = ('Face %d'):fmt(cur);
    elseif (t.mode == 'live') then
        local rf = appearance.get_real_face();
        preview = rf and ('Face %d (current)'):fmt(rf) or '(keep real)';
    else
        preview = '(not set)';
    end

    imgui.Text('Face');
    imgui.SameLine(70);
    imgui.PushItemWidth(-1);
    if (imgui.BeginCombo('##wxi_face_' .. t.id, preview, ImGuiComboFlags_None)) then
        if (imgui.Selectable(keep_text .. '##keep', cur == nil or cur < 0)) then
            t.set_face(-1); changed = true;
        end
        for i = 0, 15 do
            if (imgui.Selectable(('Face %d'):fmt(i) .. '##f' .. i, cur == i)) then
                t.set_face(i); changed = true;
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
    return changed;
end

--[[
* Draws an item icon inline (followed by SameLine), reserving space if absent.
--]]
local function draw_icon_inline(item_id)
    local ptr = item_id and icons.get(item_id) or nil;
    if (ptr ~= nil) then
        imgui.Image(ptr, { ICON_SIZE, ICON_SIZE });
    else
        imgui.Dummy({ ICON_SIZE, ICON_SIZE });
    end
    imgui.SameLine();
end

--[[
* A selectable list row with a 32px icon and a vertically-centered label.
--]]
local function icon_row(item_id, text, id, selected)
    local start_x, start_y = imgui.GetCursorScreenPos();
    local flags = bit.bor(ImGuiSelectableFlags_AllowItemOverlap, ImGuiSelectableFlags_SpanAllColumns);
    local clicked = imgui.Selectable('##' .. id, selected, flags, { 0, ICON_SIZE });
    local end_x, end_y = imgui.GetCursorScreenPos();

    local ptr = item_id and icons.get(item_id) or nil;
    if (ptr ~= nil) then
        imgui.SetCursorScreenPos({ start_x, start_y });
        imgui.Image(ptr, { ICON_SIZE, ICON_SIZE });
    end

    local text_h = imgui.GetTextLineHeight();
    imgui.SetCursorScreenPos({ start_x + ICON_SIZE + 6, start_y + (ICON_SIZE - text_h) * 0.5 });
    imgui.Text(text);

    imgui.SetCursorScreenPos({ end_x, end_y });
    return clicked;
end

--[[
* One equipment slot as a searchable, icon dropdown, editing the target.
--]]
local function render_equip_slot(t, appearance, index, slot_name)
    local changed = false;
    -- Equip values are ITEM IDS: -1 = keep, 0 = none/empty, >0 = item id.
    local current = t.get_equip(index);

    -- Preview label + icon item id.
    local preview;
    local preview_item_id = nil;
    if (current == nil or current < 0) then
        if (t.mode == 'live') then
            local item_id = appearance.get_equipped_item_id(index);
            local nm = appearance.item_name(index, item_id);
            preview_item_id = item_id;
            preview = nm and (nm .. ' (equipped)') or '(keep equipped)';
        else
            preview = '(not set)';
        end
    elseif (current == 0) then
        preview = 'None (empty)';
    else
        preview = appearance.item_name(index, current) or ('Item %d'):fmt(current);
        preview_item_id = current;
    end

    imgui.Text(slot_name);
    imgui.SameLine(70);
    draw_icon_inline(preview_item_id);
    imgui.PushItemWidth(-28);
    if (imgui.BeginCombo('##wxi_equip_' .. t.id .. '_' .. index, preview, ImGuiComboFlags_HeightLargest)) then
        imgui.SetNextItemWidth(-1);
        imgui.InputText('##wxi_search_' .. t.id .. '_' .. index, ctx.equip_search[index], SEARCH_BUFFER_SIZE);
        imgui.Separator();

        local filter = ctx.equip_search[index][1]:lower();
        imgui.BeginChild('##wxi_scroll_' .. t.id .. '_' .. index, { 0, 280 }, false);

        -- Keep row.
        local keep_label;
        local keep_icon = nil;
        if (t.mode == 'live') then
            local item_id = appearance.get_equipped_item_id(index);
            local nm = appearance.item_name(index, item_id);
            keep_icon  = item_id;
            keep_label = nm and ('Keep equipped (' .. nm .. ')') or '(keep equipped)';
        else
            keep_label = '(not set)';
        end
        if (icon_row(keep_icon, keep_label, 'keep_' .. t.id .. '_' .. index, current == nil or current < 0)) then
            t.set_equip(index, -1); changed = true;
            ctx.equip_search[index][1] = '';
            imgui.CloseCurrentPopup();
        end

        -- None (bare) row.
        if (icon_row(nil, 'None (empty)', 'none_' .. t.id .. '_' .. index, current == 0)) then
            t.set_equip(index, 0); changed = true;
            ctx.equip_search[index][1] = '';
            imgui.CloseCurrentPopup();
        end

        -- Filtered item rows (stores the chosen item id, not the shared model).
        local items = appearance.get_slot_items(index);
        local shown = 0;
        for _, item in ipairs(items) do
            if (filter == '' or item.name:lower():find(filter, 1, true) ~= nil) then
                local is_selected = (current == item.id);
                if (icon_row(item.id, item.name, 'it_' .. t.id .. '_' .. index .. '_' .. item.id, is_selected)) then
                    t.set_equip(index, item.id); changed = true;
                    ctx.equip_search[index][1] = '';
                    imgui.CloseCurrentPopup();
                end
                shown = shown + 1;
                if (shown >= 500) then
                    imgui.TextDisabled('... refine your search to see more');
                    break;
                end
            end
        end

        imgui.EndChild();
        imgui.EndCombo();
    end
    imgui.PopItemWidth();

    -- Clear (X) button: resets this slot to "keep / not set".
    imgui.SameLine();
    if (imgui.Button('X##wxi_clear_' .. t.id .. '_' .. index, { 22, 0 })) then
        t.set_equip(index, -1);
        changed = true;
    end
    if (imgui.IsItemHovered()) then imgui.SetTooltip('Clear this slot.'); end
    return changed;
end

--[[
* Draws the full race/face/equipment editor for a target. Returns true if any
* value changed this frame.
--]]
local function render_editor(t, appearance)
    local dirty = false;
    imgui.TextDisabled('Appearance');
    if (render_race(t, appearance)) then dirty = true; end
    if (render_face(t, appearance)) then dirty = true; end
    imgui.Separator();
    imgui.TextDisabled('Equipment');
    for i, slot in ipairs(EQUIP_SLOTS) do
        if (render_equip_slot(t, appearance, i, slot)) then dirty = true; end
    end
    return dirty;
end

--========================================================================
-- Clipboard (copy / paste a set)
--========================================================================

-- Serializes the 10 values (race, face, equip[8]) of a target to a string.
local function serialize_target(t)
    local parts = T{ 'WXI1', tostring(t.get_race()), tostring(t.get_face()) };
    for i = 1, 8 do
        parts:append(tostring(t.get_equip(i)));
    end
    return table.concat(parts, ',');
end

-- Parses a serialized set into { race, face, equip[8] } or nil.
local function deserialize_set(text)
    if (text == nil) then return nil; end
    local fields = T{};
    for token in text:gmatch('([^,]+)') do
        fields:append(token);
    end
    if (#fields < 11 or fields[1] ~= 'WXI1') then return nil; end
    local set = T{ race = tonumber(fields[2]), face = tonumber(fields[3]), equip = T{} };
    for i = 1, 8 do
        set.equip[i] = tonumber(fields[3 + i]);
    end
    if (set.race == nil or set.face == nil) then return nil; end
    return set;
end

-- Applies a parsed set into a target.
local function apply_set_to_target(t, set)
    t.set_race(set.race);
    t.set_face(set.face);
    for i = 1, 8 do
        t.set_equip(i, set.equip[i] or -1);
    end
end

--========================================================================
-- Tab: Player
--========================================================================

local function render_player_tab(s, appearance)
    local t = live_target(s);

    -- Master enable toggle.
    if (imgui.Checkbox('Enable appearance override', ctx.enabled)) then
        s.style.enabled[1] = ctx.enabled[1];
        if (ctx.enabled[1]) then
            appearance.apply_to_self(s);
        else
            appearance.restore_self();
        end
        settings.save();
    end

    -- Header buttons: copy / paste / save-as-design.
    if (imgui.Button('Copy', { 70, 0 })) then
        imgui.SetClipboardText(serialize_target(t));
    end
    if (imgui.IsItemHovered()) then imgui.SetTooltip('Copy the current set to the clipboard.'); end
    imgui.SameLine();
    if (imgui.Button('Paste', { 70, 0 })) then
        local set = deserialize_set(imgui.GetClipboardText());
        if (set ~= nil) then
            apply_set_to_target(t, set);
            s.style.enabled[1] = true;
            ctx.enabled[1] = true;
            appearance.apply_to_self(s);
            settings.save();
        end
    end
    if (imgui.IsItemHovered()) then imgui.SetTooltip('Apply a set from the clipboard.'); end
    imgui.SameLine();
    if (imgui.Button('Add Design', { 110, 0 })) then
        -- Save current set as a new auto-named design.
        local base = 'New Design';
        local name = base;
        local n = 1;
        while (designs.find(s, name) ~= nil) do
            n = n + 1;
            name = base .. ' ' .. n;
        end
        designs.save(s, name);
        settings.save();
    end
    if (imgui.IsItemHovered()) then imgui.SetTooltip('Save the current set as a new design.'); end

    imgui.Separator();

    local dirty = render_editor(t, appearance);

    imgui.Separator();

    if (imgui.Button('Apply', { 100, 0 })) then
        s.style.enabled[1] = true;
        ctx.enabled[1] = true;
        appearance.apply_to_self(s);
        settings.save();
    end
    imgui.SameLine();
    if (imgui.Button('Restore', { 100, 0 })) then
        s.style.enabled[1] = false;
        ctx.enabled[1] = false;
        t.set_race(-1); t.set_face(-1);
        for i = 1, 8 do t.set_equip(i, -1); end
        appearance.set_style(s);
        appearance.restore_self();
        settings.save();
    end

    if (dirty) then
        settings.save();
        if (s.style.enabled[1]) then
            appearance.apply_to_self(s);
        end
    end
end

--========================================================================
-- Tab: Designs
--========================================================================

local function render_designs_tab(s, appearance)
    local avail_w = imgui.GetContentRegionAvail();
    local list_w = ctx.design_list_width;
    -- Clamp the list width so both panes stay usable.
    if (list_w < 90) then list_w = 90; end
    if (list_w > avail_w - 180) then list_w = math.max(90, avail_w - 180); end
    ctx.design_list_width = list_w;

    -- Left: design list with "+ New".
    imgui.BeginChild('##wxi_design_list', { list_w, 0 }, true);
    if (imgui.Button('+ New', { -1, 0 })) then
        local base = 'New Design';
        local name = base;
        local n = 1;
        while (designs.find(s, name) ~= nil) do
            n = n + 1;
            name = base .. ' ' .. n;
        end
        -- Create an empty design (all "not set").
        local d = T{ name = name, race = -1, face = -1, equip = T{ -1, -1, -1, -1, -1, -1, -1, -1 } };
        table.insert(s.designs, d);
        ctx.selected_design = #s.designs;
        settings.save();
    end

    -- Search filter for the design names.
    imgui.PushItemWidth(-1);
    imgui.InputTextWithHint('##wxi_design_search', 'Search...', ctx.design_search, 64);
    imgui.PopItemWidth();
    local dfilter = ctx.design_search[1]:lower();

    imgui.Separator();

    -- Highlight the design that matches the currently applied style, and allow
    -- reordering by dragging an item up or down (simple ImGui reorder pattern).
    local style_active = s.style.enabled[1];
    local reordering = (dfilter == '');
    local count = #s.designs;
    for i, d in ipairs(s.designs) do
        if (dfilter == '' or d.name:lower():find(dfilter, 1, true) ~= nil) then
            local is_active = style_active and designs.matches_style(d, s.style);
            if (is_active) then
                imgui.PushStyleColor(ImGuiCol_Text, { 0.4, 1.0, 0.4, 1.0 });
            end
            if (imgui.Selectable(d.name .. '##wxi_dsel_' .. i, ctx.selected_design == i)) then
                ctx.selected_design = i;
            end
            if (is_active) then
                imgui.PopStyleColor();
            end

            -- Drag up/down to reorder.
            if (reordering and imgui.IsItemActive() and not imgui.IsItemHovered()) then
                local _, dy = imgui.GetMouseDragDelta(0, 0.0);
                -- Swap only after the drag passes roughly one row height, then
                -- reset the delta so it does not oscillate.
                local row_h = imgui.GetTextLineHeightWithSpacing();
                if (dy ~= nil and dy <= -row_h and i > 1) then
                    s.designs[i], s.designs[i - 1] = s.designs[i - 1], s.designs[i];
                    if (ctx.selected_design == i) then ctx.selected_design = i - 1;
                    elseif (ctx.selected_design == i - 1) then ctx.selected_design = i; end
                    imgui.ResetMouseDragDelta(0);
                    settings.save();
                elseif (dy ~= nil and dy >= row_h and i < count) then
                    s.designs[i], s.designs[i + 1] = s.designs[i + 1], s.designs[i];
                    if (ctx.selected_design == i) then ctx.selected_design = i + 1;
                    elseif (ctx.selected_design == i + 1) then ctx.selected_design = i; end
                    imgui.ResetMouseDragDelta(0);
                    settings.save();
                end
            end
        end
    end
    imgui.EndChild();

    -- Splitter handle (drag left/right to resize the list).
    imgui.SameLine();
    imgui.PushStyleColor(ImGuiCol_Button, { 0.4, 0.4, 0.4, 0.3 });
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.6, 0.6, 0.6, 0.6 });
    imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.8, 0.8, 0.8, 0.8 });
    imgui.Button('##wxi_design_splitter', { 6, -1 });
    imgui.PopStyleColor(3);
    if (imgui.IsItemHovered() or imgui.IsItemActive()) then
        imgui.SetMouseCursor(ImGuiMouseCursor_ResizeEW);
    end
    if (imgui.IsItemActive()) then
        local dx = imgui.GetMouseDragDelta(0, 0.0);
        if (dx ~= nil) then
            ctx.design_list_width = ctx.design_list_width + dx;
            imgui.ResetMouseDragDelta(0);
        end
    end
    imgui.SameLine();

    -- Right: selected design editor.
    imgui.BeginChild('##wxi_design_edit', { 0, 0 }, false);
    local idx = ctx.selected_design;
    local d = s.designs[idx];
    if (d == nil) then
        imgui.TextDisabled('Select a design on the left, or create one with "+ New".');
        imgui.TextDisabled('A new design starts empty (nothing set). Anything you');
        imgui.TextDisabled('leave as "(not set)" is left unchanged when applied.');
        imgui.EndChild();
        return;
    end

    -- Rename field.
    local name_buf = { d.name };
    imgui.PushItemWidth(-1);
    if (imgui.InputText('##wxi_design_name', name_buf, 64)) then
        local nn = name_buf[1]:trim();
        if (nn ~= '') then d.name = nn; settings.save(); end
    end
    imgui.PopItemWidth();

    local dt = design_target(d, idx);

    -- Action buttons: Apply, Copy, Paste, Clone, Delete.
    if (imgui.Button('Apply', { 70, 0 })) then
        designs.to_style(d, s.style);
        s.style.enabled[1] = true;
        ctx.enabled[1] = true;
        appearance.apply_to_self(s);
        settings.save();
    end
    if (imgui.IsItemHovered()) then imgui.SetTooltip('Apply this design to your character.'); end
    imgui.SameLine();
    if (imgui.Button('Copy', { 60, 0 })) then
        imgui.SetClipboardText(serialize_target(dt));
    end
    if (imgui.IsItemHovered()) then imgui.SetTooltip('Copy this design to the clipboard.'); end
    imgui.SameLine();
    if (imgui.Button('Paste', { 60, 0 })) then
        local set = deserialize_set(imgui.GetClipboardText());
        if (set ~= nil) then
            apply_set_to_target(dt, set);
            settings.save();
        end
    end
    if (imgui.IsItemHovered()) then imgui.SetTooltip('Replace this design with the clipboard set.'); end
    imgui.SameLine();
    if (imgui.Button('Clone', { 60, 0 })) then
        local nd = designs.clone(s, d.name);
        if (nd ~= nil) then
            ctx.selected_design = #s.designs;
            settings.save();
        end
    end
    if (imgui.IsItemHovered()) then imgui.SetTooltip('Duplicate this design.'); end
    imgui.SameLine();
    if (imgui.Button('Delete', { 60, 0 })) then
        designs.delete(s, d.name);
        ctx.selected_design = 0;
        settings.save();
        imgui.EndChild();
        return;
    end

    imgui.Separator();

    if (render_editor(dt, appearance)) then
        settings.save();
    end

    imgui.EndChild();
end

--========================================================================
-- Tab: Automation
--========================================================================

local function render_automation_tab(s, appearance)
    local auto = s.automation;
    local main, sub = appearance.get_jobs();

    -- Status card: enable toggle + current job + which design is active.
    imgui.BeginChild('##wxi_auto_status', { 0, 78 }, true);
    local en = { auto.enabled[1] };
    if (imgui.Checkbox('Enable automation', en)) then
        auto.enabled[1] = en[1];
        settings.save();
    end
    imgui.SameLine();
    imgui.TextDisabled('  Applies a design automatically based on your job.');

    imgui.Spacing();
    imgui.Text('Current job:');
    imgui.SameLine();
    imgui.TextColored({ 0.4, 0.8, 1.0, 1.0 }, ('%s / %s'):fmt(appearance.job_abbr(main), appearance.job_abbr(sub)));
    imgui.SameLine();
    imgui.Text('   Active design:');
    imgui.SameLine();
    local active = designs.match_rule(s, main, sub);
    if (auto.enabled[1] and active ~= nil and active ~= '') then
        imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, active);
    else
        imgui.TextDisabled('(none)');
    end
    imgui.EndChild();

    imgui.Spacing();
    if (imgui.Button('Add rule', { 100, 0 })) then
        designs.add_rule(s);
        settings.save();
    end
    imgui.SameLine();
    imgui.TextDisabled(('%d rule(s). First matching enabled rule wins.'):fmt(#auto.rules));

    imgui.Spacing();

    -- Build the design picker contents once.
    local function design_combo(rule)
        imgui.Text('Design');
        imgui.SameLine();
        imgui.PushItemWidth(-1);
        local preview = (rule.design ~= nil and rule.design ~= '') and rule.design or '(none)';
        if (imgui.BeginCombo('##design', preview)) then
            if (imgui.Selectable('(none)', rule.design == '' or rule.design == nil)) then
                rule.design = ''; settings.save();
            end
            for _, d in ipairs(s.designs) do
                if (imgui.Selectable(d.name .. '##d', rule.design == d.name)) then
                    rule.design = d.name; settings.save();
                end
            end
            imgui.EndCombo();
        end
        imgui.PopItemWidth();
    end

    local function job_combo(label, id, get, set)
        imgui.Text(label);
        imgui.SameLine();
        imgui.PushItemWidth(-1);
        if (imgui.BeginCombo(id, job_label(get()))) then
            for _, j in ipairs(JOBS) do
                if (imgui.Selectable(j.name .. id .. j.id, get() == j.id)) then
                    set(j.id); settings.save();
                end
            end
            imgui.EndCombo();
        end
        imgui.PopItemWidth();
    end

    -- Rules render at their natural height (no inner scroll region).
    designs.ensure_rule_uids(s);
    local remove_idx = nil;
    local rule_count = #auto.rules;
    for i, rule in ipairs(auto.rules) do
        imgui.PushID('wxi_rule_' .. rule.uid);

        -- One bordered card per rule.
        local is_active = (auto.enabled[1] and rule.enabled and active ~= nil and active ~= ''
            and rule.design == active
            and (rule.main == 0 or rule.main == main)
            and (rule.sub == 0 or rule.sub == sub));
        if (is_active) then
            imgui.PushStyleColor(ImGuiCol_Border, { 0.4, 1.0, 0.4, 0.8 });
        end
        imgui.BeginChild('##rule_card', { 0, 90 }, true, bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse));

        -- Row 1: up/down reorder + enabled toggle + active badge + delete.
        if (imgui.Button('^##up', { 24, 0 }) and i > 1) then
            auto.rules[i], auto.rules[i - 1] = auto.rules[i - 1], auto.rules[i];
            settings.save();
        end
        if (imgui.IsItemHovered()) then imgui.SetTooltip('Move rule up.'); end
        imgui.SameLine();
        if (imgui.Button('v##down', { 24, 0 }) and i < rule_count) then
            auto.rules[i], auto.rules[i + 1] = auto.rules[i + 1], auto.rules[i];
            settings.save();
        end
        if (imgui.IsItemHovered()) then imgui.SetTooltip('Move rule down.'); end
        imgui.SameLine();

        local ren = { rule.enabled };
        if (imgui.Checkbox('Enabled', ren)) then
            rule.enabled = ren[1];
            settings.save();
        end
        if (is_active) then
            imgui.SameLine();
            imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, '[ ACTIVE ]');
        end
        imgui.SameLine();
        local avail = imgui.GetContentRegionAvail();
        imgui.SetCursorPosX(imgui.GetCursorPosX() + math.max(0, avail - 60));
        if (imgui.Button('Delete', { 60, 0 })) then
            remove_idx = i;
        end

        -- Row 2: Main / Sub job, side by side.
        imgui.Columns(2, '##rule_jobs', false);
        job_combo('Main', '##main', function() return rule.main; end, function(v) rule.main = v; end);
        imgui.NextColumn();
        job_combo('Sub', '##sub', function() return rule.sub; end, function(v) rule.sub = v; end);
        imgui.Columns(1);

        -- Row 3: design picker (full width).
        design_combo(rule);

        imgui.EndChild();
        if (is_active) then
            imgui.PopStyleColor();
        end

        imgui.Spacing();
        imgui.PopID();
    end

    if (remove_idx ~= nil) then
        table.remove(auto.rules, remove_idx);
        settings.save();
    end
end

--========================================================================
-- Window
--========================================================================

function ui.render(s, appearance)
    if (not ctx.initialized_from_settings) then
        sync_from_settings(s);
    end

    if (not s.window.visible[1]) then
        return;
    end

    imgui.SetNextWindowSize({ 460, 600 }, ImGuiCond_FirstUseEver);
    local pushed = push_theme();
    local is_open = { s.window.visible[1] };
    if (imgui.Begin('WardrobeXI', is_open, ImGuiWindowFlags_None)) then
        if (imgui.BeginTabBar('##wxi_tabs', ImGuiTabBarFlags_None)) then
            if (imgui.BeginTabItem('Actor')) then
                render_player_tab(s, appearance);
                imgui.EndTabItem();
            end
            if (imgui.BeginTabItem('Designs')) then
                render_designs_tab(s, appearance);
                imgui.EndTabItem();
            end
            if (imgui.BeginTabItem('Automation')) then
                render_automation_tab(s, appearance);
                imgui.EndTabItem();
            end
            imgui.EndTabBar();
        end
    end
    imgui.End();
    imgui.PopStyleColor(pushed);

    if (is_open[1] ~= s.window.visible[1]) then
        s.window.visible[1] = is_open[1];
    end
end

return ui;

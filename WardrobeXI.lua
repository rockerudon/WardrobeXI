--[[
* WardrobeXI - A visual lockstyle / appearance editor for Final Fantasy XI.
*
* MIT License
* Copyright (c) 2026 rockerudon
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
--]]

addon.name    = 'WardrobeXI';
addon.author  = 'rockerudon';
addon.version = '0.1.0';
addon.desc    = 'Visual lockstyle / appearance editor with an ImGui interface.';
addon.link    = '';

require('common');
local chat       = require('chat');
local settings   = require('settings');
local appearance = require('appearance');
local ui         = require('ui');
local icons      = require('icons');
local designs    = require('designs');

-- Default persisted settings.
local default_settings = T{
    window = T{
        visible = T{ false, },
    },
    -- Saved appearance override for the local player. nil values mean "real".
    style = T{
        enabled = T{ false, },
        race    = T{ -1, },   -- -1 = keep real value
        face    = T{ -1, },
        -- 8 equipment model slots (head, body, hands, legs, feet, main, sub, range)
        equip   = T{ -1, -1, -1, -1, -1, -1, -1, -1, },
    },
    -- Persisted REAL race/face for this character so detection / restore
    -- survive a reload even while an override is active. -1 = unknown.
    real = T{
        race = T{ -1, },
        face = T{ -1, },
    },
    -- Saved designs (named appearance presets). Each entry:
    --   { name = string, race = n, face = n, equip = { 8 } }
    designs = T{ },
    -- Automation rules. Each entry:
    --   { enabled = bool, design = name, main = jobId, sub = jobId }
    -- main/sub of 0 means "any". The first matching enabled rule applies.
    automation = T{
        enabled = T{ false, },
        rules   = T{ },
    },
};

local wardrobe = T{
    settings = settings.load(default_settings),
};

-- Automation tracking: last applied design + last seen jobs to avoid redundant
-- re-applies every frame.
local auto_state = T{
    last_main   = -1,
    last_sub    = -1,
    last_design = nil,
};

--[[
* Applies the currently configured style to the local player, if enabled.
--]]
local function apply_current_style()
    if (not wardrobe.settings.style.enabled[1]) then
        return;
    end
    appearance.apply_to_self(wardrobe.settings);
end

--[[
* Automation: when the player's main/sub job changes, apply the design mapped
* by the automation rules (if any). Applying a design copies its values into
* settings.style and enables the override.
--]]
local function update_automation()
    if (not wardrobe.settings.automation.enabled[1]) then
        return;
    end

    local main, sub = appearance.get_jobs();
    if (main == 0) then return; end  -- jobs not loaded yet (zoning, etc.)

    -- Only act on a job change.
    if (main == auto_state.last_main and sub == auto_state.last_sub) then
        return;
    end
    auto_state.last_main = main;
    auto_state.last_sub  = sub;

    local design_name = designs.match_rule(wardrobe.settings, main, sub);
    if (design_name == nil) then
        return;  -- no rule for this job; leave the current look as-is
    end
    if (design_name == auto_state.last_design) then
        return;  -- already applied
    end

    local d = designs.find(wardrobe.settings, design_name);
    if (d == nil) then return; end

    designs.to_style(d, wardrobe.settings.style);
    wardrobe.settings.style.enabled[1] = true;
    appearance.apply_to_self(wardrobe.settings);
    auto_state.last_design = design_name;
    settings.save();
end

--========================================================================
-- Ashita events
--========================================================================

ashita.events.register('load', 'load_cb', function()
    -- The Actor tab is a transient working state: it always starts by detecting
    -- the player's real appearance. Only Designs and Automation persist. So we
    -- reset the live override on load and never carry a saved override.
    wardrobe.settings.style.enabled[1] = false;
    wardrobe.settings.style.race[1] = -1;
    wardrobe.settings.style.face[1] = -1;
    for i = 1, 8 do
        wardrobe.settings.style.equip[i] = -1;
    end

    appearance.bind_settings(wardrobe.settings);
    appearance.initialize();
    ui.initialize(wardrobe.settings, appearance);
    -- No saved override is applied on load; the character keeps its real look.
end);

ashita.events.register('unload', 'unload_cb', function()
    -- Restore the player's real appearance before unloading.
    appearance.restore_self();
    icons.clear();
    settings.save();
end);

ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end

    local cmd = args[1]:lower();
    if (cmd ~= '/wardrobe' and cmd ~= '/wardrobexi' and cmd ~= '/wxi') then
        return;
    end

    -- Block the command from reaching the game.
    e.blocked = true;

    -- No sub-command: toggle the window.
    if (#args == 1) then
        wardrobe.settings.window.visible[1] = not wardrobe.settings.window.visible[1];
        return;
    end

    local sub = args[2]:lower();
    if (sub == 'on') then
        wardrobe.settings.style.enabled[1] = true;
        apply_current_style();
        print(chat.header(addon.name):append(chat.message('Appearance override enabled.')));
    elseif (sub == 'off') then
        wardrobe.settings.style.enabled[1] = false;
        appearance.restore_self();
        print(chat.header(addon.name):append(chat.message('Appearance override disabled.')));
    elseif (sub == 'show') then
        wardrobe.settings.window.visible[1] = true;
    elseif (sub == 'hide') then
        wardrobe.settings.window.visible[1] = false;
    else
        print(chat.header(addon.name):append(chat.message('Usage: /wardrobe [on | off | show | hide]')));
    end
end);

-- Re-apply the style every frame so it survives the game refreshing the model.
ashita.events.register('d3d_present', 'present_cb', function()
    -- Snapshot the real race/face while idle so detection/restore stay correct.
    appearance.refresh_real();
    update_automation();
    apply_current_style();
    ui.render(wardrobe.settings, appearance);
end);

-- Rewrite incoming appearance packets so the override survives server updates,
-- and capture the player's real race/face from the original packet data.
ashita.events.register('packet_in', 'packet_in_cb', function(e)
    appearance.set_style(wardrobe.settings);
    appearance.handle_packet(e);
end);

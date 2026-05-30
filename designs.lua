--[[
* WardrobeXI - designs & automation
*
* A "design" is a saved appearance preset: a snapshot of the style values
* (race, face, and the 8 equipment model slots). This mirrors Glamourer's
* Designs tab.
*
* "Automation" maps the player's current main/sub job to a design, applying it
* automatically when the job combination matches. FFXI has a subjob (unlike
* FFXIV), so rules match on both main and sub (0 = any).
*
* This module only manipulates plain settings tables; applying a design to the
* character is done by copying its values into settings.style and asking the
* appearance engine to apply (handled by WardrobeXI.lua).
--]]

require('common');

local designs = T{};

--========================================================================
-- Design helpers
--========================================================================

--[[
* Captures the current style override (settings.style) into a new design table.
--]]
function designs.from_style(style)
    local d = T{
        race  = style.race[1],
        face  = style.face[1],
        equip = T{},
    };
    for i = 1, 8 do
        d.equip[i] = style.equip[i] or -1;
    end
    return d;
end

--[[
* Copies a design's values into the settings.style override table (without
* touching the enabled flag).
--]]
function designs.to_style(d, style)
    style.race[1] = d.race or -1;
    style.face[1] = d.face or -1;
    for i = 1, 8 do
        style.equip[i] = (d.equip and d.equip[i]) or -1;
    end
end

--[[
* Finds a design by name in settings.designs. Returns the design and its index,
* or nil.
--]]
function designs.find(settings, name)
    for i, d in ipairs(settings.designs) do
        if (d.name == name) then
            return d, i;
        end
    end
    return nil, nil;
end

--[[
* Saves the current style as a design with the given name, overwriting an
* existing design of the same name. Returns the design.
--]]
function designs.save(settings, name)
    local d = designs.from_style(settings.style);
    d.name = name;

    local existing, idx = designs.find(settings, name);
    if (existing ~= nil) then
        settings.designs[idx] = d;
    else
        table.insert(settings.designs, d);
    end
    return d;
end

--[[
* Deletes a design by name. Also clears any automation rules referencing it.
--]]
function designs.delete(settings, name)
    local _, idx = designs.find(settings, name);
    if (idx == nil) then return false; end
    table.remove(settings.designs, idx);

    for _, rule in ipairs(settings.automation.rules) do
        if (rule.design == name) then
            rule.design = '';
        end
    end
    return true;
end

--[[
* Clones a design under a new unique name ("<name> (copy)"), returning the new
* design.
--]]
function designs.clone(settings, name)
    local src = designs.find(settings, name);
    if (src == nil) then return nil; end

    local base = name .. ' (copy)';
    local new_name = base;
    local n = 1;
    while (designs.find(settings, new_name) ~= nil) do
        n = n + 1;
        new_name = base .. ' ' .. n;
    end

    local d = T{
        name  = new_name,
        race  = src.race or -1,
        face  = src.face or -1,
        equip = T{},
    };
    for i = 1, 8 do
        d.equip[i] = (src.equip and src.equip[i]) or -1;
    end
    table.insert(settings.designs, d);
    return d;
end

--[[
* Returns true if the design's values exactly match the current applied style
* override (race, face, and all 8 equip slots). Used to highlight the active
* design in the list. Only meaningful while the override is enabled.
--]]
function designs.matches_style(d, style)
    if ((d.race or -1) ~= style.race[1]) then return false; end
    if ((d.face or -1) ~= style.face[1]) then return false; end
    for i = 1, 8 do
        local dv = (d.equip and d.equip[i]) or -1;
        if (dv ~= (style.equip[i] or -1)) then return false; end
    end
    return true;
end

--========================================================================
-- Automation
--========================================================================

--[[
* Returns the design name that should be active for the given main/sub job per
* the automation rules, or nil if none match. A rule matches when its main is
* 0 (any) or equals the current main, AND its sub is 0 (any) or equals the
* current sub. The first enabled, matching rule with a valid design wins.
--]]
function designs.match_rule(settings, main_job, sub_job)
    if (not settings.automation.enabled[1]) then return nil; end

    for _, rule in ipairs(settings.automation.rules) do
        if (rule.enabled and rule.design ~= nil and rule.design ~= '') then
            local main_ok = (rule.main == 0 or rule.main == main_job);
            local sub_ok  = (rule.sub == 0 or rule.sub == sub_job);
            if (main_ok and sub_ok) then
                return rule.design;
            end
        end
    end
    return nil;
end

--[[
* Adds a new empty automation rule and returns it.
--]]
function designs.add_rule(settings)
    local rule = T{ enabled = true, design = '', main = 0, sub = 0, uid = designs.next_uid(settings), };
    table.insert(settings.automation.rules, rule);
    return rule;
end

--[[
* Returns a unique id for a new rule (max existing uid + 1). Also used to
* backfill uids on older saved rules that predate this field.
--]]
function designs.next_uid(settings)
    local max = 0;
    for _, r in ipairs(settings.automation.rules) do
        if (type(r.uid) == 'number' and r.uid > max) then max = r.uid; end
    end
    return max + 1;
end

--[[
* Ensures every rule has a stable uid (backfills missing ones). Returns true if
* anything changed.
--]]
function designs.ensure_rule_uids(settings)
    local changed = false;
    local max = 0;
    for _, r in ipairs(settings.automation.rules) do
        if (type(r.uid) == 'number' and r.uid > max) then max = r.uid; end
    end
    for _, r in ipairs(settings.automation.rules) do
        if (type(r.uid) ~= 'number') then
            max = max + 1;
            r.uid = max;
            changed = true;
        end
    end
    return changed;
end

return designs;

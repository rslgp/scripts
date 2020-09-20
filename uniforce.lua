-- Prompt units to adjust their uniform.
local help = [====[

uniforce
========

Prompt units to reevaluate their uniform, by removing/dropping potentially conflicting worn items.

Unlike a "replace clothing" designation, it won't remove additional clothing
if it's coexisting with a uniform item already on that body part.
It also won't remove clothing (e.g. shoes, trousers) if the unit has yet to claim an 
armor item for that bodypart. (e.g. if you're still manufacturing them.)

By default it simply prints info about the currently selected unit,
to actually drop items, you need to provide it the -drop option.

The default algorithm assumes that there's only one armor item assigned per body part,
which means that it may miss cases where one piece of armor is blocked but the other
is present. The -multi option can possibly get around this, but at the cost of ignoring
left/right distinctions when dropping items.

In no cases should it cause a uniform item to be removed/dropped. 

Targets:
:(no target): Force the selected dwarf to put on their uniform.
:-all:        Force the uniform on all military dwarves

Options:
:(none):      Will simply show identified issues (dry-run)
:-drop:       Will cause offending items to be placed on ground under unit
:-multi:      Be more agressive in removing items, best for when uniforms have muliple items per body part
]====]

local utils = require('utils')

local validArgs = utils.invert({
  'all',
  'drop',
  'multi',
  'help'
})

---- Debugging function

local dumper = require('dumper')

function debug_print_light(entry)
  dfhack.println("----------------")
  dfhack.println(tostring(entry))
  for k,v in pairs(entry) do
    dfhack.println('    '..k)
  end
  dfhack.println("----------------")
end

function debug_print(entry)
  dfhack.println("----------------")
  dfhack.println(tostring(entry))
  for k,v in pairs(entry) do
    dfhack.println('    '..k..':  '..tostring(v))
  end
  dfhack.println("----------------")
end

function find_item_by_ID(id)
  for k,v in pairs(df.global.world.items.all) do
    if v.id == id then
      return v
    end
  end
  return nil
end

function print_item_list(vector)
  for i,v in pairs(vector) do
    local item = find_item_by_ID(v)
    dfhack.println(i.."  "..v.."   "..tostring(item).."  "..utils.getItemDescription(item))
  end
end

function print_item_list_verbose(vector)
  for i,v in pairs(vector) do
    local item = find_item_by_ID(v)
    debug_print_light(item)
  end
end

-- Unused utility functions

function val_in_vector( vector, value )
  for i,v in pairs(vector) do
    if v == value then
      return true
    end
  end
  return false
end

-- Functions

function get_item_pos(item)
  local x, y, z = dfhack.items.getPosition(item)
  if x == nil or y == nil or z == nil then
    return nil
  end

  if not dfhack.maps.isValidTilePos(x,y,z) then
    dfhack.println("NOT VALID TILE")
    return nil
  end
  if not dfhack.maps.isTileVisible(x,y,z) then
    dfhack.println("NOT VISIBLE TILE")
    return nil
  end
  return {x=x, y=y, z=z}
end

function find_squad_position(unit)
  for i, squad in pairs( df.global.world.squads.all ) do
    for i, position in pairs( squad.positions ) do
      if position.occupant == unit.hist_figure_id then
        return position
      end
    end
  end
  return nil
end

-- This should be okay for dwarves, not sure if valid for others.
PART_TO_POSITION = {}
PART_TO_POSITION[ 0]="body"
PART_TO_POSITION[ 1]="pants"
PART_TO_POSITION[ 3]="head"
PART_TO_POSITION[ 8]="gloves" -- also shield and weapon
PART_TO_POSITION[ 9]="gloves" -- also shield and weapon
PART_TO_POSITION[14]="shoes"
PART_TO_POSITION[15]="shoes"
 
-- Convert the unit.inventory.body_part_id to a squad_position.uniform body position
function body_part_to_body_position(part)
  return PART_TO_POSITION[ part ]
end

-- Will figure out which items need to be moved to the floor, returns an item_id:item map
function process(unit, multi, silent)
  silent = silent or false
  local unit_name = dfhack.TranslateName( dfhack.units.getVisibleName(unit) )

  if not silent then 
    dfhack.println("Processing unit "..unit_name)
  end

  -- First get squad position for an early-out for non-military dwarves
  local squad_position = find_squad_position(unit)
  if squad_position == nil then
    if not silent then
      dfhack.println("Unit "..unit_name.." does not have a military uniform.")
    end
    return nil
  end

  -- Find all worn items which may be at issue.
  local worn_items = {} -- map of item ids to item objects
  local worn_parts = {} -- map of item ids to body part ids
  for k, inv_item in pairs(unit.inventory) do
   local item = inv_item.item
   if inv_item.mode == 2 or inv_item.mode == 1 or inv_item.mode == 4 then -- mode == 2 is worn, mode == 1 is weapon, mode == 4 is flask
     worn_items[ item.id ] = item
     worn_parts[ item.id ] = inv_item.body_part_id
   end
  end

--  dfhack.println("====== Worn items for "..unit_name)
--  debug_print(worn_items)
--  debug_print(worn_parts)


  -- Now get info about which items have been assigned as part of the uniform
  local assigned_items = {} -- assigned item ids mapped to their armor location

  for loc, specs in pairs( squad_position.uniform ) do -- indexed by armor location
    for i, spec in pairs(specs) do
      for i, assigned in pairs( spec.assigned ) do
        -- Include weapon and shield so we don't drop them later
      	assigned_items[ assigned ] = loc
      end
    end
  end

--  dfhack.println("====== Assigned items for "..unit_name)
--  debug_print(assigned_items)

  -- Figure out which assigned items are currently not being worn

  local present_ids = {} -- map of item ID to item object
  local missing_ids = {} -- map of item ID to armor location
  local missing_locs = {} -- map of armor locations to true/nil
  for u_id, loc in pairs(assigned_items) do
    if worn_items[ u_id ] == nil then
      dfhack.println("Unit "..unit_name.." is missing an assigned "..loc.." item")
      missing_ids[ u_id ] = loc
      missing_locs[ loc ] = true
    else
      present_ids[ u_id ] = worn_items[ u_id ]
    end
  end

--  dfhack.println("====== Missing items for "..unit_name)
--  debug_print(missing_ids)
--  debug_print(missing_locs)

  -- Figure out which worn items should be dropped

  -- First, figure out which body parts are covered by the uniform pieces we have.
  local covered = {} -- map of body part id to true/nil
  for id, item in pairs( present_ids ) do
    local loc = assigned_items[ id ]
    if loc ~= 'shield' and loc ~= "weapon" then -- shields and weapons don't "cover" the bodypart they're assigned to.
     covered[ worn_parts[ id ] ] = id
    end
  end 

  if multi then
    covered = {} -- Don't consider current covers - drop for anything which is missing
  end

--  dfhack.println("====== Uniform-covered body parts for  "..unit_name)
--  debug_print(covered)

  -- Figure out body parts which should be covered but aren'y
  local uncovered = {}
  for part, loc in pairs( PART_TO_POSITION ) do
    if not covered[ part ] then
      -- Only mark it "uncovered" if we're nominally supposed to have something there.
      if missing_locs[ loc ] then
        uncovered[ part ] = true
      end
    end
  end

--  dfhack.println("====== Uniform-uncovered body parts for  "..unit_name)
--  debug_print(uncovered)

  local to_drop = {} -- item id to item object

  -- Drop everything (except uniform pieces) from body parts which should be covered but aren't
  for w_id, item in pairs(worn_items) do
    if assigned_items[ w_id ] == nil then -- don't drop uniform pieces (including shields, weapons for hands)
      if uncovered[ worn_parts[ w_id ] ] then
        dfhack.println("Unit "..unit_name.." potentially has object #"..w_id.." '"..utils.getItemDescription(item).."' blocking their uniform "..PART_TO_POSITION[ worn_parts[ w_id ] ])
        to_drop[ w_id ] = item
      end
    end 
  end

  return to_drop
end


function do_drop( item_list )
  if item_list == nil then
    return nil
  end

  for id, item in pairs(item_list) do
    local pos = get_item_pos(item)
    if pos == nil then
      dfhack.println("Could not find drop location for item #"..id.."  "..utils.getItemDescription(item))
    else
      local retval = dfhack.items.moveToGround( item, pos )
      if retval == false then
        dfhack.println("Could not drop object #"..id.."  "..utils.getItemDescription(item))
      else
        dfhack.println("Dropped item #"..id.." '"..utils.getItemDescription(item).."'")
      end
    end
  end
end


-- Main

local args = utils.processArgs({...}, validArgs)

if args.help then
    print(help)
    return
end

if args.drop and df.global.ui.main.mode == df.ui_sidebar_mode.ViewUnits then
  dfhack.println("Error: Cannot actually drop items when view-unit sidebar is open.")
  return
end

if args.all then
  for k,unit in ipairs(df.global.world.units.active) do
    if dfhack.units.isCitizen(unit) then
      local to_drop = process(unit,args.multi,true)
      if args.drop then
        do_drop( to_drop ) 
      end
    end
  end  
else
  local unit=dfhack.gui.getSelectedUnit(true)
  if df.isvalid(unit) then
    local to_drop = process(unit,args.multi,false)
    if args.drop then
      do_drop( to_drop )
    end
  else
    dfhack.println("No unit is selected")
  end
end


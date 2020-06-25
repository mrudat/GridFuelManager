local PriorityQueue = require("priority-queue")
local memoize = require("__stdlib__/stdlib/vendor/memoize")

local VEHICLE_ENTITY_TYPES = {
  "car",
  "artillery-wagon",
  "cargo-wagon",
  "fluid-wagon",
  "locomotive"
}

local VEHICLE_ENTITY_NAMES

local VEHICLE_ENTITY_NAMES_MAP

-- aliases to global.<name>

local Vehicles -- with an equipment grid with a burner generator

local Trains -- with an equipment grid with a burner generator

local Players -- wearing armor with an equipment grid with a burner generator.

local Queue -- in ascending order of next_tick

--- functions start here

local function enqueue(data)
  Queue:put(data, data.next_tick)
end

local items_in_fuel_category
local function _items_in_fuel_category(fuel_category)
  local prototypes = game.get_filtered_item_prototypes{
    {
      filter = "fuel-category",
      ["fuel-category"] = fuel_category
    }
  }
  local item_data = {}
  for _, item_prototype in pairs(prototypes) do
    item_data[#item_data + 1] = {
      item_name = item_prototype.name,
      fuel_value = item_prototype.fuel_value,
      stack_fuel_value = item_prototype.fuel_value * item_prototype.stack_size,
      emissions_multiplier = item_prototype.fuel_emissions_multiplier
    }
  end
  table.sort(
    item_data,
    function(a,b)
      return a.stack_fuel_value > b.stack_fuel_value
    end
  )
  return item_data
end

local items_in_fuel_categories = function(_) end
local function _items_in_fuel_categories(fuel_categories)
  local merged
  for fuel_category in pairs(fuel_categories) do
    local data = items_in_fuel_category(fuel_category)
    -- merge sort on stack_fuel_value
    if merged then
      local temp = merged
      merged = {}
      local i = 1
      local j = 1

      while data[i] and temp[j] do
        if data[i].stack_fuel_value > temp[j].stack_fuel_value then
          merged[#merged + 1] = data[i]
          i = i + 1
        else
          merged[#merged + 1] = temp[j]
          j = j + 1
        end
      end

      while data[i] do
        merged[#merged + 1] = data[i]
        i = i + 1
      end

      while temp[j] do
        merged[#merged + 1] = temp[j]
        j = j + 1
      end
    else
      merged = data
    end
  end
  return merged
end

local function find_burner_generators(grid, complain)
  local generators = {}
  for _,equipment in ipairs(grid.equipment) do
    local burner = equipment.burner
    if not burner then goto next_equipment end

    local inventory = burner.inventory
    if not inventory.valid then
      -- shouldn't happen?
      complain({"GridGuelManager-message.generator-no-inventory", equipment.prototype.localised_name})
      goto next_equipment
    end

    local burnt_result_inventory = burner.burnt_result_inventory
    if not burnt_result_inventory.valid then
      burnt_result_inventory = nil
    end

    local power = equipment.generator_power
    if power == 0 then
      complain({"GridGuelManager-message.powerless-generator", equipment.prototype.localised_name})
      goto next_equipment
    end

    generators[#generators + 1] = {
      equipment = equipment,
      ipower = 1 / power,
      burner = burner,
      inventory = inventory,
      burnt_result_inventory = burnt_result_inventory,
      fuel_categories = burner.fuel_categories
    }
    ::next_equipment::
  end
  return generators
end

local function handle_train(data)
  local train_id = data.train_id

  local train_data = Trains[train_id]
  if not train_data then return end

  local train = train_data.train
  if not train.valid then
    Trains[train_id] = nil
    return
  end

  local generators = {}

  local failed

  for unit_number,_ in pairs(train_data.units) do
    local vehicle_data = Vehicles[unit_number]
    if not vehicle_data then
      failed = true
      goto next_vehicle
    end

    local vehicle = vehicle_data.vehicle
    if not vehicle.valid then
      Vehicles[unit_number] = nil
      failed = true
      goto next_vehicle
    end

    local grid = vehicle.grid
    if grid and not grid.valid then
      Vehicles[unit_number] = nil
      failed = true
      goto next_vehicle
    end
    local vehicle_generators = vehicle_data.generators
    if vehicle_generators then
      for i=#vehicle_generators,1,-1 do
        local generator=vehicle_generators[i]
        local remove = false
        if not generator.equipment.valid then
          remove = true
        end
        if not generator.burner.valid then
          remove = true
        end
        if not generator.inventory.valid then
          remove = true
        end
        if generator.burnt_result_inventory then
          if not generator.burnt_result_inventory.valid then
            remove = true
          end
        end
        if not remove then
          generators[#generators + 1] = generator
        else
          vehicle_generators[i] = vehicle_generators[#vehicle_generators]
          vehicle_generators[#vehicle_generators] = nil
        end
      end
    end

    ::next_vehicle::
  end

  if failed then
    -- TODO try and track down where the train is now?
    local force = train.force
    force.print({"description.broken-train", "[train=" .. train_id .. "]"},{r=1,a=1})
    log("No longer updating train " .. train_id .. " due to failure during update.")
    Trains[train_id] = nil
    return
  end

  local min_remaining_time = nil

  for _,generator in pairs(generators) do
    local inventory = generator.inventory

    inventory.sort_and_merge()

    -- try to fill inventory with more of what's already there
    local contents = inventory.get_contents()
    for name, _ in pairs(contents) do
      local available = train.get_item_count(name)
      if available > 0 then
        local moved = inventory.insert{name = name, count = available}
        if moved > 0 then
          train.remove_item{name = name, count = moved}
        end
      end
    end

    -- TODO cache this in generator? it boils down to a table lookup, so maybe not worth it?
    local fuel_items = items_in_fuel_categories(generator.fuel_categories)

    -- put the fuel that will burn the longest into inventory
    for _,fuel_item in ipairs(fuel_items) do
      local name = fuel_item.item_name
      local available = train.get_item_count(name)
      if available > 0 then
        local moved = inventory.insert{name = name, count = available}
        if moved > 0 then
          train.remove_item{name = name, count = moved}
        end
      end
    end

    local remaining_energy = 0

    -- count the remaining run time
    for _,fuel_item in ipairs(fuel_items) do
      local name = fuel_item.item_name

      local count = inventory.get_item_count(name)
      local energy = count * fuel_item.fuel_value
      remaining_energy = remaining_energy + energy
    end

    local remaining_time = remaining_energy * generator.ipower
    if not min_remaining_time then
      min_remaining_time = remaining_time
    else
      if remaining_time < min_remaining_time then
        min_remaining_time = remaining_time
      end
    end
  end

  -- evict the burnt result to the train inventory, so it can be taken away.
  for _,generator in pairs(generators) do
    local burnt_result_inventory = generator.burnt_result_inventory
    if burnt_result_inventory then
      local contents = burnt_result_inventory.get_contents()
      for name, count in pairs(contents) do
        local moved = train.insert{name = name, count = count}
        if moved > 0 then
          burnt_result_inventory.remove{name = name, count = moved}
        end
      end
    end
  end

  if min_remaining_time then
    -- return when we've burnt through 1/2 of the remaining time
    data.next_tick = game.tick + math.floor(min_remaining_time / 2) + 1

    enqueue(data)
  end
end

local function handle_vehicle(data)
  local unit_number = data.unit_number

  local vehicle_data = Vehicles[unit_number]
  if not vehicle_data then return end

  local vehicle = vehicle_data.vehicle
  if not vehicle.valid then
    Vehicles[unit_number] = nil
    return
  end

  local grid = vehicle_data.grid
  if not grid.valid then
    Vehicles[unit_number] = nil
    return
  end

  local vehicle_inventory = vehicle_data.inventory
  if not vehicle_inventory.valid then
    Vehicles[unit_number] = nil
    return
  end

  local vehicle_fuel_inventory = vehicle_data.fuel_inventory
  if vehicle_fuel_inventory then
    if not vehicle_fuel_inventory.valid then
      Vehicles[unit_number] = nil
      return
    end
  end

  local vehicle_burnt_result_inventory = vehicle_data.burnt_result_inventory
  if vehicle_burnt_result_inventory then
    if not vehicle_burnt_result_inventory.valid then
      Vehicles[unit_number] = nil
      return
    end
  end

  -- TODO should we be paranoid and check for new generators, or just watch the player and hope it's enough?

  local generators = vehicle_data.generators

  local min_remaining_time = nil

  for i=#generators,1,-1 do
    local generator=generators[i]
    local remove = false
    do
      if not generator.equipment.valid then
        remove = true
        goto next
      end
      if not generator.burner.valid then
        remove = true
        goto next
      end

      local inventory = generator.inventory
      if not inventory.valid then
        remove = true
        goto next
      end
      if generator.burnt_result_inventory then
        if not generator.burnt_result_inventory.valid then
          remove = true
          goto next
        end
      end

      -- sort the inventory to free up space
      inventory.sort_and_merge()

      -- try to fill inventory with more of what's already there
      local contents = inventory.get_contents()
      for name, _ in pairs(contents) do
        local available = vehicle_inventory.get_item_count(name)
        if available > 0 then
          local moved = inventory.insert{name = name, count = available}
          if moved > 0 then
            vehicle_inventory.remove{name = name, count = moved}
          end
        end
      end

      -- TODO cache this in generator? it boils down to a table lookup, so maybe not worth it?
      local fuel_items = items_in_fuel_categories(generator.fuel_categories)

      -- put the fuel that will burn the longest into inventory
      for _,fuel_item in ipairs(fuel_items) do
        local name = fuel_item.item_name
        local available = vehicle_inventory.get_item_count(name)
        if available > 0 then
          local moved = inventory.insert{name = name, count = available}
          if moved > 0 then
            vehicle_inventory.remove{name = name, count = moved}
          end
        end
      end

      -- pull fuel from the vehicle's fuel inventory if there's none available elsewhere
      for _,fuel_item in ipairs(fuel_items) do
        local name = fuel_item.item_name
        local available = vehicle_fuel_inventory.get_item_count(name)
        if available > 0 then
          local moved = inventory.insert{name = name, count = available}
          if moved > 0 then
            vehicle_fuel_inventory.remove{name = name, count = moved}
          end
        end
      end

      -- TODO should we attempt to count the remaining energy in the burner?
      local remaining_energy = 0
      --local remaining_energy = burner.remaining_burning_fuel -- ?

      -- count the remaining run time
      for _,fuel_item in ipairs(fuel_items) do
        local name = fuel_item.item_name

        local count = inventory.get_item_count(name)
        local energy = count * fuel_item.fuel_value
        remaining_energy = remaining_energy + energy
      end

      local remaining_time = remaining_energy / generator.ipower
      if not min_remaining_time then
        min_remaining_time = remaining_time
      else
        if remaining_time < min_remaining_time then
          min_remaining_time = remaining_time
        end
      end
    end
    ::next::
    if remove then
      generators[i] = generators[#generators]
      generators[#generators] = nil
    end
  end

  -- compact the inventory to try and free up some space.
  vehicle_inventory.sort_and_merge()

  -- evict the burnt result to the main inventory, so it can be taken away.
  for _,generator in ipairs(generators) do
    local burnt_result_inventory = generator.burnt_result_inventory
    if burnt_result_inventory then
      local contents = burnt_result_inventory.get_contents()
      for name, count in pairs(contents) do
        local moved = vehicle_inventory.insert{name = name, count = count}
        if moved > 0 then
          burnt_result_inventory.remove{name = name, count = moved}
        end
      end
    end
  end

  if vehicle_burnt_result_inventory then
    local contents = vehicle_burnt_result_inventory.get_contents()
    for name, count in pairs(contents) do
      local moved = vehicle_inventory.insert{name = name, count = count}
      if moved > 0 then
        vehicle_burnt_result_inventory.remove{name = name, count = moved}
      end
    end
  end

  -- if min_remaining_time is nil, there were no valid generators found
  if min_remaining_time then
    -- return when we've burnt through 1/2 of the remaining time
    data.next_tick = game.tick + math.floor(min_remaining_time / 2) + 1

    enqueue(data)
  end
end

local function handle_player(data)
  local player_index = data.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  local player = player_data.player
  if not player.valid then
    Players[player_index] = nil
    return
  end

  local grid = player_data.grid
  if not grid.valid then
    Players[player_index] = nil
    return
  end

  local generators = player_data.generators

  local min_remaining_time = nil

  for i=#generators,1,-1 do
    local generator=generators[i]
    local remove = false
    do
      if not generator.equipment.valid then
        remove = true
        goto next
      end
      if not generator.burner.valid then
        remove = true
        goto next
      end

      local inventory = generator.inventory
      if not inventory.valid then
        remove = true
        goto next
      end
      if generator.burnt_result_inventory then
        if not generator.burnt_result_inventory.valid then
          remove = true
          goto next
        end
      end

      -- sort the inventory to free up space
      inventory.sort_and_merge()

      -- try to fill inventory with more of what's already there
      local contents = inventory.get_contents()
      for name, _ in pairs(contents) do
        local available = player.get_item_count(name)
        if available > 0 then
          local moved = inventory.insert{name = name, count = available}
          if moved > 0 then
            player.remove_item{name = name, count = moved}
          end
        end
      end

      -- TODO cache this in generator? it boils down to a table lookup, so maybe not worth it?
      local fuel_items = items_in_fuel_categories(generator.fuel_categories)

      -- put the fuel that will burn the longest into inventory
      for _,fuel_item in ipairs(fuel_items) do
        local name = fuel_item.item_name
        local available = player.get_item_count(name)
        if available > 0 then
          local moved = inventory.insert{name = name, count = available}
          if moved > 0 then
            player.remove_item{name = name, count = moved}
          end
        end
      end

      -- TODO should we attempt to count the remaining energy in the burner?
      local remaining_energy = 0
      --local remaining_energy = burner.remaining_burning_fuel -- ?

      -- count the remaining run time
      for _,fuel_item in ipairs(fuel_items) do
        local name = fuel_item.item_name

        local count = inventory.get_item_count(name)
        local energy = count * fuel_item.fuel_value
        remaining_energy = remaining_energy + energy
      end

      local remaining_time = remaining_energy / generator.ipower
      if not min_remaining_time then
        min_remaining_time = remaining_time
      else
        if remaining_time < min_remaining_time then
          min_remaining_time = remaining_time
        end
      end
    end
    ::next::
    if remove then
      generators[i] = generators[#generators]
      generators[#generators] = nil
    end
  end

  -- evict the burnt result to the main inventory, so it can be taken away.
  for _,generator in pairs(generators) do
    local burnt_result_inventory = generator.burnt_result_inventory
    if burnt_result_inventory then
      local contents = burnt_result_inventory.get_contents()
      for name, count in pairs(contents) do
        local moved = player.insert{name = name, count = count}
        if moved > 0 then
          burnt_result_inventory.remove{name = name, count = moved}
        end
      end
    end
  end

  -- if min_remaining_time is nil, there were no valid generators found
  if min_remaining_time then
    -- return when we've burnt through 1/2 of the remaining time
    data.next_tick = game.tick + math.floor(min_remaining_time / 2) + 1

    enqueue(data)
  end
end

local function handle_thing(data)
  local type = data.type
  if type == "train" then
    handle_train(data)
  elseif type == "vehicle" then
    handle_vehicle(data)
  elseif type == "player" then
    handle_player(data)
  end
end

local function on_tick(event)
  local item = Queue:peek()
  if not item then return end

  local tick = event.tick
  if item.next_tick > tick then return end

  Queue:pop()

  handle_thing(item)
end

local function register_vehicle_with_equipment_grid(entity, grid)
  local unit_number = entity.unit_number

  local vehicle_type = entity.type

  local vehicle_data = {
    vehicle = entity,
    grid = grid
  }

  local generators = find_burner_generators(
    grid,
    function(message)
      local force = entity.force
      force.print(message)
    end
  )

  vehicle_data.generators = generators

  local train = entity.train
  local train_data
  local train_id
  if train then
    train_id = train.id
    vehicle_data.train_id = train_id
    train_data = Trains[train_id]
    if not train_data then
      train_data = {
        train = train,
        units = {}
      }
      Trains[train_id] = train_data
    end
    train_data.units[unit_number] = true
  end

  local queue_data

  if next(generators) then
    if train_id then
      queue_data = train_data.queue_data
      if not queue_data then
        queue_data = {
          type = "train",
          train_id = train_id,
          next_tick = 0,
        }
        train_data.queue_data = queue_data
        enqueue(queue_data)
      end
    else
      queue_data = {
        type = "vehicle",
        unit_number = unit_number,
        next_tick = 0,
      }
      vehicle_data.queue_data = queue_data
      enqueue(queue_data)
    end
  end

  if vehicle_type == "car" then
    vehicle_data.inventory = entity.get_inventory(defines.inventory.car_trunk)
    vehicle_data.fuel_inventory = entity.get_fuel_inventory()
    vehicle_data.burnt_result_inventory = entity.get_burnt_result_inventory()
  end

  Vehicles[unit_number] = vehicle_data
end

local function deregister_vehicle_with_equipment_grid(entity)
  local unit_number = entity.unit_number

  local vehicle_data = Vehicles[unit_number]
  if not vehicle_data then return end

  Vehicles[unit_number] = nil

  local train_id = vehicle_data.train_id
  local train_data

  if train_id then
    train_data = Trains[train_id]
    if not train_data then return end
    Trains[train_id] = nil
  end

  local queue_data

  if train_data then
    queue_data = train_data.queue_data
  else
    queue_data = vehicle_data.queue_data
  end

  -- can't efficiently delete from Queue, but if we set type to blank, it will do nothing when this reaches the head of the queue.
  if queue_data then
    queue_data.type = ''
  end
end

local function on_train_created(event)
  local train = event.train

  local train_id = train.id

  local train_data = Trains[train_id]

  if not train_data then
    train_data = {
      units = {}
    }
  end

  train_data.train = train

  local units = train_data.units

  local old_train_id_1 = event.old_train_id_1
  if old_train_id_1 then
    local old_train_data = Trains[old_train_id_1]
    if old_train_data then
      Trains[old_train_id_1] = nil
      local queue_data = old_train_data.queue_data
      if queue_data then
        old_train_data.queue_data = nil
        queue_data.type = ''
      end
    end
  end

  local old_train_id_2 = event.old_train_id_2
  if old_train_id_2 then
    local old_train_data = Trains[old_train_id_2]
    if old_train_data then
      Trains[old_train_id_2] = nil
      local queue_data = old_train_data.queue_data
      if queue_data then
        old_train_data.queue_data = nil
        queue_data.type = ''
      end
    end
  end

  Trains[train_id] = train_data

  local has_generators

  local carriages = train.carriages
  for _,carriage in ipairs(carriages) do
    local grid = carriage.grid
    if not grid then goto next_carriage end
    local unit_number = carriage.unit_number
    local vehicle_data = Vehicles[unit_number]
    if vehicle_data then
      units[unit_number] = true
      vehicle_data.train_id = train_id
      if next(vehicle_data.generators) then
        has_generators = true
      end
    else
      register_vehicle_with_equipment_grid(carriage, grid)
    end
    ::next_carriage::
  end

  if has_generators then
    local queue_data = train_data.queue_data
    if not queue_data then
      queue_data = {
        type = "train",
        train_id = train_id,
        next_tick = 0
      }
      train_data.queue_data = queue_data

      enqueue(queue_data)
    end
  end
end

local function on_entity_created(entity)
  local grid = entity.grid
  if not grid then return end
  register_vehicle_with_equipment_grid(entity, grid)
end

local function on_entity_destroyed(entity)
  local grid = entity.grid
  if not grid then return end
  deregister_vehicle_with_equipment_grid(entity, grid)
end

local function on_player_placed_equipment(event)
  local equipment = event.equipment

  local burner = equipment.burner
  if not burner then return end

  local player_index = event.player_index
  local grid = event.grid

  local player_data = Players[player_index]
  local player
  if player_data then
    player = player_data.player
  else
    player = game.players[player_index]
  end

  local generators

  local thing_data

  local queue_data = {
    next_tick = 0
  }

  local entity = player.opened
  if entity == grid then -- player.opened == grid for power armor, despite what the doco says
    if player_data.grid == grid then
      queue_data.type = 'player'
      queue_data.player_index = player_index
      thing_data = player_data
      generators = player_data.generators
    else
      player.print({"GridFuelManager-message.where-did-you-put-that", equipment.prototype.localised_name})
    end
  else
    if entity.grid == grid then
      if VEHICLE_ENTITY_NAMES_MAP[entity.name] then
        local unit_number = entity.unit_number
        local vehicle_data = Vehicles[unit_number]
        if not vehicle_data then
          register_vehicle_with_equipment_grid(entity, grid)
          vehicle_data = Vehicles[unit_number]
        end
        generators = vehicle_data.generators
        local train_id = vehicle_data.train_id
        if train_id then
          queue_data.type = 'train'
          queue_data.train_id = train_id
          thing_data = Trains[train_id]
        else
          queue_data.type = 'vehicle'
          queue_data.unit_number = unit_number
          thing_data = vehicle_data
        end
      end
    end
  end

  if ((generators == nil) or (not thing_data)) then
    player.print({"GridFuelManager-message.where-did-you-put-that", equipment.prototype.localised_name})
    -- TODO do an exhaustive search?
    return
  end

  local burnt_result_inventory = burner.burnt_result_inventory
  if not burnt_result_inventory.valid then
    burnt_result_inventory = nil
  end

  local power = equipment.generator_power
  if power == 0 then
    player.print({"GridFuelManager-message.powerless-generator"})
    return
  end

  generators[#generators + 1] = {
    equipment = equipment,
    ipower = 1 / power,
    burner = burner,
    inventory = burner.inventory,
    burnt_result_inventory = burnt_result_inventory,
    fuel_categories = burner.fuel_categories,
  }

  local old_queue_data = thing_data.queue_data
  if old_queue_data then
    if old_queue_data.next_tick == 0 then
      return
    end
    old_queue_data.type = ''
  end

  thing_data.queue_data = queue_data

  enqueue(queue_data)
end

local function on_player_armor_inventory_changed(event)
  local player_index = event.player_index

  local player_data = Players[player_index]

  local player
  if player_data then
    player = player_data.player
    player_data.grid = nil
    player_data.generators = nil
    local queue_data = player_data.queue_data
    if queue_data then
      queue_data.type = ''
      player_data.queue_data = nil
    end
  else
    player = game.players[player_index]
    player_data = {
      player = player
    }
  end

  local armor_inventory = player.get_inventory(defines.inventory.character_armor)
  if not armor_inventory then return end -- shouldn't happen?

  local armor_stack = armor_inventory[1]
  if not armor_stack then return end
  if not armor_stack.valid then return end
  if not armor_stack.valid_for_read then return end

  local grid = armor_stack.grid
  if not grid then return end

  player_data.grid = grid

  local generators = find_burner_generators(
    grid,
    function (message)
      player.print(message)
    end
  )
  player_data.generators = generators

  if next(generators) then
    local queue_data = {
      type = "player",
      player_index = player_index,
      next_tick = 0,
    }
    player_data.queue_data = queue_data
    enqueue(queue_data)
  end

  Players[player_index] = player_data
end

local function on_player_joined_game(event)
  local player_index = event.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  if not next(player_data.generators) then return end

  local queue_data = {
    type = "player",
    player_index = player_index,
    next_tick = 0
  }
  player_data.queue_data = queue_data

  enqueue(queue_data)
end

local function on_player_left_game(event)
  local player_index = event.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  if not next(player_data.generators) then return end

  local queue_data = player_data.queue_data
  if not queue_data then return end

  queue_data.type = ''

  player_data.queue_data = nil
end

local function on_player_died(event)
  local player_index = event.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  local queue_data = player_data.queue_data
  if queue_data then
    queue_data.type = ''
  end

  Players[player_index] = nil
end

local function on_player_removed(event)
  local player_index = event.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  local queue_data = player_data.queue_data
  if queue_data then
    queue_data.type = ''
  end

  Players[player_index] = nil
end

local function index_vehicle_prototypes_with_grids()
  local vehicles_filter = {}

  for i=1,#VEHICLE_ENTITY_TYPES do
    vehicles_filter[#vehicles_filter+1] = {
      filter = "type",
      type = VEHICLE_ENTITY_TYPES[i]
    }
  end

  local vehicle_names = {}
  local vehicle_names_map = {}

  for entity_prototype_name,entity_prototype in pairs(game.get_filtered_entity_prototypes(vehicles_filter)) do
    if entity_prototype.grid_prototype then
      vehicle_names[#vehicle_names + 1] = entity_prototype_name
      vehicle_names_map[entity_prototype_name] = true
    end
  end

  global.VEHICLE_ENTITY_NAMES = vehicle_names
  global.VEHICLE_ENTITY_NAMES_MAP = vehicle_names_map
end

local function find_vehicles()
  -- find all planes, trains and automobiles that have equipment grids.
  for _,surface in pairs(game.surfaces) do
    for _,vehicle in pairs(surface.find_entities_filtered{name=VEHICLE_ENTITY_NAMES}) do
      local grid = vehicle.grid
      if grid then
        register_vehicle_with_equipment_grid(vehicle, grid)
      end
    end
  end
end

local function maybe_register_player(player)
  local player_index = player.index
  local armor_inventory = player.get_inventory(defines.inventory.character_armor)
  if not armor_inventory then return end -- shouldn't happen?

  local armor_stack = armor_inventory[1]
  if not armor_stack then return end
  if not armor_stack.valid then return end
  if not armor_stack.valid_for_read then return end

  local grid = armor_stack.grid
  if not grid then return end

  local player_data = {
    player = player,
    grid = grid,
  }

  local generators = find_burner_generators(
    grid,
    function (message)
      player.print(message)
    end
  )
  player_data.generators = generators

  if next(generators) then
    local queue_data = {
      type = "player",
      player_index = player_index,
      next_tick = 0,
    }
    player_data.queue_data = queue_data
    enqueue(queue_data)
  end

  Players[player_index] = player_data
end

local function find_players()
  -- find all players wearing armor with a grid.
  for _,player in pairs(game.players) do
    maybe_register_player(player)
  end
end

local function on_load()
  Vehicles = global.Vehicles
  Trains   = global.Trains
  Players  = global.Players
  Queue    = PriorityQueue(global.Queue)

  items_in_fuel_category = memoize(_items_in_fuel_category, global._items_in_fuel_category)
  items_in_fuel_categories = memoize(_items_in_fuel_categories, global._items_in_fuel_categories)

  VEHICLE_ENTITY_NAMES = global.VEHICLE_ENTITY_NAMES
  VEHICLE_ENTITY_NAMES_MAP = global.VEHICLE_ENTITY_NAMES_MAP
end

local function on_init()
  global.Vehicles = {}
  global.Trains   = {}
  global.Players  = {}
  global.Queue    = {}

  global._items_in_fuel_category = nil
  global._items_in_fuel_categories = nil

  index_vehicle_prototypes_with_grids()

  on_load()

  find_vehicles()
  find_players()
end

local function on_configuration_changed(_)
  on_init()
end

-- register events

local vehicle_filter = {
  { filter="type", type = "rolling-stock" },
  { filter="type", type = "car" }
}

local function register_events(events, handler, filters)
  for _,event in ipairs(events) do
    script.on_event(event, handler, filters)
  end
end


register_events(
  {
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
  },
  function(event)
    on_entity_created(event.created_entity)
  end,
  vehicle_filter
)

local a_script_created_it = {
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
}

register_events(
  a_script_created_it,
  function(event)
    local entity = event.entity
    on_entity_created(entity)
  end,
  vehicle_filter
)

register_events(
  {
    defines.events.on_entity_died,
    defines.events.on_player_mined_entity,
    defines.events.on_robot_mined_entity,
  },
  function(event)
    on_entity_destroyed(event.entity)
  end,
  vehicle_filter
)

script.on_event(
  defines.events.script_raised_destroy,
  function(event)
    local entity = event.entity
    on_entity_destroyed(entity)
  end,
  vehicle_filter
)


script.on_event(defines.events.on_train_created, on_train_created)

script.on_event(defines.events.on_player_placed_equipment, on_player_placed_equipment)

script.on_event(defines.events.on_player_armor_inventory_changed, on_player_armor_inventory_changed)

script.on_event(defines.events.on_player_joined_game, on_player_joined_game)

script.on_event(defines.events.on_player_left_game, on_player_left_game)
script.on_event(defines.events.on_player_died, on_player_died)
script.on_event(defines.events.on_player_removed, on_player_removed)

script.on_event(defines.events.on_tick, on_tick)

script.on_init(
  on_init
)

script.on_configuration_changed(
  on_configuration_changed
)

script.on_load(
  on_load
)

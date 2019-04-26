PriorityQueue = require("priority-queue")
memoize = require("__stdlib__/stdlib/vendor/memoize")
Table = require("__stdlib__/stdlib/utils/table")

local VEHICLE_ENTITY_TYPES = {
  "car",
  "artillery-wagon",
  "cargo-wagon",
  "fluid-wagon",
  "locomotive"
}

local VEHICLE_ENTITY_TYPES_MAP = Table.array_to_dictionary(VEHICLE_ENTITY_TYPES)

--[[
local ROLLING_STOCK_ENTITY_TYPES = {
  "artillery-wagon",
  "cargo-wagon",
  "fluid-wagon",
  "locomotive"
}
]]

-- aliases to global.<name>

local Vehicles

local Trains

local Players

local Queue

--- functions start here

function build_fuel_category_to_items_map()
  local items_in_fuel_category = {}
  for _, item_prototype in pairs(game.item_prototypes) do
    local fuel_category = item_prototype.fuel_category
    if not fuel_category then goto next_item end
    if not items_in_fuel_category[fuel_category] then
      items_in_fuel_category[fuel_category] = {}
    end
    table.insert(
      items_in_fuel_category[fuel_category],
      {
        item_name = item_prototype.name,
        fuel_value = item_prototype.fuel_value,
        stack_fuel_value = item_prototype.fuel_value * item_prototype.stack_size,
        emissions_multiplier = item_prototype.fuel_emissions_multiplier
      }
    )
    ::next_item::
  end
  for fuel_category, data in pairs(items_in_fuel_category) do
    table.sort(
      data,
      function(a,b)
        return a.stack_fuel_value > b.stack_fuel_value
      end
    )
  end
  return items_in_fuel_category
end

function items_in_fuel_category(fuel_category)
  if not global._items_in_fuel_category then
    global._items_in_fuel_category = build_fuel_category_to_items_map()
  end
  return global._items_in_fuel_category[fuel_category]
end

items_in_fuel_categories = function(fuel_categories) end
function _items_in_fuel_categories(fuel_categories)
  local merged
  for fuel_category in pairs(fuel_categories) do
    local data = items_in_fuel_category(fuel_category)
    if merged then
      local temp = merged
      merged = {}
      local i = 1
      local j = 1

      while data[i] and data[j] do
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

function find_burner_generators(grid)
  local generators = {}
  for _,equipment in ipairs(grid.equipment) do
    local burner = equipment.burner
    if not burner then goto next_equipment end

    local inventory = burner.inventory
    if not inventory.valid then goto next_equipment end -- shouldn't happen?

    local burnt_result_inventory = burner.burnt_result_inventory
    if not burnt_result_inventory.valid then
      burnt_result_inventory = nil
    end

    local power = equipment.generator_power
    if power == 0 then goto next_equipment end

    table.insert(generators,{
      equipment = equipment,
      power = power,
      burner = burner,
      inventory = inventory,
      burnt_result_inventory = burnt_result_inventory,
      fuel_categories = burner.fuel_categories
    })
    ::next_equipment::
  end
  return generators
end

function handle_train(data)
  local train_id = data.train_id

  local train_data = Trains[train_id]
  if not train_data then return end

  local train = train_data.train
  if not train.valid then
    Trains[train_id] = nil
    return
  end

  local generators = {}

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
      iterate_and_filter(
        vehicle_generators,
        function(generator)
          if not generator.equipment.valid then return false end
          if not generator.burner.valid then return false end
          if not generator.inventory.valid then return false end
          if generator.burnt_result_inventory then
            if not generator.burnt_result_inventory.valid then return false end
          end
          return true
        end,
        function(generator)
          table.insert(generators,generator)
        end
      )
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
    local power = generator.power

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

    local remaining_time = remaining_energy / power
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
          count = count - moved
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

function handle_vehicle(data)
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

  iterate_and_filter(
    generators,
    function(generator)
      if not generator.equipment.valid then return false end
      if not generator.burner.valid then return false end
      if not generator.inventory.valid then return false end
      if generator.burnt_result_inventory then
        if not generator.burnt_result_inventory.valid then return false end
      end
      return true
    end,
    function(generator)
      local power = generator.power
      --local burner = generator.burner

      local inventory = generator.inventory

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

      local remaining_time = remaining_energy / power
      if not min_remaining_time then
        min_remaining_time = remaining_time
      else
        if remaining_time < min_remaining_time then
          min_remaining_time = remaining_time
        end
      end
    end
  )

  -- compact the inventory to try and free up some space.
  vehicle_inventory.sort_and_merge()

  -- evict the burnt result to the main inventory, so it can be taken away.
  for _,generator in pairs(generators) do
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

function handle_player(data)
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

  iterate_and_filter(
    generators,
    function(generator)
      if not generator.equipment.valid then return false end
      if not generator.burner.valid then return false end
      if not generator.inventory.valid then return false end
      if generator.burnt_result_inventory then
        if not generator.burnt_result_inventory.valid then return false end
      end
      return true
    end,
    function(generator)
      local power = generator.power
      --local burner = generator.burner

      local inventory = generator.inventory

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

      local remaining_time = remaining_energy / power
      if not min_remaining_time then
        min_remaining_time = remaining_time
      else
        if remaining_time < min_remaining_time then
          min_remaining_time = remaining_time
        end
      end
    end
  )

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

function handle_thing(data)
  local type = data.type
  if type == "train" then
    handle_train(data)
  elseif type == "vehicle" then
    handle_vehicle(data)
  elseif type == "player" then
    handle_player(data)
  end
end

function on_tick(event)
  local tick = event.tick
  local item = Queue:peek()
  -- TODO max work per tick?
  while item and item.next_tick <= tick do
    Queue:pop()

    handle_thing(item)

    item = Queue:peek()
  end

  schedule_queue_callback()
end

function enqueue(data)
  Queue:put(data, data.next_tick)
end

function schedule_queue_callback()
  script.on_nth_tick(nil)

  if Queue:empty() then
    return
  end

  local next_item = Queue:peek()
  local next_tick = next_item.next_tick
  local ticks_left = next_tick - game.tick
  if ticks_left > 0 then
    script.on_nth_tick(ticks_left, on_tick)
  else
    script.on_nth_tick(1, on_tick)
  end
end

function register_vehicle_with_equipment_grid(entity, grid)
  local unit_number = entity.unit_number

  local vehicle_type = entity.type

  local vehicle_data = {
    vehicle = entity,
    grid = grid
  }

  local generators = find_burner_generators(grid)

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
    schedule_queue_callback()
  end

  if vehicle_type == "car" then
    vehicle_data.inventory = entity.get_inventory(defines.inventory.car_trunk)
    vehicle_data.fuel_inventory = entity.get_fuel_inventory()
    vehicle_data.burnt_result_inventory = entity.get_burnt_result_inventory()
  end

  Vehicles[unit_number] = vehicle_data
end

function deregister_vehicle_with_equipment_grid(entity, grid)
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

function on_train_created(event)
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

      schedule_queue_callback()
    end
  end
end

function on_entity_created(entity)
  if not entity then return end
  if not VEHICLE_ENTITY_TYPES_MAP[entity.type] then return end
  local grid = entity.grid
  if not grid then return end
  register_vehicle_with_equipment_grid(entity, grid)
end

function on_entity_destroyed(entity)
  if not entity then return end
  if not VEHICLE_ENTITY_TYPES_MAP[entity.type] then return end
  local grid = entity.grid
  if not grid then return end
  deregister_vehicle_with_equipment_grid(entity, grid)
end

function iterate_and_filter(array, filter, func)
  local size = #array
  local index = size
  while index > 0 do
    local item = array[index]
    while not filter(item) do
      item = array[size]
      array[index] = item
      array[size] = nil
      size = size - 1
      if size == 0 then return end
    end
    if not item then return end
    func(item)
    index = index - 1
  end
end

function on_player_placed_equipment(event)
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
  local queue_type
  if entity == grid then -- player.opened == grid for power armor, despite what the doco says
    if player_data.grid == grid then
      queue_data.type = 'player'
      queue_data.player_index = player_index
      thing_data = player_data
      generators = player_data.generators
    else
      log("?!")
    end
  else
    if entity.grid == grid then
      if VEHICLE_ENTITY_TYPES_MAP[entity.type] then
        local unit_number = entity.unit_number
        local vehicle_data = Vehicles[unit_number]
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
    log("Unable to determine where equipment was placed.")
    -- TODO do an exhaustive search?
    return
  end

  local burnt_result_inventory = burner.burnt_result_inventory
  if not burnt_result_inventory.valid then
    burnt_result_inventory = nil
  end

  table.insert(generators,{
    equipment = equipment,
    power = equipment.generator_power,
    burner = burner,
    inventory = burner.inventory,
    burnt_result_inventory = burnt_result_inventory,
    fuel_categories = burner.fuel_categories,
  })

  local old_queue_data = thing_data.queue_data
  if old_queue_data then
    if old_queue_data.next_tick == 0 then
      return
    end
    old_queue_data.type = ''
  end

  thing_data.queue_data = queue_data

  enqueue(queue_data)
  schedule_queue_callback()
end

function on_player_armor_inventory_changed(event)
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

  local armor_inventory = player.get_inventory(defines.inventory.player_armor)
  if not armor_inventory then return end -- shouldn't happen?

  local armor_stack = armor_inventory[1]
  if not armor_stack then return end
  if not armor_stack.valid then return end
  if not armor_stack.valid_for_read then return end

  local grid = armor_stack.grid
  if not grid then return end

  player_data.grid = grid

  local generators = find_burner_generators(grid)
  player_data.generators = generators

  if next(generators) then
    queue_data = {
      type = "player",
      player_index = player_index,
      next_tick = 0,
    }
    player_data.queue_data = queue_data
    enqueue(queue_data)
    schedule_queue_callback()
  end

  Players[player_index] = player_data
end

function on_player_joined_game(event)
  local player_index = event.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  if not next(player_data.generators) then return end

  queue_data = {
    type = "player",
    player_index = player_index,
    next_tick = 0
  }
  player_data.queue_data = queue_data

  enqueue(queue_data)

  schedule_queue_callback()
end

function on_player_left_game(event)
  local player_index = event.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  if not next(player_data.generators) then return end

  local queue_data = player_data.queue_data
  if not queue_data then return end

  queue_data.type = ''

  player_data.queue_data = nil
end

function on_player_died(event)
  local player_index = event.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  local queue_data = player_data.queue_data
  if queue_data then
    queue_data.type = ''
  end

  Players[player_index] = nil
end

function on_player_removed(event)
  local player_index = event.player_index

  local player_data = Players[player_index]
  if not player_data then return end

  local queue_data = player_data.queue_data
  if queue_data then
    queue_data.type = ''
  end

  Players[player_index] = nil
end

function find_vehicles()
  -- find all planes, trains and automobiles
  for _,surface in pairs(game.surfaces) do
    for _,vehicle in pairs(surface.find_entities_filtered{type=VEHICLE_ENTITY_TYPES}) do
      local grid = vehicle.grid
      if grid then
        register_vehicle_with_equipment_grid(vehicle, grid)
      end
    end
  end
end

function maybe_register_player(player)
  local player_index = player.index
  local armor_inventory = player.get_inventory(defines.inventory.player_armor)
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

  local generators = find_burner_generators(grid)
  player_data.generators = generators

  if next(generators) then
    queue_data = {
      type = "player",
      player_index = player_index,
      next_tick = 0,
    }
    player_data.queue_data = queue_data
    enqueue(queue_data)
    schedule_queue_callback()
  end

  Players[player_index] = player_data
end

function find_players()
  -- find all players wearing armor with a grid.
  for _,player in pairs(game.players) do
    maybe_register_player(player)
  end
end

function on_init()
  global.Vehicles = {}
  global.Trains   = {}
  global.Players  = {}
  global.Queue    = {}

  global._items_in_fuel_category = nil
  global._items_in_fuel_categories = nil

  on_load()

  find_vehicles()
  find_players()
end

function on_configuration_changed(data)
  on_init()
end

function on_load()
  Vehicles = global.Vehicles
  Trains   = global.Trains
  Players  = global.Players
  Queue    = PriorityQueue(global.Queue)

  items_in_fuel_categories = memoize(_items_in_fuel_categories, global._items_in_fuel_categories)

  --schedule_queue_callback()
  script.on_nth_tick(1,on_tick)
end

-- register events

script.on_event(
  {
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
  },
  function(event)
    on_entity_created(event.created_entity)
  end
)
script.on_event(
  {
    defines.events.script_raised_built,
  },
  function(event)
    on_entity_created(event.entity)
  end
)

script.on_event(
  {
    defines.events.on_entity_died,
    defines.events.on_player_mined_entity,
    defines.events.on_robot_mined_entity,
    defines.events.script_raised_destroy,
  },
  function(event)
    on_entity_destroyed(event.entity)
  end
)

script.on_event(defines.events.on_train_created, on_train_created)

script.on_event(defines.events.on_player_placed_equipment, on_player_placed_equipment)

script.on_event(defines.events.on_player_armor_inventory_changed, on_player_armor_inventory_changed)

script.on_event(defines.events.on_player_joined_game, on_player_joined_game)

script.on_event(defines.events.on_player_left_game, on_player_left_game)
script.on_event(defines.events.on_player_died, on_player_died)
script.on_event(defines.events.on_player_removed, on_player_removed)

script.on_init(
  on_init
)

script.on_configuration_changed(
  on_configuration_changed
)

script.on_load(
  on_load
)

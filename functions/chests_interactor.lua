local Movement = require("functions.movement")
local interactive_patterns = require("enums.interactive_patterns")
local explorer = require("data.explorer")

local ChestsInteractor = {}

-- FSM States
local States = {
    IDLE = "IDLE",
    MOVING = "MOVING",
    INTERACTING = "INTERACTING",
    CHECKING_VFX = "CHECKING_VFX",
    RETURNING_TO_CHEST = "RETURNING_TO_CHEST",
    COLLECTING_ITEMS = "COLLECTING_ITEMS"
}

-- State variables
local currentState = States.IDLE
local targetObject = nil
local interactedObjects = {}
local expiration_time = 0
local permanent_blacklist = {}
local temporary_blacklist = {}
local temporary_blacklist_duration = 60 -- 1 minute in seconds
local max_attempts = 5
local max_return_attempts = 2
local vfx_check_start_time = 0
local vfx_check_duration = 4
local successful_chests_opened = 0
local state_start_time = 0
local max_state_duration = 30
local max_interaction_distance = 2
local return_to_chest_start_time = 0
local collecting_items_duration = 6
local last_known_chest_position = nil
local max_chest_search_attempts = 5
local chest_search_attempts = 0
local cinders_before_interaction = 0

-- New table to track attempts per chest
local chest_attempts = {}
local current_chest_key = nil

-- Helper functions
local function get_player_cinders()
    return get_helltide_coin_cinders()
end

function ChestsInteractor.update_cinders()
    local current_cinders = get_helltide_coin_cinders()
    -- Add logic to update cinders if needed
end

local function is_player_too_far_from_target()
    if not targetObject then return true end
    local player = get_local_player()
    if not player then return true end
    local player_pos = player:get_position()
    local target_pos = targetObject:get_position()
    return player_pos:dist_to(target_pos) > max_interaction_distance
end

local function has_enough_cinders(obj_name)
    local player_cinders = get_player_cinders()
    local required_cinders = interactive_patterns[obj_name]
    
    if type(required_cinders) == "table" then
        for _, cinders in ipairs(required_cinders) do
            if player_cinders >= cinders then
                return true
            end
        end
    elseif type(required_cinders) == "number" then
        if player_cinders >= required_cinders then
            return true
        end
    end
    
    return false
end

local function isObjectInteractable(obj, interactive_patterns)
    if not obj then return false end
    local obj_name = obj:get_skin_name()
    local is_interactable = obj:is_interactable()
    return interactive_patterns[obj_name] and 
           (not interactedObjects[obj_name] or os.clock() > interactedObjects[obj_name]) and
           has_enough_cinders(obj_name) and
           is_interactable
end

local function add_to_permanent_blacklist(obj)
    if not obj then return end
    local obj_name = obj:get_skin_name()
    local obj_pos = obj:get_position()
    table.insert(permanent_blacklist, {name = obj_name, position = obj_pos})
end

local function add_to_temporary_blacklist(obj)
    if not obj then return end
    local obj_name = obj:get_skin_name()
    local obj_pos = obj:get_position()
    local expiration_time = os.clock() + temporary_blacklist_duration
    table.insert(temporary_blacklist, {name = obj_name, position = obj_pos, expires_at = expiration_time})
end

local function is_blacklisted(obj)
    if not obj then return false end
    local obj_name = obj:get_skin_name()
    local obj_pos = obj:get_position()
    
    -- Check permanent blacklist
    for _, blacklisted_obj in ipairs(permanent_blacklist) do
        if blacklisted_obj.name == obj_name and blacklisted_obj.position:dist_to(obj_pos) < 0.1 then
            return true
        end
    end
    
    -- Check temporary blacklist
    local current_time = os.clock()
    for i, blacklisted_obj in ipairs(temporary_blacklist) do
        if blacklisted_obj.name == obj_name and blacklisted_obj.position:dist_to(obj_pos) < 0.1 then
            if current_time < blacklisted_obj.expires_at then
                return true
            else
                table.remove(temporary_blacklist, i)
                return false
            end
        end
    end
    
    return false
end

local function get_chest_key(obj)
    if not obj then return nil end
    local obj_name = obj:get_skin_name()
    local obj_pos = obj:get_position()
    return string.format("%s_%.2f_%.2f_%.2f", obj_name, obj_pos:x(), obj_pos:y(), obj_pos:z())
end

local function increment_chest_attempts()
    if current_chest_key then
        chest_attempts[current_chest_key] = (chest_attempts[current_chest_key] or 0) + 1
        return chest_attempts[current_chest_key]
    end
    return 0
end

local function get_chest_attempts()
    return current_chest_key and chest_attempts[current_chest_key] or 0
end

local function reset_chest_attempts()
    if current_chest_key then
        chest_attempts[current_chest_key] = nil
    end
end

local function check_chest_opened()
    local actors = actors_manager.get_all_actors()
    local current_cinders = get_helltide_coin_cinders()
    local cinders_spent = cinders_before_interaction - current_cinders
    local chest_actor_found = false
    
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == "Hell_Prop_Chest_Helltide_01_Client_Dyn" then
            chest_actor_found = true
            break
        end
    end
    
    if chest_actor_found or cinders_spent > 0 then
        console.print("Chest opened successfully")
        if chest_actor_found then
            console.print("Detected open chest actor")
        end
        if cinders_spent > 0 then
            console.print("Cinders spent: " .. cinders_spent)
        end
        successful_chests_opened = successful_chests_opened + 1
        console.print("Total chests opened successfully: " .. successful_chests_opened)
        return true
    end
    
    return false
end

local function resume_waypoint_movement()
    Movement.set_explorer_control(false)
    Movement.set_moving(true)
    --console.print("Retomando movimento normal")
end

local function reset_state()
    targetObject = nil
    -- Não resete current_chest_key aqui
    last_known_chest_position = nil
    chest_search_attempts = 0
    Movement.set_interacting(false)
    explorer.disable()
    Movement.set_explorer_control(false)
    Movement.enable_anti_stuck()
    state_start_time = os.clock()
    return_to_chest_start_time = 0
    resume_waypoint_movement()
    --console.print("Estado resetado, movimento retomado")
end

local function move_to_object(obj)
    if not obj then 
        if last_known_chest_position then
            explorer.set_target(last_known_chest_position)
            explorer.enable()
            Movement.set_explorer_control(true)
            Movement.disable_anti_stuck()
            chest_search_attempts = chest_search_attempts + 1
            console.print("Moving back to chest. Current attempt: " .. get_chest_attempts())
            return States.MOVING
        else
            reset_state()
            return States.IDLE
        end
    end
    local obj_pos = obj:get_position()
    last_known_chest_position = obj_pos
    explorer.set_target(obj_pos)
    explorer.enable()
    Movement.set_explorer_control(true)
    Movement.disable_anti_stuck()
    chest_search_attempts = 0
    console.print("Moving to chest. Current attempt: " .. get_chest_attempts())
    return States.MOVING
end

local stateFunctions = {
    [States.IDLE] = function(objects, interactive_patterns)
        reset_state()  -- Adicionado reset_state() aqui
        for _, obj in ipairs(objects) do
            if isObjectInteractable(obj, interactive_patterns) and not is_blacklisted(obj) then
                local new_chest_key = get_chest_key(obj)
                if new_chest_key ~= current_chest_key then
                    current_chest_key = new_chest_key
                    reset_chest_attempts()
                    console.print("New chest selected. Attempt counter reset.")
                end
                targetObject = obj
                return move_to_object(obj)
            end
        end
        return States.IDLE
    end,

    [States.MOVING] = function()
        if not targetObject then
            if chest_search_attempts >= max_chest_search_attempts then
                reset_state()
                return States.IDLE
            end
            if last_known_chest_position then
                if explorer.is_target_reached() then
                    chest_search_attempts = chest_search_attempts + 1
                    if chest_search_attempts >= max_chest_search_attempts then
                        reset_state()
                        return States.IDLE
                    else
                        return move_to_object(nil)
                    end
                end
            else
                reset_state()
                return States.IDLE
            end
        elseif not isObjectInteractable(targetObject, interactive_patterns) then 
            reset_state()
            return States.IDLE 
        end
        
        if is_player_too_far_from_target() then
            return move_to_object(targetObject)
        end
        
        if explorer.is_target_reached() then
            explorer.disable()
            Movement.set_explorer_control(false)
            if targetObject and targetObject:is_interactable() then
                return States.INTERACTING
            else
                increment_chest_attempts()
                local attempts = get_chest_attempts()
                console.print("Attempt " .. attempts .. " failed: object not interactive")
                if attempts >= max_attempts then
                    add_to_temporary_blacklist(targetObject)
                    reset_state()
                    return States.IDLE
                end
                return move_to_object(targetObject)
            end
        end
        
        return States.MOVING
    end,

    [States.INTERACTING] = function()
        if not targetObject or not targetObject:is_interactable() then 
            console.print("Target object not interactable. Moving back.")
            return move_to_object(targetObject)
        end

        if is_player_too_far_from_target() then
            console.print("Player too far from target. Moving back.")
            return move_to_object(targetObject)
        end

        local attempts = increment_chest_attempts()
        console.print("Attempt " .. attempts .. " to interact with the chest")
        cinders_before_interaction = get_helltide_coin_cinders()
        Movement.set_interacting(true)
        local obj_name = targetObject:get_skin_name()
        interactedObjects[obj_name] = os.clock() + expiration_time
        interact_object(targetObject)
        vfx_check_start_time = os.clock()
        return States.CHECKING_VFX
    end,

    [States.CHECKING_VFX] = function()
        if os.clock() - vfx_check_start_time > vfx_check_duration or is_player_too_far_from_target() then
            local current_cinders = get_helltide_coin_cinders()
            local cinders_spent = cinders_before_interaction - current_cinders
            
            if cinders_spent > 0 then
                console.print("Cinders spent, considering chest as opened on attempt " .. get_chest_attempts())
                successful_chests_opened = successful_chests_opened + 1
                add_to_permanent_blacklist(targetObject)
                reset_chest_attempts()
                return States.RETURNING_TO_CHEST
            end
            
            local attempts = get_chest_attempts()
            console.print("Attempt " .. attempts .. " failed")
            if attempts >= max_attempts then
                add_to_temporary_blacklist(targetObject)
                console.print("Chest added to temporary blacklist after " .. max_attempts .. " failed attempts")
                reset_state()
                return States.IDLE
            else
                Movement.set_interacting(false)
                return move_to_object(targetObject)
            end
        end

        if check_chest_opened() then
            console.print("Chest confirmed as opened on attempt " .. get_chest_attempts())
            add_to_permanent_blacklist(targetObject)
            reset_chest_attempts()
            return States.RETURNING_TO_CHEST
        end

        return States.CHECKING_VFX
    end,

    [States.RETURNING_TO_CHEST] = function()
        if not targetObject then
            reset_state()
            return States.IDLE
        end

        local player = get_local_player()
        if not player then return States.IDLE end

        local player_position = player:get_position()
        local chest_position = targetObject:get_position()
        
        if player_position:dist_to(chest_position) <= max_interaction_distance then
            console.print("Returned to chest, starting item collection")
            return_to_chest_start_time = os.clock()
            return States.COLLECTING_ITEMS
        end

        local attempts = increment_chest_attempts()
        console.print("Attempt " .. attempts .. " to return to chest")
        if attempts >= max_return_attempts then
            reset_state()
            return States.IDLE
        end

        explorer.set_target(chest_position)
        explorer.enable()
        Movement.set_explorer_control(true)
        return States.RETURNING_TO_CHEST
    end,

    [States.COLLECTING_ITEMS] = function()
        if os.clock() - return_to_chest_start_time >= collecting_items_duration then
            console.print("Item collection time completed")
            reset_state()
            return States.IDLE
        end

        return States.COLLECTING_ITEMS
    end
}

-- Main interaction function
function ChestsInteractor.interactWithObjects(doorsEnabled, interactive_patterns)
    local local_player = get_local_player()
    if not local_player then return end
    
    local objects = actors_manager.get_ally_actors()
    if not objects then return end
    
    if os.clock() - state_start_time > max_state_duration then
        console.print("Max state duration exceeded, resetting state")
        currentState = States.IDLE
        reset_state()
    end
    
    if targetObject and is_player_too_far_from_target() and currentState ~= States.IDLE then
        console.print("Player too far from target, resetting state")
        currentState = States.IDLE
        reset_state()
    end
    
    local newState = stateFunctions[currentState](objects, interactive_patterns)
    if newState ~= currentState then
        console.print("State changed from " .. currentState .. " to " .. newState)
        currentState = newState
        state_start_time = os.clock()
    end
    
    -- Verificamos se o estado atual é IDLE e se o Movement está no estado IDLE
    if currentState == States.IDLE and Movement.is_idle() then
        console.print("ChestsInteractor and Movement both in IDLE state, resuming movement")
        resume_waypoint_movement()
    end
end

-- Helper functions
function ChestsInteractor.clearInteractedObjects()
    interactedObjects = {}
end

function ChestsInteractor.clearTemporaryBlacklist()
    local current_time = os.clock()
    for i = #temporary_blacklist, 1, -1 do
        if current_time >= temporary_blacklist[i].expires_at then
            table.remove(temporary_blacklist, i)
        end
    end
end

function ChestsInteractor.printBlacklists()
    console.print("Permanent Blacklist:")
    for i, item in ipairs(permanent_blacklist) do
        local pos_string = string.format("(%.2f, %.2f, %.2f)", item.position:x(), item.position:y(), item.position:z())
        console.print(string.format("Item %d: %s at %s", i, item.name, pos_string))
    end
    
    console.print("\nTemporary Blacklist:")
    local current_time = os.clock()
    for i, item in ipairs(temporary_blacklist) do
        local pos_string = string.format("(%.2f, %.2f, %.2f)", item.position:x(), item.position:y(), item.position:z())
        local time_remaining = math.max(0, item.expires_at - current_time)
        console.print(string.format("Item %d: %s at %s, time remaining: %.2f seconds", i, item.name, pos_string, time_remaining))
    end
end

function ChestsInteractor.getSuccessfulChestsOpened()
    return successful_chests_opened
end

function ChestsInteractor.draw_chest_info()
    local chest_info_text = string.format("Total Helltide Chests Opened: %d", successful_chests_opened)
    graphics.text_2d(chest_info_text, vec2:new(10, 70), 20, color_white(255))
end

function ChestsInteractor.is_active()
    return currentState ~= States.IDLE
end

function ChestsInteractor.clearPermanentBlacklist()
    permanent_blacklist = {}
end

function ChestsInteractor.clearAllBlacklists()
    ChestsInteractor.clearTemporaryBlacklist()
    ChestsInteractor.clearPermanentBlacklist()
end

return ChestsInteractor
@tool
extends RefCounted
## Unreal names for Godot things, so the action menu finds a node when you type what it is called in Unreal
## (BeginPlay, Tick, GetActorLocation, SetTimerByEvent...). Keys identify an action:
##   event:<virtual>   get:<property>   set:<property>   call:<method>   util:<function>   tpl:<template>   k:<node kind>

const TABLE := {
	# --- events
	"event:_ready": ["Event BeginPlay", "Begin Play"],
	"event:_process": ["Event Tick", "Tick"],
	"event:_physics_process": ["Event Physics Tick", "Async Physics Tick"],
	"event:_exit_tree": ["Event EndPlay", "End Play", "Event Destroyed"],
	"event:_enter_tree": ["Event On Construction", "Post Initialize Components"],
	"event:_input": ["Event Any Key", "Input Event"],
	"event:_unhandled_input": ["Input Event", "Unhandled Input"],
	"k:custom_event": ["Add Custom Event"],
	"k:input_action": ["Input Action Event", "Enhanced Input Action"],
	"k:key_event": ["Keyboard Event", "Key Pressed"],

	# --- transform
	"get:global_position": ["Get Actor Location", "Get World Location", "K2 Get Actor Location"],
	"set:global_position": ["Set Actor Location", "Set World Location", "Teleport"],
	"get:position": ["Get Relative Location"],
	"set:position": ["Set Relative Location"],
	"get:global_rotation": ["Get Actor Rotation", "Get World Rotation"],
	"set:global_rotation": ["Set Actor Rotation", "Set World Rotation"],
	"get:rotation": ["Get Relative Rotation"],
	"set:rotation": ["Set Relative Rotation"],
	"get:global_rotation_degrees": ["Get Actor Rotation", "Get World Rotation"],
	"set:global_rotation_degrees": ["Set Actor Rotation", "Set World Rotation"],
	"get:scale": ["Get Actor Scale 3D", "Get Relative Scale 3D"],
	"set:scale": ["Set Actor Scale 3D", "Set Relative Scale 3D", "Set World Scale 3D"],
	"get:global_transform": ["Get Actor Transform", "Get World Transform"],
	"set:global_transform": ["Set Actor Transform", "Set World Transform"],
	"get:transform": ["Get Relative Transform"],
	"set:transform": ["Set Relative Transform"],
	"get:global_basis": ["Get Actor Forward Vector", "Get Actor Right Vector", "Get Actor Up Vector", "Get Forward Vector"],
	"get:basis": ["Get Forward Vector", "Get Right Vector", "Get Up Vector"],
	"call:translate": ["Add Actor Local Offset", "Add Local Offset"],
	"call:global_translate": ["Add Actor World Offset", "Add World Offset"],
	"call:rotate": ["Add Actor World Rotation", "Add World Rotation"],
	"call:rotate_x": ["Add Actor Local Rotation", "Add Local Rotation"],
	"call:rotate_y": ["Add Actor Local Rotation", "Add Local Rotation"],
	"call:rotate_z": ["Add Actor Local Rotation", "Add Local Rotation"],
	"call:rotate_object_local": ["Add Actor Local Rotation", "Add Local Rotation"],
	"call:look_at": ["Find Look at Rotation", "Set Actor Rotation Look At"],
	"call:to_local": ["Inverse Transform Location"],
	"call:to_global": ["Transform Location"],

	# --- actor lifetime and hierarchy
	"call:queue_free": ["Destroy Actor", "Destroy Component"],
	"tpl:destroy_node": ["Destroy Actor", "Destroy Component"],
	"k:spawn": ["Spawn Actor from Class", "Spawn Actor"],
	"k:new": ["Construct Object from Class", "Add Component by Class"],
	"call:add_child": ["Attach Actor To Actor", "Attach Component To Component", "Add Component"],
	"call:remove_child": ["Detach From Actor", "Detach From Component"],
	"call:reparent": ["Attach Actor To Component", "Attach To"],
	"call:get_parent": ["Get Owner", "Get Attach Parent", "Get Parent Actor"],
	"call:get_children": ["Get Children Components", "Get Attached Actors", "Get All Child Actors"],
	"call:get_child": ["Get Child Component"],
	"call:get_node": ["Get Component by Class"],
	"call:find_child": ["Get Component by Class", "Get Components by Tag"],
	"call:get_tree": ["Get World", "Get Game Mode"],
	"call:duplicate": ["Duplicate Object"],
	"call:is_queued_for_deletion": ["Is Actor Being Destroyed", "Is Pending Kill"],
	"k:get_node": ["Get Component by Class", "Component Reference"],
	"k:self": ["Self", "Get a Reference to Self"],
	"k:autoload": ["Get Game Instance", "Get Game Mode", "Get Game State", "Get Player Controller"],
	"k:cast": ["Cast To"],
	"k:is_valid": ["Is Valid"],
	"get:name": ["Get Object Name", "Get Display Name"],
	"get:visible": ["Is Visible", "Get Visible Flag"],
	"set:visible": ["Set Visibility", "Set Actor Hidden In Game", "Set Hidden In Game"],
	"call:show": ["Set Visibility", "Set Actor Hidden In Game"],
	"call:hide": ["Set Visibility", "Set Actor Hidden In Game"],
	"get:process_mode": ["Set Actor Tick Enabled"],
	"set:process_mode": ["Set Actor Tick Enabled", "Set Component Tick Enabled"],
	"call:set_process": ["Set Actor Tick Enabled", "Set Component Tick Enabled"],
	"call:set_physics_process": ["Set Actor Tick Enabled"],

	# --- groups (Unreal tags) and finding things
	"tpl:get_nodes_in_group": ["Get All Actors with Tag", "Get All Actors of Class"],
	"tpl:get_first_node_in_group": ["Get Actor of Class", "Get Player Character", "Get Player Pawn"],
	"tpl:add_to_group": ["Add Tag", "Tags"],
	"tpl:is_in_group": ["Actor Has Tag", "Component Has Tag"],

	# --- movement and physics
	"call:move_and_slide": ["Add Movement Input", "Move"],
	"call:move_and_collide": ["Set Actor Location Sweep", "Sweep"],
	"get:velocity": ["Get Velocity"],
	"set:velocity": ["Set Velocity", "Launch Character"],
	"call:is_on_floor": ["Is Falling", "Is Moving on Ground", "Is Walking"],
	"call:apply_impulse": ["Add Impulse", "Add Impulse at Location"],
	"call:apply_central_impulse": ["Add Impulse"],
	"call:apply_force": ["Add Force", "Add Force at Location"],
	"call:apply_central_force": ["Add Force"],
	"call:apply_torque": ["Add Torque in Radians", "Add Torque"],
	"get:linear_velocity": ["Get Physics Linear Velocity"],
	"set:linear_velocity": ["Set Physics Linear Velocity"],
	"get:angular_velocity": ["Get Physics Angular Velocity"],
	"set:angular_velocity": ["Set Physics Angular Velocity"],
	"call:get_overlapping_bodies": ["Get Overlapping Actors"],
	"call:get_overlapping_areas": ["Get Overlapping Components"],
	"call:intersect_ray": ["Line Trace by Channel", "Line Trace", "Raycast"],
	"call:is_colliding": ["Line Trace by Channel", "Hit Result"],
	"call:get_collider": ["Break Hit Result", "Hit Actor"],
	"call:get_collision_point": ["Break Hit Result", "Impact Point"],

	# --- game flow
	"tpl:open_scene": ["Open Level", "Open Level by Name"],
	"tpl:open_packed_scene": ["Open Level by Object Reference"],
	"tpl:reload_scene": ["Restart Level", "Restart Game"],
	"tpl:quit_game": ["Quit Game"],
	"tpl:set_paused": ["Set Game Paused"],
	"tpl:is_paused": ["Is Game Paused"],
	"tpl:delta_seconds": ["Get World Delta Seconds"],
	"tpl:game_time": ["Get Time Seconds", "Get Game Time in Seconds", "Get Real Time Seconds"],
	"tpl:set_timer": ["Set Timer by Event", "Set Timer by Function Name"],
	"tpl:clear_timer": ["Clear and Invalidate Timer by Handle", "Clear Timer by Function Name"],
	"tpl:tween_property": ["Move Component To", "Interp To", "V Interp To"],
	"tpl:load_async": ["Async Load Asset", "Async Load Class Asset"],
	"tpl:load_sync": ["Load Asset Blocking", "Load Object"],
	"tpl:is_server": ["Has Authority", "Switch Has Authority", "Is Server"],
	"tpl:call_message": ["Interface Message", "Call Interface Function"],
	"tpl:implements": ["Does Implement Interface"],
	"k:delay": ["Delay"],
	"k:emit": ["Call Event Dispatcher", "Broadcast"],
	"k:bind_signal": ["Bind Event to", "Add Dynamic"],
	"k:unbind_signal": ["Unbind Event from"],
	"k:print": ["Print String", "Print Text", "Log"],
	"k:format": ["Format Text", "Append"],
	"k:expr": ["Math Expression"],
	"k:select": ["Select", "Select Float", "Select Int"],
	"k:make_dict": ["Make Map"],
	"k:for_each_dict": ["For Each Loop Map"],

	# --- input
	"tpl:input_vector": ["Get Input Axis Value", "Move Forward", "Move Right", "Input Action Value"],
	"tpl:input_axis": ["Get Input Axis Value", "Input Axis"],
	"tpl:action_pressed": ["Is Input Key Down", "Was Input Key Just Pressed"],

	# --- animation
	"tpl:anim_travel": ["Play Montage", "Set Anim State", "Play Animation"],
	"tpl:anim_state": ["Get Current State Name"],
	"tpl:anim_set_param": ["Set Anim Instance Variable", "Set Blend Parameter"],
	"tpl:anim_get_param": ["Get Anim Instance Variable"],
	"call:play": ["Play Animation", "Play Sound 2D", "Play"],
	"call:stop": ["Stop Animation", "Stop"],

	# --- maths
	"util:lerp": ["Lerp", "Lerp Float"],
	"util:lerpf": ["Lerp", "Lerp Float", "F Interp To"],
	"util:move_toward": ["F Interp To Constant", "F Interp Constant To"],
	"util:clamp": ["Clamp"],
	"util:clampf": ["Clamp Float", "F Clamp"],
	"util:clampi": ["Clamp Integer"],
	"util:randf": ["Random Float", "Random Unit Float"],
	"util:randf_range": ["Random Float in Range"],
	"util:randi_range": ["Random Integer in Range"],
	"util:randi": ["Random Integer"],
	"util:absf": ["Abs Float", "Absolute"],
	"util:absi": ["Abs Integer", "Absolute"],
	"util:abs": ["Absolute", "Abs"],
	"util:floori": ["Floor"],
	"util:ceili": ["Ceil"],
	"util:roundi": ["Round"],
	"util:fmod": ["Modulo Float", "F Mod"],
	"util:pow": ["Power"],
	"util:sqrt": ["Square Root", "Sqrt"],
	"util:signf": ["Sign"],
	"util:remap": ["Map Range Clamped", "Map Range Unclamped"],
	"util:inverse_lerp": ["Normalize to Range", "Inverse Lerp"],
	"util:smoothstep": ["Smooth Step", "Ease"],
	"util:deg_to_rad": ["Degrees to Radians", "D2R"],
	"util:rad_to_deg": ["Radians to Degrees", "R2D"],
	"util:is_equal_approx": ["Nearly Equal Float", "Nearly Equal"],
	"util:is_zero_approx": ["Nearly Zero"],
	"util:str": ["To String", "Conv To String", "To Text", "Build String"],
	"util:is_instance_valid": ["Is Valid"],
	"call:length": ["Vector Length", "V Size", "Length"],
	"call:length_squared": ["Vector Length Squared", "V Size Squared"],
	"call:normalized": ["Normalize", "Get Unit Direction Vector", "Normal"],
	"call:distance_to": ["Get Distance To", "Distance Vector", "Get Horizontal Distance To"],
	"call:direction_to": ["Get Unit Direction Vector", "Get Direction Unit Vector"],
	"call:dot": ["Dot Product"],
	"call:cross": ["Cross Product"],
	"call:slerp": ["R Interp To", "R Lerp", "Slerp"],
	"call:move_toward": ["V Interp To Constant", "V Interp To"],
	"call:rotated": ["Rotate Vector", "Rotate Vector Around Axis"],
	"call:angle_to": ["Angle Between Vectors"],

	# --- arrays and strings (Godot method -> Unreal node)
	"call:append": ["Add", "Array Add"],
	"call:push_back": ["Add", "Array Add"],
	"call:append_array": ["Append Array"],
	"call:size": ["Length", "Array Length", "Num"],
	"call:has": ["Contains", "Array Contains", "Map Contains"],
	"call:find": ["Find Item", "Array Find", "Find Substring"],
	"call:erase": ["Remove Item", "Array Remove", "Map Remove"],
	"call:remove_at": ["Remove Index"],
	"call:clear": ["Clear", "Array Clear"],
	"call:is_empty": ["Is Empty", "Is Not Empty", "Array Is Empty"],
	"call:shuffle": ["Shuffle"],
	"call:pick_random": ["Random Array Item", "Get Random"],
	"call:back": ["Last Index", "Last"],
	"call:front": ["First"],
	"call:insert": ["Insert", "Array Insert"],
	"call:resize": ["Resize", "Array Resize"],
	"call:reverse": ["Reverse", "Array Reverse"],
	"call:keys": ["Map Keys", "Keys"],
	"call:values": ["Map Values", "Values"],
	"call:contains": ["Contains", "String Contains"],
	"call:to_upper": ["To Upper"],
	"call:to_lower": ["To Lower"],
	"call:split": ["Parse Into Array", "Split"],
	"call:substr": ["Get Substring", "Mid"],
	"call:replace": ["Replace"],
	"call:to_int": ["String to Int", "Conv String to Int"],
	"call:to_float": ["String to Float", "Conv String to Float"],
	"call:begins_with": ["Starts With"],
	"call:ends_with": ["Ends With"],
	"call:strip_edges": ["Trim", "Trim Trailing"],
}


static func key_for(kind: String, p: Dictionary) -> String:
	match kind:
		"event":
			return "event:" + String(p.get("name", ""))
		"get_prop":
			return "get:" + String(p.get("prop", ""))
		"set_prop":
			return "set:" + String(p.get("prop", ""))
		"call", "bcall":
			return "call:" + String(p.get("method", ""))
		"util":
			return "util:" + String(p.get("name", ""))
		"tpl":
			return "tpl:" + String(p.get("id", ""))
	return "k:" + kind


## Unreal display names for an action, or an empty array.
static func names_for(kind: String, p: Dictionary) -> Array:
	return TABLE.get(key_for(kind, p), [])


## Text to add to an action's search string: each name with its spaces and run together ("get actor location getactorlocation").
static func search_text(names: Array) -> String:
	var out := PackedStringArray()
	for n in names:
		var low := String(n).to_lower()
		out.append(low)
		out.append(low.replace(" ", ""))
	return " ".join(out)

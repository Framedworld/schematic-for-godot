extends RefCounted
## Wait for startup/reimport and its deferred filesystem notifications before changing fixtures or quitting.
static func idle(tree: SceneTree) -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	var idle_frames := 0
	while idle_frames < 2:
		await tree.process_frame
		idle_frames = 0 if filesystem.is_scanning() else idle_frames + 1


static func rescan(tree: SceneTree) -> void:
	await idle(tree)
	EditorInterface.get_resource_filesystem().scan()
	await idle(tree)

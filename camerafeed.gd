extends Control

const CAMERA_DEACTIVATION_DELAY := 0.1
const DISPLAY_PADDING := 40.0

enum ShaderMode { RGB = 0, YCBCR_SEP = 1, YCBCR = 2 }

@onready var camera_display := $CameraDisplay
@onready var mirror_container := $CameraDisplay/MirrorContainer
@onready var rotation_container := $CameraDisplay/MirrorContainer/RotationContainer
@onready var aspect_container := $CameraDisplay/MirrorContainer/RotationContainer/AspectContainer
@onready var camera_preview := $CameraDisplay/MirrorContainer/RotationContainer/AspectContainer/CameraPreview
@onready var camera_list := $DrawerContainer/Drawer/DrawerContent/VBoxContainer/CameraList
@onready var format_list := $DrawerContainer/Drawer/DrawerContent/VBoxContainer/FormatList
@onready var start_or_stop_button := $DrawerContainer/Drawer/DrawerContent/VBoxContainer/ButtonContainer/StartOrStopButton
@onready var reload_button := $DrawerContainer/Drawer/DrawerContent/VBoxContainer/ButtonContainer/ReloadButton

var camera_feed: CameraFeed
var _initialized: bool = false
var _cached_formats: Array = []
var _last_feed_transform: Transform2D
var _texture_initialized: bool = false

const defaultWebResolution: Dictionary = {
	"width": 640,
	"height": 480,
}

func _ready() -> void:
	_validate_platform()
	_adjust_ui()
	# Initialize camera
	_reload_camera_list()
	_initialized = true

func _validate_platform() -> void:
	var os_name := OS.get_name()
	if os_name in ["Windows", "Web"]:
		push_warning("%s implementation is work in progress" % os_name)
		if os_name == "Windows":
			push_warning("see https://github.com/godotengine/godot/pull/108538")
		else:
			push_warning("see https://github.com/godotengine/godot/pull/106784")
	if os_name in ["macOS", "iOS"]:
		push_warning("%s rendering is currently broken due to a bug" % os_name)
		push_warning("see https://github.com/godotengine/godot/pull/106777")

func _adjust_ui() -> void:
	# Rotation and mirroring are handled by MirrorContainer and RotationContainer
	camera_display.size = camera_display.get_parent_area_size() - Vector2.ONE * DISPLAY_PADDING

	# Set pivot_offset for rotation and mirror containers BEFORE any transformations
	# These need to be set dynamically as their size changes with the parent
	# Store current transformations
	var saved_mirror_scale: Vector2 = mirror_container.scale if mirror_container else Vector2.ONE
	var saved_rotation: float = rotation_container.rotation if rotation_container else 0.0

	if mirror_container:
		# Reset transformation, set pivot, then restore
		mirror_container.scale = Vector2.ONE
		mirror_container.pivot_offset = mirror_container.size / 2
		mirror_container.scale = saved_mirror_scale

	if rotation_container:
		# Reset transformation, set pivot, then restore
		rotation_container.rotation = 0.0
		rotation_container.pivot_offset = rotation_container.size / 2
		rotation_container.rotation = saved_rotation

	# Reconnect resized signal for next resize event
	# Disconnect first to avoid duplicate connections, then connect with ONE_SHOT
	if camera_display.resized.is_connected(_adjust_ui):
		camera_display.resized.disconnect(_adjust_ui)
	camera_display.resized.connect(_adjust_ui, ConnectFlags.CONNECT_ONE_SHOT)

func _reload_camera_list() -> void:
	camera_list.clear()
	format_list.clear()

	var os_name := OS.get_name()

	# Request camera permission on mobile.
	if os_name in ["Android"]:
		var permissions := OS.get_granted_permissions()
		if not "CAMERA" in permissions:
			if not OS.request_permission("CAMERA"):
				print("CAMERA permission not granted")
				return

	# Stop monitoring if already active
	if CameraServer.is_monitoring_feeds:
		CameraServer.monitoring_feeds = false
		await get_tree().process_frame

	# Reconnect signal before starting monitoring
	# This ensures the signal is ready when monitoring starts
	if CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.disconnect(_on_camera_feeds_updated)
	CameraServer.camera_feeds_updated.connect(_on_camera_feeds_updated)

	# Start monitoring - this will trigger camera_feeds_updated signal
	CameraServer.monitoring_feeds = true


func _on_camera_feeds_updated() -> void:
	# Defer processing to next frame to ensure monitoring is fully active
	call_deferred("_process_camera_feeds")


func _process_camera_feeds() -> void:
	# Get available camera feeds.
	var feeds = CameraServer.feeds()

	if feeds.is_empty():
		camera_list.add_item("No cameras found")
		camera_list.disabled = true
		format_list.add_item("No formats available")
		format_list.disabled = true
		start_or_stop_button.disabled = true
		return

	camera_list.disabled = false
	for i in range(feeds.size()):
		var feed: CameraFeed = feeds[i]
		camera_list.add_item(feed.get_name())

	# Auto-select first camera.
	_on_camera_list_item_selected(camera_list.selected)


func _on_camera_list_item_selected(index: int) -> void:
	var camera_feeds := CameraServer.feeds()
	if index < 0 or index >= camera_feeds.size():
		return

	# Stop previous camera if active and wait for deactivation to complete
	if camera_feed and camera_feed.feed_is_active:
		camera_feed.feed_is_active = false
		# Wait for camera hardware to fully deactivate
		# Note: active flag becomes false immediately, but hardware cleanup takes time
		await get_tree().create_timer(CAMERA_DEACTIVATION_DELAY).timeout

	# Switch to selected camera feed
	camera_feed = camera_feeds[index]
	_cached_formats = []

	# Update format list and auto-select format 0
	# This will trigger preview start via _on_format_list_item_selected()
	await _update_format_list()


func _update_format_list() -> void:
	format_list.clear()

	if not camera_feed:
		return

	_cached_formats = camera_feed.get_formats()
	if _cached_formats.is_empty():
		var os_name := OS.get_name()
		if os_name in ["macOS", "iOS"]:
			push_warning("%s is not supported CameraFeed formats" % os_name)
			push_warning("see https://github.com/godotengine/godot/pull/106777")

		format_list.add_item("No formats available")
		format_list.disabled = true
		start_or_stop_button.disabled = true
		return

	format_list.disabled = false
	start_or_stop_button.disabled = false
	for format in _cached_formats:
		# Safely access dictionary keys to prevent errors
		var width: int = format.get("width", 0)
		var height: int = format.get("height", 0)
		var format_name: String = format.get("format", "Unknown")

		var resolution := str(width) + "x" + str(height)
		var item := "%s - %s" % [format_name, resolution]

		if format.has("frame_denominator") and format.has("frame_numerator"):
			item += " : %s / %s" % [format["frame_numerator"], format["frame_denominator"]]
		elif format.has("framerate_denominator") and format.has("framerate_numerator"):
			item += " : %s / %s" % [format["framerate_numerator"], format["framerate_denominator"]]
		format_list.add_item(item)

	# Auto-select first format and wait for activation to complete
	format_list.selected = 0
	await _on_format_list_item_selected(0)


func _on_format_list_item_selected(index: int) -> void:
	if not camera_feed:
		return

	var os_name := OS.get_name()

	# Validate format index (skip for macOS/iOS due to format limitations)
	if not os_name in ["macOS", "iOS"]:
		if index < 0 or index >= _cached_formats.size():
			return

	# Deactivate current feed if active and wait for completion
	# This ensures clean state before format change
	if camera_feed.feed_is_active:
		camera_feed.feed_is_active = false
		# Wait for camera hardware to fully deactivate
		# Note: active flag becomes false immediately, but hardware cleanup takes time
		await get_tree().create_timer(CAMERA_DEACTIVATION_DELAY).timeout

	# Set new format with platform-specific parameters
	var parameters: Dictionary = defaultWebResolution if os_name == "Web" else {}
	camera_feed.set_format(index, parameters)

	# Wait before starting to ensure format is set
	await get_tree().process_frame

	# Start preview with new format
	_start_camera_feed()


func _start_camera_feed() -> void:
	if not camera_feed:
		return

	# Reset texture initialization flag for new feed
	_texture_initialized = false
	_last_feed_transform = Transform2D()

	# Connect frame_changed signal if not already connected
	# This will be called every frame, allowing us to respond to feed_transform updates
	if not camera_feed.frame_changed.is_connected(_on_frame_changed):
		camera_feed.frame_changed.connect(_on_frame_changed)

	# Activate the feed (will trigger frame_changed signal on first frame)
	camera_feed.feed_is_active = true


func _update_scene_transform() -> void:
	if not camera_feed or not camera_feed.feed_is_active:
		return

	# Safety check: ensure formats are available (use cached formats)
	if _cached_formats.is_empty():
		return

	var mat: ShaderMaterial = camera_preview.material
	if not mat:
		return

	# Get texture size to calculate aspect ratio
	var preview_size := Vector2.ZERO
	var datatype := camera_feed.get_datatype() as CameraFeed.FeedDataType
	match datatype:
		CameraFeed.FeedDataType.FEED_RGB:
			var rgb_texture: CameraTexture = mat.get_shader_parameter("rgb_texture")
			if rgb_texture:
				preview_size = rgb_texture.get_size()
		CameraFeed.FeedDataType.FEED_YCBCR_SEP:
			var y_texture: CameraTexture = mat.get_shader_parameter("y_texture")
			if y_texture:
				preview_size = y_texture.get_size()
		CameraFeed.FeedDataType.FEED_YCBCR:
			var ycbcr_texture: CameraTexture = mat.get_shader_parameter("ycbcr_texture")
			if ycbcr_texture:
				preview_size = ycbcr_texture.get_size()

	if preview_size.round() <= Vector2.ZERO:
		return

	# Extract rotation and mirroring from feed_transform
	# camera_android.cpp provides correctly ordered transform (scale then rotate)
	var feed_transform := camera_feed.feed_transform
	var rotation_angle := feed_transform.get_rotation()

	# Determine device orientation from display size
	# Camera sensor rotation angle doesn't reliably indicate device orientation
	var display_size := DisplayServer.window_get_size()
	var is_display_landscape := display_size.x > display_size.y

	# Detect front camera directly from camera position
	var is_front_camera := camera_feed.get_position() == CameraFeed.FeedPosition.FEED_FRONT

	# Adjust rotation and mirroring based on device orientation
	# camera_android.cpp calculates: rotationAngle = sensorOrientation - displayRotation
	# - Portrait: sensorOrientation(90°) - displayRotation(0°) = 90°
	# - Landscape: sensorOrientation(90°) - displayRotation(90°) = 0°

	var adjusted_rotation := rotation_angle
	var mirror_scale := Vector2(-1.0 if is_front_camera else 1.0, 1.0)

	# Apply transformations
	# pivot_offset is already set by _adjust_ui()
	# Order: MirrorContainer (scale) -> RotationContainer (rotation) -> CameraPreview
	mirror_container.scale = mirror_scale
	rotation_container.rotation = adjusted_rotation

	# Adjust aspect ratio based on device orientation
	# Camera sensor is landscape (wider than tall), but display orientation varies
	if is_display_landscape:
		# Device in landscape - keep horizontal aspect ratio
		aspect_container.ratio = preview_size.x / preview_size.y
	else:
		# Device in portrait - swap to vertical aspect ratio
		aspect_container.ratio = preview_size.y / preview_size.x

func _on_frame_changed() -> void:
	"""Called when camera frame is updated. Sets up textures on first frame and updates transform."""
	if not camera_feed or not camera_feed.feed_is_active:
		return

	# Safety check: ensure formats are available (use cached formats)
	# This can be empty during camera reinitialization (e.g., during screen rotation)
	if _cached_formats.is_empty():
		print("Warning: camera formats empty, skipping frame update")
		return

	# On first frame, set up textures
	if not _texture_initialized:
		var datatype := camera_feed.get_datatype() as CameraFeed.FeedDataType
		var preview_size := Vector2.ZERO

		var mat: ShaderMaterial = camera_preview.material
		var rgb_texture: CameraTexture = mat.get_shader_parameter("rgb_texture")
		var y_texture: CameraTexture = mat.get_shader_parameter("y_texture")
		var cbcr_texture: CameraTexture = mat.get_shader_parameter("cbcr_texture")
		var ycbcr_texture: CameraTexture = mat.get_shader_parameter("ycbcr_texture")

		# Configure texture feed types
		rgb_texture.which_feed = CameraServer.FeedImage.FEED_RGBA_IMAGE
		y_texture.which_feed = CameraServer.FeedImage.FEED_Y_IMAGE
		cbcr_texture.which_feed = CameraServer.FeedImage.FEED_CBCR_IMAGE
		ycbcr_texture.which_feed = CameraServer.FEED_YCBCR_IMAGE

		# Set up textures based on data type
		match datatype:
			CameraFeed.FeedDataType.FEED_RGB:
				rgb_texture.camera_feed_id = camera_feed.get_id()
				mat.set_shader_parameter("rgb_texture", rgb_texture)
				mat.set_shader_parameter("mode", ShaderMode.RGB)
				preview_size = rgb_texture.get_size()
			CameraFeed.FeedDataType.FEED_YCBCR_SEP:
				y_texture.camera_feed_id = camera_feed.get_id()
				cbcr_texture.camera_feed_id = camera_feed.get_id()
				mat.set_shader_parameter("y_texture", y_texture)
				mat.set_shader_parameter("cbcr_texture", cbcr_texture)
				mat.set_shader_parameter("mode", ShaderMode.YCBCR_SEP)
				preview_size = y_texture.get_size()
			CameraFeed.FeedDataType.FEED_YCBCR:
				ycbcr_texture.camera_feed_id = camera_feed.get_id()
				mat.set_shader_parameter("ycbcr_texture", ycbcr_texture)
				mat.set_shader_parameter("mode", ShaderMode.YCBCR)
				preview_size = ycbcr_texture.get_size()
			_:
				print("Skip formats that are not supported.")
				return

		if preview_size.round() <= Vector2.ZERO:
			return

		# Create placeholder texture with correct size
		var white_image := Image.create(int(preview_size.x), int(preview_size.y), false, Image.FORMAT_RGBA8)
		white_image.fill(Color.WHITE)
		camera_preview.texture = ImageTexture.create_from_image(white_image)

		# Mark texture as initialized
		_texture_initialized = true

		# Update UI state
		start_or_stop_button.text = "Stop"

	# Update scene transform only when feed_transform changes
	var current_transform := camera_feed.feed_transform
	if current_transform != _last_feed_transform:
		_last_feed_transform = current_transform
		_update_scene_transform()


func _on_start_or_stop_button_pressed(change_label: bool = true) -> void:
	if camera_feed and camera_feed.feed_is_active:
		camera_feed.feed_is_active = false
		await get_tree().process_frame
		camera_preview.texture = null
		camera_preview.rotation = 0
		_texture_initialized = false
		if change_label:
			start_or_stop_button.text = "Start"
	else:
		_start_camera_feed()
		if change_label:
			start_or_stop_button.text = "Stop"


func _on_reload_button_pressed() -> void:
	_on_start_or_stop_button_pressed(false)
	_reload_camera_list()


func _notification(what: int) -> void:
	if not _initialized:
		return

	match what:
		NOTIFICATION_RESIZED:
			_adjust_ui()
		NOTIFICATION_WM_SIZE_CHANGED:
			# Screen orientation changed (e.g., device rotation on mobile)
			# Adjust UI to update sizes and pivot_offset
			# Transform update will happen automatically on next frame_changed signal
			_adjust_ui()


func _exit_tree() -> void:
	if camera_feed and camera_feed.feed_is_active:
		camera_feed.feed_is_active = false

extends Control

@onready var camera_display = $CameraDisplay
@onready var camera_preview := $CameraDisplay/CameraPreview
@onready var drawer_container := $DrawerContainer
@onready var camera_list := $DrawerContainer/Drawer/DrawerContent/VBoxContainer/CameraList
@onready var format_list := $DrawerContainer/Drawer/DrawerContent/VBoxContainer/FormatList
@onready var start_or_stop_button := $DrawerContainer/Drawer/DrawerContent/VBoxContainer/ButtonContainer/StartOrStopButton
@onready var reload_button := $DrawerContainer/Drawer/DrawerContent/VBoxContainer/ButtonContainer/ReloadButton

var camera_feed: CameraFeed
var drawer_open: bool = true
var drawer_animating: bool = false
var camera_active: bool = false

const defaultWebResolution: Dictionary = {
	"width": 640,
	"height": 480
}

func _ready():
	var os_name := OS.get_name()
	if os_name in ["Windows", "Web"]:
		push_warning("%s implementation is work in progress" % os_name)
		if os_name == "Windows":
			push_warning("see https://github.com/godotengine/godot/pull/105476")
		else:
			push_warning("see https://github.com/godotengine/godot/pull/106784")
	if os_name in ["macOS", "iOS"]:
		push_warning("%s rendering is currently broken due to a bug" % os_name)
		push_warning("see https://github.com/godotengine/godot/pull/104809")

	camera_display.size = camera_display.get_parent_area_size() - Vector2.ONE * 40
	camera_preview.custom_minimum_size = camera_display.size
	camera_preview.position = camera_display.size / 2
	# Initialize camera
	_reload_camera_list()

func _reload_camera_list():
	# Request camera permission on mobile
	if OS.get_name() in ["Android", "iOS"]:
		var permissions = OS.get_granted_permissions()
		if not "CAMERA" in permissions:
			if not OS.request_permission("CAMERA"):
				print("CAMERA permission not granted")
				return

	camera_list.clear()
	format_list.clear()

	CameraServer.monitoring_feeds = true

	# Wait for monitoring to be ready on web platform
	if OS.get_name() == "Web":
		while not CameraServer.monitoring_feeds:
			await get_tree().process_frame

	# Get available camera feeds
	var feeds = CameraServer.feeds()
	if feeds.is_empty():
		camera_list.add_item("No cameras found")
		camera_list.disabled = true
		start_or_stop_button.disabled = true
		return

	camera_list.disabled = false
	for i in feeds.size():
		var feed: CameraFeed = feeds[i]
		camera_list.add_item(feed.get_name())

	# Auto-select first camera
	if camera_list.item_count > 0:
		camera_list.selected = 0
		_on_camera_list_item_selected(0)
	else:
		camera_list.disabled = true
		start_or_stop_button.disabled = true

func _on_camera_list_item_selected(index: int):
	if index < 0 or index >= CameraServer.feeds().size():
		return

	# Stop previous camera if active
	if camera_feed and camera_feed.feed_is_active:
		camera_feed.feed_is_active = false
		camera_active = false

	# Get selected camera feed
	camera_feed = CameraServer.feeds()[index]

	# Update format list
	_update_format_list()

func _update_format_list():
	format_list.clear()

	if not camera_feed:
		return

	var formats = camera_feed.get_formats()
	if formats.is_empty():
		format_list.add_item("No formats available")
		format_list.disabled = true
		var os_name := OS.get_name()
		if os_name in ["macOS", "iOS"]:
			push_warning("%s is not supported CameraFeed formats" % os_name)
			push_warning("see https://github.com/godotengine/godot/pull/106777")
		else:
			start_or_stop_button.disabled = true
			return

	format_list.disabled = false
	for format in formats:
		var resolution := str(format["width"]) + "x" + str(format["height"])
		format_list.add_item(format["format"] + " - " + resolution)

	# Auto-select first format
	format_list.selected = 0
	_on_format_list_item_selected(0)

func _on_format_list_item_selected(index: int):
	if not camera_feed:
		return

	var formats = camera_feed.get_formats()
	var os_name = OS.get_name()
	if not os_name in ["macOS", "iOS"]:
		if index < 0 or index >= formats.size():
			return
	var parameters: Dictionary = defaultWebResolution if os_name == "Web" else {}
	camera_feed.set_format(index, parameters)
	_start_camera_feed()

func _start_camera_feed():
	if not camera_feed:
		return

	camera_feed.frame_changed.connect(_on_frame_changed, ConnectFlags.CONNECT_ONE_SHOT | ConnectFlags.CONNECT_DEFERRED)
	# Start the feed
	camera_feed.feed_is_active = true
	camera_active = true

func _on_frame_changed():
	var datatype := camera_feed.get_datatype() as CameraFeed.FeedDataType
	var preview_size := Vector2.ZERO
	var mat: ShaderMaterial = camera_preview.material
	var rgb_texture: CameraTexture = mat.get_shader_parameter("rgb_texture")
	var y_texture: CameraTexture = mat.get_shader_parameter("y_texture")
	var cbcr_texture: CameraTexture = mat.get_shader_parameter("cbcr_texture")
	rgb_texture.which_feed = CameraServer.FeedImage.FEED_RGBA_IMAGE
	y_texture.which_feed = CameraServer.FeedImage.FEED_Y_IMAGE
	cbcr_texture.which_feed = CameraServer.FeedImage.FEED_CBCR_IMAGE
	match datatype:
		CameraFeed.FeedDataType.FEED_RGB:
			rgb_texture.camera_feed_id = camera_feed.get_id()
			mat.set_shader_parameter("rgb_texture", rgb_texture)
			mat.set_shader_parameter("mode", 0)
			preview_size = rgb_texture.get_size()
		CameraFeed.FeedDataType.FEED_YCBCR_SEP:
			y_texture.camera_feed_id = camera_feed.get_id()
			cbcr_texture.camera_feed_id = camera_feed.get_id()
			mat.set_shader_parameter("y_texture", y_texture)
			mat.set_shader_parameter("cbcr_texture", cbcr_texture)
			mat.set_shader_parameter("mode", 1)
			preview_size = y_texture.get_size()
		_:
			print("YCbCr format not fully implemented yet")
			return
	var white_image := Image.create(int(preview_size.x), int(preview_size.y), false, Image.FORMAT_RGBA8)
	white_image.fill(Color.WHITE)
	camera_preview.texture = ImageTexture.create_from_image(white_image)
	var rot := camera_feed.feed_transform.get_rotation()
	var degree := roundi(rad_to_deg(rot))
	camera_preview.rotation = rot
	camera_preview.custom_minimum_size.y = camera_display.size.y
	if degree % 180 == 0:
		camera_display.ratio = preview_size.x / preview_size.y
	else:
		camera_display.ratio = preview_size.y / preview_size.x
	start_or_stop_button.text = "Stop"

func _on_start_or_stop_button_pressed(change_label: bool = true):
	if camera_feed and camera_feed.feed_is_active:
		var connections = camera_feed.frame_changed.get_connections()
		for c in connections:
			camera_feed.frame_changed.disconnect(c["callable"])

		camera_feed.feed_is_active = false
		camera_active = false
		camera_preview.texture = null
		camera_preview.rotation = 0
		if change_label:
			start_or_stop_button.text = "Start"
	else:
		_start_camera_feed()
		if change_label:
			start_or_stop_button.text = "Stop"

func _on_reload_button_pressed():
	_on_start_or_stop_button_pressed(false)
	_reload_camera_list()

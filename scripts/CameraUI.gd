# CameraUI.gd
extends Control

signal permission_granted

const FEED_INDEX: int = 0
const FORMAT_INDEX: int = 0
const MAX_COUNT: int = 6000

@onready var camera_view: TextureRect = $PanelContainer/VBoxContainer/CameraView

var shader_material: ShaderMaterial = null
var texture: Texture2D = null
var rgb_texture: CameraTexture = null
var y_texture: CameraTexture = null
var cbcr_texture: CameraTexture = null

func _ready() -> void:
	# Load and prepare ShaderMaterial
	shader_material = camera_view.material
	permission_granted.connect(setup_camera)

# Release camera when the node is removed from the tree
func _exit_tree() -> void:
	stop_camera()

# Camera initialization function called from Main.gd
func initialize_camera() -> void:
	print("CameraUI: Initializing camera")
	if OS.get_name() in ["Android", "iOS"]:
		var permissions := OS.get_granted_permissions()
		for p in permissions:
			print("granted: %s" % p)
		if OS.request_permission("CAMERA"):
			permission_granted.emit()
		else:
			print("Camera permission denied.")
		return
	permission_granted.emit()

# Camera stop function called from Main.gd
func stop_camera() -> void:
	print("CameraUI: Stopping YCbCr camera...")

	# Clear TextureRect material and texture (optional)
	if is_instance_valid(camera_view): # Check if the node is valid
		camera_view.material = null
		camera_view.texture = null # Usually not necessary when using material
	texture = null
	rgb_texture = null
	y_texture = null
	cbcr_texture = null

func print_feeds(feeds: Array[CameraFeed]) -> void:
	print("-".repeat(20))
	for f in feeds:
		print("%d / %s / %s / %s" % [f.get_id(), f.get_name(), f.get_position(), prints_datatype(f.get_datatype())])
	print("-".repeat(20))

func print_formats(formats: Array) -> void:
	print("-".repeat(20))
	for f in formats:
		print(f)
	print("-".repeat(20))

func prints_datatype(dt: CameraFeed.FeedDataType) -> String:
	match dt:
		CameraFeed.FeedDataType.FEED_NOIMAGE:
			return "NOIMAGE"
		CameraFeed.FeedDataType.FEED_RGB:
			return "RGB"
		CameraFeed.FeedDataType.FEED_YCBCR:
			return "YCBCR"
		CameraFeed.FeedDataType.FEED_YCBCR_SEP:
			return "YCBCR_SEP"
		CameraFeed.FeedDataType.FEED_EXTERNAL:
			return "EXTERNAL"
		_:
			return "UNKNOWN"

# Find and set up YCbCr camera feed
func setup_camera() -> void:
	print("setup_camera")
	CameraServer.monitoring_feeds = true
	if OS.get_name() == "Web":
		var count: int = 0
		while (!CameraServer.monitoring_feeds):
			count += 1
			await get_tree().process_frame
			if count > MAX_COUNT:
				print("CameraServer does not monitoring")
				return
	var feeds := CameraServer.feeds()
	if feeds.is_empty():
		print("no cameras")
		return
	print_feeds(feeds)
	var feed := feeds[FEED_INDEX]
	print("selected feed: %d / %s / %s / %s" % [feed.get_id(), feed.get_name(), feed.get_position(), prints_datatype(feed.get_datatype())])

	if OS.get_name() != "macOS":
		# CameraFeed.formats (and similar APIs) are not supported in macOS.
		var formats := feed.get_formats()
		if OS.get_name() != "Web":
			# // CameraFeed.formats (and similar APIs) are not supported in Firefox ESR.
			if formats.is_empty():
				print("no formats")
				return
			print_formats(formats)
		var parameters: Dictionary = {}
		if OS.get_name() == "Web":
			parameters = {"width": 1280, "height": 1080}
		feed.set_format(FORMAT_INDEX, parameters)
		print("selected format: %s" % formats[FORMAT_INDEX])

	# Set texture to shader
	if shader_material:
		var id := feed.get_id()
		rgb_texture = shader_material.get_shader_parameter("rgb_texture")
		y_texture = shader_material.get_shader_parameter("y_texture")
		cbcr_texture = shader_material.get_shader_parameter("cbcr_texture")

		var _on_frame_changed = func() -> void:
			print("called frame_changed")
			var dt := feed.get_datatype()
			print("datatype: %s" % prints_datatype(dt))
			var s2 := Vector2.ZERO
			match dt:
				CameraFeed.FeedDataType.FEED_RGB:
					rgb_texture.camera_feed_id = id
					shader_material.set_shader_parameter("rgb_texture", rgb_texture)
					shader_material.set_shader_parameter("mode", 0)
					s2 = rgb_texture.get_size()
				CameraFeed.FeedDataType.FEED_YCBCR_SEP:
					y_texture.camera_feed_id = id
					cbcr_texture.camera_feed_id = id
					shader_material.set_shader_parameter("y_texture", y_texture)
					shader_material.set_shader_parameter("cbcr_texture", cbcr_texture)
					shader_material.set_shader_parameter("mode", 1)
					s2 = y_texture.get_size()
				_:
					print("Unknown datatype: %s" % dt)
					return
			print("draw size: {x, y} = {%d, %d}" % [s2.x, s2.y])
			var image2 := Image.create(int(s2.x), int(s2.y), false, Image.FORMAT_RGBA8)
			image2.fill(Color.WHITE)
			texture = ImageTexture.create_from_image(image2)
			camera_view.texture = texture

			var s1 := camera_view.size
			var rot := feed.feed_transform.get_rotation()

			# Calculate actual texture dimensions after rotation
			var texture_width := s2.x
			var texture_height := s2.y

			# If rotated by 90 or 270 degrees, swap width and height
			if int(rot) % 180 != 0:
				texture_width = s2.y
				texture_height = s2.x

			# Calculate aspect ratios
			var ui_aspect := s1.x / s1.y
			var texture_aspect := texture_width / texture_height

			# Calculate new dimensions maintaining aspect ratio
			var new_width: float
			var new_height: float

			if texture_aspect > ui_aspect:
				# Texture is wider - fit to width
				new_width = s1.x
				new_height = s1.x / texture_aspect
			else:
				# Texture is taller - fit to height
				new_height = s1.y
				new_width = s1.y * texture_aspect
			
			var new_size := Vector2(new_width, new_height)

			# Center the view in the container using pivot
			camera_view.pivot_offset = camera_view.size / 2.0
			camera_view.rotation = rot

			# Apply calculated size to camera_view
			camera_view.size = new_size
		if OS.get_name() == "macOS":
			feed.format_changed.connect(_on_frame_changed.call_deferred, ConnectFlags.CONNECT_ONE_SHOT)
		else:
			feed.frame_changed.connect(_on_frame_changed.call_deferred, ConnectFlags.CONNECT_ONE_SHOT)
		feed.feed_is_active = true
	else:
		print("Error: ShaderMaterial is not initialized.")
		feed.feed_is_active = false

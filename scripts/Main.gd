# Main.gd
extends Node

# Reference to child node (set from inspector)
@onready var camera_ui = $CameraUI

func _ready():
	# Show CameraUI from the beginning and initialize the camera
	camera_ui.show()
	if camera_ui.has_method("initialize_camera"):
		await camera_ui.initialize_camera()

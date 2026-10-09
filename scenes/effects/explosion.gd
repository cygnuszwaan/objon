extends AnimatedSprite2D
## One-shot VFX. Whoever spawns this just needs to instance it, set global_position (or
## reparent it wherever it should render), and add it to the tree — it plays its "explode"
## animation once at the authored 10 FPS and frees itself on the last frame. No signals or
## manual cleanup required from the caller.

func _ready() -> void:
	animation_finished.connect(queue_free)
	play(&"explode")

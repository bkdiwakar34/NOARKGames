extends Node

# Entry of the clinic-study flow (docs/clinic_study_interface.md), separate from
# the patient app. Run with
#     --main-scene res://app/clinic/clinic_main.tscn
# It holds the current screen. For now (build plan §7.2, package 1) the only
# screen is the round runner; Home, Registration and Settings come later.

const RoundRunner := preload("res://app/clinic/round_runner.gd")

var _screen: Node = null


func _ready() -> void:
	show_screen(RoundRunner.new())


func show_screen(screen: Node) -> void:
	if _screen:
		_screen.queue_free()
	_screen = screen
	add_child(screen)


func _input(event: InputEvent) -> void:
	# Esc quits. Stop the tracker here: get_tree().quit() does not send the
	# window-close request that UDPReceiver stops it on.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		UDPReceiver.stop()
		get_tree().quit()

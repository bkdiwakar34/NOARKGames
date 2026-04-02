@tool
extends EditorPlugin

func _enter_tree():
	print("GdBLE plugin activated")

func _exit_tree():
	print("GdBLE plugin deactivated")

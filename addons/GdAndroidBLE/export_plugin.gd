@tool
extends EditorPlugin

var export_plugin : AndroidExportPlugin

func _enter_tree():
	export_plugin = AndroidExportPlugin.new()
	add_export_plugin(export_plugin)


func _exit_tree():
	remove_export_plugin(export_plugin)
	export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	var _plugin_name = "GdAndroidBLE"

	func _supports_platform(platform):
		if platform is EditorExportPlatformAndroid:
			return true
		return false

	func _get_android_libraries(platform, debug):
		if debug:
			return PackedStringArray([_plugin_name + "/bin/debug/" + _plugin_name + "-debug.aar"])
		else:
			return PackedStringArray([_plugin_name + "/bin/release/" + _plugin_name + "-release.aar"])

	func _get_android_dependencies(platform, debug):
		return PackedStringArray([])

	# Injects plugin registration meta-data into AndroidManifest.
	# Required for non-Gradle builds where AAR manifest merging is skipped.
	func _get_android_manifest_application_element_contents(platform, debug):
		if not platform is EditorExportPlatformAndroid:
			return ""
		return """
		<meta-data
			android:name="org.godotengine.plugin.v2.GdAndroidBLE"
			android:value="org.godotengine.plugin.android.gdble.GodotAndroidPlugin" />
		"""

	func _get_name():
		return _plugin_name

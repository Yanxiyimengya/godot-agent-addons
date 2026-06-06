@abstract
class_name AgentTool;
extends Resource;

@abstract
func _get_name() -> String;

@abstract
func _get_description() -> String;

@abstract
func _get_properties() -> Dictionary;

@abstract
func _call(args : Dictionary) -> Variant;

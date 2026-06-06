class_name AgentToolActuator;
extends Resource;

@export
var tool_list : Dictionary[String, AgentTool] = {};

## 添加一个Agent工具
func append_tool(tool : AgentTool) -> void:
	if (tool == null) :
		return;
	var tool_name : String = tool._get_name();
	if (!tool_name.is_empty() && !tool_list.has(tool_name)) : 
		tool_list[tool_name] = tool;

## 获取一个Agent工具
func get_tool(tool_name : String) -> AgentTool:
	if (tool_list.has(tool_name)) :
		return tool_list[tool_name];
	return null;

## 调用Agent工具
func call_tool(tool_name : String, arguments : Dictionary) -> Variant:
	var tool : AgentTool = get_tool(tool_name);
	if (tool == null) :
		return _error_result("tool_not_found", "Tool '%s' was not found." % [tool_name]);
	
	var validation_error : Dictionary = _validate_arguments(tool, arguments);
	if (!validation_error.is_empty()) :
		return { "error" : validation_error };
	
	return await tool._call(arguments);

## 验证参数有效性
func _validate_arguments(tool : AgentTool, arguments : Dictionary) -> Dictionary:
	var parameters : Dictionary = tool._get_properties();
	if (parameters.is_empty()) :
		return {};
	if (parameters.get("type", "object") != "object") :
		return _error_payload(
			"invalid_schema",
			"Tool '%s' parameters schema must be an object." % [tool._get_name()]
		);
	
	var required_value : Variant = parameters.get("required", []);
	if (typeof(required_value) == TYPE_ARRAY) :
		for required_name : Variant in required_value :
			if (typeof(required_name) == TYPE_STRING && !arguments.has(required_name)) :
				return _error_payload(
					"missing_argument",
					"Tool '%s' requires argument '%s'." % [tool._get_name(), required_name]
				);
	
	var properties_value : Variant = parameters.get("properties", {});
	if (typeof(properties_value) != TYPE_DICTIONARY) :
		return {};
	
	var properties : Dictionary = properties_value;
	var additional_properties : bool = bool(parameters.get("additionalProperties", true));
	for argument_name : Variant in arguments.keys() :
		if (typeof(argument_name) != TYPE_STRING) :
			return _error_payload("invalid_argument", "Tool argument names must be strings.");
		if (!properties.has(argument_name)) :
			if (!additional_properties) :
				return _error_payload(
					"unexpected_argument",
					"Tool '%s' does not accept argument '%s'." % [tool._get_name(), argument_name]
				);
			continue;
		
		var property_schema : Variant = properties[argument_name];
		if (typeof(property_schema) != TYPE_DICTIONARY) :
			continue;
		var expected_type : Variant = property_schema.get("type", "");
		if (!_matches_json_schema_type(arguments[argument_name], expected_type)) :
			return _error_payload(
				"invalid_argument_type",
				"Tool '%s' argument '%s' has invalid type." % [tool._get_name(), argument_name]
			);
	return {};

## 匹配 JSON schema 参数类型
func _matches_json_schema_type(value : Variant, expected_type : Variant) -> bool:
	if (expected_type == null || expected_type == "") :
		return true;
	if (typeof(expected_type) == TYPE_ARRAY) :
		for type_name : Variant in expected_type :
			if (_matches_json_schema_type(value, type_name)) :
				return true;
		return false;
	if (typeof(expected_type) != TYPE_STRING) :
		return true;
	
	match (expected_type) :
		"string":
			return typeof(value) == TYPE_STRING;
		"number":
			return typeof(value) == TYPE_FLOAT || typeof(value) == TYPE_INT;
		"integer":
			return typeof(value) == TYPE_INT;
		"boolean":
			return typeof(value) == TYPE_BOOL;
		"object":
			return typeof(value) == TYPE_DICTIONARY;
		"array":
			return typeof(value) == TYPE_ARRAY;
		"null":
			return typeof(value) == TYPE_NIL;
		_:
			return true;

func _error_result(code : String, message : String) -> Dictionary:
	return { "error" : _error_payload(code, message) };

func _error_payload(code : String, message : String) -> Dictionary:
	return {
		"code" : code,
		"message" : message,
	};

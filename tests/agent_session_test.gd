extends Node

@export_multiline() var sys : String;

var client : AgentClient;

func _ready() -> void:

	var config_file : String = FileAccess.get_file_as_string("res://config.json");
	var json : Dictionary = JSON.parse_string(config_file);
	var model : String = "deepseek-v4-pro";

	var context = AgentContext.new(AgentContext.APIStandard.OpenAI);
	context.config.base_url = json["url"][model];
	context.config.api_key = json["api"][model];
	context.config.model = model;
	context.config.stream = true;
	context.config.system_prompt = sys;
	context.tool_actuator.append_tool(AgentToolTest.new());
	
	client = AgentClient.new();
	add_child(client);
	client.context = context;
	client.message_received.connect(_on_agent_message_received);
	client.message_stream_updated.connect(_on_agent_message_stream_updated);

@onready var text_edit: TextEdit = $TextEdit;
@onready var button: Button = $Button;
@onready var label = $Label;

func send(msg : String) -> void:
	label.text = "";
	client.send_message(msg);

func _on_agent_message_received(message : AgentMessage) -> void:
	if (message is AgentAssistantMessageStream) :
		return;
	var assistant_message : AgentAssistantMessage = message as AgentAssistantMessage;
	if (assistant_message != null) :
		label.text += assistant_message.content;

func _on_agent_message_stream_updated(message_stream : AgentAssistantMessageStream) -> void:
	label.text += message_stream.read_content_delta();

func _on_button_pressed() -> void:
	send(text_edit.text);

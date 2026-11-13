extends VBoxContainer

const UI := preload("res://scripts/UiStyle.gd")
var provider: OptionButton
var address: LineEdit
var model: LineEdit
var key: LineEdit
var status: Label
var save_button: Button
var test_button: Button
var loaded := false
var busy := false
var generation := 0

func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_note("大模型 API · 所有存档共用", UI.BODY_SIZE)
	_note("用于角色自由对话与日语补译。支持 OpenAI 兼容的 Chat Completions 接口。")
	provider = OptionButton.new()
	for title in ["自定义 / OpenAI 兼容", "DeepSeek", "OpenAI"]:
		provider.add_item(title)
	add_child(provider)
	provider.item_selected.connect(_preset)
	address = _field("服务地址（Base URL）", "例如 https://api.deepseek.com")
	_note("复制平台文档中的 Base URL，保留 /v1 等前缀；不要加 /chat/completions，也不要填聊天网页版网址。")
	model = _field("模型名称（Model ID）", "填写平台提供的完整模型 ID")
	_note("模型名称区分大小写，使用 API 文档中的 ID，不是网页上的显示名称。更换平台后请同时更换密钥。")
	key = _field("API Key（密钥）", "首次使用请填写；留空保留已保存的密钥")
	key.secret = true
	var show_key := CheckButton.new()
	show_key.text = "显示本次输入的密钥"
	show_key.toggled.connect(func(enabled: bool) -> void: key.secret = not enabled)
	add_child(show_key)
	_note("密钥在平台的 API 控制台创建，不是登录密码。仅保存在本机 Core 数据目录的配置文件中（明文），不写入故事存档；请勿分享该文件。")
	var buttons := HBoxContainer.new()
	add_child(buttons)
	test_button = _button(buttons, "测试连接", _test)
	save_button = _button(buttons, "保存 API 配置", _save)
	status = _note("正在加载当前配置…")
	_note("测试会向当前填写的地址发送一条短请求，可能产生少量 API 费用；测试成功后仍需保存。保存成功后用于后续请求，重启也会保留。")
	var help := _button(self, "展开新手配置指南", func() -> void: get_node("Guide").visible = not get_node("Guide").visible)
	help.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var guide := VBoxContainer.new()
	guide.name = "Guide"
	guide.visible = false
	add_child(guide)
	var instructions := Label.new()
	instructions.name = "GuideNote"
	instructions.text = "1. 在服务商的 API 平台注册账号，开通 API 并检查余额 / 额度。聊天会员与 API 额度可能分别计费。\n2. 在 API Keys 页面创建密钥，复制到上方密钥栏。\n3. 从官方文档复制 Base URL 和模型 ID；选择预设只会填写地址，模型请按平台当前列表填写。\n4. 点击测试连接；成功后点击保存 API 配置。角色语音仍使用原本的本机语音服务。\n\nDeepSeek 示例地址：https://api.deepseek.com；模型 ID 请查下方官方指南。\nOpenAI 示例地址：https://api.openai.com/v1；选支持 Chat Completions、流式输出及 temperature / top_p 的模型。\n第三方平台：选自定义，填写平台的 OpenAI 兼容地址及模型 ID。仅有 Anthropic Messages 或 Responses 接口的平台不能直接使用。\n本机模型：地址可填 http://127.0.0.1:端口/v1；无鉴权服务在密钥栏填 local 占位。\n\n常见问题：401 检查密钥；403 检查权限；404 检查地址和模型 ID；429 检查额度 / 限流；超时检查网络。测试成功只确认接口可用，角色输出与多角色格式仍取决于模型能力。\n如程序启动时为西耶尔单独配置过模型环境变量，它仍使用独立配置。"
	instructions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	instructions.add_theme_font_size_override("font_size", UI.CAPTION_SIZE)
	guide.add_child(instructions)
	_button(guide, "DeepSeek 官方配置指南 ↗", func() -> void: OS.shell_open("https://api-docs.deepseek.com/"))
	_button(guide, "OpenAI 官方 API 文档 ↗", func() -> void: OS.shell_open("https://developers.openai.com/api/reference/chat-completions/overview"))
	_set_busy(false)

func _note(text: String, font_size: int = UI.CAPTION_SIZE) -> Label:
	var label := Label.new()
	label.name = "ApiNote"
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	add_child(label)
	return label

func _field(title: String, placeholder: String) -> LineEdit:
	_note(title)
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size.y = 40
	field.add_theme_font_size_override("font_size", UI.NAME_SIZE)
	add_child(field)
	return field

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	parent.add_child(button)
	UI.text_button(button, UI.BUTTON_BODY_SIZE)
	button.pressed.connect(action)
	return button

func refresh() -> void:
	if busy:
		return
	generation += 1
	var ticket := generation
	loaded = false
	_set_busy(true)
	status.text = "正在加载当前配置…"
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/settings/model", {}, func(ok: bool, data) -> void:
		if not is_instance_valid(self) or ticket != generation:
			return
		loaded = ok and data is Dictionary
		if loaded:
			address.text = str(data.get("base_url", ""))
			model.text = str(data.get("model", ""))
			key.text = ""
			provider.select(1 if str(data.get("provider")) == "deepseek" else 0)
			status.text = "已配置密钥；留空可保留。" if data.get("has_api_key", false) else "尚未配置密钥，请先填写。"
			if data.get("ciel_override", false):
				status.text += " 西耶尔使用启动时的独立配置。"
		else:
			status.text = "无法读取配置，请检查 Core 连接后重新打开设置。"
		_set_busy(false)
	)

func _preset(index: int) -> void:
	if index == 1:
		address.text = "https://api.deepseek.com"
	elif index == 2:
		address.text = "https://api.openai.com/v1"
	status.text = "请按服务商当前文档填写模型 ID，并确认密钥属于这个服务商。"

func _payload() -> Dictionary:
	return {"provider": "deepseek" if provider.selected == 1 else "openai-compatible", "base_url": address.text.strip_edges(), "model": model.text.strip_edges(), "api_key": key.text.strip_edges()}

func _set_busy(value: bool) -> void:
	busy = value
	for button in [save_button, test_button]:
		button.disabled = value or not loaded
	provider.disabled = value
	for field in [address, model, key]:
		field.editable = not value

func _save() -> void:
	_submit(HTTPClient.METHOD_PUT, "/api/v2/settings/model", true)

func _test() -> void:
	_submit(HTTPClient.METHOD_POST, "/api/v2/settings/model/test", false)

func _submit(method: int, path: String, saving: bool) -> void:
	var body := _payload()
	if str(body.base_url).is_empty() or str(body.model).is_empty():
		status.text = "请先填写服务地址和模型 ID。"
		return
	_set_busy(true)
	status.text = "正在保存…" if saving else "正在测试连接…"
	ApiClient.request_json(method, path, body, func(ok: bool, data) -> void:
		if not is_instance_valid(self):
			return
		_set_busy(false)
		if not ok or not (data is Dictionary):
			status.text = str(data.get("detail", "请求失败，请检查 Core 连接。")) if data is Dictionary else "请求失败，请检查 Core 连接。"
		elif saving:
			key.text = ""
			status.text = "API 配置已保存，后续请求生效。"
		else:
			status.text = str(data.get("message", "测试未返回结果。"))
	)

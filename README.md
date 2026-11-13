# Arcueid Stage

Windows 本地运行的 Godot 对话游戏项目，包含课堂对话和公园剧情演出。玩家输入中文，Core 调用兼容 Chat Completions 的模型生成回复，可连接本地 GPT-SoVITS 实时合成角色语音。

**此仓库提供运行源码。图片、音乐、原作剧情文本、完整检索资料、模型权重与个人配置不包含在内。仅下载 Source code ZIP 尚不能完整游玩。** 外部资源的公开下载地址目前尚未提供。

## 目录

```text
game/ArcueidStage/    Godot 工程、场景、脚本、着色器与资源映射
core/                本地 API、对话、剧情、音频和存档代码
voice/proxy/         语音代理
voice/profiles/      三角色模型路由
scripts/             环境安装、资源检查、服务启停
config/              空白配置模板
dependencies/        第三方引擎版本
resources/           外部资源路径、大小与校验值
docs/                部署和资源说明
Start.bat / Stop.bat 游戏与服务入口
```

## 使用

1. 安装 Python **3.11** 和 Godot **4.7.2**，克隆本仓库。
2. 执行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup/setup.ps1`。
3. 按 [资源说明](docs/ASSETS.md) 恢复有权使用且与当前版本匹配的资源，执行 `runtime/python/Scripts/python.exe scripts/check/assets.py --hash` 检查。
4. 设置 `GODOT_PATH` 为 Godot 可执行文件路径，先运行 `Start.bat -SkipVoice`。
5. 在课堂设置中的“大模型 API”填写自己的服务地址、模型名称和密钥。API 调用费用由玩家自己的服务账户承担。
6. 完整本地语音按 [语音说明](docs/VOICE.md) 准备后，运行 `Start.bat`。`Stop.bat` 停止本项目启动的后台服务。

详细步骤见 [部署说明](docs/SETUP.md)。文本模式仍需要游戏媒体与剧情资源；不加载 TTS 不代表可以缺少图像文件。

本仓库只包含 Godot 游戏运行所需部分，不包含桌宠、训练工具、私人开发记录、个人数据或历史素材。第三方角色、原作文本、图像、音频和模型的权利归各自权利人所有；源码仓库不授予这些内容的使用或再分发权利。

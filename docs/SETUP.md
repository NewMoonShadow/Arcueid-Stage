# 部署与启动

当前提供源码部署方式，尚未提供经过干净电脑验收的 Windows 一键安装包。需要 Windows、Python 3.11、Godot 4.7.2，以及另行准备的游戏资源。

```powershell
git clone https://github.com/NewMoonShadow/Arcueid-Stage.git
cd Arcueid-Stage
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup/setup.ps1
```

环境安装到被忽略的 `runtime/python/`。若 Python 未被找到，先将 `ARCUEID_PYTHON` 指向已安装的 Python 3.11。安装脚本联网安装 Core／Proxy 轻量依赖，不下载媒体、语料、权重或底模。

恢复 [外部资源](ASSETS.md) 后，在同一 PowerShell 中设置 Godot 路径并启动：

```powershell
$env:GODOT_PATH = 'C:\Tools\Godot\Godot_v4.7.2-stable_win64.exe'
.\Start.bat -SkipVoice
```

`Start.bat -CheckOnly` 只检查资源；`Start.bat -Editor -SkipVoice` 打开 Godot 编辑器。完整语音使用 `Start.bat`，需要先按 [语音说明](VOICE.md) 安装本地语音依赖。

Core 默认监听 `127.0.0.1:8765`，Proxy 为 `127.0.0.1:8766`。在课堂设置中填写自己的 OpenAI 兼容 Chat Completions 服务 Base URL、Model ID 和 API Key，测试连接后保存。Base URL 不追加 `/chat/completions`。只启用文字模式时无需启动 Proxy。

通过 Start 入口运行时，Godot 偏好和 Core 存档保存在被忽略的 `userdata/`。模型 API 设置为本机明文配置，不应上传或作为反馈附件发送。`config/runtime_config.example.json` 是空模板；可手动复制为被忽略的 `config/runtime_config.json`。不需要替换源码里的密钥。

可选检索索引放 `corpus/stage_index/`，包含 `manifest.json`、`records.jsonl`、`index.sqlite3` 和 `vectors.npy`。该目录不包含在仓库中；没有索引时 Core 可启动，但不能提供本地证据检索。BGE 索引另需匹配的运行依赖，轻量安装不能直接加载所有嵌入模型。

停止时使用 `Stop.bat`。它按启动记录和进程身份停止本项目 Core／Proxy，并按解释器、目录、端口与配置匹配 WSL 语音；不会关闭整套 WSL。Godot 游戏／编辑器窗口可自行关闭。

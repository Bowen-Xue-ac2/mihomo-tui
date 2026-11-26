# X · Mihomo 终端

我在 Windows 上自用的 Mihomo 终端工具，基于 [wzk0/mihomo-tui](https://github.com/wzk0/mihomo-tui) v1.4。平时用 PowerShell 切节点、切模式和查状态，需要测速或看日志时再打开终端界面。

## 日常操作

```powershell
wzk                        # 打开终端界面，概览显示 X
wzk status --json          # 核心、配置和控制器状态
wzk start                  # 启动内核
wzk stop                   # 停止内核
wzk restart                # 重启内核
wzk nodes GLOBAL           # 列出候选节点，* 是当前选择
wzk use GLOBAL "节点名"    # 填列表里的完整名称，支持空格
wzk mode                   # 查看当前模式
wzk mode rule              # 可选 rule、global、direct
```

`wzk` 是本机的启动命令。其他环境可用编译后的 `mihomo-tui.exe` 执行同样的子命令。指定 `--data`、`--home` 和 `--bin` 时，把它们写在子命令前。这些命令从选定内核目录的 `config.yaml` 读取控制器信息，`mode` 修改的是当前运行模式。

## 终端快捷键

| 按键 | 操作 |
| --- | --- |
| `1` / `2` / `3` / `4` / `5` | 概览 / 订阅 / 代理 / 日志 / 设置 |
| `Tab` / `←→` | 切换焦点或代理组与节点列 |
| `Enter` | 选中节点或执行操作 |
| `t` / `T` | 在代理页测单节点 / 测整组 |
| `q` | 关界面，内核继续在后台运行 |

## 从源码构建

Windows x64 使用 Dart SDK 3.13.7。Mihomo 可执行文件和配置单独准备。

```powershell
dart pub get --enforce-lockfile
New-Item -ItemType Directory -Force build | Out-Null
dart compile exe bin/mihomo_tui.dart -o build/mihomo-tui.exe
.\build\mihomo-tui.exe --help
```

这个版本包含 Windows 终端启动的信号监听修复。订阅、系统代理和备份的操作细节见 [上游 v1.4 文档](https://github.com/wzk0/mihomo-tui/tree/v1.4)。

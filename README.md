# USBetter

Windows x64 上的 Android USB 网络共享助手。连接手机并完成 USB 调试授权后，工具自动识别设备、获取配置、开启共享，并在系统托盘显示连接状态。

## 功能

- 自动发现 USB 手机，保存设备信息与连接配置。
- 自动关联手机对应的 USB 网卡，检查地址与网关。
- 登录 Windows 后启动，接入手机时自动连接。
- 保留用户后续切换文件传输、关闭共享等操作。
- 通过托盘选择手机、立即连接、暂停或恢复。
- C++ 原生程序常驻监听，PowerShell 按需执行连接任务。

## 快速开始

准备 Windows x64 电脑、Android 手机和支持数据传输的 USB 线。

1. 从 [Actions 构建页面](https://github.com/song001-source/USBetter/actions/workflows/build.yml) 下载 `USBetter-windows-x64` 构建产物，解压其中的 Windows x64 ZIP。
2. 双击 `USBetter.exe`，按引导完成设置。程序使用当前用户权限安装。
3. 设置会查找已保存路径和系统中的 ADB。也可从 [Google 官方页面](https://developer.android.com/tools/releases/platform-tools) 下载并解压 Platform-Tools，再选择其中的 `adb.exe`；离线准备的完整目录同样可用。
4. 手机开启开发者选项与 USB 调试，通过 USB 连接电脑，解锁并允许本电脑调试。
5. 授权后自动继续连接。托盘显示“USB 网卡就绪”时，手机对应的网卡已取得有效 IPv4 地址和默认网关。

首次授权窗口为 120 秒，之后可通过托盘“重新检测”继续。连接多部手机且尚未选择目标时，工具会弹窗选择。

## 日常使用

托盘提供状态、立即连接、重新检测、选择手机、暂停、恢复、诊断、设置 / 升级和卸载。

每次登录或新接入时执行一次连接流程。连接完成后，手机端的 USB 模式由用户继续控制。当前手机接入期间保持所选目标，切换手机可使用“选择手机”。

“暂停”同时关闭自动连接和计划任务恢复，“恢复”重新启用。升级时再次运行新版本的 `USBetter.exe --setup`。

## 命令行

统一入口为 `USBetter.exe`，默认启动设置或托盘。

| 参数 | 操作 |
| --- | --- |
| `--setup` | 设置 ADB、安装或升级 |
| `--status` | 查看运行状态 |
| `--connect` | 立即连接所选手机 |
| `--detect` | 重新检测手机 |
| `--choose` | 选择手机 |
| `--pause` | 暂停自动连接与进程恢复 |
| `--resume` | 恢复自动连接与进程恢复 |
| `--diagnose` | 显示并生成脱敏诊断 |
| `--uninstall` | 移除自启并卸载，可选删除配置与日志 |

托盘与命令行共用同一组动作，通过当前用户的本地 Windows 命名管道通信。命令返回 `Accepted` 表示动作已接收，执行结果可通过 `--status` 查看。

## 安装与数据

| 内容 | 位置 |
| --- | --- |
| 程序文件 | `%LOCALAPPDATA%\Programs\USBetter` |
| 配置、日志、状态与升级备份 | `%LOCALAPPDATA%\USBetter` |
| 脱敏诊断 | 数据目录中的 `diagnostic-public.json` |

首次设置会注册当前用户的登录启动任务和进程恢复任务。已有 `AzqUsbTether` 安装会在备份后迁移，原手机作为已知目标重新识别。

升级前备份配置、任务和旧程序，失败时恢复旧安装。卸载后保留手机当前共享状态，并按用户选择保留或删除本地数据。

## 构建

安装包含 Windows SDK 的 Visual Studio C++ x64 工具链，运行：

```powershell
.\tools\Build.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Verify.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Verify-Native.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Verify-Workflows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Verify-Host.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Package.ps1
```

构建工具通过 `vswhere` 自动发现 Visual Studio。发行 ZIP、版本信息、文件清单和 SHA-256 输出到 `dist`。GitHub Actions 自动执行 Windows x64 构建与检查。

## 项目文档

- [兼容性与实机验收记录](docs/ACCEPTANCE.md)
- [架构与连接机制](docs/ARCHITECTURE.md)
- [发布说明](docs/RELEASE.md)
- [故障反馈](https://github.com/song001-source/USBetter/issues/new?template=bug_report.md)

## 许可

项目源码采用 [MIT 许可](LICENSE)。第三方组件的许可与来源见 [THIRD_PARTY.md](THIRD_PARTY.md)。

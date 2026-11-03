# USB Tether Helper

Windows x64 上的 Android USB 网络共享助手，当前为 **0.1.0-preview.1**。C++ 原生托盘接收 USB 通知，PowerShell 5.1 仅在设备事件或用户动作时运行；没有周期性联网恢复。

这是兼容性尚在验证的预览版，不能保证所有 Android 手机可通过 ADB 开启共享。授权成功也不代表支持共享。必须在目标手机对应的 USB 网卡上获得有效 IPv4 和默认网关，才显示“USB 网卡就绪”。

## 快速开始

1. 解压 Windows x64 ZIP 到可写目录，双击 `UsbTetherHelper.exe`。普通用户不需要编译器或管理员权限。
2. 设置优先使用已保存路径、PATH 中的 ADB；缺少时可打开 [Google 官方 Platform-Tools 下载说明](https://developer.android.com/tools/releases/platform-tools)，解压后选择其中的 `adb.exe`。支持预先准备的离线完整目录。不修改 PATH、不覆盖已有 ADB。
3. 手机开启开发者选项与 USB 调试，使用支持数据传输的 USB 线连接，解锁并允许本电脑调试。首次窗口最长 120 秒，授权后自动继续。超时可在托盘选择“重新检测”。
4. 查看托盘状态。多个候选且无已选目标时会弹出选择框。可选“立即连接”“重新检测”“选择手机”“暂停”“恢复”“诊断”“设置 / 升级”“卸载”。

程序安装于 `%LOCALAPPDATA%\Programs\USB Tether Helper`；配置、日志、状态和升级备份存于 `%LOCALAPPDATA%\USB Tether Helper`。首次设置会注册当前用户的登录计划任务及进程恢复触发器。设置过程检测当前用户旧 `AzqUsbTether` 任务，备份并禁用旧任务，迁入旧目标作为偏好，识别和能力重新验证。旧日志不会复制或导出。

## 命令行

统一入口：`UsbTetherHelper.exe`，默认设置或运行托盘。可用参数：

| 参数 | 行为 |
| --- | --- |
| `--setup` | 设置 ADB、安装或升级 |
| `--status` | 查询本次登录会话的驻留进程及最近状态 |
| `--connect` | 明确请求连接 |
| `--pause` | 停止自动动作并禁用计划任务恢复；驻留托盘保留 |
| `--resume` | 恢复自动动作和计划任务；已有接入不强行重连 |
| `--diagnose` | 显示并生成脱敏诊断 |
| `--uninstall` | 移除自启、退出后台；可选删除配置和日志 |
| `--detect` / `--choose` | 与托盘重新检测 / 选择手机相同 |

有驻留实例时通过命名管道提交动作；响应 `Accepted` 表示已接收，完成结果查看状态。管道仅允许当前用户、仅本机，名字隔离登录会话。工具不提供 HTTP/TCP 控制接口；ADB 自身已有的 5037 端口属于 ADB。无驻留实例时，操作命令启动托盘处理；`--status` 不启动监听器。

## 连接策略

身份要求：ADB 序列号与唯一的 Windows USB 根设备序列号完全匹配，根设备下还必须存在 `Class_ff/SubClass_42/Prot_01` ADB 接口。拒绝无线 ADB、模拟器和重复根身份。不能匹配的厂商实现会安全失败，不猜测设备。不靠固定 VID/PID 判断模式。

默认每次登录或接入尝试一次。进程崩溃恢复读取登录令牌对应的接入记录，避免重复开启共享。用户后续切换文件传输或关闭共享会被保留；只有明确“立即连接 / 重新检测”、新登录或推断的新接入才重新尝试。活跃手机仍接入时不因另一部手机接入切换目标；可用“选择手机”明确切换。

USB 断开使用 **8 秒启发式**，并合并约 300ms 通知：极快拔插可能漏检，慢速模式重新枚举可能误判。手机重启也可能表现为新接入。状态存储损坏时停止自动处理，不清空后重试。每次尝试均实际验证网卡；固件变化使旧能力结论失效，失败计数保存在设备记录中。

共享就绪与外网访问是两件事。工具不自动探测外网；如需验证互联网，需确认目标网卡后自行诊断，避免 Wi-Fi、代理造成假阳性。

## 权限、隐私与卸载

仅登录用户权限，不是系统服务。ADB 授权本身允许广泛调试权限，请只授权可信电脑，按需在手机撤销授权。驱动故障仅给出建议；不执行注册表修复、不安装驱动、不运行 root 命令、不停止其他工具的 ADB 服务。

设置记录 ADB 与两个 DLL 的 SHA-256 和版本，每次连接检查文件有无变化，变更后需要重新设置。**这些哈希用于本地完整性基线，不能证明来源真实性**；请从官方入口获取完整目录并保留 NOTICE/许可证。当前仅支持 ADB 协议 1.0.41，服务协议冲突时停止。不要在本工具运行时让其他开发工具替换 ADB 服务版本。

本地设备配置含序列号、型号、固件指纹、USB ID、网卡地址；状态文件和备份可能包含本机路径。不要整体公开数据目录。`diagnostic-public.json` 只导出固定字段，不包含序列号、用户名、本机路径或原始异常。公开反馈前仍请人工检查截图和附件。

升级前备份配置、任务 XML 和旧程序，停止旧实例后替换，任务注册或启动失败时尝试恢复。未实机验证的回滚边界见验收记录。卸载保留手机当前共享状态，不关闭 ADB 服务；独立隐藏清理进程在后台退出后删除固定用户安装目录（最多等待 30 秒，失败时可手动删除）。默认保留本地数据，也可在卸载提示中选择删除。原始 ZIP 解压目录由用户保留。

## 构建与检查

安装带 Windows SDK 的 Visual Studio C++ x64 工具，运行：

```powershell
.\tools\Build.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Verify.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Verify-Native.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Package.ps1
```

工具通过 `vswhere` 查找所有 Visual Studio 产品，不依赖 Professional 安装目录。ZIP、逐文件清单和 ZIP SHA-256 输出到 `dist`。重复版本目录拒绝覆盖。源码不含设备配置、日志、注册表备份、构建产物或本机旧实验材料。

GitHub Actions 在 Windows 构建检查，`v<VERSION>` 标签生成预览 Release。首次公开前按 [发布检查](docs/RELEASE.md) 检查内容；仅建立本地仓库不会公开上传。

详细记录：[兼容性与实机验收](docs/ACCEPTANCE.md)、[架构与边界](docs/ARCHITECTURE.md)、[第三方许可](THIRD_PARTY.md)。项目源码为 MIT；第三方组件保留各自许可。

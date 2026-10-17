# SKP模块强制清理 ❤ Github/CedarXuesong

SKRoot Pro 模块强制清理工具，中文彩色交互界面。默认先隐藏输入设备密钥，
通过 SDK 查询模块名称、描述、运行状态和实际目录，备份后清理故障模块。

## 使用

从 [Releases](https://github.com/CedarXuesong/SKRootPro-module-force-clean/releases)
下载 `SKRootPro-module-force-clean.sh`。SDK 已静态链接到辅助程序并内嵌进 SH，
只需这一个文件，不用单独部署二进制。

```sh
su -c 'sh /sdcard/Download/SKRootPro-module-force-clean.sh'
```

电脑通过 ADB 使用：

```sh
adb push SKRootPro-module-force-clean.sh /data/local/tmp/
adb shell -t "su -c 'sh /data/local/tmp/SKRootPro-module-force-clean.sh'"
```

输入当前设备的 **48 位 SKP 密钥**，不会回显或保存。认证成功后：

| 选项 | 功能 |
| --- | --- |
| 1 | 查看并选择模块，显示名称、描述、运行状态、ID、实际目录 |
| 2 | 重新输入密钥 / 刷新列表 |
| 3 | 设置目录提示，用于不同 SDK 布局或未定位目录 |
| 4 | 预览清理范围 |
| 5 | 备份并强制清理，需输入“删除”确认 |
| 6 | 备份、清理并重启，需输入“删除”确认 |
| 0 | 退出 |

不包含任何特定模块 ID、设备序列号、设备密钥或特定设备的安装目录。
目录由输入密钥和 SDK 布局动态定位，并验证真实目录；目录无法定位时停止清理，
不会将空路径当作目标。不再提供 DFM 等特定模块的单独删除入口。

## 命令行

命令行也必须先隐藏输入密钥，只能选择 SDK 已安装列表中的模块：

```sh
# 仅预览
su -c 'sh SKRootPro-module-force-clean.sh --id MODULE_ID'
# 备份后清理
su -c 'sh SKRootPro-module-force-clean.sh --id MODULE_ID --apply'
# 清理成功后重启
su -c 'sh SKRootPro-module-force-clean.sh --id MODULE_ID --apply --reboot'
```

其他参数：`--module-root /data/NAME/modules`、`--legacy-id ID`、
`--color`、`--no-color`、`--help`、`--version`。
`--legacy-id` 只在显式提供时清理对应 `/data/adb` 兼容目录。

## 运行要求与清理方式

- AArch64 Android 10+，已运行且与参考 SDK 兼容的 SKRoot Pro 环境。
- 使用已授权的 `su` 启动；ADB 需要 `-t` 分配终端以隐藏密钥输入。
- 使用 Android 自带的 `sh`、`awk`、`base64`、`tar`、`sha256sum` 等工具。
- 单文件启动时，将经过 SHA-256 校验的内置程序释放到权限为 700 的独立临时目录，
  正常退出或处理可捕获的中断时移除。密钥仅由辅助程序读取，不进入 SH 变量、
  命令行参数、环境变量或临时文件。每次启动、刷新都重新输入。
- 备份与记录保存在 `/data/local/tmp/skp-module-backup-时间戳-PID/`。
  校验归档成功后才删除目标；拒绝目录穿越、符号链接、非规范路径及目标内的挂载点。
- 跳过故障模块的卸载回调。删除目录不能撤销当前启动中已加载的内核 Hook，
  **清理后需要重启**；默认不自动重启。
- 不清理未知模块的任意外部文件、配置、旧备份、下载包。多路径清理非事务，
  部分删除后失败时会停止，已完成的操作记录在备份目录。
- “通用”指不绑定某台设备或某个模块。当前实现依据参考 SDK 的目录规则生成候选路径，
  并逐个验证实际目录；不保证所有未来 SDK 版本、布局、内核或架构都兼容。

## 自行构建单文件 SH

需要 Python 3.9+、Android NDK（已验证 r29），以及上游公开的
[`kernel_module_kit` SDK](https://github.com/abcz316/SKRoot-linuxKernelRoot/tree/master/Pro(%E4%BC%97%E6%B5%8B%E5%BC%80%E6%94%BE%E4%B8%AD)/src/testModule/kernel_module_kit)。
SDK 未复制到本仓库，使用你本地的 SDK 路径：

```sh
python build.py --ndk /path/to/android-ndk --sdk /path/to/kernel_module_kit
```

也可设置 `ANDROID_NDK_HOME` 和 `SKP_SDK_ROOT` 后运行 `python build.py`。
构建脚本还会尝试从 `ANDROID_SDK_ROOT` / `ANDROID_HOME` 自动发现已安装 NDK。
支持 Windows、Linux 和 macOS 构建主机，输出：

```text
dist/SKRootPro-module-force-clean.sh          单文件成品
dist/SHA256SUMS.txt                          文件校验值
dist/SKRootPro-module-force-clean-v1.0.0.zip  发布包
dist/skp_module_query                       独立辅助程序（调试用）
```

仅重新打包现有二进制：`python build.py --helper /path/to/skp_module_query`。
辅助程序静态链接 SDK 与 C++ 运行库，使用标准 Android 系统库。
内置载荷使用固定时间戳的 tar/gzip 包装，同一源码与二进制可复现打包结果。

## 验证

`python -m unittest -v test_build.py` 验证内嵌载荷、校验值和打包可复现性。
`test_device.py` 在真实 Android PTY 中验证隐藏输入、认证、模块查询与预览，
不清理真实模块：

```sh
python test_device.py --adb /path/to/adb --serial DEVICE_SERIAL --script dist/SKRootPro-module-force-clean.sh
```

测试在电脑终端隐藏输入密钥，并通过 ADB 标准输入传给设备，不写入文件。
另有 `test_cleanup.sh` 使用模拟 SDK 与临时模块目录验证备份/删除/路径保护，
不会操作真实模块或重启设备。

项目使用了上游 SKRoot SDK，详见 [第三方说明](THIRD_PARTY_NOTICES.md)。

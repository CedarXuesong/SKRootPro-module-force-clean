# 第三方说明

本工具的辅助程序静态链接 **SKRoot Pro kernel_module_kit SDK**。
SDK 的原作者与维护者为上游项目，来源：

- 项目：https://github.com/abcz316/SKRoot-linuxKernelRoot
- SDK：`Pro(众测开放中)/src/testModule/kernel_module_kit`

SDK 本体未作为源代码或静态库复制到本仓库；自行构建时需要提供本地 SDK。
发布的单文件 SH 包含本工具及 SDK 静态链接的辅助程序。
上游组件及其依赖的版权、许可与使用条件以相应上游说明为准；本项目不宣称
拥有第三方 SDK 的版权，也不将本项目的代码授权解释为第三方组件的重新授权。

辅助程序还静态链接 Android NDK 的 LLVM libc++ 运行库；其许可为
Apache-2.0 WITH LLVM-exception，参见 Android NDK / LLVM 上游许可文件。
SDK 自身使用的 asmjit、civetweb 等组件亦受各自上游许可约束。

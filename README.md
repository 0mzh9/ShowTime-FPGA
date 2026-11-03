# 实时畸变矫正与虚拟视角控制系统

参赛题目：紫光赛道赛题二。包含 FPGA 工程与 ShowTime V15 上位机源码。

## 目录

- `FPGA_code/`：FPGA 工程、RTL、约束及原包 IP 文件。
- `上位机程序/源码/`：Python 上位机源码、依赖清单与打包脚本。
- `上位机程序/说明文档/`：操作、源码构建和通信说明。
- `上位机程序/licenses/`：第三方许可证，分发时保留。
- `firmware/`：原工程提供的 `.sbit` 位流。
- `reports/`：原工程提供的时序摘要及多种子记录。

## FPGA 工程

使用 Pango Design Suite/Fabric Compiler **2022.2-SP6.4（build 146967）** 打开 `FPGA_code/ShowTime.pds`。
工程目标器件为 **Logos2 PG2L100H，FBG676，速度等级 -6**；顶层为 `hdmi_ddr_ov5640_top`。
保留 source、ipcore 及约束的相对位置，运行编译、综合、布局布线和位流生成。
工程中的实现参数可参阅 `FPGA_code/impl.tcl`。编程时按实际板卡与下载工具配置操作。

## 上位机源码运行

原包记录的环境为 Windows x64、Python 3.13.12，依赖版本见 requirements.txt。
在 `上位机程序/源码` 中执行：

```powershell
py -3.13 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe viewer.py
```

连接兼容的 FPGA 固件、USB-UART 和 HDMI USB 采集卡后，在界面选择对应串口及采集设备。
支持双模式显示、畸变矫正对比、标定参数校验与保存，以及 720P 虚拟水平转向。
详细步骤见 `上位机程序/说明文档/01_使用说明.md`。

## 离线自检

在上述源码目录运行：

```powershell
.\.venv\Scripts\python.exe bootstrap_v15.py --self-test --report ..\source_selftest.json
```

该检查不连接板卡；硬件验收仍需使用实板。

## 便携程序与验证范围

原包 EXE 超过 GitHub 普通仓库单文件限制，因此未放入源码仓库。配套便携程序 ZIP 单独准备，用于 Release 下载附件，内含原始 EXE、源码和第三方声明。
本仓库由 2026-11-03 解压的新工程整理，保留源代码，移除 FPGA 编译缓存。
整理时检查了项目文件引用和 Python 语法；没有重新完成 FPGA 全流程编译或实板验证。reports 内为原包记录。

## 第三方内容

保留原包中的第三方版权和许可证声明。板卡示例、厂商 IP 及第三方库按各自授权使用；本仓库未另行授予统一开源许可证。

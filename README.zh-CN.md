# FlashPilot

**Agent 原生的 ECU 烧录——CAN、DoIP 和 LIN 上的 UDS，由声明式烧录计划驱动，为编码 agent 而生。**
专注且免授权费的 vFlash 替代品：一个无常驻进程的 CLI、确定性 JSON、永不撒谎的退出码，以及让 agent 自我诊断的失败证据。

[![CI](https://github.com/turinglambdaai/flashpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/flashpilot/actions/workflows/ci.yml) ![platform](https://img.shields.io/badge/platform-Windows_%7C_Linux-lightgrey) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[English](README.md) · **中文**

## 为什么做 FlashPilot？

今天的汽车烧录意味着 vFlash：昂贵的按席位授权、Windows GUI，以及 agent 无法驱动的 COM API 自动化。烧录知识本身——seed-key 算法、内存布局、时序——曾经是长期积累出来的护城河。AI 时代这条创作的成本坍塌了：agent 可以根据 OEM 规格书起草一份烧录计划。真正剩下的价值是**闭环**：生成计划 → 校验指纹 → 带电源/时序保护地烧录 → 失败时收集证据 → 重新生成。

FlashPilot 就是围绕这个闭环构建的。

- **声明式烧录计划** —— 每个 ECU 一份 JSON 文档：段（inline、BIN、Intel HEX、S-record）、会话、带可插拔 key provider 的 security access、erase/download/verify 流程、时序、恢复策略、电源保护、期望指纹。
- **真实传输层** —— SocketCAN（Linux）、PEAK PCAN（Windows）、DoIP（以太网）。底层是 ISO-TP（ISO 15765-2）；LIN 在计划中。
- **Agent 优先的 CLI** —— 确定性 JSON 输出、永不撒谎的退出码，以及失败证据（有界、带指纹、可审计），让 agent 无需人类打开厂商工具就能诊断并重试。
- **默认安全** —— 计划在任何驱动调用之前校验期望指纹；编程中的电源保护在电流越界时中止；破坏性操作会明说。

不是 CANoe 克隆：没有整车网络仿真、没有 CAPL、没有分析窗口合集。只把一个闭环诚实地做完。

## 状态

**v0.1.0 —— 核心引擎**：带 P2/P2\* 时序和 NRC 处理的 UDS（ISO 14229）、UDS 烧录工作流（session → security access → erase → download → verify → reset，每步留审计）、带恢复策略（retry / reset-and-retry）的声明式计划、镜像指纹门、编程中电源保护、DTC 读取/清除、Intel HEX + S-record + BIN 镜像模型、可插拔安全 provider（`command:<id>` 外部算法）、模拟 CAN 与 DoIP 上的 ISO-TP，以及一个内置模拟 ECU——整条闭环在 CI 里无需硬件即可跑通。

下一道门：LIN 上的 UDS、DoIP 以太网对真实 ECU 的加固，以及计划库。

## 快速开始

```bash
git clone https://github.com/turinglambdaai/flashpilot.git
cd flashpilot
raco pkg install --auto --name flashpilot --link racket
racket app/cli.rkt flash examples/plan.sim.json
```

默认传输层是内置模拟 ECU——整条烧录闭环无需硬件即可运行：

```json
{"ok":true,"bytes":300,"fingerprint":"…","steps":["diagnostic-session","security-access","erase","download","verify","ecu-reset"]}
```

对真实 ECU 走 DoIP：

```bash
racket app/cli.rkt flash plan.doip.json --transport doip --host 192.168.0.1
```

## CLI

| 命令 | 用途 |
|---|---|
| `flash <plan.json>` | 执行声明式烧录计划（指纹门、电源保护、恢复） |
| `verify <plan.json>` | 仅做计划与指纹检查——不接触 ECU |
| `dtc read \| clear` | 诊断故障码（UDS 0x19 / 0x14） |
| `request <hex>` | 单条原始 UDS 请求 |
| `udid <did>` | 读取 DID（22 XX XX） |

退出码：`0` 成功 · `1` 烧录/断言失败 · `2` 用法错误 · `3` 未找到 · `4` 传输层。

每条命令只输出一个 JSON 对象——camelCase 字段、稳定的命名、有界的错误文本——agent 解析输出永远不需要去刮屏幕。

## 烧录计划

```json
{
  "segments": [{ "address": "0x08000000", "file": "app.hex" }],
  "securityLevel": 1,
  "keyDeriver": "xor0x5a",
  "onFail": "resetAndRetry",
  "powerGuard": { "minMa": 5, "maxMa": 1500, "pollMs": 200 },
  "expectedFingerprint": "e3400821709d3e50"
}
```

- `onFail` —— `retry` 或 `resetAndRetry`（尽力复位 ECU，然后重试一次）。
- `powerGuard` —— 编程期间轮询台架电源；电流越界即断电中止。
- `expectedFingerprint` —— 锁定镜像；不匹配在任何驱动调用之前就被拒绝。

段支持 inline hex、`.bin` 文件或 Intel HEX / S-record 镜像（按连续区域解析为段）。内置算法之外的 seed-key 算法以外部命令接入：`"keyDeriver": "command:./my-oem-algo"`。

## 测试

内置模拟 ECU 在真实 ISO-TP/UDS 协议栈后面应答，无需硬件：

```bash
raco test racket/flashpilot
```

## 许可证

AGPL-3.0。

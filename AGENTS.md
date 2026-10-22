# AGENTS.md

FlashPilot——agent 原生的 ECU 烧录工具（UDS over CAN/DoIP/LIN，声明式 flash plan，确定性 JSON 与退出码），Racket 引擎 + Rivet 线原生壳。

## 结构

- `racket/` — Racket 引擎（`racket/flashpilot` collection，flash 核心/plan 模型）
- `app/` — 宿主入口（`backend.rkt` 引擎 RPC、`cli.rkt` 命令行）
- `macos-host/`、`windows/`、`linux/` — Rivet 三宿主腿（对应平台机器独占开发，验证跨腿走 CI）
- `site/` + `docs/` — 产品站（GitHub Pages）与用户手册
- `examples/` — flash plan 示例；`assets/`、`dist/`、`packaging` 产物相关

## 常用命令

```bash
# 引擎与入口（CI 同款）
raco pkg install --auto --name flashpilot --link racket
raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#de1fb8997539d34ba029064f500f6903b955b5a7'
raco make app/backend.rkt
raco make app/cli.rkt
raco test racket/flashpilot
raco rivet acceptance
```

## 验证与发版

- CI（`ci.yml`）：多平台 matrix 装 rivet pin → raco make 入口 → raco test 引擎。
- 产品验收（`acceptance.yml`）：三平台构建并打包原生 GUI，以系统无障碍接口点击“Validate bench”，验证 RVT1、模拟 ECU 与原生结果展示的完整链路。
- 站点（`pages.yml`）：`docs/guide.html` 拷入 `site/` 后部署 GitHub Pages。
- 发版（`release.yml`）：tag `v*` 触发多平台产物构建；CHANGELOG 按 Keep a Changelog 格式随发版更新。发版前产物必须本机实测（家族教训）。

## 仓库特定规矩

- rivet 以固定提交消费，禁止漂移到 tag/main；升级 pin 须同时更新 CI、验收和本文件，并通过三平台打包交互。
- 不得以 Racket/CLI 测试替代 GUI 交付证明；Windows、macOS、Linux 宿主都必须由 `raco rivet acceptance` 实际构建、打包并操作。
- BenchPilot（ECU 试验台运行时）已于 2026-10-17 删除，其历史 issue/PR 与本产品无关，勿混淆。
- 站点 `site/` 为生成+手维护混合，改 guide 先改 `docs/` 再按 pages.yml 流程同步。

## 组合定位（Portfolio placement）

- 轨道与授权：轨道 1 商业支柱（B2B 专业工具）；授权形态：AGPL-3.0；商业归属：适合收费（收费节奏第三棒）。
- 组合归属唯一权威：[PORTFOLIO.md](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)（turinglambdaai.github.io 仓库）。改归属/授权先改权威档，再同步本节。
- 纪律：价格只进本仓 `PRICING.md`，且收费开始时才发布；README 与产品站不做价格预告。

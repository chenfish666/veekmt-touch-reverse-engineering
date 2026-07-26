# Reverse-Engineering an Undocumented I2C Touch Controller on FPGA

**從零逆向一顆無文件觸控晶片：DE2-115 + VEEK-MT 電容觸控 I2C 驅動實錄（24 個版本）**

> Every normal path was locked: the reference driver file was corrupted, the vendor IP was encrypted, the license had expired, and the working bitstream could not be decompiled. So I reverse-engineered the touch controller's I2C protocol from scratch — using only free tools (Quartus + its built-in SignalTap logic analyzer), falsifiable hypotheses, and 24 incremental hardware-tested versions — until a hand-written Verilog I2C master could read real coordinates from the panel.

![demo](demo.gif)

---

## English Summary

**Hardware:** Terasic DE2-115 (Cyclone IV EP4CE115F29, 50 MHz) + VEEK-MT 800×480 capacitive touch module (Cypress CY8CTMG120-56 PSoC, running Terasic's *custom* firmware — not stock TrueTouch).

**The problem:** No usable driver, no usable documentation. The provided reference file was corrupt, the official IP core was encrypted with an expired license, and the only known-working bitstream lives in flash and cannot be decompiled.

**What I did:** Wrote a Verilog I2C master from scratch and reverse-engineered the chip's protocol through 24 versioned, hypothesis-driven builds, observing results only through the board's switches, seven-segment displays, and LEDs (no console exists on bare-metal FPGA), plus SignalTap waveform captures.

**Key findings** (full details in the [reverse-engineered interface spec](docs/觸控晶片_I2C介面規格書_逆向工程版.md)):

| Finding | Value |
|---|---|
| Real 7-bit I2C address | **0x08** (documentation claimed 0x24 — measurement beat the docs) |
| Required bus speed | **~1 kHz** (100 kHz standard speed fails on this panel) |
| SCL | must be **open-drain** with **clock-stretching** support — the chip actively holds SCL low (this single issue caused 18 failed versions) |
| Read protocol | pointer-read (write register pointer 0x00 first) + per-read handshake (`rx0 ^ 0x80` written back) |
| Coordinates | big-endian: `X = {rx3, rx4}`, `Y = {rx5, rx6}` |
| Finger presence | the **INT line**, not coordinate changes (the chip latches the last coordinate after release) |
| Debounce | retriggerable one-shot (~150 ms) — symmetric debounce never asserts on this noisy panel |

The official Cypress cyttsp gen3 boot sequence turned out to be a **dead end** for this custom firmware; only the coordinate register layout coincidentally matches gen3.

---

## 這個 repo 有什麼

| 路徑 | 內容 |
|---|---|
| [`docs/觸控螢幕從零到成功的工程之旅.md`](docs/觸控螢幕從零到成功的工程之旅.md) | **完整除錯敘事**：v1→v24 每一版的假設、實驗、結果與轉折（含 SDA/SCL 競態、cyttsp 死路、位址掃描、時脈延伸轉捩點、握手機制、座標破解），附名詞辭典與各版本 SW/HEX/LEDG 對照表 |
| [`docs/觸控晶片_I2C介面規格書_逆向工程版.md`](docs/觸控晶片_I2C介面規格書_逆向工程版.md) | **逆向工程版介面規格書**（datasheet 式）：暫存器對照、座標解碼公式、四角實測測試向量、語言無關驅動序列、11 步最小實作清單——每條規格標注可信度（✅實測／🔶推測／❔未知） |
| [`rtl/`](rtl/) | Verilog 原始碼：手刻 I2C master 觸控驅動與手指偵測模組 |

## 戰績統計（來自真實紀錄）

- **24** 個驅動版本，每版對應一個可證偽的假設
- **60** 次 bitstream 燒錄下載（同一條 scp 指令的 shell history 為證）
- 單一 terminal session 連續開了 **3 天 6 小時**
- 外部工具成本：**NT$0**（無邏輯分析儀、無外接電阻——SignalTap + 推理）

## 方法論

1. **量測勝過文件**：交接文件寫位址 0x24，親手掃描量到的是 0x08——相信量到的。
2. **可證偽假設**：每一版只測一個假設，用板上 SW/HEX/LEDG 讓結果可觀察。
3. **對死路誠實**：整套官方 cyttsp 開機序列判死、外接上拉電阻的建議被實驗推翻——都記錄在案，不粉飾。
4. **免費工具原則**：用推理和內建工具補足設備的不足。

## AI 協作聲明 / AI Collaboration Disclosure

本專案由 **本人主導、與 AI（Anthropic Claude）協作**完成：AI 參與假設生成、Verilog 撰寫與波形分析；**所有硬體實驗、量測、觀察回報與最終驗證均由本人在實體板卡上親手執行**，並多次以實測結果修正 AI 的錯誤判斷（例如外接上拉電阻假說、cyttsp 開機序列路線）。完整的人機協作過程如實記錄於除錯敘事中。

This project was human-directed with AI assistance (Anthropic Claude) for hypothesis generation, Verilog drafting, and waveform analysis. All physical experiments, measurements, and final verification were performed by the author on real hardware; several AI hypotheses were overturned by measurement, as documented.

## 授權與智慧財產聲明 / License & IP Notice

- 本 repo 內容（Verilog 原始碼、文件、量測數據）均為作者原創，採 [MIT License](LICENSE) 授權。
- 本專案為**教育與互通性目的之獨立逆向工程**：透過觀察匯流排外部行為重建協定，**不含**任何 Terasic 加密 IP、原廠韌體、廠商手冊內容或第三方 bitstream。
- This is independent, interoperability-oriented reverse engineering based on external bus observation. No proprietary vendor files are included.

---

*Hardware: Terasic DE2-115 · VEEK-MT · Quartus (SignalTap) · 純 Verilog，無 NIOS、無外部 MCU*

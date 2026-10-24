# exam-hint-toolkit

Windows 上的「屏幕取题 → OCR → 云端作答 → 悬浮答案框」小工具，用 PowerShell 5.1 写成，纯本地运行，不注入、不改动任何第三方程序。

## 组成

| 文件 | 作用 |
|---|---|
| `exam-live.ps1` | 主程序：热键轮询、抓图相位、答案悬浮窗、分页、手动输入框 |
| `capture.ps1` | GDI 屏幕抓图（可缩放、可裁剪） |
| `ocr.ps1` | 调用 Windows 自带 WinRT OCR（zh-Hans-CN，离线），带中文空格/拆字噪声还原 |
| `solve.ps1` | 调用 DeepSeek Chat Completions 出答案（也支持 ollama / echo 调试） |
| `watch-live.ps1` | 看门狗：浮层进程消失后 4 秒内自动拉起 |
| `start-live.vbs` | 无控制台窗口启动（双击即可） |
| `boot-live.cmd` | 一键拉起看门狗（浮层由看门狗负责起） |
| `mock-exam.ps1` | 本地假考题页，用来验证整条链路 |
| `hostile-full.ps1` | 全屏 + 置顶 + 每 300ms 重新抢置顶的“对手窗口”，用于验证悬浮层级 |
| `selftest.ps1` / `netcheck.ps1` / `snapshot-watch.ps1` | 自检、网络检查、抓拍相位观察 |
| `keymon.ps1` | 按键监视器：排查“热键没反应”到底是键没到还是程序没收到 |

## 关键设计

1. **悬浮层级**：普通置顶窗口抢不过会周期性重新置顶的全屏窗口（实测 100% 被压下去）。这里用 `SetWindowLongPtr(GWLP_HWNDPARENT)` 把答案框挂成当前前台全屏窗口的 **owned window**，owned 窗口在系统层面永远画在宿主之上，不参与置顶竞争。
2. **抓拍相位**：根据客户端日志里 `offScreenCapture` 的时间戳推算抓拍周期，答案框在抓拍前 `GuardSec` 秒自动隐藏，避免出现在对方截图里。
3. **不被截屏**：`SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)`，本机验证过：开启后本进程抓不到自己的框。
4. **热键**：用 `GetAsyncKeyState` 轮询而不是 `WH_KEYBOARD_LL` 钩子——钩子会被别的程序抢走，轮询不会。
5. **兜底**：`-Auto N` 每 N 秒自动抓一次，完全不依赖按键；单实例互斥防止重复弹窗；看门狗 4 秒自愈。

## 用法

```powershell
# 常规启动（无窗口）
wscript.exe start-live.vbs

# 手动启动，带参数
powershell -File exam-live.ps1 -Hotkey f9 -Provider deepseek -Auto 30 -FontSize 9 -MaxWidth 300

# 自检 / 相位 / 演示
powershell -File exam-live.ps1 -Check
powershell -File exam-live.ps1 -SnapInfo
powershell -File exam-live.ps1 -Demo -Theme dark -NoWDA
```

热键：

| 键 | 作用 |
|---|---|
| `F9` | 抓图 → OCR → 作答 → 显示（分页时再按翻下一页） |
| `F7` | 把剪贴板内容当题目（自己选中复制，比 OCR 准） |
| `F8` | 手动输入题目 |
| 鼠标中键 | 与 F9 同（键盘被前台程序吃掉时的兜底） |
| `Ctrl+Alt+V` | 看上次 OCR 原文 |
| `Ctrl+Alt+Z` / `Ctrl+Alt+Q` | 紧急隐藏 / 重显上次答案 |
| `Ctrl+Alt+方向键` | 移动答案框 |
| `Ctrl+Alt+=` / `Ctrl+Alt+-` | 字号增减 |
| `Ctrl+Alt+W` / `Ctrl+Alt+S` | 宽度增减 |

## 归档

每次出答案都会把「时间 + 题干原文 + 答案」追加到 `archive\YYYY-MM-DD.txt`（不覆盖）。F7（剪贴板题干）和 F8（手打题干）同样入档，跑一次就是一份带原文的题库。

## 依赖

- Windows 10/11，PowerShell 5.1
- 系统自带简体中文 OCR 语言包（`Windows.Media.Ocr`）
- DeepSeek API Key：环境变量 `DEEPSEEK_API_KEY`，或 `%APPDATA%\dsh-desktop\harness\.credentials.yaml` 里的同名项

## 实测数据（1536×960 / i5-12450U）

| 阶段 | 平均 | 中位 | P90 | 最大 |
|---|---|---|---|---|
| 抓图 | 2.95 s | 2.9 s | 3.2 s | 5.0 s |
| OCR | 1.07 s | 1.0 s | 1.2 s | 2.5 s |
| 解题 | 1.21 s | 1.2 s | 1.5 s | 1.8 s |
| 合计 | ≈5.2 s/题 | | | |

瓶颈在抓图（占 57%）。想更快：只抓题目区域、`-Scale 1.0`、或用 DXGI Desktop Duplication 替代 GDI。

## 已知限制

- OCR 对小字号中文不稳：`B` 可能被认成 `&`、`法` 被拆成 `氵去`、`可以避免不可重复读` 会掉字。脚本里做了常见拆字还原，但仍会出错；选择题偶发选错就是这个原因。
- 抓的是**当前屏幕**：目标窗口必须在前台，否则截到的是别的窗口。
- 硬件加速/独占渲染的窗口可能抓不到画面（本工具用 GDI，遇到就抓不到内容）。
- 只在单显示器、100% 缩放下验证过；多屏/高 DPI 需要自行调整。

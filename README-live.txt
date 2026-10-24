考试助手 · 使用说明（实战版）
================================

一、开考前（必须做完，锁屏后补不了）
------------------------------------
1. 双击 start-live.vbs
   （热键已默认 f9；想换就右键编辑它改 HOTKEY）
2. 按一次 F9（热键已默认设成 F9）
   → 等约 5 秒，答案在屏幕右上角出现 3 秒后自动消失
   → 只看到一闪，就说明整条链路通了
3. 查相位：
   powershell -File exam-live.ps1 -SnapInfo
   看 period（本场抓拍周期）和 距离下次（多少秒后抓拍）
4. 关掉 v2rayN 系统代理：
   Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0
5. 自检（可选，30 秒）：
   powershell -File selftest.ps1
   全 PASS 才进考场


二、场中操作
------------
F9                        取题（算完才显示，中间屏幕无变化；显示 3 秒后自动隐藏）
Ctrl+Alt+Z                紧急隐藏（任何时刻有效）
Ctrl+Alt+Q                手动显示/隐藏上一次的答案
Ctrl+Alt+方向键            挪浮层位置
Ctrl+Alt+ + / -           字号
Ctrl+Alt+W / S            宽度增减
画面：白底深灰字的小方块（约 80×36，字号 14），贴在右上角页面边距（右 24px、上 96px），显示 3 秒自动隐藏，对截图/录屏不可见


三、节奏（重要）
----------------
· 抓拍周期由本场决定（见过 66.9s，也见过 89.2s），脚本自己测
· 距下一次抓拍 ≤4 秒时，按了也不会显示（脚本自动跳过）
· 显示中一旦进入最后 4 秒，会立刻强制隐藏
· 建议：抓拍刚过去 5 秒再按，最安全
· 浮层对截图/录屏不可见（WDA_EXCLUDEFROMCAPTURE），但手机/摄像头拍屏幕防不了


四、出问题怎么读
----------------
显示「无题目」            OCR 没抓到题干（页面没画完 / 被别的窗口挡住），等 1 秒再按
显示「出错: ...」          看 %TEMP%\exam-q.txt（OCR 原文）与 answers.txt
显示「云端失败(...)；本地也失败(...)」 网络被掐且没装本地模型
按了没反应                热键被占用或脚本没起；先 Ctrl+Alt+Q 试，再重启 start-live.vbs


五、收尾
--------
1. 交卷后 Ctrl+Alt+Z 隐藏，任务管理器结束 powershell.exe
2. 清痕迹：
   Remove-Item "$env:TEMP\exam-shot.png","$env:TEMP\exam-q.txt" -Force
   Remove-Item .\answers.txt -Force
3. 想回滚所有改动：本目录只读不写系统，删掉整个 exam-kit 即可


六、文件说明
------------
exam-live.ps1     主控（浮层+热键+相位守护+自动降级）
capture.ps1       截图（全屏/窗口/裁剪）
ocr.ps1           Windows 本地 OCR（zh-Hans-CN），中文空格归一化
solve.ps1         答题（deepseek 云端 / ollama 本地）
snapshot-watch.ps1 从 CEF 日志还原抓拍节奏
selftest.ps1      开考前自检
start-live.vbs    无窗口启动器（双击即可）
answers.txt       当前答案（浮层读它）

════════════════════════════════════
补丁 2026-10-24 12:52：答案框"压住全屏考试面板"已实测通过
════════════════════════════════════
问题：考试客户端是全屏 + 置顶，而且会周期性重新抢置顶。
      实测：普通"置顶窗口"在对手每 300ms 抢一次置顶时，100% 被压到下面（用户肉眼确认看不到）。

修复：显示答案时，把答案框挂成"当前全屏窗口的附属窗口"（owned window）。
      附属窗口在系统层面永远画在宿主之上，不需要抢置顶，也不怕对手刷新置顶。

实测结果（12:52）：
  - 对手窗口 1536x960 全屏置顶 + 每 300ms 重新置顶
  - 日志：attached=True owner=<对手窗口句柄>
  - 用户肉眼确认：黑底白字的答案框稳定浮在白色全屏页面上（此前同条件看不到）
  - 链路：F9 -> capture 2.9s -> ocr 0.8s -> solve 1.1s -> SHOWN

行为说明：
  - 每次显示答案自动挂接；隐藏答案（3 秒自动 / Ctrl+Alt+Z）时自动解除。
  - 只有"显示答案"的那几秒是附属关系，其余时间仍是普通置顶窗口。
  - 若挂接失败（找不到宿主、宿主是桌面等），自动退回普通置顶，不报错、不中断。
  - 已知副作用：如果考试客户端窗口被销毁/重建，答案框会跟着消失；
    看门狗 4 秒内自动拉起（2026-10-24 已把巡检从 8s 调到 4s）。

逃生开关：
  powershell -File exam-live.ps1 -NoChild     # 完全关掉挂接，回到纯置顶
  powershell -File exam-live.ps1 -ForceChild  # 强制挂接（默认已是自动挂接）

重启整套（浮层 + 看门狗，脱离当前终端）：
  schtasks /run /tn exam-live-boot
  或直接双击 boot-live.cmd
停止：
  New-Item "C:\Users\13769\AppData\Local\Temp\live-off.flag" -ItemType File -Force
  然后结束 exam-live / watch-live 的 powershell 进程
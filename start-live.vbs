' Start exam-live.ps1 with no console window (nothing appears in taskbar either).
' Edit HOTKEY / PROVIDER below, then just double-click this file.
Dim sh, fso, dir, script, args
HOTKEY   = "f9"
PROVIDER = "deepseek"
EXTRA    = "-Auto 30 -Brief -MaxWidth 300 -FontSize 9 -TextColor gray -PageChars 60 -FullWidth 360"

Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
script = dir & "\exam-live.ps1"

args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """ -Hotkey " & HOTKEY & " -Provider " & PROVIDER
If EXTRA <> "" Then args = args & " " & EXTRA

Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe " & args, 0, False

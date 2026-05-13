#Requires AutoHotkey v2.0
#SingleInstance Force

; ==============================================================================
; 1. 全局配置与变量初始化
; ==============================================================================
; 💡 1. 优先指定你的本地共享 DLL 路径
global sharedDllPath := "G:\115-Desktop\_internal\libmpv-2.dll"
global localDllPath  := A_ScriptDir "\libmpv-2.dll"
global dllPath       := ""
global mpvHandle     := 0
global hModule       := 0
global MyGui         := 0
global currentFileName := ""

; 💡 2. 智能检索路径逻辑：如果共享路径有 DLL 就用共享的，否则检查本地同级目录
if FileExist(sharedDllPath) {
    dllPath := sharedDllPath
} else if FileExist(localDllPath) {
    dllPath := localDllPath
} else {
    ; 两个地方都没有，才弹出错误提示
    MsgBox "错误：找不到播放内核 libmpv-2.dll`n请检查以下路径之一是否存有该文件：`n1. " sharedDllPath "`n2. " localDllPath
    ExitApp
}

; 缓存最后一次的GUI标题，避免不必要的更新
global lastGuiTitle := ""

; ==============================================================================
; 2. 创建并显示 GUI 窗口
; ==============================================================================
; 💡 修复：使用物理数值 +0x8 (CS_DBLCLKS) 开启窗口双击响应，彻底解决 Invalid option 报错
MyGui := Gui("+ReSize +0x8", "TINY AHK PLAYER | author: JacPas")
MyGui.BackColor := "Black"
MyGui.OnEvent("Close", Cleanup)

; 绑定文件拖拽事件
MyGui.OnEvent("DropFiles", OnGuiDropFiles)

; 绑定左键双击窗口事件 (0x0203 是 WM_LBUTTONDBLCLK)
OnMessage(0x0203, OnGuiClick)

MyGui.Show("w1280 h720")

; ==============================================================================
; 3. 文件获取与播放核心逻辑
; ==============================================================================

; 拖拽文件时触发的函数 —— 全程永久可用，不屏蔽
OnGuiDropFiles(guiObj, ctrlObj, fileArray, x, y) {
    videoFile := fileArray[1]
    StartMpvPlayer(videoFile)
}

; 双击窗口时触发的函数
OnGuiClick(wParam, lParam, msg, hwnd) {
    ; 关键：已经有播放器实例(正在播放)，直接拦截，不响应窗口双击
    if (mpvHandle)
        return
    if (hwnd != MyGui.Hwnd)
        return

    ; 未播放状态才允许双击选文件
    videoFile := FileSelect("3", A_ScriptDir, "选择视频文件", "视频 (*.mp4;*.mkv;*.avi;*.mov;*.flv;*.wmv;*.webm)")
    if (videoFile == "")
        return

    StartMpvPlayer(videoFile)
}

; 播放函数
StartMpvPlayer(videoFile) {
    global hModule, mpvHandle, currentFileName

    ; 提取路径中的纯文件名
    SplitPath videoFile, &fname

    ; ======================================================================
    ; 💡 核心修改：限制文件名长度为 60 个字符
    currentFileName := StrLen(fname) > 60 ? SubStr(fname, 1, 60) "..." : fname
    ; ========================================================================

    ; 1. 如果播放器已经初始化，直接热重载新视频
    if (mpvHandle) {
        MpvCommand(mpvHandle, ["loadfile", videoFile])
        SetTimer(UpdateGuiTitle, 250)
        return
    }

    ; 2. 首次播放时，走完整的初始化流程
    hModule := DllCall("LoadLibrary", "Str", dllPath, "Ptr")
    if (!hModule) {
        MsgBox("无法加载 DLL，请检查路径或依赖项。错误码: " A_LastError)
        ExitApp()
    }

    mpvHandle := DllCall(dllPath "\mpv_create", "Ptr")
    if (!mpvHandle) {
        MsgBox("无法创建 mpv 实例。")
        ExitApp()
    }

    vWid := MyGui.Hwnd
    pWid := Buffer(8)
    NumPut("Int64", vWid, pWid)
    DllCall(dllPath "\mpv_set_option", "Ptr", mpvHandle, "AStr", "wid", "Int", 4, "Ptr", pWid)

    ; 检查初始化返回值
    initResult := DllCall(dllPath "\mpv_initialize", "Ptr", mpvHandle, "Int")
    if (initResult < 0) {
        MsgBox("mpv 初始化失败，错误码: " initResult)
        ExitApp()
    }

    ; 首次播放视频
    MpvCommand(mpvHandle, ["loadfile", videoFile])

    SetTimer(UpdateGuiTitle, 250)
}

; ─── 辅助函数：将秒数转换为 HH:MM:SS 格式 ───
FormatTimeString(secondsStr) {
    if (secondsStr == "")
        return "00:00:00"

    totalSeconds := Integer(Number(secondsStr))
    hours   := totalSeconds // 3600
    minutes := Mod(totalSeconds // 60, 60)
    secs    := Mod(totalSeconds, 60)

    return Format("{:02d}:{:02d}:{:02d}", hours, minutes, secs)
}

; 💡 优化后的定时器函数：缓存标题，只在内容改变时更新
UpdateGuiTitle() {
    global mpvHandle, currentFileName, dllPath, lastGuiTitle

    if (!mpvHandle) {
        SetTimer(, 0)
        return
    }

    ; 从 mpv 获取原始数据（秒数数字）
    percentStr  := MpvGetPropertyString(mpvHandle, "percent-pos")
    timeSecStr  := MpvGetPropertyString(mpvHandle, "time-pos")   ; 当前播放秒数
    lengthSecStr := MpvGetPropertyString(mpvHandle, "duration")   ; 总时长秒数
    volumeStr   := MpvGetPropertyString(mpvHandle, "volume")

    ; 格式化基础数据
    percentNum := percentStr != "" ? Number(percentStr) : 0
    percent    := percentStr != "" ? Round(percentNum) "%" : "0%"
    volume     := volumeStr != "" ? Round(Number(volumeStr)) : "100"

    ; 转换时间格式
    timePos  := FormatTimeString(timeSecStr)
    duration := FormatTimeString(lengthSecStr)

    ; ─── 优化：只在百分比改变时重新生成进度条 ───
    static lastPercent := -1
    static cachedProgressBar := ""

    if (Round(percentNum) != lastPercent) {
        lastPercent := Round(percentNum)
        barLength := 50
        filledLength := Round((percentNum / 100) * barLength)
        unfilledLength := barLength - filledLength
        filledLength := Max(0, Min(filledLength, barLength))
        unfilledLength := barLength - filledLength

        progressBar := ""
        loop filledLength
            progressBar .= "■"
        loop unfilledLength
            progressBar .= "□"
        cachedProgressBar := progressBar
    } else {
        ; 进度条不变，直接使用缓存
        progressBar := cachedProgressBar
    }

    newTitle := currentFileName " | " progressBar " " percent " | [" timePos "/" duration "] - 🔊 " volume "%"

    ; 💡 优化：只在标题实际改变时更新 GUI
    if (newTitle != lastGuiTitle) {
        MyGui.Title := newTitle
        lastGuiTitle := newTitle
    }
}


; ==============================================================================
; 4. 快捷键控制
; ==============================================================================
; 辅助函数：检查是否可以响应快捷键
IsPlayerActive() {
    global MyGui, mpvHandle
    return (IsSet(MyGui) && MyGui && WinActive("ahk_id " . MyGui.Hwnd) && mpvHandle)
}

; 辅助函数：检查鼠标是否在程序 GUI 内
IsMouseInGui() {
    global MyGui
    if (!IsSet(MyGui) || !MyGui)
        return false

    MouseGetPos(&x, &y, &hwnd)
    while (hwnd) {
        if (hwnd = MyGui.Hwnd)
            return true
        hwnd := DllCall("GetParent", "Ptr", hwnd, "Ptr")
    }
    return false
}

#HotIf IsPlayerActive() && IsMouseInGui()

; --- 键盘快捷键 ---
Space:: MpvCommand(mpvHandle, ["cycle", "pause"])      ; 暂停/播放
Left::  MpvCommand(mpvHandle, ["seek", "-5"])         ; 后退5秒
Right:: MpvCommand(mpvHandle, ["seek", "5"])          ; 前进5秒
Up::    MpvCommand(mpvHandle, ["add", "volume", "5"])  ; 音量 +
Down::  MpvCommand(mpvHandle, ["add", "volume", "-5"]) ; 音量 -
Esc::   Cleanup()                                     ; 退出清理
Enter::       ToggleFullScreen()                      ; 回车切换全屏
NumpadEnter:: ToggleFullScreen()                      ; 小键盘回车切换全屏

; --- 鼠标快捷键 ---
MButton::   MpvCommand(mpvHandle, ["cycle-values", "video-zoom", "0", "0.333"])
WheelUp::   MpvCommand(mpvHandle, ["add", "volume", "5"])   ; 滚轮上：音量 +
WheelDown:: MpvCommand(mpvHandle, ["add", "volume", "-5"])  ; 滚轮下：音量 -
XButton1::  MpvCommand(mpvHandle, ["seek", "5"])     ; 侧前键：后退
XButton2::  MpvCommand(mpvHandle, ["seek", "-5"])      ; 侧后键：前进
RButton::   MpvCommand(mpvHandle, ["cycle", "pause"])  ; 右键暂停

; 鼠标左键：双击全屏
~LButton:: {
    if (A_PriorHotkey = "~LButton" && A_TimeSincePriorHotkey < 400) {
        ToggleFullScreen()
    }
}

#HotIf

; --- 提取的公共函数 ---
ToggleFullScreen() {
    global MyGui
    static isFull := false
    isFull := !isFull
    if (isFull) {
        MyGui.Opt("+AlwaysOnTop -Caption")
        MyGui.Maximize()
    } else {
        MyGui.Opt("-AlwaysOnTop +Caption")
        MyGui.Restore()
    }
}

; ==============================================================================
; 5. 核心功能函数 (处理全局变量和编码)
; ==============================================================================

MpvGetPropertyString(handle, propertyName) {
    global dllPath
    if (!handle)
        return ""

    retPtr := DllCall(dllPath "\mpv_get_property_string", "Ptr", handle, "AStr", propertyName, "Ptr")
    if (!retPtr)
        return ""

    result := StrGet(retPtr, "UTF-8")
    DllCall(dllPath "\mpv_free", "Ptr", retPtr)
    return result
}

Cleanup(*) {
    global mpvHandle, hModule, dllPath
    SetTimer(UpdateGuiTitle, 0)

    if (mpvHandle && hModule) {
        DllCall("GetProcAddress", "Ptr", hModule, "AStr", "mpv_terminate", "Ptr")
        && DllCall(dllPath "\mpv_terminate", "Ptr", mpvHandle)
        mpvHandle := 0
    }
    if (hModule) {
        DllCall("FreeLibrary", "Ptr", hModule)
        hModule := 0
    }
    ExitApp()
}

MpvCommand(handle, args) {
    global dllPath, hModule
    if (!handle || !hModule)
        return

    arrPtr := Buffer(A_PtrSize * (args.Length + 1), 0)
    static _keepAlive := []
    _keepAlive := []

    loop args.Length {
        arg := String(args[A_Index])
        buf := Buffer(StrPut(arg, "UTF-8"))
        StrPut(arg, buf, "UTF-8")
        _keepAlive.Push(buf)
        NumPut("Ptr", buf.Ptr, arrPtr, (A_Index - 1) * A_PtrSize)
    }

    return DllCall(dllPath "\mpv_command", "Ptr", handle, "Ptr", arrPtr.Ptr, "Int")
}

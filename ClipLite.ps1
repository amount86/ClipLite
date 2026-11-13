#requires -Version 5.1
<#
ClipLite v0.7.4 - text clipboard history for Windows PowerShell 5.1
No external modules, packages, EXE compilation, or persistent clipboard history.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AppVersion = 'v0.7.4'
$script:BaseDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:BaseDirectory 'config.json'
$script:TemplatesPath = Join-Path $script:BaseDirectory 'templates.json'
$script:UiStatePath = Join-Path $script:BaseDirectory 'ui-state.json'
$script:History = New-Object System.Collections.ArrayList
$script:FilteredItems = @()
$script:Templates = New-Object System.Collections.ArrayList
$script:IsPaused = $false
$script:IsExiting = $false
$script:IsModalOpen = $false
$script:IsHidingInternally = $false
$script:LastSelectedTab = 0
$script:PreviousForegroundWindow = [IntPtr]::Zero
$script:PreviousFocusWindow = [IntPtr]::Zero
$script:SuppressText = $null
$script:Mutex = $null
$script:OwnsMutex = $false
$script:CtrlHook = $null
$script:MessageWindow = $null
$script:NotifyIcon = $null
$script:LogPath = Join-Path $script:BaseDirectory 'ClipLite-startup.log'
$script:ShortcutKeys = '1234567890abcdefghijklmnopqrstuvwxyz'

# ---- 配色 ----
$script:Theme = @{
    Back        = [System.Drawing.Color]::FromArgb(32, 32, 36)
    Panel       = [System.Drawing.Color]::FromArgb(44, 44, 50)
    Border      = [System.Drawing.Color]::FromArgb(90, 90, 100)
    Text        = [System.Drawing.Color]::FromArgb(230, 230, 230)
    SubText     = [System.Drawing.Color]::FromArgb(150, 150, 160)
    Key         = [System.Drawing.Color]::FromArgb(120, 190, 255)
    SelBack     = [System.Drawing.Color]::FromArgb(0, 110, 200)
    SelText     = [System.Drawing.Color]::White
    TabActive   = [System.Drawing.Color]::FromArgb(0, 110, 200)
    TabInactive = [System.Drawing.Color]::FromArgb(55, 55, 62)
    Input       = [System.Drawing.Color]::FromArgb(24, 24, 28)
    Hover       = [System.Drawing.Color]::FromArgb(70, 70, 80)
    ErrorText   = [System.Drawing.Color]::FromArgb(255, 170, 150)
}

$script:DarkTheme = $script:Theme
$script:LightTheme = @{
    Back = [Drawing.Color]::White
    Panel = [Drawing.Color]::FromArgb(243,245,248)
    Border = [Drawing.Color]::FromArgb(160,168,180)
    Text = [Drawing.Color]::FromArgb(32,36,42)
    SubText = [Drawing.Color]::FromArgb(72,82,96)
    Key = [Drawing.Color]::FromArgb(12,83,150)
    SelBack = $script:DarkTheme.SelBack
    SelText = [Drawing.Color]::White
    TabActive = $script:DarkTheme.TabActive
    TabInactive = [Drawing.Color]::FromArgb(232,236,241)
    Input = [Drawing.Color]::White
    Hover = [Drawing.Color]::FromArgb(212,224,238)
    ErrorText = [Drawing.Color]::FromArgb(163,37,35)
}
$script:ThemeMode = 'System'
$script:FocusTimer = $null

function Get-PreferredPalette {
    if ($script:ThemeMode -eq 'Dark') { return $script:DarkTheme }
    if ($script:ThemeMode -eq 'System') {
        $light = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue
        if ($null -ne $light -and $light -eq 0) { return $script:DarkTheme }
    }
    return $script:LightTheme
}

function Write-StartupLog([string]$Message) {
    try {
        $line = ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f [DateTime]::Now, $Message)
        [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Write-AtomicUtf8([string]$Path, [string]$Text) {
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Assert-Config($Config) {
    foreach ($rule in @(
        @('MaxHistory', 1, 1000), @('MaxTextLength', 1, 100000),
        @('PreviewLength', 20, 500), @('DoubleCtrlThresholdMs', 100, 1500)
    )) {
        $property = $Config.PSObject.Properties[$rule[0]]
        if ($null -eq $property -and $rule[0] -eq 'DoubleCtrlThresholdMs') { continue }
        if ($null -eq $property -or $property.Value -isnot [ValueType] -or
            $property.Value -is [bool] -or $property.Value -lt $rule[1] -or
            $property.Value -gt $rule[2] -or $property.Value -ne [Math]::Truncate([double]$property.Value)) {
            throw ('config.json: ' + $rule[0] + ' は ' + $rule[1] + '～' + $rule[2] + ' の整数にしてください。')
        }
    }
    foreach ($name in @('IgnoreDuplicate', 'IgnoreWhitespaceOnly', 'AutoPaste')) {
        $property = $Config.PSObject.Properties[$name]
        if ($null -eq $property -and $name -eq 'AutoPaste') { continue }
        if ($null -eq $property -or $property.Value -isnot [bool]) { throw ('config.json: ' + $name + ' は true / false にしてください。') }
    }
    if ($null -eq $Config.PSObject.Properties['Window']) { throw 'config.json: Window が必要です。' }
    foreach ($name in @('Width', 'Height')) {
        $property = $Config.Window.PSObject.Properties[$name]
        $minimum = if ($name -eq 'Width') { 320 } else { 240 }
        if ($null -eq $property -or $property.Value -isnot [ValueType] -or $property.Value -is [bool] -or
            $property.Value -lt $minimum -or $property.Value -gt 3000 -or
            $property.Value -ne [Math]::Truncate([double]$property.Value)) { throw ('config.json: Window.' + $name + ' が範囲外です。') }
    }
    if ($null -eq $Config.Window.PSObject.Properties['TopMost'] -or $Config.Window.TopMost -isnot [bool]) { throw 'config.json: Window.TopMost は true / false にしてください。' }
}

function Show-Error([string]$Message) {
    $script:IsModalOpen = $true
    try {
        [System.Windows.Forms.MessageBox]::Show(
            $Message, 'ClipLite',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally { $script:IsModalOpen = $false }
}

try {
    $createdNew = $false
    $script:Mutex = [System.Threading.Mutex]::new($true, 'Local\ClipLite.PowerShell.ClipboardHistory', [ref]$createdNew)
    $script:OwnsMutex = $createdNew
    if (-not $createdNew) { exit 0 }

    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Copy-Item -LiteralPath (Join-Path $script:BaseDirectory 'config.example.json') -Destination $script:ConfigPath -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $script:TemplatesPath)) {
        $samplePath = Join-Path $script:BaseDirectory 'templates.example.json'
        if (Test-Path -LiteralPath $samplePath) { Copy-Item -LiteralPath $samplePath -Destination $script:TemplatesPath -ErrorAction Stop }
    }
    $script:Config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Config $script:Config

    $csharp = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClipLite.Native
{
    public sealed class MessageWindow : NativeWindow, IDisposable
    {
        private const int WM_CLIPBOARDUPDATE = 0x031D;
        private bool listenerAdded;
        private bool disposed;
        public event EventHandler ClipboardChanged;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool AddClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

        public MessageWindow()
        {
            CreateParams cp = new CreateParams();
            cp.Caption = "ClipLiteMessageWindow";
            CreateHandle(cp);
            listenerAdded = AddClipboardFormatListener(Handle);
            if (!listenerAdded)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "クリップボード監視を開始できませんでした。");
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_CLIPBOARDUPDATE)
            {
                EventHandler handler = ClipboardChanged;
                if (handler != null) handler(this, EventArgs.Empty);
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (listenerAdded) RemoveClipboardFormatListener(Handle);
            DestroyHandle();
            GC.SuppressFinalize(this);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    public static class FocusHelper
    {
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern IntPtr SetFocus(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);
        [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")] private static extern bool ReleaseCapture();
        [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const byte VK_CONTROL = 0x11, VK_V = 0x56, VK_SHIFT = 0x10, VK_MENU = 0x12;

        public static IntPtr ForegroundWindow { get { return GetForegroundWindow(); } }

        public static void Capture(out IntPtr topWindow, out IntPtr focusWindow)
        {
            topWindow = GetForegroundWindow();
            focusWindow = IntPtr.Zero;
            if (topWindow == IntPtr.Zero) return;
            uint tid = GetWindowThreadProcessId(topWindow, IntPtr.Zero);
            GUITHREADINFO info = new GUITHREADINFO();
            info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
            if (GetGUIThreadInfo(tid, ref info)) focusWindow = info.hwndFocus;
        }

        public static bool Restore(IntPtr topWindow, IntPtr focusWindow)
        {
            if (topWindow == IntPtr.Zero || !IsWindow(topWindow)) return false;
            uint current = GetCurrentThreadId();
            uint target = GetWindowThreadProcessId(topWindow, IntPtr.Zero);
            bool attached = (target != 0 && target != current) && AttachThreadInput(current, target, true);
            try
            {
                if (IsIconic(topWindow)) ShowWindow(topWindow, 9);
                SetForegroundWindow(topWindow);
                BringWindowToTop(topWindow);
                if (focusWindow != IntPtr.Zero && IsWindow(focusWindow)) SetFocus(focusWindow);
            }
            finally
            {
                if (attached) AttachThreadInput(current, target, false);
            }
            return GetForegroundWindow() == topWindow;
        }

        public static void ForceForeground(IntPtr hwnd)
        {
            IntPtr fg = GetForegroundWindow();
            uint current = GetCurrentThreadId();
            uint target = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
            bool attached = (target != 0 && target != current) && AttachThreadInput(current, target, true);
            try
            {
                SetForegroundWindow(hwnd);
                BringWindowToTop(hwnd);
            }
            finally
            {
                if (attached) AttachThreadInput(current, target, false);
            }
        }

        public static void SendCtrlV(IntPtr expectedWindow)
        {
            for (int i = 0; i < 50; i++)
            {
                bool held = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0
                         || (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0
                         || (GetAsyncKeyState(VK_MENU) & 0x8000) != 0
                         || (GetAsyncKeyState(0x5B) & 0x8000) != 0
                         || (GetAsyncKeyState(0x5C) & 0x8000) != 0;
                if (!held) break;
                if (i == 49) return;
                System.Threading.Thread.Sleep(10);
            }
            if (expectedWindow == IntPtr.Zero || GetForegroundWindow() != expectedWindow) return;
            keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
            keybd_event(VK_V, 0, 0, UIntPtr.Zero);
            keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        }

        // 枠なしウィンドウをドラッグ移動させる
        public static void BeginDrag(IntPtr hwnd)
        {
            ReleaseCapture();
            SendMessage(hwnd, 0xA1, (IntPtr)2, IntPtr.Zero); // WM_NCLBUTTONDOWN, HTCAPTION
        }
    }

    public sealed class DoubleCtrlHook : IDisposable
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYUP = 0x0105;
        private const int VK_LCONTROL = 0xA2;
        private const int VK_RCONTROL = 0xA3;
        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
        private readonly LowLevelKeyboardProc proc;
        private readonly Control invoker;
        private IntPtr hookId = IntPtr.Zero;
        private bool disposed;
        private bool ctrlCurrentlyDown;
        private bool otherKeyPressedWhileCtrlDown;
        private DateTime lastCtrlUpTime = DateTime.MinValue;
        public int ThresholdMilliseconds { get; set; }
        public IntPtr CapturedTopWindow { get; private set; }
        public IntPtr CapturedFocusWindow { get; private set; }
        public event EventHandler DoubleCtrlPressed;

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        public DoubleCtrlHook(int thresholdMilliseconds, Control invoker)
        {
            ThresholdMilliseconds = thresholdMilliseconds;
            this.invoker = invoker;
            proc = HookCallback;
            using (System.Diagnostics.Process curProcess = System.Diagnostics.Process.GetCurrentProcess())
            using (System.Diagnostics.ProcessModule curModule = curProcess.MainModule)
            {
                hookId = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(curModule.ModuleName), 0);
            }
            if (hookId == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "キーボードフックを開始できませんでした。");
        }

        private void RaiseAsync()
        {
            IntPtr top, focus;
            FocusHelper.Capture(out top, out focus);
            CapturedTopWindow = top;
            CapturedFocusWindow = focus;
            if (invoker != null && invoker.IsHandleCreated)
            {
                invoker.BeginInvoke((MethodInvoker)delegate
                {
                    EventHandler handler = DoubleCtrlPressed;
                    if (handler != null) handler(this, EventArgs.Empty);
                });
            }
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                int msg = wParam.ToInt32();
                int vkCode = Marshal.ReadInt32(lParam);
                bool isCtrl = (vkCode == VK_LCONTROL || vkCode == VK_RCONTROL);
                if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)
                {
                    if (isCtrl)
                    {
                        if (!ctrlCurrentlyDown)
                        {
                            ctrlCurrentlyDown = true;
                            otherKeyPressedWhileCtrlDown = false;
                        }
                    }
                    else
                    {
                        if (ctrlCurrentlyDown) otherKeyPressedWhileCtrlDown = true;
                        lastCtrlUpTime = DateTime.MinValue;
                    }
                }
                else if ((msg == WM_KEYUP || msg == WM_SYSKEYUP) && isCtrl)
                {
                    ctrlCurrentlyDown = false;
                    DateTime now = DateTime.Now;
                    if (!otherKeyPressedWhileCtrlDown)
                    {
                        double elapsedMs = (now - lastCtrlUpTime).TotalMilliseconds;
                        if (lastCtrlUpTime != DateTime.MinValue && elapsedMs <= ThresholdMilliseconds)
                        {
                            lastCtrlUpTime = DateTime.MinValue;
                            RaiseAsync();
                        }
                        else lastCtrlUpTime = now;
                    }
                    else lastCtrlUpTime = DateTime.MinValue;
                }
            }
            return CallNextHookEx(hookId, nCode, wParam, lParam);
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (hookId != IntPtr.Zero)
            {
                UnhookWindowsHookEx(hookId);
                hookId = IntPtr.Zero;
            }
            GC.SuppressFinalize(this);
        }
    }
}
'@

    Add-Type -TypeDefinition $csharp -Language CSharp -ReferencedAssemblies @(
        'System.dll',
        'System.Windows.Forms.dll'
    )

    # ================= 定型文 =================
    function Load-Templates {
        $script:Templates.Clear()
        if (-not (Test-Path -LiteralPath $script:TemplatesPath)) {
            if (-not (Save-Templates)) { throw '定型文ファイルを作成できません。' }
            return
        }
        try {
            $raw = Get-Content -LiteralPath $script:TemplatesPath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { return }
            $parsed = ConvertFrom-Json -InputObject $raw
            if ($null -eq $parsed) { return }
            foreach ($item in @($parsed)) {
                if ($null -eq $item) { continue }
                $textProperty = $item.PSObject.Properties['Text']
                $nameProperty = $item.PSObject.Properties['Name']
                if ($null -eq $textProperty) { continue }
                $text = [string]$textProperty.Value
                if ([string]::IsNullOrWhiteSpace($text)) { continue }
                $name = '無題'
                if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
                    $name = [string]$nameProperty.Value
                }
                [void]$script:Templates.Add([pscustomobject]@{ Name = $name; Text = $text })
            }
        } catch {
            throw 'templates.json を読み込めませんでした。JSON形式を確認してください（元ファイルは変更していません）。'
        }
    }

    function Save-Templates {
        try {
            $json = if ($script:Templates.Count -eq 0) { '[]' } else { @($script:Templates) | ConvertTo-Json -Depth 3 }
            Write-AtomicUtf8 $script:TemplatesPath $json
            return $true
        } catch {
            Show-Error ('定型文を保存できませんでした。変更を取り消します。' + [Environment]::NewLine + $_.Exception.Message)
            return $false
        }
    }

    function Refresh-TemplateList {
        if ($null -eq $script:TemplateList) { return }
        $script:TemplateList.BeginUpdate()
        try {
            $script:TemplateList.Items.Clear()
            foreach ($item in $script:Templates) {
                if ($null -eq $item) { continue }
                $nameProperty = $item.PSObject.Properties['Name']
                if ($null -ne $nameProperty) {
                    [void]$script:TemplateList.Items.Add([string]$nameProperty.Value)
                }
            }
            if ($script:TemplateList.Items.Count -gt 0 -and $script:TemplateList.SelectedIndex -lt 0) {
                $script:TemplateList.SelectedIndex = 0
            }
        } finally { $script:TemplateList.EndUpdate() }
        Update-CountLabel
    }

    function Show-TemplateEditor($ExistingItem) {
        $dialog = New-Object System.Windows.Forms.Form
        $dialog.Text = if ($null -eq $ExistingItem) { '定型文を追加' } else { '定型文を編集' }
        $dialog.Width = 600
        $dialog.Height = 470
        $dialog.MinimumSize = New-Object System.Drawing.Size(440, 300)
        $dialog.StartPosition = 'CenterParent'
        $dialog.Font = $script:Form.Font
        $dialog.TopMost = $script:Form.TopMost
        $dialog.ShowInTaskbar = $false
        $dialog.FormBorderStyle = 'None'
        $dialog.ClientSize = New-Object System.Drawing.Size(600, 470)
        $dialog.BackColor = $script:Theme.Back
        $dialog.ForeColor = $script:Theme.Text
        $dialog.Padding = New-Object System.Windows.Forms.Padding(1)
        $dialog.AutoScaleMode = 'Font'
        $dialog.Add_Paint({ param($sender, $e)
            $pen = New-Object System.Drawing.Pen($script:Theme.Border)
            try { $e.Graphics.DrawRectangle($pen, 0, 0, $sender.ClientSize.Width - 1, $sender.ClientSize.Height - 1) }
            finally { $pen.Dispose() }
        })
        $header = New-Object System.Windows.Forms.Label
        $header.Text = $dialog.Text
        $header.BackColor = $script:Theme.Panel
        $header.Location = New-Object System.Drawing.Point(1, 1)
        $header.Size = New-Object System.Drawing.Size(598, 44)
        $header.Anchor = 'Top,Left,Right'
        $header.Padding = New-Object System.Windows.Forms.Padding(18, 0, 0, 0)
        $header.TextAlign = 'MiddleLeft'
        $header.Add_MouseDown({ param($sender, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                [ClipLite.Native.FocusHelper]::BeginDrag($dialog.Handle)
            }
        })
        $close = New-FlatButton '×' 32 30
        $close.Location = New-Object System.Drawing.Point(556, 8)
        $close.Anchor = 'Top,Right'
        $close.FlatAppearance.BorderSize = 0
        $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $close.AccessibleName = '閉じる'

        $nameLabel = New-Object System.Windows.Forms.Label
        $nameLabel.Text = '名前'
        $nameLabel.Location = New-Object System.Drawing.Point(20, 62)
        $nameLabel.AutoSize = $true
        $nameBox = New-Object System.Windows.Forms.TextBox
        $nameBox.Location = New-Object System.Drawing.Point(20, 88)
        $nameBox.Width = 560
        $nameBox.Anchor = 'Top,Left,Right'

        $textLabel = New-Object System.Windows.Forms.Label
        $textLabel.Text = '本文'
        $textLabel.Location = New-Object System.Drawing.Point(20, 128)
        $textLabel.AutoSize = $true
        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Location = New-Object System.Drawing.Point(20, 154)
        $textBox.Size = New-Object System.Drawing.Size(560, 196)
        $textBox.Anchor = 'Top,Bottom,Left,Right'
        $textBox.Multiline = $true
        $textBox.AcceptsReturn = $true
        $textBox.AcceptsTab = $true
        $textBox.ScrollBars = 'Both'
        $textBox.WordWrap = $false

        foreach ($box in @($nameBox, $textBox)) {
            $box.BackColor = $script:Theme.Input
            $box.ForeColor = $script:Theme.Text
            $box.BorderStyle = 'FixedSingle'
        }
        $nameBox.AccessibleName = '定型文の名前'
        $textBox.AccessibleName = '定型文の本文'
        $nameBox.TabIndex = 0
        $textBox.TabIndex = 1
        $hint = New-Object System.Windows.Forms.Label
        $hint.Text = '{{DATE}} → 今日の日付（YYYY/MM/DD）'
        $hint.ForeColor = $script:Theme.SubText
        $hint.Location = New-Object System.Drawing.Point(20, 360)
        $hint.Size = New-Object System.Drawing.Size(560, 24)
        $hint.Anchor = 'Bottom,Left,Right'
        $validation = New-Object System.Windows.Forms.Label
        $validation.ForeColor = $script:Theme.ErrorText
        $validation.Location = New-Object System.Drawing.Point(20, 387)
        $validation.Size = New-Object System.Drawing.Size(560, 24)
        $validation.Anchor = 'Bottom,Left,Right'
        $ok = New-FlatButton '保存' 100 34
        $ok.BackColor = $script:Theme.TabActive
        $ok.ForeColor = $script:Theme.SelText
        $ok.FlatAppearance.MouseOverBackColor = $script:Theme.SelBack
        $ok.TabStop = $true
        $ok.TabIndex = 2
        $ok.Text = '保存'
        $ok.Location = New-Object System.Drawing.Point(480, 416)
        $ok.Anchor = 'Bottom,Right'
        $ok.DialogResult = [System.Windows.Forms.DialogResult]::None
        $cancel = New-FlatButton 'キャンセル' 110 34
        $cancel.TabStop = $true
        $cancel.TabIndex = 3
        $cancel.Text = 'キャンセル'
        $cancel.Location = New-Object System.Drawing.Point(358, 416)
        $cancel.Anchor = 'Bottom,Right'
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

        if ($null -ne $ExistingItem) {
            $nameBox.Text = [string]$ExistingItem.Name
            $textBox.Text = [string]$ExistingItem.Text
        }
        $ok.Add_Click({
            if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
                $validation.Text = '名前を入力してください。'
                [void]$nameBox.Focus(); return
            }
            if ([string]::IsNullOrWhiteSpace($textBox.Text)) {
                $validation.Text = '本文を入力してください。'
                [void]$textBox.Focus(); return
            }
            $dialog.Tag = [pscustomobject]@{ Name = $nameBox.Text.Trim(); Text = $textBox.Text }
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        })
        $dialog.AcceptButton = $ok
        $dialog.CancelButton = $cancel
        $dialog.Controls.AddRange(@($header, $close, $nameLabel, $nameBox, $textLabel, $textBox, $hint, $validation, $ok, $cancel))
        $close.BringToFront()
        $dialog.Add_Shown({ [void]$nameBox.Focus() })

        $script:IsModalOpen = $true
        try {
            $dialogResult = $dialog.ShowDialog($script:Form)
            if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK -and $null -ne $dialog.Tag) {
                Write-Output -NoEnumerate $dialog.Tag
            }
        } finally {
            $script:IsModalOpen = $false
            $dialog.Dispose()
        }
    }

    function Add-Template {
        $newItem = @(Show-TemplateEditor $null) | Select-Object -Last 1
        if ($null -eq $newItem) { return }
        $nameProperty = $newItem.PSObject.Properties['Name']
        $textProperty = $newItem.PSObject.Properties['Text']
        if ($null -eq $nameProperty -or $null -eq $textProperty) {
            Show-Error '定型文の入力結果を取得できませんでした。'
            return
        }
        $before = @($script:Templates.ToArray())
        [void]$script:Templates.Add([pscustomobject]@{
            Name = [string]$nameProperty.Value
            Text = [string]$textProperty.Value
        })
        if (-not (Save-Templates)) {
            $script:Templates.Clear(); $script:Templates.AddRange($before)
            Refresh-TemplateList; return
        }
        Refresh-TemplateList
        $script:TemplateList.SelectedIndex = $script:TemplateList.Items.Count - 1
        [void]$script:TemplateList.Focus()
    }

    function Edit-SelectedTemplate {
        $i = $script:TemplateList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:Templates.Count) { return }
        $updated = @(Show-TemplateEditor $script:Templates[$i]) | Select-Object -Last 1
        if ($null -eq $updated) { return }
        $nameProperty = $updated.PSObject.Properties['Name']
        $textProperty = $updated.PSObject.Properties['Text']
        if ($null -eq $nameProperty -or $null -eq $textProperty) {
            Show-Error '定型文の編集結果を取得できませんでした。'
            return
        }
        $before = @($script:Templates.ToArray())
        $script:Templates[$i] = [pscustomobject]@{
            Name = [string]$nameProperty.Value
            Text = [string]$textProperty.Value
        }
        if (-not (Save-Templates)) {
            $script:Templates.Clear(); $script:Templates.AddRange($before)
            Refresh-TemplateList; return
        }
        Refresh-TemplateList
        $script:TemplateList.SelectedIndex = $i
        [void]$script:TemplateList.Focus()
    }

    function Delete-SelectedTemplate {
        $i = $script:TemplateList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:Templates.Count) { return }
        $script:IsModalOpen = $true
        try {
            $answer = [System.Windows.Forms.MessageBox]::Show(('「{0}」を削除しますか？' -f $script:Templates[$i].Name), 'ClipLite', 'YesNo', 'Question')
        } finally { $script:IsModalOpen = $false }
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $before = @($script:Templates.ToArray())
        $script:Templates.RemoveAt($i)
        if (-not (Save-Templates)) {
            $script:Templates.Clear(); $script:Templates.AddRange($before)
            Refresh-TemplateList; return
        }
        Refresh-TemplateList
        [void]$script:TemplateList.Focus()
    }

    function Use-SelectedTemplate {
        $i = $script:TemplateList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:Templates.Count) { return }
        $text = Expand-TemplateText ([string]$script:Templates[$i].Text)
        Paste-TextToPreviousWindow $text
    }

    # ================= UI状態 =================
    function Load-UiState {
        $script:LastSelectedTab = 0
        if (-not (Test-Path -LiteralPath $script:UiStatePath)) { return }
        try {
            $raw = Get-Content -LiteralPath $script:UiStatePath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { return }
            $state = ConvertFrom-Json -InputObject $raw
            if ($null -eq $state) { return }
            $mode = $state.PSObject.Properties['ThemeMode']
            if ($null -ne $mode -and $mode.Value -in @('System','Light','Dark')) { $script:ThemeMode = $mode.Value }
            $tabProperty = $state.PSObject.Properties['SelectedTab']
            if ($null -ne $tabProperty) {
                $value = [int]$tabProperty.Value
                if ($value -ge 0 -and $value -le 1) { $script:LastSelectedTab = $value }
            }
        } catch {
            $script:LastSelectedTab = 0
        }
    }

    function Save-UiState {
        try {
            $json = [pscustomobject]@{ SelectedTab = [int]$script:LastSelectedTab; ThemeMode = $script:ThemeMode } | ConvertTo-Json
            Write-AtomicUtf8 $script:UiStatePath $json
        } catch { }
    }

    # ================= タブ =================
    function Set-ActiveTab([int]$Index, [switch]$NoSave) {
        $script:LastSelectedTab = $Index
        $isHistory = ($Index -eq 0)
        $script:HistoryPanel.Visible = $isHistory
        $script:TemplatePanel.Visible = -not $isHistory
        $script:SearchPanel.Visible = $isHistory
        $script:HistoryTabButton.BackColor = if ($isHistory) { $script:Theme.TabActive } else { $script:Theme.TabInactive }
        $script:TemplateTabButton.BackColor = if ($isHistory) { $script:Theme.TabInactive } else { $script:Theme.TabActive }
        $script:HistoryTabButton.ForeColor = if ($isHistory) { $script:Theme.SelText } else { $script:Theme.Text }
        $script:TemplateTabButton.ForeColor = if ($isHistory) { $script:Theme.Text } else { $script:Theme.SelText }
        Update-CountLabel
        if (-not $NoSave) { Save-UiState }
        if ($script:Form.Visible) { Focus-CurrentTabTopItem }
    }

    function Focus-CurrentTabTopItem {
        if ($script:LastSelectedTab -eq 1) {
            if ($script:TemplateList.Items.Count -gt 0) {
                $script:TemplateList.SelectedIndex = 0
                $script:TemplateList.TopIndex = 0
            }
            [void]$script:TemplateList.Focus()
        } else {
            if ($script:ListBox.Items.Count -gt 0) {
                $script:ListBox.SelectedIndex = 0
                $script:ListBox.TopIndex = 0
            }
            [void]$script:ListBox.Focus()
        }
    }

    function Update-CountLabel {
        if ($null -eq $script:CountLabel) { return }
        if ($script:LastSelectedTab -eq 1) {
            $script:CountLabel.Text = '定型文 {0}件' -f $script:Templates.Count
        } else {
            $script:CountLabel.Text = '履歴 {0}件 / {1}件中' -f @($script:FilteredItems).Count, $script:History.Count
        }
    }

    # ================= 履歴 =================
    function Get-Preview([string]$Text) {
        $singleLine = $Text -replace '[\r\n\t]+', ' '
        $singleLine = $singleLine.Trim()
        $limit = [Math]::Max(20, [int]$script:Config.PreviewLength)
        if ($singleLine.Length -gt $limit) {
            return $singleLine.Substring(0, $limit) + '...'
        }
        return $singleLine
    }

    function Refresh-HistoryList {
        $query = $script:SearchBox.Text
        if ([string]::IsNullOrWhiteSpace($query)) {
            $script:FilteredItems = @($script:History)
        } else {
            $script:FilteredItems = @($script:History | Where-Object { $_.Text.IndexOf($query, [StringComparison]::CurrentCultureIgnoreCase) -ge 0 })
        }

        $script:ListBox.BeginUpdate()
        try {
            $script:ListBox.Items.Clear()
            foreach ($item in $script:FilteredItems) {
                [void]$script:ListBox.Items.Add((Get-Preview $item.Text))
            }
            if ($script:ListBox.Items.Count -gt 0) { $script:ListBox.SelectedIndex = 0 }
            $script:LastToolTipIndex = -1
            if ($null -ne $script:HistoryToolTip) { $script:HistoryToolTip.SetToolTip($script:ListBox, '') }
        } finally {
            $script:ListBox.EndUpdate()
        }
        Update-CountLabel
    }

    function Add-ClipboardText([string]$Text) {
        if ($script:IsPaused -or $null -eq $Text) { return }
        if ([bool]$script:Config.IgnoreWhitespaceOnly -and [string]::IsNullOrWhiteSpace($Text)) { return }
        if ($Text.Length -gt [int]$script:Config.MaxTextLength) { return }
        if ($null -ne $script:SuppressText -and $Text -ceq $script:SuppressText) {
            $script:SuppressText = $null
            return
        }
        if ([bool]$script:Config.IgnoreDuplicate) {
            for ($i = $script:History.Count - 1; $i -ge 0; $i--) {
                if ($script:History[$i].Text -ceq $Text) { $script:History.RemoveAt($i) }
            }
        }
        $entry = [pscustomobject]@{
            Text = $Text
            CapturedAt = [DateTime]::Now
        }
        $script:History.Insert(0, $entry)
        while ($script:History.Count -gt [int]$script:Config.MaxHistory) {
            $script:History.RemoveAt($script:History.Count - 1)
        }
        Refresh-HistoryList
    }

    function Capture-Clipboard {
        if ($script:IsPaused) { return }
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            try {
                if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                    Add-ClipboardText ([System.Windows.Forms.Clipboard]::GetText())
                }
                return
            } catch [System.Runtime.InteropServices.ExternalException] {
                Start-Sleep -Milliseconds 60
            }
        }
    }

    function Expand-TemplateText([string]$Text) {
        if ($null -eq $Text) { return $null }
        $today = [DateTime]::Today.ToString('yyyy/MM/dd', [System.Globalization.CultureInfo]::InvariantCulture)
        return $Text.Replace('{{DATE}}', $today)
    }

    # ================= 表示・非表示・貼り付け =================
    function Restore-PreviousFocus {
        if ($script:PreviousForegroundWindow -eq [IntPtr]::Zero) { return $false }
        return [ClipLite.Native.FocusHelper]::Restore($script:PreviousForegroundWindow, $script:PreviousFocusWindow)
    }

    function Hide-HistoryWindow {
        # Escなどで閉じる場合: 先に元のウィンドウへ戻してから隠す
        $script:IsHidingInternally = $true
        try {
            [void](Restore-PreviousFocus)
            $script:Form.Hide()
        } finally { $script:IsHidingInternally = $false }
    }

    function Paste-TextToPreviousWindow([string]$Text) {
        try {
            $script:SuppressText = $Text
            [System.Windows.Forms.Clipboard]::SetText($Text)

            $autoPaste = $true
            $autoPasteProperty = $script:Config.PSObject.Properties['AutoPaste']
            if ($null -ne $autoPasteProperty) { $autoPaste = [bool]$autoPasteProperty.Value }

            $script:IsHidingInternally = $true
            try {
                $restored = Restore-PreviousFocus
                $script:Form.Hide()
            } finally { $script:IsHidingInternally = $false }

            if (-not $autoPaste -or -not $restored) { return }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 120
            [ClipLite.Native.FocusHelper]::SendCtrlV($script:PreviousForegroundWindow)
        } catch {
            $script:SuppressText = $null
            Show-Error ('貼り付けを実行できませんでした。' + [Environment]::NewLine + $_.Exception.Message)
        }
    }

    function Set-WindowNearCursor {
        $cursor = [System.Windows.Forms.Cursor]::Position
        $area = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
        $w = $script:Form.Width
        $h = $script:Form.Height
        $offset = 12
        $x = $cursor.X + $offset
        $y = $cursor.Y + $offset
        if ($x + $w -gt $area.Right)  { $x = $cursor.X - $w - $offset }
        if ($y + $h -gt $area.Bottom) { $y = $cursor.Y - $h - $offset }
        $x = [Math]::Max($area.Left, [Math]::Min($x, $area.Right - $w))
        $y = [Math]::Max($area.Top,  [Math]::Min($y, $area.Bottom - $h))
        $script:Form.Location = New-Object System.Drawing.Point($x, $y)
    }

    function Show-HistoryWindow([switch]$FromHotkey) {
        if ($script:ThemeMode -eq 'System') { Update-WindowTheme }
        if ($FromHotkey -and $null -ne $script:CtrlHook) {
            $top = $script:CtrlHook.CapturedTopWindow
            $focus = $script:CtrlHook.CapturedFocusWindow
        } else {
            $top = [IntPtr]::Zero; $focus = [IntPtr]::Zero
            [ClipLite.Native.FocusHelper]::Capture([ref]$top, [ref]$focus)
        }
        if ($top -ne [IntPtr]::Zero -and $top -ne $script:Form.Handle) {
            $script:PreviousForegroundWindow = $top
            $script:PreviousFocusWindow = $focus
        }

        if ($script:SearchBox.Text.Length -gt 0) { $script:SearchBox.Text = '' } else { Refresh-HistoryList }
        Refresh-TemplateList
        Set-ActiveTab $script:LastSelectedTab -NoSave
        if (-not $script:Form.Visible) { Set-WindowNearCursor }
        $script:Form.Show()
        $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        [ClipLite.Native.FocusHelper]::ForceForeground($script:Form.Handle)
        [void]$script:Form.Activate()
        Focus-CurrentTabTopItem
    }

    function Use-SelectedItem {
        $index = $script:ListBox.SelectedIndex
        if ($index -lt 0 -or $index -ge $script:FilteredItems.Count) { return }
        $text = [string]$script:FilteredItems[$index].Text
        Paste-TextToPreviousWindow $text
    }

    function Remove-SelectedItem {
        $index = $script:ListBox.SelectedIndex
        if ($index -lt 0 -or $index -ge $script:FilteredItems.Count) { return }
        [void]$script:History.Remove($script:FilteredItems[$index])
        Refresh-HistoryList
        if ($script:ListBox.Items.Count -gt 0) {
            $script:ListBox.SelectedIndex = [Math]::Min($index, $script:ListBox.Items.Count - 1)
        }
    }

    function Clear-History {
        $script:History.Clear()
        Refresh-HistoryList
    }

    # 1-9,0,a-z キーを一覧のインデックスへ変換
    function Get-ShortcutIndex([System.Windows.Forms.Keys]$KeyCode) {
        $k = [int]$KeyCode
        if ($k -ge 0x31 -and $k -le 0x39) { return $k - 0x31 }       # 1-9
        if ($k -eq 0x30) { return 9 }                                 # 0
        if ($k -ge 0x61 -and $k -le 0x69) { return $k - 0x61 }       # NumPad1-9
        if ($k -eq 0x60) { return 9 }                                 # NumPad0
        if ($k -ge 0x41 -and $k -le 0x5A) { return 10 + ($k - 0x41) } # A-Z
        return -1
    }

    function Exit-ClipLite {
        $script:IsExiting = $true
        Save-UiState
        if ($null -ne $script:NotifyIcon) {
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
            $script:NotifyIcon = $null
        }
        if ($null -ne $script:CtrlHook) { $script:CtrlHook.Dispose(); $script:CtrlHook = $null }
        if ($null -ne $script:MessageWindow) { $script:MessageWindow.Dispose(); $script:MessageWindow = $null }
        $script:Form.Close()
        [System.Windows.Forms.Application]::ExitThread()
    }

    # ================= コンソール表示 =================  # ★追加
    function Show-ConsoleNotice {
        try {
            $Host.UI.RawUI.WindowTitle = 'ClipLite ' + $script:AppVersion + '（実行中 - 閉じないでください）'
            Clear-Host
            $line = '=' * 60
            Write-Host ''
            Write-Host $line -ForegroundColor DarkGray
            Write-Host ('  ClipLite {0} は実行中です' -f $script:AppVersion) -ForegroundColor Cyan
            Write-Host $line -ForegroundColor DarkGray
            Write-Host ''
            Write-Host '  このウィンドウを閉じると ClipLite が終了します。' -ForegroundColor Yellow
            Write-Host '  閉じずに、最小化してお使いください。' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '  ・表示する   : Ctrl キーを素早く2回押す' -ForegroundColor Gray
            Write-Host '  ・終了する   : タスクトレイのアイコンを右クリック →「終了」' -ForegroundColor Gray
            Write-Host ''
            Write-Host ('  起動日時: {0:yyyy/MM/dd HH:mm:ss}' -f [DateTime]::Now) -ForegroundColor DarkGray
            Write-Host $line -ForegroundColor DarkGray
        } catch { }
    }

    # ================= UI部品ヘルパー =================
    function New-FlatButton([string]$Text, [int]$Width, [int]$Height) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.Width = $Width
        $b.Height = $Height
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $script:Theme.Border
        $b.FlatAppearance.MouseOverBackColor = $script:Theme.Hover
        $b.BackColor = $script:Theme.TabInactive
        $b.ForeColor = $script:Theme.Text
        $b.TabStop = $false
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        return $b
    }

    function New-DarkListBox {
        $lb = New-Object System.Windows.Forms.ListBox
        $lb.Dock = 'Fill'
        $lb.IntegralHeight = $false
        $lb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $lb.BackColor = $script:Theme.Back
        $lb.ForeColor = $script:Theme.Text
        $lb.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
        $lb.ItemHeight = 20
        $lb.Add_DrawItem({
            param($sender, $e)
            if ($e.Index -lt 0) { return }
            $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
            $bg = if ($selected) { $script:Theme.SelBack } else { $sender.BackColor }
            $brush = New-Object System.Drawing.SolidBrush($bg)
            try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }

            $key = ''
            if ($e.Index -lt $script:ShortcutKeys.Length) { $key = [string]$script:ShortcutKeys[$e.Index] + ':' }
            $keyColor = if ($selected) { $script:Theme.SelText } else { $script:Theme.Key }
            $textColor = if ($selected) { $script:Theme.SelText } else { $script:Theme.Text }
            $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                     [System.Windows.Forms.TextFormatFlags]::SingleLine -bor `
                     [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor `
                     [System.Windows.Forms.TextFormatFlags]::NoPrefix
            $keyRect = New-Object System.Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, 24, $e.Bounds.Height)
            $textRect = New-Object System.Drawing.Rectangle(($e.Bounds.X + 32), $e.Bounds.Y, [Math]::Max(10, $e.Bounds.Width - 36), $e.Bounds.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $key, $sender.Font, $keyRect, $keyColor, $flags)
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$sender.Items[$e.Index], $sender.Font, $textRect, $textColor, $flags)
        })
        return $lb
    }

    Load-Templates
    Load-UiState
    $script:Theme = Get-PreferredPalette

    # ================= メインフォーム =================
    $script:Form = New-Object System.Windows.Forms.Form
    $script:Form.Text = 'ClipLite'
    $script:Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $script:Form.Width = [int]$script:Config.Window.Width
    $script:Form.Height = [int]$script:Config.Window.Height
    $script:Form.MinimumSize = New-Object System.Drawing.Size(320, 240)
    $script:Form.TopMost = [bool]$script:Config.Window.TopMost
    $script:Form.ShowInTaskbar = $false
    $script:Form.KeyPreview = $true
    $script:Form.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9.5)
    $script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $script:Form.BackColor = $script:Theme.Border               # 1pxの外枠として見せる
    $script:Form.Padding = New-Object System.Windows.Forms.Padding(1)

    # --- タブボタン行 ---
    $tabBar = New-Object System.Windows.Forms.Panel
    $tabBar.Dock = 'Top'
    $tabBar.Height = 34
    $tabBar.BackColor = $script:Theme.Panel
    $tabBar.Padding = New-Object System.Windows.Forms.Padding(6, 5, 6, 3)

    $script:HistoryTabButton = New-FlatButton 'クリップボード' 130 26
    $script:HistoryTabButton.Location = New-Object System.Drawing.Point(6, 4)
    $script:TemplateTabButton = New-FlatButton '定型文' 90 26
    $script:TemplateTabButton.Location = New-Object System.Drawing.Point(140, 4)
    $closeButton = New-FlatButton '×' 26 26
    $closeButton.Anchor = 'Top,Right'
    $closeButton.Location = New-Object System.Drawing.Point(($script:Form.ClientSize.Width - 34), 4)
    $closeButton.FlatAppearance.BorderSize = 0
    $closeButton.BackColor = $script:Theme.Panel
    $tabBar.Controls.AddRange(@($script:HistoryTabButton, $script:TemplateTabButton, $closeButton))

    # --- 情報行(ドラッグで移動) ---
    $infoBar = New-Object System.Windows.Forms.Panel
    $infoBar.Dock = 'Top'
    $infoBar.Height = 22
    $infoBar.BackColor = $script:Theme.Panel
    $infoBar.Cursor = [System.Windows.Forms.Cursors]::SizeAll

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'ClipLite ' + $script:AppVersion
    $titleLabel.ForeColor = $script:Theme.SubText
    $titleLabel.AutoSize = $false
    $titleLabel.Dock = 'Left'
    $titleLabel.Width = 140
    $titleLabel.TextAlign = 'MiddleLeft'
    $titleLabel.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)

    $script:CountLabel = New-Object System.Windows.Forms.Label
    $script:CountLabel.ForeColor = $script:Theme.Text
    $script:CountLabel.Dock = 'Fill'
    $script:CountLabel.TextAlign = 'MiddleRight'
    $script:CountLabel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $infoBar.Controls.Add($script:CountLabel)
    $themeButton = New-FlatButton '' 112 22
    $themeButton.Dock = 'Left'
    $themeButton.TabStop = $true
    $themeButton.AccessibleName = '配色の切り替え'
    $titleLabel.Width = 94
    $infoBar.Controls.Add($themeButton)
    $infoBar.Controls.Add($titleLabel)

    $dragHandler = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            [ClipLite.Native.FocusHelper]::BeginDrag($script:Form.Handle)
        }
    }
    $infoBar.Add_MouseDown($dragHandler)
    $titleLabel.Add_MouseDown($dragHandler)
    $script:CountLabel.Add_MouseDown($dragHandler)

    # --- 検索行 ---
    $script:SearchPanel = New-Object System.Windows.Forms.Panel
    $script:SearchPanel.Dock = 'Top'
    $script:SearchPanel.Height = 30
    $script:SearchPanel.BackColor = $script:Theme.Panel
    $script:SearchPanel.Padding = New-Object System.Windows.Forms.Padding(6, 3, 6, 5)

    $script:SearchBox = New-Object System.Windows.Forms.TextBox
    $script:SearchBox.Dock = 'Fill'
    $script:SearchBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:SearchBox.BackColor = $script:Theme.Input
    $script:SearchBox.ForeColor = $script:Theme.Text
    $script:SearchPanel.Controls.Add($script:SearchBox)

    # --- 履歴パネル ---
    $script:HistoryPanel = New-Object System.Windows.Forms.Panel
    $script:HistoryPanel.Dock = 'Fill'
    $script:HistoryPanel.BackColor = $script:Theme.Back
    $script:ListBox = New-DarkListBox
    $script:HistoryPanel.Controls.Add($script:ListBox)

    $script:HistoryToolTip = New-Object System.Windows.Forms.ToolTip
    $script:HistoryToolTip.AutomaticDelay = 300
    $script:HistoryToolTip.ReshowDelay = 100
    $script:HistoryToolTip.ShowAlways = $true
    $script:LastToolTipIndex = -1
    $script:ListBox.Add_MouseMove({
        param($sender, $e)
        $index = $script:ListBox.IndexFromPoint($e.Location)
        if ($index -eq $script:LastToolTipIndex) { return }
        $script:LastToolTipIndex = $index
        if ($index -ge 0 -and $index -lt $script:FilteredItems.Count) {
            $capturedAt = $script:FilteredItems[$index].CapturedAt
            $script:HistoryToolTip.SetToolTip($script:ListBox, ('{0:yyyy/MM/dd(ddd) HH:mm:ss}' -f $capturedAt))
        } else { $script:HistoryToolTip.SetToolTip($script:ListBox, '') }
    })
    $script:ListBox.Add_MouseLeave({
        $script:LastToolTipIndex = -1
        $script:HistoryToolTip.SetToolTip($script:ListBox, '')
    })

    # --- 定型文パネル ---
    $script:TemplatePanel = New-Object System.Windows.Forms.Panel
    $script:TemplatePanel.Dock = 'Fill'
    $script:TemplatePanel.BackColor = $script:Theme.Back

    $templateButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $templateButtons.Dock = 'Top'
    $templateButtons.Height = 32
    $templateButtons.BackColor = $script:Theme.Panel
    $templateButtons.Padding = New-Object System.Windows.Forms.Padding(4, 3, 4, 3)
    $addTemplateButton = New-FlatButton '追加' 60 24
    $editTemplateButton = New-FlatButton '編集' 60 24
    $deleteTemplateButton = New-FlatButton '削除' 60 24
    $templateButtons.Controls.AddRange(@($addTemplateButton, $editTemplateButton, $deleteTemplateButton))

    $script:TemplateList = New-DarkListBox
    $script:TemplatePanel.Controls.Add($script:TemplateList)
    $script:TemplatePanel.Controls.Add($templateButtons)

    # --- 下部ヘルプ ---
    $bottomLabel = New-Object System.Windows.Forms.Label
    $bottomLabel.Dock = 'Bottom'
    $bottomLabel.Height = 22
    $bottomLabel.BackColor = $script:Theme.Panel
    $bottomLabel.ForeColor = $script:Theme.SubText
    $bottomLabel.TextAlign = 'MiddleLeft'
    $bottomLabel.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
    $bottomLabel.Text = '1-0,a-z/Enter: 貼付  Ctrl+1/2: タブ  Ctrl+F: 検索  Del: 削除  Esc: 閉じる'

    # ドッキングは後から追加したものが外側になる
    $script:Form.Controls.Add($script:HistoryPanel)
    $script:Form.Controls.Add($script:TemplatePanel)
    $script:Form.Controls.Add($bottomLabel)
    $script:Form.Controls.Add($script:SearchPanel)
    $script:Form.Controls.Add($infoBar)
    $script:Form.Controls.Add($tabBar)

    function Update-WindowTheme {
        $script:Theme = Get-PreferredPalette
        $palette = $script:Theme
        $script:Form.BackColor = $palette.Border
        foreach ($control in @($tabBar,$infoBar,$script:SearchPanel,$templateButtons,$bottomLabel,$closeButton)) {
            $control.BackColor = $palette.Panel
        }
        foreach ($control in @($script:HistoryPanel,$script:TemplatePanel,$script:ListBox,$script:TemplateList)) {
            $control.BackColor = $palette.Back
            $control.ForeColor = $palette.Text
        }
        $titleLabel.ForeColor = $bottomLabel.ForeColor = $palette.SubText
        $script:CountLabel.ForeColor = $palette.Text
        $script:SearchBox.BackColor = $palette.Input
        $script:SearchBox.ForeColor = $palette.Text
        foreach ($button in @($themeButton,$closeButton,$script:HistoryTabButton,$script:TemplateTabButton,$addTemplateButton,$editTemplateButton,$deleteTemplateButton)) {
            $button.ForeColor = $palette.Text
            $button.FlatAppearance.BorderColor = $palette.Border
            $button.FlatAppearance.MouseOverBackColor = $palette.Hover
        }
        foreach ($button in @($themeButton,$addTemplateButton,$editTemplateButton,$deleteTemplateButton)) {
            $button.BackColor = $palette.TabInactive
        }
        $label = switch ($script:ThemeMode) { 'Light' { 'ライト' } 'Dark' { 'ダーク' } default { 'システム' } }
        $themeButton.Text = '配色：' + $label
        Set-ActiveTab $script:LastSelectedTab -NoSave
        $script:Form.Invalidate($true)
    }
    $themeButton.Add_Click({
        $script:ThemeMode = switch ($script:ThemeMode) { 'System' { 'Light' } 'Light' { 'Dark' } default { 'System' } }
        Update-WindowTheme
        Save-UiState
    })
    Update-WindowTheme

    # ================= イベント =================
    $script:HistoryTabButton.Add_Click({ Set-ActiveTab 0 })
    $script:TemplateTabButton.Add_Click({ Set-ActiveTab 1 })
    $closeButton.Add_Click({ Hide-HistoryWindow })

    # フォーム全体のショートカット(KeyPreview)
    $script:Form.Add_KeyDown({
        param($sender, $e)
        if ($e.Control -and -not $e.Alt -and -not $e.Shift) {
            $target = -1
            switch ($e.KeyCode) {
                ([System.Windows.Forms.Keys]::D1)      { $target = 0 }
                ([System.Windows.Forms.Keys]::NumPad1) { $target = 0 }
                ([System.Windows.Forms.Keys]::D2)      { $target = 1 }
                ([System.Windows.Forms.Keys]::NumPad2) { $target = 1 }
            }
            if ($target -ge 0) {
                if ($script:LastSelectedTab -ne $target) { Set-ActiveTab $target } else { Focus-CurrentTabTopItem }
                $e.Handled = $true; $e.SuppressKeyPress = $true
                return
            }
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F) {
                if ($script:LastSelectedTab -ne 0) { Set-ActiveTab 0 }
                [void]$script:SearchBox.Focus()
                $script:SearchBox.SelectAll()
                $e.Handled = $true; $e.SuppressKeyPress = $true
                return
            }
        }
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            Hide-HistoryWindow
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    })

    $script:SearchBox.Add_TextChanged({ Refresh-HistoryList })
    $script:SearchBox.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Down -and $script:ListBox.Items.Count -gt 0) {
            [void]$script:ListBox.Focus()
            $e.Handled = $true
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            Use-SelectedItem
            $e.SuppressKeyPress = $true
        }
    })

    $script:ListBox.Add_DoubleClick({ Use-SelectedItem })
    $script:ListBox.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            Use-SelectedItem; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete -and $e.Control) {
            Clear-History; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
            Remove-SelectedItem; $e.SuppressKeyPress = $true
        } elseif (-not $e.Control -and -not $e.Alt -and -not $e.Shift) {
            $idx = Get-ShortcutIndex $e.KeyCode
            if ($idx -ge 0) {
                $e.SuppressKeyPress = $true
                if ($idx -lt $script:ListBox.Items.Count) {
                    $script:ListBox.SelectedIndex = $idx
                    Use-SelectedItem
                }
            }
        }
    })

    $addTemplateButton.Add_Click({ Add-Template })
    $editTemplateButton.Add_Click({ Edit-SelectedTemplate })
    $deleteTemplateButton.Add_Click({ Delete-SelectedTemplate })
    $script:TemplateList.Add_DoubleClick({ Use-SelectedTemplate })
    $script:TemplateList.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            Use-SelectedTemplate; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
            Delete-SelectedTemplate; $e.SuppressKeyPress = $true
        } elseif (-not $e.Control -and -not $e.Alt -and -not $e.Shift) {
            $idx = Get-ShortcutIndex $e.KeyCode
            if ($idx -ge 0) {
                $e.SuppressKeyPress = $true
                if ($idx -lt $script:TemplateList.Items.Count) {
                    $script:TemplateList.SelectedIndex = $idx
                    Use-SelectedTemplate
                }
            }
        }
    })

    $script:Form.Add_FormClosing({
        param($sender, $e)
        if (-not $script:IsExiting) {
            $e.Cancel = $true
            Hide-HistoryWindow
        }
    })

    # 別のウィンドウにフォーカスが移ったら隠す(元のウィンドウへは戻さない)
    function Hide-IfForegroundChanged {
        if (-not $script:Form.Visible -or $script:IsExiting -or $script:IsModalOpen -or $script:IsHidingInternally) { return }
        $foreground = [ClipLite.Native.FocusHelper]::ForegroundWindow
        if ($foreground -ne [IntPtr]::Zero -and $foreground -ne $script:Form.Handle) {
            $script:Form.Hide()
        }
    }
    # Windows may decline activation when opening from a global hotkey. In that
    # case no Deactivate event follows the first outside click.
    $script:FocusTimer = New-Object System.Windows.Forms.Timer
    $script:FocusTimer.Interval = 250
    $script:FocusTimer.Add_Tick({ Hide-IfForegroundChanged })
    $script:Form.Add_VisibleChanged({
        $script:FocusTimer.Enabled = $script:Form.Visible
    })
    $script:Form.Add_Deactivate({
        if ($script:IsExiting -or $script:IsModalOpen -or $script:IsHidingInternally) { return }
        if (-not $script:Form.Visible) { return }
        [void]$script:Form.BeginInvoke([System.Windows.Forms.MethodInvoker]{
            Hide-IfForegroundChanged
        })
    })

    Refresh-TemplateList
    Set-ActiveTab $script:LastSelectedTab -NoSave

    # ================= タスクトレイ =================
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $showItem = $menu.Items.Add('履歴を表示')
    $pauseItem = $menu.Items.Add('監視を一時停止')
    $clearItem = $menu.Items.Add('履歴を全消去')
    [void]$menu.Items.Add('-')
    $exitItem = $menu.Items.Add('終了')

    $showItem.Add_Click({ Show-HistoryWindow })
    $pauseItem.Add_Click({
        $script:IsPaused = -not $script:IsPaused
        if ($script:IsPaused) {
            $pauseItem.Text = '監視を再開'
            $script:NotifyIcon.Text = 'ClipLite（監視停止中）'
        } else {
            $pauseItem.Text = '監視を一時停止'
            $script:NotifyIcon.Text = 'ClipLite'
        }
    })
    $clearItem.Add_Click({ Clear-History })
    $exitItem.Add_Click({ Exit-ClipLite })

    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    $script:NotifyIcon.Text = 'ClipLite'
    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.Visible = $true
    $script:NotifyIcon.Add_DoubleClick({ Show-HistoryWindow })

    $script:MessageWindow = [ClipLite.Native.MessageWindow]::new()
    $script:MessageWindow.add_ClipboardChanged({ Capture-Clipboard })

    $doubleCtrlThresholdMs = 400
    $thresholdProperty = $script:Config.PSObject.Properties['DoubleCtrlThresholdMs']
    if ($null -ne $thresholdProperty) {
        $parsedThreshold = 0
        if ([int]::TryParse([string]$thresholdProperty.Value, [ref]$parsedThreshold) -and $parsedThreshold -gt 0) {
            $doubleCtrlThresholdMs = $parsedThreshold
        }
    }
    try {
        [void]$script:Form.Handle
        $script:CtrlHook = [ClipLite.Native.DoubleCtrlHook]::new($doubleCtrlThresholdMs, $script:Form)
        $script:CtrlHook.add_DoubleCtrlPressed({ Show-HistoryWindow -FromHotkey })
    } catch {
        $script:CtrlHook = $null
        $script:NotifyIcon.BalloonTipTitle = 'ClipLite'
        $script:NotifyIcon.BalloonTipText = 'Ctrlキー2回押しを登録できませんでした。タスクトレイから開いてください。'
        $script:NotifyIcon.ShowBalloonTip(5000)
        Write-StartupLog ('DoubleCtrlHook 初期化失敗: ' + $_.Exception.Message)
    }

    Write-StartupLog ('起動しました。' + $script:AppVersion)
    $script:NotifyIcon.BalloonTipTitle = 'ClipLite'
    $script:NotifyIcon.BalloonTipText = '起動しました。Ctrlキーを素早く2回押すと表示できます。'
    $script:NotifyIcon.ShowBalloonTip(3000)
    Capture-Clipboard
    Show-ConsoleNotice   # ★追加
    [System.Windows.Forms.Application]::Run()
}
catch {
    Write-StartupLog ('Startup failed: ' + $_.Exception.GetType().FullName)
    Show-Error ($_.Exception.Message)
}
finally {
    try {
        if ($null -ne $script:NotifyIcon) {
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
        }
    } catch { }
    try { if ($null -ne $script:FocusTimer) { $script:FocusTimer.Dispose() } } catch { }
    try { if ($null -ne $script:CtrlHook) { $script:CtrlHook.Dispose() } } catch { }
    try { if ($null -ne $script:MessageWindow) { $script:MessageWindow.Dispose() } } catch { }
    try {
        if ($script:OwnsMutex -and $null -ne $script:Mutex) { $script:Mutex.ReleaseMutex() }
        if ($null -ne $script:Mutex) { $script:Mutex.Dispose() }
    } catch { }
}
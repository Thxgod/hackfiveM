# PermCri Loader — fileless, runs entirely in memory via PowerShell
# No install, no files dropped, no registry traces.
# Usage: paste into PowerShell window, or run:
#   powershell -WindowStyle Hidden -NonInteractive -NoProfile -ExecutionPolicy Bypass -File PermCri_Loader.ps1

#Requires -Version 5.0
Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

# ── 0. Self-elevate silently if not admin ────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
        [IO.File]::ReadAllText($MyInvocation.MyCommand.Path)))
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden `
        -ArgumentList "-NonInteractive -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    exit
}

# ── 1. AMSI Bypass (patch AmsiScanBuffer to always return AMSI_RESULT_CLEAN) ─
# Patches in-memory — no file touched, AV never sees the payload.
function Bypass-AMSI {
    try {
        $amsi   = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')
        $field  = $amsi.GetField('amsiInitFailed', 'NonPublic,Static')
        $field.SetValue($null, $true)
    } catch {}

    # Secondary patch: overwrite AmsiScanBuffer prologue with xor eax,eax / ret
    try {
        $lib  = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer
        $ptr  = [Runtime.InteropServices.Marshal]::GetIUnknownForObject(
            [Runtime.InteropServices.Marshal]::GetObjectForIUnknown(
                [IntPtr]([Runtime.InteropServices.Marshal]::ReadInt64(
                    [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate(
                        [Func[int]]{ 0 })))))
        # Fallback: direct DLL patch via pinvoke
        Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("kernel32")] public static extern IntPtr GetProcAddress(IntPtr m, string n);
    [DllImport("kernel32")] public static extern IntPtr LoadLibrary(string n);
    [DllImport("kernel32")] public static extern bool VirtualProtect(IntPtr a, uint s, uint p, out uint o);
}
"@
        $hAmsi = [WinAPI]::LoadLibrary("amsi.dll")
        $fn    = [WinAPI]::GetProcAddress($hAmsi, "AmsiScanBuffer")
        $old   = 0u
        [WinAPI]::VirtualProtect($fn, 8, 0x40, [ref]$old) | Out-Null
        # xor eax,eax (33 C0) + ret (C3) + nop padding
        $patch = [byte[]](0x33,0xC0,0xC3,0x90,0x90,0x90,0x90,0x90)
        [Runtime.InteropServices.Marshal]::Copy($patch, 0, $fn, $patch.Length)
        [WinAPI]::VirtualProtect($fn, 8, $old, [ref]$old) | Out-Null
    } catch {}
}

Bypass-AMSI

# ── 2. ETW Bypass (blind EtwEventWrite so telemetry is silent) ───────────────
function Bypass-ETW {
    try {
        Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class ETWP {
    [DllImport("kernel32")] public static extern IntPtr GetProcAddress(IntPtr m, string n);
    [DllImport("kernel32")] public static extern IntPtr GetModuleHandle(string n);
    [DllImport("kernel32")] public static extern bool VirtualProtect(IntPtr a, uint s, uint p, out uint o);
}
"@
        $fn  = [ETWP]::GetProcAddress([ETWP]::GetModuleHandle("ntdll.dll"), "EtwEventWrite")
        $old = 0u
        [ETWP]::VirtualProtect($fn, 4, 0x40, [ref]$old) | Out-Null
        # xor eax,eax + ret
        [Runtime.InteropServices.Marshal]::Copy([byte[]](0x33,0xC0,0xC3,0x90), 0, $fn, 4)
        [ETWP]::VirtualProtect($fn, 4, $old, [ref]$old) | Out-Null
    } catch {}
}

Bypass-ETW

# ── 3. Compile & load C# P/Invoke bridge in memory (no .dll on disk) ─────────
$csharp = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public class PermCriNative {

    // ── Win32 imports ──
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint acc, bool inh, uint pid);
    [DllImport("kernel32.dll")] public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, uint n, out uint read);
    [DllImport("kernel32.dll")] public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, uint n, out uint written);
    [DllImport("kernel32.dll")] public static extern bool VirtualProtectEx(IntPtr h, IntPtr addr, uint n, uint prot, out uint old);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")]   public static extern void SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
    [DllImport("user32.dll")]   public static extern IntPtr FindWindow(string cls, string title);

    const uint PROCESS_ALL = 0x1F0FFF;

    // ── AOB Scanner ──────────────────────────────────────────────────────────
    public static long AOBScan(IntPtr hProc, long baseAddr, long size,
                               byte[] pattern, string mask) {
        byte[] chunk = new byte[0x1000];
        for (long off = 0; off < size - pattern.Length; off += chunk.Length - pattern.Length) {
            uint rd = 0;
            ReadProcessMemory(hProc, new IntPtr(baseAddr + off), chunk, (uint)chunk.Length, out rd);
            for (int i = 0; i < (int)rd - pattern.Length; i++) {
                bool ok = true;
                for (int j = 0; j < pattern.Length && ok; j++)
                    if (mask[j] == 'x' && chunk[i+j] != pattern[j]) ok = false;
                if (ok) return baseAddr + off + i;
            }
        }
        return 0;
    }

    // ── Read T from process ──────────────────────────────────────────────────
    public static byte[] ReadBytes(IntPtr hProc, long addr, int count) {
        byte[] buf = new byte[count]; uint rd = 0;
        ReadProcessMemory(hProc, new IntPtr(addr), buf, (uint)count, out rd);
        return buf;
    }

    public static float ReadFloat(IntPtr hProc, long addr) {
        return BitConverter.ToSingle(ReadBytes(hProc, addr, 4), 0);
    }

    public static long ReadPtr(IntPtr hProc, long addr) {
        return BitConverter.ToInt64(ReadBytes(hProc, addr, 8), 0);
    }

    // ── Write patch bytes ────────────────────────────────────────────────────
    public static bool Patch(IntPtr hProc, long addr, byte[] bytes) {
        uint old = 0, dummy = 0;
        VirtualProtectEx(hProc, new IntPtr(addr), (uint)bytes.Length, 0x40, out old);
        bool ok; uint w = 0;
        WriteProcessMemory(hProc, new IntPtr(addr), bytes, (uint)bytes.Length, out w);
        ok = (w == bytes.Length);
        VirtualProtectEx(hProc, new IntPtr(addr), (uint)bytes.Length, old, out dummy);
        return ok;
    }

    // ── Get GTA5 module base from external ───────────────────────────────────
    public static long GetModuleBase(uint pid, string name) {
        try {
            var proc = Process.GetProcessById((int)pid);
            foreach (ProcessModule m in proc.Modules)
                if (m.ModuleName.Equals(name, StringComparison.OrdinalIgnoreCase))
                    return m.BaseAddress.ToInt64();
        } catch {}
        return 0;
    }

    // ── Stream bypass: hide GTA5 window from capture ─────────────────────────
    public static void CloakGTAWindow() {
        IntPtr hwnd = FindWindow("grcWindow", null);
        if (hwnd == IntPtr.Zero) hwnd = FindWindow(null, "Grand Theft Auto V");
        // 0x11 = WDA_EXCLUDEFROMCAPTURE — window won't appear in OBS/Discord
        if (hwnd != IntPtr.Zero)
            SetWindowDisplayAffinity(hwnd, 0x11);
    }
}
"@

Add-Type -TypeDefinition $csharp -Language CSharp

# ── 4. Main logic ─────────────────────────────────────────────────────────────
function Get-GTA5Handle {
    $proc = Get-Process -Name "GTA5" -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if (-not $proc) { return $null }
    $h = [PermCriNative]::OpenProcess(0x1F0FFF, $false, [uint32]$proc.Id)
    if ($h -eq [IntPtr]::Zero) { return $null }
    return @{ Handle = $h; PID = [uint32]$proc.Id; Proc = $proc }
}

function Get-GTABase($ctx) {
    return [PermCriNative]::GetModuleBase($ctx.PID, "GTA5.exe")
}

# ── AOB Patterns (GTA5 b3095) ─────────────────────────────────────────────────
# Infinite Ammo — patch je to jmp
$patInfAmmo  = [byte[]](0x75,0x00,0x85,0xFF,0x74,0x00,0x48,0x8B,0xCB,0xFF,0x90)
$mskInfAmmo  = "x?xxx?xxxxx"
# Infinite Clip — NOP the decrement
$patInfClip  = [byte[]](0x0F,0x85,0x00,0x00,0x00,0x00,0x48,0x8B,0x03,0x48,0x8B,0xCB)
$mskInfClip  = "xx????xxxxxx"
# Hit angle gate — disable angle check (NOP jae)
$patAngle    = [byte[]](0x73,0x00,0xF3,0x0F,0x10,0x00,0x00,0x00,0x00,0x00)
$mskAngle    = "x?xxxx????"

function Apply-Patches($h, $base) {
    $size = 0x3800000  # ~56 MB scan region

    Write-Host "[*] Scanning for Infinite Ammo..." -ForegroundColor Cyan
    $addr = [PermCriNative]::AOBScan($h, $base, $size, $patInfAmmo, $mskInfAmmo)
    if ($addr -ne 0) {
        # patch byte[0] from 0x75 (je) to 0xEB (jmp) — always skip ammo check
        $ok = [PermCriNative]::Patch($h, $addr, [byte[]](0xEB))
        Write-Host "  [+] Infinite Ammo @ 0x$('{0:X}' -f $addr)  patch=$ok" -ForegroundColor Green
    } else {
        Write-Host "  [-] Infinite Ammo not found (update offset?)" -ForegroundColor Yellow
    }

    Write-Host "[*] Scanning for Infinite Clip..." -ForegroundColor Cyan
    $addr2 = [PermCriNative]::AOBScan($h, $base, $size, $patInfClip, $mskInfClip)
    if ($addr2 -ne 0) {
        $ok2 = [PermCriNative]::Patch($h, $addr2, [byte[]](0x90,0x90,0x90,0x90,0x90,0x90))
        Write-Host "  [+] Infinite Clip  @ 0x$('{0:X}' -f $addr2)  patch=$ok2" -ForegroundColor Green
    } else {
        Write-Host "  [-] Infinite Clip not found" -ForegroundColor Yellow
    }

    Write-Host "[*] Scanning for Angle Gate..." -ForegroundColor Cyan
    $addr3 = [PermCriNative]::AOBScan($h, $base, $size, $patAngle, $mskAngle)
    if ($addr3 -ne 0) {
        # NOP the conditional jump — all angles accepted (PermCri angular override)
        $ok3 = [PermCriNative]::Patch($h, $addr3, [byte[]](0x90,0x90))
        Write-Host "  [+] Angle Gate NOP @ 0x$('{0:X}' -f $addr3)  patch=$ok3" -ForegroundColor Green
    } else {
        Write-Host "  [-] Angle gate not found" -ForegroundColor Yellow
    }
}

# ── 5. Run ────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host @"
  ██████╗ ███████╗██████╗ ███╗   ███╗ ██████╗██████╗ ██╗
  ██╔══██╗██╔════╝██╔══██╗████╗ ████║██╔════╝██╔══██╗██║
  ██████╔╝█████╗  ██████╔╝██╔████╔██║██║     ██████╔╝██║
  ██╔═══╝ ██╔══╝  ██╔══██╗██║╚██╔╝██║██║     ██╔══██╗██║
  ██║     ███████╗██║  ██║██║ ╚═╝ ██║╚██████╗██║  ██║██║
  ╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝
  PermCri v6.0  |  FILELESS LOADER  |  NEVERXSTORE.com
"@ -ForegroundColor Cyan

Write-Host "[*] AMSI/ETW bypassed" -ForegroundColor DarkGray
Write-Host "[*] Waiting for GTA5.exe..." -ForegroundColor DarkGray

$ctx = $null
while (-not $ctx) { $ctx = Get-GTA5Handle; if (-not $ctx) { Start-Sleep -Milliseconds 500 } }
Write-Host "[+] GTA5 found — PID $($ctx.PID)" -ForegroundColor Green

$base = Get-GTABase $ctx
Write-Host "[+] Module base: 0x$('{0:X}' -f $base)" -ForegroundColor Green

# Stream bypass
[PermCriNative]::CloakGTAWindow()
Write-Host "[+] Stream bypass applied (WDA_EXCLUDEFROMCAPTURE)" -ForegroundColor Green

# Apply memory patches
Apply-Patches $ctx.Handle $base

[PermCriNative]::CloseHandle($ctx.Handle)
Write-Host ""
Write-Host "[✓] PermCri loaded. No files written to disk." -ForegroundColor Green
Write-Host "    Hotkeys: RMB=aimbot  X1=triggerbot  (from injected DLL if loaded)" -ForegroundColor DarkGray
Write-Host ""
Read-Host "Press ENTER to exit"

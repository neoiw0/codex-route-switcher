# Codex-RouteSwitcher-Friend.ps1
# Friend edition: this script contains NO API keys.
# Keys are typed by the user and saved to Windows user environment variables only.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CodexHomePath = Join-Path $env:USERPROFILE '.codex'
$ConfigPath = Join-Path $CodexHomePath 'config.toml'
$DirectLaunchPath = Join-Path $PSScriptRoot 'Start-Codex-Direct-Friend.ps1'
$SwitchLogPath = Join-Path $PSScriptRoot 'switch.log'
$OpenCodeProxyBaseUrl = 'https://opencode.ai/zen/go/v1'
$FoxBaseUrl = 'https://dm-fox.rjj.cc/codex/v1'
$Efforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
$DeepSeekContextWindow = 1000000
$DefaultContextWindow = 272000
$DeepSeekReviewModel = 'deepseek-v4-flash'
$OpenCodeModels = @(
    'deepseek-v4-flash', 'deepseek-v4-pro', 'glm-5.1', 'glm-5.2',
    'gpt-5.6-luna', 'grok-4.5', 'hy3', 'kimi-k2.6', 'kimi-k2.7-code',
    'kimi-k3', 'mimo-v2.5', 'mimo-v2.5-pro', 'minimax-m2.7',
    'minimax-m3', 'qwen3.6-plus', 'qwen3.7-max', 'qwen3.7-plus',
    'qwen3.8-max', 'hy3-preview', 'glm-5', 'kimi-k2.5',
    'mimo-v2-omni', 'mimo-v2-pro', 'minimax-m2.5', 'qwen3.5-plus'
)

function Write-Log {
    param([string]$Message)

    try {
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $SwitchLogPath -Value $line -Encoding UTF8
    }
    catch {
    }
}

function Stop-CodexProcesses {
    param([int]$MaxWaitSeconds = 30)

    $names = @('ChatGPT', 'Codex', 'codex-computer-use')
    $remaining = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Write-Log 'stop: no Codex/ChatGPT process running'
        return $true
    }
    $started = Get-Date
    $deadline = $started.AddSeconds($MaxWaitSeconds)
    while ($true) {
        $remaining = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Write-Log ('stop: all processes exited after {0:N1}s' -f ((Get-Date) - $started).TotalSeconds)
            return $true
        }
        if ((Get-Date) -ge $deadline) {
            $still = ($remaining | ForEach-Object { "$($_.ProcessName)(pid=$($_.Id))" }) -join ', '
            Write-Log "stop: TIMEOUT after $MaxWaitSeconds s - still running: $still"
            Write-Host ''
            Write-Host 'WARNING: some Codex processes did not exit.'
            Write-Host 'Close them via Task Manager (or taskbar icon -> Exit), then run this switcher again.'
            return $false
        }
        foreach ($proc in $remaining) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-Log "stop: terminated $($proc.ProcessName) pid=$($proc.Id)"
            }
            catch {
                Write-Log "stop: failed to terminate $($proc.ProcessName) pid=$($proc.Id): $($_.Exception.Message)"
            }
        }
        Start-Sleep -Milliseconds 500
    }
}

function Find-NewSessionFile {
    param(
        [string]$SessionRoot,
        [datetime]$After
    )

    $dirs = @()
    foreach ($day in @((Get-Date), (Get-Date).AddDays(-1))) {
        $dir = Join-Path $SessionRoot ($day.ToString('yyyy/MM/dd'))
        if (Test-Path -LiteralPath $dir) { $dirs += $dir }
    }
    foreach ($dir in $dirs) {
        $hit = Get-ChildItem -LiteralPath $dir -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.CreationTime -gt $After } |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1
        if ($null -ne $hit) { return $hit }
    }
    return $null
}

function Test-DynamicToolsNamespace {
    param([string]$SessionPath)

    $fileStream = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $fileStream = [System.IO.File]::Open($SessionPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            break
        }
        catch {
            if ($attempt -eq 5) {
                return @{ ok = $false; detail = "cannot open session file after 5 tries (locked by app?): $($_.Exception.Message)" }
            }
            Start-Sleep -Seconds 1
        }
    }
    $reader = [System.IO.StreamReader]::new($fileStream)
    try {
        $firstLine = $reader.ReadLine()
    }
    finally {
        $reader.Dispose()
        $fileStream.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($firstLine)) {
        return @{ ok = $false; detail = 'session first line is empty' }
    }
    try {
        $first = $firstLine | ConvertFrom-Json
    }
    catch {
        return @{ ok = $false; detail = "first line is not JSON: $($_.Exception.Message)" }
    }
    $meta = $first.session_meta
    if ($null -eq $meta) {
        return @{ ok = $false; detail = 'session_meta is missing (app version may not record tool metadata)' }
    }
    $tools = $meta.dynamic_tools
    if ($null -eq $tools) {
        return @{ ok = $false; detail = 'session_meta.dynamic_tools is missing (app version may not record tool metadata)' }
    }
    $flat = @($tools)
    $ns = @($flat | Where-Object { $_.type -eq 'namespace' -and $_.name -eq 'codex_app' })
    if ($ns.Count -gt 0) {
        $toolCount = @($ns[0].tools).Count
        return @{ ok = $true; detail = "namespace codex_app with $toolCount tools" }
    }
    $funcs = @($flat | Where-Object { $_.type -eq 'function' })
    $firstName = if ($funcs.Count -gt 0) { $funcs[0].name } else { 'unknown' }
    return @{ ok = $false; detail = "flat functions ($($funcs.Count) tools, first=$firstName) instead of namespace" }
}

function Verify-DynamicTools {
    param([int]$WaitSeconds = 120)

    $sessionRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    $restartedAt = Get-Date
    Write-Log "verify: watching for a new session under $sessionRoot since $($restartedAt.ToString('yyyy-MM-dd HH:mm:ss'))"
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $sessionFile = $null
    while ((Get-Date) -lt $deadline) {
        $sessionFile = Find-NewSessionFile -SessionRoot $sessionRoot -After $restartedAt
        if ($null -ne $sessionFile) { break }
        Start-Sleep -Seconds 2
    }
    if ($null -eq $sessionFile) {
        Write-Log "verify: no new session file within $WaitSeconds s - open a NEW chat and check switch.log"
        Write-Host ''
        Write-Host 'No new chat session was detected in time.'
        Write-Host 'Open a NEW chat window in Codex, then check switch.log for the verification result.'
        return
    }
    Write-Log "verify: new session found: $($sessionFile.Name)"
    $result = Test-DynamicToolsNamespace -SessionPath $sessionFile.FullName
    if ($result.ok) {
        Write-Log "verify: OK - $($result.detail)"
        Write-Host ''
        Write-Host "Verification OK: $($result.detail) - new chats should work."
    }
    else {
        Write-Log "verify: WARNING - $($result.detail)"
        Write-Host ''
        Write-Host "WARNING: $($result.detail)"
        Write-Host 'This usually means Codex was not fully restarted after the route switch.'
        Write-Host 'Fully quit Codex (taskbar icon -> Exit), run this switcher again, and open a NEW chat.'
        Write-Host 'Existing chats remain usable in the meantime.'
    }
}

function Get-LineEnding {
    param([string]$Text)

    $crlf = [string][char]13 + [char]10
    if ($Text.Contains($crlf)) {
        return $crlf
    }
    return [string][char]10
}

function TomlString {
    param([string]$Value)

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Set-TomlValue {
    param(
        [string]$Text,
        [AllowEmptyString()]
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $lineEnding = Get-LineEnding -Text $Text
    $trailing = $Text.EndsWith($lineEnding)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [regex]::Split($Text, '\r\n|\n|\r')) {
        [void]$lines.Add($line)
    }
    if ($trailing -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }

    $headerPattern = '^\s*\[(?<section>[^\]]+)\]\s*(?:#.*)?$'
    $keyPattern = '^(?<indent>\s*)' + [regex]::Escape($Key) + '\s*=.*$'
    $current = ''
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $header = [regex]::Match($lines[$index], $headerPattern)
        if ($header.Success) {
            $current = $header.Groups['section'].Value.Trim()
            continue
        }
        if ($current -eq $Section) {
            $match = [regex]::Match($lines[$index], $keyPattern)
            if ($match.Success) {
                $lines[$index] = $match.Groups['indent'].Value + $Key + ' = ' + $Value
                $updated = $lines -join $lineEnding
                if ($trailing) {
                    $updated += $lineEnding
                }
                return $updated
            }
        }
    }

    if ($Section -eq '') {
        $insertAt = $lines.Count
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ([regex]::IsMatch($lines[$index], $headerPattern)) {
                $insertAt = $index
                break
            }
        }
        $lines.Insert($insertAt, $Key + ' = ' + $Value)
    }
    else {
        $headerAt = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $header = [regex]::Match($lines[$index], $headerPattern)
            if ($header.Success -and $header.Groups['section'].Value.Trim() -eq $Section) {
                $headerAt = $index
                break
            }
        }
        if ($headerAt -lt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('[' + $Section + ']')
            [void]$lines.Add($Key + ' = ' + $Value)
        }
        else {
            $insertAt = $lines.Count
            for ($index = $headerAt + 1; $index -lt $lines.Count; $index++) {
                if ([regex]::IsMatch($lines[$index], $headerPattern)) {
                    $insertAt = $index
                    break
                }
            }
            $lines.Insert($insertAt, $Key + ' = ' + $Value)
        }
    }

    $updated = $lines -join $lineEnding
    if ($trailing) {
        $updated += $lineEnding
    }
    return $updated
}

function Get-FoxModels {
    $catalogPath = Join-Path $CodexHomePath 'fox-model-catalog.json'
    if (Test-Path -LiteralPath $catalogPath) {
        try {
            $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
            $models = @($catalog.models | ForEach-Object { [string]$_.slug } | Sort-Object -Unique)
            if ($models.Count -gt 0) {
                return $models
            }
        }
        catch {
        }
    }
    return @('claude-opus-5', 'gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra')
}

function Select-FromList {
    param([string]$Title, [string[]]$Items)

    Write-Host ''
    Write-Host $Title
    for ($index = 0; $index -lt $Items.Count; $index++) {
        Write-Host ('  {0}) {1}' -f ($index + 1), $Items[$index])
    }
    $choice = [int](Read-Host 'Select')
    if ($choice -lt 1 -or $choice -gt $Items.Count) {
        throw 'Invalid selection.'
    }
    return $Items[$choice - 1]
}

function Resolve-Effort {
    param([string]$Model, [string]$Requested)

    switch ($Model.ToLowerInvariant()) {
        'deepseek-v4-flash' {
            if ($Requested -eq 'low') { return 'low' }
            if ($Requested -in @('medium', 'high')) { return 'high' }
            return 'max'
        }
        'deepseek-v4-pro' {
            if ($Requested -in @('xhigh', 'max', 'ultra')) { return 'max' }
            return 'high'
        }
        'grok-4.5' {
            if ($Requested -in @('low', 'medium')) { return $Requested }
            return 'high'
        }
        'hy3' {
            if ($Requested -eq 'low') { return 'low' }
            return 'high'
        }
        'hy3-preview' {
            if ($Requested -eq 'low') { return 'low' }
            return 'high'
        }
        'glm-5.2' {
            if ($Requested -in @('xhigh', 'max', 'ultra')) { return 'max' }
            return 'high'
        }
        'kimi-k3' { return 'max' }
        'minimax-m3' {
            if ($Requested -eq 'low') { return 'low' }
            return 'high'
        }
        default {
            if ($Model -like 'qwen*') {
                if ($Requested -eq 'low') { return 'low' }
                return 'high'
            }
            if ($Requested -eq 'ultra') { return 'max' }
            return $Requested
        }
    }
}


function Get-OrSetApiKey {
    param([string]$EnvironmentKey)

    $existing = [Environment]::GetEnvironmentVariable($EnvironmentKey, 'User')
    if (-not [string]::IsNullOrEmpty($existing)) {
        Write-Host ''
        Write-Host "A key for $EnvironmentKey is already saved on this PC."
        $answer = Read-Host 'Keep the saved key? (y = keep, n = enter a new key)'
        if ($answer -notmatch '^[nN]') {
            Write-Host "Using the saved $EnvironmentKey."
            return
        }
    }

    Write-Host ''
    Write-Host "Enter your $EnvironmentKey. It is saved to your Windows user environment"
    Write-Host 'variables only and is never written into this script or any file next to it.'
    $secure = Read-Host 'API key' -AsSecureString
    if ($null -eq $secure -or $secure.Length -eq 0) {
        throw 'API key cannot be empty.'
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrEmpty($plain)) {
        throw 'API key cannot be empty.'
    }
    [Environment]::SetEnvironmentVariable($EnvironmentKey, $plain, 'User')
    Set-Item -Path "Env:$EnvironmentKey" -Value $plain
    Write-Host "Saved $EnvironmentKey for the current user."
}

function Test-SupplierConnection {
    Write-Host ''
    Write-Host '  1) CC - Fox'
    Write-Host '  2) CC - OpenCode Go'
    $target = Read-Host 'Test which supplier'
    switch ($target) {
        '1' {
            $keyName = 'FOX_API_KEY'
            $url = $FoxBaseUrl.TrimEnd('/') + '/responses'
        }
        '2' {
            $keyName = 'OPENCODE_API_KEY'
            $url = $OpenCodeProxyBaseUrl + '/responses'
        }
        default { throw 'Invalid selection.' }
    }

    $key = [Environment]::GetEnvironmentVariable($keyName, 'User')
    if ([string]::IsNullOrEmpty($key)) {
        throw "Key $keyName is not saved yet. Run the switch first."
    }

    $payload = @{
        model             = 'deepseek-v4-flash'
        input             = 'Reply with exactly: OK'
        max_output_tokens = 64
        reasoning         = @{ effort = 'low' }
    } | ConvertTo-Json -Depth 5
    $body = [System.Text.Encoding]::UTF8.GetBytes($payload)

    Write-Host ''
    Write-Host "Testing $url ..."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Uri $url -Method Post `
            -Headers @{ Authorization = "Bearer $key" } `
            -ContentType 'application/json' -Body $body -TimeoutSec 40
        $stopwatch.Stop()
        $hasMessage = @($response.output | Where-Object { $_.type -eq 'message' }).Count -gt 0
        Write-Host ("OK in {0:N1}s. model={1} status={2} contentReceived={3}" -f `
            $stopwatch.Elapsed.TotalSeconds, $response.model, $response.status, $hasMessage)
        Write-Log ("test OK {0} in {1:N1}s" -f $url, $stopwatch.Elapsed.TotalSeconds)
    }
    catch {
        $stopwatch.Stop()
        $detail = $_.Exception.Message
        try {
            if ($null -ne $_.Exception.Response) {
                $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $bodyText = $reader.ReadToEnd()
                $reader.Dispose()
                if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                    $detail = $bodyText
                }
            }
        }
        catch {
        }
        Write-Host ("FAILED after {0:N1}s: {1}" -f $stopwatch.Elapsed.TotalSeconds, $detail)
        Write-Host 'Check your network to opencode.ai (no local proxy is needed).'
        Write-Log ("test FAILED {0} after {1:N1}s: {2}" -f $url, $stopwatch.Elapsed.TotalSeconds, $detail)
    }
}

function Update-Route {
    param(
        [string]$Model,
        [string]$RequestedEffort,
        [string]$BaseUrl,
        [string]$EnvironmentKey
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Missing Codex config. Install and start Codex Desktop once first: $ConfigPath"
    }
    $configBackup = Join-Path $CodexHomePath ('config.toml.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $ConfigPath -Destination $configBackup -Force
    Write-Log "config backed up: $configBackup"
    $appliedEffort = Resolve-Effort -Model $Model -Requested $RequestedEffort
    $text = [System.IO.File]::ReadAllText($ConfigPath)
    $text = Set-TomlValue -Text $text -Section '' -Key 'model_provider' -Value (TomlString 'CC')
    $text = Set-TomlValue -Text $text -Section '' -Key 'model' -Value (TomlString $Model)
    $text = Set-TomlValue -Text $text -Section '' -Key 'model_reasoning_effort' -Value (TomlString $appliedEffort)
    $isDeepSeek = $Model -like 'deepseek-*'
    $contextWindow = if ($isDeepSeek) { $DeepSeekContextWindow } else { $DefaultContextWindow }
    $text = Set-TomlValue -Text $text -Section '' -Key 'model_context_window' -Value ([string]$contextWindow)
    $reviewModel = if ($isDeepSeek) { $DeepSeekReviewModel } else { $Model }
    $text = Set-TomlValue -Text $text -Section '' -Key 'review_model' -Value (TomlString $reviewModel)
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'name' -Value (TomlString 'CC')
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'base_url' -Value (TomlString $BaseUrl)
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'wire_api' -Value (TomlString 'responses')
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'env_key' -Value (TomlString $EnvironmentKey)
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'requires_openai_auth' -Value 'false'
    $efforts = '[ "low", "medium", "high", "xhigh", "max", "ultra" ]'
    $text = Set-TomlValue -Text $text -Section 'desktop' -Key 'enabled-reasoning-efforts' -Value $efforts
    [System.IO.File]::WriteAllText($ConfigPath, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Log "model_context_window=$contextWindow review_model=$reviewModel"

    Write-Host ''
    Write-Host 'Switched.'
    Write-Host "  provider label: CC"
    Write-Host "  model: $Model"
    Write-Host "  effort: $appliedEffort"
    Write-Host "  context window: $contextWindow"
    Write-Host "  review model: $reviewModel"
}


function Update-SessionProvider {
    param(
        [string]$Path,
        [string]$TargetProvider
    )

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 1024, $true)
        $firstLine = $reader.ReadLine()
        $rest = $reader.ReadToEnd()
        $reader.Dispose()

        $m = [regex]::Match($firstLine, '"model_provider"\s*:\s*"([^"]*)"')
        if (-not $m.Success) { return @{ Changed = $false; OldProvider = $null } }
        $old = $m.Groups[1].Value
        if ($old -eq $TargetProvider) { return @{ Changed = $false; OldProvider = $old } }

        $newFirst = [regex]::Replace($firstLine, '"model_provider"\s*:\s*"[^"]*"', ('"model_provider": "' + $TargetProvider + '"'), 1)

        $fs.SetLength(0)
        $fs.Position = 0
        $writer = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)), 1024, $true)
        $writer.Write($newFirst)
        $writer.Write([string][char]10)
        $writer.Write($rest)
        $writer.Flush()
        $writer.Dispose()

        Write-Log "provider fix: $Path : $old -> $TargetProvider"
        return @{ Changed = $true; OldProvider = $old }
    }
    finally {
        $fs.Dispose()
    }
}

function Get-ConfigModel {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $text = [System.IO.File]::ReadAllText($ConfigPath)
    $m = [regex]::Match($text, '(?m)^model\s*=\s*"([^"]+)"')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Update-HistoryDatabase {
    param(
        [string]$TargetProvider,
        [string]$TargetModel
    )

    $dbPath = Join-Path $CodexHomePath 'state_5.sqlite'
    if (-not (Test-Path -LiteralPath $dbPath)) {
        Write-Host "  state database not found, skipping: $dbPath"
        return @{ Updated = 0; Remaining = -1 }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = $dbPath + '.backup-provider-cc-' + $stamp
    Copy-Item -LiteralPath $dbPath -Destination $backup -Force
    foreach ($suffix in @('-wal', '-shm')) {
        $side = $dbPath + $suffix
        if (Test-Path -LiteralPath $side) {
            Copy-Item -LiteralPath $side -Destination ($backup + $suffix) -Force
        }
    }
    Write-Log "state db backed up: $backup"
    Write-Host "  state db backed up: $(Split-Path $backup -Leaf)"

    if (-not ('WinSqliteHelper' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WinSqliteHelper {
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern int sqlite3_open_v2(string filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern int sqlite3_exec(IntPtr db, string sql, IntPtr cb, IntPtr arg, out IntPtr errmsg);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern int sqlite3_changes(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern int sqlite3_prepare_v2(IntPtr db, string sql, int nByte, out IntPtr stmt, IntPtr pzTail);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr sqlite3_column_text(IntPtr stmt, int iCol);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern int sqlite3_close(IntPtr db);
}
"@
    }

    $db = [IntPtr]::Zero
    $rc = [WinSqliteHelper]::sqlite3_open_v2($dbPath, [ref]$db, 6, [IntPtr]::Zero)
    if ($rc -ne 0) {
        Write-Log "state db open failed rc=$rc"
        Write-Host '  ERROR: could not open the state database'
        return @{ Updated = 0; Remaining = -1 }
    }
    try {
        if ([string]::IsNullOrEmpty($TargetModel)) {
            $setClause = "model_provider = '$TargetProvider'"
            $whereClause = "model_provider IS NULL OR model_provider <> '$TargetProvider'"
        }
        else {
            if ($TargetModel -notmatch '^[A-Za-z0-9._-]+$') {
                Write-Log "state db update aborted: invalid target model: $TargetModel"
                Write-Host "  ERROR: invalid target model: $TargetModel"
                return @{ Updated = 0; Remaining = -1 }
            }
            $setClause = "model_provider = '$TargetProvider', model = '$TargetModel'"
            $whereClause = "model_provider IS NULL OR model_provider <> '$TargetProvider' OR model IS NULL OR model <> '$TargetModel'"
        }
        $sql = "UPDATE threads SET $setClause WHERE $whereClause"
        $err = [IntPtr]::Zero
        $rc = [WinSqliteHelper]::sqlite3_exec($db, $sql, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$err)
        if ($rc -ne 0) {
            $msg = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi([WinSqliteHelper]::sqlite3_errmsg($db))
            Write-Log "state db update failed: $msg"
            Write-Host "  ERROR updating state db: $msg"
            return @{ Updated = 0; Remaining = -1 }
        }
        $changed = [WinSqliteHelper]::sqlite3_changes($db)

        $checkSql = "SELECT COUNT(*) FROM threads WHERE $whereClause"
        $stmt = [IntPtr]::Zero
        [void][WinSqliteHelper]::sqlite3_prepare_v2($db, $checkSql, -1, [ref]$stmt, [IntPtr]::Zero)
        $remaining = -1
        if ([WinSqliteHelper]::sqlite3_step($stmt) -eq 100) {
            $ptr = [WinSqliteHelper]::sqlite3_column_text($stmt, 0)
            if ($ptr -ne [IntPtr]::Zero) { $remaining = [int][System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($ptr) }
        }
        [void][WinSqliteHelper]::sqlite3_finalize($stmt)

        [void][WinSqliteHelper]::sqlite3_exec($db, 'PRAGMA wal_checkpoint(TRUNCATE)', [IntPtr]::Zero, [IntPtr]::Zero, [ref]$err)
        Write-Log "state db updated: rows=$changed remaining=$remaining provider=$TargetProvider model=$TargetModel"
        return @{ Updated = $changed; Remaining = $remaining }
    }
    finally {
        [void][WinSqliteHelper]::sqlite3_close($db)
    }
}

function Fix-HistoryProvider {
    param(
        [string]$TargetProvider = 'CC'
    )

    if ([string]::IsNullOrEmpty($TargetProvider)) {
        Write-Host 'ERROR: no target provider specified.'
        return
    }
    Write-Host "Target: provider=$TargetProvider (chat models left unchanged)"

    $dbResult = Update-HistoryDatabase -TargetProvider $TargetProvider
    if ($null -eq $dbResult) { return }
    if ($dbResult.Remaining -eq 0) {
        Write-Host "  state db: all chat records now use provider $TargetProvider"
    }
    elseif ($dbResult.Remaining -gt 0) {
        Write-Host "  state db: updated=$($dbResult.Updated) remaining=$($dbResult.Remaining) - please rerun"
    }
    else {
        Write-Host '  state db: update failed (see switch.log)'
    }

    $sessionRoot = Join-Path $CodexHomePath 'sessions'
    if (-not (Test-Path -LiteralPath $sessionRoot)) {
        Write-Host "No sessions folder found: $sessionRoot"
        return
    }

    $files = @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'rollout-*.jsonl' -or $_.Name -like 'review-rollout-*.jsonl' })
    Write-Host "Scanning $($files.Count) session files for provider..."

    $updated = 0
    $skipped = 0
    $failed = 0
    $byProvider = @{}
    foreach ($file in $files) {
        $result = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $result = Update-SessionProvider -Path $file.FullName -TargetProvider $TargetProvider
                break
            }
            catch {
                if ($attempt -eq 5) {
                    $failed++
                    Write-Log "provider fix FAILED: $($file.FullName) - $($_.Exception.Message)"
                    Write-Host "  FAILED: $($file.Name)"
                }
                else { Start-Sleep -Milliseconds 300 }
            }
        }
        if ($null -eq $result) { continue }
        if ($result.Changed) {
            $updated++
            if (-not $byProvider.ContainsKey($result.OldProvider)) { $byProvider[$result.OldProvider] = 0 }
            $byProvider[$result.OldProvider]++
        }
        else { $skipped++ }
    }

    Write-Host ''
    Write-Host "Done. session files: changed=$updated skipped=$skipped failed=$failed"
    foreach ($k in $byProvider.Keys) { Write-Host "  provider $k -> $TargetProvider : $($byProvider[$k])" }
    Write-Log "provider fix done: session files changed=$updated skipped=$skipped failed=$failed sources=$($byProvider | ConvertTo-Json -Compress)"
    if ($updated -gt 0 -or $dbResult.Updated -gt 0) {
        Write-Host ''
        Write-Host 'Old chats are now bound to CC (chat models kept as they are).'
        Write-Host 'Fully quit and reopen Codex to see them.'
    }
}

function Update-HistoryModels {
    param(
        [string]$TargetProvider = 'CC',
        [string]$TargetModel
    )

    if ([string]::IsNullOrEmpty($TargetModel)) {
        Write-Log 'history model sync skipped: no target model selected'
        return
    }
    Write-Host "  Syncing all old chats to model: $TargetModel"
    $dbResult = Update-HistoryDatabase -TargetProvider $TargetProvider -TargetModel $TargetModel
    if ($null -eq $dbResult) { return }
    if ($dbResult.Remaining -eq 0) {
        if ($dbResult.Updated -gt 0) {
            Write-Host "  Old chats: $($dbResult.Updated) record(s) synced to $TargetModel"
        }
        else {
            Write-Host "  Old chats: already all using $TargetModel"
        }
    }
    elseif ($dbResult.Remaining -gt 0) {
        Write-Host "  Old chats: updated=$($dbResult.Updated) remaining=$($dbResult.Remaining) - please rerun"
    }
    else {
        Write-Host '  Old chats: state db update failed (see switch.log)'
    }
    Write-Log "history model sync done: updated=$($dbResult.Updated) remaining=$($dbResult.Remaining) model=$TargetModel"
}
function Start-CodexDirect {
    if (-not (Test-Path -LiteralPath $DirectLaunchPath)) {
        throw "Missing direct launcher: $DirectLaunchPath"
    }
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $DirectLaunchPath
    Write-Log "launcher exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        throw "Direct launcher failed: $LASTEXITCODE"
    }
}

try {
    Write-Log 'switch start'
    Write-Host 'Codex Switcher (friend edition - no API keys included)'
    Write-Host '  1) CC - Fox (optional)'
    Write-Host '  2) CC - OpenCode Go (recommended / default)'
    Write-Host '  3) Test connection'
    Write-Host '  4) Fix old chat provider -> CC (name only, repair old chats)'
    $provider = Read-Host 'Supplier'

    switch ($provider) {
        '3' {
            Test-SupplierConnection
            Write-Host ''
            Read-Host 'Press Enter to close'
            exit 0
        }
        '1' {
            $model = Select-FromList -Title 'Fox models' -Items (Get-FoxModels)
            $baseUrl = $FoxBaseUrl
            $environmentKey = 'FOX_API_KEY'
        }
        '2' {
            $model = Select-FromList -Title 'OpenCode Go models' -Items $OpenCodeModels
            $baseUrl = $OpenCodeProxyBaseUrl
            $environmentKey = 'OPENCODE_API_KEY'
        }

        '4' {
            Write-Host ''
            Write-Host 'This will fully quit Codex, then rewrite the provider of every old chat to CC.'
            Write-Host 'Old chats from Fox / other suppliers become usable again.'
            Write-Host 'Each chat keeps its current model (use 1 or 2 to sync models).'
            if (-not (Stop-CodexProcesses)) {
                throw 'Codex processes did not exit in time. Close them via Task Manager and run again.'
            }
            Fix-HistoryProvider -TargetProvider 'CC'
            Write-Host ''
            Read-Host 'Press Enter to close'
            exit 0
        }
        default { throw 'Invalid supplier.' }
    }

    $requestedEffort = Select-FromList -Title 'Reasoning effort' -Items $Efforts
    Write-Log "supplier=$provider model=$model effort=$requestedEffort"
    Get-OrSetApiKey -EnvironmentKey $environmentKey
    if (-not (Stop-CodexProcesses)) {
        throw 'Codex processes did not exit in time. Close them via Task Manager and run the switcher again.'
    }
    Update-Route -Model $model -RequestedEffort $requestedEffort -BaseUrl $baseUrl -EnvironmentKey $environmentKey
    Write-Log 'route updated'
    Update-HistoryModels -TargetModel $model
    Start-CodexDirect
    Verify-DynamicTools
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
    exit 1
}
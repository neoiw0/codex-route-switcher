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

function Assert-CodexStopped {
    $processes = @(Get-Process -Name 'ChatGPT', 'codex', 'Codex' -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) {
        throw 'Exit Codex completely before switching. The script does not stop it for you.'
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
    $appliedEffort = Resolve-Effort -Model $Model -Requested $RequestedEffort
    $text = [System.IO.File]::ReadAllText($ConfigPath)
    $text = Set-TomlValue -Text $text -Section '' -Key 'model_provider' -Value (TomlString 'CC')
    $text = Set-TomlValue -Text $text -Section '' -Key 'model' -Value (TomlString $Model)
    $text = Set-TomlValue -Text $text -Section '' -Key 'model_reasoning_effort' -Value (TomlString $appliedEffort)
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'name' -Value (TomlString 'CC')
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'base_url' -Value (TomlString $BaseUrl)
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'wire_api' -Value (TomlString 'responses')
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'env_key' -Value (TomlString $EnvironmentKey)
    $text = Set-TomlValue -Text $text -Section 'model_providers.CC' -Key 'requires_openai_auth' -Value 'false'
    $efforts = '[ "low", "medium", "high", "xhigh", "max", "ultra" ]'
    $text = Set-TomlValue -Text $text -Section 'desktop' -Key 'enabled-reasoning-efforts' -Value $efforts
    [System.IO.File]::WriteAllText($ConfigPath, $text, [System.Text.UTF8Encoding]::new($false))

    Write-Host ''
    Write-Host 'Switched.'
    Write-Host "  provider label: CC"
    Write-Host "  model: $Model"
    Write-Host "  effort: $appliedEffort"
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
    Assert-CodexStopped
    Write-Host 'Codex Switcher (friend edition - no API keys included)'
    Write-Host '  1) CC - Fox'
    Write-Host '  2) CC - OpenCode Go'
Write-Host '  3) Test connection'
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
        default { throw 'Invalid supplier.' }
    }

    $requestedEffort = Select-FromList -Title 'Reasoning effort' -Items $Efforts
    Write-Log "supplier=$provider model=$model effort=$requestedEffort"
    Get-OrSetApiKey -EnvironmentKey $environmentKey
    Update-Route -Model $model -RequestedEffort $requestedEffort -BaseUrl $baseUrl -EnvironmentKey $environmentKey
    Write-Log 'route updated'
    Start-CodexDirect
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
    exit 1
}
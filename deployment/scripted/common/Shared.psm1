#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Csf {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-CsfFingerprint {
    param($Value)
    function ConvertTo-Canonical($Item) {
        if ($Item -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in @($Item.Keys | Sort-Object)) { $result[$key] = ConvertTo-Canonical $Item[$key] }
            return $result
        }
        if ($Item -is [array]) { return ,@($Item | ForEach-Object { ConvertTo-Canonical $_ }) }
        return $Item
    }
    $json = ConvertTo-Canonical $Value | ConvertTo-Json -Depth 100 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-CsfConfiguration {
    param([string]$Path)
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-Csf ($c -is [System.Collections.IDictionary] -and $c.schemaVersion -eq 1) 'Expected schemaVersion 1 configuration.'
    foreach ($key in 'tenantId', 'subscriptionId') {
        Assert-Csf ([string]$c.environment[$key] -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') "environment.$key must be a GUID."
    }
    Assert-Csf ([string]$c.environment.location -match '^[a-z][a-z0-9]{1,39}$') 'Use an approved canonical Azure region name.'
    Assert-Csf ($c.network -is [System.Collections.IDictionary] -and $c.network.inputs -is [System.Collections.IDictionary]) 'network.inputs is required.'
    Assert-Csf ($c.network.outputs -is [System.Collections.IDictionary]) 'network.outputs must be an object.'
    Assert-Csf ($c.modules -is [System.Collections.IDictionary]) 'modules must be an object.'
    $target = Get-CsfFingerprint $c.environment
    foreach ($module in $c.modules.Values) {
        Assert-Csf ($module.targetFingerprint -ceq $target) 'Environment changed after state was recorded. Use a separate configuration file per target.'
    }
    return $c
}

function Save-CsfConfiguration {
    param($Configuration, [string]$Path)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $Configuration -Depth 100
        [IO.File]::WriteAllText($temp, "$json`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temp, $Path, "$Path.bak")
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}

function Invoke-CsfAz {
    param([string[]]$Arguments, [string]$SubscriptionId, [switch]$AllowMissing)
    foreach ($argument in $Arguments) {
        Assert-Csf ($argument -notmatch '[\r\n()|&<>^%!]') 'Unsupported Azure CLI argument character; pass JSON bodies by file.'
    }
    $raw = @(& az @Arguments --subscription $SubscriptionId --only-show-errors --output json 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { "$_" }) -join "`n"
    if ($exitCode -ne 0) {
        $code = if ($text -match '"code"\s*:\s*"([A-Za-z][A-Za-z0-9_.]+)"') { $Matches[1] }
            elseif ($text -match '\(([A-Za-z][A-Za-z0-9_.]+)\)') { $Matches[1] } else { 'CliFailure' }
        if ($AllowMissing -and $code -cin @('ResourceNotFound', 'ResourceGroupNotFound', 'ParentResourceNotFound')) { return $null }
        throw "Azure CLI failed ($code). No success was recorded; inspect the authorized Azure operation."
    }
    try { return ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100 }
    catch { throw 'Azure CLI returned missing or invalid JSON.' }
}

function Invoke-CsfArm {
    param(
        $Configuration, [string]$ResourceId,
        [ValidateSet('get', 'put')][string]$Method = 'get',
        $Body, [switch]$AllowMissing
    )
    Assert-Csf ($ResourceId -match '^/subscriptions/([0-9a-fA-F-]{36})/') 'Expected a subscription-scoped ARM resource ID.'
    $subscription = $Matches[1]
    Assert-Csf ($subscription -ieq $Configuration.environment.subscriptionId) 'This network slice supports references in the configured subscription only.'
    $api = if ($ResourceId -match '/providers/Microsoft.Network') { '2024-05-01' } else { '2022-09-01' }
    $arguments = @('rest', '--method', $Method, '--url', "https://management.azure.com${ResourceId}?api-version=$api")
    $file = $null
    try {
        if ($Method -eq 'put') {
            $file = Join-Path ([IO.Path]::GetTempPath()) "ccof-network-$([guid]::NewGuid().ToString('N')).json"
            [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $Body -Depth 100), [Text.UTF8Encoding]::new($false))
            $arguments += @('--body', "@$file", '--headers', 'Content-Type=application/json')
        }
        $result = Invoke-CsfAz -Arguments $arguments -SubscriptionId $subscription -AllowMissing:$AllowMissing
        if ($Method -eq 'get' -and $null -ne $result) {
            Assert-Csf ($result.id -ieq $ResourceId) 'ARM read-back resource ID differs from the requested resource.'
        }
        return $result
    }
    finally { if ($file -and (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file } }
}

function Assert-CsfContext {
    param($Configuration)
    $sub = $Configuration.environment.subscriptionId
    $account = Invoke-CsfAz -Arguments @('account', 'show') -SubscriptionId $sub
    Assert-Csf ($account.id -ieq $sub -and $account.tenantId -ieq $Configuration.environment.tenantId) 'Wrong tenant or subscription. Sign in explicitly before running this block.'
    Assert-Csf ($account.environmentName -ceq 'AzureCloud') 'This first slice supports Azure public cloud only.'
}

function Set-CsfModuleState {
    param($Configuration, [string]$Name, [string]$Status, [string]$InputFingerprint, $Outputs)
    $Configuration.modules[$Name] = @{
        status = $Status
        targetFingerprint = Get-CsfFingerprint $Configuration.environment
        inputFingerprint = $InputFingerprint
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
    if ($Name -eq 'networkFoundation') { $Configuration.network.outputs = $Outputs }
}

function Invoke-CsfBlock {
    param(
        [string]$ConfigurationPath, [string]$Name,
        [ValidateSet('Plan', 'Apply', 'Verify')][string]$Action,
        [scriptblock]$Operation
    )
    $path = (Resolve-Path -LiteralPath $ConfigurationPath -ErrorAction Stop).Path
    $lock = $null
    try {
        try {
            $lock = [IO.FileStream]::new("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
        }
        catch { throw 'Configuration is locked or its directory is not writable. Only one block may use this file at a time.' }
        $c = Read-CsfConfiguration $path
        Assert-CsfContext $c
        & $Operation $c $path $Action
    }
    finally { if ($lock) { $lock.Dispose() } }
}

Export-ModuleMember -Function *-Csf*

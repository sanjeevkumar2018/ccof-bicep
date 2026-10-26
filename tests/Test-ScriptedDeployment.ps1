#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $root 'deployment\scripted'
Import-Module (Join-Path $directory 'common\Shared.psm1') -Force
Import-Module (Join-Path $directory 'common\Network.psm1') -Force
$scratch = Join-Path $root ".env.scripted-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $scratch
$configPath = Join-Path $scratch 'environment.json'
$script:checks = 0

function Check([bool]$Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) { throw "FAIL: $Message" }
}
function Read-Configuration { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }
function Write-Configuration($Configuration) {
    ConvertTo-Json -InputObject $Configuration -Depth 100 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
}
function Run-Block([string]$Name, [string]$Action = 'Plan') {
    & (Join-Path $directory "$Name.ps1") -ConfigurationPath $configPath -Action $Action | Out-Null
}
function Reject([scriptblock]$Operation, [string]$Pattern) {
    $caught = $null
    try { & $Operation } catch { $caught = $_.Exception.Message }
    Check ($caught -and $caught -match $Pattern) "Expected refusal matching '$Pattern'; got '$caught'."
}
function Reset-Fixture {
    $sub = '11111111-1111-1111-1111-111111111111'
    $tenant = '22222222-2222-2222-2222-222222222222'
    $rg = "/subscriptions/$sub/resourceGroups/network"
    $nsgId = "$rg/providers/Microsoft.Network/networkSecurityGroups/apim"
    $vnetId = "$rg/providers/Microsoft.Network/virtualNetworks/ccof"
    $c = Get-Content (Join-Path $directory 'environment.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $c.environment = @{ tenantId = $tenant; subscriptionId = $sub; location = 'eastus2' }
    $c.network.inputs.mode = 'create'
    $c.network.inputs.resourceGroup = 'network'
    $c.network.inputs.vnetName = 'ccof'
    $c.network.inputs.addressPrefixes = @('10.80.0.0/24')
    $c.network.inputs.subnets.apim.addressPrefix = '10.80.0.0/27'
    $c.network.inputs.subnets.apim.networkSecurityGroupId = $nsgId
    $c.network.inputs.subnets.functions.addressPrefix = '10.80.0.32/27'
    $c.network.inputs.subnets.privateEndpoints.addressPrefix = '10.80.0.64/27'
    $c.futureBlock = @{ inputs = @{ preserve = 'untouched' }; outputs = @{ preserve = 'also untouched' } }
    Write-Configuration $c
    $global:CsfFixture = @{
        subscriptionId = $sub; tenantId = $tenant; cloud = 'AzureCloud'
        rg = $rg; vnetId = $vnetId; provider = 'Registered'
        denied = ''; malformed = ''; failPut = ''; driftId = ''; wrongId = ''
        calls = [Collections.Generic.List[object]]::new()
        resources = @{
            $rg = @{ id = $rg; properties = @{ provisioningState = 'Succeeded' } }
            $nsgId = @{ id = $nsgId; location = 'eastus2'; properties = @{ provisioningState = 'Succeeded'; securityRules = @() } }
        }
    }
}

function global:az {
    $f = $global:CsfFixture
    $argv = @($args)
    $global:LASTEXITCODE = 0
    if ($argv -notcontains '--subscription' -or $argv[[array]::IndexOf($argv, '--subscription') + 1] -ine $f.subscriptionId) {
        throw 'Mock refused missing/wrong explicit subscription.'
    }
    if ($argv[0] -eq 'account' -and $argv[1] -eq 'show') {
        return (@{ id = $f.subscriptionId; tenantId = $f.tenantId; environmentName = $f.cloud } | ConvertTo-Json -Compress)
    }
    if ($argv[0] -eq 'account' -and $argv[1] -eq 'list-locations') { return '[{"name":"eastus2"}]' }
    if ($argv[0] -eq 'provider' -and $argv[1] -eq 'show') {
        return (@{ registrationState = $f.provider } | ConvertTo-Json -Compress)
    }
    if ($argv[0] -ne 'rest') { throw 'Unexpected CLI command (login/context switching is prohibited).' }
    $method = $argv[[array]::IndexOf($argv, '--method') + 1]
    $url = $argv[[array]::IndexOf($argv, '--url') + 1]
    $id = ([uri]$url).AbsolutePath
    $f.calls.Add(@{ method = $method; id = $id })
    if ($id -eq $f.denied) {
        $global:LASTEXITCODE = 1
        return 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"DO-NOT-LOG"}})'
    }
    if ($id -eq $f.malformed) { return 'not json DO-NOT-LOG' }
    if ($method -eq 'put') {
        if ($id -eq $f.failPut) {
            $global:LASTEXITCODE = 1
            return 'ERROR: (RequestDisallowedByPolicy) DO-NOT-LOG'
        }
        $bodyFile = $argv[[array]::IndexOf($argv, '--body') + 1]
        $body = Get-Content -LiteralPath $bodyFile.Substring(1) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $body.id = $id
        $body.properties.provisioningState = 'Succeeded'
        if ($id -eq $f.vnetId) { $body.properties.subnets = @() }
        $f.resources[$id] = $body
        if ($id -match '/subnets/') {
            $f.resources[$f.vnetId].properties.subnets += $body
        }
    } elseif ($method -ne 'get') { throw 'Unexpected REST method.' }
    if (-not $f.resources.ContainsKey($id)) {
        $global:LASTEXITCODE = 1
        return 'ERROR: Not Found({"error":{"code":"ResourceNotFound","message":"DO-NOT-LOG"}})'
    }
    $resource = $f.resources[$id]
    if ($id -eq $f.driftId) { $resource.properties.defaultOutboundAccess = $true }
    if ($id -eq $f.wrongId) {
        $resource = @{ id = '/wrong/resource'; properties = @{ provisioningState = 'Succeeded' } }
    }
    return (ConvertTo-Json -InputObject $resource -Depth 100 -Compress)
}

try {
    Reset-Fixture
    $original = Get-Content -LiteralPath $configPath -Raw
    Run-Block 00-Preflight
    Check ((Get-Content -LiteralPath $configPath -Raw) -ceq $original) 'Preflight Plan preserves file bytes.'
    Reject { Run-Block 10-NetworkFoundation } 'Preflight'
    Run-Block 00-Preflight Verify
    $beforePlan = Get-Content -LiteralPath $configPath -Raw
    Run-Block 10-NetworkFoundation
    Check ((Get-Content -LiteralPath $configPath -Raw) -ceq $beforePlan) 'Network Plan preserves file bytes.'
    Check (@($global:CsfFixture.calls | Where-Object method -ne get).Count -eq 0) 'Plans and preflight never write Azure.'
    Reject { Run-Block 10-NetworkFoundation Verify } 'incomplete'
    Check ((Read-Configuration).modules.networkFoundation.status -eq 'failed') 'Incomplete Verify records failure.'
    Check ((Read-Configuration).network.outputs.Count -eq 0) 'Failed Verify has no usable outputs.'

    Run-Block 10-NetworkFoundation Apply
    $c = Read-Configuration
    Check ($c.modules.networkFoundation.status -eq 'verified') 'Apply records verified state.'
    Check ($c.network.outputs.vnetId -eq $global:CsfFixture.vnetId) 'VNet output comes from read-back.'
    Check ($c.network.outputs.functionsSubnetId -eq "$($global:CsfFixture.vnetId)/subnets/snet-functions") 'Next-block subnet input is saved in the same file.'
    Check ($c.network.outputs.privateEndpointSubnetId -eq "$($global:CsfFixture.vnetId)/subnets/snet-private-endpoints") 'Private-endpoint output uses the existing project naming convention.'
    Check ($c.futureBlock.inputs.preserve -eq 'untouched' -and $c.futureBlock.outputs.preserve -eq 'also untouched') 'Unowned sections survive writes.'
    $network = Get-CsfVerifiedNetworkOutputs -Configuration $c
    Check ($network.functionsSubnetId -eq $c.network.outputs.functionsSubnetId) 'A dependent block consumes the shared verified output directly.'
    $c.network.outputs.functionsSubnetId = '/incorrect/output'
    Reject { Get-CsfVerifiedNetworkOutputs -Configuration $c } 'Stored network output differs'
    $c = Read-Configuration
    $c.network.inputs.dnsServers = @('10.80.0.100')
    Reject { Get-CsfVerifiedNetworkOutputs -Configuration $c } 'stale'
    $c = Read-Configuration
    Check (Test-Path -LiteralPath "$configPath.bak") 'Atomic save retains recovery file.'
    $puts = @($global:CsfFixture.calls | Where-Object method -eq put).Count
    Check ($puts -eq 4) 'Apply creates exactly one VNet and three subnets.'
    $apim = $global:CsfFixture.resources["$($global:CsfFixture.vnetId)/subnets/snet-apim"].properties
    Check ($apim.defaultOutboundAccess -eq $false -and $apim.delegations[0].properties.serviceName -eq 'Microsoft.Web/serverFarms') 'APIM creation has private outbound and correct delegation.'
    $functions = $global:CsfFixture.resources[$c.network.outputs.functionsSubnetId].properties
    Check ($functions.delegations[0].properties.serviceName -eq 'Microsoft.App/environments') 'Flex delegation differs from APIM.'
    Run-Block 10-NetworkFoundation Apply
    Check (@($global:CsfFixture.calls | Where-Object method -eq put).Count -eq $puts) 'Rerun never overwrites existing resources.'

    $vnet = $global:CsfFixture.resources[$global:CsfFixture.vnetId]
    $vnet.properties.dhcpOptions.dnsServers = @('10.80.0.100', '10.80.0.101')
    $c = Read-Configuration
    $c.network.inputs.dnsServers = @('10.80.0.101', '10.80.0.100')
    Write-Configuration $c
    Reject { Run-Block 10-NetworkFoundation } 'DNS server configuration or order differs'
    $c.network.inputs.dnsServers = @()
    Write-Configuration $c
    $vnet.properties.dhcpOptions.dnsServers = @()
    $extra = @{ id = "$($vnet.id)/subnets/unrelated"; properties = @{ addressPrefix = '10.80.0.128/27' } }
    $vnet.properties.subnets += $extra
    Run-Block 10-NetworkFoundation Verify
    Check (@($vnet.properties.subnets | Where-Object id -eq $extra.id).Count -eq 1) 'Unrelated subnets are preserved.'
    $c = Read-Configuration
    $c.network.inputs.mode = 'existing'
    Write-Configuration $c
    Run-Block 10-NetworkFoundation Verify
    Check ((Read-Configuration).modules.networkFoundation.status -eq 'verified') 'Existing mode verifies a matching foundation.'
    Check (@($global:CsfFixture.calls | Where-Object method -eq put).Count -eq $puts) 'Existing Verify never writes Azure.'

    $global:CsfFixture.driftId = "$($vnet.id)/subnets/snet-functions"
    Reject { Get-CsfVerifiedNetworkOutputs -Configuration (Read-Configuration) } 'disable default outbound'
    Reject { Run-Block 10-NetworkFoundation Apply } 'disable default outbound'
    Check ((Read-Configuration).network.outputs.Count -eq 0) 'Drift invalidates previously saved network outputs.'
    Check (@($global:CsfFixture.calls | Where-Object method -eq put).Count -eq $puts) 'Drift is not silently repaired.'

    Reset-Fixture
    Run-Block 00-Preflight Verify
    $c = Read-Configuration
    $c.network.inputs.mode = 'existing'
    Write-Configuration $c
    Reject { Run-Block 10-NetworkFoundation Apply } 'Existing mode'
    Check (@($global:CsfFixture.calls | Where-Object method -eq put).Count -eq 0) 'Existing mode cannot create missing resources.'

    Reset-Fixture
    Run-Block 00-Preflight Verify
    $global:CsfFixture.denied = $global:CsfFixture.vnetId
    Reject { Run-Block 10-NetworkFoundation Apply } 'AuthorizationFailed'
    Check (@($global:CsfFixture.calls | Where-Object method -eq put).Count -eq 0) '403 is never interpreted as absence.'
    $global:CsfFixture.denied = ''
    $global:CsfFixture.malformed = $global:CsfFixture.vnetId
    Reject { Run-Block 10-NetworkFoundation Apply } 'invalid JSON'

    Reset-Fixture
    Run-Block 00-Preflight Verify
    $global:CsfFixture.failPut = "$($global:CsfFixture.vnetId)/subnets/snet-functions"
    Reject { Run-Block 10-NetworkFoundation Apply } 'RequestDisallowedByPolicy'
    Check ((Read-Configuration).modules.networkFoundation.status -eq 'failed' -and (Read-Configuration).network.outputs.Count -eq 0) 'Partial Apply cannot publish success or stale outputs.'
    Check ($global:CsfFixture.resources.ContainsKey($global:CsfFixture.vnetId)) 'Partial creation is preserved, not deleted.'
    $global:CsfFixture.failPut = ''
    Run-Block 10-NetworkFoundation Apply
    Check ((Read-Configuration).modules.networkFoundation.status -eq 'verified') 'Rerun resumes from partial creation.'
    $vnet = $global:CsfFixture.resources[$global:CsfFixture.vnetId]
    $peId = "$($vnet.id)/subnets/snet-private-endpoints"
    $global:CsfFixture.resources.Remove($peId)
    $vnet.properties.subnets = @($vnet.properties.subnets | Where-Object id -ne $peId)
    $vnet.properties.subnets += @{ id = "$($vnet.id)/subnets/owned-elsewhere"; properties = @{ addressPrefix = '10.80.0.64/27' } }
    $putsBeforeOverlap = @($global:CsfFixture.calls | Where-Object method -eq put).Count
    Reject { Run-Block 10-NetworkFoundation Apply } 'overlaps a subnet already'
    Check (@($global:CsfFixture.calls | Where-Object method -eq put).Count -eq $putsBeforeOverlap) 'Existing subnet overlap fails before creating anything.'

    Reset-Fixture
    Run-Block 00-Preflight Verify
    $c = Read-Configuration
    $c.network.inputs.subnets.functions.addressPrefix = '10.80.0.0/27'
    Write-Configuration $c
    Reject { Run-Block 10-NetworkFoundation Apply } 'subnets overlap'
    Check (@($global:CsfFixture.calls | Where-Object method -eq put).Count -eq 0) 'Overlapping input ranges fail before writes.'
    $c.network.inputs.subnets.functions.addressPrefix = '10.81.0.0/27'
    Write-Configuration $c
    Reject { Run-Block 10-NetworkFoundation } 'outside'
    $c.network.inputs.subnets.functions.addressPrefix = '10.80.0.32/28'
    Write-Configuration $c
    Reject { Run-Block 10-NetworkFoundation } 'smaller'
    $c.network.inputs.subnets.functions.addressPrefix = '10.80.0.33/27'
    Write-Configuration $c
    Reject { Run-Block 10-NetworkFoundation } 'network address'

    Reset-Fixture
    Run-Block 00-Preflight Verify
    $c = Read-Configuration
    $c.network.inputs.resourceGroup = 'different'
    Write-Configuration $c
    Reject { Run-Block 10-NetworkFoundation Apply } 'Preflight'
    $c.environment.subscriptionId = '33333333-3333-3333-3333-333333333333'
    Write-Configuration $c
    Reject { Run-Block 00-Preflight } 'Environment changed'

    Reset-Fixture
    $global:CsfFixture.tenantId = '33333333-3333-3333-3333-333333333333'
    Reject { Run-Block 00-Preflight Verify } 'Wrong tenant'
    Reset-Fixture
    $global:CsfFixture.cloud = 'AzureUSGovernment'
    Reject { Run-Block 00-Preflight } 'public cloud'
    Reset-Fixture
    $global:CsfFixture.provider = 'NotRegistered'
    Reject { Run-Block 00-Preflight Verify } 'already be registered'
    Check ((Read-Configuration).modules.preflight.status -eq 'failed') 'Failed preflight cannot authorize downstream work.'

    Reset-Fixture
    $global:CsfFixture.wrongId = $global:CsfFixture.rg
    Reject { Run-Block 00-Preflight Verify } 'resource ID differs'
    Reset-Fixture
    $c = Read-Configuration
    $c.network.inputs.subnets.apim.networkSecurityGroupId = $c.network.inputs.subnets.apim.networkSecurityGroupId.Replace($c.environment.subscriptionId, '33333333-3333-3333-3333-333333333333')
    Write-Configuration $c
    Reject { Run-Block 00-Preflight } 'configured subscription'

    Reset-Fixture
    $handle = [IO.FileStream]::new("$configPath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Reject { Run-Block 00-Preflight Verify } 'locked' } finally { $handle.Dispose() }
    Write-Host "PASS: $script:checks scripted deployment checks (offline Azure CLI fixtures)."
}
finally {
    Remove-Item Function:\global:az -ErrorAction SilentlyContinue
    Remove-Variable CsfFixture -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force
}

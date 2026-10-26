#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Shared.psm1')

function Get-CsfCidr {
    param([string]$Cidr)
    Assert-Csf ($Cidr -match '^(\d{1,3}\.){3}\d{1,3}/(\d{1,2})$') "Invalid IPv4 CIDR: $Cidr"
    $parts = $Cidr.Split('/')
    $length = [int]$parts[1]
    Assert-Csf ($length -ge 0 -and $length -le 32) "Invalid IPv4 CIDR: $Cidr"
    [uint64]$number = 0
    foreach ($octet in $parts[0].Split('.')) {
        Assert-Csf ([int]$octet -le 255 -and "$([int]$octet)" -ceq $octet) "Invalid IPv4 address: $Cidr"
        $number = $number * 256 + [int]$octet
    }
    [uint64]$size = [uint64][Math]::Pow(2, 32 - $length)
    Assert-Csf ($number % $size -eq 0) "CIDR must use its network address: $Cidr"
    return @{ start = $number; end = $number + $size - 1; length = $length }
}

function Test-CsfOverlap {
    param($First, $Second)
    return $First.start -le $Second.end -and $Second.start -le $First.end
}

function Assert-CsfNetworkInputs {
    param($Configuration)
    $n = $Configuration.network.inputs
    Assert-Csf ($n.mode -cin @('existing', 'create')) 'network.inputs.mode must be existing or create.'
    Assert-Csf ([string]$n.resourceGroup -match '^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,88}[A-Za-z0-9_-]$') 'Use a valid network resource group name (2-90 characters).'
    Assert-Csf ([string]$n.vnetName -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') 'Use a valid VNet name (1-64 characters).'
    Assert-Csf ($n.addressPrefixes -is [array] -and $n.addressPrefixes.Count -gt 0) 'addressPrefixes must be a nonempty IPv4 CIDR array.'
    $ranges = @()
    foreach ($prefix in $n.addressPrefixes) {
        $range = Get-CsfCidr $prefix
        foreach ($other in $ranges) { Assert-Csf (-not (Test-CsfOverlap $range $other)) 'VNet address prefixes overlap.' }
        $ranges += $range
    }
    Assert-Csf ($n.dnsServers -is [array]) 'dnsServers must be an array (empty means Azure-provided DNS).'
    foreach ($ip in $n.dnsServers) { $null = Get-CsfCidr "$ip/32" }
    Assert-Csf ($n.subnets -is [System.Collections.IDictionary] -and $n.subnets.Count -eq 3) 'Specify exactly apim, functions and privateEndpoints subnets for this slice.'
    $names = @(); $subnetRanges = @()
    $types = @{ networkSecurityGroupId = 'networkSecurityGroups'; routeTableId = 'routeTables'; natGatewayId = 'natGateways' }
    foreach ($key in 'apim', 'functions', 'privateEndpoints') {
        $s = $n.subnets[$key]
        Assert-Csf ($s -is [System.Collections.IDictionary]) "Missing $key subnet inputs."
        Assert-Csf ([string]$s.name -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$' -and $s.name -notin $names) 'Subnet names must be valid and unique.'
        $names += $s.name
        $range = Get-CsfCidr $s.addressPrefix
        $maxLength = if ($key -eq 'privateEndpoints') { 29 } else { 27 }
        Assert-Csf ($range.length -le $maxLength) "$key subnet is smaller than /$maxLength."
        Assert-Csf (@($ranges | Where-Object { $range.start -ge $_.start -and $range.end -le $_.end }).Count -gt 0) "$key subnet is outside the VNet address space."
        foreach ($other in $subnetRanges) { Assert-Csf (-not (Test-CsfOverlap $range $other)) 'Configured subnets overlap.' }
        $subnetRanges += $range
        foreach ($property in $types.Keys) {
            $id = [string]$s[$property]
            if (-not $id) { continue }
            $pattern = '^/subscriptions/' + [regex]::Escape($Configuration.environment.subscriptionId) +
                '/resourceGroups/[A-Za-z0-9_.-]+/providers/Microsoft.Network/' + $types[$property] + '/[A-Za-z0-9_.-]+$'
            Assert-Csf ($id -imatch $pattern) "$key.$property must be a full resource ID in the configured subscription."
        }
    }
    Assert-Csf (-not [string]::IsNullOrWhiteSpace($n.subnets.apim.networkSecurityGroupId)) 'The APIM subnet requires an approved existing NSG reference.'
}

function Assert-CsfSetEqual {
    param($Actual, $Expected, [string]$Message)
    $a = @($Actual | Sort-Object -Unique)
    $e = @($Expected | Sort-Object -Unique)
    Assert-Csf (($a -join '|') -ieq ($e -join '|')) $Message
}

function Assert-CsfProvisioned {
    param($Resource)
    Assert-Csf ($Resource.properties.provisioningState -ceq 'Succeeded') "Resource is not Succeeded: $($Resource.id)"
}

function Get-CsfSubnetProperties {
    param([string]$Key, $InputSubnet)
    $properties = @{
        addressPrefix = $InputSubnet.addressPrefix
        defaultOutboundAccess = $false
        delegations = @()
    }
    if ($Key -ne 'privateEndpoints') {
        $service = if ($Key -eq 'apim') { 'Microsoft.Web/serverFarms' } else { 'Microsoft.App/environments' }
        $properties.delegations = @(@{ name = "$Key-integration"; properties = @{ serviceName = $service } })
    }
    foreach ($pair in @(
        @('networkSecurityGroupId', 'networkSecurityGroup'),
        @('routeTableId', 'routeTable'),
        @('natGatewayId', 'natGateway')
    )) {
        if ($InputSubnet[$pair[0]]) { $properties[$pair[1]] = @{ id = $InputSubnet[$pair[0]] } }
    }
    return $properties
}

function Assert-CsfSubnet {
    param($Resource, $Desired)
    Assert-CsfProvisioned $Resource
    $p = $Resource.properties
    $prefixes = if ($p.Contains('addressPrefixes')) { @($p.addressPrefixes) } else { @($p.addressPrefix) }
    Assert-CsfSetEqual $prefixes @($Desired.addressPrefix) "Subnet address prefix differs: $($Resource.id)"
    $actualDelegations = @($p.delegations | ForEach-Object { $_.properties.serviceName })
    $expectedDelegations = @($Desired.delegations | ForEach-Object { $_.properties.serviceName })
    Assert-CsfSetEqual $actualDelegations $expectedDelegations "Subnet delegation differs: $($Resource.id)"
    Assert-Csf ($p.Contains('defaultOutboundAccess') -and $p.defaultOutboundAccess -eq $false) "Subnet must explicitly disable default outbound access: $($Resource.id)"
    foreach ($property in 'networkSecurityGroup', 'routeTable', 'natGateway') {
        $actual = if ($p.Contains($property) -and $p[$property]) { [string]$p[$property].id } else { '' }
        $expected = if ($Desired.Contains($property)) { [string]$Desired[$property].id } else { '' }
        Assert-Csf ($actual -ieq $expected) "Subnet $property differs; existing resources are never modified: $($Resource.id)"
    }
}

function Get-CsfNetworkPlan {
    param($Configuration)
    $n = $Configuration.network.inputs
    $sub = $Configuration.environment.subscriptionId
    $location = $Configuration.environment.location
    $vnetId = "/subscriptions/$sub/resourceGroups/$($n.resourceGroup)/providers/Microsoft.Network/virtualNetworks/$($n.vnetName)"
    $missing = [Collections.Generic.List[object]]::new()
    $outputs = @{ verificationScope = 'ARM foundation configuration only' }
    $vnet = Invoke-CsfArm -Configuration $Configuration -ResourceId $vnetId -AllowMissing
    if ($null -eq $vnet) {
        $missing.Add(@{ id = $vnetId; body = @{
            location = $location
            properties = @{ addressSpace = @{ addressPrefixes = $n.addressPrefixes }; dhcpOptions = @{ dnsServers = $n.dnsServers } }
        } })
    } else {
        Assert-CsfProvisioned $vnet
        Assert-Csf ($vnet.location -ieq $location) 'Existing VNet region differs.'
        Assert-CsfSetEqual $vnet.properties.addressSpace.addressPrefixes $n.addressPrefixes 'Existing VNet address space differs.'
        $dns = if ($vnet.properties.Contains('dhcpOptions')) { @($vnet.properties.dhcpOptions.dnsServers) } else { @() }
        Assert-Csf (($dns -join '|') -ceq ($n.dnsServers -join '|')) 'Existing VNet DNS server configuration or order differs.'
        $outputs.vnetId = $vnet.id
    }
    $references = @{}
    foreach ($key in 'apim', 'functions', 'privateEndpoints') {
        $s = $n.subnets[$key]
        foreach ($property in 'networkSecurityGroupId', 'routeTableId', 'natGatewayId') {
            $id = [string]$s[$property]
            if (-not $id -or $references.ContainsKey($id)) { continue }
            $resource = Invoke-CsfArm -Configuration $Configuration -ResourceId $id
            Assert-CsfProvisioned $resource
            Assert-Csf ($resource.location -ieq $location) 'Referenced NSG/route table/NAT gateway must be in the VNet region.'
            $references[$id] = $true
        }
        $id = "$vnetId/subnets/$($s.name)"
        $desired = Get-CsfSubnetProperties $key $s
        $live = if ($vnet) { Invoke-CsfArm -Configuration $Configuration -ResourceId $id -AllowMissing } else { $null }
        if ($null -eq $live) {
            if ($vnet) {
                $targetRange = Get-CsfCidr $s.addressPrefix
                foreach ($other in @($vnet.properties.subnets)) {
                    $prefixes = if ($other.properties.Contains('addressPrefixes')) { @($other.properties.addressPrefixes) } else { @($other.properties.addressPrefix) }
                    foreach ($prefix in $prefixes) {
                        Assert-Csf (-not (Test-CsfOverlap $targetRange (Get-CsfCidr $prefix))) 'New subnet overlaps a subnet already in the VNet.'
                    }
                }
            }
            $missing.Add(@{ id = $id; body = @{ properties = $desired } })
        } else {
            Assert-CsfSubnet $live $desired
            $outputKey = if ($key -eq 'privateEndpoints') { 'privateEndpointSubnetId' } else { "${key}SubnetId" }
            $outputs[$outputKey] = $live.id
        }
    }
    return @{ missing = @($missing.ToArray()); outputs = $outputs }
}

function Wait-CsfNetworkResource {
    param($Configuration, [string]$ResourceId)
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    do {
        $resource = Invoke-CsfArm -Configuration $Configuration -ResourceId $ResourceId
        $state = $resource.properties.provisioningState
        if ($state -ceq 'Succeeded') { return }
        Assert-Csf ($state -cnotin @('Failed', 'Canceled')) "Network provisioning failed: $ResourceId"
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Network provisioning timed out. Inspect Azure before retry: $ResourceId"
}

function Get-CsfVerifiedNetworkOutputs {
    param([Parameter(Mandatory)]$Configuration)
    Assert-CsfNetworkInputs $Configuration
    $fingerprint = Get-CsfFingerprint @{ environment = $Configuration.environment; inputs = $Configuration.network.inputs }
    Assert-Csf ($Configuration.modules.Contains('networkFoundation') -and
        $Configuration.modules.networkFoundation.status -ceq 'verified' -and
        $Configuration.modules.networkFoundation.targetFingerprint -ceq (Get-CsfFingerprint $Configuration.environment) -and
        $Configuration.modules.networkFoundation.inputFingerprint -ceq $fingerprint) 'Network dependency is missing, failed or stale. Run network Verify.'
    $plan = Get-CsfNetworkPlan $Configuration
    Assert-Csf ($plan.missing.Count -eq 0) 'Network dependency no longer exists.'
    foreach ($key in 'vnetId', 'apimSubnetId', 'functionsSubnetId', 'privateEndpointSubnetId') {
        Assert-Csf ($Configuration.network.outputs[$key] -ieq $plan.outputs[$key]) 'Stored network output differs from live read-back. Run network Verify.'
    }
    return $plan.outputs
}

Export-ModuleMember -Function Assert-CsfNetworkInputs, Get-CsfNetworkPlan, Wait-CsfNetworkResource, Get-CsfVerifiedNetworkOutputs

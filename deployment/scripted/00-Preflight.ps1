#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [ValidateSet('Plan', 'Apply', 'Verify')][string]$Action = 'Plan'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\Shared.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'common\Network.psm1') -Force

Invoke-CsfBlock -ConfigurationPath $ConfigurationPath -Name preflight -Action $Action -Operation {
    param($c, $path, $action)
    Assert-CsfNetworkInputs $c
    $fingerprint = Get-CsfFingerprint @{ environment = $c.environment; resourceGroup = $c.network.inputs.resourceGroup }
    try {
        $sub = $c.environment.subscriptionId
        $provider = Invoke-CsfAz -Arguments @('provider', 'show', '--namespace', 'Microsoft.Network') -SubscriptionId $sub
        Assert-Csf ($provider.registrationState -ceq 'Registered') 'Microsoft.Network must already be registered by an authorized subscription operator.'
        $group = Invoke-CsfArm -Configuration $c -ResourceId "/subscriptions/$sub/resourceGroups/$($c.network.inputs.resourceGroup)"
        $locations = @(Invoke-CsfAz -Arguments @('account', 'list-locations') -SubscriptionId $sub)
        Assert-Csf (@($locations | Where-Object { $_.name -ceq $c.environment.location }).Count -eq 1) 'Configured region is not available in the subscription location list.'
        Assert-Csf ($group.properties.provisioningState -ceq 'Succeeded') 'Network resource group is not provisioned.'
        if ($action -ne 'Plan') {
            Set-CsfModuleState $c preflight verified $fingerprint $null
            Save-CsfConfiguration $c $path
        }
        Write-Host "Preflight $action passed: tenant/subscription, network inputs, provider, existing RG and region."
        Write-Host 'No Azure writes. RBAC effectiveness, estate-wide CIDR overlap, DNS/egress and application prerequisites are not proven.'
    }
    catch {
        if ($action -ne 'Plan') {
            Set-CsfModuleState $c preflight failed $fingerprint $null
            Save-CsfConfiguration $c $path
        }
        throw
    }
}

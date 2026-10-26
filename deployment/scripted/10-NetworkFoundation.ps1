#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [ValidateSet('Plan', 'Apply', 'Verify')][string]$Action = 'Plan'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\Shared.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'common\Network.psm1') -Force

Invoke-CsfBlock -ConfigurationPath $ConfigurationPath -Name networkFoundation -Action $Action -Operation {
    param($c, $path, $action)
    $fingerprint = Get-CsfFingerprint @{ environment = $c.environment; inputs = $c.network.inputs }
    try {
        Assert-CsfNetworkInputs $c
        Assert-Csf ($c.modules.Contains('preflight') -and $c.modules.preflight.status -ceq 'verified' -and
            $c.modules.preflight.inputFingerprint -ceq (Get-CsfFingerprint @{ environment = $c.environment; resourceGroup = $c.network.inputs.resourceGroup })) 'Run 00-Preflight.ps1 -Action Verify first.'
        $plan = Get-CsfNetworkPlan $c
        foreach ($item in $plan.missing) { Write-Host "Missing: $($item.id)" }
        if ($action -eq 'Plan') {
            foreach ($item in $plan.missing) {
                Write-Host ($item.body | ConvertTo-Json -Depth 20)
            }
            Write-Host "Network Plan ($($c.network.inputs.mode)): $($plan.missing.Count) missing resources. Existing mode never creates them. No Azure writes or configuration updates."
            return
        }
        if ($action -eq 'Verify') {
            Assert-Csf ($plan.missing.Count -eq 0) 'Network is incomplete. Verify never creates resources.'
        } else {
            Assert-Csf ($c.network.inputs.mode -ceq 'create' -or $plan.missing.Count -eq 0) 'Existing mode never creates resources. Ask the network owner to complete the missing resources.'
            Set-CsfModuleState $c networkFoundation applying $fingerprint @{}
            Save-CsfConfiguration $c $path
            foreach ($item in $plan.missing) {
                # Do not PUT an existing VNet/subnet: its configuration may have changed since planning.
                $live = Invoke-CsfArm -Configuration $c -ResourceId $item.id -AllowMissing
                Assert-Csf ($null -eq $live) 'A planned resource appeared concurrently. Rerun Plan; no existing resource will be overwritten.'
                $null = Invoke-CsfArm -Configuration $c -ResourceId $item.id -Method put -Body $item.body
                Wait-CsfNetworkResource $c $item.id
            }
            $plan = Get-CsfNetworkPlan $c
            Assert-Csf ($plan.missing.Count -eq 0) 'Resources remain missing after Apply.'
        }
        Set-CsfModuleState $c networkFoundation verified $fingerprint $plan.outputs
        Save-CsfConfiguration $c $path
        Write-Host "Network $action passed. Verified ARM IDs saved to network.outputs."
        Write-Host 'Foundation only: private endpoints, DNS forwarding, peering, firewall/egress and runtime reachability still require separate work.'
    }
    catch {
        if ($action -ne 'Plan') {
            Set-CsfModuleState $c networkFoundation failed $fingerprint @{}
            Save-CsfConfiguration $c $path
        }
        throw
    }
}

# Independent scripted deployment: network-first slice

This directory is an opt-in alternative. It does not invoke or change the existing
staged, quick-start or manual deployment paths. PowerShell 7 runs Azure CLI commands
directly; no Bicep, ARM template deployment or Copilot-specific runtime is required.
The CLI uses ARM REST resource operations, not template deployments.

Implemented: shared JSON inputs/outputs, preflight, and VNet/subnet foundations.
Platform resources, identity, private endpoints, private DNS zones/links, application
publication and acceptance are **not implemented by this path yet**. Do not interpret
a verified foundation as production connectivity or production readiness.

## Prepare once

Use a reviewed checkout with PowerShell 7 and Azure CLI. No extra packages are needed.
Copy the example **outside the checkout**, into an existing restricted local directory:

```powershell
$repo = 'C:\devbox\ccof-bicep'
$config = 'C:\private\ccof\environment.prod.json'
Copy-Item (Join-Path $repo 'deployment\scripted\environment.example.json') $config
```

Fill the file with approved tenant/subscription/region, an existing network resource
group, non-overlapping IPv4 ranges, subnet names and the APIM subnet's existing NSG ID.
Replace every `REPLACE-` value. `mode: existing` is the safe starting point; switch
explicitly to `create` to permit creation of missing VNets/subnets. No existing resource
is updated in either mode. Matching existing resources may be verified and referenced.
Unrelated subnets are preserved.

Optional NSG, route table and NAT gateway references must already exist in the configured
subscription and VNet region; their resource groups may differ. Existing attachments
must match the file, including explicit nulls. The script does not invent firewall,
NSG, routing or NAT policy. New subnets disable default outbound access; supply approved
egress attachments where appropriate. No NAT/route attachment does **not** prove usable
egress. These are dedicated APIM Standard v2, Flex Functions and endpoint subnets:

| Subnet | Foundation contract |
| --- | --- |
| APIM | `/27` or larger, existing NSG, `Microsoft.Web/serverFarms` delegation |
| Functions | `/27` or larger, `Microsoft.App/environments` delegation; size for actual scale |
| Private endpoints | `/29` or larger, no delegation; network-policy design is deferred |

Set `dnsServers` to approved DNS server IPs, or `[]` for Azure-provided DNS. Private-zone
links/forwarding, estate-wide overlap, routes/firewall effectiveness and runtime DNS/TLS
are separate checks. This slice supports Azure public cloud and IPv4 in one subscription.
It does not construct peering, shared DNS or cross-subscription network dependencies.

Sign in yourself to the intended tenant. Use an isolated Azure CLI profile if desired;
each terminal must set the same intended profile or sign in independently. Scripts never
log in, switch your selected subscription, register providers, create RGs or grant roles.
Every Azure operation supplies its subscription explicitly.

```powershell
az login --tenant '<approved-tenant-id>'
```

## Run logical blocks

These exact commands work in an ordinary PowerShell terminal or as commands executed
by Copilot CLI. Each is a fresh process and reads everything from the shared file;
no variables from an earlier PowerShell process are required.

```powershell
pwsh -NoProfile -File C:\devbox\ccof-bicep\deployment\scripted\00-Preflight.ps1 -ConfigurationPath C:\private\ccof\environment.prod.json
pwsh -NoProfile -File C:\devbox\ccof-bicep\deployment\scripted\00-Preflight.ps1 -ConfigurationPath C:\private\ccof\environment.prod.json -Action Verify

pwsh -NoProfile -File C:\devbox\ccof-bicep\deployment\scripted\10-NetworkFoundation.ps1 -ConfigurationPath C:\private\ccof\environment.prod.json
```

Review the network plan, then run **one** of:

```powershell
# Read back an existing foundation and record its verified outputs; no Azure writes.
pwsh -NoProfile -File C:\devbox\ccof-bicep\deployment\scripted\10-NetworkFoundation.ps1 -ConfigurationPath C:\private\ccof\environment.prod.json -Action Verify

# Only with mode=create and approved resource creation:
pwsh -NoProfile -File C:\devbox\ccof-bicep\deployment\scripted\10-NetworkFoundation.ps1 -ConfigurationPath C:\private\ccof\environment.prod.json -Action Apply
```

`Plan` is the default: Azure reads only; it does not change the JSON. It uses a temporary
exclusive lock, so the private directory must be writable. `Verify` changes only local
state after reading Azure. `Apply` can create missing network resources, then reads back
the result. Preflight `Apply` is equivalent to `Verify`: no Azure writes.

## Output becomes the next block's input

After successful network verification, the **same file** contains:

```json
{
  "network": {
    "outputs": {
      "vnetId": "<actual-vnet-id>",
      "apimSubnetId": "<actual-apim-subnet-id>",
      "functionsSubnetId": "<actual-functions-subnet-id>",
      "privateEndpointSubnetId": "<actual-endpoint-subnet-id>",
      "verificationScope": "ARM foundation configuration only"
    }
  }
}
```

This is an output excerpt, not a replacement configuration. A future Functions block
will consume `network.outputs.functionsSubnetId` directly, not copy it to a second input.
The shared `Get-CsfVerifiedNetworkOutputs` helper checks verified status, the fingerprint
of current `environment` + `network.inputs`, live configuration and stored output IDs.
An old success flag alone is not a dependency check. Inside a future block, after loading
the shared modules and using `Invoke-CsfBlock`:

```powershell
$network = Get-CsfVerifiedNetworkOutputs -Configuration $c
$functionsSubnetId = $network.functionsSubnetId
```

Only this block owns `network.outputs` and `modules.networkFoundation`; preflight owns
`modules.preflight`. Other sections are preserved. Keep one file per environment and
one writer at a time. Atomic replacement retains the immediately previous file as
`environment.prod.json.bak`. File content/formatting is reserialized on state updates.
Do not edit the file while a block runs; the lock coordinates scripts, not text editors.

Apply clears old network outputs before its first Azure write. A failed Apply/Verify
records failure and clears network outputs. Plan never rewrites state, even on failure.
Partial creation may remain in Azure: inspect the exact configured IDs and rerun Plan.
There is no automatic delete/rollback. Reruns verify matching resources and create only
missing ones; incompatible existing settings stop the block. Local locks do not exclude
other Azure operators: serialize changes to the target network through change control.

## Scoped permissions

| Operator | Required access |
| --- | --- |
| Preflight | Subscription provider/location metadata read; Reader on the existing network RG |
| Network Plan/Verify | Reader on the VNet/subnets and referenced NSGs/routes/NAT gateways |
| Network Apply (`create`) | Network Contributor on the network RG; required subnet join permissions on referenced NSGs/routes/NAT gateways at their actual scopes; preflight reads above |

No Owner, access-administrator role, Entra directory role or Microsoft Graph grant is
needed for this slice. Effective authorization, policy and resource locks can still deny
an operation; preflight does not promise that writes are permitted. References outside
the configured subscription are deliberately refused.

## Offline checks

From the repository root:

```powershell
pwsh -NoProfile -File .\tests\Test-ScriptedDeployment.ps1
```

Tests mock Azure CLI; they do not sign in or change Azure resources. No live deployment
or runtime connectivity qualification is implied.

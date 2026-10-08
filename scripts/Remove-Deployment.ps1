<#
.SYNOPSIS
    Removes the deployment: the resource group and, optionally, the StaleUser-* Entra groups.
    Deleted groups remain restorable from the Entra recycle bin for 30 days.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$GroupNamePrefix = 'StaleUser',
    [switch]$RemoveGroups
)
$ErrorActionPreference = 'Stop'
if ($RemoveGroups) {
    $h = @{ Authorization = "Bearer $(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)" }
    $f = [uri]::EscapeDataString("startswith(displayName,'$GroupNamePrefix-')")
    foreach ($g in (Invoke-RestMethod -Headers $h -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$f&`$select=id,displayName").value) {
        Invoke-RestMethod -Method DELETE -Headers $h -Uri "https://graph.microsoft.com/v1.0/groups/$($g.id)" | Out-Null
        Write-Host "Deleted group $($g.displayName)"
    }
}
az group delete -n $ResourceGroup --yes --no-wait
Write-Host "Resource group deletion started: $ResourceGroup (the managed identity and its Graph permissions are removed with it)."

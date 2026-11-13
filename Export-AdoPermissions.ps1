<#
.SYNOPSIS
  Read-only export of Azure DevOps project group membership and role assignments
  on service connections, project agent queues, and organization agent pools.
.NOTES
  Requires Azure CLI (az) and az login with an account that can read the org's security settings.
  Uses GET requests only. Output CSV contains identities - do NOT commit it.
  List calls are a single page (projects are capped at $top=500). Large organizations
  need continuation-token paging; see the README. A full page returns success with no warning.
#>
param(
  [Parameter(Mandatory = $true)][string]$Org,
  [string]$Out = ".\ado-permissions.csv"
)

# Windows PowerShell 5.1 can still negotiate TLS 1.0. Azure DevOps requires TLS 1.2.
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Invoke-RestMethod in Windows PowerShell 5.1 writes progress on every call and becomes very slow.
$ProgressPreference = "SilentlyContinue"

$Org = $Org.Trim()
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) was not found on PATH. Install it and run 'az login' first."
}

# Windows PowerShell 5.1 otherwise decodes az.cmd output with the wrong code page and corrupts the token.
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = @(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv)
$tok = ([string]($raw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)).Trim()
# az sometimes emits a warning line or a trailing CR. A real token is a three-part JWT.
if ([string]::IsNullOrWhiteSpace($tok) -or ($tok -notmatch '^\S+\.\S+\.\S+$')) {
  throw "Could not get an Azure DevOps token. Run 'az login' first."
}
$H = @{ Authorization = "Bearer $tok" }
$Base = "https://dev.azure.com/$Org"
$Vssps = "https://vssps.dev.azure.com/$Org"
$rows = New-Object System.Collections.Generic.List[object]

function Get-Ado($url) { Invoke-RestMethod -Uri $url -Headers $H -Method Get }

function Add-RoleRows($scope, $resource, $kind, $project, $name) {
  try {
    $ra = Get-Ado "$Base/_apis/securityroles/scopes/$scope/roleassignments/resources/${resource}?api-version=7.1-preview.1"
  } catch {
    Write-Warning "$kind '$name' (scope $scope) : $($_.Exception.Message)"
    return
  }
  if ($null -eq $ra -or $null -eq $ra.value) { return }
  foreach ($a in $ra.value) {
    try {
      $rows.Add([pscustomobject]@{
        Kind=$kind; Project=$project; Object=$name; Principal=$a.identity.displayName
        PrincipalId=$a.identity.uniqueName; Role=$a.role.name; Access=$a.access })
    } catch {
      Write-Warning "$kind '$name' (scope $scope) : $($_.Exception.Message)"
    }
  }
}

$projects = (Get-Ado "$Base/_apis/projects?`$top=500&api-version=7.1").value
foreach ($p in $projects) {
  # Project security groups and their direct members (users here = direct assignments).
  # Descriptors are URL-encoded; unencoded '+' or '=' breaks the graph query.
  try {
    $desc = (Get-Ado "$Vssps/_apis/graph/descriptors/$($p.id)?api-version=7.1-preview.1").value
    $groups = (Get-Ado "$Vssps/_apis/graph/groups?scopeDescriptor=$([uri]::EscapeDataString([string]$desc))&api-version=7.1-preview.1").value
    foreach ($g in $groups) {
      try {
        $gDesc = [uri]::EscapeDataString([string]$g.descriptor)
        $mem = (Get-Ado "$Vssps/_apis/graph/memberships/${gDesc}?direction=down&api-version=7.1-preview.1").value
        foreach ($m in $mem) {
          try {
            $mDesc = [uri]::EscapeDataString([string]$m.memberDescriptor)
            $sub = Get-Ado "$Vssps/_apis/graph/subjects/${mDesc}?api-version=7.1-preview.1"
            $rows.Add([pscustomobject]@{
              Kind="ProjectGroup"; Project=$p.name; Object=$g.displayName; Principal=$sub.displayName
              PrincipalId=$sub.principalName; Role=$sub.subjectKind; Access="member" })
          } catch { Write-Warning "ProjectGroup $($p.name) / $($g.displayName) : $($_.Exception.Message)" }
        }
      } catch { Write-Warning "ProjectGroup $($p.name) / $($g.displayName) : $($_.Exception.Message)" }
    }
  } catch { Write-Warning "ProjectGroup $($p.name) : $($_.Exception.Message)" }

  # Service connections
  try {
    $eps = (Get-Ado "$Base/$($p.id)/_apis/serviceendpoint/endpoints?api-version=7.1").value
    foreach ($e in $eps) { Add-RoleRows "distributedtask.serviceendpointrole" "$($p.id)_$($e.id)" "ServiceConnection" $p.name $e.name }
  } catch { Write-Warning "ServiceConnection $($p.name) : $($_.Exception.Message)" }

  # Project agent queues
  try {
    $qs = (Get-Ado "$Base/$($p.id)/_apis/distributedtask/queues?api-version=7.1").value
    foreach ($q in $qs) { Add-RoleRows "distributedtask.agentqueuerole" "$($p.id)_$($q.id)" "AgentQueue" $p.name $q.name }
  } catch { Write-Warning "AgentQueue $($p.name) : $($_.Exception.Message)" }
}

# Organization agent pools
try {
  $pools = (Get-Ado "$Base/_apis/distributedtask/pools?api-version=7.1").value
  foreach ($pl in $pools) { Add-RoleRows "distributedtask.agentpoolrole" "$($pl.id)" "AgentPool" "(org)" $pl.name }
} catch { Write-Warning "AgentPool : $($_.Exception.Message)" }

if ($rows.Count -eq 0) {
  "Kind,Project,Object,Principal,PrincipalId,Role,Access" | Set-Content -LiteralPath $Out -Encoding utf8
} else {
  $rows | Export-Csv -LiteralPath $Out -NoTypeInformation -Encoding utf8
}
"Wrote $($rows.Count) rows to $Out"

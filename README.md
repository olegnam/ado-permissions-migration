# Azure DevOps permissions migration kit

This kit helps a cloud engineer move Azure DevOps permissions off direct per-user assignments and onto group-based access driven by Okta.

Azure DevOps accepts Microsoft Entra users and groups. It does not accept Okta groups directly. The working model is:

1. Push the Okta groups into Microsoft Entra ID so Entra group membership follows Okta.
2. Add those Entra groups to Azure DevOps groups.
3. Grant service connection, agent queue, and agent pool roles to Azure DevOps groups, which then contain the Entra groups.

`Export-AdoPermissions.ps1` is a read-only inventory of where access sits today. It sends GET requests only. It writes a CSV of project group members and of role assignments on service connections, project agent queues, and organization agent pools. The CSV contains identities. Do not commit it. `*.csv` is gitignored except for the fake mapping template.

Changing who can use a service connection in Azure DevOps does not change the Azure RBAC permissions held by that connection's service principal or managed identity. Azure role assignments on subscriptions, resource groups, and resources stay as they are until someone changes them in Azure.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7. The script uses Windows PowerShell 5.1 syntax.
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) on `PATH`.
- `az login` with an account that can read the organization's security data: project groups and membership, service connections, agent queues, and agent pools. The account's Entra tenant must be the tenant connected to the Azure DevOps organization.
- The token is an Azure DevOps access token for resource `499b84ac-1321-427f-aa17-267ca6975798`, obtained with `az account get-access-token`. No personal access token is required.

## Usage

Pass the organization name from `https://dev.azure.com/<org>`, not the full URL.

```powershell
.\Export-AdoPermissions.ps1 -Org <org>
```

The default output file is `.\ado-permissions.csv`. Choose another path with `-Out`:

```powershell
.\Export-AdoPermissions.ps1 -Org <org> -Out .\contoso-ado-permissions.csv
```

A warning means that call was skipped. The script keeps going and still writes the CSV. Listing projects is the exception: a bad token or an unknown organization stops the script before it writes the file. See [Role scope names](#role-scope-names) before treating a service connection, queue, or pool warning as a missing permission.

## CSV columns

| Column | Meaning |
| --- | --- |
| Kind | `ProjectGroup`, `ServiceConnection`, `AgentQueue`, or `AgentPool`. |
| Project | Project name. Organization agent pools use `(org)`. |
| Object | Azure DevOps group display name, service connection name, queue name, or pool name. |
| Principal | Display name of the member or of the identity that holds the role. |
| PrincipalId | For `ProjectGroup` rows, the graph subject's `principalName` (often an email). For role rows, the identity `uniqueName`. This can be blank for some groups. |
| Role | For `ProjectGroup` rows, the subject kind: `user`, `group`, or `servicePrincipal`. For the other kinds, the security role name, such as `Reader`, `User`, or `Administrator`. |
| Access | `member` on group rows. On role rows, `assigned` is a direct assignment on that object and `inherited` came from a parent scope. |

`ProjectGroup` rows are direct members only (`direction=down`, one level). The script does not expand nested groups. A person who has access only because their group is a member appears as that group (`Role=group`), which is the target shape.

## How to spot direct user assignments

Review `ProjectGroup` rows with `Role=user`. Those people were added directly to a project group (for example Contributors, Readers, or Project Administrators). `Role=servicePrincipal` is also a direct non-group member and should be reviewed the same way. `Role=group` is already group-based access, including an Entra group that Okta pushes.

On `ServiceConnection`, `AgentQueue`, and `AgentPool` rows, `Role` is the permission (`Reader`, `User`, `Administrator`, and similar), not the principal type. An individual assignment is a row whose Principal is a person and whose PrincipalId looks like a user email, with `Access=assigned`. A group assignment shows a group name in Principal. `Access=inherited` is not a direct assignment on that object.

Use the export to fill in [group-mapping.template.csv](group-mapping.template.csv), then add the Entra groups and verify access before deleting any direct assignment. The template's three data rows are fake examples (`FAKE`, `example.com`, `ExampleProject`). Replace them with the real mapping. Columns:

| Column | Meaning |
| --- | --- |
| OktaGroup | Okta group whose members should receive the access. |
| EntraGroup | Microsoft Entra group that Okta pushes into. |
| AdoScope | Azure DevOps organization name or project name. |
| AdoGroupOrResource | Azure DevOps group, or the service connection, queue, or pool name. |
| RoleOrPermission | Group membership (`Member`) or the role to grant (for example User or Administrator). |
| Owner | Person or team accountable for the mapping. |
| Notes | Why the row exists and any cutover detail. |

## Role scope names

Service connection, agent queue, and agent pool roles are read with the security roles API and these scope names:

- `distributedtask.serviceendpointrole` for service connections (resource id `{projectId}_{endpointId}`)
- `distributedtask.agentqueuerole` for project agent queues (resource id `{projectId}_{queueId}`)
- `distributedtask.agentpoolrole` for organization agent pools (resource id is the pool id)

Those scope names are only partly documented. A warning in this part of the run includes the scope name. A 404, or a message that the scope is unknown, likely means the scope name. A 401 or 403 means the account could not read that resource.

## Large organizations and paging

Each list call takes one page. Projects are requested with `$top=500`. Graph groups, group memberships, service endpoints, queues, and pools are also a single response. Graph list APIs put the next page in the `X-MS-ContinuationToken` response header (pass it back as the `continuationToken` query parameter). This script uses `Invoke-RestMethod` and does not follow that header.

A large organization can therefore produce a successful export that is missing projects, groups, members, or resources, with no warning. If the counts look short, add paging before you use the CSV to remove access.

## Cutover

- Add the Azure DevOps group (with the Entra group inside it) and verify the same people can still perform the work. Remove the direct user assignment only after that check.
- Do not remove the last Administrator on a service connection. Leave a group in the Administrator role, confirm someone in that group can manage the connection, and only then remove direct Administrator users.
- Per-pipeline authorization on service connections is separate from these role assignments. This export does not list it, and changing role assignments leaves pipeline authorization as it is.
- Approvals and checks that name individual approvers must be switched to groups. This export does not list approval or check approvers.
- Microsoft Entra group changes can take up to an hour to appear in Azure DevOps. Wait for the new membership to show up before you conclude that a group grant failed.

## References

- [Manage Microsoft Entra groups in Azure DevOps](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/manage-azure-active-directory-groups?view=azure-devops)
- [Security overview](https://learn.microsoft.com/en-us/azure/devops/organizations/security/security-overview?view=azure-devops)
- [Role assignments - List](https://learn.microsoft.com/en-us/rest/api/azure/devops/securityroles/roleassignments/list?view=azure-devops-rest-7.1)
- [About permissions and security groups](https://learn.microsoft.com/en-us/azure/devops/organizations/security/about-permissions?view=azure-devops)

# Taming the Azure DevOps Service Connection Beast

## Bringing Order to your Azure DevOps Service Connections and Corresponding Application Registrations

### The Problem

If you suffer from any of these challenges:
- Maintaining a full inventory of all your Azure DevOps ARM Service Connections along with their corresponding Application Registrations in Microsoft Entra ID (Azure AD)
- Determining Expired Application Registrations or Unused Service Connections
- Establishing Governance and Naming Conventions around these Application Registrations and Corresponding Service Principals

then this post is for you!

### The Solution

#### Overview

To tackle these challenges we need to:
- Get all Application Registrations and Corresponding Service Principals
- Obtain a complete inventory of all our ADO Service Connections, more specifically, the ARM service connections.

#### Getting All App Registrations and Service Principals

This is relatively straightforward:
```
Write-Host "Fetching all app registrations from Azure AD..."
$appRegistrationsJson = az ad app list --all
$appRegistrations = $appRegistrationsJson | ConvertFrom-Json -Depth 100
Write-Host "There is a total of $($appRegistrations.Length) app registrations."
```

Sample Output:
![get all app registrations](/media/get_all_app_registrations.png)

The output `$appRegistrationsJson` is a JSON array of elements such as [sampleArmConnectionAppRegistrationData.json](https://github.com/devopsshield/ado-service-connection/blob/main/data/sampleArmConnectionAppRegistrationData.json)

Just as easily, we can obtain all service principals like so:
```
Write-Host "Fetching all service principals from Azure AD..."
$servicePrincipalsJson = az ad sp list --all
$servicePrincipals = $servicePrincipalsJson | ConvertFrom-Json -Depth 100
Write-Host "There is a total of $($servicePrincipals.Length) service principals."
```

Sample Output:
![get all service principals](/media/get_all_service_principals.png)

The output `$servicePrincipalsJson` is also a JSON array of elements.

#### ARM Service Connections

For ARM Service Connections created as in [here](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure?view=azure-devops#create-an-azure-resource-manager-service-connection-using-automated-security), the corresponding App Registration will have its `homePageUrl` set to `https://VisualStudio/SPN` as can be seen here:
![sample arm service connection](/media/sample_arm_svc_conn.png)

The corresponding JSON element [sampleArmConnectionAppRegistrationData.json](https://github.com/devopsshield/ado-service-connection/blob/main/data/sampleArmConnectionAppRegistrationData.json) reflects this fact:
![sample arm service connection JSON](/media/sample_arm_conn_json.png)

#### Getting All ADO Service Connections (Do-It-Yourself)

Ultimately, to get all service connections, we must loop over all our ADO organizations, then loop over all our projects, and finally, get all service connections.

This can be accomplished with the [Azure DevOps REST API](https://learn.microsoft.com/en-us/rest/api/azure/devops/?view=azure-devops-rest-7.1).

For a given organization and project, we can obtain all [service endpoints](https://learn.microsoft.com/en-us/rest/api/azure/devops/serviceendpoint/endpoints/get-service-endpoints?view=azure-devops-rest-7.1&tabs=HTTP).

This can also be done with the following [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/get-started-with-azure-cli) call using the [Azure DevOps CLI extension](https://learn.microsoft.com/en-us/azure/devops/cli/?view=azure-devops):

```
$organization = "https://dev.azure.com/devopsabcs"
$project = "OneProject"
$serviceEndpointsJson = az devops service-endpoint list --organization $organization --project $project
$serviceEndpoints = $serviceEndpointsJson | ConvertFrom-Json -Depth 100
$organizationName = ($organization -split "/")[3]
Write-Host "Organization $organizationName has project $project with $($serviceEndpoints.Length) service endpoints."
```

Sample Output:
![sample output using azure devops cli](/media/sample_output_azure_devops_cli.png)

The output is a JSON array of elements that look like [sampleEndpointData.json](https://github.com/devopsshield/ado-service-connection/blob/main/data/sampleEndpointData.json).

#### Getting All ADO Service Connections (With DevOps Shield)

DevOps Shield is an innovative cybersecurity platform for DevOps and available for FREE from the [Azure Marketplace](https://azuremarketplace.microsoft.com/en-us/marketplace/apps/cad4devopsinc1662079207461.devops-shield?src=website&mktcmpid=header). It continuously provides a full inventory of all our ADO resources including all service connections.

Indeed, we can see all **127 service connections** for the project **OneProject** of the organization **devopsabcs** above in the Data Explorer:
![data explorer overview](/media/data_explorer_overview.png)

We can also navigate to the same [sampleEndpointData.json](https://github.com/devopsshield/ado-service-connection/blob/main/data/sampleEndpointData.json):
![data explorer details](/media/data_explorer_details.png)

Finally, in a [single kusto query](https://github.com/devopsshield/ado-service-connection/blob/main/queries/service-connections.kql), we can obtain **all** service connections for **all** our projects in **all** our ADO organizations for **all** of our Microsoft Entra IDs (Azure ADs):
![kusto query](/media/kusto_query.png)

#### Establishing order through naming conventions

While navigating from a service connection to its corresponding application registration is easy enough by clicking on the *Manage Service Principal* hyperlink:
![hyperlink service principal](/media/hyperlink_service_principal.png)

You will navigate to the corresponding App Registration:
![app registration azure portal](/media/app_registration_azure_portal.png)

Determining which App Registration is referenced by **at least one** ARM Service Connection as well as determining **all** service connections that are dependent on this App registration is much more challenging.

We tackle this problem in the following way:
- We rename all such App Registrations using a **naming convention**
- We leverage a field of the App Registration such as the **Internal Notes** field to list all service connections that use the app registration

The end result leads to being able to quickly determine all app registrations that are used as ARM Service Connections in ADO with a prefix such as **ADO-**:
![ado prefix](/media/ado_prefix.png)

For any such app registration, we populate the notes field to list all ADO Service Connections that use it:
![multiple service connections](/media/multiple_service_connections.png)

Note that the above app registration has multiple (7) app service connections. This is **not** a best practice. It is best to have exactly one app registration per ADO Arm Service Connection. DevOps Shield has 100+ DevOps Shield Policies which, in particular, highlight such *non-compliant* service connections.

#### Running The PowerShell Script

Running the PowerShell Script [Rename-ServicePrincipals.ps1](https://github.com/devopsshield/ado-service-connection/blob/main/scripts/Rename-ServicePrincipals.ps1) yields the following production run summary and is **idempotent**:
![production summary visual studio code](/media/production_summary_vs_code.png)

The above was obtained by executing:
```
$devOpsShieldLogAnalyticsWorkspaceName = 'log-devopsshield-ek010devfd63l2gacbtca'
$devOpsShieldResourceGroupName = 'rg-devopsshieldek010dev'
$devOpsShieldSubscriptionIdOrName = "Microsoft Azure Sponsorship"
./Rename-ServicePrincipals.ps1 -WorkspaceName $devOpsShieldLogAnalyticsWorkspaceName `
                               -ResourceGroupName $devOpsShieldResourceGroupName `
                               -subscriptionIdOrName $devOpsShieldSubscriptionIdOrName `
                               -isProductionRun $true `
                               -usePreviouslyFetchedResults $false 
```
You can also execute this in a regular PowerShell window:
![production summary PowerShell](/media/production_summary_power_shell.png)

#### Script Highlights

The naming convention used can be customized and appears in the PowerShell Function:
```
function Rename-AppRegistration {
    param (
        [string] $organizationName,
        [string] $projectName,
        [string] $subscriptionId,
        [string] $serviceConnectionName,
        [string] $endpointId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ServiceConnections
    )

    # To determine primary project - we take the first service connection
    $firstServiceConnectionUrl = $ServiceConnections[0]
    $primaryOrganizationName = Get-PrimaryOrganizationName $firstServiceConnectionUrl
    $primaryProjectName = Get-PrimaryProjectName $firstServiceConnectionUrl
    $primaryEndpointId = Get-PrimaryEndpointId $firstServiceConnectionUrl

    $newDisplayName000 = "$primaryOrganizationName-$primaryProjectName-$subscriptionId" #default
    $newDisplayName001 = substr "ADO-$primaryOrganizationName-$primaryProjectName-$subscriptionId" 0 $maxNameLength #default with prefix
    $newDisplayName002 = substr "$primaryOrganizationName-$primaryProjectName-$primaryEndpointId" 0 $maxNameLength #unique name 
    $newDisplayName003 = substr "ADO-$primaryOrganizationName-$primaryProjectName-$primaryEndpointId" 0 $maxNameLength #unique name with prefix
    $newDisplayName004 = substr "$primaryOrganizationName-$primaryProjectName-$serviceConnectionName" 0 $maxNameLength #friendly name

    # Choose a name format:
    $newDisplayName = $newDisplayName003 #choosing 003

    return $newDisplayName
}
```

We recommend going with a naming scheme such as:
```
ADO-$primaryOrganizationName-$primaryProjectName-$primaryEndpointId
```

This has the advantage of being uniquely named. The reason we add the qualifier **primary** is that a given app registration could be used in more than one ADO ARM Service Connection. Therefore, in order for the display name to remain idempotent, we must consistently choose a *representative* service connection to base the display name on. We call this service connection the **primary** one.

The script also highlights (using colors) which app registrations tied to a service connection were created automatically (🟢) or manually (🟡) as can be seen in this output:
![creation mode automatic versus manual](/media/creation_mode_auto_vs_manual.png)

Finally, the script also highlights "App Registrations That Is Probable Arm Connection". This is just a fancy way of spotting app registrations that have its `homePageUrl` set to `https://VisualStudio/SPN` as can be seen in the snippet:
```
$homePageUrl = $appRegistration.web.homePageUrl
$isProbableArmConnection = $false
if ($homePageUrl -eq $defaultHomePageUrlForArmConnection) {
    $isProbableArmConnection = $true
    if ($isProbableArmConnection) {
        Write-Host "found likely arm connection $($appRegistration.displayName)"
        $totalNumberOfAppRegistrationsThatIsProbableArmConnection++
    }
    foreach ($uri in $appRegistration.web.redirectUris) {
        Write-Host "web redirect uri: $uri"
    }
}
```

After running the script in production, we can then execute this to determine orphaned app registrations:
```
Write-Host "Fetching all app registrations from Azure AD..."
$appRegistrationsJson = az ad app list --all
$appRegistrations = $appRegistrationsJson | ConvertFrom-Json -Depth 100
Write-Host "There is a total of $($appRegistrations.Length) app registrations."
Write-Host "Filtering for app registrations that Is Probable Arm Connection..."
$defaultHomePageUrlForArmConnection = "https://VisualStudio/SPN"
$appRegistrationsThatIsProbableArmConnection = $appRegistrations | Where-Object {$_.web.homePageUrl -eq $defaultHomePageUrlForArmConnection}
Write-Host "There is a total of $($appRegistrationsThatIsProbableArmConnection.Length) app registrations that are Probable Arm Connections."
$appRegistrationsThatIsOrphan = $appRegistrations | Where-Object {($_.web.homePageUrl -eq $defaultHomePageUrlForArmConnection) -and -not $_.notes}
Write-Host "There is a total of $($appRegistrationsThatIsOrphan.Length) orphaned app registrations."
Write-Host "Here are all orphaned app registrations:"
$appRegistrationsThatIsOrphan | Sort-Object -Property DisplayName | Select-Object -Property DisplayName, AppId | Format-Table -AutoSize
$orphansPath = "orphans.txt"
$appRegistrationsThatIsOrphan | Sort-Object -Property DisplayName | Select-Object -Property DisplayName, AppId | Format-Table -AutoSize | Out-File -FilePath $orphansPath
```

We encourage you to review your orphaned app registrations. There can be many reasons why you have orphaned app registrations. For instance, the app registration may point to a resource group that no longer exists. You may then see an error message such as:
```
Failed to set Azure permission 'RoleAssignmentId: ********-****-****-****-************' for the service principal '********-****-****-****-************' on subscription ID '********-****-****-****-************': error code: NotFound, innner error code: ResourceGroupNotFound, inner error message Resource group 'jenkins-storage-rg' could not be found. For troubleshooting refer to <a href="https://go.microsoft.com/fwlink/?linkid=835898" target="_blank">link</a>.
```

There may be other causes for orphaned resources such as:
- ADO project deletion

#### Limitations

For now, the script handles only one Azure AD at a time. It does however allow you to have distinct tenants: one for the Azure AD containing the app registrations and one for the tenant containing the DevOps Shield app (if different). However, it shouldn't be too difficult to extend the script to support multiple Azure AD tenants. This is because **DevOps Shield has multi-tenant support**.

Finally, the script does show expired and expiring password credentials for all app registrations. However, it does not attempt to rotate expired or expiring keys. Instead, it allows you to highlight expired app registrations and possibly expose unused ARM service connections.

## References

1. [Create an Azure Resource Manager service connection using automated security](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure?view=azure-devops#create-an-azure-resource-manager-service-connection-using-automated-security)
1. [Azure DevOps Services REST API Reference](https://learn.microsoft.com/en-us/rest/api/azure/devops/?view=azure-devops-rest-7.1)
1. [Get started with Azure DevOps CLI](https://learn.microsoft.com/en-us/azure/devops/cli/?view=azure-devops)
1. [DevOps Shield - Azure Marketplace](https://azuremarketplace.microsoft.com/en-us/marketplace/apps/cad4devopsinc1662079207461.devops-shield?src=website&mktcmpid=header)
1. [DevOps Shield](https://www.devopsshield.com)

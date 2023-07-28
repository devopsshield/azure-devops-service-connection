# MIT License

# Copyright (c) 2023 DevOps Shield

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

param (
    [Parameter(mandatory = $true)]
    [string] $WorkspaceName,
    [Parameter(mandatory = $true)]
    [string] $ResourceGroupName,
    [Parameter(mandatory = $true)]
    [string] $subscriptionIdOrName,
    [bool]   $isProductionRun = $false,
    [bool]   $usePreviouslyFetchedResults = $false,
    [bool]   $skipPauseAfterError = $false,
    [string] $serviceConnectionCsvPath = "../data/export_data_kql.csv",
    [string] $servicePrincipalsJsonFilePath = "../data/servicePrincipals.json",
    [string] $appRegistrationsJsonFilePath = "../data/appRegistrations.json",
    [string] $sampleDataJsonPath = "../data/sampleEndpointData.json",
    [string] $sampleDataCreatedManuallyJsonPath = "../data/sampleEndpointDataCreatedManually.json",
    [string] $sampleArmConnectionJsonPath = "../data/sampleArmConnectionAppRegistrationData.json",
    [string] $sampleArmConnectionCreatedManuallyJsonPath = "../data/sampleArmConnectionAppRegistrationDataCreatedManually.json",
    [string] $appRegToRefSvcConnJsonPath = "../data/appRegToRefSvcConn.json",
    [string] $appRegToRefSvcConnPrePopJsonPath = "../data/appRegToRefSvcConnPrePop.json",
    [int]    $jsonDepth = 100,
    [int]    $maxNameLength = 93, #maximum in Azure Portal
    [int]    $maxNotesLength = 1024, #Less than 1024 characters in length
    [int]    $toleranceInDaysForPasswordExpiration = 60,
    [string] $queryFile = '../queries/service-connections.kql',
    [string] $bookkeepingCsvPath = "../data/appRegistrationRefServiceConnectionsBookkeeping.csv",
    [string] $orphansPath = "../data/orphans.txt",
    [bool]   $doExtraSanityChecks = $false
)

# # sample production call
# ./Rename-ServicePrincipals.ps1 -WorkspaceName 'log-devopsshield-ek010devfd63l2gacbtca' `
#     -ResourceGroupName  'rg-devopsshieldek010dev' `
#     -subscriptionIdOrName "Microsoft Azure Sponsorship"
#     -isProductionRun $true `
#     -usePreviouslyFetchedResults $true

# STEP 1
Write-Host 'Step 1: Login to your Azure account using Connect-AzAccount (use an account that has access to your DevOps Shield application) ...'

#Disconnect-AzAccount
Clear-AzContext -Force

$login = Connect-AzAccount

if (!$login) {
    Write-Error 'Error logging in and validating your credentials.'
    return;
}

Write-Host "setting subscription to `"$subscriptionIdOrName`""
Set-AzContext -Subscription $subscriptionIdOrName

$defaultHomePageUrlForArmConnection = "https://VisualStudio/SPN"

$numberOfAppRegistrationsProcessed = 0
$numberOfAppRegistrationsUpdated = 0
$numberOfAppRegistrationsSkippedDueToTenantMismatch = 0
$numberOfAppRegistrationsSkippedDueToNoUpdateRequired = 0
$numberOfAppRegistrationsSkippedDueToMaxNoOfRefServiceConnectionsNotYetReached = 0
$numberOfAppRegistrationsWithAnIssueUpdating = 0

$totalNumberOfAppRegistrations = 0
$totalNumberOfAppRegistrationsWithExpiredPasswordCredentials = 0

$totalNumberOfAppRegistrationsThatIsProbableArmConnection = 0
$totalNumberOfAppRegistrationsThatIsProbableArmConnectionWithExpiredPasswordCredentials = 0

$numberOfArmServiceConnectionsCreatedAutomatically = 0
$numberOfArmServiceConnectionsCreatedManually = 0
$totalNumberOfArmServiceConnections = 0

$totalNumberOfReferencedServiceConnectionIterations = 0

# Safe equivalent of:
#    $String.Substring($Start)
#    $String.Substring($Start, $Length)
function substr {
    param (
        [string] $String,
        [int]    $Start = 0,
        [int]    $Length = -1
    )

    if ($Length -eq -1 -or $Start + $Length -ge $String.Length) {
        $String.Substring($Start)
    }
    else {
        $String.Substring($Start, $Length)
    }
}

function Get-PrimaryOrganizationName {
    param (
        [string] $serviceConnectionUrl
    )

    return ($serviceConnectionUrl -split "/" | Where-Object { $_ -ne "" })[2]
}

function Get-PrimaryProjectName {
    param (
        [string] $serviceConnectionUrl
    )

    return ($serviceConnectionUrl -split "/" | Where-Object { $_ -ne "" })[3]
}

function Get-PrimaryEndpointId {
    param (
        [string] $serviceConnectionUrl
    )

    $firstArray = $serviceConnectionUrl -split "/" | Where-Object { $_ -ne "" }
    $rawEndpoint = $firstArray[$($firstArray.Length) - 1]
    $secondArray = $rawEndpoint -split "="

    return $secondArray[$($secondArray.Length) - 1]
}

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

function New-InternalNotes {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ServiceConnections
    )

    $notes = "No of Service Connections: $($ServiceConnections.Length)"

    foreach ($ServiceConnection in $ServiceConnections) {
        $notes += "`n$ServiceConnection"
    }

    $notes = substr $notes 0 $maxNotesLength

    return $notes
}

function New-PatchBody {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ServiceConnections
    )

    $appPatchBody = "{`"`"notes`"`":`"`""
    $appPatchBodyNotesValue = "No of Service Connections: $($ServiceConnections.Length)"

    foreach ($ServiceConnection in $ServiceConnections) {
        $appPatchBodyNotesValue += "\n$ServiceConnection"
    }

    #truncate appPatchBodyNotesValue if needed
    $appPatchBodyNotesValue = substr $appPatchBodyNotesValue 0 $maxNotesLength

    $appPatchBody += $appPatchBodyNotesValue
    $appPatchBody += "`"`"}"

    return $appPatchBody
}

function Get-ServiceConnections {
    param (
        [string] $WorkspaceName, # = 'log-devopsshield-ek010devfd63l2gacbtca',
        [string] $ResourceGroupName, # = 'rg-devopsshieldek010dev',
        [string] $queryFile = '../queries/service-connections.kql',
        [string] $serviceConnectionCsvPath = '../data/export_data_kql.csv'
    )
    $exported = $false

    $query = Get-Content -Raw $queryFile
    $query = $query.Replace('\n', ' ').Replace('\r', ' ')
    Write-Host "The following Kusto Query will be used to fetch service connections:"
    Write-Host $query
    $Workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName `
        -Name $WorkspaceName
    $QueryResults = Invoke-AzOperationalInsightsQuery -Workspace $Workspace `
        -Query $query
    $QueryResults.Results | export-csv -Delimiter "," `
        -Path $serviceConnectionCsvPath #-NoTypeInformation

    $exported = $true

    return $exported
}

function Update-Guid {
    param (
        [Parameter(Mandatory)]
        [string] $filename
    )

    ## GuidSwap.ps1
    ##
    ## Reads a file, finds any GUIDs in the file, and swaps them for a NewGUID
    ##

    $folder = (Get-ChildItem $filename).Directory.FullName
    $baseFileName = (Get-ChildItem $filename).BaseName
    $extension = (Get-ChildItem $filename).Extension
    $outputFilename = "$folder\${baseFileName}_masked$extension"

    $text = [string]::join([environment]::newline, (get-content -path $filename))

    $sbNew = new-object system.text.stringBuilder

    #$guidPattern = "[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}"
    $guidPattern = "[a-fA-F0-9]{5}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}" #leave hint

    $lastStart = 0
    $null = ([regex]::matches($text, $guidPattern) | ForEach-Object {
            $sbNew.Append($text.Substring($lastStart, $_.Index - $lastStart))
            #$guid = [system.guid]::newguid()
            #$maskedGuid = "********-****-****-****-************"
            $maskedGuid = "*****-****-****-****-************" #leave hint
            $sbNew.Append($maskedGuid)
            $lastStart = $_.Index + $_.Length
        })
    $null = $sbNew.Append($text.Substring($lastStart))

    # $sbNew.ToString() | out-file $outputFilename

    Write-Host "Done masking guids"

    $text = $sbNew.ToString()

    $sbNew = new-object system.text.stringBuilder
    
    #$descriptorPattern = "aad.[a-zA-Z0-9]{48}"
    $descriptorPattern = "aad.[a-zA-Z0-9]{45}" #leave hint

    $lastStart = 0
    $null = ([regex]::matches($text, $descriptorPattern) | ForEach-Object {
            $sbNew.Append($text.Substring($lastStart, $_.Index - $lastStart))
            $maskedDescriptor = "aad.************************************************"
            $maskedDescriptor = "aad.*********************************************" #leave hint
            $sbNew.Append($maskedDescriptor)
            $lastStart = $_.Index + $_.Length
        })
    $null = $sbNew.Append($text.Substring($lastStart))

    $sbNew.ToString() | out-file $outputFilename

    Write-Host "Done masking descriptors"

}

try {
    # STEP 2
    Write-Host "Step 2: Get Service Connections from Log Analytics Workspace $WorkspaceName and export to CSV $serviceConnectionCsvPath ..."
    $exported = Get-ServiceConnections -WorkspaceName $WorkspaceName `
        -ResourceGroupName $ResourceGroupName `
        -queryFile $queryFile `
        -serviceConnectionCsvPath $serviceConnectionCsvPath
}
catch {
    throw
}

if ($exported) {
    # STEP 3
    Write-Host 'Step 3: Get Service Principals and App Registrations from Microsoft Entra ID (aka Azure AD) ...'

    Write-Host 'Login to your Azure account using az login (use an account that has access to your Microsoft Entra ID) ...'

    az account clear

    $login = az login --only-show-errors

    if (!$login) {
        Write-Error 'Error logging in and validating your credentials.'
        return;
    }

    $accountJson = az account show
    $account = $accountJson | ConvertFrom-Json
    $currentTenantId = $($account.tenantId)
    Write-Host "Current Tenant ID: $currentTenantId"

    if (-not $usePreviouslyFetchedResults) {
        Write-Host "Fetching service principals from Azure AD..."
        Write-Host "You can still use '--all' to get all of them with long latency expected, or provide a filter through command arguments"
        $servicePrincipalsJson = az ad sp list --all
        Set-Content -Value $servicePrincipalsJson -Path $servicePrincipalsJsonFilePath
    }
    else {
        Write-Host "Fetching previously fetched service principals"
        $servicePrincipalsJson = Get-Content -Path $servicePrincipalsJsonFilePath
    }

    $servicePrincipals = $servicePrincipalsJson | ConvertFrom-Json

    # Create a hashtable for Service Principals
    $htServicePrincipals = @{}

    try {
        foreach ($servicePrincipal in $servicePrincipals) {
            Write-Host $servicePrincipal.id
            $htServicePrincipals[$servicePrincipal.id] = $servicePrincipal
        }
    }
    catch {
        <#Do this if a terminating exception happens#>
    }
    finally {
        <#Do this after the try block regardless of whether an exception occurred or not#>
    }

    # Create hashtables for App Registrations
    $htAppRegistrationsByAppObjId = @{}
    $htAppRegistrationsByAppClientId = @{}

    # Create hashtables for App Registration Service Connections
    $htAppRegistrationServiceConnectionsByAppClientId = @{}
    $htAppRegistrationServiceConnectionsByAppClientIdPrePopulated = @{}

    if (-not $usePreviouslyFetchedResults) {
        Write-Host "Fetching app registrations from Azure AD..."
        Write-Host "You can still use '--all' to get all of them with long latency expected, or provide a filter through command arguments"
        $appRegistrationsJson = az ad app list --all
        Set-Content -Value $appRegistrationsJson -Path $appRegistrationsJsonFilePath
    }
    else {
        Write-Host "Fetching previously fetched app registrations"
        $appRegistrationsJson = Get-Content -Path $appRegistrationsJsonFilePath
    }

    $appRegistrations = $appRegistrationsJson | ConvertFrom-Json

    $totalNumberOfAppRegistrations = $appRegistrations.Length

    # STEP 4
    Write-Host "Step 4: Analyze App Registrations highlighting ARM connections along with expiring and expired password credentials ..."

    try {
        foreach ($appRegistration in $appRegistrations) {
            Write-Host $appRegistration.id
            # Initialize Hash Tables
            $htAppRegistrationsByAppObjId[$appRegistration.id] = $appRegistration
            $htAppRegistrationsByAppClientId[$appRegistration.appId] = $appRegistration
            $htAppRegistrationServiceConnectionsByAppClientId[$appRegistration.appId] = @()
            $htAppRegistrationServiceConnectionsByAppClientIdPrePopulated[$appRegistration.appId] = @()
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
            $passwordCredentials = $appRegistration.passwordCredentials
            $totalNumberOfPasswordCredentials = $passwordCredentials.Length
            $numberOfExpiredPasswordCredentials = 0
            $numberOfExpiringSoonPasswordCredentials = 0
            $numberOfHealthyPasswordCredentials = 0
            foreach ($passwordCredential in $passwordCredentials) {
                $endDateTime = $passwordCredential.endDateTime
                Write-Host "`tpassword credential exprires on $endDateTime"
                # Variable for password expiration date
                [datetime]$passwordExpirationDate = New-Object DateTime
                if ([DateTime]::TryParse($endDateTime, 
                        [ref]$passwordExpirationDate)) {
                    # Check if password is expired or expiring
                    $numberOfDaysBeforePasswordExpires = ($passwordExpirationDate - [DateTime]::UtcNow).TotalDays
                    if ($numberOfDaysBeforePasswordExpires -le 0) {
                        $absNumberOfDaysBeforePasswordExpires = [Math]::Abs($numberOfDaysBeforePasswordExpires)
                        Write-Error "`t`tpassword expired $absNumberOfDaysBeforePasswordExpires days ago"
                        $numberOfExpiredPasswordCredentials++
                    }
                    elseif ($numberOfDaysBeforePasswordExpires -le $toleranceInDaysForPasswordExpiration) {
                        Write-Warning "`t`tpassword expires in $numberOfDaysBeforePasswordExpires days"
                        $numberOfExpiringSoonPasswordCredentials++
                    }
                    else {
                        Write-Host "`t`tpassword only expires in $numberOfDaysBeforePasswordExpires days"
                        $numberOfHealthyPasswordCredentials++
                    }
                }
                else {
                    throw
                }
            }
            Write-Host "numberOfHealthyPasswordCredentials      : $numberOfHealthyPasswordCredentials"
            Write-Host "numberOfExpiringSoonPasswordCredentials : $numberOfExpiringSoonPasswordCredentials"
            Write-Host "numberOfExpiredPasswordCredentials      : $numberOfExpiredPasswordCredentials"
            Write-Host "totalNumberOfPasswordCredentials        : $totalNumberOfPasswordCredentials"
            if ($numberOfHealthyPasswordCredentials -ne $totalNumberOfPasswordCredentials) {
                $totalNumberOfAppRegistrationsWithExpiredPasswordCredentials++
                Write-Host "You should rotate credentials OR delete the service connection if NOT used"
                if ($isProbableArmConnection) {
                    $totalNumberOfAppRegistrationsThatIsProbableArmConnectionWithExpiredPasswordCredentials++
                }
            }
        }
    }
    catch {
        <#Do this if a terminating exception happens#>
    }
    finally {
        <#Do this after the try block regardless of whether an exception occurred or not#>
    }

    # STEP 5
    Write-Host "Step 5: Populate Hash Table of App Registrations to Referenced Service Connections"
    $csv = Import-Csv -path $serviceConnectionCsvPath
    foreach ($line in $csv) {
        $properties = $line | Get-Member -MemberType Properties
        $lineContainsArmServiceConnection = $false
        for ($i = 0; $i -lt $properties.Count; $i++) {
            $column = $properties[$i]
            $columnValue = $line | Select-Object -ExpandProperty $column.Name

            if ($column.Name -eq 'spnObjectId' -and $columnValue) {
                $spObjId = $columnValue
                $lineContainsArmServiceConnection = $true
            }
            if ($column.Name -eq 'appObjectId' -and $columnValue) {
                $appObjId = $columnValue
                $lineContainsArmServiceConnection = $true
            }
            if ($column.Name -eq 'Data_s' -and $columnValue) {
                $dataJson = $columnValue
                $dataObj = $dataJson | ConvertFrom-Json
            }
            if ($column.Name -eq 'Organization' -and $columnValue) {
                $organizationName = $columnValue
            }
            if ($column.Name -eq 'Project' -and $columnValue) {
                $projectName = $columnValue
            }
            if ($column.Name -eq 'Name' -and $columnValue) {
                $serviceConnectionName = $columnValue
            }
            if ($column.Name -eq 'EndpointId' -and $columnValue) {
                $endpointId = $columnValue
            }
        }

        $applicationRegistrationClientId = $($dataObj.authorization.parameters.serviceprincipalid)
        Write-Host "App Registration Client Id   : $applicationRegistrationClientId"

        $tenantId = $($dataObj.authorization.parameters.tenantid)
        Write-Host "Tenant ID                    : $tenantId"
        Write-Host "Current AAD Tenant is        : $currentTenantId"
        Write-Host "Service Connection Tenant    : $tenantId"
        $tenantsMatch = $tenantId -eq $currentTenantId
        Write-Host "Tenants Match                : $tenantsMatch"
        if ($tenantsMatch) {
            $altAppObjId = $htAppRegistrationsByAppClientId[$applicationRegistrationClientId].id
            if ($lineContainsArmServiceConnection) {
                if ($appObjId -eq $altAppObjId) {
                    Write-Host "App Object ID is as expected : $altAppObjId"
                }
                else {
                    throw "App object id should have matched!"
                }
            }
            else {
                $appObjId = $altAppObjId
                Write-Host "Setting app object id to     : $appObjId"
            }
        }

        $serviceConnectionUrl = "https://dev.azure.com/$organizationName/$projectName/_settings/adminservices?resourceId=$endpointId"
        Write-Host "Service Connection URL       : $serviceConnectionUrl"

        $itemToAdd = "$serviceConnectionUrl"
        $htAppRegistrationServiceConnectionsByAppClientIdPrePopulated[$applicationRegistrationClientId] += , $itemToAdd

        $totalNumberOfItems = $htAppRegistrationServiceConnectionsByAppClientIdPrePopulated[$applicationRegistrationClientId].Length

        if ($totalNumberOfItems -gt 0) {
            Write-Host "Total Number Of Referenced Service Connections : $totalNumberOfItems"
            foreach ($item in $htAppRegistrationServiceConnectionsByAppClientIdPrePopulated[$applicationRegistrationClientId]) {
                Write-Host "`t$item"
            }
        }
    }

    $htAppRegistrationServiceConnectionsByAppClientIdPrePopulatedJson = $htAppRegistrationServiceConnectionsByAppClientIdPrePopulated | ConvertTo-Json
    Set-Content -Value $htAppRegistrationServiceConnectionsByAppClientIdPrePopulatedJson -Path $appRegToRefSvcConnPrePopJsonPath

    # STEP 6    
    if (Test-Path $bookkeepingCsvPath) {
        Remove-Item $bookkeepingCsvPath -verbose
    }
    else {
        Write-Host "Path doesn't exist."
    }
    Write-Host "Step 6: Update App Registrations and Corresponding Service Principal (Display Name and Internal Notes) That Originate From an ARM Service Connection ..."
    foreach ($line in $csv) {
        $totalNumberOfArmServiceConnections++
        $properties = $line | Get-Member -MemberType Properties
        $lineContainsArmServiceConnection = $false
        for ($i = 0; $i -lt $properties.Count; $i++) {
            $column = $properties[$i]
            $columnValue = $line | Select-Object -ExpandProperty $column.Name

            if ($column.Name -eq 'spnObjectId' -and $columnValue) {
                $spObjId = $columnValue
                $lineContainsArmServiceConnection = $true
            }
            if ($column.Name -eq 'appObjectId' -and $columnValue) {
                $appObjId = $columnValue
                $lineContainsArmServiceConnection = $true
            }
            if ($column.Name -eq 'Data_s' -and $columnValue) {
                $dataJson = $columnValue
                $dataObj = $dataJson | ConvertFrom-Json
            }
            if ($column.Name -eq 'Organization' -and $columnValue) {
                $organizationName = $columnValue
            }
            if ($column.Name -eq 'Project' -and $columnValue) {
                $projectName = $columnValue
            }
            if ($column.Name -eq 'Name' -and $columnValue) {
                $serviceConnectionName = $columnValue
            }
            if ($column.Name -eq 'EndpointId' -and $columnValue) {
                $endpointId = $columnValue
            }
        }

        Write-Host "-----------------------"
        Write-Host "Organization                 : $organizationName"
        Write-Host "Project                      : $projectName"
        Write-Host "Endpoint ID                  : $endpointId"
        $creationMode = $($dataObj.data.creationMode)
        if ($creationMode -eq "Automatic") {
            $numberOfArmServiceConnectionsCreatedAutomatically++
            $foregroundColor = "Green"
        }
        elseif ($creationMode -eq "Manual") {
            $numberOfArmServiceConnectionsCreatedManually++
            $foregroundColor = "Yellow"
        }
        else {
            throw "Unexpected creation mode $creationMode"
        }
        Write-Host "Creation Mode                : " -NoNewline
        Write-Host "$creationMode" -ForegroundColor $foregroundColor

        $serviceConnectionUrl = "https://dev.azure.com/$organizationName/$projectName/_settings/adminservices?resourceId=$endpointId"
        Write-Host "Service Connection URL       : $serviceConnectionUrl"

        $applicationRegistrationClientId = $($dataObj.authorization.parameters.serviceprincipalid)
        Write-Host "App Registration Client Id   : $applicationRegistrationClientId"

        $tenantId = $($dataObj.authorization.parameters.tenantid)
        Write-Host "Tenant ID                    : $tenantId"
        Write-Host "Current AAD Tenant is        : $currentTenantId"
        Write-Host "Service Connection Tenant    : $tenantId"
        $tenantsMatch = $tenantId -eq $currentTenantId
        Write-Host "Tenants Match                : $tenantsMatch"
        if ($tenantsMatch) {
            $altAppObjId = $htAppRegistrationsByAppClientId[$applicationRegistrationClientId].id
            if ($lineContainsArmServiceConnection) {
                if ($appObjId -eq $altAppObjId) {
                    Write-Host "App Object ID is as expected : $altAppObjId"
                }
                else {
                    throw "App object id should have matched!"
                }
            }
            else {
                $appObjId = $altAppObjId
                Write-Host "Setting app object id to     : $appObjId"
            }
        }
        $scope = $($dataObj.authorization.parameters.scope)
        Write-Host "Scope                        : $scope"

        $appRegistrationFoundByAppClientId = $htAppRegistrationsByAppClientId[$applicationRegistrationClientId]
        $appIdAppReg = $appRegistrationFoundByAppClientId.appId
        if ($appIdAppReg) {
            Write-Host "App id is non-empty."
        }
        else {
            if ($tenantsMatch) {
                throw "Should NOT have an empty app id!"
            }
            else {
                Write-Warning "Empty app id is expected when tenants do not match."
            }
        }

        $itemToAdd = "$serviceConnectionUrl"
        $htAppRegistrationServiceConnectionsByAppClientId[$applicationRegistrationClientId] += , $itemToAdd

        $totalNumberOfItems = $htAppRegistrationServiceConnectionsByAppClientId[$applicationRegistrationClientId].Length

        if ($totalNumberOfItems -gt 0) {
            Write-Host "Total Number Of Referenced Service Connections : $totalNumberOfItems"
            foreach ($item in $htAppRegistrationServiceConnectionsByAppClientId[$applicationRegistrationClientId]) {
                Write-Host "`t$item"
                $totalNumberOfReferencedServiceConnectionIterations++
                Add-Content -Value "$item,$applicationRegistrationClientId" -Path $bookkeepingCsvPath
            }
        }

        $prettyJson = $dataJson | ConvertFrom-Json | ConvertTo-Json -Depth $jsonDepth
        
        $appRegistrationFoundByAppClientIdJson = $appRegistrationFoundByAppClientId | ConvertTo-Json -Depth $jsonDepth

        if ($lineContainsArmServiceConnection) {
            Set-Content -Value $prettyJson -Path $sampleDataJsonPath
            Update-Guid -filename $sampleDataJsonPath
            Set-Content -Value $appRegistrationFoundByAppClientIdJson -Path $sampleArmConnectionJsonPath
            Update-Guid -filename $sampleArmConnectionJsonPath
        }
        else {
            Set-Content -Value $prettyJson -Path $sampleDataCreatedManuallyJsonPath
            Update-Guid -filename $sampleDataCreatedManuallyJsonPath
            Set-Content -Value $appRegistrationFoundByAppClientIdJson -Path $sampleArmConnectionCreatedManuallyJsonPath
            Update-Guid -filename $sampleArmConnectionCreatedManuallyJsonPath
        }

        $subscriptionId = $($dataObj.data.subscriptionId)
        Write-Host "Tied to subscription         : $subscriptionId"
        $currentDisplayName = $appRegistrationFoundByAppClientId.displayName
        Write-Host "Current Display Name         : $currentDisplayName"
        # Get New App Registration and Service Principal Display Name
        $newDisplayName = Rename-AppRegistration $organizationName $projectName $subscriptionId $serviceConnectionName $endpointId $htAppRegistrationServiceConnectionsByAppClientId[$applicationRegistrationClientId]
        $numberOfAppRegistrationsProcessed++
        # Get New Internal Notes
        # CAREFUL: an app registration may be associated to MORE THAN ONE service connection
        $currentNotes = $appRegistrationFoundByAppClientId.notes
        Write-Host "Current Internal Notes       :`n---`n$currentNotes`n---"
        $newNotes = New-InternalNotes $htAppRegistrationServiceConnectionsByAppClientId[$applicationRegistrationClientId]
        $updateDisplayName = $currentDisplayName -ne $newDisplayName
        $updateInternalNotes = $currentNotes -ne $newNotes
        $updateAppRegistration = $updateDisplayName -or $updateInternalNotes
        $maxServiceConnectionsExpected = $htAppRegistrationServiceConnectionsByAppClientIdPrePopulated[$applicationRegistrationClientId].Length
        $actualNumberOfServiceConnections = $htAppRegistrationServiceConnectionsByAppClientId[$applicationRegistrationClientId].Length
        $expectedNumberOfServiceConnectionsReached = $maxServiceConnectionsExpected -eq $actualNumberOfServiceConnections
        Write-Host "Currently have $actualNumberOfServiceConnections referenced service connection(s) from a total of $maxServiceConnectionsExpected."
        if ($updateAppRegistration -and $tenantsMatch -and $expectedNumberOfServiceConnectionsReached) {
            if (-not $isProductionRun) {
                if ($updateDisplayName) {
                    Write-Warning "Dry-Run: Renaming to $newDisplayName"
                    Write-Host "az ad app update --id $appIdAppReg --display-name `"$newDisplayName`""
                }
                if ($updateInternalNotes) {
                    Write-Warning "Dry-Run: Updating internal notes to:`n$newNotes"
                    # There is no CLI support for some properties, so we have to patch manually via az rest
                    $appPatchUri = "https://graph.microsoft.com/v1.0/applications/{0}" -f $appObjId
                    $appPatchBody = New-PatchBody $htAppRegistrationServiceConnectionsByAppClientId[$applicationRegistrationClientId]
                    Write-Host "az rest --method PATCH --uri $appPatchUri --headers 'Content-Type=application/json' --body $appPatchBody --output none"
                }

                $numberOfAppRegistrationsUpdated++
            }
            else {
                if ($appIdAppReg) {
                    try {
                        if ($updateDisplayName) {
                            Write-Warning "Production-Run: Renaming to $newDisplayName"
                            Write-Host "az ad app update --id $appIdAppReg --display-name `"$newDisplayName`""
                            az ad app update --id $appIdAppReg --display-name `"$newDisplayName`"
                        }
                        if ($updateInternalNotes) {
                            Write-Warning "Production-Run: Updating internal notes to:`n$newNotes"
                            # There is no CLI support for some properties, so we have to patch manually via az rest
                            $appPatchUri = "https://graph.microsoft.com/v1.0/applications/{0}" -f $appObjId
                            $appPatchBody = New-PatchBody $htAppRegistrationServiceConnectionsByAppClientId[$applicationRegistrationClientId]
                            Write-Host "az rest --method PATCH --uri $appPatchUri --headers 'Content-Type=application/json' --body $appPatchBody --output none"
                            az rest --method PATCH --uri $appPatchUri --headers 'Content-Type=application/json' --body $appPatchBody --output none
                        }

                        $numberOfAppRegistrationsUpdated++
                    }
                    catch {
                        Write-Error $Error[0]
                        if (-not $skipPauseAfterError) {
                            Write-Host $prettyJson
                            Write-Host -NoNewLine 'Press any key to continue...';
                            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
                            Write-Host
                        }
                        $numberOfAppRegistrationsWithAnIssueUpdating++
                    }
                }
                else {
                    throw "should NOT be here - as app id cannot be empty"
                }
            }
        }
        else {
            # Either there's nothing to update OR tenants don't match OR there are still some referenced service connections to process.
            if (-not $updateAppRegistration) {
                Write-Host "Update skipped. Nothing to update..."
                $numberOfAppRegistrationsSkippedDueToNoUpdateRequired++
            }
            elseif (-not $tenantsMatch) {
                Write-Host "Update skipped. Tenants do not match..."
                $numberOfAppRegistrationsSkippedDueToTenantMismatch++
            }
            else {
                Write-Host "Update skipped. Max no of referenced Service Connections not yet reached..."
                Write-Host "maxServiceConnectionsExpected: $maxServiceConnectionsExpected VS actualNumberOfServiceConnections: $actualNumberOfServiceConnections"
                $numberOfAppRegistrationsSkippedDueToMaxNoOfRefServiceConnectionsNotYetReached++

                # Write-Host -NoNewLine 'Press any key to continue...';
                # $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
                # Write-Host
            }
        }

        # Just a bunch of extra sanity checks
        if ($doExtraSanityChecks) {
            if ($lineContainsArmServiceConnection) {
                Write-Host "Found a svc principal obj id : $spObjId"
                $servicePrincipalFound = $htServicePrincipals[$spObjId]
                $appIdSvcPrin = $servicePrincipalFound.appId
                Write-Host "With app object id           : $appObjId"
                $appRegistrationFoundByAppObjId = $htAppRegistrationsByAppObjId[$appObjId]
                # sanity check
                if ($appRegistrationFoundByAppObjId.id -eq $appRegistrationFoundByAppClientId.id) {
                    "Sanity check passed."
                }
                else {
                    throw "Sanity check failed!"
                }            
                if ($appIdSvcPrin -eq $appIdAppReg) {
                    Write-Host "App id                       : $appIdAppReg"
                    if ($appIdAppReg) {
                        if ($appIdAppReg -eq $applicationRegistrationClientId) {
                            "As expected!"
                        }
                        else {
                            throw "Did NOT get expected app id of $applicationRegistrationClientId !"
                        }
                    }
                    else {
                        if ($tenantsMatch) {
                            throw "Should not happen!"
                        }
                        else {
                            Write-Warning "Tenants do NOT match and that is why we did not find the app registration."
                        }
                    }
                }
                else {
                    throw "Mismatch of app id!"
                }            
            }
            else {
                Write-Host "Neither appObjectId nor spnObjectId found! In other words, lineContainsArmServiceConnection has value: $lineContainsArmServiceConnection."
                if ($lineContainsArmServiceConnection) {
                    throw "A service connection that has neither appObjectId nor spnObjectId should have given a FALSE value above."
                }
                if ($creationMode -eq 'Manual') {
                    Write-Host "Manually created ARM service connection have neither appObjectId nor spnObjectId."
                }
                else {
                    throw "An automatically created ARM service connection should have BOTH an appObjectId and spnObjectId."
                }
            }
        }
        Write-Host "-----------------------"
    }

    $htAppRegistrationServiceConnectionsByAppClientIdJson = $htAppRegistrationServiceConnectionsByAppClientId | ConvertTo-Json
    Set-Content -Value $htAppRegistrationServiceConnectionsByAppClientIdJson -Path $appRegToRefSvcConnJsonPath

    Write-Host

    if (-not $isProductionRun) {
        Write-Host "Dry run... NOTHING was changed"
    }
    else {
        #list orphans before summary
        Write-Host "Fetching all app registrations from Azure AD..."
        $appRegistrationsJson = az ad app list --all
        $appRegistrations = $appRegistrationsJson | ConvertFrom-Json -Depth 100
        Write-Host "There is a total of $($appRegistrations.Length) app registrations."
        Write-Host "Filtering for app registrations that Is Probable Arm Connection..."
        $defaultHomePageUrlForArmConnection = "https://VisualStudio/SPN"
        $appRegistrationsThatIsProbableArmConnection = $appRegistrations | Where-Object { $_.web.homePageUrl -eq $defaultHomePageUrlForArmConnection }
        Write-Host "There is a total of $($appRegistrationsThatIsProbableArmConnection.Length) app registrations that are Probable Arm Connections."
        $appRegistrationsThatIsOrphan = $appRegistrations | Where-Object { ($_.web.homePageUrl -eq $defaultHomePageUrlForArmConnection) -and -not $_.notes }
        Write-Host "There is a total of $($appRegistrationsThatIsOrphan.Length) orphaned app registrations."
        Write-Host "Here are all orphaned app registrations:"
        $appRegistrationsThatIsOrphan | Sort-Object -Property DisplayName | Select-Object -Property DisplayName, AppId | Format-Table -AutoSize
        $appRegistrationsThatIsOrphan | Sort-Object -Property DisplayName | Select-Object -Property DisplayName, AppId | Format-Table -AutoSize | Out-File -FilePath $orphansPath

        #now for summary
        Write-Host "SUMMARY of Production Run"
    }

    Write-Host
    Write-Host "App Registrations Updated                                                : $numberOfAppRegistrationsUpdated"
    Write-Host "App Registrations Skipped Due To No Update Required                      : $numberOfAppRegistrationsSkippedDueToNoUpdateRequired"
    Write-Host "App Registrations Skipped Due To Tenant Mismatch                         : $numberOfAppRegistrationsSkippedDueToTenantMismatch"
    Write-Host "App Registrations Skipped Due To Max No Of Ref Svc Conns Not Yet Reached : $numberOfAppRegistrationsSkippedDueToMaxNoOfRefServiceConnectionsNotYetReached"
    Write-Host "App Registrations With An Issue Updating                                 : $numberOfAppRegistrationsWithAnIssueUpdating"
    Write-Host "App Registrations Processed                                              : $numberOfAppRegistrationsProcessed"
    Write-Host
    Write-Host "App Registrations That Is Probable Arm Connection With Expired Password Credentials : $totalNumberOfAppRegistrationsThatIsProbableArmConnectionWithExpiredPasswordCredentials"
    Write-Host "App Registrations That Is Probable Arm Connection And Orphaned                      : $($appRegistrationsThatIsOrphan.Length)"
    Write-Host "App Registrations That Is Probable Arm Connection                                   : $totalNumberOfAppRegistrationsThatIsProbableArmConnection"
    Write-Host
    Write-Host "App Registrations With Expired Password Credentials : $totalNumberOfAppRegistrationsWithExpiredPasswordCredentials"
    Write-Host "Total Number Of App Registrations                   : $totalNumberOfAppRegistrations"
    Write-Host
    Write-Host "ARM service connections created automatically  : $numberOfArmServiceConnectionsCreatedAutomatically"
    Write-Host "ARM service connections created manually       : $numberOfArmServiceConnectionsCreatedManually"
    Write-Host "Total Number of ARM Service Connections        : $totalNumberOfArmServiceConnections"
    Write-Host
    Write-Host "Total Number of Referenced Service Connection Iterations : $totalNumberOfReferencedServiceConnectionIterations"
    Write-Host
    Write-Host "Number of entries in htServicePrincipals                              : $($htServicePrincipals.Count)"
    Write-Host "Number of entries in htAppRegistrationsByAppObjId                     : $($htAppRegistrationsByAppObjId.Count)"
    Write-Host "Number of entries in htAppRegistrationsByAppClientId                  : $($htAppRegistrationsByAppClientId.Count)"
    Write-Host "Number of entries in htAppRegistrationServiceConnectionsByAppClientId : $($htAppRegistrationServiceConnectionsByAppClientId.Count)"
}
else {
    Write-Error "Unable to export service connections"
}

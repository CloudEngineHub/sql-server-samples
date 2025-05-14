﻿param (
    [Parameter (Mandatory= $false)]
    [string] $SubId,
    [Parameter (Mandatory= $false)]
    [PSCredential] $Cred,
    [Parameter (Mandatory= $false)]
    [string] $FilePath
)

function CheckModule ($m) {

    # This function ensures that the specified module is imported into the session
    # If module is already imported - do nothing

    if (!(Get-Module | Where-Object {$_.Name -eq $m})) {
         # If module is not imported, but available on disk then import
        if (Get-Module -ListAvailable | Where-Object {$_.Name -eq $m}) {
            Import-Module $m
        }
        else {

            # If module is not imported, not available on disk, but is in online gallery then install and import
            if (Find-Module -Name $m | Where-Object {$_.Name -eq $m}) {
                Install-Module -Name $m -Force -Verbose -Scope CurrentUser
                Import-Module $m
            }
            else {

                # If module is not imported, not available and not in online gallery then abort
                write-host "Module $m not imported, not available and not in online gallery, exiting."
                EXIT 1
            }
        }
    }
}

#
# Suppress warnings
#
Update-AzConfig -DisplayBreakingChangeWarning $false

$requiredModules = @(
    "Az.Accounts",
    "Az.Compute",
    "Az.DataFactory",
    "Az.Resources",
    "Az.Sql",
    "Az.SqlVirtualMachine"
)
$requiredModules | Foreach-Object {CheckModule $_}

# Subscriptions to scan

if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId
}elseif($SubId -ne $null){
    $subscriptions = [PSCustomObject]@{SubscriptionId = $SubId} | Get-AzSubscription
}else{
    $subscriptions = Get-AzSubscription
}

#Log file setup
if (!$PSBoundParameters.ContainsKey("FilePath")) {
    $FilePath = '.\sql-change-log.csv'
}

Write-Host ([Environment]::NewLine + "-- Scanning subscriptions --")

# Record the start time
$startTime = Get-Date
Write-Host ("Script execution started at: $startTime")

# Calculate usage for each subscription

foreach ($sub in $subscriptions){

    if ($sub.State -ne "Enabled") {continue}

    try {
        Set-AzContext -SubscriptionId $sub.Id
    }catch {
        write-host "Invalid subscription: " $sub.Id
        continue
    }

    # Get all resource groups in the subscription
    $rgs = Get-AzResourceGroup

    # Get all logical servers
    $servers = Get-AzSqlServer

    # Scan all vCore-based SQL database resources in the subscription
    $servers | Get-AzSqlDatabase | Where-Object { $_.SkuName -ne "ElasticPool" -and $_.Edition -in @("GeneralPurpose", "BusinessCritical", "Hyperscale") } | ForEach-Object {
        if ($_.LicenseType -ne "LicenseIncluded") {
            Set-AzSqlDatabase -ResourceGroupName $_.ResourceGroupName -ServerName $_.ServerName -DatabaseName $_.DatabaseName -LicenseType "LicenseIncluded"
            Write-Host ([Environment]::NewLine + "-- Database $_.DatabaseName is set to \"LicenseIncluded\"")
        }
    }
    [system.gc]::Collect()

    # Scan all vCore-based SQL elastic pool resources in the subscription
    $servers | Get-AzSqlElasticPool | Where-Object { $_.Edition -in @("GeneralPurpose", "BusinessCritical", "Hyperscale") } | ForEach-Object {
        if ($_.LicenseType -ne "LicenseIncluded") {
            Set-AzSqlElasticPool -ResourceGroupName $_.ResourceGroupName -ServerName $_.ServerName -ElasticPoolName $_.ElasticPoolName -LicenseType "LicenseIncluded"
            Write-Host ([Environment]::NewLine + "-- ElasticPool $_.ElasticPoolName is set to \"LicenseIncluded\"")
        }
    } 
    [system.gc]::Collect()

    # Scan all SQL managed instance resources in the subscription
    Get-AzSqlInstance | Where-Object { $_.InstancePoolName -eq $null } | ForEach-Object {
        if ($_.LicenseType -ne "LicenseIncluded") {
            Set-AzSqlInstance -ResourceGroupName $_.ResourceGroupName -ServerName $_.ServerName -InstanceName $_.InstanceName -LicenseType "LicenseIncluded"
            Write-Host ([Environment]::NewLine + "-- Instance $_.InstanceName is set to \"LicenseIncluded\"")
        }      
    }
    [system.gc]::Collect()

    # Scan all instance pool resources in the subscription
    Get-AzSqlInstancePool | Foreach-Object {
        if ($_.LicenseType -ne "LicenseIncluded") {
            Set-AzSqlInstancePool -ResourceGroupName $_.ResourceGroupName -ServerName $_.ServerName -InstanceName $_.InstanceName -LicenseType "LicenseIncluded"
            Write-Host ([Environment]::NewLine + "-- InstancePool $_.InstanceName is set to \"LicenseIncluded\"")
        }
    }
    [system.gc]::Collect()

    # Scan all SSIS integration runtime resources in the subscription
    $rgs | Get-AzDataFactoryV2 | Get-AzDataFactoryV2IntegrationRuntime | Where-Object { $_.State -eq "Started" -and $_.NodeSize -ne $null } | ForEach-Object {
        if ($_.LicenseType -ne "LicenseIncluded") {
            # Set the license type to "LicenseIncluded"
            Set-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName -Name $_.Name -LicenseType "LicenseIncluded"
            Write-Host ([Environment]::NewLine + "-- DataFactory $_.DataFactoryName is set to \"LicenseIncluded\"")
        }
    }
    [system.gc]::Collect()

    # Scan all SQL VMs in the subscription
    $rgs | Get-AzVM | Where-Object { $_.StorageProfile.ImageReference.Offer -like "*sql*" -and $_.ProvisioningState -eq "Succeeded" } | ForEach-Object {
        $vmName = $_.Name
        $resourceGroupName = $_.ResourceGroupName
    
        # Get the SQL configuration for the VM
        $sqlConfig = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "SqlIaaSAgent"
        
        if ($sqlConfig -ne $null) {
            $licenseType = $sqlConfig.Settings.LicenseType
    
            if ($licenseType -ne "LicenseIncluded") {
                # Set the license type to "LicenseIncluded"
                Set-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "SqlIaaSAgent" -Publisher "Microsoft.SqlServer.Management" -ExtensionType "SqlIaaSAgent" -TypeHandlerVersion "1.5" -Settings @{ "LicenseType" = "LicenseIncluded" }
                Write-Host ([Environment]::NewLine + "-- SQL VM $vmName is set to \"LicenseIncluded\"")
            }
    
        }
    }
    [system.gc]::Collect()

}

# Record the end time
$endTime = Get-Date
Write-Host ("Script execution ended at: $endTime")

# Calculate the duration of script execution
$executionDuration = $endTime - $startTime
Write-Host ("Script execution duration: $executionDuration")

Write-Host ([Environment]::NewLine + "-- Script execution completed --")

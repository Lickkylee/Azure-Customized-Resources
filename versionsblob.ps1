# ====================================================================================
# Azure Storage Blob calculator:
# Base Blobs, Blob Snapshots, Versions, Deleted / not Deleted, by Container, by tier, with prefix and considering Last Modified Date
# ====================================================================================
# This PowerShell script will count and calculate blob usage on each container, or in some specific container in the provided Storage account
# Filters can be used based on  
#     All containers or some specific Container
#     Base Blobs, Blob Snapshots, Versions, All
#     Hot, Cool, Archive or All Access Tiers
#     Deleted, Not Deleted or All
#     Filtered by prefix
#     Filtered by Last Modified Date
# This can take some hours to complete, depending of the amount of blobs, versions and snapshots in the container or Storage account.
# $logs container is not covered  by this script (not supported)
# By default, this script List All non Soft Deleted Base Blobs, in All Containers, with All Access Tiers
# ====================================================================================
# DISCLAMER : Please note that this script is to be considered as a sample and is provided as is with no warranties express or implied, even more considering this is about deleting data. 
# You can use or change this script at you own risk.
# ====================================================================================
# PLEASE NOTE :
# - This script does not recover folders on ADLS Gen2 accounts.
# - Just run the script and your AAD credentials and the storage account name to list will be asked.
# - All other values should be defined in the script, under 'Parameters - user defined' section.
# - Uncomment line 180 (line after # DEBUG) to get the full list of all selected objects 
# ====================================================================================
# For any question, please contact Luis Filipe (Msft)
# ====================================================================================
# Corrected:
#  - Null array exception for empty containers
#  - Added capacity unit "Bytes" in the output
#  - Added options to select Tenant and Subscription

# sign in
Write-Host "Logging in...";
Connect-AzAccount -Environment AzureChinaCloud;
$tenantId = Get-AzTenant | Select-Object Id, Name | Out-GridView -Title 'Select your Tenant' -PassThru  -ErrorAction Stop
$subscId = Get-AzSubscription -TenantId $tenantId.Id | Select-Object TenantId, Id, Name | Out-GridView -Title 'Select your Subscription' -PassThru  -ErrorAction Stop

$subscriptionId = $subscId.Id;
if(!$subscriptionId)
{
    Write-Host "----------------------------------";
    Write-Host "No subscription was selected.";
    Write-Host "Exiting...";
    Write-Host "----------------------------------";
    Write-Host " ";
    exit;
}

# select subscription
Write-Host "Selecting subscription '$subscriptionId'";
Set-AzContext -SubscriptionId $subscriptionId;
CLS

#----------------------------------------------------------------------
# Parameters - user defined
#----------------------------------------------------------------------
$selectedStorage = Get-AzStorageAccount  | Out-GridView -Title 'Select your Storage Account' -PassThru  -ErrorAction Stop
$resourceGroupName = $selectedStorage.ResourceGroupName
$storageAccountName = $selectedStorage.StorageAccountName

$containerName = ''             # Container Name, or empty to all containers
$prefix = ''                    # Set prefix for scanning (optional)
    
$deleted = 'All'              # valid values: 'True' / 'False' / 'All' 
$blobType = 'Versions'              # valid values: 'Base' / 'Snapshots' / 'Versions' / 'Versions+Snapshots' / 'All Types'
$accessTier = 'All'             # valid values: 'Hot', 'Cool', 'Archive', 'All'

# Select blobs before Last Modified Date (optional) - if all three empty, current date will be used
$Year = ''
$Month = ''
$Day = ''
#----------------------------------------------------------------------
if($storageAccountName -eq $Null) { break }


#----------------------------------------------------------------------
# Date format
#----------------------------------------------------------------------
if ($Year -ne '' -and $Month -ne '' -and $Day -ne '')
{
    $maxdate = Get-Date -Year $Year -Month $Month -Day $Day -ErrorAction Stop
} else {
    $maxdate = Get-Date
}
#----------------------------------------------------------------------



#----------------------------------------------------------------------
# Format String Details in user friendy format
#----------------------------------------------------------------------
switch($blobType) 
{
    'Base'               {$strBlobType = 'Base Blobs'}
    'Snapshots'          {$strBlobType = 'Snapshots'}
    'Versions+Snapshots' {$strBlobType = 'Versions & Snapshots'}
    'Versions'           {$strBlobType = 'Blob Versions only'}
    'All Types'          {$strBlobType = 'All blobs (Base Blobs + Versions + Snapshots)'}
}
switch($deleted) 
{
    'True'               {$strDeleted = 'Only Deleted'}
    'False'              {$strDeleted = 'Active (not deleted)'}
    'All'                {$strDeleted = 'All (Active+Deleted)'}
}
if ($containerName -eq '') {$strContainerName = 'All Containers (except $logs)'} else {$strContainerName = $containerName}
#----------------------------------------------------------------------



#----------------------------------------------------------------------
# Show summary of the selected options
#----------------------------------------------------------------------
function ShowDetails ($storageAccountName, $strContainerName, $prefix, $strBlobType, $accessTier, $strDeleted, $maxdate)
{
    # CLS

    write-host " "
    write-host "-----------------------------------"
    write-host "Listing Storage usage per Container"
    write-host "-----------------------------------"

    write-host "Storage account: $storageAccountName"
    write-host "Container: $strContainerName"
    write-host "Prefix: '$prefix'"
    write-host "Blob Type: $strDeleted $strBlobType"
    write-host "Blob Tier: $accessTier"
    write-host "Last Modified Date before: $maxdate"
    write-host "-----------------------------------"
}
#----------------------------------------------------------------------



#----------------------------------------------------------------------
#  Filter and count blobs in some specific Container
#----------------------------------------------------------------------
function ContainerList ($containerName, $ctx, $prefix, $blobType, $accessTier, $deleted, $maxdate)
{

    $count = 0
    $capacity = 0

    $blob_Token = $Null
    $exception = $Null 

    write-host -NoNewline "Processing $containerName...   "

    do
    { 

        # all Blobs, Snapshots
        $listOfAllBlobs = Get-AzStorageBlob -Container $containerName -IncludeDeleted -IncludeVersion -Context $ctx  -ContinuationToken $blob_Token -Prefix $prefix -MaxCount 5000 -ErrorAction Stop
        if($listOfAllBlobs.Count -le 0) {
            write-host "No Objects found to list"
            break
        }
     
        #------------------------------------------
        # Filtering blobs by type
        #------------------------------------------
        switch($blobType) 
        {
            'Base'               {$listOfBlobs = $listOfAllBlobs | Where-Object { $_.IsLatestVersion -eq $true -or ($_.SnapshotTime -eq $null -and $_.VersionId -eq $null) } }   # Base Blobs - Base versions may have versionId
            'Snapshots'          {$listOfBlobs = $listOfAllBlobs | Where-Object { $_.SnapshotTime -ne $null } }                                                                  # Snapshots
            'Versions+Snapshots' {$listOfBlobs = $listOfAllBlobs | Where-Object { $_.IsLatestVersion -ne $true -and (($_.SnapshotTime -eq $null -and $_.VersionId -ne $null) -or $_.SnapshotTime -ne $null) } }  # Versions & Snapshotsk
            'Versions'           {$listOfBlobs = $listOfAllBlobs | Where-Object { $_.IsLatestVersion -ne $true -and $_.SnapshotTime -eq $null -and $_.VersionId -ne $null} }     # Versions only 
            'All Types'          {$listOfBlobs = $listOfAllBlobs } # All - Base Blobs + Versions + Snapshots
        }


        #------------------------------------------
        # filter by Deleted / not Deleted / all
        #------------------------------------------
        switch($deleted) 
        {
            'True'               {$listOfBlobs = $listOfBlobs | Where-Object { ($_.IsDeleted -eq $true)} }   # Deleted
            'False'              {$listOfBlobs = $listOfBlobs | Where-Object { ($_.IsDeleted -eq $false)} }  # Not Deleted
            # 'All'              # All Deleted + Not Deleted
        }
  
        # filter by Last Modified Date
        $listOfBlobs = $listOfBlobs | Where-Object { ($_.LastModified -le $maxdate)}   # <= Last Modified Date


        #Filter by Access Tier
        if($accessTier -ne 'All') 
           {$listOfBlobs = $listOfBlobs | Where-Object { ($_.accesstier -eq $accessTier)} }
        


        #------------------------------------------
        # Count and used Capacity
        # Count includes folder/subfolders on ADLS Gen2 Storage accounts
        #------------------------------------------
        foreach($blob in $listOfBlobs)
        {
            # DEBUG - Uncomment next line to have a full list of selected objects
            # write-host $blob.Name " Content-length:" $blob.Length " Access Tier:" $blob.accesstier " LastModified:" $blob.LastModified  " SnapshotTime:" $blob.SnapshotTime " URI:" $blob.ICloudBlob.Uri.AbsolutePath  " IslatestVersion:" $blob.IsLatestVersion  " Lease State:" $blob.ICloudBlob.Properties.LeaseState  " Version ID:" $blob.VersionID

            $count++
            $capacity = $capacity + $blob.Length
        }

        $blob_Token = $listOfAllBlobs[$listOfAllBlobs.Count -1].ContinuationToken;
        

    }while ($blob_Token -ne $Null)   

    write-host "  Count: $count    Capacity: $capacity Bytes"
    

    return $count, $capacity
}
#----------------------------------------------------------------------

$totalCount = 0
$totalCapacity = 0

# $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop
$ctx = (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -StorageAccount $storageAccountName).Context

ShowDetails $storageAccountName $strContainerName $prefix $strBlobType $accessTier $strDeleted $maxdate


$arr = "Container", "Count", "Used capacity"   
$arr = $arr + "-------------", "-------------", "-------------"   


$container_Token = $Null


#----------------------------------------------------------------------
# Looping Containers
#----------------------------------------------------------------------
do {
    
    $containers = Get-AzStorageContainer -Context $Ctx -Name $containerName -ContinuationToken $container_Token -MaxCount 5000 -ErrorAction Stop
        
        
    if ($containers -ne $null)
    {
        $container_Token = $containers[$containers.Count - 1].ContinuationToken

        for ([int] $c = 0; $c -lt $containers.Count; $c++)
        {
            $container = $containers[$c].Name

            $count, $capacity, $exception =  ContainerList $container $ctx $prefix $blobType $accessTier $deleted $maxdate 
            $arr = $arr + ($container, $count, $capacity)

            $totalCount = $totalCount +$count
            $totalCapacity = $totalCapacity + $capacity
        }
    }

} while ($container_Token -ne $null)

write-host "-----------------------------------"
#----------------------------------------------------------------------


#----------------------------------------------------------------------
# Show details in user friendly format and Totals
#----------------------------------------------------------------------
for ($i=0; $i -lt 15; $i++) { write-host " " }
ShowDetails $storageAccountName $strContainerName $prefix $strBlobType $accessTier $strDeleted $maxdate
$arr | Format-Wide -Property {$_} -Column 3 -Force

write-host "-----------------------------------"
write-host "Total Count: $totalCount"
write-host "Total Capacity: $totalCapacity Bytes"
write-host "-----------------------------------"
#----------------------------------------------------------------------
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

# Create a file in temp folder to save data
$tempPath = [System.IO.Path]::GetTempPath()
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$fileName = "BlobInfo_$timestamp.txt"
$filePath = Join-Path -Path $tempPath -ChildPath $fileName
New-Item -Path $filePath -ItemType File -Force
Write-Host "Create Temp file to store data: $filePath"
"Container,TotalCount,Totalcapacity,BaseCount,BaseCapacity,SnapshotsCount,SnapshotsCapacity,VersionsCount,VersionsCapacity,DeletedCount,DeletedCapacity,HotCount,HotCapacity,CoolCount,CoolCapacity,ColdCount,ColdCapacity,ColdCapacity,ArchiveCapacity,BlockCount,BlockCapacity,PageCount,PageCapacity,AppendCount,AppendCapacity" | out-file $filePath 

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

#----------------------------------------------------------------------
if($storageAccountName -eq $Null) { break }

#----------------------------------------------------------------------
# Format String Details in user friendy format
#----------------------------------------------------------------------
if ($containerName -eq '') {$strContainerName = 'All Containers (except $logs)'} else {$strContainerName = $containerName}
#----------------------------------------------------------------------


#----------------------------------------------------------------------
# Show summary of the selected options
#----------------------------------------------------------------------
function ShowDetails ($storageAccountName, $strContainerName)
{
    # CLS

    write-host " "
    write-host "-----------------------------------"
    write-host "Listing Storage usage per Container"
    write-host "-----------------------------------"

    write-host "Storage account: $storageAccountName"
    write-host "Container: $strContainerName"
    write-host "-----------------------------------"
}
#----------------------------------------------------------------------



#----------------------------------------------------------------------
#  Filter and count blobs in some specific Container
#----------------------------------------------------------------------
function ContainerList ($containerName, $ctx)
{
    ## blob type
    $Count = 0
    $Capacity = 0 
    $BaseCount = 0
    $BaseCapacity = 0
    $SnapshotsCount = 0
    $SnapshotsCapacity = 0
    $VersionsCount = 0
    $VersionsCapacity = 0
    $DeletedCount = 0
    $DeletedCapacity = 0

    ## blob tier
    $HotCount = 0
    $HotCapacity = 0
    $CoolCount = 0
    $CoolCapacity = 0
    $ColdCount = 0 
    $ColdCapacity = 0
    $ArchiveCount = 0
    $ArchiveCapacity = 0 


     ## blob Type
    $BlockCount = 0
    $BlockCapacity = 0
    $PageCount = 0
    $PageCapacity = 0
    $AppendCount = 0 
    $AppendCapacity = 0
   
    $blob_Token = $Null
    $exception = $Null 

    write-host  "Processing $containerName...   "

    do
    { 

        # all Blobs, Snapshots
        $listOfAllBlobs = Get-AzStorageBlob -Container $containerName -IncludeDeleted -IncludeVersion -Context $ctx  -ContinuationToken $blob_Token -Prefix $prefix -MaxCount 5000 -ErrorAction Stop
        if($listOfAllBlobs.Count -le 0) {
            write-host "No Objects found to list"
            break
        }

        $Base = $listOfAllBlobs | Where-Object { ($_.IsLatestVersion -eq $true -or ($_.SnapshotTime -eq $null -and $_.VersionId -eq $null)) -and $_.IsDeleted -ne $true } 
        $Snapshots = $listOfAllBlobs | Where-Object { $_.SnapshotTime -ne $null -and $_.IsDeleted -ne $true} 
        $Versions = $listOfAllBlobs | Where-Object { $_.IsLatestVersion -ne $true -and $_.SnapshotTime -eq $null -and $_.VersionId -ne $null  -and $_.IsDeleted -ne $true}
        $Deleted = $listOfAllBlobs | Where-Object { $_.IsDeleted -eq $true}
     
        foreach($blob in $Base)
        {
            # DEBUG - Uncomment next line to have a full list of selected objects
            # write-host $blob.Name " Content-length:" $blob.Length " Access Tier:" $blob.accesstier " LastModified:" $blob.LastModified  " SnapshotTime:" $blob.SnapshotTime " URI:" $blob.ICloudBlob.Uri.AbsolutePath  " IslatestVersion:" $blob.IsLatestVersion  " Lease State:" $blob.ICloudBlob.Properties.LeaseState  " Version ID:" $blob.VersionID

            $BaseCount++
            $BaseCapacity = $BaseCapacity + $blob.Length
            if ($blob.accessTier -eq 'Hot')
            {
                $HotCount++
                $HotCapacity = $HotCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Cool')
            {
                $CoolCount++
                $CoolCapacity = $CoolCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Cold')
            {
                $ColdCount++
                $ColdCapacity = $ColdCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Archive')
            {
                $ArchiveCount++
                $ArchiveCapacity = $ArchiveCapacity + $blob.Length
            }

            if ($blob.BlobType -eq 'BlockBlob')
            {
                $BlockCount++
                $BlockCapacity = $BlockCapacity + $blob.Length
            }
            elseif ($blob.BlobType -eq 'PageBlob')
            {
                $PageCount++
                $PageCapacity = $PageCapacity + $blob.Length
            }
            elseif ($blob.BlobType -eq 'AppendBlob')
            {
                $AppendCount++
                $AppendCapacity = $ApppendCapacity + $blob.Length
            }

        }

        foreach($blob in $Snapshots)
        {
            # DEBUG - Uncomment next line to have a full list of selected objects
            # write-host $blob.Name " Content-length:" $blob.Length " Access Tier:" $blob.accesstier " LastModified:" $blob.LastModified  " SnapshotTime:" $blob.SnapshotTime " URI:" $blob.ICloudBlob.Uri.AbsolutePath  " IslatestVersion:" $blob.IsLatestVersion  " Lease State:" $blob.ICloudBlob.Properties.LeaseState  " Version ID:" $blob.VersionID

            $SnapshotsCount++
            $SnapshotsCapacity = $SnapshotsCapacity + $blob.Length
            if ($blob.accessTier -eq 'Hot')
            {
                $HotCount++
                $HotCapacity = $HotCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Cool')
            {
                $CoolCount++
                $CoolCapacity = $CoolCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Cold')
            {
                $ColdCount++
                $ColdCapacity = $ColdCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Archive')
            {
                $ArchiveCount++
                $ArchiveCapacity = $ArchiveCapacity + $blob.Length
            }

            if ($blob.BlobType -eq 'BlockBlob')
            {
                $BlockCount++
                $BlockCapacity = $BlockCapacity + $blob.Length
            }
            elseif ($blob.BlobType -eq 'PageBlob')
            {
                $PageCount++
                $PageCapacity = $PageCapacity + $blob.Length
            }
            elseif ($blob.BlobType -eq 'AppendBlob')
            {
                $AppendCount++
                $AppendCapacity = $ApppendCapacity + $blob.Length
            }
        }

        foreach($blob in $Versions)
        {
            # DEBUG - Uncomment next line to have a full list of selected objects
            # write-host $blob.Name " Content-length:" $blob.Length " Access Tier:" $blob.accesstier " LastModified:" $blob.LastModified  " SnapshotTime:" $blob.SnapshotTime " URI:" $blob.ICloudBlob.Uri.AbsolutePath  " IslatestVersion:" $blob.IsLatestVersion  " Lease State:" $blob.ICloudBlob.Properties.LeaseState  " Version ID:" $blob.VersionID

            $VersionsCount++
            $VersionsCapacity = $VersionsCapacity + $blob.Length
            if ($blob.accessTier -eq 'Hot')
            {
                $HotCount++
                $HotCapacity = $HotCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Cool')
            {
                $CoolCount++
                $CoolCapacity = $CoolCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Cold')
            {
                $ColdCount++
                $ColdCapacity = $ColdCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Archive')
            {
                $ArchiveCount++
                $ArchiveCapacity = $ArchiveCapacity + $blob.Length
            }

            if ($blob.BlobType -eq 'BlockBlob')
            {
                $BlockCount++
                $BlockCapacity = $BlockCapacity + $blob.Length
            }
            elseif ($blob.BlobType -eq 'PageBlob')
            {
                $PageCount++
                $PageCapacity = $PageCapacity + $blob.Length
            }
            elseif ($blob.BlobType -eq 'AppendBlob')
            {
                $AppendCount++
                $AppendCapacity = $ApppendCapacity + $blob.Length
            }

        }

        foreach($blob in $Deleted)
        {
            # DEBUG - Uncomment next line to have a full list of selected objects
            # write-host $blob.Name " Content-length:" $blob.Length " Access Tier:" $blob.accesstier " LastModified:" $blob.LastModified  " SnapshotTime:" $blob.SnapshotTime " URI:" $blob.ICloudBlob.Uri.AbsolutePath  " IslatestVersion:" $blob.IsLatestVersion  " Lease State:" $blob.ICloudBlob.Properties.LeaseState  " Version ID:" $blob.VersionID

            $DeletedCount++
            $DeletedCapacity = $DeletedCapacity + $blob.Length
            if ($blob.accessTier -eq 'Hot')
            {
                $HotCount++
                $HotCapacity = $HotCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Cool')
            {
                $CoolCount++
                $CoolCapacity = $CoolCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Cold')
            {
                $ColdCount++
                $ColdCapacity = $ColdCapacity + $blob.Length
            }
            elseif
             ($blob.accessTier -eq 'Archive')
            {
                $ArchiveCount++
                $ArchiveCapacity = $ArchiveCapacity + $blob.Length
            }

            if ($blob.BlobType -eq 'BlockBlob')
            {
                $BlockCount++
                $BlockCapacity = $BlockCapacity + $blob.Length
            }
            elseif ($blob.BlobType -eq 'PageBlob')
            {
                $PageCount++
                $PageCapacity = $PageCapacity + $blob.Length
            }
            elseif ($blob.BlobType -eq 'AppendBlob')
            {
                $AppendCount++
                $AppendCapacity = $ApppendCapacity + $blob.Length
            }

        }

        $blob_Token = $listOfAllBlobs[$listOfAllBlobs.Count -1].ContinuationToken;
        

    }while ($blob_Token -ne $Null) 

    $count =  $BaseCount + $SnapshotsCount  + $VersionsCount + $DeletedCount
    $capacity = $BaseCapacity + $SnapshotsCapacity + $VersionsCapacity + $DeletedCapacity

    write-output $containerName","$count","$capacity","$BaseCount","$BaseCapacity","$SnapshotsCount","$SnapshotsCapacity","$VersionsCount","$VersionsCapacity","$DeletedCount","$DeletedCapacity","$HotCount","$HotCapacity","$CoolCount","$CoolCapacity","$ColdCount","$ColdCapacity","$ArchiveCount","$ArchiveCapacity","$BlockCount","$BlockCapacity","$PageCount","$PageCapacity","$AppendCount","$AppendCapacity | out-file $filePath -Append
    
    return  $count,$capacity,$BaseCount,$BaseCapacity,$SnapshotsCount,$SnapshotsCapacity,$VersionsCount,$VersionsCapacity,$DeletedCount,$DeletedCapacity,$HotCount,$HotCapacity,$CoolCount,$CoolCapacity,$ColdCount,$ColdCapacity,$ArchiveCount,$ArchiveCapacity,$BlockCount,$BlockCapacity,$PageCount,$PageCapacity,$AppendCount,$AppendCapacity
}

#----------------------------------------------------------------------

$totalCount = 0
$totalCapacity = 0

## blob state
$TotalBaseCount = 0
$TotalBaseCapacity = 0
$TotalSnapshotsCount = 0
$TotalSnapshotsCapacity = 0
$TotalVersionsCount = 0
$TotalVersionsCapacity = 0
$TotalDeletedCount = 0
$TotalDeletedCapacity = 0

## blob tier
$TotalHotCount = 0
$TotalHotCapacity = 0
$TotalCoolCount = 0
$TotalCoolCapacity = 0
$TotalColdCount = 0 
$TotalColdCapacity = 0
$TotalArchiveCount = 0
$TotalArchiveCapacity = 0 

## blob type
$TotalBlockCount = 0
$TotalBlockCapacity = 0
$TotalPageCount = 0
$TotalPageCapacity = 0
$TotalAppendCount = 0 
$TotalAppendCapacity = 0

# $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop
$ctx = (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -StorageAccount $storageAccountName).Context

ShowDetails $storageAccountName $strContainerName


$arr = "Container", "TotalCount", "Totalcapacity" 
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

            $count,$capacity,$BaseCount,$BaseCapacity,$SnapshotsCount,$SnapshotsCapacity,$VersionsCount,$VersionsCapacity,$DeletedCount,$DeletedCapacity,$HotCount,$HotCapacity,$CoolCount,$CoolCapacity,$ColdCount,$ColdCapacity,$ArchiveCount,$ArchiveCapacity,$BlockCount,$BlockCapacity,$PageCount,$PageCapacity,$AppendCount,$AppendCapacity,$exception =  ContainerList $container $ctx 
            $arr = $arr + ($container, $count, $capacity)

            $totalCount = $totalCount +$count
            $totalCapacity = $totalCapacity + $capacity

            ## blob State
            $TotalBaseCount = $TotalBaseCount + $BaseCount
            $TotalBaseCapacity = $TotalBaseCapacity + $BaseCapacity
            $TotalSnapshotsCount = $TotalSnapshotsCount + $SnapshotsCount
            $TotalSnapshotsCapacity = $TotalSnapshotsCapacity + $SnapshotsCapacity
            $TotalVersionsCount = $TotalVersionsCount  + $VersionsCount 
            $TotalVersionsCapacity = $TotalVersionsCapacity + $VersionsCapacity
            $TotalDeletedCount = $TotalDeletedCount + $DeletedCount
            $TotalDeletedCapacity = $TotalDeletedCount + $DeletedCount

            ## blob tier
            $TotalHotCount = $TotalHotCount + $HotCount 
            $TotalHotCapacity = $TotalHotCapacity + $HotCapacity
            $TotalCoolCount = $TotalCoolCount + $CoolCount
            $TotalCoolCapacity = $TotalCoolCapacity + $CoolCapacity
            $TotalColdCount = $TotalColdCount + $ColdCount
            $TotalColdCapacity = $TotalColdCapacity + $ColdCapacity
            $TotalArchiveCount = $TotalArchiveCount + $ArchiveCount
            $TotalArchiveCapacity = $TotalArchiveCapacity + $ArchiveCapacity

              ## blob type
            $TotalBlockCount = $TotalBlockCount + $BlockCount 
            $TotalBlockCapacity = $TotalBlockCapacity + $BlockCapacity
            $TotalPageCount = $TotalPageCount + $PageCount
            $TotalPageCapacity = $TotalPageCapacity + $PageCapacity
            $TotalAppendCount = $TotalAppendCount + $AppendCount
            $TotalAppendCapacity = $TotalAppendCapacity + $AppendCapacity
        }
    }

} while ($container_Token -ne $null)

write-host "-----------------------------------"
#----------------------------------------------------------------------


#----------------------------------------------------------------------
# Show details in user friendly format and Totals
#----------------------------------------------------------------------
for ($i=0; $i -lt 15; $i++) { write-host " " }
ShowDetails $storageAccountName $strContainerName 
$arr | Format-Wide -Property {$_} -Column 3 -Force

$Name="Total_sum"
write-output $Name","$Totalcount","$Totalcapacity","$TotalBaseCount","$TotalBaseCapacity","$TotalSnapshotsCount","$TotalSnapshotsCapacity","$TotalVersionsCount","$TotalVersionsCapacity","$TotalDeletedCount","$TotalDeletedCapacity","$TotalHotCount","$TotalHotCapacity","$TotalCoolCount","$TotalCoolCapacity","$TotalColdCount","$TotalColdCapacity","$TotalArchiveCount","$TotalArchiveCapacity","$TotalBlockCount","$TotalBlockCapacity","$TotalPageCount","$TotalPageCapacity","$TotalAppendCount","$TotalAppendCapacity | out-file $filePath -Append

write-host "-----------------------------------"
write-host "Total Count: $totalCount"
write-host "Total Capacity: $totalCapacity Bytes"
Write-host "File Path: $filepath"
write-host "-----------------------------------"
#----------------------------------------------------------------------
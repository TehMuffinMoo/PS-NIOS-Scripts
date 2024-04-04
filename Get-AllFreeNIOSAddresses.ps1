#### Configure ####
[String]$CSVPath = './AllAddresses.csv'

#######################################################################################################################################

function Get-AllFreeNIOSAddresses {

    [Int]$Count = 0
    [Int]$Limit = 1000
    $Results = @()
    $Network = Get-IBObject -ObjectRef "network?_paging=1&_max_results=$($Limit)&_return_as_object=1"
    $Count += $Network.result.Count
    Write-Host "Queried $($Count) network objects"
    $NetworkResults += $Network.result

    while ($Network.next_page_id -ne $null) {
        $Network = Get-IBObject -ObjectRef "network?_max_results=$($Limit)&_paging=1&_return_as_object=1&_page_id=$($Network.next_page_id)"
        $Count += $Network.result.Count
        Write-Host "Queried $($Count) network objects"
        $NetworkResults += $Network.result
    }

    if ($PSVersionTable.PSVersion -gt [Version]"7.0") {
        $AllAddresses = $NetworkResults | Foreach-Object -ThrottleLimit 10 -Parallel {
            Write-Host "Querying $($_.network)..."
            $Addresses = Get-IBObject -ObjectRef "ipv4address?network=$($_.network)&status=UNUSED&_paging=1&_return_as_object=1&_max_results=$($using:Limit)"
            $Addresses.result
            while ($Addresses.next_page_id -ne $null) {
                $Addresses = Get-IBObject -ObjectRef "ipv4address?network=$($_.network)&status=UNUSED&_paging=1&_return_as_object=1&_page_id=$($Addresses.next_page_id)&_max_results=$($using:Limit)"
                $Addresses.result
            }
        }
    } else {
        $AllAddresses = @()
        foreach ($NetworkResult in $NetworkResults) {
            Write-Host "Querying $($NetworkResult.network)..."
            [Int]$AddressCount = 0
            $AllAddresses += Get-IBObject -ObjectRef "ipv4address?network=$($NetworkResult.network)&status=UNUSED&_paging=1&_return_as_object=1&_max_results=$($Limit)" | Select -ExpandProperty result
            $AddressCount += $AllAddresses.result.Count
            while ($AllAddresses.next_page_id -ne $null) {
                $AllAddresses = Get-IBObject -ObjectRef "ipv4address?network=$($NetworkResult.network)&status=UNUSED&_paging=1&_return_as_object=1&_page_id=$($AddressResults.next_page_id)&_max_results=$($Limit)"
                $AddressCount += $AllAddresses.result.Count
                Write-Host "Queried $($AddressCount) address objects"
                $AllAddresses += $AllAddresses.result
            }
        }
    }

    $AllAddresses | Select ip_address,is_conflict,mac_address,network,network_view,status

}

### Run this script and export results to CSV
Get-AllFreeNIOSAddresses | Export-Csv $($CSVPath) -NoClobber

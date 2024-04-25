function Get-AllNIOSNetworks {
    [Int]$Count = 0
    [Int]$Limit = 1000
    $Results = @()
    $Network = Get-IBObject -ObjectRef "network?_paging=1&_max_results=$($Limit)&_return_as_object=1&_return_fields%2b=options"
    $Count += $Network.result.Count
    Write-Host "Queried $($Count) network objects"
    $NetworkResults += $Network.result
    
    while ($Network.next_page_id -ne $null) {
        $Network = Get-IBObject -ObjectRef "network?_max_results=$($Limit)&_paging=1&_return_as_object=1&_page_id=$($Network.next_page_id)&_return_fields%2b=options"
        $Count += $Network.result.Count
        Write-Host "Queried $($Count) network objects"
        $NetworkResults += $Network.result
    }
    return $NetworkResults
}

function Find-NIOSNetworksWithOldDNS {
    param (
        [System.Object]$Networks,
        $OldIPs
    )
    $NetworksToUpdate = @()
    $NetworksWithDNSDefined = $AllNetworks | Where-Object {'domain-name-servers' -in $_.options.name}
    foreach ($NWDD in $NetworksWithDNSDefined) {
        foreach ($NWDDi in $(($NWDD.options | Where-Object {$_.name -eq 'domain-name-servers'}).value -split ',')) {
            if ($NWDDi -in $($OldIPs)) {
                $NetworksToUpdate += $NWDD
                break
            }
        }
    }
    return $NetworksToUpdate
}

function Set-NIOSNetworksDNS {
    param (
        [PSCustomObject]$Networks,
        $OldIPs,
        $NewIP,
        [Switch]$DryRun
    )
    $Objects = $Networks | ConvertTo-Json -Depth 5 | ConvertFrom-Json -Depth 5
    Write-Host "Objects to Update:"
    $Objects | Select-Object network,network_view,@{name='dns_servers';expr={($_.options | Where-Object {$_.name -eq "domain-name-servers"}).value -join ","}}
    foreach ($NWWOD in $Objects) {
        [String[]]$DNSServers = $null
        $DNSServers = ($NWWOD.options | Where-Object {$_.name -eq 'domain-name-servers'}).value -split ','
        foreach ($DNSServer in $DNSServers) {
            if ($DNSServer -in $OldIPs) {
                $DNSServers = $DNSServers | Where-Object {$_ -ne $DNSServer}
            }
        }
        $DNSServers += $NewIP
        ($NWWOD.options | Where-Object {$_.name -eq 'domain-name-servers'}).value = ($DNSServers -join ',')
    }
    Write-Host "Changes to apply:"
    $Objects | Select-Object network,network_view,@{name='dns_servers';expr={($_.options | Where-Object {$_.name -eq "domain-name-servers"}).value -join ","}}
    if (!($DryRun)) {
        Write-Host "Applying changes to network objects.."
        $Objects | Select-Object -ExcludeProperty network_view | Set-IBObject
    }
}

## Get list of all NIOS Networks
$AllNetworks = Get-AllNIOSNetworks

## "IF Values" - Populate whole list of IPs here
$OldIPs = '10.123.123.10','10.123.123.20'

## Identify list of networks with old DNS server(s)
$NetworksWithOldDNS = Find-NIOSNetworksWithOldDNS $AllNetworks $OldIPs

## Replace Old DNS IPs with New on each network. Remove -DryRun to implement the changes
Set-NIOSNetworksDNS $NetworksWithOldDNS $OldIPs '10.255.255.1' -DryRun
function Migrate-DTC-NIOS-To-BloxOne {
    param (
        [Parameter(Mandatory=$true)]
        $NIOSLBDN,
        [Parameter(Mandatory=$true)]
        $B1DNSView
    )

    $MethodArr = @{
        'round_robin' = 'RoundRobin'
        'ratio' = 'Ratio'
        'global_availability' = 'GlobalAvailability'
        'topology' = 'Topology'
    }

    if (!(Get-B1DNSView $B1DNSView -Strict)) {
        Write-Error "Unable to find DNS View: $($B1DNSView)"
        return $null
    }

    $LBDNToMigrate = Invoke-NIOS -Method GET -Uri "dtc:lbdn?name=$($NIOSLBDN)&_return_fields%2b=auto_consolidated_monitors,disable,health,lb_method,name,patterns,persistence,pools,priority,types,use_ttl"

    $NewPools = @()
    $NewLBDNs = @()
    foreach ($Pool in $LBDNToMigrate.pools) {
        $NIOSPool = Invoke-NIOS -Method GET -Uri "$($Pool.pool)?_return_fields%2b=auto_consolidated_monitors,availability,consolidated_monitors,disable,health,lb_alternate_method,lb_dynamic_ratio_alternate,lb_dynamic_ratio_preferred,lb_preferred_method,name,quorum,servers,use_ttl"
        $NewPool = [PSCustomObject]@{
            "name" = $NIOSPool.name
            "method" = $NIOSPool.lb_preferred_method.ToLower()
            "servers" = @()
        }
        foreach ($Server in $NIOSPool.servers) {
            $NIOSServer = Invoke-NIOS -Method GET -Uri "$($Server.server)?_return_fields%2b=auto_create_host_record,disable,health,host,monitors,name,use_sni_hostname"
            $NewServer = @{
                "weight" = $Server.ratio
                "AutoCreateResponses" = $NIOSServer.auto_create_host_record
                "disable" = $NIOSServer.disable
                "name" = $NIOSServer.name
                "address" = $null
                "fqdn" = $null
            }
            if (Test-ValidIPv4Address($NIOSServer.host)) {
                $NewServer.address = $NIOSServer.host
            } else {
                $NewServer.fqdn = $NIOSServer.host
            }
            $NewPool.servers += $NewServer
        }
        $NewPools += $NewPool
    }

    foreach ($Pattern in $LBDNToMigrate.patterns) {
        $NewLBDNs += [PSCustomObject]@{
            "Name" = $Pattern
            "Description" = $LBDNToMigrate.name
            "DNSView" = $B1DNSView
        }
    }
    
    $NewPolicy = [PSCustomObject]@{
        "Name" = $LBDNToMigrate.name
        "LoadBalancingMethod" = $LBDNToMigrate.lb_method.ToLower()
    }    

    $Results = [PSCustomObject]@{
        "LBDN" = $NewLBDNs
        "Policy" = $NewPolicy
        "Pools" = $NewPools
    }
       
    ## Create DTC Pool(s), Servers(s) & Associations
    $PoolList = @()
    foreach ($MigrationPool in $Results.pools) {
        foreach ($MigrationServer in $MigrationPool.servers) {
            $ServerSplat = @{
                "Name" = $MigrationServer.name
                "State" = $(if ($($MigrationServer.disable)) { "Disabled" } else { "Enabled" })
                "AutoCreateResponses" = $(if ($($MigrationServer.AutoCreateResponses)) { "Disabled" } else { "Enabled" })
            }
            if ($MigrationServer.fqdn) {
                $ServerSplat.FQDN = $MigrationServer.fqdn
            } elseif ($MigrationServer.address)  {
                $ServerSplat.IP = $MigrationServer.address
            }
            New-B1DTCServer @ServerSplat
        }
        $PoolSplat = @{
            "Name" = $MigrationPool.name
            "LoadBalancingType" = $MethodArr[$MigrationPool.method]
            "Servers" = $MigrationPool.servers.name -join ','
        }
        New-B1DTCPool @PoolSplat
        $PoolList += $PoolSplat.Name
    }

    New-B1DTCPolicy -Name $Results.Policy.Name -LoadBalancingType $MethodArr[$Results.Policy.LoadBalancingMethod] -Pools $PoolList

    foreach ($MigrationLBDN in $Results.lbdn) {
        New-B1DTCLBDN -Name $MigrationLBDN.Name -Description $MigrationLBDN.Description -DNSView $MigrationLBDN.DNSView -Policy $Results.Policy.Name
    }

    ## Create the DTC Health Check(s)

    ## Need to populate TTL Values & Topology Rulesets where applicable
}


function Migrate-DTC-NIOS-To-BloxOne {
    <#
    .SYNOPSIS
        Used to build a text or HTML based visual topology of all related child networks

    .DESCRIPTION
        This function is used to build a text or HTML based visual topology of all related child networks, based on a parent IP Space, Address Block, Subnet or Range.

    .PARAMETER B1DNSView
        The DNS View within BloxOne DDI in which to assign the new LBDNs to. The LBDNs will not initialise unless the zone(s) exist within the specified DNS View.

    .PARAMETER NIOSLBDN
        The LBDN Name within NIOS that you would like to migrate to BloxOne DDI
    
    .EXAMPLE
        PS> Migrate-DTC-NIOS-To-BloxOne -B1DNSView 'my-dnsview' -NIOSLBDN 'some-lbdn' -ApplyChanges

    .FUNCTIONALITY
        BloxOneDDI

    .FUNCTIONALITY
        NIOS
    
    .FUNCTIONALITY
        Migration
    #>
    param (
        [Parameter(Mandatory=$true)]
        $NIOSLBDN,
        [Parameter(Mandatory=$true)]
        $B1DNSView,
        [Switch]$ApplyChanges
    )

    $MethodArr = @{
        'round_robin' = 'RoundRobin'
        'ratio' = 'Ratio'
        'global_availability' = 'GlobalAvailability'
        'topology' = 'Topology'
    }

    Write-Host "Querying BloxOne DNS View: $($B1DNSView)" -ForegroundColor Cyan
    if (!(Get-B1DNSView $B1DNSView -Strict)) {
        Write-Error "Unable to find DNS View: $($B1DNSView)"
        return $null
    }

    Write-Host "Querying DTC LBDN: $($NIOSLBDN)" -ForegroundColor Cyan
    $LBDNToMigrate = Invoke-NIOS -Method GET -Uri "dtc:lbdn?name=$($NIOSLBDN)&_return_fields%2b=auto_consolidated_monitors,disable,health,lb_method,name,patterns,persistence,pools,priority,types,use_ttl,ttl"

    if ($LBDNToMigrate) {
        $NewPools = @()
        $NewLBDNs = @()
        foreach ($Pool in $LBDNToMigrate.pools) {
            Write-Host "Querying DTC Pool: $($Pool.pool)" -ForegroundColor Cyan
            $NIOSPool = Invoke-NIOS -Method GET -Uri "$($Pool.pool)?_return_fields%2b=auto_consolidated_monitors,availability,consolidated_monitors,monitors,disable,health,lb_alternate_method,lb_dynamic_ratio_alternate,lb_dynamic_ratio_preferred,lb_preferred_method,name,quorum,servers,use_ttl"
            $NewPool = [PSCustomObject]@{
                "name" = $NIOSPool.name
                "method" = $NIOSPool.lb_preferred_method.ToLower()
                "servers" = @()
                "monitors" = @()
                "ttl" = $(if ($($NIOSPool.ttl)) { $NIOSPool.ttl } else { $null } )
            }
            foreach ($Server in $NIOSPool.servers) {
                Write-Host "Querying DTC Server: $($Server.server)" -ForegroundColor Cyan
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
            foreach ($Monitor in $NIOSPool.monitors) {
                $ReturnFields = @('name,retry_up,retry_down,timeout,interval')
                $Process = $true
                Switch -Wildcard ($Monitor) {
                    "dtc:monitor:http*" {
                        $ReturnFields += @('content_check','content_check_input','content_check_op','content_extract_group','content_extract_type','enable_sni','port','request','result','result_code','validate_cert')
                    }
                    "dtc:monitor:tcp*" {
                        $ReturnFields += @('port')
                        $Monitor
                    }
                    "dtc:monitor:icmp*" {
                        ## Nothing to add
                    }
                    default {
                        Write-Host "Found unsupported DTC Monitor. BloxOne DTC currently supports TCP, HTTP or ICMP Health Checks, so this one will be skipped: $($Monitor)" -ForegroundColor Red
                        $Process = $false
                    }
                }
                if ($Process) {
                    Write-Host "Querying DTC Monitor: $($Monitor)" -ForegroundColor Cyan
                    $NIOSMonitor = Invoke-NIOS -Method GET -Uri "$($Monitor)?_return_fields%2b=$($ReturnFields -join ',')"
                    $NewPool.monitors += $NIOSMonitor
                }
            }
            $NewPools += $NewPool
        }
    
        foreach ($Pattern in $LBDNToMigrate.patterns) {
            $NewLBDNs += [PSCustomObject]@{
                "Name" = $Pattern
                "Description" = $LBDNToMigrate.name
                "DNSView" = $B1DNSView
                "ttl" = $(if ($($LBDNToMigrate.ttl)) { $LBDNToMigrate.ttl } else { $null } )
                "priority" = $LBDNToMigrate.priority
                "persistence" = $LBDNToMigrate.persistence
                "types" = $LBDNToMigrate.types
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
        
        $Results | ConvertTo-Json -Depth 5
        
        if ($ApplyChanges) {
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
                    $B1DTCServer = New-B1DTCServer @ServerSplat
                    if ($B1DTCServer.id) {
                        Write-Host "Successfully created DTC Server: $($B1DTCServer.name)" -ForegroundColor Green
                    } else {
                        Write-Host "Failed to create DTC Server $($ServerSplat.Name)" -ForegroundColor Red
                    }
                }
                $PoolSplat = @{
                    "Name" = $MigrationPool.name
                    "LoadBalancingType" = $MethodArr[$MigrationPool.method]
                    "Servers" = $(if ($MigrationPool.method -eq "ratio") { ($MigrationPool.Servers | Select *,@{name="ratio-host";expression={"$($_.name):$($_.weight)"}}).'ratio-host' -join ',' } else { $MigrationPool.Servers.name -join ',' })
                }
                $B1DTCPool = New-B1DTCPool @PoolSplat
                if ($B1DTCPool.id) {
                    Write-Host "Successfully created DTC Pool: $($B1DTCPool.name)" -ForegroundColor Green
                } else {
                    Write-Host "Failed to create DTC Pool $($PoolSplat.Name)" -ForegroundColor Red
                }
                $PoolList += $PoolSplat.Name
            }
    
            $B1DTCPolicy = New-B1DTCPolicy -Name $Results.Policy.Name -LoadBalancingType $MethodArr[$Results.Policy.LoadBalancingMethod] -Pools $PoolList
            if ($B1DTCPolicy.id) {
                Write-Host "Successfully created DTC Policy: $($B1DTCPolicy.name)" -ForegroundColor Green
            } else {
                Write-Host "Failed to create DTC Policy $($Results.Policy.Name)" -ForegroundColor Red
            }
    
            foreach ($MigrationLBDN in $Results.lbdn) {
                $B1DTCLBDN = New-B1DTCLBDN -Name $MigrationLBDN.Name -Description $MigrationLBDN.Description -DNSView $MigrationLBDN.DNSView -Policy $Results.Policy.Name
                if ($B1DTCLBDN.id) {
                    Write-Host "Successfully created DTC LBDN: $($B1DTCLBDN.name)" -ForegroundColor Green
                } else {
                    Write-Host "Failed to create DTC LBDN $($MigrationLBDN.Name)" -ForegroundColor Red
                }
            }
    
            ## Create the DTC Health Check(s)
    
            ## Need to populate TTL Values & Topology Rulesets where applicable
        }
    } else {
        Write-Error "Error - Unable to find LBDN: $($NIOSLBDN)"
    }

}


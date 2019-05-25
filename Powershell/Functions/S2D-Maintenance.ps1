<#
This file contains powershell functions, designed to make it easier
to perform maintenance on S2D Clusters and nodes.

Dot source the file to import the functions
eg. PS> . C:\Scripts\S2D-Maintenance.ps1

Functions:
- Enable-S2DNodeMaintenance
- Disable-S2DNodeMaintenance
- Get-S2DNodeMaintenanceState
- Stop-S2DCluster

Maintained by: Ben Thomas (@NZ_BenThomas)
Version: 1.0.3
Last Updated: 2019-05-26
Website: https://bcthomas.com

Changelog:
 - 1.0.0 (2019-05-25)
  - Initial Commit
 - 1.0.1 (2019-05-25)
  - Added verbose output
 - 1.0.2 (2019-05-25)
  - Disabled Verbose Output on Get-Module
 - 1.0.3 (2019-05-26)
  - Added Stop-S2DCluster command
#>

Function Enable-S2DNodeMaintenance { 
    [cmdletbinding()]
    Param(
        [alias('ComputerName', 'StorageNodeFriendlyName')]
        [string]$Name = $Env:ComputerName,
        [switch]$OnlyCluster,
        [switch]$OnlyStorage
    )
    begin {
        Write-Verbose "Checking that the required powershell modules are available"
        $AvailableModules = Get-Module -ListAvailable -Verbose:$false
        if ( $AvailableModules.Name -inotcontains "FailoverClusters" -or $AvailableModules.Name -inotcontains "Storage" ) {
            throw "Required modules FailoverClusters and Storage are not available"
        }
    }
    process {
        Write-Verbose "Checking that all volumes are currently healthy before enabling maintenance"
        $UnhealthyDisks = Get-VirtualDisk -CimSession $Name | Where-Object { 
            $_.HealthStatus -ine "Healthy" -and $_.OperationalStatus -ine "OK" 
        }
        if ($UnhealthyDisks.Count -gt 0) {
            throw "Cannot enter maintenance mode as the follow volumes are unhealthy`n$($UnhealthyDisks.FriendlyName -join ", ")"
        }
        if ( -not $OnlyStorage ) {
            Write-Verbose "Pausing and draining $Name"
            $ClusterName = Get-Cluster -Name $Name | Select-Object -ExpandProperty Name
            $NodeState = (Get-ClusterNode -Name $Name -Cluster $ClusterName).State
            if ( $NodeState -ieq 'Up' ) {
                Suspend-ClusterNode -Name $Name -Drain -Cluster $ClusterName -Wait | Out-Null
            }
            elseif ($NodeState -ieq 'Paused') {
                Write-Verbose "Skipping $Name as it is already paused"
            }
            else {
                Write-Warning "$Name is currently $NodeState"
            }
        }
        if ( -not $OnlyCluster ) {
            Write-Verbose "Enabling Storage Maintenance Mode on disks in $Name"
            $ScaleUnit = Get-StorageFaultDomain -Type StorageScaleUnit -CimSession $Name | Where-Object { $_.FriendlyName -eq $Name }
            $ScaleUnit | Enable-StorageMaintenanceMode -CimSession $Name | Out-Null
            Start-Sleep -Seconds 5
        }
    }
    end {
        Write-Verbose "Returning current state of host"
        Get-S2DNodeMaintenanceState -Name $Name
    }
}

Function Disable-S2DNodeMaintenance {
    [cmdletbinding()]
    Param(
        [alias('ComputerName', 'StorageNodeFriendlyName')]
        [string]$Name = $Env:ComputerName,
        [switch]$OnlyCluster,
        [switch]$OnlyStorage
    )
    begin {
        Write-Verbose "Checking that the required powershell modules are available"
        $AvailableModules = Get-Module -ListAvailable -Verbose:$false
        if ( $AvailableModules.Name -inotcontains "FailoverClusters" -or $AvailableModules.Name -inotcontains "Storage" ) {
            throw "Required modules FailoverClusters and Storage are not available"
        }
    }
    process {
        if ( -not $OnlyCluster ) {
            Write-Verbose "Disabling Storage Maintenance Mode on disks in $Name"
            $ScaleUnit = Get-StorageFaultDomain -Type StorageScaleUnit -CimSession $Name | Where-Object { $_.FriendlyName -eq $Name }
            $ScaleUnit | Disable-StorageMaintenanceMode -CimSession $Name | Out-Null
            Start-Sleep -Seconds 5
        }
        if ( -not $OnlyStorage ) {
            Write-Verbose "Resuming $Name and moving roles back"
            $ClusterName = Get-Cluster -Name $Name | Select-Object -ExpandProperty Name
            $NodeState = (Get-ClusterNode -Name $Name -Cluster $ClusterName).State
            if ( $NodeState -ieq 'Paused' ) {
                Resume-ClusterNode -Name $Name -Failback Immediate -Cluster $ClusterName | Out-Null
            }
            elseif ($NodeState -ieq "Up") {
                Write-Verbose "Skipping $Name as it is not currently paused"
            }
            else {
                Write-Warning "$Name is currently $NodeState"
            }
        }
    }
    end {
        Write-Verbose "Returning current state of $Name"
        Get-S2DNodeMaintenanceState -Name $Name
    }
}

Function Get-S2DNodeMaintenanceState {
    [cmdletbinding(DefaultParameterSetName = "Node")]
    Param(
        [parameter(ParameterSetName = "Node")]
        [alias('ComputerName')]
        [string[]]$Name = $Env:ComputerName,
        [parameter(ParameterSetName = "Cluster")]
        [string[]]$Cluster
    )
    begin {
        Write-Verbose "Checking that the required powershell modules are available"
        $AvailableModules = Get-Module -ListAvailable -Verbose:$false
        if ( $AvailableModules.Name -inotcontains "FailoverClusters" -or $AvailableModules.Name -inotcontains "Storage" ) {
            throw "Required modules FailoverClusters and Storage are not available"
        }
        if ($PSCmdlet.ParameterSetName -ieq 'Cluster') {
            Write-Verbose "Execution context: Cluster"
            Write-Verbose "Getting Node to Cluster mappings"
            $NodeMappings = @{ }
            $Name = foreach ($S2DCluster in $Cluster) {
                $Nodes = Get-ClusterNode -Cluster $S2DCluster | Select-Object -ExpandProperty Name
                Foreach ($Node in $Nodes) {
                    Write-Verbose "$Node is part of $S2DCluster"
                    $NodeMappings[$Node] = $S2DCluster
                }
                $Nodes
            }
        }
        $results = @()
    }
    process {
        Foreach ($ClusterNode in $Name) {
            Write-Verbose "$ClusterNode - Starting to gather state info"
            Write-Verbose "$ClusterNode - Gather physical disk details"
            $NodeDisks = Get-StorageSubSystem clu* -CimSession $ClusterNode | 
            Get-StorageNode | Where-Object { $_.Name -ilike "*$ClusterNode*" } | 
            Get-PhysicalDisk -PhysicallyConnected -CimSession $ClusterNode

            Write-Verbose "$ClusterNode - Gather Cluster Name"
            if ($PSCmdlet.ParameterSetName -ieq 'Node') {
                $ClusterName = Get-Cluster -Name $ClusterNode | Select-Object -ExpandProperty Name
            }
            else {
                $ClusterName = $NodeMappings[$ClusterNode]
            }
            Write-Verbose "$ClusterNode - Gather Cluster Node State"
            $ClusterNodeState = Get-ClusterNode -Name $ClusterNode -Cluster $ClusterName | Select-Object -ExpandProperty State 
            Write-Verbose "$ClusterNode - Gather Storage Node State"
            $StorageNodeState = switch ($NodeDisks.Where( { $_.OperationalStatus -icontains "In Maintenance Mode" } ).Count) {
                0 { "Up"; Break }
                { $_ -lt $NodeDisks.Count } { "PartialMaintenance"; Break }
                { $_ -eq $NodeDisks.Count } { "InMaintenance"; Break }
                default { "UNKNOWN" }
            }
            Write-Verbose "$ClusterNode - Compile results"
            $Results += [pscustomobject][ordered]@{
                Cluster      = $ClusterName
                Name         = $ClusterNode
                ClusterState = $ClusterNodeState
                StorageState = $StorageNodeState
            }
        }
    }
    end {
        Write-Verbose "Return state details"
        $results
    }
}

Function Stop-S2DCluster {
    [cmdletbinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string[]]$Name,
        [switch]$SkipVirtualDiskCheck
    )
    begin { 
        $results = @()
    }
    process {
        Foreach ($Cluster in $Name) {
            try {
                Write-Verbose "$Cluster - Gathering required information"
                $ClusterResources = Get-ClusterResource -Cluster $Cluster
                $ClusterPool = $ClusterResources | where-object { $_.ResourceType -eq "Storage Pool" }
                $CSVs = Get-ClusterSharedVolume -Cluster $Cluster
                $ClusterNodes = Get-ClusterNode -Cluster $Cluster
                $VirtualDisks = Get-VirtualDisk -CimSession $Cluster
                # Check Virtual Disks are healthy before shutting down
                Write-Verbose "$Cluster - Checking for unhealthy volumes"
                $UnhealthyDisks = $VirtualDisks | Where-Object { 
                    $_.HealthStatus -ine "Healthy" -and $_.OperationalStatus -ine "OK" 
                }
                if ($UnhealthyDisks.Count -gt 0 -and $SkipVirtualDiskCheck) {
                    Write-Warning "There are $($UnhealthyDisks.Count) unhealthy volumes on $Cluster"
                }
                elseif ($UnhealthyDisks.Count -gt 0) {
                    Throw "$Cluster has $($UnhealthyDisks.Count) unhealthy disks.`nResolve issues with volume health before continuing`nor use -SkipVirtualDiskCheck and try again."
                }
                # Check there are no running VMs
                Write-Verbose "$Cluster - Checking for running VMs"
                $RunningVMs = $ClusterResources | Where-Object { 
                    $_.ResourceType -eq "Virtual Machine" -and $_.State -eq "Online" 
                } 
                if ($RunningVMs.Count -gt 0) {
                    # Possibly use ShoudlProcess here instead to offer stopping VMs
                    Throw "$Cluster cannot to shutdown because there are still running VMs`nVMs: $( ( $RunningVMs -join ", " ) )"
                }
                # Stop CSVs
                Write-Verbose "$Cluster - Starting shutdown proceedures"
                Foreach ($CSV in $CSVs) {
                    if ($PSCmdlet.ShouldProcess(
                            ("Stopping {0} on {1}" -f $CSV.Name, $Cluster),
                            ("Would you like to stop {0} on {1}?" -f $CSV.Name, $Cluster),
                            "Stop Cluster Shared Volume"
                        )
                    ) {
                        try {
                            $CSV | Stop-ClusterResource -Cluster $Cluster -ErrorAction Stop
                        }
                        catch {
                            Throw "Something went wrong when trying to stop $($CSV.Name)`nRerun the command.`n$($PSItem.ToString())"
                        }
                    }
                }
                # Stop Cluster Pool
                if ($PSCmdlet.ShouldProcess(
                        ("Stopping {0} on {1}" -f $ClusterPool.Name, $Cluster),
                        ("Would you like to stop {0} on {1}?" -f $ClusterPool.Name, $Cluster),
                        "Stop Cluster Pool"
                    )
                ) {
                    try {
                        $ClusterPool | Stop-ClusterResource -Cluster $Cluster -ErrorAction Stop
                    }
                    catch {
                        Throw "Something went wrong when trying to stop $($ClusterPool.Name)`nRerun the command.`n$($PSItem.ToString())"
                    }
                }

                # Stop Cluster
                if ($PSCmdlet.ShouldProcess(
                        ("Stopping {0}" -f $Cluster),
                        ("Would you like to stop {0}?" -f $Cluster),
                        "Stop Cluster"
                    )
                ) {
                    try {
                        # Stop Cluster
                        Write-Verbose "$Cluster - Shutting down Cluster"
                        Stop-Cluster -Cluster $Cluster -Force -Confirm:$false -ErrorAction Stop
                        foreach ($Node in $ClusterNodes.Name) {
                            $Service = Get-Service clussvc -ComputerName $Node
                            # Stop Cluster Service on hosts
                            Write-Verbose "$Cluster - $Node - Stopping Cluster Service"
                            $Service | Stop-Service
                            # Set Cluster Service to disabled on hosts
                            Write-Verbose "$Cluster - $Node - Disabling Cluster Service Startup"
                            $Service | Set-Service -StartupType Disabled
                        }
                    }
                    catch {
                        Throw "Something went wrong when trying to stop $($Cluster)`nRerun the command.`n$($PSItem.ToString())"
                    }
                }
            }
            catch {
                Write-Warning "$($PSItem.ToString())"
                $results += [pscustomobject][ordered]@{
                    Name   = $Cluster
                    Result = "Failed"
                }
                continue
            }
            Write-Verbose "$Cluster - Writing results"
            $results += [pscustomobject][ordered]@{
                Name   = $Cluster
                Result = "Succeeded"
            }
        }
    }
    end { 
        Write-Verbose "Returning results"
        $results
    }
}
